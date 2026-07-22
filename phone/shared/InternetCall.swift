import Combine
import Foundation
import LiveKit

enum InternetCallState: String {
    case idle = "Idle"
    case registering = "Registering device"
    case ringing = "Ringing"
    case connecting = "Connecting"
    case connected = "Connected"
    case reconnecting = "Reconnecting"
    case ended = "Ended"
    case failed = "Failed"
}

enum InternetCallError: LocalizedError {
    case notConfigured
    case invalidResponse
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Internet calling is not configured. Set the API or LiveKit development URL in Settings."
        case .invalidResponse:
            return "The call service returned an invalid response."
        case let .server(code, message):
            return "Call service error \(code): \(message)"
        }
    }
}

struct DeviceRegistrationRequest: Encodable {
    let userID: String
    let deviceID: String
    let displayName: String
    let signingPublicKey: String
    let keyFingerprint: String
    let platform: String
    let voipPushToken: String?
    let capabilities: [String]
}

struct CreateInternetCallRequest: Encodable {
    let callee: String
    let callerUserID: String
    let callerDeviceID: String
    let audio: Bool
    let video: Bool
}

struct InternetCallSession: Decodable {
    let callID: String
    let roomID: String
    let liveKitURL: String
    let token: String
    let mediaKey: String?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case roomID = "room_id"
        case liveKitURL = "livekit_url"
        case token
        case mediaKey = "media_key"
    }
}

struct IncomingInternetCall: Decodable, Identifiable, Equatable {
    let callID: String
    let caller: String
    let audio: Bool
    let video: Bool
    let createdAt: Int64

    var id: String { callID }

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case caller
        case audio
        case video
        case createdAt = "created_at"
    }
}

struct AccountDevice: Decodable, Identifiable, Equatable {
    let deviceID: String
    let displayName: String
    let platform: String
    let keyFingerprint: String
    let lastSeen: Int64
    let current: Bool
    let revoked: Bool

    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case displayName = "display_name"
        case platform
        case keyFingerprint = "key_fingerprint"
        case lastSeen = "last_seen"
        case current
        case revoked
    }
}

struct AccountSnapshot: Decodable, Equatable {
    let accountID: String
    let nickname: String?
    let devices: [AccountDevice]

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case nickname
        case devices
    }
}

struct DeviceLinkCode: Decodable, Equatable {
    let linkCode: String
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case linkCode = "link_code"
        case expiresAt = "expires_at"
    }
}

struct GroupChatSummary: Decodable, Identifiable, Equatable {
    let chatID: String
    let title: String
    let members: [String]
    let createdAt: Int64
    let lastMessage: String?
    let lastMessageAt: Int64?

    var id: String { chatID }

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case title
        case members
        case createdAt = "created_at"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
    }
}

struct GroupChatMessage: Decodable, Identifiable, Equatable {
    let messageID: Int64
    let chatID: String
    let senderUserID: String
    let senderNickname: String
    let text: String
    let createdAt: Int64

    var id: Int64 { messageID }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case chatID = "chat_id"
        case senderUserID = "sender_user_id"
        case senderNickname = "sender_nickname"
        case text
        case createdAt = "created_at"
    }
}

private struct IncomingInternetCallsResponse: Decodable {
    let calls: [IncomingInternetCall]
}

private struct GroupChatsResponse: Decodable {
    let chats: [GroupChatSummary]
}

private struct GroupMessagesResponse: Decodable {
    let messages: [GroupChatMessage]
}

private struct InternetDataMessage: Codable {
    enum Kind: String, Codable {
        case chat
        case reaction
    }

    let kind: Kind
    let value: String
}

final class InternetCallAPI {
    private let configuration: InternetCallConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: InternetCallConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func register(identity: DeviceIdentity, voipToken: String?) async throws {
        guard !configuration.isDevelopmentDirect else { return }
        let body = DeviceRegistrationRequest(
            userID: identity.userID,
            deviceID: identity.deviceID,
            displayName: identity.displayName,
            signingPublicKey: identity.signingPublicKey,
            keyFingerprint: identity.keyFingerprint,
            platform: platformName,
            voipPushToken: voipToken,
            capabilities: ["audio", "video", "mesh", "webrtc"]
        )
        let _: EmptyResponse = try await request(path: "/v1/devices/register", method: "POST", body: body, identity: identity)
    }

