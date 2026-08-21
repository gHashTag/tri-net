import CryptoKit
import XCTest
@testable import TriNetVideo

final class NicknamePolicyTests: XCTestCase {
    private func meshTextFixture() -> (sender: DeviceIdentity,
                                       senderKey: P256.Signing.PrivateKey,
                                       recipient: DeviceIdentity,
                                       recipientKey: Curve25519.KeyAgreement.PrivateKey,
                                       contact: DirectoryContact) {
        let senderKey = P256.Signing.PrivateKey()
        let senderPublic = senderKey.publicKey.x963Representation
        let sender = DeviceIdentity(userID: "sender-user",
                                    deviceID: "sender-device",
                                    displayName: "Alice",
                                    nickname: "alice",
                                    signingPublicKey: senderPublic.base64EncodedString(),
                                    keyFingerprint: SHA256.hash(data: senderPublic).prefix(12).map {
                                        String(format: "%02x", $0)
                                    }.joined())
        let recipientSigningKey = P256.Signing.PrivateKey()
        let recipientPublic = recipientSigningKey.publicKey.x963Representation
        let recipient = DeviceIdentity(userID: "recipient-user",
                                       deviceID: "recipient-device",
                                       displayName: "Bob",
                                       nickname: "bob",
                                       signingPublicKey: recipientPublic.base64EncodedString(),
                                       keyFingerprint: SHA256.hash(data: recipientPublic).prefix(12).map {
                                           String(format: "%02x", $0)
                                       }.joined())
        let recipientKey = Curve25519.KeyAgreement.PrivateKey()
        let contact = DirectoryContact(userID: recipient.userID,
                                       deviceID: recipient.deviceID,
                                       nickname: "bob",
                                       displayName: "Bob",
                                       keyFingerprint: recipient.keyFingerprint,
                                       source: .mesh,
                                       online: true,
                                       meshAddress: "192.168.1.20",
                                       meshPort: MeshCallSignaling.port,
                                       signingPublicKey: recipient.signingPublicKey,
                                       textEncryptionPublicKey: recipientKey.publicKey.rawRepresentation
                                        .base64EncodedString())
        return (sender, senderKey, recipient, recipientKey, contact)
    }

    private func sealMeshText(_ text: String,
                              fixture: (sender: DeviceIdentity,
                                        senderKey: P256.Signing.PrivateKey,
                                        recipient: DeviceIdentity,
                                        recipientKey: Curve25519.KeyAgreement.PrivateKey,
                                        contact: DirectoryContact),
                              timestamp: Int64,
                              nonce: UUID = UUID()) -> Data? {
        MeshTextEnvelope.seal(text: text,
                              sender: fixture.sender,
                              recipient: fixture.contact,
                              timestamp: timestamp,
                              nonce: nonce,
                              sign: { payload in
                                  try fixture.senderKey.signature(for: payload).derRepresentation
                                    .base64EncodedString()
                              })
    }

    private func internetTextFixture() -> (sender: DeviceIdentity,
                                           senderKey: P256.Signing.PrivateKey,
                                           recipientKey: Curve25519.KeyAgreement.PrivateKey,
                                           recipient: InternetDirectMessageRecipientKey) {
        let senderKey = P256.Signing.PrivateKey()
        let senderPublicKey = senderKey.publicKey.x963Representation
        let sender = DeviceIdentity(
            userID: "sender-user",
            deviceID: "sender-device",
            displayName: "Alice",
            nickname: "alice",
            signingPublicKey: senderPublicKey.base64EncodedString(),
            keyFingerprint: SHA256.hash(data: senderPublicKey).prefix(12).map {
                String(format: "%02x", $0)
            }.joined())
        let recipientKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPublicKey = recipientKey.publicKey.rawRepresentation
        let recipient = InternetDirectMessageRecipientKey(
            deviceID: "recipient-device",
            publicKeyBase64: recipientPublicKey.base64EncodedString(),
            keyFingerprint: SHA256.hash(data: recipientPublicKey).prefix(12).map {
                String(format: "%02x", $0)
            }.joined())
        return (sender, senderKey, recipientKey, recipient)
    }

    private func backendDirectMessageSignaturePayload(
        senderUserID: String,
        senderDeviceID: String,
        recipientNickname: String,
        cryptoVersion: UInt8,
        recipientDeviceID: String,
        recipientKeyFingerprint: String,
        clientMessageID: String,
        ephemeralPublicKey: Data,
        nonce: Data,
        ciphertext: Data
    ) -> Data {
        func append(_ field: Data, to result: inout Data) {
            let length = UInt32(field.count)
            result.append(UInt8((length >> 24) & 0xff))
            result.append(UInt8((length >> 16) & 0xff))
            result.append(UInt8((length >> 8) & 0xff))
            result.append(UInt8(length & 0xff))
            result.append(field)
        }
        var result = Data("TRINET-DIRECT-MESSAGE-V1".utf8)
        for field in [Data(senderUserID.utf8),
                      Data(senderDeviceID.utf8),
                      Data(recipientNickname.utf8),
                      Data([cryptoVersion]),
                      Data(recipientDeviceID.utf8),
                      Data(recipientKeyFingerprint.utf8),
                      Data(clientMessageID.utf8),
                      ephemeralPublicKey,
                      nonce,
                      ciphertext] {
            append(field, to: &result)
        }
        return result
    }

    private func replacingInternetEnvelope(
        _ envelope: InternetDirectMessageSealedEnvelope,
        recipientDeviceID: String? = nil,
        recipientKeyFingerprint: String? = nil,
        ephemeralPublicKey: String? = nil,
        nonce: String? = nil,
        ciphertext: String? = nil,
        senderSignature: String? = nil,
        cryptoVersion: UInt8? = nil
    ) -> InternetDirectMessageSealedEnvelope {
        InternetDirectMessageSealedEnvelope(
            recipientDeviceID: recipientDeviceID ?? envelope.recipientDeviceID,
            recipientKeyFingerprint: recipientKeyFingerprint ?? envelope.recipientKeyFingerprint,
            ephemeralPublicKey: ephemeralPublicKey ?? envelope.ephemeralPublicKey,
            nonce: nonce ?? envelope.nonce,
            ciphertext: ciphertext ?? envelope.ciphertext,
            senderSignature: senderSignature ?? envelope.senderSignature,
            cryptoVersion: cryptoVersion ?? envelope.cryptoVersion)
    }

