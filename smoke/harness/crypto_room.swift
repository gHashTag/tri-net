// Verifies room-bound auth in the ACTUAL MeshCrypto.swift.
//   swiftc MeshCrypto.swift crypto_room_main.swift -o /tmp/cr && /tmp/cr
// Construct with an EXPLICIT ephemeral identity, never bare MeshCrypto(identity: Curve25519.Signing.PrivateKey()): the default
// initializer loads the device key from the Keychain, and a freshly-built unsigned binary
// is not in the item's ACL, so SecItemCopyMatching blocks on a GUI SecurityAgent prompt
// forever in a headless run. Room auth is orthogonal to identity, so this weakens nothing.
import Foundation
import CryptoKit

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

// Two peers exchange handshakes; returns whether BOTH installed a session.
func handshakeEstablishes(roomA: String, roomB: String) -> Bool {
    let a = MeshCrypto(identity: Curve25519.Signing.PrivateKey()); a.room = roomA
    let b = MeshCrypto(identity: Curve25519.Signing.PrivateKey()); b.room = roomB
    let pa = a.handshakePacket(), pb = b.handshakePacket()
    a.consumeHandshake(pb)
    b.consumeHandshake(pa)
    return a.established && b.established
}

print("== handshake auth is bound to the room secret ==")
check(handshakeEstablishes(roomA: "OFFICE", roomB: "OFFICE"), "same room -> session established")
check(!handshakeEstablishes(roomA: "OFFICE", roomB: "HOME"), "different room -> NO session (HMAC rejected)")
check(!handshakeEstablishes(roomA: "OFFICE", roomB: ""),     "room vs open-lobby -> NO session")
check(handshakeEstablishes(roomA: "", roomB: ""),            "empty room both -> session (open lobby)")

print("\n== round-trip seal/open works once a same-room session is up ==")
do {
    let a = MeshCrypto(identity: Curve25519.Signing.PrivateKey()); a.room = "TEAM"; let b = MeshCrypto(identity: Curve25519.Signing.PrivateKey()); b.room = "TEAM"
    a.consumeHandshake(b.handshakePacket()); b.consumeHandshake(a.handshakePacket())
    let msg = Data("hello mesh".utf8)
    let sealed = a.seal(msg)
    check(sealed != nil && b.unseal(sealed!) == msg, "A seals -> B opens the same bytes")
}

print("\n== BACKWARD COMPAT: empty room reproduces the legacy keys BIT-FOR-BIT ==")
let psk = SymmetricKey(data: SHA256.hash(data: Data("tri-net-psk-v1".utf8)))
// legacy handshake key was the PSK directly:
do {
    let pub = Data((0..<32).map { UInt8($0) })
    let legacy = HMAC<SHA256>.authenticationCode(for: pub, using: psk)
    let now = HMAC<SHA256>.authenticationCode(for: pub, using: MeshCrypto.handshakeAuthKey(room: ""))
    check(Data(legacy) == Data(now), "handshakeAuthKey(\"\") == legacy PSK key")
    check(Data(HMAC<SHA256>.authenticationCode(for: pub, using: MeshCrypto.handshakeAuthKey(room: "X"))) != Data(legacy),
          "handshakeAuthKey(room) != legacy (room actually changes the key)")
}
// legacy invite key: HKDF(psk, salt="trios-mesh/v1/invite", info="invite-auth")
do {
    let legacy = SymmetricKey(data: HKDF<SHA256>.deriveKey(
        inputKeyMaterial: psk, salt: Data("trios-mesh/v1/invite".utf8),
        info: Data("invite-auth".utf8), outputByteCount: 32))
    let payload = Data("name\n1.2.3.4\n\n123".utf8)
    let lm = HMAC<SHA256>.authenticationCode(for: payload, using: legacy)
    let nm = HMAC<SHA256>.authenticationCode(for: payload, using: MeshCrypto.inviteAuthKey(room: ""))
    check(Data(lm) == Data(nm), "inviteAuthKey(\"\") == legacy invite key")
    check(Data(HMAC<SHA256>.authenticationCode(for: payload, using: MeshCrypto.inviteAuthKey(room: "OFFICE"))) != Data(lm),
          "inviteAuthKey(room) != legacy")
    check(Data(HMAC<SHA256>.authenticationCode(for: payload, using: MeshCrypto.inviteAuthKey(room: "A"))) !=
          Data(HMAC<SHA256>.authenticationCode(for: payload, using: MeshCrypto.inviteAuthKey(room: "B"))),
          "different rooms -> different invite MAC")
}
// legacy group key: HKDF(psk, salt="trios-mesh/v1/conference", info="group-aead")
do {
    let legacy = SymmetricKey(data: HKDF<SHA256>.deriveKey(
        inputKeyMaterial: psk, salt: Data("trios-mesh/v1/conference".utf8),
        info: Data("group-aead".utf8), outputByteCount: 32))
    let msg = Data("group frame".utf8)
    let sealed = try! ChaChaPoly.seal(msg, using: MeshCrypto.groupAuthKey(room: "")).combined
    let opened = try? ChaChaPoly.open(try! ChaChaPoly.SealedBox(combined: sealed), using: legacy)
    check(opened == msg, "groupAuthKey(\"\") == legacy conference key (legacy peer can still decrypt)")
    // a room-bound group key cannot be opened with the legacy key
    let sealedRoom = try! ChaChaPoly.seal(msg, using: MeshCrypto.groupAuthKey(room: "SECRET")).combined
    let openedRoom = try? ChaChaPoly.open(try! ChaChaPoly.SealedBox(combined: sealedRoom), using: legacy)
    check(openedRoom == nil, "room-bound group key is NOT decryptable with the legacy key")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
