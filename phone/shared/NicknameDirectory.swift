import Combine
import CryptoKit
import Darwin
import Foundation

enum NicknameClaimKind: String, Codable {
    case none
    case meshLocal = "mesh-local"
    case verified
}

enum NicknamePolicy {
    static let minimumLength = 3
    static let maximumLength = 20

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validationError(_ value: String) -> String? {
        let nickname = normalize(value)
        guard (minimumLength...maximumLength).contains(nickname.count) else {
            return "Use 3 to 20 characters."
        }
        guard nickname.first?.isASCII == true,
              nickname.first?.isLetter == true else {
            return "The first character must be a letter."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard nickname.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Use lowercase letters, numbers, and underscore only."
        }
        return nil
    }

    static func isConfusing(_ candidate: String, with existing: String) -> Bool {
        let lhs = normalize(candidate)
        let rhs = normalize(existing)
        if lhs == rhs { return true }
        let distance = editDistance(lhs, rhs)
        if distance <= 1 { return true }
        return commonPrefixLength(lhs, rhs) >= 4 && distance == 2
    }

    static func suggestions(for value: String,
                            excluding existing: [String],
                            seed: String) -> [String] {
        var base = normalize(value).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        if base.first?.isLetter != true { base = "user_" + base }
        if base.count < minimumLength { base += "net" }
        base = String(base.prefix(maximumLength - 3))
        let suffixSeed = seed.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 997 }
        let existingNames = existing.map(normalize)
        return (0..<20).compactMap { offset in
            let suffix = String(format: "%03d", (suffixSeed + offset * 37) % 1000)
            let proposal = String(base.prefix(maximumLength - suffix.count)) + suffix
            return existingNames.contains(where: { isConfusing(proposal, with: $0) }) ? nil : proposal
        }.prefix(3).map { $0 }
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix(while: { $0 == $1 }).count
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }
}

enum NicknameMigrationPolicy {
    static func candidate(currentNickname: String?,
                          displayName: String,
                          deviceID: String) -> String? {
        if let currentNickname,
           !NicknamePolicy.normalize(currentNickname).isEmpty {
            return nil
        }
        var base = NicknamePolicy.normalize(displayName).filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")
        }
        if base.first?.isLetter != true { base = "user_" + base }
        if base.count < NicknamePolicy.minimumLength { base += "net" }
        let suffix = String(deviceID.lowercased().filter { $0.isHexDigit }.prefix(6))
        guard suffix.count == 6 else { return nil }
        let maximumBase = NicknamePolicy.maximumLength - suffix.count - 1
        let migrated = String(base.prefix(maximumBase)) + "_" + suffix
        return NicknamePolicy.validationError(migrated) == nil ? migrated : nil
    }
}

struct NicknameClaimRequest: Encodable {
    let nickname: String
    let userID: String
    let deviceID: String
}

struct NicknameClaimResponse: Decodable {
    let claimed: Bool
    let normalized: String
    let reason: String?
    let suggestions: [String]
}

struct NicknameSearchRequest: Encodable {
    let query: String
    let limit: Int
}

private struct InternetDirectoryContact: Decodable {
    let userID: String
    let deviceID: String
    let nickname: String
    let displayName: String?
    let keyFingerprint: String
    let online: Bool

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case nickname
        case displayName = "display_name"
        case keyFingerprint = "key_fingerprint"
        case online
    }
}

struct NicknameSearchResponse: Decodable {
    fileprivate let results: [InternetDirectoryContact]
}

enum DirectorySource: String, Codable {
    case mesh = "LOCAL"
    case internet = "INTERNET"
}

struct DirectoryContact: Identifiable, Equatable {
    let userID: String
    let deviceID: String
    let nickname: String
    let displayName: String
    let keyFingerprint: String
    let source: DirectorySource
    let online: Bool
    let meshAddress: String?
    let meshPort: UInt16?
    let signingPublicKey: String?
    let textEncryptionPublicKey: String?
    let meshAddresses: [String]

    init(userID: String,
         deviceID: String,
         nickname: String,
         displayName: String,
         keyFingerprint: String,
         source: DirectorySource,
         online: Bool,
         meshAddress: String?,
         meshPort: UInt16?,
         signingPublicKey: String? = nil,
         textEncryptionPublicKey: String? = nil,
         meshAddresses: [String] = []) {
        self.userID = userID
        self.deviceID = deviceID
        self.nickname = nickname
        self.displayName = displayName
        self.keyFingerprint = keyFingerprint
        self.source = source
        self.online = online
        self.meshAddress = meshAddress
        self.meshPort = meshPort
        self.signingPublicKey = signingPublicKey
        self.textEncryptionPublicKey = textEncryptionPublicKey
        self.meshAddresses = meshAddresses
    }

    var id: String { "\(source.rawValue):\(deviceID)" }
}

enum DirectoryResultPolicy {
    static func merge(mesh: [DirectoryContact],
                      internet: [DirectoryContact],
                      query: String) -> [DirectoryContact] {
        let normalizedQuery = NicknamePolicy.normalize(query)
        func matches(_ contact: DirectoryContact) -> Bool {
            normalizedQuery.isEmpty ||
                NicknamePolicy.normalize(contact.nickname).contains(normalizedQuery) ||
                NicknamePolicy.normalize(contact.displayName).contains(normalizedQuery)
        }

        let matchingMesh = mesh.filter(matches)
        let matchingInternet = internet.filter(matches)
        let candidates = [
            matchingMesh.filter(\.online),
            matchingInternet.filter(\.online),
            matchingMesh.filter { !$0.online },
            matchingInternet.filter { !$0.online }
        ]
        var selected: [DirectoryContact] = []
        var selectedDeviceIDs = Set<String>()
        for rankedCandidates in candidates {
            for contact in rankedCandidates where selectedDeviceIDs.insert(contact.deviceID).inserted {
                selected.append(contact)
            }
        }
        return selected.sorted {
            if $0.nickname != $1.nickname { return $0.nickname < $1.nickname }
            if $0.online != $1.online { return $0.online && !$1.online }
            return $0.deviceID < $1.deviceID
        }
    }
}

private struct MeshPeer: Equatable {
    let serviceName: String
    let userID: String
    let deviceID: String
    let nickname: String
    let displayName: String
    let keyFingerprint: String
    let signingPublicKey: String
    let textEncryptionPublicKey: String
    let address: String
    let addresses: [String]
    let port: UInt16
}

private struct CachedMeshPeer: Codable {
    let userID: String
    let deviceID: String
    let nickname: String
    let displayName: String
    let keyFingerprint: String
    let signingPublicKey: String?
    let textEncryptionPublicKey: String?
    let address: String
    let port: UInt16
    let lastSeen: Int64
}

struct MeshCallInvite: Codable, Identifiable, Equatable {
    let version: UInt8
    let callID: String
    let nickname: String
    let displayName: String
    let userID: String
    let deviceID: String
    let publicKey: String
    let keyFingerprint: String
    let mediaPort: UInt16
    let media: InternetCallMedia
    let timestamp: Int64
    let nonce: String
    let signature: String

    var id: String { callID }