    private func data(_ haystack: Data, contains needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Data(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    func testInternetDirectMessageRoundTripMatchesBackendSignatureContract() throws {
        let fixture = internetTextFixture()
        let clientMessageID = "b3541665-3f5d-487b-9264-06af42d46210"
        let plaintext = InternetDirectMessagePlaintext(
            clientMessageID: clientMessageID,
            senderNickname: "Alice",
            recipientNickname: "BOB",
            text: "line one\nline two",
            createdAtMilliseconds: 1_800_000_000_123)
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let nonce = Data(0..<12)
        var capturedSignaturePayload: Data?
        let envelope = try InternetDirectMessageCrypto.seal(
            plaintext,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            recipient: fixture.recipient,
            ephemeralPrivateKey: ephemeralPrivateKey,
            nonceData: nonce,
            sign: { payload in
                capturedSignaturePayload = payload
                return try fixture.senderKey.signature(for: payload)
                    .derRepresentation.base64EncodedString()
            })

        let ciphertext = try XCTUnwrap(Data(base64Encoded: envelope.ciphertext))
        let expectedSignaturePayload = backendDirectMessageSignaturePayload(
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            recipientNickname: "bob",
            cryptoVersion: 1,
            recipientDeviceID: fixture.recipient.deviceID,
            recipientKeyFingerprint: fixture.recipient.keyFingerprint,
            clientMessageID: clientMessageID,
            ephemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
            nonce: nonce,
            ciphertext: ciphertext)
        XCTAssertEqual(capturedSignaturePayload, expectedSignaturePayload)
        XCTAssertEqual(envelope.cryptoVersion, 1)
        XCTAssertEqual(Data(base64Encoded: envelope.ephemeralPublicKey)?.count, 32)
        XCTAssertEqual(Data(base64Encoded: envelope.nonce)?.count, 12)
        XCTAssertLessThanOrEqual(ciphertext.count, InternetDirectMessageCrypto.maximumCiphertextBytes)
        XCTAssertFalse(data(ciphertext, contains: Data(plaintext.text.utf8)))

        let opened = try InternetDirectMessageCrypto.open(
            envelope,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            senderSigningPublicKey: fixture.sender.signingPublicKey,
            senderKeyFingerprint: fixture.sender.keyFingerprint,
            recipientDeviceID: fixture.recipient.deviceID,
            recipientPrivateKey: fixture.recipientKey,
            expectedClientMessageID: clientMessageID,
            expectedSenderNickname: "alice",
            expectedRecipientNickname: "bob")
        XCTAssertEqual(opened,
                       InternetDirectMessagePlaintext(
                        clientMessageID: clientMessageID,
                        senderNickname: "alice",
                        recipientNickname: "bob",
                        text: plaintext.text,
                        createdAtMilliseconds: plaintext.createdAtMilliseconds))
    }

    func testInternetDirectMessageV1DeterministicInteropVector() throws {
        let senderKey = P256.Signing.PrivateKey()
        let recipientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(1...32))
        let ephemeralPrivateKey = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(33...64))
        let recipient = InternetDirectMessageRecipientKey(
            deviceID: "recipient-device",
            publicKeyBase64: "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=",
            keyFingerprint: "aaa8fff703b50b2297f4f6e1")
        let plaintext = InternetDirectMessagePlaintext(
            clientMessageID: "b3541665-3f5d-487b-9264-06af42d46210",
            senderNickname: "alice",
            recipientNickname: "bob",
            text: "interop vector",
            createdAtMilliseconds: 1_800_000_000_123)
        let envelope = try InternetDirectMessageCrypto.seal(
            plaintext,
            senderUserID: "sender-user",
            senderDeviceID: "sender-device",
            recipient: recipient,
            ephemeralPrivateKey: ephemeralPrivateKey,
            nonceData: Data(0..<12),
            sign: { payload in
                try senderKey.signature(for: payload).derRepresentation.base64EncodedString()
            })
        XCTAssertEqual(envelope.ephemeralPublicKey,
                       "WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns=")
        XCTAssertEqual(envelope.nonce, "AAECAwQFBgcICQoL")
        XCTAssertEqual(
            envelope.ciphertext,
            "CxnpyCKt8T7MjkugcB7TVOk/ofplegOEb58v1C0ErdNz3vE8082CtJySYHf2N7YWMzYfbzgaAP5kzB7KmKfTkapu11y1W4RnCa7RexoMmMAuxQOF8dJ60lUkV1Q7QZS1YpayHBVSTimBGG61BSwOgeJz84A00qcpgALc9tP6mITE1yeg")
        let senderPublicKey = senderKey.publicKey.x963Representation
        let opened = try InternetDirectMessageCrypto.open(
            envelope,
            senderUserID: "sender-user",
            senderDeviceID: "sender-device",
            senderSigningPublicKey: senderPublicKey.base64EncodedString(),
            senderKeyFingerprint: SHA256.hash(data: senderPublicKey).prefix(12).map {
                String(format: "%02x", $0)
            }.joined(),
            recipientDeviceID: recipient.deviceID,
            recipientPrivateKey: recipientPrivateKey,
            expectedClientMessageID: plaintext.clientMessageID,
            expectedSenderNickname: plaintext.senderNickname,
            expectedRecipientNickname: plaintext.recipientNickname)
        XCTAssertEqual(opened, plaintext)
    }

