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
    private var replayCount = 0

    // ANTI-REPLAY. ChaChaPoly.seal picks a RANDOM 12-byte nonce per call, so a nonce is
    // seen at most once for legitimate traffic — a REPEAT is a captured datagram replayed
    // (e.g. to duplicate a chat message or nudge the rate controller). We can't run a
    // counter window (there is no application counter in the frame), but a bounded set of
    // recently-seen nonces gives the same bounded-window guarantee with ZERO false drops:
    // a legit nonce is inserted once and never re-seen. Called only on the rx queue.
    private var seenNonces = Set<Data>()
    private var nonceRing: [Data] = []
    private static let replayWindow = 8192   // ~a few seconds at video rates

    // Returns true if the nonce is fresh (and records it); false if it's a replay.
    func acceptNonce(_ nonce: Data) -> Bool {
        let n = Data(nonce)
        if seenNonces.contains(n) { return false }
        seenNonces.insert(n)
        nonceRing.append(n)
        if nonceRing.count > MeshCrypto.replayWindow { seenNonces.remove(nonceRing.removeFirst()) }
        return true
    }

    // Shared room passphrase. The hardcoded PSK ships in every binary, so it authenticates
    // NOTHING on its own — anyone with the app can complete a handshake or forge an INVITE.
    // Mixing a room secret in means an attacker must ALSO know the room to MITM/forge. Empty
    // room keeps the legacy PSK-only key BIT-FOR-BIT, so open-lobby calls are unaffected and
    // an old build still interops. The transport sets this from PeerDiscovery.myRoom.
    var room = ""

    // ---- persistent device IDENTITY (Ed25519) + trust-on-first-use pinning ----
    // Room-binding says WHO may connect (knows the room); it does NOT stop an active
    // MITM who also knows the room from substituting their own ephemeral key. A stable
    // per-device signing key does: the handshake carries idPub + a signature over the
    // ephemeral key, so only the identity holder can authorize a session. On first
    // contact we PIN a peer's idPub; a later handshake with a different idPub at the
    // same peer flags a MITM. Users compare the safetyNumber out-of-band to catch a
    // first-call MITM. NOTE: the private key is stored in UserDefaults (base64) — real
    // hardening puts it in the Keychain; it still never leaves the device.
    let identityPriv: Curve25519.Signing.PrivateKey
    var identityPub: Data { identityPriv.publicKey.rawRepresentation }
    private(set) var peerIdentity: Data?     // the pinned/observed peer idPub for this session
    private(set) var mitmDetected = false     // peer's idPub changed vs a prior pin

    init(identity: Curve25519.Signing.PrivateKey = MeshCrypto.deviceIdentity()) {
        self.identityPriv = identity
    }

    // Load (or first-run generate + persist) this device's long-term signing key.
    static func deviceIdentity() -> Curve25519.Signing.PrivateKey {
        let k = "trinetIdentityKeyV1"
        if let b64 = UserDefaults.standard.string(forKey: k), let raw = Data(base64Encoded: b64),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.Signing.PrivateKey()
        UserDefaults.standard.set(key.rawRepresentation.base64EncodedString(), forKey: k)
        return key
    }

    // Persisted TOFU pins: peer IP -> idPub. In-memory mirror for speed.
    private var pins: [String: Data] = (UserDefaults.standard.dictionary(forKey: "trinetPeerPins") as? [String: String] ?? [:])
        .compactMapValues { Data(base64Encoded: $0) }
    private func pin(_ ip: String, _ idPub: Data) {
        pins[ip] = idPub
        UserDefaults.standard.set(pins.mapValues { $0.base64EncodedString() }, forKey: "trinetPeerPins")
    }

    // Short digit string over BOTH identity keys (order-independent) for out-of-band checks.
    static func safetyNumber(_ a: Data, _ b: Data) -> String {
        let pair = a.lexicographicallyPrecedes(b) ? a + b : b + a
        let h = SHA256.hash(data: pair)
        let n = h.prefix(5).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return String(format: "%011llu", n % 100_000_000_000)   // 11 digits, grouped by the UI
    }

    static func handshakeAuthKey(room: String) -> SymmetricKey {
        room.isEmpty ? psk : SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: psk, salt: Data("trios-mesh/v1/room".utf8),
            info: Data(room.utf8), outputByteCount: 32))
    }

    // INVITE authenticator key. Empty room reproduces the legacy key exactly.
    static func inviteAuthKey(room: String) -> SymmetricKey {
        SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: psk,
            salt: room.isEmpty ? Data("trios-mesh/v1/invite".utf8) : Data(("trios-mesh/v1/invite/" + room).utf8),
            info: Data("invite-auth".utf8), outputByteCount: 32))
    }

    // Group-conference AEAD key (there is no pairwise handshake in group mode, so the
    // static conference key IS the confidentiality boundary). Empty room reproduces the
    // legacy key exactly; a set room means only same-room peers can decrypt the call.
    static func groupAuthKey(room: String) -> SymmetricKey {
        SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: psk,
            salt: room.isEmpty ? Data("trios-mesh/v1/conference".utf8) : Data(("trios-mesh/v1/conference/" + room).utf8),
            info: Data("group-aead".utf8), outputByteCount: 32))
    }

    var established: Bool { sessionKey != nil }

    // 162-byte handshake: [TH][ephPub 32][room-HMAC 32][idPub 32][Ed25519 sig(ephPub) 64].
    func handshakePacket() -> Data {
        let pub = ephPriv.publicKey.rawRepresentation // 32B
        let mac = HMAC<SHA256>.authenticationCode(for: pub, using: MeshCrypto.handshakeAuthKey(room: room))
        var d = Data(MeshCrypto.handshakeMagic)
        d.append(pub)
        d.append(Data(mac))
        d.append(identityPub)                                                     // who I am
        d.append((try? identityPriv.signature(for: pub)) ?? Data(count: 64))      // I authorize this ephemeral key
        return d
    }

    func isHandshake(_ d: Data) -> Bool {
        d.count == 162 && d[0] == MeshCrypto.handshakeMagic[0] && d[1] == MeshCrypto.handshakeMagic[1]
    }

    // Verify + install the session. Returns true if a (valid) handshake was consumed.
    @discardableResult
    func consumeHandshake(_ d: Data, from peerIP: String = "") -> Bool {
        guard isHandshake(d) else { return false }
        let pub = d.subdata(in: 2..<34)
        let mac = d.subdata(in: 34..<66)
        let idPub = d.subdata(in: 66..<98)
        let sig = d.subdata(in: 98..<162)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: pub, using: MeshCrypto.handshakeAuthKey(room: room)) else {
            NSLog("TRINET: handshake HMAC invalid — wrong room secret or not a TRI-NET peer — rejected")
            return true // it was a handshake, just a bad one; don't treat as data
        }
        // IDENTITY: the signature proves the idPub holder authorized THIS ephemeral key.
        guard let idKey = try? Curve25519.Signing.PublicKey(rawRepresentation: idPub),
              idKey.isValidSignature(sig, for: pub) else {
            NSLog("TRINET: handshake identity signature invalid — rejected")
            return true
        }
        // TOFU: a different idPub at a peer we've pinned is a MITM. Refuse the session.
        if let pinned = pins[peerIP], pinned != idPub {
            mitmDetected = true
            NSLog("TRINET: MITM — peer %@ identity CHANGED from the pinned key; session refused", peerIP)
            return true
        }
        if pins[peerIP] == nil, !peerIP.isEmpty { pin(peerIP, idPub) }   // trust on first use
        peerIdentity = idPub
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
        // Authentic, but reject a REPLAY (the nonce is the first 12 bytes of ChaChaPoly.combined).
        guard acceptNonce(wire.prefix(12)) else {
            replayCount += 1
            if replayCount <= 3 || replayCount % 1000 == 0 { NSLog("TRINET: dropped REPLAYED datagram (#\(replayCount))") }
            return nil
        }
        return plain
    }
}