    init(version: UInt8,
         callID: String,
         nickname: String,
         displayName: String,
         userID: String,
         deviceID: String,
         publicKey: String,
         keyFingerprint: String,
         mediaPort: UInt16,
         media: InternetCallMedia = .audioVideo,
         timestamp: Int64,
         nonce: String,
         signature: String) {
        self.version = version
        self.callID = callID
        self.nickname = nickname
        self.displayName = displayName
        self.userID = userID
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.keyFingerprint = keyFingerprint
        self.mediaPort = mediaPort
        self.media = media
        self.timestamp = timestamp
        self.nonce = nonce
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case callID
        case nickname
        case displayName
        case userID
        case deviceID
        case publicKey
        case keyFingerprint
        case mediaPort
        case media
        case timestamp
        case nonce
        case signature
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(UInt8.self, forKey: .version)
        callID = try values.decode(String.self, forKey: .callID)
        nickname = try values.decode(String.self, forKey: .nickname)
        displayName = try values.decode(String.self, forKey: .displayName)
        userID = try values.decode(String.self, forKey: .userID)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        publicKey = try values.decode(String.self, forKey: .publicKey)
        keyFingerprint = try values.decode(String.self, forKey: .keyFingerprint)
        mediaPort = try values.decode(UInt16.self, forKey: .mediaPort)
        // Version 1 had one fixed meaning: microphone + camera. Ignore an
        // injected media field because the v1 signature did not cover it.
        if version == 1 {
            media = .audioVideo
        } else {
            media = try values.decode(InternetCallMedia.self, forKey: .media)
        }
        timestamp = try values.decode(Int64.self, forKey: .timestamp)
        nonce = try values.decode(String.self, forKey: .nonce)
        signature = try values.decode(String.self, forKey: .signature)
    }
}

enum MeshCallControlKind: String, Codable {
    case accepted
    case cancelled
}

struct MeshCallControl: Codable, Equatable {
    let version: UInt8
    let kind: MeshCallControlKind
    let callID: String
    let recipientDeviceID: String
    let senderUserID: String
    let senderDeviceID: String
    let publicKey: String
    let keyFingerprint: String
    let timestamp: Int64
    let nonce: String
    let signature: String
}

struct MeshCallControlExpectation: Equatable {
    let callID: String
    let localDeviceID: String
    let peerUserID: String
    let peerDeviceID: String
    let peerKeyFingerprint: String
    let peerAddress: String

    func matches(_ control: MeshCallControl, sourceAddress: String) -> Bool {
        control.callID == callID &&
            control.recipientDeviceID == localDeviceID &&
            control.senderUserID == peerUserID &&
            control.senderDeviceID == peerDeviceID &&
            control.keyFingerprint == peerKeyFingerprint &&
            sourceAddress == peerAddress
    }
}

struct MeshCallCancellationTarget: Equatable {
    let callID: String
    let recipientDeviceID: String
    let address: String
    let port: UInt16?
}

enum MeshCallCancellationPolicy {
    static func target(outbound: MeshCallControlExpectation?,
                       outboundPort: UInt16?,
                       inbound: IncomingMeshCall?) -> MeshCallCancellationTarget? {
        if let outbound {
            return MeshCallCancellationTarget(
                callID: outbound.callID,
                recipientDeviceID: outbound.peerDeviceID,
                address: outbound.peerAddress,
                port: outboundPort
            )
        }
        guard let inbound else { return nil }
        return MeshCallCancellationTarget(
            callID: inbound.invite.callID,
            recipientDeviceID: inbound.invite.deviceID,
            address: inbound.sourceAddress,
            port: nil
        )
    }
}

enum MeshCallControlPolicy {
    static let sendAttempts = 3
}

enum MeshCallTimestampPolicy {
    // Physical-device clocks can be tens of seconds apart even while both
    // devices are online. Replay protection is provided separately by the
    // persisted signed-message nonce ring, so keep a bounded symmetric window
    // that covers the measured 44-second peer-to-peer skew.
    static let maxPastAge: Int64 = 60
    static let maxFutureSkew: Int64 = 60

    static func isFresh(_ timestamp: Int64, now: Int64) -> Bool {
        if timestamp > now {
            let (latest, overflow) = now.addingReportingOverflow(maxFutureSkew)
            return overflow || timestamp <= latest
        }
        let (earliest, overflow) = now.subtractingReportingOverflow(maxPastAge)
        return overflow || timestamp >= earliest
    }
}

struct IncomingMeshCall: Identifiable, Equatable {
    let invite: MeshCallInvite
    let sourceAddress: String
    let expiresAt: Int64

    init(invite: MeshCallInvite,
         sourceAddress: String,
         receivedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.invite = invite
        self.sourceAddress = sourceAddress
        expiresAt = receivedAt + Int64(CallRoutePolicy.automaticMeshProbeTimeout)
    }

    var id: String { invite.callID }

    func isFresh(at now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        now <= expiresAt
    }

    func controlExpectation(localDeviceID: String) -> MeshCallControlExpectation {
        MeshCallControlExpectation(callID: invite.callID,
                                   localDeviceID: localDeviceID,
                                   peerUserID: invite.userID,
                                   peerDeviceID: invite.deviceID,
                                   peerKeyFingerprint: invite.keyFingerprint,
                                   peerAddress: sourceAddress)
    }
}

struct MeshTextMessage: Equatable {
    let id: String
    let senderNickname: String
    let senderUserID: String
    let senderDeviceID: String
    let senderSigningPublicKey: String
    let senderKeyFingerprint: String
    let recipientDeviceID: String
    let text: String
    let timestamp: Int64
}

enum MeshTextIdentityPolicy {
    static func matches(_ message: MeshTextMessage,
                        contact: DirectoryContact,
                        sourceAddress: String) -> Bool {
        contact.online &&
            contact.source == .mesh &&
            contact.deviceID == message.senderDeviceID &&
            contact.userID == message.senderUserID &&
            NicknamePolicy.normalize(contact.nickname) == message.senderNickname &&
            contact.signingPublicKey == message.senderSigningPublicKey &&
            contact.keyFingerprint == message.senderKeyFingerprint &&
            (contact.meshAddress == sourceAddress || contact.meshAddresses.contains(sourceAddress))
    }
}

enum MeshInviteIdentityPolicy {
    static func matches(_ invite: MeshCallInvite,
                        contact: DirectoryContact,
                        sourceAddress: String) -> Bool {
        contact.online &&
            contact.source == .mesh &&
            contact.deviceID == invite.deviceID &&
            contact.userID == invite.userID &&
            NicknamePolicy.normalize(contact.nickname) == NicknamePolicy.normalize(invite.nickname) &&
            contact.signingPublicKey == invite.publicKey &&
            contact.keyFingerprint == invite.keyFingerprint &&
            (contact.meshAddress == sourceAddress || contact.meshAddresses.contains(sourceAddress)) &&
            contact.meshPort == MeshCallSignaling.port
    }
}

private struct MeshTextIdentityPin: Codable, Equatable {
    let deviceID: String
    let signingPublicKey: String
    let keyFingerprint: String
    let textEncryptionPublicKey: String
}

final class MeshTextIdentityPinStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private var pins: [String: MeshTextIdentityPin]

    init(defaults: UserDefaults = .standard,
         storageKey: String = "trinet.mesh.text.identity-pins.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: MeshTextIdentityPin].self, from: data) {
            pins = saved
        } else {
            pins = [:]
        }
    }

    func accept(_ contact: DirectoryContact) -> Bool {
        let nickname = NicknamePolicy.normalize(contact.nickname)
        guard !nickname.isEmpty,
              let signingPublicKey = contact.signingPublicKey,
              DeviceIdentityStore.fingerprint(for: signingPublicKey) == contact.keyFingerprint,
              let encryptionPublicKey = contact.textEncryptionPublicKey,
              let encryptionData = Data(base64Encoded: encryptionPublicKey),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encryptionData)) != nil else {
            return false
        }
        let proposed = MeshTextIdentityPin(deviceID: contact.deviceID,
                                           signingPublicKey: signingPublicKey,
                                           keyFingerprint: contact.keyFingerprint,
                                           textEncryptionPublicKey: encryptionPublicKey)
        if let pinned = pins[nickname] { return pinned == proposed }
        pins[nickname] = proposed
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: storageKey) }
        return true
    }
}