    func testInternetDirectMessageRejectsTamperingAndWrongRecipientKey() throws {
        let fixture = internetTextFixture()
        let plaintext = InternetDirectMessagePlaintext(
            clientMessageID: "81e5a2dd-457c-45d1-864e-d901ad1272df",
            senderNickname: "alice",
            recipientNickname: "bob",
            text: "authenticated text",
            createdAtMilliseconds: 1_800_000_000_124)
        let envelope = try InternetDirectMessageCrypto.seal(
            plaintext,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            recipient: fixture.recipient,
            sign: { payload in
                try fixture.senderKey.signature(for: payload)
                    .derRepresentation.base64EncodedString()
            })

        var tamperedCiphertext = try XCTUnwrap(Data(base64Encoded: envelope.ciphertext))
        tamperedCiphertext[0] ^= 0x01
        let unsignedTamper = replacingInternetEnvelope(
            envelope,
            ciphertext: tamperedCiphertext.base64EncodedString())
        XCTAssertThrowsError(try InternetDirectMessageCrypto.open(
            unsignedTamper,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            senderSigningPublicKey: fixture.sender.signingPublicKey,
            senderKeyFingerprint: fixture.sender.keyFingerprint,
            recipientDeviceID: fixture.recipient.deviceID,
            recipientPrivateKey: fixture.recipientKey,
            expectedClientMessageID: plaintext.clientMessageID,
            expectedSenderNickname: plaintext.senderNickname,
            expectedRecipientNickname: plaintext.recipientNickname)) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .invalidSenderSignature)
        }

        let tamperedPayload = backendDirectMessageSignaturePayload(
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            recipientNickname: plaintext.recipientNickname,
            cryptoVersion: envelope.cryptoVersion,
            recipientDeviceID: envelope.recipientDeviceID,
            recipientKeyFingerprint: envelope.recipientKeyFingerprint,
            clientMessageID: plaintext.clientMessageID,
            ephemeralPublicKey: try XCTUnwrap(Data(base64Encoded: envelope.ephemeralPublicKey)),
            nonce: try XCTUnwrap(Data(base64Encoded: envelope.nonce)),
            ciphertext: tamperedCiphertext)
        let resignedTamper = replacingInternetEnvelope(
            unsignedTamper,
            senderSignature: try fixture.senderKey.signature(for: tamperedPayload)
                .derRepresentation.base64EncodedString())
        XCTAssertThrowsError(try InternetDirectMessageCrypto.open(
            resignedTamper,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            senderSigningPublicKey: fixture.sender.signingPublicKey,
            senderKeyFingerprint: fixture.sender.keyFingerprint,
            recipientDeviceID: fixture.recipient.deviceID,
            recipientPrivateKey: fixture.recipientKey,
            expectedClientMessageID: plaintext.clientMessageID,
            expectedSenderNickname: plaintext.senderNickname,
            expectedRecipientNickname: plaintext.recipientNickname)) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .authenticationFailed)
        }

        XCTAssertThrowsError(try InternetDirectMessageCrypto.open(
            envelope,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            senderSigningPublicKey: fixture.sender.signingPublicKey,
            senderKeyFingerprint: fixture.sender.keyFingerprint,
            recipientDeviceID: fixture.recipient.deviceID,
            recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            expectedClientMessageID: plaintext.clientMessageID,
            expectedSenderNickname: plaintext.senderNickname,
            expectedRecipientNickname: plaintext.recipientNickname)) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .wrongRecipientKey)
        }
        XCTAssertThrowsError(try InternetDirectMessageCrypto.open(
            envelope,
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            senderSigningPublicKey: fixture.sender.signingPublicKey,
            senderKeyFingerprint: fixture.sender.keyFingerprint,
            recipientDeviceID: fixture.recipient.deviceID,
            recipientPrivateKey: fixture.recipientKey,
            expectedClientMessageID: plaintext.clientMessageID,
            expectedSenderNickname: "mallory",
            expectedRecipientNickname: plaintext.recipientNickname)) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .messageMetadataMismatch)
        }
    }

    func testInternetDirectMessageFanoutUsesFreshKeyAndNoncePerDevice() throws {
        let fixture = internetTextFixture()
        let secondPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let secondPublicKey = secondPrivateKey.publicKey.rawRepresentation
        let secondRecipient = InternetDirectMessageRecipientKey(
            deviceID: "recipient-device-two",
            publicKeyBase64: secondPublicKey.base64EncodedString(),
            keyFingerprint: SHA256.hash(data: secondPublicKey).prefix(12).map {
                String(format: "%02x", $0)
            }.joined())
        let plaintext = InternetDirectMessagePlaintext(
            clientMessageID: "635994ef-eed5-433d-a481-9d726d003e73",
            senderNickname: "alice",
            recipientNickname: "bob",
            text: "one plaintext, one envelope per device",
            createdAtMilliseconds: 1_800_000_000_125)
        let envelopes = try InternetDirectMessageCrypto.seal(
            plaintext,
            sender: fixture.sender,
            recipients: [fixture.recipient, secondRecipient],
            sign: { payload in
                try fixture.senderKey.signature(for: payload)
                    .derRepresentation.base64EncodedString()
            })
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(Set(envelopes.map { $0.recipientDeviceID }).count, 2)
        XCTAssertEqual(Set(envelopes.map { $0.ephemeralPublicKey }).count, 2)
        XCTAssertEqual(Set(envelopes.map { $0.nonce }).count, 2)
        let openedSecond = try InternetDirectMessageCrypto.open(
            envelopes[1],
            senderUserID: fixture.sender.userID,
            senderDeviceID: fixture.sender.deviceID,
            senderSigningPublicKey: fixture.sender.signingPublicKey,
            senderKeyFingerprint: fixture.sender.keyFingerprint,
            recipientDeviceID: secondRecipient.deviceID,
            recipientPrivateKey: secondPrivateKey,
            expectedClientMessageID: plaintext.clientMessageID,
            expectedSenderNickname: plaintext.senderNickname,
            expectedRecipientNickname: plaintext.recipientNickname)
        XCTAssertEqual(openedSecond, plaintext)
    }

    func testInternetDirectMessageRejectsInvalidClientNicknameAndTextBounds() throws {
        let fixture = internetTextFixture()
        func seal(_ plaintext: InternetDirectMessagePlaintext) throws {
            _ = try InternetDirectMessageCrypto.seal(
                plaintext,
                senderUserID: fixture.sender.userID,
                senderDeviceID: fixture.sender.deviceID,
                recipient: fixture.recipient,
                sign: { payload in
                    try fixture.senderKey.signature(for: payload)
                        .derRepresentation.base64EncodedString()
                })
        }
        XCTAssertThrowsError(try seal(InternetDirectMessagePlaintext(
            clientMessageID: "not-a-uuid",
            senderNickname: "alice",
            recipientNickname: "bob",
            text: "text",
            createdAtMilliseconds: 1))) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .invalidClientMessageID)
        }
        XCTAssertThrowsError(try seal(InternetDirectMessagePlaintext(
            clientMessageID: UUID().uuidString,
            senderNickname: "alice",
            recipientNickname: "invalid nickname",
            text: "text",
            createdAtMilliseconds: 1))) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .invalidNickname)
        }
        XCTAssertThrowsError(try seal(InternetDirectMessagePlaintext(
            clientMessageID: UUID().uuidString,
            senderNickname: "alice",
            recipientNickname: "bob",
            text: String(repeating: "x", count: InternetDirectMessageCrypto.maximumTextBytes + 1),
            createdAtMilliseconds: 1))) { error in
                XCTAssertEqual(error as? InternetDirectMessageCryptoError,
                               .invalidText)
        }
    }

    func testMeshTextEnvelopeRoundTripPreservesUnicodeNewlinesAndIdentity() throws {
        let fixture = meshTextFixture()
        let now: Int64 = 1_800_000_000_000
        let nonce = UUID()
        let text = "line one\nline two 👋"
        let wire = try XCTUnwrap(sealMeshText(text, fixture: fixture, timestamp: now, nonce: nonce))
        let opened = try XCTUnwrap(MeshTextEnvelope.open(wire,
                                                        recipient: fixture.recipient,
                                                        recipientPrivateKey: fixture.recipientKey,
                                                        nowMilliseconds: now))
        XCTAssertEqual(opened.id, nonce.uuidString.lowercased())
        XCTAssertEqual(opened.senderNickname, "alice")
        XCTAssertEqual(opened.senderUserID, fixture.sender.userID)
        XCTAssertEqual(opened.senderDeviceID, fixture.sender.deviceID)
        XCTAssertEqual(opened.recipientDeviceID, fixture.recipient.deviceID)
        XCTAssertEqual(opened.text, text)
        XCTAssertEqual(wire.prefix(2), MeshTextEnvelope.magic)
        XCTAssertLessThanOrEqual(wire.count, MeshTextEnvelope.maximumWireBytes)
    }

    func testMeshTextEnvelopeRejectsWrongRecipientTamperingAndStaleTimestamp() throws {
        let fixture = meshTextFixture()
        let now: Int64 = 1_800_000_000_000
        let wire = try XCTUnwrap(sealMeshText("private", fixture: fixture, timestamp: now))
        XCTAssertNil(MeshTextEnvelope.open(wire,
                                           recipient: fixture.recipient,
                                           recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
                                           nowMilliseconds: now))
        var tamperedHeader = wire
        tamperedHeader[3] ^= 1
        XCTAssertNil(MeshTextEnvelope.open(tamperedHeader,
                                           recipient: fixture.recipient,
                                           recipientPrivateKey: fixture.recipientKey,
                                           nowMilliseconds: now))
        var tamperedCiphertext = wire
        tamperedCiphertext[tamperedCiphertext.count - 1] ^= 1
        XCTAssertNil(MeshTextEnvelope.open(tamperedCiphertext,
                                           recipient: fixture.recipient,
                                           recipientPrivateKey: fixture.recipientKey,
                                           nowMilliseconds: now))
        XCTAssertNil(MeshTextEnvelope.open(wire,
                                           recipient: fixture.recipient,
                                           recipientPrivateKey: fixture.recipientKey,
                                           nowMilliseconds: now + MeshTextEnvelope.maximumSkewMilliseconds + 1))
    }

    func testMeshTextEnvelopeRejectsMissingCapabilityAndForgedSenderSignature() throws {
        let fixture = meshTextFixture()
        let now: Int64 = 1_800_000_000_000
        let noCapability = DirectoryContact(userID: fixture.contact.userID,
                                            deviceID: fixture.contact.deviceID,
                                            nickname: fixture.contact.nickname,
                                            displayName: fixture.contact.displayName,
                                            keyFingerprint: fixture.contact.keyFingerprint,
                                            source: .mesh,
                                            online: true,
                                            meshAddress: fixture.contact.meshAddress,
                                            meshPort: fixture.contact.meshPort)
        XCTAssertNil(MeshTextEnvelope.seal(text: "no downgrade",
                                           sender: fixture.sender,
                                           recipient: noCapability))
        let forged = MeshTextEnvelope.seal(text: "forged",
                                           sender: fixture.sender,
                                           recipient: fixture.contact,
                                           timestamp: now,
                                           sign: { payload in
                                               try P256.Signing.PrivateKey().signature(for: payload)
                                                .derRepresentation.base64EncodedString()
                                           })
        XCTAssertNotNil(forged)
        XCTAssertNil(MeshTextEnvelope.open(try XCTUnwrap(forged),
                                           recipient: fixture.recipient,
                                           recipientPrivateKey: fixture.recipientKey,
                                           nowMilliseconds: now))
    }

    func testMeshTextIdentityMustMatchLiveSignedContactKeyAndAddress() throws {
        let fixture = meshTextFixture()
        let now: Int64 = 1_800_000_000_000
        let wire = try XCTUnwrap(sealMeshText("bound sender", fixture: fixture, timestamp: now))
        let message = try XCTUnwrap(MeshTextEnvelope.open(wire,
                                                         recipient: fixture.recipient,
                                                         recipientPrivateKey: fixture.recipientKey,
                                                         nowMilliseconds: now))
        let validSenderContact = DirectoryContact(
            userID: fixture.sender.userID,
            deviceID: fixture.sender.deviceID,
            nickname: fixture.sender.nickname ?? "",
            displayName: fixture.sender.displayName,
            keyFingerprint: fixture.sender.keyFingerprint,
            source: .mesh,
            online: true,
            meshAddress: "192.168.1.10",
            meshPort: MeshCallSignaling.port,
            signingPublicKey: fixture.sender.signingPublicKey,
            textEncryptionPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
                .base64EncodedString())
        XCTAssertTrue(MeshTextIdentityPolicy.matches(message,
                                                     contact: validSenderContact,
                                                     sourceAddress: "192.168.1.10"))

        let victimKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let victimContact = DirectoryContact(
            userID: fixture.sender.userID,
            deviceID: fixture.sender.deviceID,
            nickname: fixture.sender.nickname ?? "",
            displayName: fixture.sender.displayName,
            keyFingerprint: SHA256.hash(data: victimKey).prefix(12).map {
                String(format: "%02x", $0)
            }.joined(),
            source: .mesh,
            online: true,
            meshAddress: "192.168.1.10",
            meshPort: MeshCallSignaling.port,
            signingPublicKey: victimKey.base64EncodedString(),
            textEncryptionPublicKey: validSenderContact.textEncryptionPublicKey)
        XCTAssertFalse(MeshTextIdentityPolicy.matches(message,
                                                      contact: victimContact,
                                                      sourceAddress: "192.168.1.10"))
        XCTAssertFalse(MeshTextIdentityPolicy.matches(message,
                                                      contact: validSenderContact,
                                                      sourceAddress: "192.168.1.11"))
        let multihomed = DirectoryContact(userID: validSenderContact.userID,
                                          deviceID: validSenderContact.deviceID,
                                          nickname: validSenderContact.nickname,
                                          displayName: validSenderContact.displayName,
                                          keyFingerprint: validSenderContact.keyFingerprint,
                                          source: validSenderContact.source,
                                          online: true,
                                          meshAddress: "10.15.94.164",
                                          meshPort: MeshCallSignaling.port,
                                          signingPublicKey: validSenderContact.signingPublicKey,
                                          textEncryptionPublicKey: validSenderContact.textEncryptionPublicKey,
                                          meshAddresses: ["10.15.94.164", "192.168.1.10"])
        XCTAssertTrue(MeshTextIdentityPolicy.matches(message,
                                                     contact: multihomed,
                                                     sourceAddress: "192.168.1.10"))
    }

    func testMeshInviteIdentityMustMatchPinnedSignedContactKeyAndAddress() {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let fingerprint = SHA256.hash(data: publicKey).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        let invite = MeshCallInvite(version: 1,
                                    callID: UUID().uuidString,
                                    nickname: "alice",
                                    displayName: "Alice",
                                    userID: "alice-user",
                                    deviceID: "alice-device",
                                    publicKey: publicKey.base64EncodedString(),
                                    keyFingerprint: fingerprint,
                                    mediaPort: MeshCallSignaling.mediaPort,
                                    timestamp: 1_000,
                                    nonce: UUID().uuidString,
                                    signature: "signature")
        let contact = DirectoryContact(userID: invite.userID,
                                       deviceID: invite.deviceID,
                                       nickname: invite.nickname,
                                       displayName: invite.displayName,
                                       keyFingerprint: invite.keyFingerprint,
                                       source: .mesh,
                                       online: true,
                                       meshAddress: "192.168.1.10",
                                       meshPort: MeshCallSignaling.port,
                                       signingPublicKey: invite.publicKey,
                                       textEncryptionPublicKey: Curve25519.KeyAgreement.PrivateKey()
                                        .publicKey.rawRepresentation.base64EncodedString())
        XCTAssertTrue(MeshInviteIdentityPolicy.matches(invite,
                                                       contact: contact,
                                                       sourceAddress: "192.168.1.10"))
        let cachedContact = DirectoryContact(userID: contact.userID,
                                             deviceID: contact.deviceID,
                                             nickname: contact.nickname,
                                             displayName: contact.displayName,
                                             keyFingerprint: contact.keyFingerprint,
                                             source: .mesh,
                                             online: false,
                                             meshAddress: contact.meshAddress,
                                             meshPort: contact.meshPort,
                                             signingPublicKey: contact.signingPublicKey,
                                             textEncryptionPublicKey: contact.textEncryptionPublicKey)
        XCTAssertTrue(MeshInviteIdentityPolicy.matches(invite,
                                                       contact: cachedContact,
                                                       sourceAddress: "192.168.1.10"))
        XCTAssertFalse(MeshInviteIdentityPolicy.matches(invite,
                                                        contact: contact,
                                                        sourceAddress: "192.168.1.11"))
        let forgedKey = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let forged = MeshCallInvite(version: invite.version,
                                    callID: invite.callID,
                                    nickname: invite.nickname,
                                    displayName: invite.displayName,
                                    userID: invite.userID,
                                    deviceID: invite.deviceID,
                                    publicKey: forgedKey,
                                    keyFingerprint: DeviceIdentityStore.fingerprint(for: forgedKey)!,
                                    mediaPort: invite.mediaPort,
                                    timestamp: invite.timestamp,
                                    nonce: invite.nonce,
                                    signature: invite.signature)
        XCTAssertFalse(MeshInviteIdentityPolicy.matches(forged,
                                                        contact: contact,
                                                        sourceAddress: "192.168.1.10"))
    }

    func testEncryptedTextContactSelectionFailsClosedOnDuplicateNickname() {
        func contact(device: String, address: String) -> DirectoryContact {
            DirectoryContact(userID: "user-\(device)",
                             deviceID: device,
                             nickname: "alice",
                             displayName: "Alice",
                             keyFingerprint: "fingerprint-\(device)",
                             source: .mesh,
                             online: true,
                             meshAddress: address,
                             meshPort: MeshCallSignaling.port,
                             signingPublicKey: "key-\(device)",
                             textEncryptionPublicKey: "text-key-\(device)")
        }
        let first = contact(device: "one", address: "192.168.1.10")
        let second = contact(device: "two", address: "192.168.1.11")
        XCTAssertEqual(MeshContactSelectionPolicy.uniqueActive([first], named: "alice"), first)
        XCTAssertNil(MeshContactSelectionPolicy.uniqueActive([first, second], named: "alice"))
        XCTAssertNil(MeshContactSelectionPolicy.uniqueActive([first, second], named: "Alice"))
    }

    func testMeshTextIdentityPinRejectsNicknameKeyOrDeviceReplacement() {
        let suite = "trinet-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeshTextIdentityPinStore(defaults: defaults, storageKey: "pins")

        func contact(deviceID: String,
                     signingKey: P256.Signing.PrivateKey,
                     textKey: Curve25519.KeyAgreement.PrivateKey) -> DirectoryContact {
            let publicKey = signingKey.publicKey.x963Representation
            return DirectoryContact(userID: "user",
                                    deviceID: deviceID,
                                    nickname: "alice",
                                    displayName: "Alice",
                                    keyFingerprint: SHA256.hash(data: publicKey).prefix(12).map {
                                        String(format: "%02x", $0)
                                    }.joined(),
                                    source: .mesh,
                                    online: true,
                                    meshAddress: "192.168.1.10",
                                    meshPort: MeshCallSignaling.port,
                                    signingPublicKey: publicKey.base64EncodedString(),
                                    textEncryptionPublicKey: textKey.publicKey.rawRepresentation
                                        .base64EncodedString())
        }

        let signingKey = P256.Signing.PrivateKey()
        let textKey = Curve25519.KeyAgreement.PrivateKey()
        let original = contact(deviceID: "device-one", signingKey: signingKey, textKey: textKey)
        XCTAssertTrue(store.accept(original))
        XCTAssertTrue(store.accept(original))
        XCTAssertFalse(store.accept(contact(deviceID: "device-two",
                                            signingKey: signingKey,
                                            textKey: textKey)))
        XCTAssertFalse(store.accept(contact(deviceID: "device-one",
                                            signingKey: P256.Signing.PrivateKey(),
                                            textKey: textKey)))
        XCTAssertFalse(store.accept(contact(deviceID: "device-one",
                                            signingKey: signingKey,
                                            textKey: Curve25519.KeyAgreement.PrivateKey())))
        let reloaded = MeshTextIdentityPinStore(defaults: defaults, storageKey: "pins")
        XCTAssertTrue(reloaded.accept(original))
    }

    func testMeshTextEnvelopeClampsUtf8AndUsesFreshEphemeralKeys() throws {
        let fixture = meshTextFixture()
        let now: Int64 = 1_800_000_000_000
        let input = String(repeating: "👋", count: MeshTextEnvelope.maximumTextBytes)
        let clamped = MeshTextEnvelope.clamp(input)
        XCTAssertLessThanOrEqual(clamped.utf8.count, MeshTextEnvelope.maximumTextBytes)
        XCTAssertEqual(clamped.utf8.count % 4, 0)
        let first = try XCTUnwrap(sealMeshText(clamped, fixture: fixture, timestamp: now))
        let second = try XCTUnwrap(sealMeshText(clamped, fixture: fixture, timestamp: now))
        XCTAssertLessThanOrEqual(first.count, MeshTextEnvelope.maximumWireBytes)
        XCTAssertLessThanOrEqual(second.count, MeshTextEnvelope.maximumWireBytes)
        XCTAssertNotEqual(Data(first[19..<51]), Data(second[19..<51]))
    }

    func testMeshTextTimestampBoundsAreOverflowSafe() {
        let now: Int64 = 1_000_000
        XCTAssertTrue(MeshTextEnvelope.isFresh(now - 44_000, now: now))
        XCTAssertTrue(MeshTextEnvelope.isFresh(now - 60_000, now: now))
        XCTAssertFalse(MeshTextEnvelope.isFresh(now - 60_001, now: now))
        XCTAssertTrue(MeshTextEnvelope.isFresh(now + 44_000, now: now))
        XCTAssertTrue(MeshTextEnvelope.isFresh(now + 60_000, now: now))
        XCTAssertFalse(MeshTextEnvelope.isFresh(now + 60_001, now: now))
        XCTAssertTrue(MeshTextEnvelope.isFresh(Int64.max, now: Int64.max - 1))
        XCTAssertTrue(MeshTextEnvelope.isFresh(Int64.min, now: Int64.min + 1))
        XCTAssertFalse(MeshTextEnvelope.isFresh(0, now: now))
    }

    func testTextEncryptionKeyIsStableAcrossConcurrentLoads() {
        let resultLock = NSLock()
        var values: [Data] = []
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let value = try DeviceIdentityStore.shared.textEncryptionPrivateKey().rawRepresentation
                resultLock.lock(); values.append(value); resultLock.unlock()
            } catch {
                resultLock.lock(); failures += 1; resultLock.unlock()
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(values.count, 16)
        XCTAssertEqual(Set(values).count, 1)
        XCTAssertEqual(values.first?.count, 32)
    }

    func testNicknameMigrationIsStableUniqueAndDoesNotReplaceAnExistingNickname() {
        XCTAssertEqual(
            NicknameMigrationPolicy.candidate(
                currentNickname: nil,
                displayName: "iPhone13",
                deviceID: "1c50a201-a8e4-4bd1-8c49-8ace606e47c7"
            ),
            "iphone13_1c50a2"
        )
        XCTAssertNil(
            NicknameMigrationPolicy.candidate(
                currentNickname: "alice",
                displayName: "iPhone13",
                deviceID: "1c50a201-a8e4-4bd1-8c49-8ace606e47c7"
            )
        )
    }

    func testInternetCallMediaKeepsAudioOnlyAndVideoIntentDistinct() {
        XCTAssertEqual(
            InternetCallMedia.outgoing(cameraOff: true),
            InternetCallMedia(audio: true, video: false)
        )
        XCTAssertEqual(
            InternetCallMedia.outgoing(cameraOff: false),
            InternetCallMedia(audio: true, video: true)
        )
        XCTAssertEqual(
            InternetCallMedia(audio: false, video: true),
            InternetCallMedia(audio: false, video: true)
        )
        XCTAssertEqual(MeshCallSignaling.protocolVersion(for: .audioVideo), 1)
        XCTAssertEqual(MeshCallSignaling.protocolVersion(for: .audioOnly), 2)
    }

    func testDirectChatTimestampFreshnessIsOverflowSafe() {
        let now: Int64 = 1_000_000
        XCTAssertTrue(DirectChatTimestampPolicy.isFresh(now - 30_000, now: now))
        XCTAssertFalse(DirectChatTimestampPolicy.isFresh(now - 30_001, now: now))
        XCTAssertTrue(DirectChatTimestampPolicy.isFresh(now + 30_000, now: now))
        XCTAssertFalse(DirectChatTimestampPolicy.isFresh(now + 30_001, now: now))
        XCTAssertFalse(DirectChatTimestampPolicy.isFresh(0, now: now))
        XCTAssertTrue(DirectChatTimestampPolicy.isFresh(Int64.max, now: Int64.max - 1))
        XCTAssertTrue(DirectChatTimestampPolicy.isFresh(Int64.min, now: Int64.min + 1))
    }

    func testOutgoingCallGateRequiresRequestAndActionInEitherOrder() {
        var requestFirst = CallStartGate()
        requestFirst.requestSucceeded = true
        XCTAssertFalse(requestFirst.isReady)
        requestFirst.actionSucceeded = true
        XCTAssertTrue(requestFirst.isReady)

        var actionFirst = CallStartGate()
        actionFirst.actionSucceeded = true
        XCTAssertFalse(actionFirst.isReady)
        actionFirst.requestSucceeded = true
        XCTAssertTrue(actionFirst.isReady)
    }

    func testForegroundChatPushDoesNotPlayDuplicateSystemSound() {
        XCTAssertFalse(
            AlertPresentationPolicy.shouldPlaySystemSound(
                userInfo: ["type": "group_chat_message"]
            )
        )
        XCTAssertFalse(
            AlertPresentationPolicy.shouldPlaySystemSound(
                userInfo: ["type": "direct_message"]
            )
        )
        XCTAssertTrue(
            AlertPresentationPolicy.shouldPlaySystemSound(
                userInfo: ["type": "incoming_call"]
            )
        )
        XCTAssertTrue(
            AlertPresentationPolicy.shouldPlaySystemSound(userInfo: [:])
        )
    }

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

    func testStalePrivateAPIEndpointUsesBundledLocalHostname() {
        let bundled = "http://SSDs-MacBook-Pro.local:8080"

        XCTAssertEqual(
            InternetCallConfiguration.preferredAPIBaseURL(
                saved: "http://172.20.10.5:8080",
                bundled: bundled
            ),
            bundled
        )
        XCTAssertEqual(
            InternetCallConfiguration.preferredAPIBaseURL(
                saved: "https://calls.example.com",
                bundled: bundled
            ),
            "https://calls.example.com"
        )
        XCTAssertEqual(
            InternetCallConfiguration.preferredAPIBaseURL(
                saved: "http://192.168.50.2:8080",
                bundled: "https://calls.example.com"
            ),
            "http://192.168.50.2:8080"
        )
    }

    func testPublicRouteRequiresPublicHTTPSAndBuildsHealthURL() {
        func configuration(_ api: String) -> InternetCallConfiguration {
            InternetCallConfiguration(apiBaseURL: api,
                                      liveKitURL: "",
                                      accessToken: "",
                                      developmentRoomToken: "")
        }

        XCTAssertTrue(configuration("https://calls.example.com").isPublicHTTPSAPI)
        XCTAssertEqual(configuration("https://calls.example.com").healthURL?.absoluteString,
                       "https://calls.example.com/healthz")
        XCTAssertEqual(configuration("https://calls.example.com/api").healthURL?.absoluteString,
                       "https://calls.example.com/api/healthz")
        XCTAssertEqual(
            configuration("https://calls.example.com/api").endpointURL(path: "/v1/calls")?.absoluteString,
            "https://calls.example.com/api/v1/calls"
        )
        XCTAssertFalse(configuration("http://calls.example.com").isPublicHTTPSAPI)
        XCTAssertFalse(configuration("https://SSDs-MacBook-Pro.local:8080").isPublicHTTPSAPI)
        XCTAssertFalse(configuration("https://192.168.1.20:8080").isPublicHTTPSAPI)
        XCTAssertFalse(configuration("https://[fd00::1]:8080").isPublicHTTPSAPI)
    }

    func testInternetCallCreationRetriesOnlyAmbiguousFailures() {
        XCTAssertTrue(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 408))
        XCTAssertTrue(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 429))
        XCTAssertTrue(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 500))
        XCTAssertTrue(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 599))
        XCTAssertFalse(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 400))
        XCTAssertFalse(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 409))
        XCTAssertFalse(InternetCallCreateRetryPolicy.shouldRetryHTTP(statusCode: 600))
        XCTAssertEqual(
            InternetCallCreateRetryPolicy.retryDelayNanoseconds(afterFailedAttempt: 1),
            350_000_000
        )
        XCTAssertEqual(
            InternetCallCreateRetryPolicy.retryDelayNanoseconds(afterFailedAttempt: 2),
            700_000_000
        )
    }

    func testPushEnvironmentComesFromSigningConfigurationValue() {
        XCTAssertEqual(PushEnvironmentPolicy.normalizedBackendValue("development"), "sandbox")
        XCTAssertEqual(PushEnvironmentPolicy.normalizedBackendValue("sandbox"), "sandbox")
        XCTAssertEqual(PushEnvironmentPolicy.normalizedBackendValue("production"), "production")
        XCTAssertNil(PushEnvironmentPolicy.normalizedBackendValue("DEBUG"))
        XCTAssertNil(PushEnvironmentPolicy.normalizedBackendValue(nil))
    }

    func testUDPSourcePolicyRequiresExactAddressAndPort() {
        let expected = UDPSourceEndpoint(ipv4NetworkOrder: 0x0101A8C0,
                                         portNetworkOrder: UInt16(7000).bigEndian)
        let wrongPort = UDPSourceEndpoint(ipv4NetworkOrder: 0x0101A8C0,
                                          portNetworkOrder: UInt16(7001).bigEndian)
        let wrongAddress = UDPSourceEndpoint(ipv4NetworkOrder: 0x0201A8C0,
                                             portNetworkOrder: UInt16(7000).bigEndian)
        XCTAssertTrue(UDPSourcePolicy.allows(expected, expected: [expected]))
        XCTAssertFalse(UDPSourcePolicy.allows(wrongPort, expected: [expected]))
        XCTAssertFalse(UDPSourcePolicy.allows(wrongAddress, expected: [expected]))
    }

    func testAutomaticRouteUsesOnlyLiveMeshContacts() {
        XCTAssertEqual(
            CallRoutePolicy.select(
                requested: .automatic,
                targetIsMeshAddress: false,
                hasLiveMeshContact: true
            ),
            .mesh
        )
        XCTAssertEqual(
            CallRoutePolicy.select(
                requested: .automatic,
                targetIsMeshAddress: false,
                hasLiveMeshContact: false
            ),
            .internet
        )
        XCTAssertEqual(
            CallRoutePolicy.select(
                requested: .automatic,
                targetIsMeshAddress: true,
                hasLiveMeshContact: false
            ),
            .mesh
        )
        XCTAssertEqual(
            CallRoutePolicy.select(
                requested: .mesh,
                targetIsMeshAddress: false,
                hasLiveMeshContact: false
            ),
            .mesh
        )
    }

    func testLinkLocalMeshAddressIsNeverPersisted() {
        XCTAssertTrue(MeshAddressPolicy.isNumericIPv4("169.254.77.118"))
        XCTAssertFalse(MeshAddressPolicy.isNumericIPv4("peer.local"))
        XCTAssertFalse(MeshAddressPolicy.isNumericIPv4("192.168.1.256"))
        XCTAssertFalse(MeshAddressPolicy.isNumericIPv4("192.168..1"))
        XCTAssertFalse(MeshAddressPolicy.isNumericIPv4("192.168.bad.1.2"))
        XCTAssertTrue(MeshAddressPolicy.isLinkLocalIPv4("169.254.77.118"))
        XCTAssertFalse(MeshAddressPolicy.canPersist("169.254.77.118"))
        XCTAssertTrue(MeshAddressPolicy.canPersist("192.168.1.105"))
        XCTAssertTrue(MeshAddressPolicy.canPersist("10.27.0.4"))
    }

    func testDeviceDisplayNamePolicyHidesRawNetworkAddresses() {
        XCTAssertTrue(DeviceDisplayNamePolicy.isRawIPAddress("192.168.1.20"))
        XCTAssertTrue(DeviceDisplayNamePolicy.isRawIPAddress("@192.168.1.20:7000"))
        XCTAssertTrue(DeviceDisplayNamePolicy.isRawIPAddress("[fe80::1%en0]:7000"))
        XCTAssertFalse(DeviceDisplayNamePolicy.isRawIPAddress("iphone13"))
        XCTAssertEqual(
            DeviceDisplayNamePolicy.safe("192.168.1.20", fallback: "Local TRI-NET peer"),
            "Local TRI-NET peer"
        )
        XCTAssertEqual(DeviceDisplayNamePolicy.safe(" Alice ", fallback: "peer"), "Alice")
    }

    func testDirectoryResultsSurviveBonjourUpdatesWithCorrectPriority() {
        func contact(_ source: DirectorySource,
                     online: Bool,
                     deviceID: String,
                     nickname: String = "zames") -> DirectoryContact {
            DirectoryContact(userID: "user-\(deviceID)",
                             deviceID: deviceID,
                             nickname: nickname,
                             displayName: nickname,
                             keyFingerprint: "fp-\(deviceID)",
                             source: source,
                             online: online,
                             meshAddress: source == .mesh ? "192.168.1.105" : nil,
                             meshPort: source == .mesh ? 7001 : nil)
        }

        let cached = contact(.mesh, online: false, deviceID: "device-1")
        let onlineInternet = contact(.internet, online: true, deviceID: "device-1")
        var merged = DirectoryResultPolicy.merge(mesh: [cached],
                                                 internet: [onlineInternet],
                                                 query: "zames")
        XCTAssertEqual(merged, [onlineInternet])

        let unrelatedBonjourPeer = contact(.mesh,
                                           online: true,
                                           deviceID: "device-2",
                                           nickname: "t27")
        merged = DirectoryResultPolicy.merge(mesh: [cached, unrelatedBonjourPeer],
                                             internet: [onlineInternet],
                                             query: "zames")
        XCTAssertEqual(merged, [onlineInternet])

        let liveMesh = contact(.mesh, online: true, deviceID: "device-1")
        merged = DirectoryResultPolicy.merge(mesh: [liveMesh],
                                             internet: [onlineInternet],
                                             query: "zames")
        XCTAssertEqual(merged, [liveMesh])

        let offlineInternet = contact(.internet, online: false, deviceID: "device-1")
        merged = DirectoryResultPolicy.merge(mesh: [cached],
                                             internet: [offlineInternet],
                                             query: "zames")
        XCTAssertEqual(merged, [cached])

        let distinctInternet = contact(.internet,
                                       online: true,
                                       deviceID: "device-3",
                                       nickname: "zames_two")
        merged = DirectoryResultPolicy.merge(mesh: [unrelatedBonjourPeer],
                                             internet: [distinctInternet],
                                             query: "zames")
        XCTAssertTrue(merged.isEmpty)
        merged = DirectoryResultPolicy.merge(mesh: [unrelatedBonjourPeer],
                                             internet: [distinctInternet],
                                             query: "zames_two")
        XCTAssertEqual(merged, [distinctInternet])

        let migratedLocal = DirectoryContact(userID: "user-migrated",
                                             deviceID: "device-migrated",
                                             nickname: "stable_1c50a2",
                                             displayName: "iPhone13",
                                             keyFingerprint: "fp-migrated",
                                             source: .mesh,
                                             online: true,
                                             meshAddress: "192.168.1.106",
                                             meshPort: 7001)
        merged = DirectoryResultPolicy.merge(mesh: [migratedLocal],
                                             internet: [],
                                             query: "iphone13")
        XCTAssertTrue(merged.isEmpty)
        merged = DirectoryResultPolicy.merge(mesh: [migratedLocal],
                                             internet: [],
                                             query: "stable_1c50a2")
        XCTAssertEqual(merged, [migratedLocal])
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
        let payload = MeshCallSignaling.signedPayloadV2(callID: "call-1",
                                                        nickname: "alice",
                                                        displayName: "Alice",
                                                        userID: "user-1",
                                                        deviceID: "device-1",
                                                        mediaPort: 7000,
                                                        media: .audioOnly,
                                                        timestamp: timestamp,
                                                        nonce: "nonce-1")
        let signature = try privateKey.signature(for: payload).derRepresentation.base64EncodedString()
        let invite = MeshCallInvite(version: 2,
                                    callID: "call-1",
                                    nickname: "alice",
                                    displayName: "Alice",
                                    userID: "user-1",
                                    deviceID: "device-1",
                                    publicKey: publicKeyText,
                                    keyFingerprint: fingerprint,
                                    mediaPort: 7000,
                                    media: .audioOnly,
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
                                      media: invite.media,
                                      timestamp: invite.timestamp,
                                      nonce: invite.nonce,
                                      signature: invite.signature)
        XCTAssertFalse(MeshCallSignaling.signatureIsValid(tampered))

        let tamperedMedia = MeshCallInvite(version: invite.version,
                                           callID: invite.callID,
                                           nickname: invite.nickname,
                                           displayName: invite.displayName,
                                           userID: invite.userID,
                                           deviceID: invite.deviceID,
                                           publicKey: invite.publicKey,
                                           keyFingerprint: invite.keyFingerprint,
                                           mediaPort: invite.mediaPort,
                                           media: .audioVideo,
                                           timestamp: invite.timestamp,
                                           nonce: invite.nonce,
                                           signature: invite.signature)
        XCTAssertFalse(MeshCallSignaling.signatureIsValid(tamperedMedia))
        let incoming = IncomingMeshCall(invite: invite,
                                        sourceAddress: "192.168.1.105",
                                        receivedAt: timestamp)
        XCTAssertTrue(incoming.isFresh(at: timestamp + 30))
        XCTAssertFalse(incoming.isFresh(at: timestamp + 31))
    }

    func testLegacyMeshInviteDefaultsToVideoAndIgnoresUnsignedMediaInjection() throws {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let publicKeyText = publicKey.base64EncodedString()
        let fingerprint = SHA256.hash(data: publicKey).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        let payload = MeshCallSignaling.signedPayload(callID: "legacy-call",
                                                      nickname: "alice",
                                                      displayName: "Alice",
                                                      userID: "user-1",
                                                      deviceID: "legacy-device",
                                                      mediaPort: 7000,
                                                      timestamp: 100,
                                                      nonce: "legacy-nonce")
        let signature = try privateKey.signature(for: payload).derRepresentation.base64EncodedString()
        let encoded = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "callID": "legacy-call",
            "nickname": "alice",
            "displayName": "Alice",
            "userID": "user-1",
            "deviceID": "legacy-device",
            "publicKey": publicKeyText,
            "keyFingerprint": fingerprint,
            "mediaPort": 7000,
            // Version 1 did not sign this field. A receiver must not trust it.
            "media": ["audio": true, "video": false],
            "timestamp": 100,
            "nonce": "legacy-nonce",
            "signature": signature
        ])

        let invite = try JSONDecoder().decode(MeshCallInvite.self, from: encoded)
        XCTAssertEqual(invite.media, .audioVideo)
        XCTAssertTrue(MeshCallSignaling.signatureIsValid(invite))
    }

    func testMeshControlIsSignedAndBoundToExactRoute() throws {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        let publicKeyText = publicKey.base64EncodedString()
        let fingerprint = SHA256.hash(data: publicKey).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        let timestamp: Int64 = 200
        let payload = MeshCallSignaling.signedControlPayload(kind: .accepted,
                                                             callID: "call-2",
                                                             recipientDeviceID: "caller-device",
                                                             senderUserID: "callee-user",
                                                             senderDeviceID: "callee-device",
                                                             timestamp: timestamp,
                                                             nonce: "nonce-2")
        let signature = try privateKey.signature(for: payload).derRepresentation.base64EncodedString()
        let control = MeshCallControl(version: 1,
                                      kind: .accepted,
                                      callID: "call-2",
                                      recipientDeviceID: "caller-device",
                                      senderUserID: "callee-user",
                                      senderDeviceID: "callee-device",
                                      publicKey: publicKeyText,
                                      keyFingerprint: fingerprint,
                                      timestamp: timestamp,
                                      nonce: "nonce-2",
                                      signature: signature)
        XCTAssertTrue(MeshCallSignaling.signatureIsValid(control))

        let expected = MeshCallControlExpectation(callID: "call-2",
                                                  localDeviceID: "caller-device",
                                                  peerUserID: "callee-user",
                                                  peerDeviceID: "callee-device",
                                                  peerKeyFingerprint: fingerprint,
                                                  peerAddress: "192.168.1.105")
        XCTAssertTrue(expected.matches(control, sourceAddress: "192.168.1.105"))
        XCTAssertFalse(expected.matches(control, sourceAddress: "192.168.1.106"))
        let wrongKey = MeshCallControlExpectation(callID: "call-2",
                                                  localDeviceID: "caller-device",
                                                  peerUserID: "callee-user",
                                                  peerDeviceID: "callee-device",
                                                  peerKeyFingerprint: "different-key",
                                                  peerAddress: "192.168.1.105")
        XCTAssertFalse(wrongKey.matches(control, sourceAddress: "192.168.1.105"))

        let tampered = MeshCallControl(version: control.version,
                                       kind: .cancelled,
                                       callID: control.callID,
                                       recipientDeviceID: control.recipientDeviceID,
                                       senderUserID: control.senderUserID,
                                       senderDeviceID: control.senderDeviceID,
                                       publicKey: control.publicKey,
                                       keyFingerprint: control.keyFingerprint,
                                       timestamp: control.timestamp,
                                       nonce: control.nonce,
                                       signature: control.signature)
        XCTAssertFalse(MeshCallSignaling.signatureIsValid(tampered))
        XCTAssertNil(try? JSONDecoder().decode(MeshCallInvite.self,
                                               from: JSONEncoder().encode(control)))
        XCTAssertEqual(MeshCallControlPolicy.sendAttempts, 3)
        XCTAssertEqual(CallRoutePolicy.automaticMeshControlGrace, 1)
        XCTAssertEqual(CallRoutePolicy.automaticAcceptedMeshTimeout, 30)
    }

    func testMeshTimestampAllowsOnlyBoundedClockSkew() {
        let now: Int64 = 1_000
        XCTAssertTrue(MeshCallTimestampPolicy.isFresh(now + 44, now: now))
        XCTAssertTrue(MeshCallTimestampPolicy.isFresh(now + 60, now: now))
        XCTAssertFalse(MeshCallTimestampPolicy.isFresh(now + 61, now: now))
        XCTAssertTrue(MeshCallTimestampPolicy.isFresh(now - 44, now: now))
        XCTAssertTrue(MeshCallTimestampPolicy.isFresh(now - 60, now: now))
        XCTAssertFalse(MeshCallTimestampPolicy.isFresh(now - 61, now: now))

        // Arithmetic remains total at Int64 boundaries.
        XCTAssertTrue(MeshCallTimestampPolicy.isFresh(Int64.max, now: Int64.max - 5))
        XCTAssertTrue(MeshCallTimestampPolicy.isFresh(Int64.min, now: Int64.min + 5))
    }

    func testMeshReplayStorePersistsAndNamespacesSignedNonces() {
        let suite = "trinet-replay-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "replay"
        let nonce = UUID().uuidString
        let first = MeshReplayStore(defaults: defaults, storageKey: key, maximumEntries: 3)
        XCTAssertTrue(first.accept(domain: "invite", senderFingerprint: "alice", nonce: nonce,
                                   timestamp: 1_000, now: 1_000, maximumSkew: 60))
        XCTAssertFalse(first.accept(domain: "invite", senderFingerprint: "alice", nonce: nonce,
                                    timestamp: 1_000, now: 1_000, maximumSkew: 60))
        XCTAssertTrue(first.accept(domain: "control", senderFingerprint: "alice", nonce: nonce,
                                   timestamp: 1_000, now: 1_000, maximumSkew: 60))
        XCTAssertTrue(first.accept(domain: "invite", senderFingerprint: "bob", nonce: nonce,
                                   timestamp: 1_000, now: 1_000, maximumSkew: 60))
        XCTAssertFalse(first.accept(domain: "invite", senderFingerprint: "carol",
                                    nonce: UUID().uuidString, timestamp: 1_000,
                                    now: 1_000, maximumSkew: 60))

        let reloaded = MeshReplayStore(defaults: defaults, storageKey: key, maximumEntries: 3)
        XCTAssertFalse(reloaded.accept(domain: "invite", senderFingerprint: "alice", nonce: nonce,
                                       timestamp: 1_000, now: 1_000, maximumSkew: 60))
        XCTAssertTrue(reloaded.accept(domain: "invite", senderFingerprint: "carol",
                                      nonce: UUID().uuidString, timestamp: 1_061,
                                      now: 1_061, maximumSkew: 60))
        XCTAssertFalse(reloaded.accept(domain: "invite", senderFingerprint: "carol",
                                       nonce: "not-a-uuid", timestamp: 1_061,
                                       now: 1_061, maximumSkew: 60))

        let signal = MeshReplayStore(defaults: defaults, storageKey: "signal")
        let text = MeshReplayStore(defaults: defaults, storageKey: "text")
        let crossUnitNonce = UUID().uuidString
        XCTAssertTrue(signal.accept(domain: "invite", senderFingerprint: "alice",
                                    nonce: crossUnitNonce, timestamp: 1_000,
                                    now: 1_000, maximumSkew: 60))
        XCTAssertTrue(text.accept(domain: "text", senderFingerprint: "alice",
                                  nonce: UUID().uuidString, timestamp: 1_000_000,
                                  now: 1_000_000, maximumSkew: 60_000))
        XCTAssertFalse(signal.accept(domain: "invite", senderFingerprint: "alice",
                                     nonce: crossUnitNonce, timestamp: 1_000,
                                     now: 1_000, maximumSkew: 60))
    }

    func testIncomingPresentationDeliveryPolicyMarksOnlyConsumedInvites() {
        XCTAssertFalse(
            IncomingCallDeliveryPolicy.shouldMarkReported(
                alreadyReported: false,
                consumedByUI: false
            )
        )
        XCTAssertTrue(
            IncomingCallDeliveryPolicy.shouldMarkReported(
                alreadyReported: false,
                consumedByUI: true
            )
        )
        XCTAssertFalse(
            IncomingCallDeliveryPolicy.shouldMarkReported(
                alreadyReported: true,
                consumedByUI: true
            )
        )
        XCTAssertFalse(
            IncomingCallDeliveryPolicy.shouldRetryAfterPresentation(
                succeeded: true
            )
        )
        XCTAssertTrue(
            IncomingCallDeliveryPolicy.shouldRetryAfterPresentation(
                succeeded: false
            )
        )
    }

    func testInternetRemoteDepartureEndsOnlyInternetCall() {
        XCTAssertTrue(
            InternetCallLifecyclePolicy.shouldEndAfterRemoteDeparture(
                activeRoute: .internet
            )
        )
        XCTAssertFalse(
            InternetCallLifecyclePolicy.shouldEndAfterRemoteDeparture(
                activeRoute: .mesh
            )
        )
        XCTAssertFalse(
            InternetCallLifecyclePolicy.shouldEndAfterRemoteDeparture(
                activeRoute: nil
            )
        )
    }

    func testOutgoingDisconnectCancelsRingingAndEndsAnsweredCall() {
        XCTAssertFalse(
            InternetCallLifecyclePolicy.shouldEndOutgoingOnDisconnect(
                hasRemoteParticipant: false,
                lastServerStatus: "ringing",
                state: .ringing)
        )
        XCTAssertTrue(
            InternetCallLifecyclePolicy.shouldEndOutgoingOnDisconnect(
                hasRemoteParticipant: false,
                lastServerStatus: "active",
                state: .ringing)
        )
        XCTAssertTrue(
            InternetCallLifecyclePolicy.shouldEndOutgoingOnDisconnect(
                hasRemoteParticipant: true,
                lastServerStatus: nil,
                state: .connected)
        )
        XCTAssertTrue(
            InternetCallLifecyclePolicy.shouldEndOutgoingOnDisconnect(
                hasRemoteParticipant: false,
                lastServerStatus: nil,
                state: .reconnecting)
        )
    }

    func testStopAfterAcceptedBuildsPeerCancellationTarget() {
        let outbound = MeshCallControlExpectation(
            callID: "outgoing-call",
            localDeviceID: "caller-device",
            peerUserID: "callee-user",
            peerDeviceID: "callee-device",
            peerKeyFingerprint: "callee-key",
            peerAddress: "192.168.1.105"
        )
        XCTAssertEqual(
            MeshCallCancellationPolicy.target(
                outbound: outbound,
                outboundPort: 7101,
                inbound: nil
            ),
            MeshCallCancellationTarget(
                callID: "outgoing-call",
                recipientDeviceID: "callee-device",
                address: "192.168.1.105",
                port: 7101
            )
        )

        let invite = MeshCallInvite(
            version: 1,
            callID: "incoming-call",
            nickname: "caller",
            displayName: "Caller",
            userID: "caller-user",
            deviceID: "caller-device",
            publicKey: "caller-public-key",
            keyFingerprint: "caller-key",
            mediaPort: 7000,
            timestamp: 100,
            nonce: "incoming-nonce",
            signature: "incoming-signature"
        )
        let incoming = IncomingMeshCall(
            invite: invite,
            sourceAddress: "192.168.1.110",
            receivedAt: 100
        )
        XCTAssertEqual(
            MeshCallCancellationPolicy.target(
                outbound: nil,
                outboundPort: nil,
                inbound: incoming
            ),
            MeshCallCancellationTarget(
                callID: "incoming-call",
                recipientDeviceID: "caller-device",
                address: "192.168.1.110",
                port: nil
            )
        )
        XCTAssertNil(
            MeshCallCancellationPolicy.target(
                outbound: nil,
                outboundPort: nil,
                inbound: nil
            )
        )
    }

    #if DEBUG
    func testPhysicalE2ELaunchArgumentsAreStrictAndDeterministic() {
        let parsed = DebugPhysicalE2EPlan.parse(arguments: [
            "TriNetVideo",
            "--trinet-e2e-run", "mesh-audio-001",
            "--trinet-e2e-role", "callee",
            "--trinet-e2e-peer", "iPhone17",
            "--trinet-e2e-media", "audio",
            "--trinet-e2e-auto-accept",
            "--trinet-e2e-chat", "CHAT-mesh-audio-001",
            "--trinet-e2e-timeout", "40"
        ])
        guard case .enabled(let plan) = parsed else {
            return XCTFail("Expected a valid physical E2E plan")
        }
        XCTAssertEqual(plan.runID, "mesh-audio-001")
        XCTAssertEqual(plan.role, .callee)
        XCTAssertEqual(plan.media, .audioOnly)
        XCTAssertEqual(plan.timeout, 40)
        XCTAssertTrue(plan.autoAccept)
        XCTAssertTrue(plan.matchesPeer(nickname: "iphone17_54af19", displayName: "iPhone17"))
        XCTAssertTrue(plan.matchesChatSender("iphone17_54af19"))

        XCTAssertEqual(
            DebugPhysicalE2EPlan.parse(arguments: ["TriNetVideo"]),
            .disabled
        )
        XCTAssertEqual(
            DebugPhysicalE2EPlan.parse(arguments: [
                "TriNetVideo",
                "--trinet-e2e-run", "bad run",
                "--trinet-e2e-role", "caller",
                "--trinet-e2e-peer", "iPhone13",
                "--trinet-e2e-media", "video"
            ]),
            .invalid("invalid_run")
        )
        XCTAssertEqual(
            DebugPhysicalE2EPlan.parse(arguments: [
                "TriNetVideo",
                "--trinet-e2e-run", "mesh-video-001",
                "--trinet-e2e-role", "caller",
                "--trinet-e2e-peer", "iPhone13",
                "--trinet-e2e-media", "video",
                "--trinet-e2e-auto-accept"
            ]),
            .invalid("caller_cannot_auto_accept")
        )
    }

    func testPhysicalE2EResultRequiresAuthenticatedMediaAndTrueAudioOnly() {
        guard case .enabled(let audioPlan) = DebugPhysicalE2EPlan.parse(arguments: [
            "TriNetVideo",
            "--trinet-e2e-run", "mesh-audio-002",
            "--trinet-e2e-role", "callee",
            "--trinet-e2e-peer", "iPhone17",
            "--trinet-e2e-media", "audio",
            "--trinet-e2e-auto-accept",
            "--trinet-e2e-chat", "CHAT-mesh-audio-002"
        ]) else {
            return XCTFail("Expected an audio plan")
        }
        XCTAssertTrue(DebugPhysicalE2EResultPolicy.passes(
            plan: audioPlan,
            isLive: true,
            isMeshRoute: true,
            activeMedia: .audioOnly,
            signedSignalComplete: true,
            audioPacketsReceived: 3,
            framesSent: 0,
            framesReceived: 0,
            cameraOff: true,
            chatReceived: true
        ))
        XCTAssertFalse(DebugPhysicalE2EResultPolicy.passes(
            plan: audioPlan,
            isLive: true,
            isMeshRoute: true,
            activeMedia: .audioOnly,
            signedSignalComplete: true,
            audioPacketsReceived: 3,
            framesSent: 1,
            framesReceived: 0,
            cameraOff: true,
            chatReceived: true
        ))
        XCTAssertFalse(DebugPhysicalE2EResultPolicy.passes(
            plan: audioPlan,
            isLive: true,
            isMeshRoute: true,
            activeMedia: .audioOnly,
            signedSignalComplete: true,
            audioPacketsReceived: 3,
            framesSent: 0,
            framesReceived: 0,
            cameraOff: true,
            chatReceived: false
        ))
    }
    #endif
}
