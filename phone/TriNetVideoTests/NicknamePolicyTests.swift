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

    func testMeshInviteIdentityMustMatchLiveSignedContactKeyAndAddress() {
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

    func testForegroundGroupChatPushDoesNotPlayDuplicateSystemSound() {
        XCTAssertFalse(
            AlertPresentationPolicy.shouldPlaySystemSound(
                userInfo: ["type": "group_chat_message"]
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
        XCTAssertTrue(incoming.isFresh(at: timestamp + 8))
        XCTAssertFalse(incoming.isFresh(at: timestamp + 9))
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

    func testBusyUILeavesInternetInvitePendingForRetry() {
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
