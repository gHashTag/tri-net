// Verifies the connectivity-check / hole-punch logic in the ACTUAL HolePunch.swift. Three
// layers, all deterministic: (1) probe/ack wire codec bit-exact; (2) ICE-style pair priority
// + nomination on synthetic candidate lists; (3) TWO real agents hole-punch each other over
// loopback UDP. Layer 3 is real UDP but non-flaky: both agents retransmit for the whole
// window on a lossless loopback, so both always hear an ack.
//   swiftc HolePunch.swift holepunch.swift -o /tmp/hp && /tmp/hp
import Foundation

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

print("== probe/ack wire codec ==")
do {
    let txid: UInt64 = 0x0123_4567_89AB_CDEF
    let probe = HolePunch.probePacket(txid: txid)
    let ack = HolePunch.ackPacket(txid: txid)
    check([UInt8](probe) == [0xFD, 0x1C, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF], "probe = 0xFD 0x1C + big-endian txid")
    check([UInt8](ack)   == [0xFD, 0x1D, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF], "ack = 0xFD 0x1D + big-endian txid")
    check(HolePunch.probeTxid(probe) == txid, "probeTxid round-trips")
    check(HolePunch.ackTxid(ack) == txid, "ackTxid round-trips")
    check(HolePunch.ackTxid(probe) == nil && HolePunch.probeTxid(ack) == nil, "a probe is not an ack and vice-versa")
    check(HolePunch.probeTxid(Data([0x00, 0x00])) == nil, "too-short datagram -> nil (no crash)")
    check(HolePunch.probeTxid(Data([0x65])) == nil, "a raw video byte is not a probe")
}

print("== ICE-style pair priority + nomination ==")
do {
    let hostL  = HolePunch.Candidate(ip: "192.168.1.5", port: 5000, kind: .host)
    let srflxL = HolePunch.Candidate(ip: "203.0.113.5", port: 6000, kind: .srflx)
    let hostR  = HolePunch.Candidate(ip: "192.168.1.9", port: 5000, kind: .host)
    let srflxR = HolePunch.Candidate(ip: "203.0.113.9", port: 6000, kind: .srflx)
    check(HolePunch.priority(hostL) > HolePunch.priority(srflxL), "host candidate outranks srflx")

    let ordered = HolePunch.orderedPairs(local: [hostL, srflxL], remote: [hostR, srflxR], controlling: true)
    check(ordered.count == 4, "2x2 candidates -> 4 pairs")
    check(ordered.first!.0 == hostL && ordered.first!.1 == hostR, "highest-priority pair is host-host")
    check(ordered.last!.0 == srflxL && ordered.last!.1 == srflxR, "lowest-priority pair is srflx-srflx")

    // symmetric: both agents compute the SAME pair-priority for the same pair (min/max).
    let pc = HolePunch.pairPriority(local: hostL, remote: hostR, controlling: true)
    let pd = HolePunch.pairPriority(local: hostR, remote: hostL, controlling: false)
    check(pc == pd, "pair priority is identical for controlling and controlled views of the same pair")

    // nomination picks the highest-priority pair that PASSED — even if a better pair failed.
    // only the srflx-srflx pair (index 3) succeeded here.
    let nom = HolePunch.nominate(ordered: ordered, succeeded: [3])
    check(nom?.0 == srflxL && nom?.1 == srflxR, "nominate returns the best SUCCEEDED pair, not the best pair overall")
    check(HolePunch.nominate(ordered: ordered, succeeded: []) == nil, "no successful pair -> no nomination")
}

print("== two agents hole-punch each other over loopback UDP (real sockets) ==")
do {
    let portA: UInt16 = 48231, portB: UInt16 = 48232
    var okA = false, okB = false
    let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { okA = HolePunch.punch(boundPort: portA, peerHost: "127.0.0.1", peerPort: portB, timeoutMs: 1200); g.leave() }
    g.enter(); DispatchQueue.global().async { okB = HolePunch.punch(boundPort: portB, peerHost: "127.0.0.1", peerPort: portA, timeoutMs: 1200); g.leave() }
    g.wait()
    check(okA, "agent A heard an ack for its probe (round-trip A->B->A)")
    check(okB, "agent B heard an ack for its probe (round-trip B->A->B)")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
