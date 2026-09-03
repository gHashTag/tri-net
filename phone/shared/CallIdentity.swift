import CryptoKit
import Darwin
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

enum CallRoutePolicy {
    static let automaticMeshProbeTimeout: TimeInterval = 8
    static let automaticMeshControlGrace: TimeInterval = 1
    static let automaticAcceptedMeshTimeout: TimeInterval = 30

    static func select(requested: CallRoute,
                       targetIsMeshAddress: Bool,
                       hasLiveMeshContact: Bool) -> CallRoute {
        guard requested == .automatic else { return requested }
        return targetIsMeshAddress || hasLiveMeshContact ? .mesh : .internet
    }
}

enum DeviceDisplayNamePolicy {
    static func isRawIPAddress(_ candidate: String) -> Bool {
        var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return false }
            value = String(value[value.index(after: value.startIndex)..<closing])
        } else if value.filter({ $0 == ":" }).count == 1,
                  let separator = value.lastIndex(of: ":"),
                  value[value.index(after: separator)...].allSatisfy(\.isNumber) {
            value = String(value[..<separator])
        }
        if let zone = value.firstIndex(of: "%") {
            value = String(value[..<zone])
        }

        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }

    static func safe(_ candidate: String, fallback: String) -> String {
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isRawIPAddress(clean) else { return fallback }
        return clean
    }
}

enum MeshAddressPolicy {
    static func isNumericIPv4(_ address: String) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil
        }
    }

    static func isLinkLocalIPv4(_ address: String) -> Bool {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({
                  !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil
              }) else { return false }
        return UInt8(components[0]) == 169 && UInt8(components[1]) == 254
    }

    static func canPersist(_ address: String) -> Bool {
        !isLinkLocalIPv4(address)
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

        let bundledAPIBaseURL = bundle.object(forInfoDictionaryKey: "TRINET_API_BASE_URL") as? String ?? ""
        let savedAPIBaseURL = defaults.string(forKey: "internetAPIBaseURL")
        let apiBaseURL = preferredAPIBaseURL(saved: savedAPIBaseURL, bundled: bundledAPIBaseURL)
        if let savedAPIBaseURL,
           !savedAPIBaseURL.isEmpty,
           savedAPIBaseURL != apiBaseURL {
            defaults.set(apiBaseURL, forKey: "internetAPIBaseURL")
        }

        return InternetCallConfiguration(
            apiBaseURL: apiBaseURL,
            liveKitURL: value("liveKitURL", "TRINET_LIVEKIT_URL"),
            accessToken: value("serviceAccessToken", "TRINET_SERVICE_ACCESS_TOKEN"),
            developmentRoomToken: value("developmentRoomToken", "TRINET_DEVELOPMENT_ROOM_TOKEN")
        )
    }

    static func preferredAPIBaseURL(saved: String?, bundled: String) -> String {
        guard let saved, !saved.isEmpty else { return bundled }
        guard let savedHost = URL(string: saved)?.host,
              let bundledHost = URL(string: bundled)?.host,
              isPrivateIPv4(savedHost),
              bundledHost.lowercased().hasSuffix(".local") else {
            return saved
        }
        return bundled
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        let octets = components.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254) ||
            (octets[0] == 100 && (64...127).contains(octets[1]))
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

    var isPublicHTTPSAPI: Bool {
        guard let url = URL(string: apiBaseURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return false }
        let privateIPv6 = host.contains(":") &&
            (host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") ||
             host.hasPrefix("fe80:"))
        if host == "localhost" || host == "0.0.0.0" ||
            host.hasSuffix(".local") || host.hasSuffix(".lan") ||
            privateIPv6 || Self.isPrivateIPv4(host) {
            return false
        }
        return true
    }

    var healthURL: URL? {
        endpointURL(path: "/healthz")
    }

    func endpointURL(path: String) -> URL? {
        guard var components = URLComponents(string: apiBaseURL),
              components.scheme != nil,
              components.host != nil else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !endpointPath.isEmpty else { return nil }
        components.path = basePath.isEmpty
            ? "/\(endpointPath)"
            : "/\(basePath)/\(endpointPath)"
        components.query = nil
        components.fragment = nil
        return components.url
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
    private let textEncryptionKeyAccount = "text-encryption-key-v1"
    private let textEncryptionKeyLock = NSLock()
    private var cachedTextEncryptionKey: Curve25519.KeyAgreement.PrivateKey?

    private init() {}

    func loadOrCreate(defaultName: String = "ssd26") throws -> DeviceIdentity {
        let storedName = UserDefaults.standard.string(forKey: "deviceDisplayName") ?? defaultName
        let requestedName = DeviceDisplayNamePolicy.safe(storedName, fallback: defaultName)
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
        let clean = DeviceDisplayNamePolicy.safe(displayName, fallback: "ssd26")
        UserDefaults.standard.set(clean, forKey: "deviceDisplayName")
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

    func textEncryptionPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        textEncryptionKeyLock.lock()
        defer { textEncryptionKeyLock.unlock() }
        if let cachedTextEncryptionKey { return cachedTextEncryptionKey }
        if let stored = try readData(account: textEncryptionKeyAccount) {
            guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored) else {
                throw IdentityStoreError.invalidKey
            }
            cachedTextEncryptionKey = privateKey
            return privateKey
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let status = addDataIfMissing(privateKey.rawRepresentation, account: textEncryptionKeyAccount)
        if status == errSecSuccess {
            cachedTextEncryptionKey = privateKey
            return privateKey
        }
        if status == errSecDuplicateItem,
           let winnerData = try readData(account: textEncryptionKeyAccount),
           let winner = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: winnerData) {
            cachedTextEncryptionKey = winner
            return winner
        }
        throw IdentityStoreError.keychain(status)
    }

    func textEncryptionPublicKey() throws -> Data {
        try textEncryptionPrivateKey().publicKey.rawRepresentation
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

    private func addDataIfMissing(_ data: Data, account: String) -> OSStatus {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }
}
