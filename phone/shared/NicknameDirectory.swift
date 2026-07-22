import Combine
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

    var id: String { "\(source.rawValue):\(deviceID)" }
}

private struct MeshPeer: Equatable {
    let serviceName: String
    let userID: String
    let deviceID: String
    let nickname: String
    let displayName: String
    let keyFingerprint: String
    let address: String
    let port: UInt16
}

private struct CachedMeshPeer: Codable {
    let userID: String
    let deviceID: String
    let nickname: String
    let displayName: String
    let keyFingerprint: String
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
    let timestamp: Int64
    let nonce: String
    let signature: String

    var id: String { callID }
}

struct IncomingMeshCall: Identifiable, Equatable {
    let invite: MeshCallInvite
    let sourceAddress: String

    var id: String { invite.callID }
}

enum MeshCallSignalingError: LocalizedError {
    case invalidAddress
    case missingIdentity
    case socketFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "The local peer address is invalid."
        case .missingIdentity:
            return "Create a nickname before placing a local call."
        case let .socketFailure(code):
            return "Local call signaling failed (errno \(code))."
        }
    }
}

final class MeshCallSignaling {
    static let port: UInt16 = 7001
    static let mediaPort: UInt16 = 7000

    var onInvite: ((MeshCallInvite, String) -> Void)?

    private var fd: Int32 = -1
    private var running = false
    private var identity: DeviceIdentity
    private var seenNonces: [String: Int64] = [:]
    private let receiveQueue = DispatchQueue(label: "trinet.mesh.signal", qos: .userInitiated)

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

    func sendInvite(to address: String, port: UInt16 = MeshCallSignaling.port) throws -> MeshCallInvite {
        guard let nickname = identity.nickname, NicknamePolicy.validationError(nickname) == nil else {
            throw MeshCallSignalingError.missingIdentity
        }
        let callID = UUID().uuidString.lowercased()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.lowercased()
        let payload = Self.signedPayload(callID: callID,
                                         nickname: nickname,
                                         displayName: identity.displayName,
                                         userID: identity.userID,
                                         deviceID: identity.deviceID,
                                         mediaPort: Self.mediaPort,
                                         timestamp: timestamp,
                                         nonce: nonce)
        let signature = try DeviceIdentityStore.shared.signMessage(payload)
        let invite = MeshCallInvite(version: 1,
                                    callID: callID,
                                    nickname: nickname,
                                    displayName: identity.displayName,
                                    userID: identity.userID,
                                    deviceID: identity.deviceID,
                                    publicKey: identity.signingPublicKey,
                                    keyFingerprint: identity.keyFingerprint,
                                    mediaPort: Self.mediaPort,
                                    timestamp: timestamp,
                                    nonce: nonce,
                                    signature: signature)
        guard var destinationAddress = IPv4Address(address, port: port) else {
            throw MeshCallSignalingError.invalidAddress
        }
        let sendFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard sendFD >= 0 else { throw MeshCallSignalingError.socketFailure(errno) }
        defer { close(sendFD) }
        let data = try JSONEncoder().encode(invite)
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
        guard sent == data.count else { throw MeshCallSignalingError.socketFailure(errno) }
        return invite
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
            guard let invite = try? JSONDecoder().decode(MeshCallInvite.self, from: data),
                  verify(invite),
                  let sourceAddress = Self.string(from: source) else { continue }
            DispatchQueue.main.async { self.onInvite?(invite, sourceAddress) }
        }
    }

    private func verify(_ invite: MeshCallInvite) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        guard now >= invite.timestamp,
              now - invite.timestamp <= 30,
              invite.deviceID != identity.deviceID,
              Self.signatureIsValid(invite),
              seenNonces[invite.nonce] == nil else { return false }
        seenNonces = seenNonces.filter { now - $0.value <= 30 }
        seenNonces[invite.nonce] = invite.timestamp
        return true
    }

    static func signatureIsValid(_ invite: MeshCallInvite) -> Bool {
        guard invite.version == 1,
              invite.mediaPort == Self.mediaPort,
              NicknamePolicy.validationError(invite.nickname) == nil,
              DeviceIdentityStore.fingerprint(for: invite.publicKey) == invite.keyFingerprint else {
            return false
        }
        let payload = signedPayload(callID: invite.callID,
                                    nickname: invite.nickname,
                                    displayName: invite.displayName,
                                    userID: invite.userID,
                                    deviceID: invite.deviceID,
                                    mediaPort: invite.mediaPort,
                                    timestamp: invite.timestamp,
                                    nonce: invite.nonce)
        return DeviceIdentityStore.verifyMessage(payload,
                                                 signature: invite.signature,
                                                 publicKey: invite.publicKey)
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
        if let active = peersByService.values.first(where: { NicknamePolicy.normalize($0.nickname) == target }) {
            return contact(active)
        }
        return cachedPeersByDevice.values
            .first(where: { NicknamePolicy.normalize($0.nickname) == target })
            .map(cachedContact)
    }

    private func publish(identity: DeviceIdentity) {
        publisher?.stop()
        publisher = nil
        guard let nickname = identity.nickname, !nickname.isEmpty else { return }
        let port = MeshCallSignaling.port
        let payload = signedPayload(nickname: nickname,
                                    userID: identity.userID,
                                    deviceID: identity.deviceID,
                                    port: port)
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
              let signature = text(record["sig"]),
              let address = numericAddress(sender.addresses),
              deviceID != identity?.deviceID else { return }
        let port = UInt16(clamping: sender.port)
        let payload = signedPayload(nickname: nickname, userID: userID, deviceID: deviceID, port: port)
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
            address: address,
            port: port
        )
        cachedPeersByDevice[deviceID] = CachedMeshPeer(userID: userID,
                                                       deviceID: deviceID,
                                                       nickname: nickname,
                                                       displayName: text(record["name"]) ?? nickname,
                                                       keyFingerprint: fingerprint,
                                                       address: address,
                                                       port: port,
                                                       lastSeen: Int64(Date().timeIntervalSince1970))
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
                         meshPort: peer.port)
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
                         meshPort: peer.port)
    }

    private func loadCache() {
        let now = Int64(Date().timeIntervalSince1970)
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? JSONDecoder().decode([CachedMeshPeer].self, from: data) else { return }
        cachedPeersByDevice = Dictionary(uniqueKeysWithValues: cached
            .filter { now >= $0.lastSeen && now - $0.lastSeen <= Self.cacheTTL }
            .map { ($0.deviceID, $0) })
    }

    private func saveCache() {
        let now = Int64(Date().timeIntervalSince1970)
        cachedPeersByDevice = cachedPeersByDevice.filter {
            now >= $0.value.lastSeen && now - $0.value.lastSeen <= Self.cacheTTL
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
                               port: UInt16) -> Data {
        Data("\(NicknamePolicy.normalize(nickname))\n\(userID)\n\(deviceID)\n\(port)".utf8)
    }

    private func numericAddress(_ addresses: [Data]?) -> String? {
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
        return candidates.sorted { $0.1 < $1.1 }.first?.0
    }

    private func addressFamily(_ data: Data) -> sa_family_t {
        data.withUnsafeBytes { raw in
            raw.baseAddress?.assumingMemoryBound(to: sockaddr.self).pointee.sa_family ?? 0
        }
    }
}

