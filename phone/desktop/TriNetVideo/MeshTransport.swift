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
    private var peerHostStr = ""              // the connected peer's IP, for drop diagnostics
    private var dropByIP: [String: Int] = [:] // undecryptable datagrams per source IP
    private var peers: [(addr: sockaddr_in, ip: String)] = []  // group peers
    private var running = false
    private let rxQueue = DispatchQueue(label: "mesh.rx", qos: .userInitiated)
    // Separate queue: rxQueue is parked forever in a blocking recv(), so a
    // timer scheduled on it would never fire.
    private let hsQueue = DispatchQueue(label: "mesh.hs", qos: .userInitiated)
    var onReceive: ((Data) -> Void)?
    var onSecureSessionReady: (() -> Void)?
    // Group calls need to know WHO sent each datagram (per-source decoding +
    // roster), so recvfrom carries the sender IP up alongside the payload.
    var onReceiveFrom: ((Data, String) -> Void)?
    var connected = false

    // MARK: link feedback (see specs/video_bridge.t27)
    //
    // The node knows its load exactly; we do not. Without this the encoder finds
    // the link's capacity by overrunning it and waiting for the FAR end's
    // decoder to complain (PLI) — which only happens after frames are already
    // broken. Measured on a live call: 44% of our packets dropped by the node,
    // with nothing telling us.
    //
    // Plaintext by design: local telemetry from our own node, no payload bytes,
    // nothing about content. Never put content here.
    /// (advice, utilPct, dropPct, rate). `advice` is the node's VERDICT and the
    /// only thing to act on — the thresholds live in specs/video_bridge.t27 and
    /// nowhere else, because t27c cannot generate Swift and a second copy here
    /// would drift until the node and the encoder disagreed about "full".
    /// The numbers are for the log and the UI.
    var onLinkFeedback: ((_ advice: UInt8, _ utilPct: Int, _ dropPct: Int, _ rate: Int) -> Void)?
    private var fbFd: Int32 = -1
    // A fresh report proves a NODE is relaying for us; used only to route audio.
    private var lastFeedbackAt: Date?
    private static let audioPort: UInt16 = 7002
    private var expressTx = 0
    private var expressErrs = 0
    private let fbQueue = DispatchQueue(label: "mesh.fb", qos: .utility)
    private static let feedbackPort: UInt16 = 7003
    private static let feedbackType: UInt8 = 10
    private static let feedbackLen = 6

    private func startFeedbackListener() {
        stopFeedbackListener()
        fbFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fbFd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fbFd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MeshTransport.feedbackPort.bigEndian
        addr.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Foundation.bind(fbFd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound < 0 {
            // Not fatal: a direct peer-to-peer call has no node to report, so
            // silence here is normal. Say so rather than looking broken.
            NSLog("TRINET: link feedback port busy — running without node telemetry")
            close(fbFd); fbFd = -1
            return
        }
        let fd = fbFd
        fbQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 32)
            while true {
                guard let self = self, self.fbFd == fd else { break }
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                guard n >= MeshTransport.feedbackLen,
                      buf[0] == MeshTransport.feedbackType else { continue }
                let util = Int(buf[1]), drop = Int(buf[2])
                let rate = Int(buf[3]) | (Int(buf[4]) << 8)
                let advice = buf[5]
                self.lastFeedbackAt = Date()
                DispatchQueue.main.async { self.onLinkFeedback?(advice, util, drop, rate) }
            }
        }
    }

    private func stopFeedbackListener() {
        if fbFd >= 0 { close(fbFd); fbFd = -1 }
    }

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

    /// Audio goes to the node's express ingress (AUDIO_IN_PORT 7002): its own
    /// budget, never paced, so it cannot queue behind a keyframe -- and it skips
    /// the parity duplicate (a parity over ONE fragment IS a copy; measured,
    /// audio cost 100 frags/s of a 700/s budget on the video port, half of it
    /// duplicates). Same sealing, different door. Only when a node has proven
    /// itself with a fresh report: on a direct call the peer listens on the
    /// main port alone, and this falls back to the normal path.
    func sendAudio(_ data: Data) {
        let viaNode = lastFeedbackAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if groupMode || !viaNode {
            send(data)
            return
        }
        guard fd >= 0, let wire = crypto.seal(data) else { return }
        var addr = peer
        addr.sin_port = MeshTransport.audioPort.bigEndian
        // Never fail silently in an audio path: a discarded sendto result made
        // vanishing audio indistinguishable from working audio -- the tx
        // counter counts hand-offs, not deliveries.
        let sent = wire.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(fd, raw.baseAddress, wire.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            expressErrs += 1
            if expressErrs % 100 == 1 {
                NSLog("%@", "TRINET: audio express sendto FAILED: \(String(cString: strerror(errno))) (#\(expressErrs))")
            }
        } else {
            expressTx += 1
            if expressTx == 1 { NSLog("%@", "TRINET: audio express up -> :7002 (\(sent)B)") }
            if expressTx % 2500 == 0 { NSLog("%@", "TRINET: audio express #\(expressTx)") }
        }
    }

    // 1-1 (ephemeral forward-secret) — unchanged path.
    func connect(peerHost: String, peerPort: UInt16, listenPort: UInt16) {
        disconnect()
        crypto = MeshCrypto()
        secureReadyEmitted = false
        groupMode = false
        startFeedbackListener()

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
        peerHostStr = peerHost
        dropByIP.removeAll()

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
                        self.emitSecureReadyIfNeeded()
                        self.rawSendWire(self.crypto.handshakePacket())
                        continue
                    }
                    count += 1
                    if count == 1 || count % 500 == 0 { NSLog("TRINET: rx #\(count) \(n)B from \(senderIP)") }
                    if let plain = self.crypto.unseal(pkt) {
                        if let msg = self.reassemble(plain) {
                            self.onReceive?(msg)
                            self.onReceiveFrom?(msg, senderIP)
                        }
                    } else {
                        // Undecryptable: either OUR peer (a real bug — wrong key/corruption) or a STRAY peer
                        // on the shared LAN blasting :7000 (benign). The sender IP tells them apart.
                        self.dropByIP[senderIP, default: 0] += 1
                        let c = self.dropByIP[senderIP]!
                        if c <= 3 || c % 500 == 0 {
                            let who = senderIP == self.peerHostStr ? "OUR PEER — REAL BUG" : "stray peer (ignore)"
                            NSLog("TRINET: DROP undecryptable \(n)B from \(senderIP) [\(who), peer=\(self.peerHostStr)] — \(c) from this IP")
                        }
                    }
                } else if n < 0 {
                    // UDP + ICMP gotcha: a previous sendto to an UNREACHABLE peer delivers its ICMP
                    // error (EHOSTDOWN / ECONNREFUSED / ENETUNREACH / EHOSTUNREACH) on the NEXT recvfrom.
                    // These are TRANSIENT — one dead group peer, or a peer not yet bound during 1-1
                    // startup, must NOT kill the whole receive loop (that ended the entire call ~15s in,
                    // caught by a live loopback test). EINTR is a transient interrupt. Only a genuinely
                    // closed socket (EBADF, when running -> false) exits the loop.
                    let e = errno
                    if e == EINTR || e == EHOSTDOWN || e == ECONNREFUSED || e == ENETUNREACH
                        || e == EHOSTUNREACH || e == EAGAIN || e == EWOULDBLOCK { continue }
                    break
                }
                // n == 0: a zero-length UDP datagram (UDP has no EOF) — ignore and keep receiving.
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
    // `tick` orders partial groups by arrival so GC can evict the OLDEST rather
    // than everything but the current seq (see reassemble).
    private var fragBufs: [UInt16: (parts: [Data?], have: Int, tick: UInt64)] = [:]
    private var fragTick: UInt64 = 0
    private let fragBufsCap = 24
    // FEC parity per fragment group (XOR over padded cells, last-cell length).
    private var fecBufs: [UInt16: (xor: [UInt8], lastLen: Int, total: Int)] = [:]
    // Send parity only when the peer is known to understand it (see send()).
    // Receiving parity is always safe, so only the send side is gated.
    private let fecEnabled = true
    private var sendErrCount = 0

    // MARK: forward-secret session (see MeshCrypto). Data is sealed under a
    // per-connection ephemeral session key; the static PSK only authenticates
    // the handshake, so a later PSK leak can't decrypt recorded traffic.
    private var crypto = MeshCrypto()
    private var handshakeTimer: DispatchSourceTimer?
    private var secureReadyEmitted = false

    private func emitSecureReadyIfNeeded() {
        guard crypto.established, !secureReadyEmitted else { return }
        secureReadyEmitted = true
        DispatchQueue.main.async { self.onSecureSessionReady?() }
    }

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
        // Forward error correction: one XOR-parity packet over all fragments
        // (each cell padded to maxPayload). Lets the peer rebuild ANY single lost
        // fragment without a keyframe request.
        //
        // OFF until BOTH ends run >= v0.9. A pre-v0.9 receiver does NOT ignore an
        // unknown magic: its reassemble() returns any non-0xFA-0xFB datagram as a
        // finished NAL, so parity reached the H.264 decoder as garbage -> decode
        // errors -> PLI -> keyframe storm -> frozen video. There is no safe way to
        // probe an old peer either (any new magic chokes it the same way), so this
        // stays a build-time gate rather than a negotiation.
        if fecEnabled, total >= 2 {
            var xor = [UInt8](repeating: 0, count: maxPayload)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<total {
                    let start = i * maxPayload
                    let end = min(start + maxPayload, data.count)
                    for k in 0..<(end - start) { xor[k] ^= raw[start + k] }
                }
            }
            let lastLen = data.count - (total - 1) * maxPayload
            var parity = Data([0xFA, 0xEC, UInt8(fragSeqOut & 0xFF), UInt8(fragSeqOut >> 8),
                               UInt8(total), UInt8(lastLen & 0xFF), UInt8(lastLen >> 8)])
            parity.append(contentsOf: xor)
            rawSend(parity)
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
        // FEC parity packet: store it, then try to recover a single lost fragment.
        if d.count > 7, d[0] == 0xFA, d[1] == 0xEC {
            let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
            let total = Int(d[4])
            let lastLen = Int(d[5]) | (Int(d[6]) << 8)
            guard total >= 2 else { return nil }
            fecBufs[seq] = (Array(d[7...]), lastLen, total)
            return tryFEC(seq)
        }
        // 0xFA is reserved for this framing layer (raw NALs start 00 00 00 01 and
        // control packets use 0xFB..0xFE). Drop an unknown 0xFA subtype instead of
        // returning it as a finished NAL — handing unknown magic to the decoder is
        // exactly what made pre-v0.9 peers storm on FEC parity.
        if d.count > 1, d[0] == 0xFA, d[1] != 0xFB { return nil }
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4])
        let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        var entry = fragBufs[seq] ?? (Array(repeating: nil, count: total), 0, 0)
        if entry.parts.count != total { entry = (Array(repeating: nil, count: total), 0, 0) }
        if entry.parts[idx] == nil {
            entry.parts[idx] = d.subdata(in: 6..<d.count)
            entry.have += 1
        }
        if entry.have == total {
            fragBufs.removeValue(forKey: seq); fecBufs.removeValue(forKey: seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragTick &+= 1
        entry.tick = fragTick
        fragBufs[seq] = entry
        if let recovered = tryFEC(seq) { return recovered }  // parity may already be here
        // GC by RECENCY, never "keep only the current seq". Audio and video
        // fragments interleave, so wiping every other partial group silently
        // destroyed in-flight audio groups the moment video filled the table —
        // audio died while video kept flowing.
        if fragBufs.count > fragBufsCap {
            let keep = Set(fragBufs.sorted { $0.value.tick > $1.value.tick }
                                   .prefix(fragBufsCap).map { $0.key })
            let dropped = fragBufs.count - keep.count
            fragBufs = fragBufs.filter { keep.contains($0.key) }
            fecBufs = fecBufs.filter { keep.contains($0.key) }
            NSLog("TRINET: frag GC dropped \(dropped) stale group(s)")
        }
        return nil
    }

    // XOR-reconstruct exactly one missing fragment from parity + the rest.
    private func tryFEC(_ seq: UInt16) -> Data? {
        guard let fec = fecBufs[seq], var entry = fragBufs[seq],
              entry.parts.count == fec.total else { return nil }
        let missing = (0..<fec.total).filter { entry.parts[$0] == nil }
        guard missing.count == 1 else { return nil }
        let j = missing[0]
        var rec = fec.xor                       // parity = XOR of all padded cells
        for i in 0..<fec.total where i != j {
            guard let part = entry.parts[i] else { return nil }
            part.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for k in 0..<part.count { rec[k] ^= raw[k] }
            }
        }
        let len = (j == fec.total - 1) ? fec.lastLen : maxPayload
        guard len >= 0, len <= rec.count else { return nil }
        entry.parts[j] = Data(rec.prefix(len))
        entry.have += 1
        if entry.have == fec.total {
            fragBufs.removeValue(forKey: seq); fecBufs.removeValue(forKey: seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragBufs[seq] = entry
        return nil
    }

    func disconnect() {
        running = false
        handshakeTimer?.cancel(); handshakeTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
        stopFeedbackListener()
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