private struct MeshReplayEntry: Codable, Equatable {
    let id: String
    let timestamp: Int64
}

final class MeshReplayStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumEntries: Int
    private var entries: [MeshReplayEntry]

    init(defaults: UserDefaults = .standard,
         storageKey: String,
         maximumEntries: Int = 4_096) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumEntries = maximumEntries
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([MeshReplayEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    func accept(domain: String,
                senderFingerprint: String,
                nonce: String,
                timestamp: Int64,
                now: Int64,
                maximumSkew: Int64) -> Bool {
        guard UUID(uuidString: nonce) != nil,
              !senderFingerprint.isEmpty,
              maximumSkew > 0 else { return false }
        let id = [domain, senderFingerprint, nonce.lowercased()].joined(separator: "|")
        entries.removeAll { entry in
            guard entry.timestamp <= now else { return false }
            let (expiry, overflow) = entry.timestamp.addingReportingOverflow(maximumSkew)
            return !overflow && expiry < now
        }
        guard !entries.contains(where: { $0.id == id }) else { return false }
        // Never evict a still-fresh nonce: fail closed under a signed flood.
        guard entries.count < maximumEntries else { return false }
        entries.append(MeshReplayEntry(id: id, timestamp: timestamp))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
        return true
    }
}

enum MeshContactSelectionPolicy {
    static func uniqueActive(_ contacts: [DirectoryContact], named name: String) -> DirectoryContact? {
        let target = NicknamePolicy.normalize(name)
        guard !target.isEmpty else { return nil }
        let matches = contacts.filter {
            $0.online && $0.source == .mesh &&
                (NicknamePolicy.normalize($0.nickname) == target ||
                 NicknamePolicy.normalize($0.displayName) == target)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

enum MeshTextEnvelope {
    static let magic = Data([0xFD, 0x13])
    static let version: UInt8 = 1
    static let maximumWireBytes = 1_200
    static let maximumTextBytes = 768
    static let maximumSkewMilliseconds: Int64 = 60_000

    private static let headerLength = 2 + 1 + 16 + 32
    private static let keyIDLength = 16
    private static let signatureLengthField = 2
    private static let salt = Data(SHA256.hash(data: Data("tri-net/mesh-text/v1/salt".utf8)))
    private static let keyDomain = Data("tri-net/mesh-text/v1/key\0".utf8)
    private static let signatureDomain = Data("tri-net/mesh-text/v1/signature\0".utf8)

    static func clamp(_ text: String, maximumBytes: Int = maximumTextBytes) -> String {
        var result = ""
        var count = 0
        for character in text {
            let piece = String(character)
            guard let bytes = piece.data(using: .utf8), count + bytes.count <= maximumBytes else { break }
            result.append(character)
            count += bytes.count
        }
        return result
    }

    static func seal(text: String,
                     sender: DeviceIdentity,
                     recipient: DirectoryContact,
                     timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
                     nonce: UUID = UUID(),
                     ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey = .init(),
                     sign: (Data) throws -> String = DeviceIdentityStore.shared.signMessage) -> Data? {
        let senderNickname = NicknamePolicy.normalize(sender.nickname ?? "")
        let cleanText = clamp(text)
        guard !senderNickname.isEmpty,
              !cleanText.isEmpty,
              let recipientIdentity = recipient.signingPublicKey,
              let recipientIdentityData = Data(base64Encoded: recipientIdentity),
              DeviceIdentityStore.fingerprint(for: recipientIdentity) == recipient.keyFingerprint,
              let recipientKeyText = recipient.textEncryptionPublicKey,
              let recipientKeyData = Data(base64Encoded: recipientKeyText),
              let recipientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientKeyData),
              let shared = try? ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientKey) else {
            return nil
        }

        let keyID = recipientKeyID(identityPublicKey: recipientIdentityData,
                                   encryptionPublicKey: recipientKeyData)
        var header = magic
        header.append(version)
        header.append(keyID)
        header.append(ephemeralPrivateKey.publicKey.rawRepresentation)

        guard let body = canonicalBody(senderNickname: senderNickname,
                                       senderUserID: sender.userID,
                                       senderDeviceID: sender.deviceID,
                                       senderPublicKey: sender.signingPublicKey,
                                       recipientDeviceID: recipient.deviceID,
                                       timestamp: timestamp,
                                       nonce: nonce.uuidString.lowercased(),
                                       text: cleanText),
              let signatureText = try? sign(signaturePayload(header: header, body: body)),
              let signature = Data(base64Encoded: signatureText),
              signature.count <= Int(UInt16.max) else { return nil }

        var plaintext = body
        appendUInt16(UInt16(signature.count), to: &plaintext)
        plaintext.append(signature)
        let key = deriveKey(shared: shared, header: header,
                            recipientIdentityPublicKey: recipientIdentityData,
                            recipientEncryptionPublicKey: recipientKeyData)
        guard let box = try? ChaChaPoly.seal(plaintext, using: key, authenticating: header) else { return nil }
        var wire = header
        wire.append(box.combined)
        return wire.count <= maximumWireBytes ? wire : nil
    }

    static func open(_ wire: Data,
                     recipient: DeviceIdentity,
                     recipientPrivateKey: Curve25519.KeyAgreement.PrivateKey,
                     nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> MeshTextMessage? {
        guard wire.count > headerLength + 28 + signatureLengthField,
              wire.count <= maximumWireBytes,
              wire.prefix(2) == magic,
              wire[2] == version,
              let recipientIdentityData = Data(base64Encoded: recipient.signingPublicKey),
              DeviceIdentityStore.fingerprint(for: recipient.signingPublicKey) == recipient.keyFingerprint else {
            return nil
        }
        let recipientEncryptionPublicKey = recipientPrivateKey.publicKey.rawRepresentation
        let expectedKeyID = recipientKeyID(identityPublicKey: recipientIdentityData,
                                           encryptionPublicKey: recipientEncryptionPublicKey)
        guard Data(wire[3..<(3 + keyIDLength)]) == expectedKeyID,
              let ephemeralKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: Data(wire[(3 + keyIDLength)..<headerLength])),
              let shared = try? recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralKey),
              let box = try? ChaChaPoly.SealedBox(combined: wire.dropFirst(headerLength)) else {
            return nil
        }
        let header = Data(wire.prefix(headerLength))
        let key = deriveKey(shared: shared, header: header,
                            recipientIdentityPublicKey: recipientIdentityData,
                            recipientEncryptionPublicKey: recipientEncryptionPublicKey)
        guard let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: header),
              let parsed = parsePlaintext(plaintext),
              parsed.recipientDeviceID == recipient.deviceID,
              isFresh(parsed.timestamp, now: nowMilliseconds),
              DeviceIdentityStore.fingerprint(for: parsed.senderPublicKey) == parsed.senderFingerprint,
              DeviceIdentityStore.verifyMessage(signaturePayload(header: header, body: parsed.body),
                                                signature: parsed.signature.base64EncodedString(),
                                                publicKey: parsed.senderPublicKey) else { return nil }
        return MeshTextMessage(id: parsed.nonce,
                               senderNickname: parsed.senderNickname,
                               senderUserID: parsed.senderUserID,
                               senderDeviceID: parsed.senderDeviceID,
                               senderSigningPublicKey: parsed.senderPublicKey,
                               senderKeyFingerprint: parsed.senderFingerprint,
                               recipientDeviceID: parsed.recipientDeviceID,
                               text: parsed.text,
                               timestamp: parsed.timestamp)
    }

    static func isFresh(_ timestamp: Int64, now: Int64) -> Bool {
        guard timestamp != 0 else { return false }
        if timestamp > now {
            let (latest, overflow) = now.addingReportingOverflow(maximumSkewMilliseconds)
            return overflow || timestamp <= latest
        }
        let (earliest, overflow) = now.subtractingReportingOverflow(maximumSkewMilliseconds)
        return overflow || timestamp >= earliest
    }

    private struct ParsedPlaintext {
        let senderNickname: String
        let senderUserID: String
        let senderDeviceID: String
        let senderPublicKey: String
        let senderFingerprint: String
        let recipientDeviceID: String
        let timestamp: Int64
        let nonce: String
        let text: String
        let body: Data
        let signature: Data
    }

    private static func canonicalBody(senderNickname: String,
                                      senderUserID: String,
                                      senderDeviceID: String,
                                      senderPublicKey: String,
                                      recipientDeviceID: String,
                                      timestamp: Int64,
                                      nonce: String,
                                      text: String) -> Data? {
        let senderFingerprint = DeviceIdentityStore.fingerprint(for: senderPublicKey) ?? ""
        let fields = [senderNickname, senderUserID, senderDeviceID, senderPublicKey,
                      senderFingerprint, recipientDeviceID, nonce, text]
        guard !senderNickname.isEmpty,
              !senderUserID.isEmpty,
              !senderDeviceID.isEmpty,
              !senderPublicKey.isEmpty,
              !senderFingerprint.isEmpty,
              !recipientDeviceID.isEmpty,
              UUID(uuidString: nonce) != nil,
              !text.isEmpty,
              text.utf8.count <= maximumTextBytes,
              fields.allSatisfy({ $0.utf8.count <= Int(UInt16.max) }) else { return nil }
        var body = Data()
        appendString(senderNickname, to: &body)
        appendString(senderUserID, to: &body)
        appendString(senderDeviceID, to: &body)
        appendString(senderPublicKey, to: &body)
        appendString(senderFingerprint, to: &body)
        appendString(recipientDeviceID, to: &body)
        appendInt64(timestamp, to: &body)
        appendString(nonce, to: &body)
        appendString(text, to: &body)
        return body
    }

    private static func parsePlaintext(_ plaintext: Data) -> ParsedPlaintext? {
        var offset = 0
        guard let senderNickname = readString(plaintext, offset: &offset),
              NicknamePolicy.normalize(senderNickname) == senderNickname,
              NicknamePolicy.validationError(senderNickname) == nil,
              let senderUserID = readString(plaintext, offset: &offset),
              let senderDeviceID = readString(plaintext, offset: &offset),
              let senderPublicKey = readString(plaintext, offset: &offset),
              let senderFingerprint = readString(plaintext, offset: &offset),
              let recipientDeviceID = readString(plaintext, offset: &offset),
              let timestamp = readInt64(plaintext, offset: &offset),
              let nonce = readString(plaintext, offset: &offset), UUID(uuidString: nonce) != nil,
              let text = readString(plaintext, offset: &offset), !text.isEmpty,
              text.utf8.count <= maximumTextBytes else { return nil }
        let body = Data(plaintext.prefix(offset))
        guard let signatureLength = readUInt16(plaintext, offset: &offset),
              Int(signatureLength) == plaintext.count - offset else { return nil }
        let signature = Data(plaintext[offset...])
        return ParsedPlaintext(senderNickname: senderNickname,
                               senderUserID: senderUserID,
                               senderDeviceID: senderDeviceID,
                               senderPublicKey: senderPublicKey,
                               senderFingerprint: senderFingerprint,
                               recipientDeviceID: recipientDeviceID,
                               timestamp: timestamp,
                               nonce: nonce,
                               text: text,
                               body: body,
                               signature: signature)
    }

    private static func recipientKeyID(identityPublicKey: Data,
                                       encryptionPublicKey: Data) -> Data {
        var input = Data("tri-net/mesh-text/v1/recipient\0".utf8)
        input.append(identityPublicKey)
        input.append(encryptionPublicKey)
        return Data(SHA256.hash(data: input).prefix(keyIDLength))
    }

    private static func deriveKey(shared: SharedSecret,
                                  header: Data,
                                  recipientIdentityPublicKey: Data,
                                  recipientEncryptionPublicKey: Data) -> SymmetricKey {
        var info = keyDomain
        info.append(header)
        info.append(recipientIdentityPublicKey)
        info.append(recipientEncryptionPublicKey)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: salt,
                                              sharedInfo: info,
                                              outputByteCount: 32)
    }

    private static func signaturePayload(header: Data, body: Data) -> Data {
        var result = signatureDomain
        result.append(header)
        result.append(body)
        return result
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF))
    }

    private static func appendInt64(_ value: Int64, to data: inout Data) {
        let bits = UInt64(bitPattern: value)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bits >> UInt64(shift)) & 0xFF))
        }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendUInt16(UInt16(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func readUInt16(_ data: Data, offset: inout Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    private static func readInt64(_ data: Data, offset: inout Int) -> Int64? {
        guard offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] { value = (value << 8) | UInt64(byte) }
        offset += 8
        return Int64(bitPattern: value)
    }

    private static func readString(_ data: Data, offset: inout Int) -> String? {
        guard let length = readUInt16(data, offset: &offset),
              offset + Int(length) <= data.count else { return nil }
        let value = String(data: data[offset..<(offset + Int(length))], encoding: .utf8)
        offset += Int(length)
        return value
    }
}

enum MeshCallSignalingError: LocalizedError {
    case invalidAddress
    case missingIdentity
    case unsupportedMedia
    case textIdentityChanged
    case socketFailure(Int32, String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "The local peer address is invalid."
        case .missingIdentity:
            return "Create a nickname before placing a local call."
        case .unsupportedMedia:
            return "Local mesh calls currently require audio."
        case .textIdentityChanged:
            return "The signed encrypted-chat identity for this nickname changed."
        case let .socketFailure(code, address):
            return "Cannot reach \(address) on the local mesh: \(String(cString: strerror(code))) (errno \(code))."
        }
    }
}

