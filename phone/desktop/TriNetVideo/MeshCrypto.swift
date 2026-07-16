// MeshCrypto.swift — forward-secret session crypto shared by both transports.
//
// Mirrors trios-mesh/src/crypto.rs: ephemeral X25519 -> HKDF session key ->
// ChaCha20-Poly1305 AEAD. The ephemeral exchange is authenticated by a
// pre-shared key (HMAC-SHA256 over the ephemeral public key), so a passive
// LAN attacker can't MITM without the PSK, and — crucially — a PSK leaked
// *later* does not decrypt recorded traffic, because the ephemeral private
// keys are never persisted (forward secrecy). This is the phone-side analog
// of trios-mesh's B'-wire authenticated handshake; the static PSK that v0.2
// used to encrypt data directly is now only a handshake authenticator.
//
// Wire (handshake): [0x54 0x48] + ephPub(32) + HMAC-SHA256(PSK, ephPub)(32) = 66B
// Wire (data): ChaChaPoly.combined sealed under the derived session key.
import Foundation
import CryptoKit

final class MeshCrypto {
    // PSK authenticates the ephemeral exchange (not the data). Swap for real
    // per-node identity keys when the mesh layer supplies them.
    private static let psk = SymmetricKey(data: SHA256.hash(data: Data("tri-net-psk-v1".utf8)))
    private static let hkdfSalt = Data("trios-mesh/v1/session".utf8)
    private static let hkdfInfo = Data("aead-key".utf8)
    static let handshakeMagic: [UInt8] = [0x54, 0x48] // "TH"

    private let ephPriv = Curve25519.KeyAgreement.PrivateKey()
    private var sessionKey: SymmetricKey?
    private var dropCount = 0

    var established: Bool { sessionKey != nil }

    // 66-byte authenticated handshake to send to the peer.
    func handshakePacket() -> Data {
        let pub = ephPriv.publicKey.rawRepresentation // 32B
        let mac = HMAC<SHA256>.authenticationCode(for: pub, using: MeshCrypto.psk)
        var d = Data(MeshCrypto.handshakeMagic)
        d.append(pub)
        d.append(Data(mac))
        return d
    }

    func isHandshake(_ d: Data) -> Bool {
        d.count == 66 && d[0] == MeshCrypto.handshakeMagic[0] && d[1] == MeshCrypto.handshakeMagic[1]
    }

    // Verify + install the session. Returns true if a (valid) handshake was consumed.
    @discardableResult
    func consumeHandshake(_ d: Data) -> Bool {
        guard isHandshake(d) else { return false }
        let pub = d.subdata(in: 2..<34)
        let mac = d.subdata(in: 34..<66)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: pub, using: MeshCrypto.psk) else {
            NSLog("TRINET: handshake HMAC invalid — rejected")
            return true // it was a handshake, just a bad one; don't treat as data
        }
        guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub),
              let shared = try? ephPriv.sharedSecretFromKeyAgreement(with: peerPub) else {
            return true
        }
        // X25519 is symmetric: both sides derive the same secret regardless of
        // who is initiator, so no role negotiation is needed.
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                 salt: MeshCrypto.hkdfSalt,
                                                 sharedInfo: MeshCrypto.hkdfInfo,
                                                 outputByteCount: 32)
        if sessionKey == nil { NSLog("TRINET: session established (forward-secret)") }
        sessionKey = key
        return true
    }

    func seal(_ plain: Data) -> Data? {
        guard let key = sessionKey,
              let box = try? ChaChaPoly.seal(plain, using: key) else { return nil }
        return box.combined
    }

    func unseal(_ wire: Data) -> Data? {
        guard let key = sessionKey else { return nil }
        guard let box = try? ChaChaPoly.SealedBox(combined: wire),
              let plain = try? ChaChaPoly.open(box, using: key) else {
            dropCount += 1
            if dropCount <= 3 || dropCount % 1000 == 0 {
                NSLog("TRINET: dropped unauthenticated datagram \(wire.count)B (#\(dropCount))")
            }
            return nil
        }
        return plain
    }
}
