// Verifies the ICE session orchestration in the ACTUAL IceSession.swift (+ HolePunch.swift).
// Two layers: (1) the candidate-list wire format round-trips bit-exact and rejects garbage;
// (2) TWO real in-process sessions exchange serialized candidate blobs and actually connect
// over loopback UDP, each correctly IGNORING a higher/equal-priority decoy candidate that
// never answers (192.0.2.2, an RFC 5737 unroutable address) and nominating the real peer.
// Deterministic: both sides retransmit for the whole window on lossless loopback.
//   swiftc HolePunch.swift IceSession.swift ice_session.swift -o /tmp/ice && /tmp/ice
import Foundation

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

print("== candidate-list serialization ==")
do {
    let cands = [Ice.Candidate(ip: "192.168.1.7", port: 5000, kind: .host),
                 Ice.Candidate(ip: "203.0.113.7", port: 61234, kind: .srflx)]
    let blob = Ice.encode(cands)
    check(Ice.decode(blob) == cands, "encode -> decode round-trips a mixed host/srflx list")
    check(Ice.decode(Data([0x00, 0x02, 126])) == nil, "count says 2 but bytes run out -> nil")
    check(Ice.decode(Data()) == nil, "empty -> nil")
    check(Ice.decode(Ice.encode([])) == [], "empty list round-trips to empty")
    // a bad kind byte is rejected
    check(Ice.decode(Data([0x00, 0x01, 0x07, 0x13, 0x88, 0x01, 0x41])) == nil, "unknown kind byte -> nil")
}

print("== two sessions connect over loopback, discarding a dead decoy candidate ==")
do {
    let pA: UInt16 = 48311, pB: UInt16 = 48312
    let decoy = Ice.Candidate(ip: "192.0.2.2", port: 9, kind: .host)   // RFC 5737 unroutable: never answers
    // each side advertises its real host candidate; the peer also sees the decoy first
    let aSeesB = [decoy] + (Ice.decode(Ice.encode([Ice.Candidate(ip: "127.0.0.1", port: pB, kind: .host)])) ?? [])
    let bSeesA = [decoy] + (Ice.decode(Ice.encode([Ice.Candidate(ip: "127.0.0.1", port: pA, kind: .host)])) ?? [])

    var rA: Ice.Connected?, rB: Ice.Connected?
    let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { rA = Ice.connect(localPort: pA, remote: aSeesB, timeoutMs: 1500); g.leave() }
    g.enter(); DispatchQueue.global().async { rB = Ice.connect(localPort: pB, remote: bSeesA, timeoutMs: 1500); g.leave() }
    g.wait()

    check(rA?.remote.ip == "127.0.0.1" && rA?.remote.port == pB, "A nominated the REAL peer 127.0.0.1:\(pB), not the decoy")
    check(rB?.remote.ip == "127.0.0.1" && rB?.remote.port == pA, "B nominated the REAL peer 127.0.0.1:\(pA), not the decoy")
    check(rA?.localPort == pA, "A reports its own bound port as the media socket")
    check(rB?.localPort == pB, "B reports its own bound port as the media socket")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