    func createCall(callee: String,
                    identity: DeviceIdentity,
                    audio: Bool,
                    video: Bool) async throws -> InternetCallSession {
        if configuration.isDevelopmentDirect {
            return InternetCallSession(
                callID: UUID().uuidString.lowercased(),
                roomID: "development",
                liveKitURL: configuration.liveKitURL,
                token: configuration.developmentRoomToken,
                mediaKey: nil
            )
        }
        let body = CreateInternetCallRequest(
            callee: callee,
            callerUserID: identity.userID,
            callerDeviceID: identity.deviceID,
            audio: audio,
            video: video
        )
        return try await request(path: "/v1/calls", method: "POST", body: body, identity: identity)
    }

    func joinCall(callID: String, identity: DeviceIdentity) async throws -> InternetCallSession {
        struct JoinRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        let body = JoinRequest(userID: identity.userID, deviceID: identity.deviceID)
        return try await request(path: "/v1/calls/\(callID)/join", method: "POST", body: body, identity: identity)
    }

    func incomingCalls(identity: DeviceIdentity) async throws -> [IncomingInternetCall] {
        struct IncomingRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        guard !configuration.isDevelopmentDirect else { return [] }
        let body = IncomingRequest(userID: identity.userID, deviceID: identity.deviceID)
        let response: IncomingInternetCallsResponse = try await request(
            path: "/v1/calls/incoming",
            method: "POST",
            body: body,
            identity: identity
        )
        return response.calls
    }

