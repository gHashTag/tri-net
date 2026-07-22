// VideoFEC.swift — grouped, adaptive XOR forward error correction for video NALs.
//
// The old scheme sent ONE XOR parity over a whole fragmented NAL, so it repaired
// exactly one lost fragment no matter how big the NAL was. Measured, that left
// video at ~60% delivery under 25% loss: a large keyframe loses several fragments,
// FEC can't repair it, the frame is dropped, a PLI asks for a fresh keyframe (even
// bigger), and the loss cascades into a stall.
//
// This carries ONE parity per GROUP of `group` fragments instead. A 40-fragment
// keyframe at group=16 gets 3 parities (repairs 1 per group); under loss the call
// shrinks the group toward 4 so a quarter of each group can be rebuilt. Overhead
// scales with the protection: 1/group of the NAL, paid only where it's needed.
//
// XOR gives a HARD ceiling of one erasure per group — two losses in the same group
// are unrecoverable (that needs a Reed-Solomon / RLNC code). Shrinking the group
// trades bandwidth for a higher survivable loss rate; it does not lift that ceiling.
//
// Parity wire (after the [0xFA 0xEC] magic):
//   [seqLo seqHi][total:1][gStart:1][gLen:1][lastLen:2 LE] + xor[maxPayload]
// gStart/gLen name the fragment range this parity covers; total/lastLen let the
// receiver size the one fragment it rebuilds. PURE (Foundation only) so the
// standalone harness compiles the exact production codec — no drift.
import Foundation

enum VideoFEC {
    static let cleanGroup = 16   // fragments per parity on a clean link (low overhead)
    static let lossyGroup = 4    // fragments per parity while the link is dropping frames

    // Contiguous group start indices for `total` fragments at the given group size.
    static func groupStarts(total: Int, group: Int) -> [Int] {
        let g = max(1, group)
        return Array(stride(from: 0, to: total, by: g))
    }

    // XOR parity over data fragments [gStart, gStart+gLen) of `payload`, each cell
    // padded to maxPayload. `payload` is the whole NAL; fragment i is
    // payload[i*maxPayload ..< min((i+1)*maxPayload, count)].
    static func parity(_ payload: [UInt8], maxPayload: Int, gStart: Int, gLen: Int, total: Int) -> [UInt8] {
        var xor = [UInt8](repeating: 0, count: maxPayload)
        let end = min(gStart + gLen, total)
        for i in gStart..<end {
            let start = i * maxPayload
            let stop = min(start + maxPayload, payload.count)
            for k in 0..<(stop - start) { xor[k] ^= payload[start + k] }
        }
        return xor
    }

    // Rebuild the single missing fragment in a group from its parity + the present
    // fragments, or nil if the group has zero or >1 missing (XOR can only fix one).
    static func recover(parity: [UInt8], present: [Int: [UInt8]],
                        gStart: Int, gLen: Int, total: Int, lastLen: Int, maxPayload: Int) -> (idx: Int, bytes: [UInt8])? {
        let end = min(gStart + gLen, total)
        guard end > gStart else { return nil }
        var missing = -1
        for i in gStart..<end where present[i] == nil {
            if missing != -1 { return nil }   // more than one missing -> unrecoverable
            missing = i
        }
        guard missing != -1 else { return nil }   // nothing missing
        var rec = parity
        for i in gStart..<end where i != missing {
            guard let p = present[i] else { return nil }
            for k in 0..<p.count { rec[k] ^= p[k] }
        }
        let len = (missing == total - 1) ? lastLen : maxPayload
        guard len >= 0, len <= rec.count else { return nil }
        return (missing, Array(rec.prefix(len)))
    }
}
