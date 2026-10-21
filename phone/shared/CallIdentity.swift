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
        // Bind a token saved before origins were recorded to the address it
        // was saved with, before that address may be rewritten below.
        migrateLegacyAccessToken(defaults: defaults, savedAPIBaseURL: savedAPIBaseURL)
        let apiBaseURL = preferredAPIBaseURL(saved: savedAPIBaseURL, bundled: bundledAPIBaseURL)
        if let savedAPIBaseURL,
           !savedAPIBaseURL.isEmpty,
           savedAPIBaseURL != apiBaseURL {
            defaults.set(apiBaseURL, forKey: "internetAPIBaseURL")
        }

        return InternetCallConfiguration(
            apiBaseURL: apiBaseURL,
            liveKitURL: value("liveKitURL", "TRINET_LIVEKIT_URL"),
            accessToken: scopedAccessToken(apiBaseURL: apiBaseURL, defaults: defaults, bundle: bundle),
            developmentRoomToken: value("developmentRoomToken", "TRINET_DEVELOPMENT_ROOM_TOKEN")
        )
    }

    /// `scheme://host[:port]`, lowercased; nil when the address has no host.
    static func origin(of address: String) -> String? {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Service access tokens by origin (`scheme://host[:port]`).
    static let accessTokensKey = "serviceAccessTokens"

    static func storedAccessTokens(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: accessTokensKey) as? [String: String] ?? [:]
    }

    /// Moves a single token saved by an older build into the per-origin store,
    /// bound to the origin recorded with it or else the address saved with it,
    /// then removes the old keys. A token saved without any address is
    /// deleted, never kept: an address recorded later must not adopt it.
    static func migrateLegacyAccessToken(defaults: UserDefaults, savedAPIBaseURL: String?) {
        guard let legacy = defaults.string(forKey: "serviceAccessToken") else { return }
        let legacyOrigin = defaults.string(forKey: "serviceAccessTokenOrigin")
            ?? origin(of: savedAPIBaseURL ?? "")
        if !legacy.isEmpty, let legacyOrigin {
            var tokens = storedAccessTokens(defaults)
            if tokens[legacyOrigin] == nil {
                tokens[legacyOrigin] = legacy
            }
            defaults.set(tokens, forKey: accessTokensKey)
        }
        defaults.removeObject(forKey: "serviceAccessToken")
        defaults.removeObject(forKey: "serviceAccessTokenOrigin")
    }

    /// A service access token is sent only to the origin it was saved or
    /// bundled for, so switching servers never carries it to another host,
    /// also after a restart.
    static func scopedAccessToken(apiBaseURL: String,
                                  defaults: UserDefaults,
                                  bundle: Bundle) -> String {
        guard let activeOrigin = origin(of: apiBaseURL) else { return "" }
        if let saved = storedAccessTokens(defaults)[activeOrigin], !saved.isEmpty {
            return saved
        }
        let bundledToken = bundle.object(forInfoDictionaryKey: "TRINET_SERVICE_ACCESS_TOKEN") as? String ?? ""
        let bundledBase = bundle.object(forInfoDictionaryKey: "TRINET_API_BASE_URL") as? String ?? ""
        if !bundledToken.isEmpty, origin(of: bundledBase) == activeOrigin {
            return bundledToken
        }
        return ""
    }

    /// True when `token` is a credential of a different origin, for example
    /// the previous server's token still in a settings form after only the
    /// address was edited.
    static func tokenBelongsToAnotherOrigin(_ token: String,
                                            target: String,
                                            tokens: [String: String],
                                            bundle: Bundle) -> Bool {
        if tokens[target] == token { return false }
        if tokens.contains(where: { $0.key != target && $0.value == token }) { return true }
        let bundledToken = bundle.object(forInfoDictionaryKey: "TRINET_SERVICE_ACCESS_TOKEN") as? String ?? ""
        let bundledBase = bundle.object(forInfoDictionaryKey: "TRINET_API_BASE_URL") as? String ?? ""
        return !bundledToken.isEmpty && token == bundledToken && origin(of: bundledBase) != target
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

    /// Saves the address and LiveKit settings, and the token for this
    /// address's origin only. A token that belongs to another origin (an
    /// address-only edit) is not stored for this one; an empty token clears
    /// this origin's token only when the address stays on this origin, so an
    /// address-only edit neither moves nor deletes a token; other origins'
    /// tokens are kept. Callers reload with `load()` so the in-memory
    /// configuration carries the scoped token.
    func save(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        let previousAPIBaseURL = defaults.string(forKey: "internetAPIBaseURL")
        Self.migrateLegacyAccessToken(defaults: defaults, savedAPIBaseURL: previousAPIBaseURL)
        let previousOrigin = Self.origin(of: previousAPIBaseURL ?? "")
        defaults.set(apiBaseURL, forKey: "internetAPIBaseURL")
        defaults.set(liveKitURL, forKey: "liveKitURL")
        defaults.set(developmentRoomToken, forKey: "developmentRoomToken")
        guard let target = Self.origin(of: apiBaseURL) else { return }
        var tokens = Self.storedAccessTokens(defaults)
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            if previousOrigin == target {
                tokens.removeValue(forKey: target)
            }
        } else if !Self.tokenBelongsToAnotherOrigin(token, target: target, tokens: tokens, bundle: bundle) {
            tokens[target] = token
        }
        defaults.set(tokens, forKey: Self.accessTokensKey)
    }

    /// Authorization header value sent to the call service; nil when no
    /// token is scoped to this configuration's origin.
    var authorizationHeader: String? {
        accessToken.isEmpty ? nil : "Bearer \(accessToken)"
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

    /// Keychain service of this app's device identity. An app that embeds
    /// these shared files next to another TRI-NET client on the same Mac (the
    /// TriOS macOS app) sets `TRINET_IDENTITY_KEYCHAIN_SERVICE` in its
    /// Info.plist so it registers as its own device instead of reusing the
    /// other client's signing key. Without the key the existing item is used.
    static let defaultKeychainService = "com.trinet.video.device-identity"
    private let service = DeviceIdentityStore.keychainService(bundle: .main)

    static func keychainService(bundle: Bundle) -> String {
        let configured = (bundle.object(forInfoDictionaryKey: "TRINET_IDENTITY_KEYCHAIN_SERVICE") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.isEmpty ? defaultKeychainService : configured
    }
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
