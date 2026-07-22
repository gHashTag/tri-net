// Verifies Keychain-backed identity storage + UserDefaults->Keychain migration in the
// real MeshCrypto.swift.  swiftc MeshCrypto.swift keychain_main.swift -o /tmp/kc && /tmp/kc
import Foundation
import CryptoKit
import Security

func wipe() {
    SecItemDelete([kSecClass: kSecClassGenericPassword,
                   kSecAttrService: MeshCrypto.kcService, kSecAttrAccount: MeshCrypto.kcAccount] as CFDictionary)
    UserDefaults.standard.removeObject(forKey: "trinetIdentityKeyV1")
}

var fails = 0
func check(_ c: Bool, _ l: String) { print("\(c ? "PASS" : "FAIL")  \(l)"); if !c { fails += 1 } }

wipe()

print("== first run generates + stores in the Keychain; not in UserDefaults ==")
let k1 = MeshCrypto.deviceIdentity()
check(MeshCrypto.keychainLoad() == k1.rawRepresentation, "the key is now in the Keychain")
check(UserDefaults.standard.string(forKey: "trinetIdentityKeyV1") == nil, "the key is NOT written to the plist")

print("== the identity PERSISTS: a second load returns the same key ==")
let k2 = MeshCrypto.deviceIdentity()
check(k1.rawRepresentation == k2.rawRepresentation, "deviceIdentity() is stable across calls (loaded from Keychain)")

print("== raw Keychain save/load round-trip ==")
wipe()
let blob = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })
check(MeshCrypto.keychainSave(blob), "SecItemAdd succeeds")
check(MeshCrypto.keychainLoad() == blob, "SecItemCopyMatching returns the same bytes")

print("== MIGRATION: a legacy UserDefaults key moves to the Keychain and the plist is scrubbed ==")
wipe()
let legacy = Curve25519.Signing.PrivateKey()
UserDefaults.standard.set(legacy.rawRepresentation.base64EncodedString(), forKey: "trinetIdentityKeyV1")
let migrated = MeshCrypto.deviceIdentity()
check(migrated.rawRepresentation == legacy.rawRepresentation, "the SAME identity is returned (no new key -> pins stay valid)")
check(MeshCrypto.keychainLoad() == legacy.rawRepresentation, "it now lives in the Keychain")
check(UserDefaults.standard.string(forKey: "trinetIdentityKeyV1") == nil, "the plaintext plist copy is removed")

wipe()
print("\n\(fails == 0 ? "ALL PASS" : "\(fails) FAILURE(S)")")
exit(fails == 0 ? 0 : 1)
