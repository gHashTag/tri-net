// Fuzzes every UNTRUSTED-input parser in the NAT stack. These read bytes straight off the
// network: a STUN response from any server, a candidate offer from any rendezvous, a probe/ack
// from any peer. A malformed or malicious datagram must return nil, never crash (an out-of-bounds
// read is a remote DoS) and never hang. A deterministic PRNG (fixed seed) throws tens of thousands
// of random byte strings AND mutations of valid messages (flip / truncate / extend / splice) at
// each parser; the harness reaching its final line IS the proof that none of them trapped. Any
// out-of-bounds access would abort the process and fail the run.
//   swiftc MeshCrypto.swift HolePunch.swift IceSession.swift CandidateOffer.swift Rendezvous.swift StunClient.swift nat_fuzz.swift -o /tmp/fz && /tmp/fz
import Foundation
import CryptoKit

// xorshift64 — reproducible, no dependency on Date/random.
struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func byte() -> UInt8 { UInt8(next() & 0xFF) }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func randomData(maxLen: Int) -> Data { Data((0..<int(maxLen + 1)).map { _ in byte() }) }
    mutating func mutate(_ seed: [UInt8]) -> Data {
        var b = seed
        switch int(4) {
        case 0: for _ in 0...int(max(1, b.count / 3)) where !b.isEmpty { b[int(b.count)] = byte() }   // flip
        case 1: b = Array(b.prefix(int(b.count + 1)))                                                 // truncate
        case 2: for _ in 0...int(48) { b.append(byte()) }                                             // extend
        default: if !b.isEmpty { b[int(b.count)] = byte(); b.insert(byte(), at: int(b.count + 1)) }   // splice
        }
        return Data(b)
    }
}

// Fixed seed by default so verify.sh is reproducible; TRINET_FUZZ_SEED broadens the search ad-hoc.
let seed = ProcessInfo.processInfo.environment["TRINET_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x9E37_79B9_7F4A_7C15
var rng = RNG(s: seed)
let ITER = 20_000
let txid = Data((0..<12).map { _ in rng.byte() })
let room = "fuzz-room"

// valid seeds — mutations near a valid structure hit boundary bugs that pure noise misses
let stunSeed: [UInt8] = [0x01, 0x01, 0x00, 0x0c, 0x21, 0x12, 0xa4, 0x42] + [UInt8](txid) + [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43]
let probeSeed = [UInt8](HolePunch.probePacket(txid: 0x1122_3344_5566_7788))
let iceSeed = [UInt8](Ice.encode([Ice.Candidate(ip: "192.168.1.9", port: 5000, kind: .host),
                                  Ice.Candidate(ip: "203.0.113.9", port: 61000, kind: .srflx)]))
let offerSeed = [UInt8](CandidateOffer.make(candidates: [Ice.Candidate(ip: "10.0.0.1", port: 7000, kind: .host)],
                                            tiebreaker: 42, room: room, ttlMs: 30_000))
let rzPubSeed = [UInt8](Rendezvous.encodePublish(selfTag: 7, roomHash: Rendezvous.roomHash(room), offer: Data(offerSeed)))
let rzGetSeed = [UInt8](Rendezvous.encodeGet(selfTag: 7, roomHash: Rendezvous.roomHash(room)))

// each entry: a name, and a closure that parses one input (return true if ACCEPTED, for stats)
let parsers: [(String, [UInt8], (Data) -> Bool)] = [
    ("Stun.parseBindingResponse", stunSeed, { Stun.parseBindingResponse($0, transactionID: txid) != nil }),
    ("HolePunch.probeTxid",        probeSeed, { HolePunch.probeTxid($0) != nil }),
    ("HolePunch.ackTxid",          probeSeed, { HolePunch.ackTxid($0) != nil }),
    ("Ice.decode",                 iceSeed,   { Ice.decode($0) != nil }),
    ("CandidateOffer.open",        offerSeed, { CandidateOffer.open($0, room: room) != nil }),
    ("Rendezvous.parsePublish",    rzPubSeed, { Rendezvous.parsePublish($0) != nil }),
    ("Rendezvous.parseGet",        rzGetSeed, { Rendezvous.parseGet($0) != nil }),
    ("Rendezvous.parseResponse",   [0x03] + offerSeed, { Rendezvous.parseResponse($0) != nil }),
]

var totalInputs = 0
for (name, seed, parse) in parsers {
    var accepted = 0
    for i in 0..<ITER {
        // alternate pure noise and structured mutation
        let input = (i & 1 == 0) ? rng.randomData(maxLen: 600) : rng.mutate(seed)
        if parse(input) { accepted += 1 }
        totalInputs += 1
    }
    print("PASS  \(name): \(ITER) inputs, no crash (\(accepted) parsed as valid)")
}

print("\nALL PASS  (\(totalInputs) untrusted inputs across \(parsers.count) parsers, zero crashes)")
