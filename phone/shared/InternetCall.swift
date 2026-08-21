import Combine
import Foundation
import LiveKit

enum InternetCallState: String {
    case idle = "Idle"
    case registering = "Calling"
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

enum InternetCallCreateRetryPolicy {
    static let maximumAttempts = 3

    static func shouldRetryHTTP(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500 ... 599).contains(statusCode)
    }

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let callError = error as? InternetCallError {
            switch callError {
            case .notConfigured:
                return false
            case .invalidResponse:
                return true
            case let .server(statusCode, _):
                return shouldRetryHTTP(statusCode: statusCode)
            }
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled && urlError.code != .badURL &&
                urlError.code != .unsupportedURL
        }
        return error is DecodingError
    }

    static func retryDelayNanoseconds(afterFailedAttempt attempt: Int) -> UInt64 {
        UInt64(max(1, attempt)) * 350_000_000
    }
}

enum InternetDirectMessageDeliveryError: LocalizedError {
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .unconfirmed:
            return "The service did not confirm delivery. Check the conversation before sending again."
        }
    }
}

struct DeviceRegistrationRequest: Encodable {
    let userID: String
    let deviceID: String
    let displayName: String
    let signingPublicKey: String
    let textEncryptionPublicKey: String?
    let keyFingerprint: String
    let platform: String
    let voipPushToken: String?
    let alertPushToken: String?
    let pushEnvironment: String?
    let capabilities: [String]
}

struct CreateInternetCallRequest: Encodable {
    let clientCallID: String
    let callee: String
    let callerUserID: String
    let callerDeviceID: String
    let audio: Bool
    let video: Bool
}

struct InternetCallStatus: Decodable, Equatable {
    let callID: String
    let callUUID: String
    let status: String
    let role: String
    let targetStatus: String?
    let answeredHere: Bool
    let createdAt: Int64
    let answeredAt: Int64?
    let endedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case callUUID = "call_uuid"
        case status
        case role
        case targetStatus = "target_status"
        case answeredHere = "answered_here"
        case createdAt = "created_at"
        case answeredAt = "answered_at"
        case endedAt = "ended_at"
    }

    var isTerminal: Bool {
        ["ended", "declined", "cancelled", "missed"].contains(status)
    }
}

struct InternetCallMedia: Codable, Equatable {
    let audio: Bool
    let video: Bool

    static let audioOnly = InternetCallMedia(audio: true, video: false)
    static let audioVideo = InternetCallMedia(audio: true, video: true)

    static func outgoing(cameraOff: Bool) -> InternetCallMedia {
        cameraOff ? .audioOnly : .audioVideo
    }
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
    var unreadCount: Int

    var id: String { chatID }

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case title
        case members
        case createdAt = "created_at"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case unreadCount = "unread_count"
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

struct DirectMessageRecipientAPIResponse: Decodable {
    let cryptoVersion: UInt8
    let nickname: String
    let userID: String
    let devices: [DirectMessageRecipientAPIDevice]

    enum CodingKeys: String, CodingKey {
        case cryptoVersion = "crypto_version"
        case nickname
        case userID = "user_id"
        case devices
    }
}

struct DirectMessageRecipientAPIDevice: Decodable {
    let deviceID: String
    let textEncryptionPublicKey: String
    let textEncryptionKeyFingerprint: String
    let keyFingerprint: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case textEncryptionPublicKey = "text_encryption_public_key"
        case textEncryptionKeyFingerprint = "text_encryption_key_fingerprint"
        case keyFingerprint = "key_fingerprint"
    }
}

struct DirectMessageAPIEnvelope: Encodable {
    let cryptoVersion: UInt8
    let recipientDeviceID: String
    let recipientKeyFingerprint: String
    let ephemeralPublicKey: String
    let nonce: String
    let ciphertext: String
    let senderSignature: String
}

struct DirectMessageSendAPIResponse: Decodable {
    let messageID: Int64
    let clientMessageID: String
    let recipientUserID: String
    let recipientNickname: String
    let createdAt: Int64
    let inserted: Bool

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case recipientUserID = "recipient_user_id"
        case recipientNickname = "recipient_nickname"
        case createdAt = "created_at"
        case inserted
    }
}

struct DirectMessageInboxAPIResponse: Decodable {
    let messages: [DirectMessageInboxAPIMessage]
    let totalUnreadCount: Int

    enum CodingKeys: String, CodingKey {
        case messages
        case totalUnreadCount = "total_unread_count"
    }
}

struct DirectMessageInboxAPIMessage: Decodable {
    let messageID: Int64
    let clientMessageID: String
    let senderUserID: String
    let senderDeviceID: String
    let senderNickname: String
    let senderSigningPublicKey: String
    let senderKeyFingerprint: String
    let recipientNickname: String
    let cryptoVersion: UInt8
    let recipientDeviceID: String
    let recipientKeyFingerprint: String
    let ephemeralPublicKey: String
    let nonce: String
    let ciphertext: String
    let senderSignature: String
    let createdAt: Int64
    let read: Bool

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case clientMessageID = "client_message_id"
        case senderUserID = "sender_user_id"
        case senderDeviceID = "sender_device_id"
        case senderNickname = "sender_nickname"
        case senderSigningPublicKey = "sender_signing_public_key"
        case senderKeyFingerprint = "sender_key_fingerprint"
        case recipientNickname = "recipient_nickname"
        case cryptoVersion = "crypto_version"
        case recipientDeviceID = "recipient_device_id"
        case recipientKeyFingerprint = "recipient_key_fingerprint"
        case ephemeralPublicKey = "ephemeral_public_key"
        case nonce
        case ciphertext
        case senderSignature = "sender_signature"
        case createdAt = "created_at"
        case read
    }
}

struct DirectMessageReadAPIResponse: Decodable {
    let lastReadMessageID: Int64
    let totalUnreadCount: Int

