// HolePunch.swift — the SECOND brick of NAT traversal, on top of StunClient. Once each
// side knows its candidates (host addresses + the STUN server-reflexive address), the two
// peers send probes to each other's candidates AT THE SAME TIME. That simultaneous open is
// what punches a pinhole through each NAT: NAT B lets A's probe in because B just sent one
// out toward A, and vice-versa. The pair that completes a probe/ack round-trip is the one
// the media call then uses.
//
// Pure + standalone (like StunClient / MeshCrypto): the probe/ack wire format and the
// ICE-style pair-priority / nomination are proven deterministically, and two in-process
// agents actually hole-punch each other over loopback UDP in the harness. What a single
// machine canNOT prove is traversal of a REAL NAT (needs two separate NATs); that is the
// integration step. Not yet wired into the transport.
import Foundation

enum HolePunch {
    // 0xFD is the control family; 0x1C/0x1D are free (0x11/0x4E/0x4F/0xAD/0xBE/0xC0 are taken).
    private static let probeTag: [UInt8] = [0xFD, 0x1C]
    private static let ackTag:   [UInt8] = [0xFD, 0x1D]

    // ---- candidates + ICE-style priority (RFC 8445 §5.1.2 / §6.1.2) ----
    enum Kind: Int { case host = 126, srflx = 100 }        // type preferences
    struct Candidate: Equatable { let ip: String; let port: UInt16; let kind: Kind }

    static func priority(_ c: Candidate) -> UInt32 {
        (UInt32(c.kind.rawValue) << 24) | 255              // component 1 -> (256 - 1)
    }
    // Pair priority, RFC 8445 §6.1.2.3: G is the controlling agent's candidate priority,
    // D the controlled agent's. min/max make the value symmetric across the two agents.
    static func pairPriority(local: Candidate, remote: Candidate, controlling: Bool) -> UInt64 {
        let g = UInt64(priority(controlling ? local : remote))
        let d = UInt64(priority(controlling ? remote : local))
        return (UInt64(1) << 32) * min(g, d) + 2 * max(g, d) + (g > d ? 1 : 0)
    }
    // All candidate pairs, highest priority first — the check order.
    static func orderedPairs(local: [Candidate], remote: [Candidate], controlling: Bool) -> [(Candidate, Candidate)] {
        var pairs: [(Candidate, Candidate)] = []
        for l in local { for r in remote { pairs.append((l, r)) } }
        return pairs.sorted { pairPriority(local: $0.0, remote: $0.1, controlling: controlling)
                            > pairPriority(local: $1.0, remote: $1.1, controlling: controlling) }
    }
    // Nominate: the controlling agent picks the highest-priority pair that PASSED its check.
    static func nominate(ordered: [(Candidate, Candidate)], succeeded: Set<Int>) -> (Candidate, Candidate)? {
        for (i, pair) in ordered.enumerated() where succeeded.contains(i) { return pair }
        return nil
    }

    // ---- probe / ack wire codec ----
    static func probePacket(txid: UInt64) -> Data { Data(probeTag + be(txid)) }
    static func ackPacket(txid: UInt64) -> Data { Data(ackTag + be(txid)) }
    static func probeTxid(_ d: Data) -> UInt64? { txid(d, tag: probeTag) }
    static func ackTxid(_ d: Data)   -> UInt64? { txid(d, tag: ackTag) }

    private static func be(_ x: UInt64) -> [UInt8] { (0..<8).map { UInt8((x >> (56 - 8 * $0)) & 0xFF) } }
    private static func txid(_ d: Data, tag: [UInt8]) -> UInt64? {
        let b = [UInt8](d)
        guard b.count == 10, b[0] == tag[0], b[1] == tag[1] else { return nil }
        return b[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    // ---- the actual hole-punch over one UDP socket ----
    // Bind boundPort, then for the whole window: retransmit our probe toward the peer, answer
    // every probe we receive with an ack (replying to the OBSERVED source, which is what a
    // symmetric NAT rewrites the port to), and watch for an ack that echoes OUR txid. Success
    // = we heard an ack for our own probe, i.e. this pair round-tripped. Retransmission is
    // what makes the simultaneous open robust to which side sends first.
    static func punch(boundPort: UInt16, peerHost: String, peerPort: UInt16, timeoutMs: Int = 1200) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var me = sockaddr_in()
        me.sin_family = sa_family_t(AF_INET)
        me.sin_port = boundPort.bigEndian
        me.sin_addr.s_addr = 0                              // INADDR_ANY
        let bound = withUnsafePointer(to: &me) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return false }

        var tv = timeval(tv_sec: 0, tv_usec: 50_000)        // 50ms: re-probe ~20x/sec
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = peerPort.bigEndian
        inet_pton(AF_INET, peerHost, &peer.sin_addr)

        let myTxid = UInt64.random(in: 0 ... UInt64.max)
        let probe = probePacket(txid: myTxid)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var gotAck = false
        var buf = [UInt8](repeating: 0, count: 64)

        while Date() < deadline {
            _ = probe.withUnsafeBytes { pb in
                withUnsafePointer(to: &peer) { pp in
                    pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                        sendto(fd, pb.baseAddress, probe.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
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
            guard n > 0 else { continue }                   // timeout -> re-probe
            let pkt = Data(buf.prefix(n))
            if let t = probeTxid(pkt) {                      // peer's probe -> ack the observed source
                let ack = ackPacket(txid: t)
                _ = ack.withUnsafeBytes { ab in
                    withUnsafeMutablePointer(to: &from) { fp in
                        fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            sendto(fd, ab.baseAddress, ack.count, 0, sp, fromLen)
                        }
                    }
                }
            } else if let t = ackTxid(pkt), t == myTxid {    // ack for OUR probe -> this pair works
                gotAck = true
            }
        }
        return gotAck
    }
}
