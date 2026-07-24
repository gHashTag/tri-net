// Verifies the confidential candidate exchange in the ACTUAL CandidateOffer.swift (+ Ice +
// MeshCrypto). Only static room-key derivation is used, so no MeshCrypto() is constructed and
// the Keychain is never touched (the #41 hang cannot recur here). The clock is passed in, so
// expiry is deterministic.
//   swiftc MeshCrypto.swift HolePunch.swift IceSession.swift CandidateOffer.swift candidate_offer.swift -o /tmp/co && /tmp/co
import Foundation
import CryptoKit

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

let cands = [Ice.Candidate(ip: "192.168.1.50", port: 5000, kind: .host),
             Ice.Candidate(ip: "203.0.113.50", port: 61000, kind: .srflx)]
let t0 = Date(timeIntervalSince1970: 1_700_000_000)          // fixed clock

print("== honest round-trip under the same room ==")
do {
    let offer = CandidateOffer.make(candidates: cands, tiebreaker: 0xAABB_CCDD, room: "team-alpha", ttlMs: 30_000, now: t0)
    let got = CandidateOffer.open(offer, room: "team-alpha", now: t0.addingTimeInterval(5))
    check(got?.candidates == cands, "the peer's candidate list is recovered intact")
    check(got?.tiebreaker == 0xAABB_CCDD, "the ICE tiebreaker is recovered")
    check(offer.count > 17, "the offer is sealed (nonce+ciphertext+tag), not plaintext")
}

print("== a rendezvous without the room passphrase can neither read nor forge ==")
do {
    let offer = CandidateOffer.make(candidates: cands, tiebreaker: 1, room: "team-alpha", ttlMs: 30_000, now: t0)
    check(CandidateOffer.open(offer, room: "team-beta", now: t0) == nil, "a different room passphrase -> nil (cannot read)")
    var tampered = [UInt8](offer); tampered[tampered.count - 1] ^= 0xFF
    check(CandidateOffer.open(Data(tampered), room: "team-alpha", now: t0) == nil, "flipped auth-tag byte -> nil (cannot forge a candidate)")
    // the offer key is domain-separated from the raw invite key: opening under it must fail
    let underInviteKey = { () -> Bool in
        guard let box = try? ChaChaPoly.SealedBox(combined: offer),
              let _ = try? ChaChaPoly.open(box, using: MeshCrypto.inviteAuthKey(room: "team-alpha")) else { return false }
        return true
    }()
    check(!underInviteKey, "the offer does NOT open under the raw invite key (domain separation holds)")
}

print("== a captured offer cannot be replayed after it expires ==")
do {
    let offer = CandidateOffer.make(candidates: cands, tiebreaker: 1, room: "r", ttlMs: 10_000, now: t0)
    check(CandidateOffer.open(offer, room: "r", now: t0.addingTimeInterval(9)) != nil, "within TTL -> accepted")
    check(CandidateOffer.open(offer, room: "r", now: t0.addingTimeInterval(11)) == nil, "past TTL -> rejected (stale, un-replayable)")
}

print("== ICE role resolves deterministically and oppositely for the two peers ==")
do {
    check(CandidateOffer.isControlling(mine: 100, peer: 50), "higher tiebreaker -> controlling")
    check(!CandidateOffer.isControlling(mine: 50, peer: 100), "lower tiebreaker -> controlled")
    check(CandidateOffer.isControlling(mine: 100, peer: 50) != CandidateOffer.isControlling(mine: 50, peer: 100),
          "the two peers pick OPPOSITE roles (no double-controlling)")
}

print("== garbage / truncated input never crashes ==")
do {
    check(CandidateOffer.open(Data(), room: "r", now: t0) == nil, "empty -> nil")
    check(CandidateOffer.open(Data([1, 2, 3, 4, 5]), room: "r", now: t0) == nil, "junk -> nil")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
