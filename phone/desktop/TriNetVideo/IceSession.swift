// IceSession.swift — the THIRD brick of NAT traversal: turn "I know my candidates" (host +
// STUN server-reflexive) and "I can punch a known port" (HolePunch) into "connect to this
// peer". Two things #43 lacked:
//   1. a wire format for the candidate LIST, so the two sides can exchange candidates over a
//      signaling / rendezvous channel (a room code, the mesh, anything);
//   2. orchestration: probe ALL of the peer's candidates at once and nominate the pair that
//      actually round-trips, ignoring the ones that never answer (a NAT may block some).
// Pure + standalone; reuses HolePunch's probe/ack codec and priority. Verified by two
// in-process sessions that exchange serialized candidate blobs and actually connect over
// loopback UDP, discarding a decoy candidate. A single machine cannot prove real-NAT
// traversal (needs two separate NATs); the check/serialize/nominate is what is proven.
import Foundation

enum Ice {
    typealias Candidate = HolePunch.Candidate

    // ---- candidate-list wire format (crosses the signaling channel) ----
    // [count:2 BE] then per candidate [kind:1][port:2 BE][ipLen:1][ip utf8].
    static func encode(_ cands: [Candidate]) -> Data {
        var d = Data()
        d.append(UInt8(cands.count >> 8)); d.append(UInt8(cands.count & 0xFF))
        for c in cands {
            let ip = Array(c.ip.utf8)
            d.append(UInt8(c.kind.rawValue))
            d.append(UInt8(c.port >> 8)); d.append(UInt8(c.port & 0xFF))
            d.append(UInt8(ip.count))
            d.append(contentsOf: ip)
        }
        return d
    }

    static func decode(_ data: Data) -> [Candidate]? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let count = Int(b[0]) << 8 | Int(b[1])
        var i = 2
        var out: [Candidate] = []
        for _ in 0..<count {
            guard i + 4 <= b.count, let kind = HolePunch.Kind(rawValue: Int(b[i])) else { return nil }
            let port = UInt16(b[i + 1]) << 8 | UInt16(b[i + 2])
            let ipLen = Int(b[i + 3])
            let ipStart = i + 4
            guard ipStart + ipLen <= b.count, let ip = String(bytes: b[ipStart ..< ipStart + ipLen], encoding: .utf8) else { return nil }
            out.append(Candidate(ip: ip, port: port, kind: kind))
            i = ipStart + ipLen
        }
        return out.count == count ? out : nil
    }

    // fd is the socket that PUNCHED the pinhole. A symmetric NAT maps per-destination, so the hole
    // belongs to that socket, not merely to the local port: media sent from a fresh socket gets a
    // NEW mapping the peer's NAT drops. With keepSocket the caller adopts this fd (and must close
    // it); without it fd is -1 and the socket is closed here.
    struct Connected: Equatable { let remote: Candidate; let localPort: UInt16; let fd: Int32 }

    // Bind one UDP socket, then for the whole window: probe EVERY remote candidate, answer
    // every probe we receive (ack to the observed source — the pinhole), and note which
    // remote's ack echoes our txid. That remote is a working pair. We do not early-exit: a
    // peer that stopped answering the moment it succeeded would strand the other side, so we
    // keep answering and nominate the highest-priority pair that answered by the deadline.
    static func connect(localPort: UInt16, remote: [Candidate], timeoutMs: Int = 1500,
                        keepSocket: Bool = false) -> Connected? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var handedOff = false
        defer { if !handedOff { close(fd) } }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var me = sockaddr_in()
        me.sin_family = sa_family_t(AF_INET)
        me.sin_port = localPort.bigEndian
        me.sin_addr.s_addr = 0
        let bound = withUnsafePointer(to: &me) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        let boundPort = localBoundPort(fd) ?? localPort

        var tv = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // precompute a sockaddr for each remote candidate, ordered by priority
        let ordered = remote.sorted { HolePunch.priority($0) > HolePunch.priority($1) }
        let remoteAddrs: [(Candidate, sockaddr_in)] = ordered.map { c in
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = c.port.bigEndian
            inet_pton(AF_INET, c.ip, &a.sin_addr)
            return (c, a)
        }

        let myTxid = UInt64.random(in: 0 ... UInt64.max)
        let probe = HolePunch.probePacket(txid: myTxid)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var winners: Set<String> = []                       // "ip:port" of remotes that acked us
        var buf = [UInt8](repeating: 0, count: 64)

        while Date() < deadline {
            for (_, a) in remoteAddrs {
                var aa = a
                _ = probe.withUnsafeBytes { pb in
                    withUnsafePointer(to: &aa) { pp in
                        pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            sendto(fd, pb.baseAddress, probe.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    recvfrom(fd, &buf, buf.count, 0, sp, &fromLen)
                }
            }
            guard n > 0 else { continue }
            let pkt = Data(buf.prefix(n))
            if let t = HolePunch.probeTxid(pkt) {            // peer's probe -> ack the observed source
                let ack = HolePunch.ackPacket(txid: t)
                _ = ack.withUnsafeBytes { ab in
                    withUnsafeMutablePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            sendto(fd, ab.baseAddress, ack.count, 0, sp, fromLen)
                        }
                    }
                }
            } else if let t = HolePunch.ackTxid(pkt), t == myTxid {   // our probe was answered
                var addr = from.sin_addr
                var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr, &ipbuf, socklen_t(INET_ADDRSTRLEN))
                winners.insert("\(String(cString: ipbuf)):\(UInt16(bigEndian: from.sin_port))")
            }
        }
        // nominate the highest-priority candidate that answered
        for (c, _) in remoteAddrs where winners.contains("\(c.ip):\(c.port)") {
            guard keepSocket else { return Connected(remote: c, localPort: boundPort, fd: -1) }
            // hand the punched socket to the caller: clear the probe-loop recv timeout first, or
            // the adopting receive loop sees a spurious EAGAIN every 50ms.
            var tv = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            handedOff = true
            return Connected(remote: c, localPort: boundPort, fd: fd)
        }
        return nil
    }

    private static func localBoundPort(_ fd: Int32) -> UInt16? {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return ok == 0 ? UInt16(bigEndian: a.sin_port) : nil
    }
}
