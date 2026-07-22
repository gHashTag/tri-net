// Standalone verification for VideoFEC. Compiles the ACTUAL production file, so
// it cannot drift. Simulates encode -> fragment -> drop -> per-group recover ->
// reassemble through naked bytes, exactly like the transport.
//   swiftc VideoFEC.swift video_fec_main.swift -o /tmp/vfec && /tmp/vfec
import Foundation

let MP = 1200
func payload(_ n: Int) -> [UInt8] { (0..<n).map { UInt8(($0 * 37 + 11) & 0xFF) } }

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print("\(cond ? "PASS" : "FAIL")  \(label)")
    if !cond { failures += 1 }
}

func fragments(_ p: [UInt8]) -> [[UInt8]] {
    let total = (p.count + MP - 1) / MP
    return (0..<total).map { i in Array(p[i*MP ..< min((i+1)*MP, p.count)]) }
}

// Run one NAL through group-FEC with a given group size and dropped-fragment set.
// Returns the reassembled payload, or nil if any group could not be repaired.
func roundtrip(_ p: [UInt8], group: Int, drop: Set<Int>) -> [UInt8]? {
    let frags = fragments(p)
    let total = frags.count
    let lastLen = p.count - (total - 1) * MP
    // sender: one parity per group
    var parities: [(gStart: Int, gLen: Int, xor: [UInt8])] = []
    for gStart in VideoFEC.groupStarts(total: total, group: group) {
        let gLen = min(group, total - gStart)
        parities.append((gStart, gLen, VideoFEC.parity(p, maxPayload: MP, gStart: gStart, gLen: gLen, total: total)))
    }
    // receiver: everything that arrived
    var present = [Int: [UInt8]]()
    for i in 0..<total where !drop.contains(i) { present[i] = frags[i] }
    // try to repair each group (one pass is enough: XOR fixes at most one per group)
    for pg in parities {
        if let (idx, bytes) = VideoFEC.recover(parity: pg.xor, present: present, gStart: pg.gStart,
                                               gLen: pg.gLen, total: total, lastLen: lastLen, maxPayload: MP) {
            present[idx] = bytes
        }
    }
    guard present.count == total else { return nil }
    var out = [UInt8]()
    for i in 0..<total { out += present[i]! }
    return out
}

// Whether FEC *should* succeed: no group has more than one loss.
func repairable(total: Int, group: Int, drop: Set<Int>) -> Bool {
    for gStart in VideoFEC.groupStarts(total: total, group: group) {
        let end = min(gStart + group, total)
        if (gStart..<end).filter({ drop.contains($0) }).count > 1 { return false }
    }
    return true
}

print("== no loss reassembles exactly (various sizes/groups) ==")
for (n, g) in [(3*MP, 16), (16*MP + 500, 16), (40*MP + 7, 16), (40*MP + 7, 4)] {
    let p = payload(n)
    check(roundtrip(p, group: g, drop: []) == p, "n=\(n)B group=\(g) no loss")
}

print("\n== one loss per group is recovered ==")
do {
    let p = payload(40*MP + 7); let total = fragments(p).count      // 41 fragments
    // drop the first fragment of every group at group=16 -> 0, 16, 32 (one per group)
    let drop: Set<Int> = [0, 16, 32]
    check(roundtrip(p, group: 16, drop: drop) == p, "drop 1 per group (0,16,32) recovered")
    // last-fragment loss (partial length) recovered
    check(roundtrip(p, group: 16, drop: [total - 1]) == p, "last (partial) fragment recovered")
}

print("\n== two losses in ONE group cannot be repaired (graceful nil) ==")
do {
    let p = payload(16*MP)
    check(roundtrip(p, group: 16, drop: [2, 5]) == nil, "2 losses in a 16-group -> unrecoverable, no corruption")
    // but the SAME two losses at group=4 fall in different groups -> recovered
    check(roundtrip(p, group: 4, drop: [2, 5]) == p, "same 2 losses at group=4 (different groups) recovered")
}

print("\n== smaller group survives a higher loss rate ==")
do {
    let p = payload(16*MP)                          // 16 fragments
    let drop: Set<Int> = [1, 5, 9, 13]              // 25% loss, spread one-per-4
    check(roundtrip(p, group: 16, drop: drop) == nil, "group=16: 4 losses in one group -> fails")
    check(roundtrip(p, group: 4,  drop: drop) == p,   "group=4: one loss per group -> fully recovered")
}

print("\n== exhaustive: every single-fragment loss recovered at group 4/8/16 ==")
do {
    let p = payload(24*MP + 3); let total = fragments(p).count
    var ok = true
    for g in [4, 8, 16] { for k in 0..<total { if roundtrip(p, group: g, drop: [k]) != p { ok = false; print("  MISS g=\(g) k=\(k)") } } }
    check(ok, "all single-loss positions recovered at every group size")
}

print("\n== model check: roundtrip succeeds IFF repairable() says so (random-ish patterns) ==")
do {
    let p = payload(20*MP); let total = fragments(p).count
    var consistent = true
    // deterministic pseudo-random drop patterns via an LCG
    var seed: UInt64 = 12345
    func rnd() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
    for _ in 0..<400 {
        let g = [4, 8, 16][Int(rnd()) % 3]
        var drop = Set<Int>()
        for i in 0..<total where (rnd() % 100) < 25 { drop.insert(i) }
        let got = roundtrip(p, group: g, drop: drop)
        let expect = repairable(total: total, group: g, drop: drop)
        if (got == p) != expect { consistent = false; print("  mismatch g=\(g) drop=\(drop.sorted())") }
        if got != nil && got != p { consistent = false; print("  CORRUPT output g=\(g) drop=\(drop.sorted())") }
    }
    check(consistent, "400 random loss patterns: recovers exactly when (and only when) no group has >1 loss")
}

print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