final class NicknameDirectoryController: ObservableObject {
    @Published var proposedNickname = ""
    @Published var searchQuery = ""
    @Published private(set) var currentNickname: String?
    @Published private(set) var claimKind: NicknameClaimKind
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var results: [DirectoryContact] = []
    @Published private(set) var meshPeers: [DirectoryContact] = []
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?

    var onIdentityChanged: ((DeviceIdentity) -> Void)?
    var onIncomingMeshInvite: ((MeshCallInvite, String) -> Void)?

    private var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    private let mesh = MeshNicknameDirectory()
    private let signaling: MeshCallSignaling

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
            self.refreshLocalResults()
            self.detectLocalConflict()
        }
        signaling.onInvite = { [weak self] invite, address in
            guard let self else { return }
            self.onIncomingMeshInvite?(invite, address)
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
        signaling.update(identity: identity)
        mesh.start(identity: identity)
        reconcileProvisionalNickname()
    }

    func sendMeshInvite(to address: String, port: UInt16?) throws -> MeshCallInvite {
        try signaling.sendInvite(to: address, port: port ?? MeshCallSignaling.port)
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
        refreshLocalResults()
        guard !query.isEmpty else { return }
        if !configuration.hasDirectoryAPI { return }
        isWorking = true
        Task {
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
                let meshDeviceIDs = Set(results.filter { $0.source == .mesh }.map(\.deviceID))
                results += remote.filter { !meshDeviceIDs.contains($0.deviceID) }
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func meshContact(named nickname: String) -> DirectoryContact? {
        mesh.contact(named: nickname)
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

    private func refreshLocalResults() {
        let query = NicknamePolicy.normalize(searchQuery)
        results = meshPeers.filter {
            query.isEmpty || NicknamePolicy.normalize($0.nickname).contains(query)
        }
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
