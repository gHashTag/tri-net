// CandidateOffer.swift — a confidential, authenticated, time-bounded candidate exchange.
// The three NAT bricks (STUN #42, punch #43, ICE session #44) all assume the two peers
// already hold each other's candidate lists. Whatever rendezvous carries that list — a relay,
// the mesh, a pasted code — MUST NOT be trusted to read or forge it: an attacker who injects
// candidates redirects the call to a machine it controls (a classic ICE candidate-injection /
// call hijack; WebRTC blocks it with signed SDP + a DTLS fingerprint). We seal the offer under
// a key derivable ONLY from the room passphrase (a rendezvous host does not have it), stamp it
// with an expiry so a captured offer cannot be replayed later, and resolve the ICE
// controlling/controlled role by tiebreaker.
//
// Pure; reuses MeshCrypto.inviteAuthKey (room-derived) and Ice candidate serialization. The
// offer key is domain-separated from the invite key by HKDF so a candidate offer and an invite
// can never be cross-interpreted even though both are room-authenticated.
import Foundation
import CryptoKit

enum CandidateOffer {
    static let version: UInt8 = 1

    // Domain-separated offer key: HKDF(invite-key) so it is cryptographically independent of
    // the invite path while still gated on the room passphrase.
    static func offerKey(room: String) -> SymmetricKey {
        SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: MeshCrypto.inviteAuthKey(room: room),
            salt: Data("trinet/candidate-offer/v1".utf8),
            info: Data(room.utf8), outputByteCount: 32))
    }

    // Sealed inner plaintext: [version:1][tiebreaker:8 BE][expiry unix-ms:8 BE][Ice list].
    static func make(candidates: [Ice.Candidate], tiebreaker: UInt64, room: String, ttlMs: Int, now: Date = Date()) -> Data {
        let expiry = UInt64((now.timeIntervalSince1970 * 1000).rounded()) + UInt64(ttlMs)
        var inner = Data([version])
        inner.append(contentsOf: be(tiebreaker))
        inner.append(contentsOf: be(expiry))
        inner.append(Ice.encode(candidates))
        return ((try? ChaChaPoly.seal(inner, using: offerKey(room: room)))?.combined) ?? Data()
    }

    struct Offer: Equatable { let candidates: [Ice.Candidate]; let tiebreaker: UInt64 }

    // nil if: wrong room passphrase, tampered ciphertext, bad version, expired, or a malformed
    // candidate list. Every rejection is silent-safe (no crash on any input).
    static func open(_ data: Data, room: String, now: Date = Date()) -> Offer? {
        guard let box = try? ChaChaPoly.SealedBox(combined: data),
              let inner = try? ChaChaPoly.open(box, using: offerKey(room: room)) else { return nil }
        let b = [UInt8](inner)
        guard b.count >= 17, b[0] == version else { return nil }
        let tiebreaker = u64(b[1..<9])
        let expiry = u64(b[9..<17])
        let nowMs = UInt64((now.timeIntervalSince1970 * 1000).rounded())
        guard expiry >= nowMs else { return nil }                     // stale: cannot be replayed later
        guard let cands = Ice.decode(Data(b[17...])) else { return nil }
        return Offer(candidates: cands, tiebreaker: tiebreaker)
    }

    // ICE role (RFC 8445 §6.1.1): the peer with the higher tiebreaker is controlling. 64-bit
    // random tiebreakers never tie in practice; resolve a tie deterministically anyway.
    static func isControlling(mine: UInt64, peer: UInt64) -> Bool { mine > peer }

    private static func be(_ x: UInt64) -> [UInt8] { (0..<8).map { UInt8((x >> (56 - 8 * $0)) & 0xFF) } }
    private static func u64(_ s: ArraySlice<UInt8>) -> UInt64 { s.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
}