final class MeshCallSignaling {
    static let port: UInt16 = 7001
    static let mediaPort: UInt16 = 7000

    var onInvite: ((MeshCallInvite, String) -> Void)?
    var onControl: ((MeshCallControl, String) -> Void)?
    var onText: ((MeshTextMessage, String) -> Void)?

    private var fd: Int32 = -1
    private var running = false
    private var identity: DeviceIdentity
    private let receiveQueue = DispatchQueue(label: "trinet.mesh.signal", qos: .userInitiated)
    private lazy var signalReplay = MeshReplayStore(
        storageKey: "trinet.mesh.signal.seen.v2.\(identity.deviceID)"
    )
    private lazy var textReplay = MeshReplayStore(
        storageKey: "trinet.mesh.text.seen.v2.\(identity.deviceID)"
    )

    init(identity: DeviceIdentity) {
        self.identity = identity
    }

    func update(identity: DeviceIdentity) {
        self.identity = identity
    }

    func start() {
        guard fd < 0 else { return }
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return }
        var enabled: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(socketFD)
            return
        }
        fd = socketFD
        running = true
        receiveQueue.async { [weak self] in self?.receiveLoop(socketFD) }
    }

    func stop() {
        running = false
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            fd = -1
        }
    }

    func sendInvite(to address: String,
                    port: UInt16 = MeshCallSignaling.port,
                    media: InternetCallMedia = .audioVideo) throws -> MeshCallInvite {
        guard let nickname = identity.nickname, NicknamePolicy.validationError(nickname) == nil else {
            throw MeshCallSignalingError.missingIdentity
        }
        guard media.audio else { throw MeshCallSignalingError.unsupportedMedia }
        let callID = UUID().uuidString.lowercased()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.lowercased()
        let version = Self.protocolVersion(for: media)
        let payload = version == 1
            ? Self.signedPayload(callID: callID,
                                 nickname: nickname,
                                 displayName: identity.displayName,
                                 userID: identity.userID,
                                 deviceID: identity.deviceID,
                                 mediaPort: Self.mediaPort,
                                 timestamp: timestamp,
                                 nonce: nonce)
            : Self.signedPayloadV2(callID: callID,
                                   nickname: nickname,
                                   displayName: identity.displayName,
                                   userID: identity.userID,
                                   deviceID: identity.deviceID,
                                   mediaPort: Self.mediaPort,
                                   media: media,
                                   timestamp: timestamp,
                                   nonce: nonce)
        let signature = try DeviceIdentityStore.shared.signMessage(payload)
        let invite = MeshCallInvite(version: version,
                                    callID: callID,
                                    nickname: nickname,
                                    displayName: identity.displayName,
                                    userID: identity.userID,
                                    deviceID: identity.deviceID,
                                    publicKey: identity.signingPublicKey,
                                    keyFingerprint: identity.keyFingerprint,
                                    mediaPort: Self.mediaPort,
                                    media: media,
                                    timestamp: timestamp,
                                    nonce: nonce,
                                    signature: signature)
        try send(try JSONEncoder().encode(invite), to: address, port: port)
        return invite
    }

    func sendControl(_ kind: MeshCallControlKind,
                     callID: String,
                     recipientDeviceID: String,
                     to address: String,
                     port: UInt16 = MeshCallSignaling.port) throws -> MeshCallControl {
        guard !callID.isEmpty, !recipientDeviceID.isEmpty else {
            throw MeshCallSignalingError.invalidAddress
        }
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.lowercased()
        let payload = Self.signedControlPayload(kind: kind,
                                                callID: callID,
                                                recipientDeviceID: recipientDeviceID,
                                                senderUserID: identity.userID,
                                                senderDeviceID: identity.deviceID,
                                                timestamp: timestamp,
                                                nonce: nonce)
        let signature = try DeviceIdentityStore.shared.signMessage(payload)
        let control = MeshCallControl(version: 1,
                                      kind: kind,
                                      callID: callID,
                                      recipientDeviceID: recipientDeviceID,
                                      senderUserID: identity.userID,
                                      senderDeviceID: identity.deviceID,
                                      publicKey: identity.signingPublicKey,
                                      keyFingerprint: identity.keyFingerprint,
                                      timestamp: timestamp,
                                      nonce: nonce,
                                      signature: signature)
        let encoded = try JSONEncoder().encode(control)
        var sent = false
        var lastError: Error?
        for _ in 0..<MeshCallControlPolicy.sendAttempts {
            do {
                try send(encoded, to: address, port: port)
                sent = true
            } catch {
                lastError = error
            }
        }
        if !sent, let lastError {
            throw lastError
        }
        return control
    }

    @discardableResult
    func sendText(_ text: String,
                  to contact: DirectoryContact,
                  timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
                  nonce: UUID = UUID()) throws -> String {
        guard contact.online,
              contact.source == .mesh,
              let address = contact.meshAddress,
              let port = contact.meshPort,
              port == Self.port,
              let envelope = MeshTextEnvelope.seal(text: text,
                                                   sender: identity,
                                                   recipient: contact,
                                                   timestamp: timestamp,
                                                   nonce: nonce) else {
            throw MeshCallSignalingError.invalidAddress
        }
        try send(envelope, to: address, port: port)
        return nonce.uuidString.lowercased()
    }

    private func receiveLoop(_ socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while running && fd == socketFD {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &buffer, buffer.count, 0, $0, &sourceLength)
                }
            }
            guard count > 0 else { break }
            let data = Data(buffer.prefix(count))
            guard let sourceAddress = Self.string(from: source) else { continue }
            if data.prefix(2) == MeshTextEnvelope.magic,
               let privateKey = try? DeviceIdentityStore.shared.textEncryptionPrivateKey(),
               let message = MeshTextEnvelope.open(data,
                                                   recipient: identity,
                                                   recipientPrivateKey: privateKey),
               acceptTextReplayID(message) {
                DispatchQueue.main.async { self.onText?(message, sourceAddress) }
                continue
            }
            if let invite = try? JSONDecoder().decode(MeshCallInvite.self, from: data),
               verify(invite) {
                DispatchQueue.main.async { self.onInvite?(invite, sourceAddress) }
                continue
            }
            if let control = try? JSONDecoder().decode(MeshCallControl.self, from: data),
               verify(control) {
                DispatchQueue.main.async { self.onControl?(control, sourceAddress) }
            }
        }
    }

    private func acceptTextReplayID(_ message: MeshTextMessage) -> Bool {
        textReplay.accept(domain: "text",
                          senderFingerprint: message.senderKeyFingerprint,
                          nonce: message.id,
                          timestamp: message.timestamp,
                          now: Int64(Date().timeIntervalSince1970 * 1_000),
                          maximumSkew: MeshTextEnvelope.maximumSkewMilliseconds)
    }

    private func acceptSignalReplayID(domain: String,
                                      fingerprint: String,
                                      nonce: String,
                                      timestamp: Int64) -> Bool {
        signalReplay.accept(domain: domain,
                            senderFingerprint: fingerprint,
                            nonce: nonce,
                            timestamp: timestamp,
                            now: Int64(Date().timeIntervalSince1970),
                            maximumSkew: max(MeshCallTimestampPolicy.maxPastAge,
                                             MeshCallTimestampPolicy.maxFutureSkew))
    }

    private func verify(_ invite: MeshCallInvite) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        guard MeshCallTimestampPolicy.isFresh(invite.timestamp, now: now),
              invite.deviceID != identity.deviceID,
              Self.signatureIsValid(invite) else { return false }
        return acceptSignalReplayID(domain: "invite",
                                    fingerprint: invite.keyFingerprint,
                                    nonce: invite.nonce,
                                    timestamp: invite.timestamp)
    }

    static func signatureIsValid(_ invite: MeshCallInvite) -> Bool {
        guard invite.mediaPort == Self.mediaPort,
              NicknamePolicy.validationError(invite.nickname) == nil,
              DeviceIdentityStore.fingerprint(for: invite.publicKey) == invite.keyFingerprint else {
            return false
        }
        let payload: Data
        switch invite.version {
        case 1:
            guard invite.media == .audioVideo else { return false }
            payload = signedPayload(callID: invite.callID,
                                    nickname: invite.nickname,
                                    displayName: invite.displayName,
                                    userID: invite.userID,
                                    deviceID: invite.deviceID,
                                    mediaPort: invite.mediaPort,
                                    timestamp: invite.timestamp,
                                    nonce: invite.nonce)
        case 2:
            guard invite.media.audio else { return false }
            payload = signedPayloadV2(callID: invite.callID,
                                      nickname: invite.nickname,
                                      displayName: invite.displayName,
                                      userID: invite.userID,
                                      deviceID: invite.deviceID,
                                      mediaPort: invite.mediaPort,
                                      media: invite.media,
                                      timestamp: invite.timestamp,
                                      nonce: invite.nonce)
        default:
            return false
        }
        return DeviceIdentityStore.verifyMessage(payload,
                                                 signature: invite.signature,
                                                 publicKey: invite.publicKey)
    }

    static func protocolVersion(for media: InternetCallMedia) -> UInt8 {
        // Preserve video-call interoperability with v1 peers. Audio-only must
        // use v2 so an old peer rejects it instead of silently opening camera.
        media == .audioVideo ? 1 : 2
    }

    private func verify(_ control: MeshCallControl) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        guard MeshCallTimestampPolicy.isFresh(control.timestamp, now: now),
              control.recipientDeviceID == identity.deviceID,
              control.senderDeviceID != identity.deviceID,
              Self.signatureIsValid(control) else { return false }
        return acceptSignalReplayID(domain: "control:\(control.kind.rawValue)",
                                    fingerprint: control.keyFingerprint,
                                    nonce: control.nonce,
                                    timestamp: control.timestamp)
    }

    static func signatureIsValid(_ control: MeshCallControl) -> Bool {
        guard control.version == 1,
              !control.callID.isEmpty,
              !control.recipientDeviceID.isEmpty,
              !control.senderUserID.isEmpty,
              !control.senderDeviceID.isEmpty,
              DeviceIdentityStore.fingerprint(for: control.publicKey) == control.keyFingerprint else {
            return false
        }
        let payload = signedControlPayload(kind: control.kind,
                                           callID: control.callID,
                                           recipientDeviceID: control.recipientDeviceID,
                                           senderUserID: control.senderUserID,
                                           senderDeviceID: control.senderDeviceID,
                                           timestamp: control.timestamp,
                                           nonce: control.nonce)
        return DeviceIdentityStore.verifyMessage(payload,
                                                 signature: control.signature,
                                                 publicKey: control.publicKey)
    }

    static func signedPayload(callID: String,
                              nickname: String,
                              displayName: String,
                              userID: String,
                              deviceID: String,
                              mediaPort: UInt16,
                              timestamp: Int64,
                              nonce: String) -> Data {
        Data(["mesh-invite-v1",
              callID,
              NicknamePolicy.normalize(nickname),
              displayName,
              userID,
              deviceID,
              String(mediaPort),
              String(timestamp),
              nonce].joined(separator: "\n").utf8)
    }

    static func signedPayloadV2(callID: String,
                                nickname: String,
                                displayName: String,
                                userID: String,
                                deviceID: String,
                                mediaPort: UInt16,
                                media: InternetCallMedia,
                                timestamp: Int64,
                                nonce: String) -> Data {
        Data(["mesh-invite-v2",
              callID,
              NicknamePolicy.normalize(nickname),
              displayName,
              userID,
              deviceID,
              String(mediaPort),
              media.audio ? "audio=1" : "audio=0",
              media.video ? "video=1" : "video=0",
              String(timestamp),
              nonce].joined(separator: "\n").utf8)
    }

    static func signedControlPayload(kind: MeshCallControlKind,
                                     callID: String,
                                     recipientDeviceID: String,
                                     senderUserID: String,
                                     senderDeviceID: String,
                                     timestamp: Int64,
                                     nonce: String) -> Data {
        Data(["mesh-control-v1",
              kind.rawValue,
              callID,
              recipientDeviceID,
              senderUserID,
              senderDeviceID,
              String(timestamp),
              nonce].joined(separator: "\n").utf8)
    }

    private func send(_ data: Data, to address: String, port: UInt16) throws {
        guard var destinationAddress = IPv4Address(address, port: port) else {
            throw MeshCallSignalingError.invalidAddress
        }
        let sendFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard sendFD >= 0 else { throw MeshCallSignalingError.socketFailure(errno, address) }
        defer { close(sendFD) }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destinationAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sendFD,
                           bytes.baseAddress,
                           bytes.count,
                           0,
                           $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { throw MeshCallSignalingError.socketFailure(errno, address) }
    }

    private static func string(from address: sockaddr_in) -> String? {
        var copy = address.sin_addr
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &copy, &output, socklen_t(output.count)) != nil else { return nil }
        return String(cString: output)
    }
}

