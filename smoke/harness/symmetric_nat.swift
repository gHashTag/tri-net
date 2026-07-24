// Symmetric-NAT semantics, without root. A symmetric NAT allocates a DIFFERENT external port per
// destination, so the address a peer LEARNED from a STUN server is NOT the address its traffic
// arrives from when it talks to you. Kernel NAT emulation needs pfctl/dnctl (root); this models the
// one property that actually breaks hole punching: the peer's probes arrive from a source that is
// NOT in the candidate list it advertised.
//
// Agent A gets a candidate list pointing at a DEAD port (the peer's STUN-learned mapping, useless
// under symmetric NAT) while the peer really speaks from another port. A can only connect if it
// treats the observed source of an incoming probe as a new PEER-REFLEXIVE candidate and nominates
// that. Without peer-reflexive discovery A probes the dead port forever and never nominates.
//   swiftc HolePunch.swift IceSession.swift symmetric_nat.swift -o /tmp/sn && /tmp/sn
import Foundation

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

// A peer that behaves like one behind a symmetric NAT: it answers probes and sends its own, but
// always from `actualPort`, while the world was told about `advertisedPort`.
func natPeer(actualPort: UInt16, targetPort: UInt16, seconds: Double) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var me = sockaddr_in(); me.sin_family = sa_family_t(AF_INET); me.sin_port = actualPort.bigEndian; me.sin_addr.s_addr = 0
    _ = withUnsafePointer(to: &me) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var tv = timeval(tv_sec: 0, tv_usec: 50_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var target = sockaddr_in(); target.sin_family = sa_family_t(AF_INET); target.sin_port = targetPort.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &target.sin_addr)

    let myTxid = UInt64.random(in: 0 ... UInt64.max)
    let probe = HolePunch.probePacket(txid: myTxid)
    let deadline = Date().addingTimeInterval(seconds)
    var buf = [UInt8](repeating: 0, count: 64)
    while Date() < deadline {
        _ = probe.withUnsafeBytes { pb in withUnsafePointer(to: &target) { tp in
            tp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pb.baseAddress, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        var from = sockaddr_in(); var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &flen) } }
        guard n > 0 else { continue }
        if let t = HolePunch.probeTxid(Data(buf.prefix(n))) {         // ack whatever probes us
            let ack = HolePunch.ackPacket(txid: t)
            _ = ack.withUnsafeBytes { ab in withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, ab.baseAddress, ack.count, 0, $0, flen) } } }
        }
    }
}

print("== a peer whose real source port differs from its advertised candidate (symmetric NAT) ==")
do {
    let aPort: UInt16 = 48711          // our media port
    let peerActual: UInt16 = 48712     // where the peer really speaks from
    let peerAdvertised: UInt16 = 48713 // the STUN-learned mapping it published: DEAD for us
    DispatchQueue.global().async { natPeer(actualPort: peerActual, targetPort: aPort, seconds: 3.0) }
    Thread.sleep(forTimeInterval: 0.2)

    let advertised = [Ice.Candidate(ip: "127.0.0.1", port: peerAdvertised, kind: .srflx)]
    let got = Ice.connect(localPort: aPort, remote: advertised, timeoutMs: 2500)
    check(got != nil, "connected despite the advertised candidate being the wrong (dead) port")
    check(got?.remote.port == peerActual,
          "nominated the OBSERVED source \(peerActual) (peer-reflexive), not the advertised \(peerAdvertised)")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
