// Standalone verification for AudioRED (adaptive depth). Compiles the ACTUAL
// production file (AudioRED.swift) plus this main — no re-implementation, so it
// cannot drift. Round-trips through naked wire bytes exactly like the app.
//   swiftc AudioRED.swift main.swift -o /tmp/audio_red && /tmp/audio_red
import Foundation

func frame(_ i: Int) -> Data { Data("OPUS_FRAME_\(i)".utf8) }

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print("\(cond ? "PASS" : "FAIL")  \(label)")
    if !cond { failures += 1 }
}

// Sender keeps a newest-first ring of the last `depth` frames and packs them;
// `drop` is the set of dropped sequence indices; returns the frames the receiver played.
func run(n: Int, drop: Set<Int>, depth: Int) -> [Data] {
    var rx = AudioREDReceiver()
    var ring: [Data] = []
    var played: [Data] = []
    for i in 0..<n {
        ring.insert(frame(i), at: 0)
        if ring.count > depth { ring.removeLast() }
        let pkt = AudioRED.pack(seq: UInt8(i & 0xFF), frames: ring)
        if drop.contains(i) { continue }
        guard let (s, frames) = AudioRED.parse(pkt) else { played.append(Data("PARSE_FAIL".utf8)); continue }
        played.append(contentsOf: rx.receive(seq: s, frames: frames))
    }
    return played
}

print("== pack/parse round-trip (variable depth, incl max-len) ==")
for frames in [[frame(1)], [frame(9), frame(8)], [frame(5), frame(4), frame(3)],
               [Data(repeating: 0xAB, count: 300), frame(2)]] {
    let (s, fs) = AudioRED.parse(AudioRED.pack(seq: 200, frames: frames))!
    check(s == 200 && fs == Array(frames.prefix(AudioRED.maxFrames)), "roundtrip depth=\(frames.count)")
}
check(AudioRED.parse(Data([0x01])) == nil, "truncated header rejected")
check(AudioRED.parse(Data([0x01, 0x02, 0xFF, 0x00])) == nil, "declared frame past end rejected")
check(AudioRED.parse(Data([0x01, 0x09])) == nil, "count > maxFrames rejected")

print("\n== depth 2 (baseline: survive 1 isolated loss) ==")
check(run(n: 10, drop: [], depth: 2) == (0..<10).map(frame), "no loss -> all in order")
check(run(n: 10, drop: [4], depth: 2) == (0..<10).map(frame), "1 isolated loss recovered")
check(run(n: 10, drop: [4, 5], depth: 2) == [0,1,2,3,5,6,7,8,9].map(frame), "2 CONSECUTIVE -> only #5 recovered (1-deep)")
check(run(n: 12, drop: [3, 7], depth: 2) == (0..<12).map(frame), "2 spaced losses both recovered")

print("\n== depth 3 (survive a 2-loss BURST — the new capability) ==")
check(run(n: 10, drop: [], depth: 3) == (0..<10).map(frame), "no loss -> all in order")
check(run(n: 10, drop: [4], depth: 3) == (0..<10).map(frame), "1 isolated loss recovered")
check(run(n: 10, drop: [4, 5], depth: 3) == (0..<10).map(frame), "2 CONSECUTIVE losses BOTH recovered")
check(run(n: 12, drop: [4, 5, 6], depth: 3) == [0,1,2,3,5,6,7,8,9,10,11].map(frame), "3 consecutive -> #5,#6 recovered, #4 lost (2-deep ceiling)")

print("\n== adaptive: depth changes MID-STREAM without breaking order ==")
do {
    var rx = AudioREDReceiver(); var ring: [Data] = []; var played: [Data] = []
    for i in 0..<12 {
        let depth = i < 6 ? 2 : 3                       // sender bumps depth at frame 6
        ring.insert(frame(i), at: 0); if ring.count > depth { ring.removeLast() }
        let pkt = AudioRED.pack(seq: UInt8(i), frames: ring)
        if i == 8 || i == 9 { continue }                // a 2-burst while at depth 3
        let (s, fs) = AudioRED.parse(pkt)!
        played += rx.receive(seq: s, frames: fs)
    }
    check(played == (0..<12).map(frame), "depth 2->3 mid-call, a 2-burst at depth 3 fully recovered")
}

print("\n== duplicate not played twice; late/reordered dropped ==")
do {
    var rx = AudioREDReceiver(); var played: [Data] = []
    played += rx.receive(seq: 0, frames: [frame(0)])
    played += rx.receive(seq: 1, frames: [frame(1), frame(0)])
    played += rx.receive(seq: 1, frames: [frame(1), frame(0)])   // duplicate
    check(played == [frame(0), frame(1)], "seq 1 twice -> played once")
    let before = played.count
    for i in 2...5 { played += rx.receive(seq: UInt8(i), frames: [frame(i), frame(i-1)]) }
    let afterFwd = played.count
    played += rx.receive(seq: 3, frames: [frame(3), frame(2)])   // arrives late
    check(played.count == afterFwd, "seq 3 after seq 5 -> ignored")
    _ = before
}

print("\n== u8 wraparound with a loss across 255->0 (depth 2) ==")
do {
    var rx = AudioREDReceiver(); var played: [Data] = []
    played += rx.receive(seq: 254, frames: [frame(254), frame(253)])
    played += rx.receive(seq: 255, frames: [frame(255), frame(254)])
    // seq 0 dropped
    played += rx.receive(seq: 1, frames: [frame(257), frame(256)])   // 256==seq0, 257==seq1
    check(played == [frame(254), frame(255), frame(256), frame(257)], "loss at wrap recovered")
}

print("\n== long outage resyncs immediately at any depth ==")
func outageDrop(_ outage: Int, _ depth: Int) -> Int {
    var rx = AudioREDReceiver(); var ring: [Data] = []
    for i in 0..<20 { ring.insert(frame(i), at: 0); if ring.count > depth { ring.removeLast() }; _ = rx.receive(seq: UInt8(i & 0xFF), frames: ring) }
    for i in 20..<(20+outage) { ring.insert(frame(i), at: 0); if ring.count > depth { ring.removeLast() } }
    var dropped = 0
    for k in 0..<300 {
        let i = 20 + outage + k
        ring.insert(frame(i), at: 0); if ring.count > depth { ring.removeLast() }
        if rx.receive(seq: UInt8(i & 0xFF), frames: ring).isEmpty { dropped += 1 } else { break }
    }
    return dropped
}
for o in [130, 200, 255] { check(outageDrop(o, 3) <= 1, "outage \(o) (depth 3) resumes within 1 packet") }

print("\n== exhaustive: every interior single-loss position recovered, depth 2 AND 3 ==")
var ok2 = true, ok3 = true
for k in 1..<19 {
    if run(n: 20, drop: [k], depth: 2) != (0..<20).map(frame) { ok2 = false }
    if run(n: 20, drop: [k], depth: 3) != (0..<20).map(frame) { ok3 = false }
}
check(ok2 && ok3, "all interior single-loss positions recovered at depth 2 and depth 3")

print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