private func IPv4Address(_ address: String, port: UInt16) -> sockaddr_in? {
    var result = sockaddr_in()
    result.sin_family = sa_family_t(AF_INET)
    result.sin_port = port.bigEndian
    guard inet_pton(AF_INET, address, &result.sin_addr) == 1 else { return nil }
    return result
}

final class MeshNicknameDirectory: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let serviceType = "_trinet-call._udp."
    private static let cacheKey = "trinet.mesh.nickname.routes"
    private static let cacheTTL: Int64 = 7 * 24 * 60 * 60

    var onPeersChanged: (([DirectoryContact]) -> Void)?

    private let browser = NetServiceBrowser()
    private var publisher: NetService?
    private var identity: DeviceIdentity?
    private var resolving: [ObjectIdentifier: NetService] = [:]
    private var peersByService: [String: MeshPeer] = [:]
    private var cachedPeersByDevice: [String: CachedMeshPeer] = [:]
    private var started = false

    override init() {
        super.init()
        loadCache()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func start(identity: DeviceIdentity) {
        self.identity = identity
        if !started {
            started = true
            browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        }
        publish(identity: identity)
        emitPeers()
    }

    func stop() {
        browser.stop()
        publisher?.stop()
        publisher = nil
        started = false
        peersByService.removeAll()
        emitPeers()
    }

    func contact(named nickname: String) -> DirectoryContact? {
        let target = NicknamePolicy.normalize(nickname)
        let activeNicknameMatches = peersByService.values.filter {
            NicknamePolicy.normalize($0.nickname) == target
        }
        if !activeNicknameMatches.isEmpty {
            guard activeNicknameMatches.count == 1,
                  let active = activeNicknameMatches.first else { return nil }
            return contact(active)
        }
        let activeDisplayMatches = peersByService.values.filter {
            NicknamePolicy.normalize($0.displayName) == target
        }
        if activeDisplayMatches.count == 1, let active = activeDisplayMatches.first {
            return contact(active)
        }
        let cachedNicknameMatches = cachedPeersByDevice.values.filter {
            NicknamePolicy.normalize($0.nickname) == target
        }
        if !cachedNicknameMatches.isEmpty {
            guard cachedNicknameMatches.count == 1,
                  let cached = cachedNicknameMatches.first else { return nil }
            return cachedContact(cached)
        }
        let cachedDisplayMatches = cachedPeersByDevice.values.filter {
            NicknamePolicy.normalize($0.displayName) == target
        }
        guard cachedDisplayMatches.count == 1, let cached = cachedDisplayMatches.first else {
            return nil
        }
        return cachedContact(cached)
    }

    private func publish(identity: DeviceIdentity) {
        publisher?.stop()
        publisher = nil
        guard let nickname = identity.nickname, !nickname.isEmpty,
              let textKeyData = try? DeviceIdentityStore.shared.textEncryptionPublicKey() else { return }
        let textKey = textKeyData.base64EncodedString()
        let port = MeshCallSignaling.port
        let payload = signedPayload(nickname: nickname,
                                    userID: identity.userID,
                                    deviceID: identity.deviceID,
                                    port: port,
                                    textEncryptionPublicKey: textKey)
        guard let signature = try? DeviceIdentityStore.shared.signMessage(payload) else { return }
        let service = NetService(domain: "local.",
                                 type: Self.serviceType,
                                 name: "trinet-\(identity.deviceID.prefix(8))",
                                 port: Int32(port))
        service.includesPeerToPeer = true
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "nick": Data(nickname.utf8),
            "name": Data(identity.displayName.utf8),
            "uid": Data(identity.userID.utf8),
            "did": Data(identity.deviceID.utf8),
            "fp": Data(identity.keyFingerprint.utf8),
            "pk": Data(identity.signingPublicKey.utf8),
            "txk": Data(textKey.utf8),
            "sig": Data(signature.utf8)
        ]))
        publisher = service
        service.publish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        guard service.name != publisher?.name else { return }
        resolving[ObjectIdentifier(service)] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        peersByService.removeValue(forKey: service.name)
        resolving.removeValue(forKey: ObjectIdentifier(service))
        emitPeers()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeValue(forKey: ObjectIdentifier(sender)) }
        guard let record = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)),
              let nickname = text(record["nick"]),
              let userID = text(record["uid"]),
              let deviceID = text(record["did"]),
              let fingerprint = text(record["fp"]),
              let publicKey = text(record["pk"]),
              let textKey = text(record["txk"]),
              let textKeyData = Data(base64Encoded: textKey),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: textKeyData)) != nil,
              let signature = text(record["sig"]),
              deviceID != identity?.deviceID else { return }
        let addresses = numericAddresses(sender.addresses)
        guard let address = addresses.first else { return }
        let port = UInt16(clamping: sender.port)
        let payload = signedPayload(nickname: nickname, userID: userID, deviceID: deviceID,
                                    port: port, textEncryptionPublicKey: textKey)
        guard NicknamePolicy.validationError(nickname) == nil,
              DeviceIdentityStore.fingerprint(for: publicKey) == fingerprint,
              DeviceIdentityStore.verifyMessage(payload, signature: signature, publicKey: publicKey) else { return }
        peersByService[sender.name] = MeshPeer(
            serviceName: sender.name,
            userID: userID,
            deviceID: deviceID,
            nickname: nickname,
            displayName: text(record["name"]) ?? nickname,
            keyFingerprint: fingerprint,
            signingPublicKey: publicKey,
            textEncryptionPublicKey: textKey,
            address: address,
            addresses: addresses,
            port: port
        )
        if MeshAddressPolicy.canPersist(address) {
            cachedPeersByDevice[deviceID] = CachedMeshPeer(userID: userID,
                                                           deviceID: deviceID,
                                                           nickname: nickname,
                                                           displayName: text(record["name"]) ?? nickname,
                                                           keyFingerprint: fingerprint,
                                                           signingPublicKey: publicKey,
                                                           textEncryptionPublicKey: textKey,
                                                           address: address,
                                                           port: port,
                                                           lastSeen: Int64(Date().timeIntervalSince1970))
        } else {
            cachedPeersByDevice.removeValue(forKey: deviceID)
        }
        saveCache()
        emitPeers()
    }

    private func contact(_ peer: MeshPeer) -> DirectoryContact {
        DirectoryContact(userID: peer.userID,
                         deviceID: peer.deviceID,
                         nickname: peer.nickname,
                         displayName: peer.displayName,
                         keyFingerprint: peer.keyFingerprint,
                         source: .mesh,
                         online: true,
                         meshAddress: peer.address,
                         meshPort: peer.port,
                         signingPublicKey: peer.signingPublicKey,
                         textEncryptionPublicKey: peer.textEncryptionPublicKey,
                         meshAddresses: peer.addresses)
    }

    private func emitPeers() {
        let active = peersByService.values.map(contact)
        let activeDeviceIDs = Set(active.map(\.deviceID))
        let cached = cachedPeersByDevice.values
            .filter { !activeDeviceIDs.contains($0.deviceID) }
            .map(cachedContact)
        let contacts = (active + cached).sorted { $0.nickname < $1.nickname }
        DispatchQueue.main.async { self.onPeersChanged?(contacts) }
    }

    private func cachedContact(_ peer: CachedMeshPeer) -> DirectoryContact {
        DirectoryContact(userID: peer.userID,
                         deviceID: peer.deviceID,
                         nickname: peer.nickname,
                         displayName: peer.displayName,
                         keyFingerprint: peer.keyFingerprint,
                         source: .mesh,
                         online: false,
                         meshAddress: peer.address,
                         meshPort: peer.port,
                         signingPublicKey: peer.signingPublicKey,
                         textEncryptionPublicKey: peer.textEncryptionPublicKey)
    }

    private func loadCache() {
        let now = Int64(Date().timeIntervalSince1970)
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode([CachedMeshPeer].self, from: data) else { return }
        cachedPeersByDevice = Dictionary(uniqueKeysWithValues: cached
            .filter {
                now >= $0.lastSeen &&
                    now - $0.lastSeen <= Self.cacheTTL &&
                    MeshAddressPolicy.canPersist($0.address)
            }
            .map { ($0.deviceID, $0) })
    }

    private func saveCache() {
        let now = Int64(Date().timeIntervalSince1970)
        cachedPeersByDevice = cachedPeersByDevice.filter {
            now >= $0.value.lastSeen &&
                now - $0.value.lastSeen <= Self.cacheTTL &&
                MeshAddressPolicy.canPersist($0.value.address)
        }
        if let data = try? JSONEncoder().encode(Array(cachedPeersByDevice.values)) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private func text(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private func signedPayload(nickname: String,
                               userID: String,
                               deviceID: String,
                               port: UInt16,
                               textEncryptionPublicKey: String) -> Data {
        Data(["mesh-directory-v2",
              NicknamePolicy.normalize(nickname),
              userID,
              deviceID,
              String(port),
              textEncryptionPublicKey].joined(separator: "\n").utf8)
    }

    private func numericAddresses(_ addresses: [Data]?) -> [String] {
        let candidates = (addresses ?? []).compactMap { data -> (String, Int)? in
            guard addressFamily(data) == AF_INET else { return nil }
            return data.withUnsafeBytes { raw -> (String, Int)? in
                guard let base = raw.baseAddress else { return nil }
                let socketAddress = base.assumingMemoryBound(to: sockaddr.self)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(socketAddress,
                                  socklen_t(data.count),
                                  &host,
                                  socklen_t(host.count),
                                  nil,
                                  0,
                                  NI_NUMERICHOST) == 0 else { return nil }
                let value = String(cString: host)
                guard value != "0.0.0.0" else { return nil }
                let rank = value.hasPrefix("169.254.") ? 1 : (value.hasPrefix("127.") ? 2 : 0)
                return (value, rank)
            }
        }
        var seen = Set<String>()
        return candidates
            .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }
            .compactMap { seen.insert($0.0).inserted ? $0.0 : nil }
    }

    private func addressFamily(_ data: Data) -> sa_family_t {
        data.withUnsafeBytes { raw in
            raw.baseAddress?.assumingMemoryBound(to: sockaddr.self).pointee.sa_family ?? 0
        }
    }
}