    func claimNickname(_ nickname: String,
                       identity: DeviceIdentity) async throws -> NicknameClaimResponse {
        let body = NicknameClaimRequest(nickname: nickname,
                                        userID: identity.userID,
                                        deviceID: identity.deviceID)
        return try await request(path: "/v1/directory/nicknames/claim",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func searchNicknames(_ query: String,
                         identity: DeviceIdentity) async throws -> NicknameSearchResponse {
        let body = NicknameSearchRequest(query: query, limit: 20)
        return try await request(path: "/v1/directory/search",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func account(identity: DeviceIdentity) async throws -> AccountSnapshot {
        struct AccountRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        let body = AccountRequest(userID: identity.userID, deviceID: identity.deviceID)
        return try await request(path: "/v1/account", method: "POST", body: body, identity: identity)
    }

    func createLinkCode(identity: DeviceIdentity) async throws -> DeviceLinkCode {
        struct AccountRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        let body = AccountRequest(userID: identity.userID, deviceID: identity.deviceID)
        return try await request(path: "/v1/account/link-code", method: "POST", body: body, identity: identity)
    }

    func linkDevice(code: String, identity: DeviceIdentity) async throws -> AccountSnapshot {
        struct LinkRequest: Encodable {
            let userID: String
            let deviceID: String
            let linkCode: String
        }
        let body = LinkRequest(userID: identity.userID,
                               deviceID: identity.deviceID,
                               linkCode: code)
        return try await request(path: "/v1/account/link", method: "POST", body: body, identity: identity)
    }

    func revokeDevice(_ deviceID: String, identity: DeviceIdentity) async throws {
        struct RevokeRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        let path = "/v1/account/devices/\(deviceID)/revoke"
        let body = RevokeRequest(userID: identity.userID, deviceID: identity.deviceID)
        let _: EmptyResponse = try await request(path: path,
                                                 method: "POST",
                                                 body: body,
                                                 identity: identity)
    }

    func createGroupChat(title: String?,
                         members: [String],
                         identity: DeviceIdentity) async throws -> GroupChatSummary {
        struct CreateRequest: Encodable {
            let creatorUserID: String
            let creatorDeviceID: String
            let title: String?
            let members: [String]
        }
        let body = CreateRequest(creatorUserID: identity.userID,
                                 creatorDeviceID: identity.deviceID,
                                 title: title,
                                 members: members)
        return try await request(path: "/v1/chats",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func groupChats(identity: DeviceIdentity) async throws -> [GroupChatSummary] {
        struct ListRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        let body = ListRequest(userID: identity.userID, deviceID: identity.deviceID)
        let response: GroupChatsResponse = try await request(path: "/v1/chats/list",
                                                             method: "POST",
                                                             body: body,
                                                             identity: identity)
        return response.chats
    }

    func sendGroupMessage(chatID: String,
                          clientMessageID: String,
                          text: String,
                          identity: DeviceIdentity) async throws -> GroupChatMessage {
        struct SendRequest: Encodable {
            let userID: String
            let deviceID: String
            let clientMessageID: String
            let text: String
        }
        let body = SendRequest(userID: identity.userID,
                               deviceID: identity.deviceID,
                               clientMessageID: clientMessageID,
                               text: text)
        return try await request(path: "/v1/chats/\(chatID)/messages",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func groupMessages(chatID: String,
                       afterMessageID: Int64,
                       limit: UInt16 = 100,
                       identity: DeviceIdentity) async throws -> [GroupChatMessage] {
        struct ListRequest: Encodable {
            let userID: String
            let deviceID: String
            let afterMessageID: Int64
            let limit: UInt16
        }
        let body = ListRequest(userID: identity.userID,
                               deviceID: identity.deviceID,
                               afterMessageID: afterMessageID,
                               limit: limit)
        let response: GroupMessagesResponse = try await request(
            path: "/v1/chats/\(chatID)/messages/list",
            method: "POST",
            body: body,
            identity: identity
        )
        return response.messages
    }

    private func request<Body: Encodable, Response: Decodable>(path: String,
                                                                method: String,
                                                                body: Body,
                                                                identity: DeviceIdentity) async throws -> Response {
        guard let base = URL(string: configuration.apiBaseURL),
              let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw InternetCallError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let encodedBody = try encoder.encode(body)
        request.httpBody = encodedBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let proof = try DeviceIdentityStore.shared.signRequest(
            identity: identity,
            method: method,
            path: path,
            body: encodedBody
        )
        request.setValue(proof.deviceID, forHTTPHeaderField: "X-TRINET-Device-ID")
        request.setValue(proof.timestamp, forHTTPHeaderField: "X-TRINET-Timestamp")
        request.setValue(proof.nonce, forHTTPHeaderField: "X-TRINET-Nonce")
        request.setValue(proof.signature, forHTTPHeaderField: "X-TRINET-Signature")
        if !configuration.accessToken.isEmpty {
            request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw InternetCallError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw InternetCallError.server(http.statusCode, message)
        }
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try decoder.decode(Response.self, from: data)
    }

    private var platformName: String {
#if os(iOS)
        return "ios"
#elseif os(macOS)
        return "macos"
#else
        return "apple"
#endif
    }
}

private struct EmptyResponse: Codable {}

final class AccountDeviceController: ObservableObject {
    @Published private(set) var devices: [AccountDevice] = []
    @Published private(set) var accountID: String
    @Published private(set) var nickname: String?
    @Published private(set) var generatedLinkCode: String?
    @Published private(set) var linkCodeExpiresAt: Date?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var linkCodeInput = ""

    var onIdentityChanged: ((DeviceIdentity) -> Void)?

    private var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI

    init(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        accountID = identity.userID
        nickname = identity.nickname
        api = InternetCallAPI(configuration: configuration)
    }

    func update(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        accountID = identity.userID
        nickname = identity.nickname
        api = InternetCallAPI(configuration: configuration)
    }

    func sync() {
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else { return }
        run { identity, api in
            try await api.register(identity: identity,
                                   voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
            return try await api.account(identity: identity)
        }
    }

    func createLinkCode() {
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else {
            statusMessage = "Configure the Directory API before linking another device."
            return
        }
        isWorking = true
        statusMessage = nil
        let identity = self.identity
        let api = self.api
        Task { @MainActor in
            do {
                try await api.register(identity: identity,
                                       voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
                let result = try await api.createLinkCode(identity: identity)
                generatedLinkCode = result.linkCode
                linkCodeExpiresAt = Date(timeIntervalSince1970: TimeInterval(result.expiresAt))
                statusMessage = "Use this single-use code on the new device within 10 minutes."
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func joinAccount() {
        let code = linkCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else {
            statusMessage = "Enter the link code from a trusted device."
            return
        }
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else {
            statusMessage = "Configure the same Directory API on both devices first."
            return
        }
        isWorking = true
        statusMessage = nil
        let identity = self.identity
        let api = self.api
        Task { @MainActor in
            do {
                try await api.register(identity: identity,
                                       voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
                let snapshot = try await api.linkDevice(code: code, identity: identity)
                try apply(snapshot)
                linkCodeInput = ""
                statusMessage = "This device now belongs to @\(snapshot.nickname ?? "your account")."
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    func revoke(_ device: AccountDevice) {
        guard !device.current else {
            statusMessage = "Revoke this device from another trusted device."
            return
        }
        isWorking = true
        statusMessage = nil
        let identity = self.identity
        let api = self.api
        Task { @MainActor in
            do {
                try await api.revokeDevice(device.deviceID, identity: identity)
                let snapshot = try await api.account(identity: identity)
                try apply(snapshot)
                statusMessage = "\(device.displayName) was revoked."
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func run(_ operation: @escaping (DeviceIdentity, InternetCallAPI) async throws -> AccountSnapshot) {
        isWorking = true
        let identity = self.identity
        let api = self.api
        Task { @MainActor in
            do {
                try apply(try await operation(identity, api))
                statusMessage = nil
            } catch {
                statusMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    @MainActor
    private func apply(_ snapshot: AccountSnapshot) throws {
        let updated = try DeviceIdentityStore.shared.adoptAccount(userID: snapshot.accountID,
                                                                  nickname: snapshot.nickname)
        identity = updated
        accountID = snapshot.accountID
        nickname = snapshot.nickname
        devices = snapshot.devices
        onIdentityChanged?(updated)
    }
}

final class GroupChatController: ObservableObject {
    @Published private(set) var chats: [GroupChatSummary] = []
    @Published private(set) var messages: [GroupChatMessage] = []
    @Published private(set) var activeChatID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var titleInput = ""
    @Published var membersInput = ""
    @Published var draft = ""

    var activeChat: GroupChatSummary? {
        chats.first { $0.chatID == activeChatID }
    }

    private var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    private var pollTimer: Timer?
    private var refreshInFlight = false

    init(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
    }

    func update(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        startPolling()
    }

    func startPolling() {
        stopPolling()
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else {
            statusMessage = "Configure the Directory API to use persistent group chats."
            return
        }
        let identity = self.identity
        let api = self.api
        Task { @MainActor [weak self] in
            do {
                try await api.register(identity: identity,
                                       voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
                self?.statusMessage = nil
                self?.refresh()
            } catch {
                self?.statusMessage = error.localizedDescription
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        let invalidate = { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
        }
        if Thread.isMainThread {
            invalidate()
        } else {
            DispatchQueue.main.async(execute: invalidate)
        }
    }

    func refresh() {
        guard configuration.hasDirectoryAPI,
              !configuration.isDevelopmentDirect,
              !refreshInFlight else { return }
        refreshInFlight = true
        let identity = self.identity
        let api = self.api
        let selectedChatID = activeChatID
        let afterMessageID = selectedChatID == nil ? 0 : (messages.last?.messageID ?? 0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.refreshInFlight = false }
            do {
                self.chats = try await api.groupChats(identity: identity)
                if let selectedChatID {
                    let received = try await api.groupMessages(chatID: selectedChatID,
                                                               afterMessageID: afterMessageID,
                                                               identity: identity)
                    guard self.activeChatID == selectedChatID else { return }
                    self.merge(received)
                }
                self.statusMessage = nil
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func createGroup() {
        let members = parsedMembers()
        guard !members.isEmpty else {
            statusMessage = "Enter at least one participant nickname."
            return
        }
        let title = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        statusMessage = nil
        let identity = self.identity
        let api = self.api
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false }
            do {
                let chat = try await api.createGroupChat(title: title.isEmpty ? nil : title,
                                                         members: members,
                                                         identity: identity)
                self.chats.removeAll { $0.chatID == chat.chatID }
                self.chats.insert(chat, at: 0)
                self.titleInput = ""
                self.membersInput = ""
                self.open(chat)
                self.statusMessage = "Group created."
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func open(_ chat: GroupChatSummary) {
        activeChatID = chat.chatID
        messages = []
        loadMessages(chatID: chat.chatID, afterMessageID: 0)
    }

    func closeChat() {
        activeChatID = nil
        messages = []
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chatID = activeChatID, !text.isEmpty else { return }
        isWorking = true
        statusMessage = nil
        let identity = self.identity
        let api = self.api
        let clientMessageID = UUID().uuidString.lowercased()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false }
            do {
                let message = try await api.sendGroupMessage(chatID: chatID,
                                                             clientMessageID: clientMessageID,
                                                             text: text,
                                                             identity: identity)
                guard self.activeChatID == chatID else { return }
                self.draft = ""
                self.merge([message])
                self.refresh()
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func loadMessages(chatID: String, afterMessageID: Int64) {
        let identity = self.identity
        let api = self.api
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let received = try await api.groupMessages(chatID: chatID,
                                                           afterMessageID: afterMessageID,
                                                           identity: identity)
                guard self.activeChatID == chatID else { return }
                self.merge(received)
                self.statusMessage = nil
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func parsedMembers() -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        var members: [String] = []
        for component in membersInput.components(separatedBy: separators) {
            let nickname = NicknamePolicy.normalize(component.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
            guard !nickname.isEmpty, !members.contains(nickname) else { continue }
            members.append(nickname)
        }
        return members
    }

    private func merge(_ received: [GroupChatMessage]) {
        for message in received where !messages.contains(where: { $0.messageID == message.messageID }) {
            messages.append(message)
        }
        messages.sort { $0.messageID < $1.messageID }
    }
}

final class InternetCallController: NSObject, ObservableObject, RoomDelegate, @unchecked Sendable {
    @Published private(set) var state: InternetCallState = .idle
    @Published private(set) var callID: String?
    @Published private(set) var participantName = ""
    @Published private(set) var localVideoTrack: LocalVideoTrack?
    @Published private(set) var remoteVideoTrack: RemoteVideoTrack?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraEnabled = true

    var onChat: ((String) -> Void)?
    var onReaction: ((String) -> Void)?
    var onIncomingCall: ((IncomingInternetCall) -> Void)?

    private(set) var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    private var room: Room?
    private var incomingPollTimer: Timer?
    private var reportedIncomingCallIDs = Set<String>()
    private var registeredVoipToken = UserDefaults.standard.string(forKey: "voipPushToken")

    init(identity: DeviceIdentity,
         configuration: InternetCallConfiguration = .load()) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        super.init()
    }

    func update(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
    }

    func startIncomingPolling(voipToken: String? = nil) {
        stopIncomingPolling()
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else { return }
        if let voipToken { registeredVoipToken = voipToken }
        Task { [weak self] in
            guard let self else { return }
            try? await self.api.register(identity: self.identity, voipToken: self.registeredVoipToken)
            await self.pollIncomingCalls()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.incomingPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { await self?.pollIncomingCalls() }
            }
        }
    }

    func stopIncomingPolling() {
        let invalidate = { [weak self] in
            self?.incomingPollTimer?.invalidate()
            self?.incomingPollTimer = nil
        }
        if Thread.isMainThread { invalidate() } else { DispatchQueue.main.async(execute: invalidate) }
    }

    private func pollIncomingCalls() async {
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else { return }
        guard let calls = try? await api.incomingCalls(identity: identity) else { return }
        guard let incoming = calls.first(where: { !reportedIncomingCallIDs.contains($0.callID) }) else { return }
        setMain {
            guard !self.reportedIncomingCallIDs.contains(incoming.callID) else { return }
            self.reportedIncomingCallIDs.insert(incoming.callID)
            self.onIncomingCall?(incoming)
        }
    }

    func registerDevice(voipToken: String? = nil) async throws {
        registeredVoipToken = voipToken
        setState(.registering)
        try await api.register(identity: identity, voipToken: registeredVoipToken)
        setState(.idle)
    }

    func start(callee: String, audio: Bool = true, video: Bool = true) async throws {
        guard configuration.isConfigured else { throw InternetCallError.notConfigured }
        setState(.registering)
        try await api.register(identity: identity, voipToken: registeredVoipToken)
        let session = try await api.createCall(callee: callee,
                                               identity: identity,
                                               audio: audio,
                                               video: video)
        try await connect(session: session, audio: audio, video: video)
    }

    func join(callID: String, audio: Bool = true, video: Bool = true) async throws {
        guard configuration.isConfigured else { throw InternetCallError.notConfigured }
        setState(.connecting)
        let session = try await api.joinCall(callID: callID, identity: identity)
        try await connect(session: session, audio: audio, video: video)
    }

    private func connect(session: InternetCallSession, audio: Bool, video: Bool) async throws {
        setState(.connecting)
        setMain { self.callID = session.callID }
        let encryption = session.mediaKey.map { EncryptionOptions.sharedKey($0) }
        let options = RoomOptions(adaptiveStream: true,
                                  dynacast: true,
                                  encryptionOptions: encryption,
                                  reportRemoteTrackStatistics: true,
                                  singlePeerConnection: true)
        let newRoom = Room(delegate: self, roomOptions: options)
        room = newRoom
        do {
            try await newRoom.connect(url: session.liveKitURL, token: session.token)
            let cameraPublication = try await newRoom.localParticipant.setCamera(enabled: video)
            let microphonePublication = try await newRoom.localParticipant.setMicrophone(enabled: audio)
            _ = microphonePublication
            setMain {
                self.localVideoTrack = cameraPublication?.track as? LocalVideoTrack
                self.isCameraEnabled = video
                self.isMuted = !audio
                self.state = .connected
            }
        } catch {
            setFailure(error)
            await newRoom.disconnect()
            room = nil
            throw error
        }
    }

    func setMuted(_ muted: Bool) {
        guard let room else { return }
        Task {
            do {
                _ = try await room.localParticipant.setMicrophone(enabled: !muted)
                setMain { self.isMuted = muted }
            } catch {
                setFailure(error)
            }
        }
    }

    func setCamera(enabled: Bool) {
        guard let room else { return }
        Task {
            do {
                let publication = try await room.localParticipant.setCamera(enabled: enabled)
                setMain {
                    self.localVideoTrack = publication?.track as? LocalVideoTrack
                    self.isCameraEnabled = enabled
                }
            } catch {
                setFailure(error)
            }
        }
    }

    func sendChat(_ text: String) {
        publish(kind: .chat, value: text)
    }

    func sendReaction(_ value: String) {
        publish(kind: .reaction, value: value)
    }

    private func publish(kind: InternetDataMessage.Kind, value: String) {
        guard let room else { return }
        Task {
            do {
                let data = try JSONEncoder().encode(InternetDataMessage(kind: kind, value: value))
                let options = DataPublishOptions(topic: "trinet.control", reliable: true)
                try await room.localParticipant.publish(data: data, options: options)
            } catch {
                setFailure(error)
            }
        }
    }

    func disconnect() {
        let oldRoom = room
        room = nil
        setMain {
            self.state = .ended
            self.callID = nil
            self.participantName = ""
            self.localVideoTrack = nil
            self.remoteVideoTrack = nil
        }
        Task { await oldRoom?.disconnect() }
    }

    func room(_ room: Room,
              didUpdateConnectionState connectionState: ConnectionState,
              from oldConnectionState: ConnectionState) {
        switch connectionState {
        case .connected:
            setState(.connected)
        case .reconnecting:
            setState(.reconnecting)
        case .disconnected:
            setState(.ended)
        default:
            break
        }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let label = participantLabel(participant)
        setMain { self.participantName = label }
    }

    func room(_ room: Room,
              participant: RemoteParticipant,
              didSubscribeTrack publication: RemoteTrackPublication) {
        guard let video = publication.track as? RemoteVideoTrack else { return }
        let label = participantLabel(participant)
        setMain {
            self.participantName = label
            self.remoteVideoTrack = video
        }
    }

    func room(_ room: Room,
              participant: RemoteParticipant,
              didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard publication.track is RemoteVideoTrack else { return }
        setMain { self.remoteVideoTrack = nil }
    }

    func room(_ room: Room,
              participant: RemoteParticipant?,
              didReceiveData data: Data,
              forTopic topic: String,
              encryptionType: EncryptionType) {
        guard topic == "trinet.control",
              let message = try? JSONDecoder().decode(InternetDataMessage.self, from: data) else { return }
        DispatchQueue.main.async {
            switch message.kind {
            case .chat:
                self.onChat?(message.value)
            case .reaction:
                self.onReaction?(message.value)
            }
        }
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        setFailure(error ?? InternetCallError.invalidResponse)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error { setFailure(error) } else { setState(.ended) }
    }

    private func setState(_ state: InternetCallState) {
        setMain {
            self.state = state
            if state != .failed { self.errorMessage = nil }
        }
    }

    private func participantLabel(_ participant: Participant) -> String {
        if let name = participant.name, !name.isEmpty { return name }
        return participant.identity?.stringValue ?? "Peer"
    }

    private func setFailure(_ error: Error) {
        setMain {
            self.state = .failed
            self.errorMessage = error.localizedDescription
        }
    }

    private func setMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}
