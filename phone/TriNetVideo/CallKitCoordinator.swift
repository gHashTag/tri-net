import AVFoundation
import CallKit
import Foundation
import LiveKit
import PushKit
import UIKit
import UserNotifications

extension Notification.Name {
    static let triNetAlertPushTokenDidChange =
        Notification.Name("TriNetAlertPushTokenDidChange")
}

enum AlertPresentationPolicy {
    static func shouldPlaySystemSound(userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = userInfo["type"] as? String else { return true }
        return type != "group_chat_message" && type != "direct_message"
    }
}

struct CallStartGate {
    var requestSucceeded = false
    var actionSucceeded = false

    var isReady: Bool {
        requestSucceeded && actionSucceeded
    }
}

enum PushEnvironmentPolicy {
    static func normalizedBackendValue(_ value: String?) -> String? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development", "sandbox":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }

    static func configuredBackendValue(bundle: Bundle = .main) -> String? {
        normalizedBackendValue(
            bundle.object(forInfoDictionaryKey: "TRINET_PUSH_ENVIRONMENT") as? String
        )
    }

    static func persistConfiguredEnvironment(bundle: Bundle = .main,
                                             defaults: UserDefaults = .standard) {
        guard let value = configuredBackendValue(bundle: bundle) else {
            defaults.removeObject(forKey: CallKitCoordinator.pushEnvironmentDefaultsKey)
            NSLog("TRINET: APNs environment is not configured; backend fallback will be used")
            return
        }
        defaults.set(value, forKey: CallKitCoordinator.pushEnvironmentDefaultsKey)
    }
}

final class TriNetAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushEnvironmentPolicy.persistConfiguredEnvironment()
        CallKitCoordinator.shared.startPushRegistry()
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("TRINET: notification authorization failed: %@", error.localizedDescription)
            } else {
                NSLog("TRINET: notification authorization granted=%@", granted ? "true" : "false")
            }
            // APNs registration is independent from presentation permission.
            // Keep a token even when the user temporarily disables banners so
            // enabling notifications later does not require reinstalling.
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token,
                                  forKey: CallKitCoordinator.alertPushTokenDefaultsKey)
        PushEnvironmentPolicy.persistConfiguredEnvironment()
        NotificationCenter.default.post(name: .triNetAlertPushTokenDidChange,
                                        object: token)
        CallKitCoordinator.shared.refreshDeviceRegistration()
        NSLog("TRINET: APNs alert token updated")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("TRINET: APNs alert registration failed: %@", error.localizedDescription)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        CallKitCoordinator.shared.handleAlertNotification(
            notification.request.content.userInfo,
            openConversation: false
        )
        var options: UNNotificationPresentationOptions = [.banner, .list, .badge]
        if AlertPresentationPolicy.shouldPlaySystemSound(
            userInfo: notification.request.content.userInfo
        ) {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        CallKitCoordinator.shared.handleAlertNotification(
            response.notification.request.content.userInfo,
            openConversation: true
        )
        completionHandler()
    }
}

