// MeshTransport.swift — BSD-socket UDP transport.
// NWListener on macOS binds IPv6-only and silently drops IPv4 datagrams
// (proven in VideoCallTab: BSD recvfrom received 770k+ packets where
// NWListener received zero). One AF_INET socket bound to :listenPort
// handles both directions, so the peer sees our source port = 7000.
import Foundation
import Darwin
import CryptoKit

class MeshTransport {
    private var fd: Int32 = -1
    private var peer = sockaddr_in()          // 1-1 peer (ephemeral session)
    private var peers: [(addr: sockaddr_in, ip: String)] = []  // group peers
    private var running = false
    private let rxQueue = DispatchQueue(label: "mesh.rx", qos: .userInitiated)
    // Separate queue: rxQueue is parked forever in a blocking recv(), so a
    // timer scheduled on it would never fire.
    private let hsQueue = DispatchQueue(label: "mesh.hs", qos: .userInitiated)
    var onReceive: ((Data) -> Void)?
    // Group calls need to know WHO sent each datagram (per-source decoding +
    // roster), so recvfrom carries the sender IP up alongside the payload.
    var onReceiveFrom: ((Data, String) -> Void)?
    var connected = false

    // Conference mode: a group of >1 peers shares one static conference key
    // (HKDF of the PSK) instead of pairwise ephemeral handshakes — full-mesh
    // broadcast to 2-4 nodes, the right topology for a zero-server mesh.
    private var groupMode = false
    private var groupKey: SymmetricKey?
    private static let confKey = SymmetricKey(
        data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: SHA256.hash(data: Data("tri-net-psk-v1".utf8))),
            salt: Data("trios-mesh/v1/conference".utf8),
            info: Data("group-aead".utf8), outputByteCount: 32))

    // 1-1 (ephemeral forward-secret) — unchanged path.
    func connect(peerHost: String, peerPort: UInt16, listenPort: UInt16) {
        disconnect()
        groupMode = false

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            NSLog("TRINET: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            NSLog("TRINET: bind(:\(listenPort)) failed: \(String(cString: strerror(errno)))")
            close(fd); fd = -1
            return
        }

        peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = peerPort.bigEndian
        peer.sin_addr.s_addr = inet_addr(peerHost)

        running = true
        connected = true
        NSLog("TRINET: BSD transport up — listen :\(listenPort), peer \(peerHost):\(peerPort)")

        // Drive the handshake until a session is established (both sides send
        // periodically so neither has to be "first").
        let timer = DispatchSource.makeTimerSource(queue: hsQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.crypto.established { self.handshakeTimer?.cancel(); self.handshakeTimer = nil; return }
            self.rawSendWire(self.crypto.handshakePacket())
        }
        handshakeTimer = timer
        timer.resume()

        startRx(fd)
    }

    // Receive loop shared by 1-1 and group. recvfrom carries the sender's
    // address so the caller can route by source (per-source decoding + roster).
    private func startRx(_ sock: Int32) {
        rxQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var from = sockaddr_in()
            var count = 0
            while true {
                guard let self = self, self.running else { break }
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                        recvfrom(sock, &buf, buf.count, 0, s, &fromLen)
                    }
                }
                if n > 0 {
                    let pkt = Data(bytes: buf, count: n)
                    let senderIP = String(cString: inet_ntoa(from.sin_addr))
                    if self.groupMode {
                        guard let key = self.groupKey,
                              let box = try? ChaChaPoly.SealedBox(combined: pkt),
                              let plain = try? ChaChaPoly.open(box, using: key) else { continue }
                        if let msg = self.reassemble(plain) {
                            self.onReceiveFrom?(msg, senderIP)
                        }
                        continue
                    }
                    // 1-1 ephemeral path
                    if self.crypto.isHandshake(pkt) {
                        self.crypto.consumeHandshake(pkt)
                        self.rawSendWire(self.crypto.handshakePacket())
                        continue
                    }
                    count += 1
                    if count == 1 || count % 500 == 0 { NSLog("TRINET: rx #\(count) \(n)B") }
                    if let plain = self.crypto.unseal(pkt),
                       let msg = self.reassemble(plain) {
                        self.onReceive?(msg)
                        self.onReceiveFrom?(msg, senderIP)
                    }
                } else {
                    break
                }
            }
        }
    }

    // MARK: application-level fragmentation
    // macOS caps a UDP datagram at net.inet.udp.maxdgram (9216B default), so
    // I-frames (10-60KB) can NEVER be sent whole ("Message too long") and the
    // peer sees only P-frames -> decoder stuck at BadDataErr. NALs larger
    // than maxPayload are split into [0xFA 0xFB seqLo seqHi idx total]+chunk
    // datagrams (< WiFi MTU, so no IP fragmentation either) and reassembled
    // on receive. Raw NALs always start 00 00 00 01, so the magic is unambiguous.
    private let maxPayload = 1200
    private var fragSeqOut: UInt16 = 0
    private var fragBufs: [UInt16: (parts: [Data?], have: Int)] = [:]
    private var sendErrCount = 0

    // MARK: forward-secret session (see MeshCrypto). Data is sealed under a
    // per-connection ephemeral session key; the static PSK only authenticates
    // the handshake, so a later PSK leak can't decrypt recorded traffic.
    private let crypto = MeshCrypto()
    private var handshakeTimer: DispatchSourceTimer?

    func send(_ data: Data) {
        guard fd >= 0 else { return }
        if data.count <= maxPayload {
            rawSend(data)
            return
        }
        let total = (data.count + maxPayload - 1) / maxPayload
        guard total <= 255 else { return }
        fragSeqOut &+= 1
        for i in 0..<total {
            let start = i * maxPayload
            let end = min(start + maxPayload, data.count)
            var pkt = Data([0xFA, 0xFB, UInt8(fragSeqOut & 0xFF), UInt8(fragSeqOut >> 8), UInt8(i), UInt8(total)])
            pkt.append(data.subdata(in: start..<end))
            rawSend(pkt)
        }
    }

    // Encrypt a fragment (group key in conference mode, else the ephemeral
    // session key) and wire it out.
    private func rawSend(_ data: Data) {
        if groupMode {
            guard let key = groupKey,
                  let box = try? ChaChaPoly.seal(data, using: key) else { return }
            rawSendWire(box.combined)
        } else {
            guard let wire = crypto.seal(data) else { return } // drop until session up
            rawSendWire(wire)
        }
    }

    // Send bytes verbatim. In conference mode, full-mesh broadcast to every
    // peer; in 1-1, just the single peer. (Handshakes are self-authenticating.)
    private func rawSendWire(_ wire: Data) {
        guard fd >= 0 else { return }
        if groupMode {
            for var pr in peers { sendOne(wire, &pr.addr) }
        } else {
            sendOne(wire, &peer)
        }
    }

    private func sendOne(_ wire: Data, _ addr: inout sockaddr_in) {
        let sent = wire.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { pp in
                pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                    sendto(fd, raw.baseAddress, wire.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            sendErrCount += 1
            if sendErrCount <= 5 || sendErrCount % 500 == 0 {
                NSLog("TRINET: sendto(\(wire.count)B) failed: \(String(cString: strerror(errno))) (#\(sendErrCount))")
            }
        }
    }

    // Conference call: 2-4 peers, shared static conference key, full-mesh
    // broadcast, per-source delivery. No pairwise handshake.
    func connectGroup(peerHosts: [String], peerPort: UInt16, listenPort: UInt16) {
        disconnect()
        groupMode = true
        groupKey = MeshTransport.confKey

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { NSLog("TRINET: socket() failed"); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { NSLog("TRINET: group bind failed"); close(fd); fd = -1; return }

        peers = peerHosts.map { ip in
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = peerPort.bigEndian
            a.sin_addr.s_addr = inet_addr(ip)
            return (a, ip)
        }
        running = true
        connected = true
        NSLog("TRINET: GROUP transport up — listen :\(listenPort), \(peers.count) peers")
        startRx(fd)
    }

    // Returns a complete NAL when the datagram finishes one, nil otherwise.
    // Multi-slot: chunks of several NALs may interleave (video + a peer
    // restart, or future multi-stream), so partial buffers are keyed by seq.
    private func reassemble(_ d: Data) -> Data? {
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4])
        let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        var entry = fragBufs[seq] ?? (Array(repeating: nil, count: total), 0)
        if entry.parts.count != total { entry = (Array(repeating: nil, count: total), 0) }
        if entry.parts[idx] == nil {
            entry.parts[idx] = d.subdata(in: 6..<d.count)
            entry.have += 1
        }
        if entry.have == total {
            fragBufs.removeValue(forKey: seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragBufs[seq] = entry
        if fragBufs.count > 8 { fragBufs = fragBufs.filter { $0.key == seq } } // GC stale partials
        return nil
    }

    func disconnect() {
        running = false
        handshakeTimer?.cancel(); handshakeTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
        connected = false
    }

    deinit { disconnect() }

    static func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr!.pointee.ifa_next }
                let iface = ptr!.pointee
                if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    let name = String(cString: iface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                        let s = String(cString: host)
                        if !s.hasPrefix("169.254") { address = s }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
