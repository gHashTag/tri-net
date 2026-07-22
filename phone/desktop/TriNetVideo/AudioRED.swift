// AudioRED.swift — application-level audio redundancy (RED, RFC 2198-style).
//
// Opus over UDP had NO loss protection: one dropped 20ms packet was an audible
// gap. Video carries XOR-FEC parity; audio carried nothing, so on a lossy link
// the picture survived while the voice — the part of a call that actually
// matters — broke up. AVAudioConverter (AudioToolbox) exposes neither Opus
// in-band FEC nor PLC, so the fix lives one layer up, in the packet framing.
//
// Each packet carries the CURRENT Opus frame AND a copy of the PREVIOUS one. If
// packet N is lost, packet N+1 still contains frame N, so a single isolated loss
// is fully reconstructed. Cost is ~2x the (tiny) audio bitrate — ~25 -> ~50 kbps,
// still one datagram, far under the fragment budget. Both ends must run this
// (the [0xFD 0xC0] payload layout changes); it rolls out like Opus itself did.
//
// Payload AFTER the [0xFD 0xC0] magic:  [seq:1][curLen:2 LE][cur bytes][prev bytes]
//
// This file is PURE (Foundation only) so the standalone verification harness can
// compile the exact production framing — no re-implementation that could drift.
import Foundation

enum AudioRED {
    // Wrap one Opus frame plus the previous for redundancy. `prev` may be empty
    // (the first packet of a call) — the receiver treats an empty prev as "no
    // redundancy available", never as a zero-length frame.
    static func pack(seq: UInt8, cur: Data, prev: Data) -> Data {
        var b = [UInt8]()
        b.reserveCapacity(3 + cur.count + prev.count)
        b.append(seq)
        let n = min(cur.count, 0xFFFF)
        b.append(UInt8(n & 0xFF)); b.append(UInt8((n >> 8) & 0xFF))
        b.append(contentsOf: cur)
        b.append(contentsOf: prev)
        return Data(b)
    }

    // Split back into (seq, cur, prev). nil on a malformed header/length so a
    // corrupt datagram is dropped, never decoded as garbage.
    static func parse(_ d: Data) -> (seq: UInt8, cur: Data, prev: Data)? {
        let b = [UInt8](d)
        guard b.count >= 3 else { return nil }
        let seq = b[0]
        let curLen = Int(b[1]) | (Int(b[2]) << 8)
        guard b.count >= 3 + curLen else { return nil }
        let cur = Data(b[3 ..< 3 + curLen])
        let prev = Data(b[(3 + curLen) ..< b.count])
        return (seq, cur, prev)
    }
}

// Receiver-side gap detector. Feed it every parsed packet; it returns the Opus
// frames to decode+play IN ORDER, reconstructing one isolated loss from the
// redundant copy. Duplicates and late (reordered) packets return [] so nothing
// is played twice or out of order. seq is a rolling u8, so distances wrap at 256.
struct AudioREDReceiver {
    private var lastSeq = -1

    mutating func receive(seq: UInt8, cur: Data, prev: Data) -> [Data] {
        let s = Int(seq)
        if lastSeq < 0 { lastSeq = s; return [cur] }   // first packet of the call
        let gap = (s - lastSeq + 256) % 256
        switch gap {
        case 0:                          // exact duplicate (the sender re-sends INVITEs etc.)
            return []
        case 1:                          // in order
            lastSeq = s; return [cur]
        case 2...128:                    // one-or-more lost; RED reconstructs only the most recent
            lastSeq = s
            return prev.isEmpty ? [cur] : [prev, cur]
        default:                         // gap > 128 => s is behind us: a late/reordered old packet
            return []
        }
    }
}
