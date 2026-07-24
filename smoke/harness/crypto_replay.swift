// Verifies anti-replay in the ACTUAL MeshCrypto.swift.
//   swiftc MeshCrypto.swift crypto_replay_main.swift -o /tmp/rp && /tmp/rp
// Construct with an EXPLICIT ephemeral identity, never bare MeshCrypto(identity: Curve25519.Signing.PrivateKey()): the default
// initializer loads the device key from the Keychain, and a freshly-built unsigned binary
// is not in the item's ACL, so SecItemCopyMatching blocks on a GUI SecurityAgent prompt
// forever in a headless run. Replay is orthogonal to identity, so this weakens nothing.
import Foundation
import CryptoKit

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

// A live session between two peers (same room).
func pair() -> (MeshCrypto, MeshCrypto) {
    let a = MeshCrypto(identity: Curve25519.Signing.PrivateKey()); let b = MeshCrypto(identity: Curve25519.Signing.PrivateKey())
    a.consumeHandshake(b.handshakePacket()); b.consumeHandshake(a.handshakePacket())
    return (a, b)
}

print("== a replayed datagram is rejected; fresh ones pass ==")
do {
    let (a, b) = pair()
    let w1 = a.seal(Data("chat: hello".utf8))!
    check(b.unseal(w1) == Data("chat: hello".utf8), "first delivery decodes")
    check(b.unseal(w1) == nil, "SAME datagram replayed -> rejected")
    check(b.unseal(w1) == nil, "replayed again -> still rejected")
    let w2 = a.seal(Data("chat: world".utf8))!
    check(b.unseal(w2) == Data("chat: world".utf8), "a different datagram still passes")
}

print("== no false positives across a long distinct stream ==")
do {
    let (a, b) = pair()
    var ok = true
    for i in 0..<5000 {
        let w = a.seal(Data("frame \(i)".utf8))!
        if b.unseal(w) != Data("frame \(i)".utf8) { ok = false; break }
    }
    check(ok, "5000 distinct sealed frames all delivered (each nonce unique -> no false drop)")
}

print("== acceptNonce is a pure fresh/replay predicate ==")
do {
    let c = MeshCrypto(identity: Curve25519.Signing.PrivateKey())
    let n = Data((0..<12).map { UInt8($0) })
    check(c.acceptNonce(n) == true, "novel nonce -> fresh")
    check(c.acceptNonce(n) == false, "same nonce -> replay")
    check(c.acceptNonce(Data((0..<12).map { UInt8($0 + 1) })) == true, "another novel nonce -> fresh")
}

print("== HONEST bound: the window is finite; a replay after eviction succeeds ==")
do {
    let c = MeshCrypto(identity: Curve25519.Signing.PrivateKey())
    let victim = Data((100..<112).map { UInt8($0) })
    check(c.acceptNonce(victim) == true, "victim nonce recorded")
    check(c.acceptNonce(victim) == false, "immediate replay caught")
    for i in 0..<9000 { _ = c.acceptNonce(Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)] + (0..<10).map { UInt8($0) })) }
    check(c.acceptNonce(victim) == true, "after > window fresh nonces, the victim is EVICTED -> replay no longer caught (documented bound)")
}

print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
