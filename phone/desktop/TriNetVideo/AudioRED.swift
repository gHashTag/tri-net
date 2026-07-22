// AudioRED.swift — application-level audio redundancy (RED, RFC 2198-style),
// with ADAPTIVE depth.
//
// Opus over UDP has NO loss protection: a dropped 20ms packet is an audible gap.
// Video carries XOR-FEC parity; audio carried nothing, so on a lossy link the
// picture survived while the voice — the part of a call that actually matters —
// broke up. AVAudioConverter (AudioToolbox) exposes neither Opus in-band FEC nor
// PLC, so the fix lives one layer up, in the packet framing.
//
// Each packet carries the CURRENT Opus frame plus a few PREVIOUS ones, so a lost
// packet is reconstructed from the next: seq N lost -> N+1 still contains frame N.
// Carrying ONE previous survives an isolated loss; carrying TWO survives a burst
// of two CONSECUTIVE losses (what a fading radio or a full socket buffer actually
// produces). The sender raises the depth only while the link is lossy (the loss
// controller drives it) so a clean call pays ~2x and a lossy one ~3x, never more.
//
// Payload AFTER the [0xFD 0xC0] magic (self-describing so depth can vary per packet):
//   [seq:1][count:1][len:2 LE]*count [frameBytes]*count
// frame[0] = current, frame[1] = previous, frame[2] = the one before that.
//
// This file is PURE (Foundation only) so the standalone verification harness can
// compile the exact production framing — no re-implementation that could drift.
import Foundation

enum AudioRED {
    static let maxFrames = 3    // current + up to two previous (survives a 2-loss burst)

    // Pack newest-first frames (frame[0] = current). Depth is min(frames.count, maxFrames).
    static func pack(seq: UInt8, frames: [Data]) -> Data {
        let count = min(frames.count, maxFrames)
        var b = [UInt8]()
        b.append(seq)
        b.append(UInt8(count))
        for i in 0..<count {
            let n = min(frames[i].count, 0xFFFF)
            b.append(UInt8(n & 0xFF)); b.append(UInt8((n >> 8) & 0xFF))
        }
        for i in 0..<count { b.append(contentsOf: frames[i]) }
        return Data(b)
    }

    // Split back into (seq, newest-first frames). nil on a malformed header/length
    // so a corrupt datagram is dropped, never decoded as garbage.
    static func parse(_ d: Data) -> (seq: UInt8, frames: [Data])? {
        let b = [UInt8](d)
        guard b.count >= 2 else { return nil }
        let seq = b[0]
        let count = Int(b[1])
        guard count >= 1, count <= maxFrames else { return nil }
        guard b.count >= 2 + count * 2 else { return nil }
        var lens = [Int](); var off = 2
        for _ in 0..<count { lens.append(Int(b[off]) | (Int(b[off + 1]) << 8)); off += 2 }
        let total = lens.reduce(0, +)
        guard b.count >= off + total else { return nil }
        var frames = [Data]()
        for L in lens { frames.append(Data(b[off ..< off + L])); off += L }
        return (seq, frames)
    }
}

// Receiver-side gap filler. Feed it every parsed packet; it returns the Opus
// frames to decode+play IN ORDER, reconstructing up to (count-1) CONSECUTIVE lost
// frames from the redundant copies the newest packet carries. Duplicates and late
// (reordered) packets return [] so nothing plays twice or out of order. seq is a
// rolling u8, so distances wrap at 256.
struct AudioREDReceiver {
    private var lastSeq = -1

    // A 1-byte seq can't tell a large FORWARD jump (a long outage) from a small
    // BACKWARD step (a reorder): a 130-packet gap and a 126-late packet both read
    // as gap==130. RTP (RFC 3550) resolves this with a narrow misorder window and
    // treats anything past it as forward progress / a sender resync. Without it, a
    // >128-packet (~2.5s) outage was misread as reorder and EVERY packet after it
    // was dropped until the u8 seq lapped back to lastSeq+1 — a ~5s audio blackout.
    private static let misorderWindow = 16   // tolerate reorders up to 16 packets (~320ms at 50fps)

    // frames are newest-first: frames[k] is the sender's frame (seq - k).
    mutating func receive(seq: UInt8, frames: [Data]) -> [Data] {
        guard !frames.isEmpty else { return [] }
        let s = Int(seq)
        if lastSeq < 0 { lastSeq = s; return [frames[0]] }   // first packet of the call
        let gap = (s - lastSeq + 256) % 256
        if gap == 0 { return [] }                            // exact duplicate
        if gap >= 256 - Self.misorderWindow { return [] }    // small backward step = genuine reorder, ignore
        // Forward progress. `gap` frames are missing in (lastSeq, s]; the packet supplies
        // the newest `count`. Emit the newest min(gap, count) of them, oldest-first, so up
        // to count-1 consecutive losses are filled and older gaps are simply skipped. Using
        // `gap` (not raw s/lastSeq) keeps this correct across the u8 wrap (s can be < lastSeq).
        lastSeq = s
        let m = min(gap, frames.count)
        var out = [Data]()
        for k in stride(from: m - 1, through: 0, by: -1) { out.append(frames[k]) }
        return out
    }
}