final class NicknameDirectoryController: ObservableObject {
    @Published var proposedNickname = ""
    @Published var searchQuery = "" {
        didSet {
            let query = NicknamePolicy.normalize(searchQuery)
            guard query != internetResultsQuery else { return }
            searchGeneration = nil
            internetResults = []
            internetResultsQuery = ""
            isWorking = false
            rebuildResults()
        }
    }
    @Published private(set) var currentNickname: String?
    @Published private(set) var claimKind: NicknameClaimKind
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var results: [DirectoryContact] = []
    @Published private(set) var meshPeers: [DirectoryContact] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?

    var onIdentityChanged: ((DeviceIdentity) -> Void)?
    var onIncomingMeshInvite: ((MeshCallInvite, String) -> Void)?
    var onMeshCallControl: ((MeshCallControl, String) -> Void)?
    var onMeshText: ((MeshTextMessage, String) -> Void)?

    private var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    private var internetResults: [DirectoryContact] = []
    private var internetResultsQuery = ""
    private var searchGeneration: UUID?
    private let mesh = MeshNicknameDirectory()
    private let signaling: MeshCallSignaling
    private let textIdentityPins = MeshTextIdentityPinStore()

    init(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        signaling = MeshCallSignaling(identity: identity)
        currentNickname = identity.nickname
        claimKind = NicknameClaimKind(rawValue: UserDefaults.standard.string(forKey: "nicknameClaimKind") ?? "")
            ?? (identity.nickname == nil ? .none : .meshLocal)
        proposedNickname = identity.nickname ?? ""
        mesh.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            self.meshPeers = peers
            self.rebuildResults()
            self.detectLocalConflict()
        }
        signaling.onInvite = { [weak self] invite, address in
            guard let self else { return }
            self.onIncomingMeshInvite?(invite, address)
        }
        signaling.onControl = { [weak self] control, address in
            guard let self else { return }
            self.onMeshCallControl?(control, address)
        }
        signaling.onText = { [weak self] message, address in
            guard let self else { return }
            self.onMeshText?(message, address)
        }
        mesh.start(identity: identity)
        signaling.start()
        reconcileProvisionalNickname()
    }

    func update(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        currentNickname = identity.nickname
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        internetResults = []
        internetResultsQuery = ""
        searchGeneration = nil
        isWorking = false
        rebuildResults()
        signaling.update(identity: identity)
        mesh.start(identity: identity)
        reconcileProvisionalNickname()
    }

    func sendMeshInvite(to address: String,
                        port: UInt16?,
                        media: InternetCallMedia = .audioVideo) throws -> MeshCallInvite {
        try signaling.sendInvite(to: address,
                                 port: port ?? MeshCallSignaling.port,
                                 media: media)
    }

    @discardableResult
    func sendMeshControl(_ kind: MeshCallControlKind,
                         callID: String,
                         recipientDeviceID: String,
                         to address: String,
                         port: UInt16? = nil) throws -> MeshCallControl {
        try signaling.sendControl(kind,
                                  callID: callID,
                                  recipientDeviceID: recipientDeviceID,
                                  to: address,
                                  port: port ?? MeshCallSignaling.port)
    }

    @discardableResult
    func sendMeshText(_ text: String, to contact: DirectoryContact) throws -> String {
        guard textIdentityPins.accept(contact) else {
            throw MeshCallSignalingError.textIdentityChanged
        }
        return try signaling.sendText(text, to: contact)
    }

    func verifiedMeshTextSender(_ message: MeshTextMessage,
                                sourceAddress: String) -> DirectoryContact? {
        let matches = meshPeers.filter {
            MeshTextIdentityPolicy.matches(message, contact: $0, sourceAddress: sourceAddress)
        }
        guard matches.count == 1, let contact = matches.first,
              textIdentityPins.accept(contact) else { return nil }
        return contact
    }

    func verifiedMeshInviteSender(_ invite: MeshCallInvite,
                                  sourceAddress: String) -> DirectoryContact? {
        let matches = meshPeers.filter {
            MeshInviteIdentityPolicy.matches(invite, contact: $0, sourceAddress: sourceAddress)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func claimProposedNickname() {
        let candidate = NicknamePolicy.normalize(proposedNickname)
        proposedNickname = candidate
        suggestions = []
        statusMessage = nil
        if let error = NicknamePolicy.validationError(candidate) {
            statusMessage = error
            suggestions = localSuggestions(candidate)
            return
        }
        if let collision = meshPeers.first(where: {
            $0.userID != identity.userID && NicknamePolicy.isConfusing(candidate, with: $0.nickname)
        }) {
            statusMessage = "@\(candidate) is too similar to mesh user @\(collision.nickname)."
            suggestions = localSuggestions(candidate)
            return
        }

        isWorking = true
        Task { @MainActor in
            do {
                if configuration.hasDirectoryAPI {
                    let response = try await api.claimNickname(candidate, identity: identity)
                    guard response.claimed else {
                        suggestions = response.suggestions.isEmpty ? localSuggestions(candidate) : response.suggestions
                        statusMessage = response.reason ?? "That nickname is unavailable."
                        isWorking = false
                        return
                    }
                    try persistNickname(response.normalized, kind: .verified)
                    statusMessage = "@\(response.normalized) is globally verified."
                } else {
                    try persistNickname(candidate, kind: .meshLocal)
                    statusMessage = "@\(candidate) is active in this mesh. Connect the Directory API for global verification."
                }
            } catch is URLError {
                do {
                    try persistNickname(candidate, kind: .meshLocal)
                    statusMessage = "Directory is offline. @\(candidate) is active as a provisional mesh-local nickname."
                } catch {
                    statusMessage = error.localizedDescription
                }
            } catch {
                statusMessage = error.localizedDescription
                suggestions = localSuggestions(candidate)
            }
            isWorking = false
        }
    }

    func search() {
        let query = NicknamePolicy.normalize(searchQuery)
        let generation = UUID()
        searchGeneration = generation
        internetResults = []
        internetResultsQuery = query
        isWorking = false
        rebuildResults()
        guard !query.isEmpty else { return }
        if !configuration.hasDirectoryAPI { return }
        isWorking = true
        Task { @MainActor in
            defer {
                if searchGeneration == generation {
                    isWorking = false
                }
            }
            do {
                let remote = try await api.searchNicknames(query, identity: identity).results.map {
                    DirectoryContact(userID: $0.userID,
                                     deviceID: $0.deviceID,
                                     nickname: $0.nickname,
                                     displayName: $0.displayName ?? $0.nickname,
                                     keyFingerprint: $0.keyFingerprint,
                                     source: .internet,
                                     online: $0.online,
                                     meshAddress: nil,
                                     meshPort: nil)
                }
                guard searchGeneration == generation,
                      NicknamePolicy.normalize(searchQuery) == query else { return }
                internetResults = remote
                internetResultsQuery = query
                rebuildResults()
            } catch {
                guard searchGeneration == generation else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    func meshContact(named nickname: String) -> DirectoryContact? {
        let target = NicknamePolicy.normalize(nickname)
        let hasActiveCandidate = meshPeers.contains {
            $0.online && $0.source == .mesh &&
                (NicknamePolicy.normalize($0.nickname) == target ||
                 NicknamePolicy.normalize($0.displayName) == target)
        }
        if hasActiveCandidate {
            return MeshContactSelectionPolicy.uniqueActive(meshPeers, named: nickname)
        }
        return mesh.contact(named: nickname)
    }

    private func reconcileProvisionalNickname() {
        guard configuration.hasDirectoryAPI,
              !configuration.isDevelopmentDirect,
              claimKind != .verified,
              let nickname = identity.nickname,
              !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            do {
                try await api.register(identity: identity,
                                       voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
                let response = try await api.claimNickname(nickname, identity: identity)
                if response.claimed {
                    try persistNickname(response.normalized, kind: .verified)
                    statusMessage = "@\(response.normalized) is globally verified."
                } else {
                    suggestions = response.suggestions.isEmpty ? localSuggestions(nickname) : response.suggestions
                    statusMessage = response.reason ?? "Choose another nickname for global use."
                }
            } catch {
                statusMessage = "Global nickname verification is pending: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func persistNickname(_ nickname: String, kind: NicknameClaimKind) throws {
        identity = try DeviceIdentityStore.shared.setNickname(nickname)
        currentNickname = nickname
        claimKind = kind
        proposedNickname = nickname
        UserDefaults.standard.set(kind.rawValue, forKey: "nicknameClaimKind")
        mesh.start(identity: identity)
        signaling.update(identity: identity)
        onIdentityChanged?(identity)
    }

    private func rebuildResults() {
        let query = NicknamePolicy.normalize(searchQuery)
        let matchingInternetResults = internetResultsQuery == query ? internetResults : []
        results = DirectoryResultPolicy.merge(mesh: meshPeers,
                                              internet: matchingInternetResults,
                                              query: query)
    }

    private func detectLocalConflict() {
        guard let own = identity.nickname,
              let conflict = meshPeers.first(where: {
                  $0.userID != identity.userID && NicknamePolicy.isConfusing(own, with: $0.nickname)
              }) else { return }
        statusMessage = "Nickname conflict with @\(conflict.nickname) in this mesh. Choose another nickname."
        suggestions = localSuggestions(own)
    }

    private func localSuggestions(_ candidate: String) -> [String] {
        NicknamePolicy.suggestions(for: candidate,
                                   excluding: meshPeers.map(\.nickname),
                                   seed: identity.deviceID)
    }
}
