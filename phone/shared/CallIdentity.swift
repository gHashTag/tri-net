import CryptoKit
import Foundation
import Security

enum CallRoute: String, CaseIterable, Codable, Identifiable {
    case automatic = "Auto"
    case mesh = "Mesh"
    case internet = "Internet"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .mesh: return "Local/Mesh UDP"
        case .internet: return "Internet"
        }
    }
}

struct DeviceIdentity: Codable, Equatable {
    var userID: String
    let deviceID: String
    var displayName: String
    var nickname: String?
    let signingPublicKey: String
    let keyFingerprint: String
}

struct DeviceRequestSignature {
    let deviceID: String
    let timestamp: String
    let nonce: String
    let signature: String
}

struct InternetCallConfiguration: Equatable {
    var apiBaseURL: String
    var liveKitURL: String
    var accessToken: String
    var developmentRoomToken: String

    static func load(defaults: UserDefaults = .standard,
                     bundle: Bundle = .main) -> InternetCallConfiguration {
        func value(_ defaultsKey: String, _ plistKey: String) -> String {
            if let saved = defaults.string(forKey: defaultsKey), !saved.isEmpty {
                return saved
            }
            return bundle.object(forInfoDictionaryKey: plistKey) as? String ?? ""
        }

        return InternetCallConfiguration(
            apiBaseURL: value("internetAPIBaseURL", "TRINET_API_BASE_URL"),
            liveKitURL: value("liveKitURL", "TRINET_LIVEKIT_URL"),
            accessToken: value("serviceAccessToken", "TRINET_SERVICE_ACCESS_TOKEN"),
            developmentRoomToken: value("developmentRoomToken", "TRINET_DEVELOPMENT_ROOM_TOKEN")
        )
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(apiBaseURL, forKey: "internetAPIBaseURL")
        defaults.set(liveKitURL, forKey: "liveKitURL")
        defaults.set(accessToken, forKey: "serviceAccessToken")
        defaults.set(developmentRoomToken, forKey: "developmentRoomToken")
    }

    var isDevelopmentDirect: Bool {
        !liveKitURL.isEmpty && !developmentRoomToken.isEmpty
    }

    var isConfigured: Bool {
        isDevelopmentDirect || URL(string: apiBaseURL) != nil
    }

    var hasDirectoryAPI: Bool {
        guard let url = URL(string: apiBaseURL),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

enum IdentityStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            return "Keychain operation failed (\(status))."
        case .invalidKey:
            return "The stored device identity key is invalid."
        }
    }
}

final class DeviceIdentityStore {
    static let shared = DeviceIdentityStore()

    private let service = "com.trinet.video.device-identity"
    private let identityAccount = "identity-v1"
    private let signingKeyAccount = "signing-key-v1"

    private init() {}

    func loadOrCreate(defaultName: String = "ssd26") throws -> DeviceIdentity {
        let requestedName = UserDefaults.standard.string(forKey: "deviceDisplayName") ?? defaultName
        if var identity: DeviceIdentity = try readCodable(account: identityAccount) {
            if identity.displayName != requestedName {
                identity.displayName = requestedName
                try writeCodable(identity, account: identityAccount)
            }
            return identity
        }

        let publicKey = try loadOrCreateSigningPublicKey()
        let digest = SHA256.hash(data: publicKey)
        let fingerprint = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let identity = DeviceIdentity(
            userID: UUID().uuidString.lowercased(),
            deviceID: UUID().uuidString.lowercased(),
            displayName: requestedName,
            nickname: nil,
            signingPublicKey: publicKey.base64EncodedString(),
            keyFingerprint: fingerprint
        )
        try writeCodable(identity, account: identityAccount)
        return identity
    }

    func rename(_ displayName: String) throws -> DeviceIdentity {
        let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(clean.isEmpty ? "ssd26" : clean, forKey: "deviceDisplayName")
        return try loadOrCreate(defaultName: "ssd26")
    }

    func setNickname(_ nickname: String?) throws -> DeviceIdentity {
        guard var identity: DeviceIdentity = try readCodable(account: identityAccount) else {
            throw IdentityStoreError.invalidKey
        }
        identity.nickname = nickname
        try writeCodable(identity, account: identityAccount)
        return identity
    }

    func adoptAccount(userID: String, nickname: String?) throws -> DeviceIdentity {
        guard var identity: DeviceIdentity = try readCodable(account: identityAccount),
              !userID.isEmpty else {
            throw IdentityStoreError.invalidKey
        }
        identity.userID = userID
        identity.nickname = nickname
        try writeCodable(identity, account: identityAccount)
        return identity
    }

    func signMessage(_ message: Data) throws -> String {
        guard let stored = try readData(account: signingKeyAccount),
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: stored) else {
            throw IdentityStoreError.invalidKey
        }
        return try privateKey.signature(for: message).derRepresentation.base64EncodedString()
    }

    static func verifyMessage(_ message: Data,
                              signature: String,
                              publicKey: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let proof = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            return false
        }
        return key.isValidSignature(proof, for: message)
    }

    static func fingerprint(for publicKey: String) -> String? {
        guard let keyData = Data(base64Encoded: publicKey) else { return nil }
        return SHA256.hash(data: keyData).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
    }

    func signRequest(identity: DeviceIdentity,
                     method: String,
                     path: String,
                     body: Data) throws -> DeviceRequestSignature {
        guard let stored = try readData(account: signingKeyAccount),
              let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: stored) else {
            throw IdentityStoreError.invalidKey
        }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.lowercased()
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = [method.uppercased(), path, timestamp, nonce, bodyHash].joined(separator: "\n")
        let signature = try privateKey.signature(for: Data(canonical.utf8))
        return DeviceRequestSignature(
            deviceID: identity.deviceID,
            timestamp: timestamp,
            nonce: nonce,
            signature: signature.derRepresentation.base64EncodedString()
        )
    }

    private func loadOrCreateSigningPublicKey() throws -> Data {
        if let stored = try readData(account: signingKeyAccount) {
            guard let privateKey = try? P256.Signing.PrivateKey(rawRepresentation: stored) else {
                throw IdentityStoreError.invalidKey
            }
            return privateKey.publicKey.x963Representation
        }

        let privateKey = P256.Signing.PrivateKey()
        try writeData(privateKey.rawRepresentation, account: signingKeyAccount)
        return privateKey.publicKey.x963Representation
    }

    private func readCodable<T: Decodable>(account: String) throws -> T? {
        guard let data = try readData(account: account) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func writeCodable<T: Encodable>(_ value: T, account: String) throws {
        try writeData(JSONEncoder().encode(value), account: account)
    }

    private func readData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityStoreError.keychain(status) }
        return item as? Data
    }

    private func writeData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw IdentityStoreError.keychain(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw IdentityStoreError.keychain(addStatus) }
    }
}