final class CallKitCoordinator: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
    private struct IncomingCallContext {
        let callID: String
        var caller: String
        var media: InternetCallMedia
        var verified: Bool
    }

    private final class PendingStart {
        let completion: (UUID, Result<Void, Error>) -> Void
        var gate = CallStartGate()

        init(completion: @escaping (UUID, Result<Void, Error>) -> Void) {
            self.completion = completion
        }
    }

    private enum FlowError: LocalizedError {
        case actionTimedOut
        case callAlreadyInProgress
        case mediaFailed(String)
        case providerReset

        var errorDescription: String? {
            switch self {
            case .actionTimedOut:
                return "The system timed out while starting the call."
            case .callAlreadyInProgress:
                return "Finish or decline the current incoming call first."
            case .mediaFailed(let message):
                return "Call audio could not start: \(message)"
            case .providerReset:
                return "The system call service was reset."
            }
        }
    }

    static let shared = CallKitCoordinator()
    static let alertPushTokenDefaultsKey = "alertPushToken"
    static let pushEnvironmentDefaultsKey = "pushEnvironment"

    private let provider: CXProvider
    private let callController = CXCallController()
    private var incomingCalls: [UUID: IncomingCallContext] = [:]
    private var busyIncomingReports: [String: UUID] = [:]
    private var activeCallUUID: UUID?
    private var pendingStarts: [UUID: PendingStart] = [:]
    private var pendingAnswers: [UUID: CXAnswerCallAction] = [:]
    private var startedAnswers: Set<UUID> = []
    private var answeredIncomingCalls: Set<UUID> = []
    private var incomingStatusTasks: [UUID: Task<Void, Never>] = [:]
    private var outgoingRingingUUID: UUID?
    private var ringbackPlayer: AVAudioPlayer?
    private var audioSessionActive = false
    private weak var viewModel: StreamViewModel?
    private var pushRegistry: PKPushRegistry?

    var alertPushToken: String? {
        UserDefaults.standard.string(forKey: Self.alertPushTokenDefaultsKey)
    }

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        // A residual simultaneous VoIP push must still be reported to CallKit
        // before it is immediately closed as busy. Keep one spare system slot
        // without allowing it to replace the app-owned active call UUID.
        configuration.maximumCallsPerCallGroup = 2
        configuration.maximumCallGroups = 2
        configuration.ringtoneSound = "trinet-call.caf"
        provider = CXProvider(configuration: configuration)
        super.init()
        // CallKit owns AVAudioSession activation. LiveKit may prepare tracks
        // while the system UI is ringing, but its audio engine must not touch
        // the device until CallKit activates the session after Answer.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        do {
            try AudioManager.shared.setEngineAvailability(.none)
        } catch {
            NSLog("TRINET: LiveKit CallKit audio preparation failed: %@",
                  error.localizedDescription)
        }
        provider.setDelegate(self, queue: nil)
    }

    func attach(viewModel: StreamViewModel) {
        self.viewModel = viewModel
        refreshDeviceRegistration()
        for (uuid, incoming) in incomingCalls {
            startIncomingStatusWatch(uuid: uuid, callID: incoming.callID)
        }
        for uuid in pendingAnswers.keys {
            startPendingAnswer(uuid)
        }
    }

    func refreshDeviceRegistration() {
        guard let viewModel else { return }
        let token = UserDefaults.standard.string(forKey: "voipPushToken")
        Task {
            do {
                try await viewModel.internet.registerDevice(voipToken: token)
            } catch {
                NSLog("TRINET: push token registration failed: %@",
                      error.localizedDescription)
            }
        }
    }

    func startPushRegistry() {
        DispatchQueue.main.async {
            guard self.pushRegistry == nil else { return }
            let registry = PKPushRegistry(queue: .main)
            registry.delegate = self
            registry.desiredPushTypes = [.voIP]
            self.pushRegistry = registry
        }
    }

    @discardableResult
    func startOutgoing(
        handle: String,
        video: Bool,
        completion: @escaping (UUID, Result<Void, Error>) -> Void
    ) -> UUID {
        let uuid = UUID()
        if activeCallUUID != nil {
            // An authenticated incoming invitation can be ringing while the
            // SwiftUI media phase is still idle. Reject the new outgoing action
            // instead of silently deleting that real CallKit lifecycle.
            DispatchQueue.main.async {
                completion(uuid, .failure(FlowError.callAlreadyInProgress))
            }
            return uuid
        }
        activeCallUUID = uuid
        pendingStarts[uuid] = PendingStart(completion: completion)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = video
        callController.request(CXTransaction(action: action)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    NSLog("TRINET: CallKit start failed: %@", error.localizedDescription)
                    self.failOutgoingStart(uuid, error: error)
                    return
                }
                guard let pending = self.pendingStarts[uuid] else { return }
                pending.gate.requestSucceeded = true
                self.finishPendingStartIfReady(uuid)
            }
        }
        return uuid
    }

    func markOutgoingConnected(_ uuid: UUID) {
        guard activeCallUUID == uuid else { return }
        stopOutgoingRingback(uuid)
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    @discardableResult
    func reportIncoming(callID: String,
                        caller: String,
                        audio: Bool,
                        video: Bool,
                        uuid: UUID = UUID(),
                        verified: Bool = true,
                        completion: ((Bool) -> Void)? = nil) -> Bool {
        let safeCaller = DeviceDisplayNamePolicy.safe(caller, fallback: "TRI-NET peer")
        if let existing = incomingCalls.first(where: { $0.value.callID == callID }) {
            if verified {
                reconcileAuthenticatedIncoming(uuid: existing.key,
                                               callID: callID,
                                               caller: safeCaller,
                                               audio: audio,
                                               video: video)
            }
            completion?(true)
            return true
        }
        let appMediaBusy = viewModel.map { $0.phase != .idle || $0.activeRoute != nil } ?? false
        if activeCallUUID != nil || appMediaBusy {
            if busyIncomingReports[callID] != nil {
                completion?(true)
                return false
            }
            busyIncomingReports[callID] = uuid
            let media = InternetCallMedia(audio: audio, video: video)
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: safeCaller)
            update.localizedCallerName = safeCaller
            update.hasVideo = media.video
            provider.reportNewIncomingCall(with: uuid, update: update) { error in
                DispatchQueue.main.async {
                    self.busyIncomingReports.removeValue(forKey: callID)
                    if error == nil {
                        self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    } else {
                        NSLog("TRINET: busy incoming CallKit report failed: %@",
                              error!.localizedDescription)
                    }
                    completion?(error == nil)
                }
            }
            NSLog("TRINET: reporting and declining concurrent incoming call: %@", callID)
            declineIncomingAsBusy(callID: callID)
            return false
        }
        let media = InternetCallMedia(audio: audio, video: video)
        incomingCalls[uuid] = IncomingCallContext(callID: callID,
                                                  caller: safeCaller,
                                                  media: media,
                                                  verified: verified)
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: safeCaller)
        update.localizedCallerName = safeCaller
        update.hasVideo = media.video
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                NSLog("TRINET: incoming CallKit report failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.incomingCalls.removeValue(forKey: uuid)
                    if self.activeCallUUID == uuid { self.activeCallUUID = nil }
                    self.viewModel?.internet.allowIncomingRetry(callID: callID)
                }
            } else {
                DispatchQueue.main.async {
                    self.startIncomingStatusWatch(uuid: uuid, callID: callID)
                }
            }
            completion?(error == nil)
        }
        return true
    }

    func declineIncomingAsBusy(callID: String) {
        guard let internet = viewModel?.internet else { return }
        Task {
            var attempt = 1
            while true {
                do {
                    _ = try await internet.decline(callID: callID)
                    return
                } catch {
                    guard attempt < InternetCallCreateRetryPolicy.maximumAttempts,
                          InternetCallCreateRetryPolicy.shouldRetry(error) else {
                        NSLog("TRINET: busy decline failed call=%@ error=%@",
                              callID, error.localizedDescription)
                        return
                    }
                    try? await Task.sleep(nanoseconds:
                        InternetCallCreateRetryPolicy.retryDelayNanoseconds(
                            afterFailedAttempt: attempt
                        )
                    )
                    attempt += 1
                }
            }
        }
    }

    func end(_ uuid: UUID) {
        cancelPendingStart(uuid, error: CancellationError())
        stopOutgoingRingback(uuid)
        pendingAnswers.removeValue(forKey: uuid)?.fail()
        startedAnswers.remove(uuid)
        if activeCallUUID == uuid { activeCallUUID = nil }
        callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            if let error {
                NSLog("TRINET: CallKit end failed: %@", error.localizedDescription)
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            }
        }
    }

    func endCurrent() {
        guard let uuid = activeCallUUID else { return }
        end(uuid)
    }

    func reportCurrentEnded(reason: CXCallEndedReason) {
        guard let uuid = activeCallUUID else { return }
        cancelPendingStart(uuid, error: CancellationError())
        stopOutgoingRingback(uuid)
        pendingAnswers.removeValue(forKey: uuid)?.fail()
        startedAnswers.remove(uuid)
        answeredIncomingCalls.remove(uuid)
        cancelIncomingStatusWatch(uuid)
        incomingCalls.removeValue(forKey: uuid)
        activeCallUUID = nil
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    func reportCurrentEnded(serverStatus: String) {
        let reason: CXCallEndedReason
        switch serverStatus {
        case "declined": reason = .declinedElsewhere
        case "missed": reason = .unanswered
        default: reason = .remoteEnded
        }
        reportCurrentEnded(reason: reason)
    }

    func handleAlertNotification(_ userInfo: [AnyHashable: Any],
                                 openConversation: Bool) {
        let aps = userInfo["aps"] as? [String: Any]
        let badge: Int?
        if let count = aps?["badge"] as? Int {
            badge = count
        } else if let number = aps?["badge"] as? NSNumber {
            badge = number.intValue
        } else {
            badge = nil
        }
        DispatchQueue.main.async {
            let isDirectMessage = userInfo["type"] as? String == "direct_message"
            self.viewModel?.receiveAlertNotification(
                unreadCount: badge,
                openSenderUserID: openConversation && isDirectMessage
                    ? userInfo["sender_user_id"] as? String : nil,
                openSenderNickname: openConversation && isDirectMessage
                    ? userInfo["sender_nickname"] as? String : nil)
        }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "voipPushToken")
        refreshDeviceRegistration()
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        UserDefaults.standard.removeObject(forKey: "voipPushToken")
        refreshDeviceRegistration()
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }
        let values = payload.dictionaryPayload
        let callID = values["call_id"] as? String ?? UUID().uuidString.lowercased()
        let uuid = (values["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        reportIncoming(callID: callID,
                       caller: "TRI-NET call",
                       audio: true,
                       video: false,
                       uuid: uuid,
                       verified: false,
                       completion: { _ in completion() })
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard incomingCalls[action.callUUID] != nil else {
            action.fail()
            return
        }
        pendingAnswers[action.callUUID] = action
        startPendingAnswer(action.callUUID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self,
                  let pending = self.pendingAnswers.removeValue(forKey: action.callUUID) else {
                return
            }
            pending.fail()
            self.finishFailedCall(action.callUUID,
                                  message: "Timed out while establishing media.")
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard activeCallUUID == action.callUUID,
              let pending = pendingStarts[action.callUUID] else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
        pending.gate.actionSucceeded = true
        finishPendingStartIfReady(action.callUUID)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let incoming = incomingCalls[action.callUUID]
        guard activeCallUUID == action.callUUID || incoming != nil else {
            // A concurrent VoIP push is reported in a spare CallKit slot and
            // immediately ended as busy. Its system action must never tear
            // down the app-owned call that is already using media.
            NSLog("TRINET: ignored end action for non-active CallKit UUID %@",
                  action.callUUID.uuidString)
            action.fulfill()
            return
        }
        let wasAnswered = answeredIncomingCalls.contains(action.callUUID)
        let ownsAppMedia = callOwnsAppMedia(action.callUUID)
        cancelPendingStart(action.callUUID, error: CancellationError())
        stopOutgoingRingback(action.callUUID)
        pendingAnswers.removeValue(forKey: action.callUUID)?.fail()
        startedAnswers.remove(action.callUUID)
        answeredIncomingCalls.remove(action.callUUID)
        cancelIncomingStatusWatch(action.callUUID)
        incomingCalls.removeValue(forKey: action.callUUID)
        if activeCallUUID == action.callUUID { activeCallUUID = nil }
        if let incoming, let internet = viewModel?.internet {
            Task {
                do {
                    if wasAnswered {
                        _ = try await internet.end(callID: incoming.callID)
                    } else {
                        _ = try await internet.decline(callID: incoming.callID)
                    }
                } catch {
                    NSLog("TRINET: incoming lifecycle update failed call=%@ error=%@",
                          incoming.callID, error.localizedDescription)
                }
            }
        }
        if ownsAppMedia { viewModel?.stopCall() }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard activeCallUUID == action.callUUID || incomingCalls[action.callUUID] != nil else {
            NSLog("TRINET: ignored mute action for non-active CallKit UUID %@",
                  action.callUUID.uuidString)
            action.fulfill()
            return
        }
        viewModel?.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
        if let startAction = action as? CXStartCallAction {
            let uuid = startAction.callUUID
            failOutgoingStart(uuid, error: FlowError.actionTimedOut)
            return
        }
        if let answerAction = action as? CXAnswerCallAction {
            let uuid = answerAction.callUUID
            pendingAnswers.removeValue(forKey: uuid)
            finishFailedCall(uuid, message: "Timed out while answering the call.")
            return
        }
        if let endAction = action as? CXEndCallAction {
            let uuid = endAction.callUUID
            guard activeCallUUID == uuid || incomingCalls[uuid] != nil else { return }
            let ownsAppMedia = callOwnsAppMedia(uuid)
            cancelPendingStart(uuid, error: FlowError.actionTimedOut)
            stopOutgoingRingback(uuid)
            if ownsAppMedia { disableCallAudioEngine() }
            pendingAnswers.removeValue(forKey: uuid)
            startedAnswers.remove(uuid)
            answeredIncomingCalls.remove(uuid)
            cancelIncomingStatusWatch(uuid)
            incomingCalls.removeValue(forKey: uuid)
            if activeCallUUID == uuid { activeCallUUID = nil }
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            if ownsAppMedia { viewModel?.stopCall() }
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        do {
            try audioSession.setCategory(.playAndRecord,
                                         mode: .voiceChat,
                                         options: [.defaultToSpeaker, .allowBluetoothHFP])
            try AudioManager.shared.setEngineAvailability(.default)
            audioSessionActive = true
            startRingbackIfReady()
        } catch {
            audioSessionActive = false
            NSLog("TRINET: CallKit audio activation failed: %@",
                  error.localizedDescription)
            if let uuid = activeCallUUID {
                finishFailedCall(uuid, message: error.localizedDescription)
            }
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        disableCallAudioEngine()
    }

    func providerDidReset(_ provider: CXProvider) {
        let hadOwnedInternetMedia = pendingStarts.keys.contains(where: callOwnsAppMedia) ||
            startedAnswers.contains(where: callOwnsAppMedia) ||
            answeredIncomingCalls.contains(where: callOwnsAppMedia) ||
            activeCallUUID.map(callOwnsAppMedia) == true
        if hadOwnedInternetMedia { disableCallAudioEngine() }
        let starts = pendingStarts
        pendingStarts.removeAll()
        for (uuid, pending) in starts {
            DispatchQueue.main.async {
                pending.completion(uuid, .failure(FlowError.providerReset))
            }
        }
        clearOutgoingRingback()
        for action in pendingAnswers.values { action.fail() }
        pendingAnswers.removeAll()
        startedAnswers.removeAll()
        answeredIncomingCalls.removeAll()
        for task in incomingStatusTasks.values { task.cancel() }
        incomingStatusTasks.removeAll()
        incomingCalls.removeAll()
        busyIncomingReports.removeAll()
        activeCallUUID = nil
        if hadOwnedInternetMedia { viewModel?.stopCall() }
    }

    private func startPendingAnswer(_ uuid: UUID) {
        guard pendingAnswers[uuid] != nil,
              !startedAnswers.contains(uuid),
              let incoming = incomingCalls[uuid],
              incoming.verified,
              let viewModel else { return }
        guard viewModel.phase == .idle, viewModel.activeRoute == nil else {
            // A mesh call can begin after CallKit displayed this Internet
            // invitation but before the user answers. Reject only the pending
            // Internet call; never switch transports underneath live media.
            pendingAnswers.removeValue(forKey: uuid)?.fail()
            startedAnswers.remove(uuid)
            cancelIncomingStatusWatch(uuid)
            incomingCalls.removeValue(forKey: uuid)
            if activeCallUUID == uuid { activeCallUUID = nil }
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            declineIncomingAsBusy(callID: incoming.callID)
            return
        }
        startedAnswers.insert(uuid)
        viewModel.answerInternetCall(callID: incoming.callID,
                                     caller: incoming.caller,
                                     media: incoming.media) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      let action = self.pendingAnswers.removeValue(forKey: uuid) else {
                    return
                }
                self.startedAnswers.remove(uuid)
                switch result {
                case .success:
                    self.answeredIncomingCalls.insert(uuid)
                    action.fulfill()
                case .failure(let error):
                    self.startedAnswers.insert(uuid)
                    action.fail()
                    self.finishFailedCall(uuid, message: error.localizedDescription)
                }
            }
        }
    }

    private func finishFailedCall(_ uuid: UUID, message: String) {
        NSLog("TRINET: call media failed: %@", message)
        let ownsAppMedia = callOwnsAppMedia(uuid)
        cancelPendingStart(uuid, error: FlowError.mediaFailed(message))
        stopOutgoingRingback(uuid)
        if ownsAppMedia { disableCallAudioEngine() }
        startedAnswers.remove(uuid)
        answeredIncomingCalls.remove(uuid)
        cancelIncomingStatusWatch(uuid)
        incomingCalls.removeValue(forKey: uuid)
        if activeCallUUID == uuid { activeCallUUID = nil }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        if ownsAppMedia { viewModel?.stopCall() }
    }

    private func finishPendingStartIfReady(_ uuid: UUID) {
        guard let pending = pendingStarts[uuid],
              pending.gate.isReady,
              activeCallUUID == uuid else { return }
        pendingStarts.removeValue(forKey: uuid)
        outgoingRingingUUID = uuid
        startRingbackIfReady()
        DispatchQueue.main.async {
            pending.completion(uuid, .success(()))
        }
    }

    private func failOutgoingStart(_ uuid: UUID, error: Error) {
        cancelPendingStart(uuid, error: error)
        stopOutgoingRingback(uuid)
        disableCallAudioEngine()
        incomingCalls.removeValue(forKey: uuid)
        if activeCallUUID == uuid {
            activeCallUUID = nil
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        viewModel?.internet.disconnect()
    }

    private func cancelPendingStart(_ uuid: UUID, error: Error) {
        guard let pending = pendingStarts.removeValue(forKey: uuid) else { return }
        DispatchQueue.main.async {
            pending.completion(uuid, .failure(error))
        }
    }

    private func startRingbackIfReady() {
        guard audioSessionActive,
              let uuid = outgoingRingingUUID,
              activeCallUUID == uuid,
              ringbackPlayer == nil,
              let url = Bundle.main.url(forResource: "trinet-call", withExtension: "caf") else {
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.22
            player.prepareToPlay()
            guard player.play() else {
                NSLog("TRINET: outgoing ringback could not start")
                return
            }
            ringbackPlayer = player
        } catch {
            NSLog("TRINET: outgoing ringback failed: %@", error.localizedDescription)
        }
    }

    private func stopOutgoingRingback(_ uuid: UUID) {
        guard outgoingRingingUUID == uuid else { return }
        clearOutgoingRingback()
    }

    private func clearOutgoingRingback() {
        outgoingRingingUUID = nil
        stopRingbackPlayer()
    }

    private func stopRingbackPlayer() {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    private func startIncomingStatusWatch(uuid: UUID, callID: String) {
        cancelIncomingStatusWatch(uuid)
        // PushKit requires an immediate CallKit report, before there is time to
        // authenticate the server record. Keep that neutral report bounded even
        // if URLSession is stalled: a separate main-queue deadline can cancel
        // the polling task instead of waiting for its current request to return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self,
                  self.incomingCalls[uuid]?.callID == callID,
                  self.incomingCalls[uuid]?.verified == false else { return }
            self.rejectUnverifiedIncoming(uuid: uuid)
        }
        incomingStatusTasks[uuid] = Task { [weak self] in
            var transientRetryDelay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                guard let self, let internet = self.viewModel?.internet else { return }
                do {
                    let needsVerification = await MainActor.run {
                        self.incomingCalls[uuid]?.verified == false
                    }
                    if needsVerification,
                       let authenticated = try await internet.authenticatedIncoming(
                        callID: callID) {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            self.reconcileAuthenticatedIncoming(
                                uuid: uuid,
                                callID: authenticated.callID,
                                caller: authenticated.caller,
                                audio: authenticated.audio,
                                video: authenticated.video)
                        }
                    }
                    let status = try await internet.status(callID: callID)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.applyIncomingStatus(status, uuid: uuid)
                    }
                    let keepWatching = await MainActor.run {
                        self.incomingCalls[uuid] != nil
                    }
                    if !keepWatching { return }
                    transientRetryDelay = 1_000_000_000
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                } catch is CancellationError {
                    return
                } catch let error as InternetCallError {
                    if case let .server(code, _) = error,
                       (400...499).contains(code), code != 408, code != 429 {
                        await MainActor.run {
                            if self.incomingCalls[uuid]?.verified == true {
                                // The call can become terminal between the
                                // authenticated /incoming read and /status.
                                // A participant-scoped 4xx must close the
                                // verified system call instead of orphaning it.
                                let reason: CXCallEndedReason =
                                    [403, 404, 409].contains(code) ? .remoteEnded : .failed
                                self.finishIncomingAfterStatusFailure(uuid: uuid,
                                                                      reason: reason)
                            } else {
                                self.rejectUnverifiedIncoming(uuid: uuid)
                            }
                        }
                        return
                    }
                    NSLog("TRINET: incoming status poll failed call=%@ error=%@",
                          callID, error.localizedDescription)
                } catch {
                    NSLog("TRINET: incoming status poll failed call=%@ error=%@",
                          callID, error.localizedDescription)
                }
                do {
                    try await Task.sleep(nanoseconds: transientRetryDelay)
                } catch {
                    return
                }
                transientRetryDelay = min(transientRetryDelay * 2, 8_000_000_000)
            }
        }
    }

    private func reconcileAuthenticatedIncoming(uuid: UUID,
                                                callID: String,
                                                caller: String,
                                                audio: Bool,
                                                video: Bool) {
        guard var context = incomingCalls[uuid], context.callID == callID else { return }
        let media = InternetCallMedia(audio: audio, video: video)
        let safeCaller = DeviceDisplayNamePolicy.safe(caller, fallback: "TRI-NET peer")
        context.media = media
        context.caller = safeCaller
        context.verified = true
        incomingCalls[uuid] = context
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: safeCaller)
        update.localizedCallerName = safeCaller
        update.hasVideo = media.video
        provider.reportCall(with: uuid, updated: update)
        startPendingAnswer(uuid)
    }

    private func rejectUnverifiedIncoming(uuid: UUID) {
        guard incomingCalls[uuid]?.verified == false else { return }
        pendingAnswers.removeValue(forKey: uuid)?.fail()
        startedAnswers.remove(uuid)
        cancelIncomingStatusWatch(uuid)
        incomingCalls.removeValue(forKey: uuid)
        if activeCallUUID == uuid { activeCallUUID = nil }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
    }

    private func finishIncomingAfterStatusFailure(uuid: UUID,
                                                  reason: CXCallEndedReason) {
        guard incomingCalls[uuid] != nil else { return }
        let ownsAppMedia = callOwnsAppMedia(uuid)
        pendingAnswers.removeValue(forKey: uuid)?.fail()
        startedAnswers.remove(uuid)
        answeredIncomingCalls.remove(uuid)
        cancelIncomingStatusWatch(uuid)
        incomingCalls.removeValue(forKey: uuid)
        if activeCallUUID == uuid { activeCallUUID = nil }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        if ownsAppMedia { viewModel?.stopCall() }
    }

    private func applyIncomingStatus(_ status: InternetCallStatus, uuid: UUID) {
        guard incomingCalls[uuid]?.callID == status.callID else { return }
        let reason: CXCallEndedReason?
        if status.status == "active" && !status.answeredHere {
            reason = .answeredElsewhere
        } else {
            switch status.status {
            case "cancelled", "ended": reason = .remoteEnded
            case "missed": reason = .unanswered
            case "declined": reason = .declinedElsewhere
            default: reason = nil
            }
        }
        guard let reason else { return }
        let ownsAppMedia = callOwnsAppMedia(uuid)
        pendingAnswers.removeValue(forKey: uuid)?.fail()
        startedAnswers.remove(uuid)
        answeredIncomingCalls.remove(uuid)
        cancelIncomingStatusWatch(uuid)
        incomingCalls.removeValue(forKey: uuid)
        if activeCallUUID == uuid { activeCallUUID = nil }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        // A terminal server state stops only media that this Internet UUID
        // actually started; an unanswered banner must not tear down Mesh.
        if ownsAppMedia { viewModel?.stopCall() }
    }

    private func cancelIncomingStatusWatch(_ uuid: UUID) {
        incomingStatusTasks.removeValue(forKey: uuid)?.cancel()
    }

    private func callOwnsAppMedia(_ uuid: UUID) -> Bool {
        if startedAnswers.contains(uuid) || answeredIncomingCalls.contains(uuid) {
            return true
        }
        // An active UUID without an incoming context is an outgoing Internet
        // call. Incoming contexts do not own media until Answer starts.
        return activeCallUUID == uuid && incomingCalls[uuid] == nil
    }

    private func disableCallAudioEngine() {
        audioSessionActive = false
        stopRingbackPlayer()
        do {
            try AudioManager.shared.setEngineAvailability(.none)
        } catch {
            NSLog("TRINET: CallKit audio deactivation failed: %@",
                  error.localizedDescription)
        }
    }
}
