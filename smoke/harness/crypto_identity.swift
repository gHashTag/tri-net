// Verifies identity signing + TOFU pinning + MITM detection in the real MeshCrypto.swift.
//   swiftc MeshCrypto.swift crypto_identity_main.swift -o /tmp/id && /tmp/id
import Foundation
import CryptoKit

UserDefaults.standard.removeObject(forKey: "trinetPeerPins")   // clean slate per run

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

func peer() -> MeshCrypto { MeshCrypto(identity: Curve25519.Signing.PrivateKey()) }

print("== handshake is 162B and carries a valid identity signature ==")
do {
    let a = peer()
    let hs = a.handshakePacket()
    check(hs.count == 162, "handshake is 162 bytes")
    check(a.isHandshake(hs), "recognized as a handshake")
    check(!a.isHandshake(hs.prefix(66)), "the old 66B format is NOT accepted")
}

print("== two identity-bearing peers establish + pin each other ==")
do {
    let a = peer(), b = peer()
    a.consumeHandshake(b.handshakePacket(), from: "10.0.0.2")
    b.consumeHandshake(a.handshakePacket(), from: "10.0.0.1")
    check(a.established && b.established, "both sessions up")
    check(a.peerIdentity == b.identityPub, "A pinned B's real identity")
    check(b.peerIdentity == a.identityPub, "B pinned A's real identity")
    check(!a.mitmDetected && !b.mitmDetected, "no MITM flagged")
}

print("== MITM: a changed identity at a pinned peer is refused ==")
do {
    let victimReceiver = peer()
    let honest = peer(), attacker = peer()
    victimReceiver.consumeHandshake(honest.handshakePacket(), from: "10.0.0.9")   // TOFU-pin honest
    check(victimReceiver.established && !victimReceiver.mitmDetected, "first (honest) call pins + establishes")
    let v2 = peer()                                                               // simulate a later fresh session obj sharing the pin store
    v2.consumeHandshake(attacker.handshakePacket(), from: "10.0.0.9")             // attacker at the SAME peer IP
    check(v2.mitmDetected, "different identity at pinned IP -> MITM detected")
    check(!v2.established, "MITM session refused")
    _ = honest
}

print("== a tampered signature / wrong room is rejected ==")
do {
    let a = peer(), b = peer()
    var hs = b.handshakePacket()
    hs[100] ^= 0xFF                                   // flip a byte inside the signature
    a.consumeHandshake(hs, from: "10.0.1.1")
    check(!a.established, "bad signature -> no session")
    let c = peer(); c.room = "OFFICE"; let d = peer(); d.room = "HOME"
    c.consumeHandshake(d.handshakePacket(), from: "10.0.1.2")
    check(!c.established, "wrong room -> no session (room gate still holds)")
}

print("== safety number is symmetric, deterministic, and 11 digits ==")
do {
    let a = peer(), b = peer()
    let sab = MeshCrypto.safetyNumber(a.identityPub, b.identityPub)
    let sba = MeshCrypto.safetyNumber(b.identityPub, a.identityPub)
    check(sab == sba, "safety number is order-independent (both parties see the same)")
    check(sab.count == 11 && sab.allSatisfy { $0.isNumber }, "11-digit numeric code")
    let cKey = peer()
    check(MeshCrypto.safetyNumber(a.identityPub, cKey.identityPub) != sab, "different peer -> different code")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
UserDefaults.standard.removeObject(forKey: "trinetPeerPins")
exit(fails == 0 ? 0 : 1)