    enum CodingKeys: String, CodingKey {
        case lastReadMessageID = "last_read_message_id"
        case totalUnreadCount = "total_unread_count"
    }
}

struct GroupChatsResponse: Decodable {
    let chats: [GroupChatSummary]
    let totalUnreadCount: Int

    enum CodingKeys: String, CodingKey {
        case chats
        case totalUnreadCount = "total_unread_count"
    }
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
        let defaults = UserDefaults.standard
        let textEncryptionPublicKey = try? DeviceIdentityStore.shared
            .textEncryptionPublicKey()
            .base64EncodedString()
        let body = DeviceRegistrationRequest(
            userID: identity.userID,
            deviceID: identity.deviceID,
            displayName: identity.displayName,
            signingPublicKey: identity.signingPublicKey,
            textEncryptionPublicKey: textEncryptionPublicKey,
            keyFingerprint: identity.keyFingerprint,
            platform: platformName,
            voipPushToken: voipToken,
            alertPushToken: defaults.string(forKey: "alertPushToken"),
            pushEnvironment: defaults.string(forKey: "pushEnvironment"),
            capabilities: ["audio", "video", "mesh", "webrtc", "e2ee-direct-message"]
        )
        let _: EmptyResponse = try await request(path: "/v1/devices/register", method: "POST", body: body, identity: identity)
    }

    func createCall(callee: String,
                    identity: DeviceIdentity,
                    clientCallID: String,
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
            clientCallID: clientCallID,
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

    func cancelCall(callID: String, identity: DeviceIdentity) async throws {
        struct EndRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        guard !configuration.isDevelopmentDirect else { return }
        let body = EndRequest(userID: identity.userID, deviceID: identity.deviceID)
        let _: EmptyResponse = try await request(
            path: "/v1/calls/\(callID)/cancel",
            method: "POST",
            body: body,
            identity: identity
        )
    }

    func declineCall(callID: String, identity: DeviceIdentity) async throws -> InternetCallStatus {
        let body = CallParticipantRequest(userID: identity.userID,
                                          deviceID: identity.deviceID)
        guard !configuration.isDevelopmentDirect else {
            return developmentStatus(callID: callID, status: "declined", role: "callee")
        }
        return try await request(path: "/v1/calls/\(callID)/decline",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func callStatus(callID: String, identity: DeviceIdentity) async throws -> InternetCallStatus {
        let body = CallParticipantRequest(userID: identity.userID,
                                          deviceID: identity.deviceID)
        guard !configuration.isDevelopmentDirect else {
            return developmentStatus(callID: callID, status: "active", role: "caller")
        }
        return try await request(path: "/v1/calls/\(callID)/status",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func endCall(callID: String, identity: DeviceIdentity) async throws -> InternetCallStatus {
        let body = CallParticipantRequest(userID: identity.userID,
                                          deviceID: identity.deviceID)
        guard !configuration.isDevelopmentDirect else {
            return developmentStatus(callID: callID, status: "ended", role: "caller")
        }
        return try await request(path: "/v1/calls/\(callID)/end",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
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

    func directMessageRecipient(nickname: String,
                                identity: DeviceIdentity) async throws
    -> DirectMessageRecipientAPIResponse {
        struct RecipientRequest: Encodable {
            let userID: String
            let deviceID: String
            let nickname: String
        }
        let body = RecipientRequest(userID: identity.userID,
                                    deviceID: identity.deviceID,
                                    nickname: nickname)
        return try await request(path: "/v1/direct-messages/recipients",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func sendDirectMessage(recipient: String,
                           clientMessageID: String,
                           envelopes: [InternetDirectMessageSealedEnvelope],
                           identity: DeviceIdentity) async throws
    -> DirectMessageSendAPIResponse {
        struct SendRequest: Encodable {
            let userID: String
            let deviceID: String
            let recipient: String
            let clientMessageID: String
            let envelopes: [DirectMessageAPIEnvelope]
        }
        let apiEnvelopes = envelopes.map {
            DirectMessageAPIEnvelope(cryptoVersion: $0.cryptoVersion,
                                     recipientDeviceID: $0.recipientDeviceID,
                                     recipientKeyFingerprint: $0.recipientKeyFingerprint,
                                     ephemeralPublicKey: $0.ephemeralPublicKey,
                                     nonce: $0.nonce,
                                     ciphertext: $0.ciphertext,
                                     senderSignature: $0.senderSignature)
        }
        let body = SendRequest(userID: identity.userID,
                               deviceID: identity.deviceID,
                               recipient: recipient,
                               clientMessageID: clientMessageID,
                               envelopes: apiEnvelopes)
        return try await request(path: "/v1/direct-messages",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func directMessageInbox(afterMessageID: Int64,
                            limit: UInt16 = 100,
                            identity: DeviceIdentity) async throws
    -> DirectMessageInboxAPIResponse {
        struct InboxRequest: Encodable {
            let userID: String
            let deviceID: String
            let afterMessageID: Int64
            let limit: UInt16
        }
        let body = InboxRequest(userID: identity.userID,
                                deviceID: identity.deviceID,
                                afterMessageID: afterMessageID,
                                limit: limit)
        return try await request(path: "/v1/direct-messages/inbox",
                                 method: "POST",
                                 body: body,
                                 identity: identity)
    }

    func markDirectMessagesRead(senderUserID: String,
                                throughMessageID: Int64,
                                identity: DeviceIdentity) async throws
    -> DirectMessageReadAPIResponse {
        struct ReadRequest: Encodable {
            let userID: String
            let deviceID: String
            let senderUserID: String
            let throughMessageID: Int64
        }
        let body = ReadRequest(userID: identity.userID,
                               deviceID: identity.deviceID,
                               senderUserID: senderUserID,
                               throughMessageID: throughMessageID)
        return try await request(path: "/v1/direct-messages/read",
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

    func groupChats(identity: DeviceIdentity) async throws -> GroupChatsResponse {
        struct ListRequest: Encodable {
            let userID: String
            let deviceID: String
        }
        let body = ListRequest(userID: identity.userID, deviceID: identity.deviceID)
        let response: GroupChatsResponse = try await request(path: "/v1/chats/list",
                                                             method: "POST",
                                                             body: body,
                                                             identity: identity)
        return response
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

    func markGroupChatRead(chatID: String,
                           throughMessageID: Int64,
                           identity: DeviceIdentity) async throws {
        struct MarkReadRequest: Encodable {
            let userID: String
            let deviceID: String
            let throughMessageID: Int64
        }
        let body = MarkReadRequest(userID: identity.userID,
                                   deviceID: identity.deviceID,
                                   throughMessageID: throughMessageID)
        let _: EmptyResponse = try await request(
            path: "/v1/chats/\(chatID)/read",
            method: "POST",
            body: body,
            identity: identity
        )
    }

    private func request<Body: Encodable, Response: Decodable>(path: String,
                                                                method: String,
                                                                body: Body,
                                                                identity: DeviceIdentity) async throws -> Response {
        guard let url = configuration.endpointURL(path: path) else {
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

    private func developmentStatus(callID: String,
                                   status: String,
                                   role: String) -> InternetCallStatus {
        InternetCallStatus(callID: callID,
                           callUUID: callID,
                           status: status,
                           role: role,
                           targetStatus: nil,
                           answeredHere: role == "callee" && status == "active",
                           createdAt: Int64(Date().timeIntervalSince1970),
                           answeredAt: status == "active" ? Int64(Date().timeIntervalSince1970) : nil,
                           endedAt: ["ended", "declined", "cancelled", "missed"].contains(status)
                               ? Int64(Date().timeIntervalSince1970) : nil)
    }
}

private struct CallParticipantRequest: Encodable {
    let userID: String
    let deviceID: String
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

struct ReceivedInternetDirectMessage: Identifiable, Equatable {
    let serverMessageID: Int64
    let clientMessageID: String
    let senderUserID: String
    let senderNickname: String
    let recipientNickname: String
    let text: String
    let createdAt: Date
    let serverCreatedAt: Date
    let read: Bool

    var id: String { clientMessageID }
}

private struct DirectMessageReadTarget: Codable {
    let senderUserID: String
    let throughMessageID: Int64
}

final class InternetDirectMessageController: ObservableObject {
    @Published private(set) var totalUnreadCount = 0
    @Published private(set) var statusMessage: String?

    var onMessage: ((ReceivedInternetDirectMessage) -> Void)?

    private var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    private var pollTimer: Timer?
    private var refreshInFlight = false
    private var generation = UUID()
    private var cursor: Int64 = 0
    private var readTargets: [String: DirectMessageReadTarget] = [:]

    init(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        totalUnreadCount = 0
        statusMessage = nil
        loadPersistentState()
    }

    deinit {
        pollTimer?.invalidate()
    }

    func update(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        stopPolling()
        generation = UUID()
        refreshInFlight = false
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        totalUnreadCount = 0
        statusMessage = nil
        loadPersistentState()
    }

    func startPolling() {
        stopPolling()
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else { return }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func send(text: String,
              to recipient: String,
              clientMessageID: UUID,
              createdAt: Date = Date()) async throws -> DirectMessageSendAPIResponse {
        guard configuration.hasDirectoryAPI, !configuration.isDevelopmentDirect else {
            throw InternetCallError.notConfigured
        }
        let senderNickname = NicknamePolicy.normalize(identity.nickname ?? "")
        let recipientNickname = NicknamePolicy.normalize(recipient)
        guard NicknamePolicy.validationError(senderNickname) == nil,
              NicknamePolicy.validationError(recipientNickname) == nil,
              senderNickname != recipientNickname else {
            throw InternetDirectMessageCryptoError.invalidNickname
        }

        let identity = self.identity
        let api = self.api
        try await api.register(identity: identity,
                               voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
        let canonicalClientID = clientMessageID.uuidString.lowercased()
        let plaintext = InternetDirectMessagePlaintext(
            clientMessageID: canonicalClientID,
            senderNickname: senderNickname,
            recipientNickname: recipientNickname,
            text: text,
            createdAtMilliseconds: Int64(createdAt.timeIntervalSince1970 * 1_000)
        )

        func resolveAndSeal() async throws -> [InternetDirectMessageSealedEnvelope] {
            let resolved = try await api.directMessageRecipient(nickname: recipientNickname,
                                                                identity: identity)
            guard resolved.cryptoVersion == InternetDirectMessageCrypto.cryptoVersion,
                  NicknamePolicy.normalize(resolved.nickname) == recipientNickname,
                  resolved.userID != identity.userID else {
                throw InternetDirectMessageCryptoError.invalidRecipientKey
            }
            let recipientKeys = resolved.devices.map {
                InternetDirectMessageRecipientKey(deviceID: $0.deviceID,
                                                  publicKeyBase64: $0.textEncryptionPublicKey,
                                                  keyFingerprint: $0.textEncryptionKeyFingerprint)
            }
            return try InternetDirectMessageCrypto.seal(plaintext,
                                                         sender: identity,
                                                         recipients: recipientKeys)
        }

        func deliver(_ envelopes: [InternetDirectMessageSealedEnvelope]) async throws
        -> DirectMessageSendAPIResponse {
            try await api.sendDirectMessage(recipient: recipientNickname,
                                            clientMessageID: canonicalClientID,
                                            envelopes: envelopes,
                                            identity: identity)
        }

        func deliverWithExactRetry(_ envelopes: [InternetDirectMessageSealedEnvelope]) async throws
        -> DirectMessageSendAPIResponse {
            do {
                return try await deliver(envelopes)
            } catch let error as InternetCallError {
                switch error {
                case let .server(code, _):
                    guard code == 408 || (500...599).contains(code) else {
                        throw error
                    }
                case .notConfigured:
                    throw error
                case .invalidResponse:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A transport or decoding failure can happen after the service commits.
                // Retry only the identical idempotency key and sealed envelopes.
            }

            try await Task.sleep(nanoseconds: 250_000_000)
            do {
                return try await deliver(envelopes)
            } catch let error as InternetCallError {
                switch error {
                case let .server(code, _):
                    guard code == 408 || (500...599).contains(code) else {
                        throw error
                    }
                    throw InternetDirectMessageDeliveryError.unconfirmed
                case .notConfigured:
                    throw error
                case .invalidResponse:
                    throw InternetDirectMessageDeliveryError.unconfirmed
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw InternetDirectMessageDeliveryError.unconfirmed
            }
        }

        let envelopes = try await resolveAndSeal()
        do {
            return try await deliverWithExactRetry(envelopes)
        } catch let error as InternetCallError {
            if case let .server(code, message) = error {
                guard code == 409,
                      message.contains("encrypted envelopes must match every current recipient device and key") else {
                    throw error
                }
                let refreshedEnvelopes = try await resolveAndSeal()
                return try await deliverWithExactRetry(refreshedEnvelopes)
            }
            throw error
        }
    }

    func refresh() {
        guard configuration.hasDirectoryAPI,
              !configuration.isDevelopmentDirect,
              !refreshInFlight else { return }
        refreshInFlight = true
        let identity = self.identity
        let api = self.api
        let startingCursor = cursor
        let generation = self.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.refreshInFlight = false
                }
            }
            do {
                try await api.register(identity: identity,
                                       voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
                let response = try await api.directMessageInbox(afterMessageID: startingCursor,
                                                                identity: identity)
                guard self.generation == generation else { return }
                var processedCursor = startingCursor
                var unreadCount = response.totalUnreadCount
                for message in response.messages.sorted(by: { $0.messageID < $1.messageID }) {
                    guard message.messageID > processedCursor else { continue }
                    do {
                        let envelope = InternetDirectMessageSealedEnvelope(
                            recipientDeviceID: message.recipientDeviceID,
                            recipientKeyFingerprint: message.recipientKeyFingerprint,
                            ephemeralPublicKey: message.ephemeralPublicKey,
                            nonce: message.nonce,
                            ciphertext: message.ciphertext,
                            senderSignature: message.senderSignature,
                            cryptoVersion: message.cryptoVersion)
                        let plaintext = try InternetDirectMessageCrypto.open(
                            envelope,
                            senderUserID: message.senderUserID,
                            senderDeviceID: message.senderDeviceID,
                            senderSigningPublicKey: message.senderSigningPublicKey,
                            senderKeyFingerprint: message.senderKeyFingerprint,
                            recipient: identity,
                            expectedClientMessageID: message.clientMessageID,
                            expectedSenderNickname: message.senderNickname,
                            expectedRecipientNickname: message.recipientNickname)
                        let senderNickname = NicknamePolicy.normalize(message.senderNickname)
                        guard plaintext.senderNickname == senderNickname,
                              plaintext.recipientNickname == NicknamePolicy.normalize(
                                message.recipientNickname) else {
                            throw InternetDirectMessageCryptoError.messageMetadataMismatch
                        }
                        self.recordReadTarget(nickname: senderNickname,
                                              senderUserID: message.senderUserID,
                                              throughMessageID: message.messageID)
                        self.onMessage?(ReceivedInternetDirectMessage(
                            serverMessageID: message.messageID,
                            clientMessageID: plaintext.clientMessageID,
                            senderUserID: message.senderUserID,
                            senderNickname: senderNickname,
                            recipientNickname: plaintext.recipientNickname,
                            text: plaintext.text,
                            createdAt: Date(timeIntervalSince1970:
                                Double(plaintext.createdAtMilliseconds) / 1_000),
                            serverCreatedAt: Date(timeIntervalSince1970:
                                Double(message.createdAt)),
                            read: message.read))
                        processedCursor = message.messageID
                    } catch is InternetDirectMessageCryptoError {
                        NSLog("TRINET TEXT: rejected unauthenticated Internet message id=%lld",
                              message.messageID)
                        let readResponse = try await api.markDirectMessagesRead(
                            senderUserID: message.senderUserID,
                            throughMessageID: message.messageID,
                            identity: identity)
                        unreadCount = readResponse.totalUnreadCount
                        processedCursor = message.messageID
                    }
                }
                self.cursor = max(self.cursor, processedCursor)
                self.totalUnreadCount = unreadCount
                self.statusMessage = nil
                self.persistState()
            } catch {
                guard self.generation == generation else { return }
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func markRead(nickname: String) {
        let normalized = NicknamePolicy.normalize(nickname)
        guard let target = readTargets[normalized],
              configuration.hasDirectoryAPI,
              !configuration.isDevelopmentDirect else { return }
        let identity = self.identity
        let api = self.api
        let generation = self.generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await api.markDirectMessagesRead(
                    senderUserID: target.senderUserID,
                    throughMessageID: target.throughMessageID,
                    identity: identity)
                guard self.generation == generation else { return }
                self.totalUnreadCount = response.totalUnreadCount
                self.statusMessage = nil
            } catch {
                guard self.generation == generation else { return }
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func verifiedNickname(senderUserID: String, nicknameHint: String?) -> String? {
        let matches = readTargets.compactMap { nickname, target in
            target.senderUserID == senderUserID ? nickname : nil
        }
        if let hint = nicknameHint.map(NicknamePolicy.normalize) {
            return matches.contains(hint) ? hint : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private var persistentPrefix: String {
        "trinet.direct-message.\(identity.userID).\(identity.deviceID).\(configuration.apiBaseURL)"
    }

    private func loadPersistentState() {
        let defaults = UserDefaults.standard
        cursor = (defaults.object(forKey: persistentPrefix + ".cursor") as? NSNumber)?.int64Value ?? 0
        guard let data = defaults.data(forKey: persistentPrefix + ".read-targets"),
              let saved = try? JSONDecoder().decode([String: DirectMessageReadTarget].self,
                                                     from: data) else {
            readTargets = [:]
            return
        }
        readTargets = saved
    }

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(cursor, forKey: persistentPrefix + ".cursor")
        if let data = try? JSONEncoder().encode(readTargets) {
            defaults.set(data, forKey: persistentPrefix + ".read-targets")
        }
    }

    private func recordReadTarget(nickname: String,
                                  senderUserID: String,
                                  throughMessageID: Int64) {
        let current = readTargets[nickname]
        guard current == nil || throughMessageID > current!.throughMessageID else { return }
        readTargets[nickname] = DirectMessageReadTarget(senderUserID: senderUserID,
                                                        throughMessageID: throughMessageID)
    }
}

final class GroupChatController: ObservableObject {
    @Published private(set) var chats: [GroupChatSummary] = []
    @Published private(set) var messages: [GroupChatMessage] = []
    @Published private(set) var activeChatID: String?
    @Published private(set) var totalUnreadCount = 0
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var titleInput = ""
    @Published var membersInput = ""
    @Published var draft = ""

    var onNewUnread: ((Int) -> Void)?

    var activeChat: GroupChatSummary? {
        chats.first { $0.chatID == activeChatID }
    }

    private var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    private var pollTimer: Timer?
    private var refreshInFlight = false
    private var observedUnreadByChat: [String: Int]?
    private var lastMarkedReadMessageID: [String: Int64] = [:]

    init(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
    }

    func update(identity: DeviceIdentity, configuration: InternetCallConfiguration) {
        self.identity = identity
        self.configuration = configuration
        api = InternetCallAPI(configuration: configuration)
        chats = []
        messages = []
        activeChatID = nil
        totalUnreadCount = 0
        observedUnreadByChat = nil
        lastMarkedReadMessageID = [:]
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
                let response = try await api.groupChats(identity: identity)
                self.apply(response, activeChatID: self.activeChatID)
                if let selectedChatID {
                    let received = try await api.groupMessages(chatID: selectedChatID,
                                                               afterMessageID: afterMessageID,
                                                               identity: identity)
                    guard self.activeChatID == selectedChatID else { return }
                    self.merge(received)
                    try await self.markReadIfPossible(chatID: selectedChatID,
                                                      identity: identity,
                                                      api: api)
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
                try await self.markReadIfPossible(chatID: chatID,
                                                  identity: identity,
                                                  api: api)
                self.statusMessage = nil
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func apply(_ response: GroupChatsResponse, activeChatID: String?) {
        let nextUnreadByChat = Dictionary(
            uniqueKeysWithValues: response.chats.map { ($0.chatID, max(0, $0.unreadCount)) }
        )
        var newUnread = 0
        if let previous = observedUnreadByChat {
            for chat in response.chats where chat.chatID != activeChatID {
                let oldCount = previous[chat.chatID] ?? 0
                newUnread += max(0, chat.unreadCount - oldCount)
            }
        }
        chats = response.chats
        totalUnreadCount = max(0, response.totalUnreadCount)
        observedUnreadByChat = nextUnreadByChat
        if newUnread > 0 {
            onNewUnread?(newUnread)
        }
    }

    @MainActor
    private func markReadIfPossible(chatID: String,
                                    identity: DeviceIdentity,
                                    api: InternetCallAPI) async throws {
        guard activeChatID == chatID,
              let throughMessageID = messages.last?.messageID,
              throughMessageID > (lastMarkedReadMessageID[chatID] ?? 0) else { return }
        try await api.markGroupChatRead(chatID: chatID,
                                        throughMessageID: throughMessageID,
                                        identity: identity)
        lastMarkedReadMessageID[chatID] = throughMessageID
        guard activeChatID == chatID else { return }
        markReadLocally(chatID: chatID)
    }

    @MainActor
    private func markReadLocally(chatID: String) {
        if let index = chats.firstIndex(where: { $0.chatID == chatID }) {
            let removed = max(0, chats[index].unreadCount)
            chats[index].unreadCount = 0
            totalUnreadCount = max(0, totalUnreadCount - removed)
        }
        observedUnreadByChat?[chatID] = 0
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

enum IncomingCallDeliveryPolicy {
    static func shouldMarkReported(alreadyReported: Bool,
                                   consumedByUI: Bool) -> Bool {
        !alreadyReported && consumedByUI
    }

    static func shouldRetryAfterPresentation(succeeded: Bool) -> Bool {
        !succeeded
    }
}

enum InternetCallLifecyclePolicy {
    static func shouldEndAfterRemoteDeparture(activeRoute: CallRoute?) -> Bool {
        activeRoute == .internet
    }

    static func shouldEndOutgoingOnDisconnect(hasRemoteParticipant: Bool,
                                               lastServerStatus: String?,
                                               state: InternetCallState) -> Bool {
        hasRemoteParticipant ||
            lastServerStatus == "active" ||
            state == .connected ||
            state == .reconnecting
    }
}

final class InternetCallController: NSObject, ObservableObject, RoomDelegate, @unchecked Sendable {
    @Published private(set) var state: InternetCallState = .idle
    @Published private(set) var callID: String?
    @Published private(set) var participantName = ""
    @Published private(set) var hasRemoteParticipant = false
    @Published private(set) var localVideoTrack: LocalVideoTrack?
    @Published private(set) var remoteVideoTrack: RemoteVideoTrack?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraEnabled = true

    var onChat: ((String) -> Void)?
    var onReaction: ((String) -> Void)?
    var onIncomingCall: ((IncomingInternetCall) -> Bool)?
    var onRemoteEnded: (() -> Void)?
    var onCallStatus: ((InternetCallStatus) -> Void)?

    private(set) var identity: DeviceIdentity
    private var configuration: InternetCallConfiguration
    private var api: InternetCallAPI
    // Accessed on the main queue only. A generation token prevents a cancelled
    // async attempt from installing its Room after Stop followed by a retry.
    private var room: Room?
    private var roomAttemptID: UUID?
    private var outgoingCallID: String?
    private var incomingCallID: String?
    private var statusPollTask: Task<Void, Never>?
    private var lastCallStatus: InternetCallStatus?
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
        setMain {
            guard let incoming = calls.first(where: {
                !self.reportedIncomingCallIDs.contains($0.callID)
            }) else { return }
            let alreadyReported = self.reportedIncomingCallIDs.contains(incoming.callID)
            guard !alreadyReported else { return }
            let consumed = self.onIncomingCall?(incoming) ?? false
            guard IncomingCallDeliveryPolicy.shouldMarkReported(
                alreadyReported: alreadyReported,
                consumedByUI: consumed
            ) else { return }
            self.reportedIncomingCallIDs.insert(incoming.callID)
        }
    }

    func allowIncomingRetry(callID: String) {
        // Always enqueue this removal. A presentation callback is allowed to
        // fail immediately, before pollIncomingCalls finishes inserting the ID.
        DispatchQueue.main.async {
            self.reportedIncomingCallIDs.remove(callID)
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
        let attemptID = try await beginRoomAttempt()
        let requestAPI = api
        let requestIdentity = identity
        try await setAttemptState(.registering, attemptID: attemptID)
        try await requestAPI.register(identity: requestIdentity, voipToken: registeredVoipToken)
        try Task.checkCancellation()
        // Keep creation independent from the UI task cancellation. If Stop
        // arrives while POST /v1/calls is in flight, its response still gives us
        // the call ID required to retract the server-side invitation.
        let clientCallID = UUID().uuidString.lowercased()
        let creation = Task {
            var attempt = 1
            while true {
                do {
                    return try await requestAPI.createCall(callee: callee,
                                                           identity: requestIdentity,
                                                           clientCallID: clientCallID,
                                                           audio: audio,
                                                           video: video)
                } catch {
                    guard attempt < InternetCallCreateRetryPolicy.maximumAttempts,
                          InternetCallCreateRetryPolicy.shouldRetry(error) else { throw error }
                    try await Task.sleep(nanoseconds:
                        InternetCallCreateRetryPolicy.retryDelayNanoseconds(
                            afterFailedAttempt: attempt
                        )
                    )
                    attempt += 1
                }
            }
        }
        let session = try await creation.value
        do {
            try await retainOutgoingCallID(session.callID, attemptID: attemptID)
            startStatusPolling(callID: session.callID,
                               api: requestAPI,
                               identity: requestIdentity)
            try Task.checkCancellation()
            try await connect(session: session, audio: audio, video: video, attemptID: attemptID)
        } catch {
            clearOutgoingCallID(session.callID)
            cancelCallBestEffort(session.callID, api: requestAPI, identity: requestIdentity)
            throw error
        }
    }

    func join(callID: String, audio: Bool = true, video: Bool = true) async throws {
        guard configuration.isConfigured else { throw InternetCallError.notConfigured }
        let attemptID = try await beginRoomAttempt()
        try await setAttemptState(.connecting, attemptID: attemptID)
        let requestAPI = api
        let requestIdentity = identity
        do {
            let session = try await requestAPI.joinCall(callID: callID, identity: requestIdentity)
            try await MainActor.run {
                guard self.roomAttemptID == attemptID else { throw CancellationError() }
                self.incomingCallID = callID
            }
            try Task.checkCancellation()
            try await connect(session: session, audio: audio, video: video, attemptID: attemptID)
        } catch {
            endCallBestEffort(callID, api: requestAPI, identity: requestIdentity)
            setMain {
                if self.incomingCallID == callID { self.incomingCallID = nil }
            }
            throw error
        }
    }

    func status(callID: String) async throws -> InternetCallStatus {
        try await api.callStatus(callID: callID, identity: identity)
    }

    func authenticatedIncoming(callID: String) async throws -> IncomingInternetCall? {
        let calls = try await api.incomingCalls(identity: identity)
        return calls.first { $0.callID == callID }
    }

    @discardableResult
    func decline(callID: String) async throws -> InternetCallStatus {
        let result = try await api.declineCall(callID: callID, identity: identity)
        setMain { self.reportedIncomingCallIDs.insert(callID) }
        return result
    }

    @discardableResult
    func end(callID: String) async throws -> InternetCallStatus {
        try await api.endCall(callID: callID, identity: identity)
    }

    private func beginRoomAttempt() async throws -> UUID {
        try Task.checkCancellation()
        let attemptID = UUID()
        do {
            let oldRoom = try await MainActor.run {
                try Task.checkCancellation()
                let oldRoom = self.room
                self.room = nil
                self.roomAttemptID = attemptID
                return oldRoom
            }
            if let oldRoom { await oldRoom.disconnect() }
            try Task.checkCancellation()
            return attemptID
        } catch {
            await MainActor.run {
                guard self.roomAttemptID == attemptID else { return }
                self.roomAttemptID = nil
            }
            throw error
        }
    }

    private func setAttemptState(_ state: InternetCallState, attemptID: UUID) async throws {
        try await MainActor.run {
            guard self.roomAttemptID == attemptID else { throw CancellationError() }
            self.applyState(state)
        }
    }

    private func retainOutgoingCallID(_ callID: String, attemptID: UUID) async throws {
        try await MainActor.run {
            guard self.roomAttemptID == attemptID else { throw CancellationError() }
            self.callID = callID
            self.outgoingCallID = callID
        }
    }

    private func clearOutgoingCallID(_ expectedCallID: String) {
        setMain {
            guard self.outgoingCallID == expectedCallID else { return }
            self.outgoingCallID = nil
            if self.callID == expectedCallID { self.callID = nil }
        }
    }

    private func cancelCallBestEffort(_ callID: String,
                                      api: InternetCallAPI,
                                      identity: DeviceIdentity) {
        Task {
            do {
                try await api.cancelCall(callID: callID, identity: identity)
                NSLog("TRINET: Internet call ended call=%@", callID)
            } catch {
                NSLog("TRINET: Internet call end failed call=%@ error=%@",
                      callID, error.localizedDescription)
            }
        }
    }

    private func endCallBestEffort(_ callID: String,
                                   api: InternetCallAPI,
                                   identity: DeviceIdentity) {
        Task {
            do {
                _ = try await api.endCall(callID: callID, identity: identity)
                NSLog("TRINET: Internet call participant ended call=%@", callID)
            } catch {
                NSLog("TRINET: Internet participant end failed call=%@ error=%@",
                      callID, error.localizedDescription)
            }
        }
    }

    private func startStatusPolling(callID: String,
                                    api: InternetCallAPI,
                                    identity: DeviceIdentity) {
        statusPollTask?.cancel()
        lastCallStatus = nil
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let status = try await api.callStatus(callID: callID, identity: identity)
                    guard !Task.isCancelled else { return }
                    self?.setMain {
                        guard self?.outgoingCallID == callID else { return }
                        if self?.lastCallStatus != status {
                            self?.lastCallStatus = status
                            self?.onCallStatus?(status)
                        }
                    }
                    if status.isTerminal { return }
                } catch is CancellationError {
                    return
                } catch {
                    // A transient status failure must not tear down working media.
                    NSLog("TRINET: call status poll failed call=%@ error=%@",
                          callID, error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func connect(session: InternetCallSession,
                         audio: Bool,
                         video: Bool,
                         attemptID: UUID) async throws {
        try Task.checkCancellation()
        try await MainActor.run {
            guard self.roomAttemptID == attemptID else { throw CancellationError() }
            self.state = .connecting
            self.callID = session.callID
            self.participantName = ""
            self.hasRemoteParticipant = false
            self.remoteVideoTrack = nil
        }
        NSLog("TRINET: LiveKit connecting call=%@ url=%@", session.callID, session.liveKitURL)
        let encryption = session.mediaKey.map { EncryptionOptions.sharedKey($0) }
        let options = RoomOptions(adaptiveStream: true,
                                  dynacast: true,
                                  encryptionOptions: encryption,
                                  reportRemoteTrackStatistics: true,
                                  singlePeerConnection: true)
        let newRoom = Room(delegate: self, roomOptions: options)
        let installed = await MainActor.run {
            guard self.roomAttemptID == attemptID else { return false }
            self.room = newRoom
            return true
        }
        guard installed else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            try await newRoom.connect(url: session.liveKitURL, token: session.token)
            try Task.checkCancellation()
            NSLog("TRINET: LiveKit signaling connected call=%@", session.callID)
            let cameraPublication = try await newRoom.localParticipant.setCamera(enabled: video)
            try Task.checkCancellation()
            let microphonePublication = try await newRoom.localParticipant.setMicrophone(enabled: audio)
            try Task.checkCancellation()
            _ = microphonePublication
            let existingParticipant = newRoom.remoteParticipants.values.first
            let existingVideo = existingParticipant?.trackPublications.values
                .compactMap { $0.track as? RemoteVideoTrack }
                .first
            let accepted = await MainActor.run {
                guard self.roomAttemptID == attemptID, self.room === newRoom else { return false }
                self.localVideoTrack = cameraPublication?.track as? LocalVideoTrack
                if let existingParticipant {
                    self.participantName = self.participantLabel(existingParticipant)
                    self.hasRemoteParticipant = true
                }
                if let existingVideo { self.remoteVideoTrack = existingVideo }
                self.isCameraEnabled = video
                self.isMuted = !audio
                self.state = existingParticipant == nil ? .ringing : .connected
                return true
            }
            guard accepted else { throw CancellationError() }
            NSLog("TRINET: LiveKit media published call=%@ camera=%d microphone=%d",
                  session.callID, video ? 1 : 0, audio ? 1 : 0)
        } catch {
            if !(error is CancellationError) {
                NSLog("TRINET: LiveKit connect failed call=%@ error=%@",
                      session.callID, error.localizedDescription)
                await MainActor.run {
                    guard self.roomAttemptID == attemptID, self.room === newRoom else { return }
                    self.applyFailure(error)
                }
            }
            await newRoom.disconnect()
            await MainActor.run {
                guard self.roomAttemptID == attemptID, self.room === newRoom else { return }
                self.room = nil
                self.roomAttemptID = nil
            }
            throw error
        }
    }

    func setMuted(_ muted: Bool) {
        guard let activeRoom = currentRoom() else { return }
        Task {
            do {
                _ = try await activeRoom.localParticipant.setMicrophone(enabled: !muted)
                setMain {
                    guard self.room === activeRoom else { return }
                    self.isMuted = muted
                }
            } catch {
                setFailure(error, for: activeRoom)
            }
        }
    }

    func setCamera(enabled: Bool) {
        guard let activeRoom = currentRoom() else { return }
        Task {
            do {
                let publication = try await activeRoom.localParticipant.setCamera(enabled: enabled)
                setMain {
                    guard self.room === activeRoom else { return }
                    self.localVideoTrack = publication?.track as? LocalVideoTrack
                    self.isCameraEnabled = enabled
                }
            } catch {
                setFailure(error, for: activeRoom)
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
        guard let activeRoom = currentRoom() else { return }
        Task {
            do {
                let data = try JSONEncoder().encode(InternetDataMessage(kind: kind, value: value))
                let options = DataPublishOptions(topic: "trinet.control", reliable: true)
                try await activeRoom.localParticipant.publish(data: data, options: options)
            } catch {
                setFailure(error, for: activeRoom)
            }
        }
    }

    func disconnect() {
        let disconnected = mainSync {
            let oldRoom = self.room
            let outgoingCallID = self.outgoingCallID
            let incomingCallID = self.incomingCallID
            let shouldEndOutgoing = outgoingCallID != nil &&
                InternetCallLifecyclePolicy.shouldEndOutgoingOnDisconnect(
                    hasRemoteParticipant: self.hasRemoteParticipant,
                    lastServerStatus: self.lastCallStatus?.status,
                    state: self.state)
            let api = self.api
            let identity = self.identity
            self.statusPollTask?.cancel()
            self.statusPollTask = nil
            self.lastCallStatus = nil
            self.roomAttemptID = nil
            self.room = nil
            self.outgoingCallID = nil
            self.incomingCallID = nil
            self.state = .ended
            self.callID = nil
            self.participantName = ""
            self.hasRemoteParticipant = false
            self.localVideoTrack = nil
            self.remoteVideoTrack = nil
            return (room: oldRoom,
                    outgoingCallID: outgoingCallID,
                    incomingCallID: incomingCallID,
                    shouldEndOutgoing: shouldEndOutgoing,
                    api: api,
                    identity: identity)
        }
        if let callID = disconnected.outgoingCallID {
            if disconnected.shouldEndOutgoing {
                endCallBestEffort(callID, api: disconnected.api, identity: disconnected.identity)
            } else {
                cancelCallBestEffort(callID, api: disconnected.api, identity: disconnected.identity)
            }
        } else if let callID = disconnected.incomingCallID {
            endCallBestEffort(callID, api: disconnected.api, identity: disconnected.identity)
        }
        Task { await disconnected.room?.disconnect() }
    }

    func room(_ room: Room,
              didUpdateConnectionState connectionState: ConnectionState,
              from oldConnectionState: ConnectionState) {
        setMain {
            guard self.room === room else { return }
            switch connectionState {
            case .connected:
                NSLog("TRINET: LiveKit state connected")
                self.applyState(self.hasRemoteParticipant ? .connected : .ringing)
            case .reconnecting:
                NSLog("TRINET: LiveKit state reconnecting")
                self.applyState(.reconnecting)
            case .disconnected:
                NSLog("TRINET: LiveKit state disconnected")
                self.applyState(.ended)
            default:
                break
            }
        }
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let label = participantLabel(participant)
        NSLog("TRINET: LiveKit participant connected %@", label)
        setMain {
            guard self.room === room else { return }
            self.participantName = label
            self.hasRemoteParticipant = true
            self.applyState(.connected)
        }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let label = participantLabel(participant)
        NSLog("TRINET: LiveKit participant disconnected %@", label)
        setMain {
            guard self.room === room else { return }
            self.participantName = ""
            self.hasRemoteParticipant = false
            self.remoteVideoTrack = nil
            self.applyState(.ended)
            self.onRemoteEnded?()
        }
    }

    func room(_ room: Room,
              participant: RemoteParticipant,
              didSubscribeTrack publication: RemoteTrackPublication) {
        guard let video = publication.track as? RemoteVideoTrack else { return }
        let label = participantLabel(participant)
        NSLog("TRINET: LiveKit remote video subscribed %@", label)
        setMain {
            guard self.room === room else { return }
            self.participantName = label
            self.remoteVideoTrack = video
        }
    }

    func room(_ room: Room,
              participant: RemoteParticipant,
              didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard publication.track is RemoteVideoTrack else { return }
        setMain {
            guard self.room === room else { return }
            self.remoteVideoTrack = nil
        }
    }

    func room(_ room: Room,
              participant: RemoteParticipant?,
              didReceiveData data: Data,
              forTopic topic: String,
              encryptionType: EncryptionType) {
        guard topic == "trinet.control",
              let message = try? JSONDecoder().decode(InternetDataMessage.self, from: data) else { return }
        setMain {
            guard self.room === room else { return }
            switch message.kind {
            case .chat:
                self.onChat?(message.value)
            case .reaction:
                self.onReaction?(message.value)
            }
        }
    }

    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        setFailure(error ?? InternetCallError.invalidResponse, for: room)
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error {
            setFailure(error, for: room)
        } else {
            setMain {
                guard self.room === room else { return }
                self.applyState(.ended)
            }
        }
    }

    private func setState(_ state: InternetCallState) {
        setMain { self.applyState(state) }
    }

    private func applyState(_ state: InternetCallState) {
        self.state = state
        if state != .failed { self.errorMessage = nil }
        if state == .ended {
            self.participantName = ""
            self.hasRemoteParticipant = false
            self.remoteVideoTrack = nil
        }
    }

    private func participantLabel(_ participant: Participant) -> String {
        let candidate = participant.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? participant.identity?.stringValue
            ?? ""
        return DeviceDisplayNamePolicy.safe(candidate, fallback: "TRI-NET peer")
    }

    private func setFailure(_ error: Error, for expectedRoom: Room? = nil) {
        setMain {
            if let expectedRoom, self.room !== expectedRoom { return }
            self.applyFailure(error)
        }
    }

    private func applyFailure(_ error: Error) {
        self.state = .failed
        self.errorMessage = error.localizedDescription
        self.participantName = ""
        self.hasRemoteParticipant = false
        self.remoteVideoTrack = nil
    }

    private func currentRoom() -> Room? {
        mainSync { self.room }
    }

    private func mainSync<T>(_ action: () -> T) -> T {
        if Thread.isMainThread { return action() }
        return DispatchQueue.main.sync(execute: action)
    }

    private func setMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }
}
