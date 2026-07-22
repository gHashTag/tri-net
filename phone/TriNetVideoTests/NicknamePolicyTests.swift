import CryptoKit
import XCTest
@testable import TriNetVideo

final class NicknamePolicyTests: XCTestCase {
    func testNormalizationAndShape() {
        XCTAssertEqual(NicknamePolicy.normalize("  Alice_NET  "), "alice_net")
        XCTAssertNil(NicknamePolicy.validationError("alice_27"))
        XCTAssertNotNil(NicknamePolicy.validationError("27alice"))
        XCTAssertNotNil(NicknamePolicy.validationError("alice-net"))
        XCTAssertNotNil(NicknamePolicy.validationError("al"))
    }

    func testNearCopyDetection() {
        XCTAssertTrue(NicknamePolicy.isConfusing("alice", with: "alice"))
        XCTAssertTrue(NicknamePolicy.isConfusing("alice", with: "alixe"))
        XCTAssertTrue(NicknamePolicy.isConfusing("alice", with: "alice12"))
        XCTAssertFalse(NicknamePolicy.isConfusing("alice", with: "bravo"))
    }

    func testSuggestionsAreValidAndDistinct() {
        let suggestions = NicknamePolicy.suggestions(
            for: "alice",
            excluding: ["alice", "alixe"],
            seed: "device-27"
        )
        XCTAssertEqual(suggestions.count, 3)
        XCTAssertEqual(Set(suggestions).count, 3)
        XCTAssertTrue(suggestions.allSatisfy { NicknamePolicy.validationError($0) == nil })
        XCTAssertTrue(suggestions.allSatisfy { !NicknamePolicy.isConfusing($0, with: "alice") })
    }

    func testFingerprintIsDerivedFromPublicKey() {
        let publicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let encoded = publicKey.base64EncodedString()
        let expected = SHA256.hash(data: publicKey).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()

        XCTAssertEqual(DeviceIdentityStore.fingerprint(for: encoded), expected)
        XCTAssertNil(DeviceIdentityStore.fingerprint(for: "not-base64"))
    }

    func testMeshInviteSignatureRejectsTampering() throws {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let publicKeyText = publicKey.base64EncodedString()
        let fingerprint = SHA256.hash(data: publicKey).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        let timestamp: Int64 = 100
        let payload = MeshCallSignaling.signedPayload(callID: "call-1",
                                                      nickname: "alice",
                                                      displayName: "Alice",
                                                      userID: "user-1",
                                                      deviceID: "device-1",
                                                      mediaPort: 7000,
                                                      timestamp: timestamp,
                                                      nonce: "nonce-1")
        let signature = try privateKey.signature(for: payload).derRepresentation.base64EncodedString()
        let invite = MeshCallInvite(version: 1,
                                    callID: "call-1",
                                    nickname: "alice",
                                    displayName: "Alice",
                                    userID: "user-1",
                                    deviceID: "device-1",
                                    publicKey: publicKeyText,
                                    keyFingerprint: fingerprint,
                                    mediaPort: 7000,
                                    timestamp: timestamp,
                                    nonce: "nonce-1",
                                    signature: signature)
        XCTAssertTrue(MeshCallSignaling.signatureIsValid(invite))

        let tampered = MeshCallInvite(version: invite.version,
                                      callID: invite.callID,
                                      nickname: "mallory",
                                      displayName: invite.displayName,
                                      userID: invite.userID,
                                      deviceID: invite.deviceID,
                                      publicKey: invite.publicKey,
                                      keyFingerprint: invite.keyFingerprint,
                                      mediaPort: invite.mediaPort,
                                      timestamp: invite.timestamp,
                                      nonce: invite.nonce,
                                      signature: invite.signature)
        XCTAssertFalse(MeshCallSignaling.signatureIsValid(tampered))
    }
}
