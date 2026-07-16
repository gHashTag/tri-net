// MeshTransport.swift — BSD-socket UDP transport.
// NWListener on macOS binds IPv6-only and silently drops IPv4 datagrams
// (proven in VideoCallTab: BSD recvfrom received 770k+ packets where
// NWListener received zero). One AF_INET socket bound to :listenPort
// handles both directions, so the peer sees our source port = 7000.
import Foundation
import Darwin

class MeshTransport {
    private var fd: Int32 = -1
    private var peer = sockaddr_in()
    private var running = false
    private let rxQueue = DispatchQueue(label: "mesh.rx", qos: .userInitiated)
    var onReceive: ((Data) -> Void)?
    var connected = false

    func connect(peerHost: String, peerPort: UInt16, listenPort: UInt16) {
        disconnect()

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

        let sock = fd
        rxQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var count = 0
            while true {
                guard let self = self, self.running else { break }
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    count += 1
                    if count == 1 || count % 500 == 0 {
                        NSLog("TRINET: rx #\(count) \(n)B")
                    }
                    if let nal = self.reassemble(Data(bytes: buf, count: n)) {
                        self.onReceive?(nal)
                    }
                } else {
                    break // socket closed by disconnect() or error
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
    private var fragSeqIn: UInt16 = 0xFFFF
    private var fragParts: [Data?] = []
    private var fragHave = 0
    private var sendErrCount = 0

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

    private func rawSend(_ data: Data) {
        var p = peer
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &p) { pp in
                pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                    sendto(fd, raw.baseAddress, data.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            sendErrCount += 1
            if sendErrCount <= 5 || sendErrCount % 500 == 0 {
                NSLog("TRINET: sendto(\(data.count)B) failed: \(String(cString: strerror(errno))) (#\(sendErrCount))")
            }
        }
    }

    // Returns a complete NAL when the datagram finishes one, nil otherwise
    private func reassemble(_ d: Data) -> Data? {
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4])
        let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        if seq != fragSeqIn || fragParts.count != total {
            fragSeqIn = seq
            fragParts = Array(repeating: nil, count: total)
            fragHave = 0
        }
        if fragParts[idx] == nil {
            fragParts[idx] = d.subdata(in: 6..<d.count)
            fragHave += 1
        }
        if fragHave == total {
            let whole = fragParts.compactMap { $0 }.reduce(Data(), +)
            fragSeqIn = 0xFFFF
            fragParts = []
            fragHave = 0
            return whole
        }
        return nil
    }

    func disconnect() {
        running = false
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
