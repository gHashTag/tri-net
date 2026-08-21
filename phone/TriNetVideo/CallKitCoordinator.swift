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
        userInfo["type"] as? String != "group_chat_message"
    }
}

struct CallStartGate {
    var requestSucceeded = false
    var actionSucceeded = false

    var isReady: Bool {
        requestSucceeded && actionSucceeded
    }
}

final class TriNetAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        UserDefaults.standard.set("sandbox",
                                  forKey: CallKitCoordinator.pushEnvironmentDefaultsKey)
        #else
        UserDefaults.standard.set("production",
                                  forKey: CallKitCoordinator.pushEnvironmentDefaultsKey)
        #endif
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
        #if DEBUG
        UserDefaults.standard.set("sandbox",
                                  forKey: CallKitCoordinator.pushEnvironmentDefaultsKey)
        #else
        UserDefaults.standard.set("production",
                                  forKey: CallKitCoordinator.pushEnvironmentDefaultsKey)
        #endif
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
            notification.request.content.userInfo
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
            response.notification.request.content.userInfo
        )
        completionHandler()
    }
}

final class CallKitCoordinator: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
    private struct IncomingCallContext {
        let callID: String
        let media: InternetCallMedia
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
        case mediaFailed(String)
        case providerReset

        var errorDescription: String? {
            switch self {
            case .actionTimedOut:
                return "The system timed out while starting the call."
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
    private var activeCallUUID: UUID?
    private var pendingStarts: [UUID: PendingStart] = [:]
    private var pendingAnswers: [UUID: CXAnswerCallAction] = [:]
    private var startedAnswers: Set<UUID> = []
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
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
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
        // A failed or interrupted CallKit transaction can leave our single call
        // group occupied. Close only the call owned by this provider before a
        // new foreground attempt; otherwise CallKit rejects the next request
        // with maximumCallGroupsReached while WebRTC continues independently.
        if let staleUUID = activeCallUUID {
            cancelPendingStart(staleUUID, error: CancellationError())
            stopOutgoingRingback(staleUUID)
            provider.reportCall(with: staleUUID, endedAt: Date(), reason: .failed)
            incomingCalls.removeValue(forKey: staleUUID)
            activeCallUUID = nil
        }
        let uuid = UUID()
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

    func reportIncoming(callID: String,
                        caller: String,
                        audio: Bool,
                        video: Bool,
                        uuid: UUID = UUID(),
                        completion: ((Bool) -> Void)? = nil) {
        if incomingCalls.contains(where: { $0.value.callID == callID }) {
            completion?(true)
            return
        }
        let media = InternetCallMedia(audio: audio, video: video)
        incomingCalls[uuid] = IncomingCallContext(callID: callID, media: media)
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = media.video
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                NSLog("TRINET: incoming CallKit report failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.incomingCalls.removeValue(forKey: uuid)
                    if self.activeCallUUID == uuid { self.activeCallUUID = nil }
                    self.viewModel?.internet.allowIncomingRetry(callID: callID)
                }
            }
            completion?(error == nil)
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

    func handleAlertNotification(_ userInfo: [AnyHashable: Any]) {
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
            self.viewModel?.receiveAlertNotification(unreadCount: badge)
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
        let caller = values["caller_name"] as? String ?? values["caller"] as? String ?? "TRI-NET caller"
        let uuid = (values["call_uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        reportIncoming(callID: callID,
                       caller: caller,
                       audio: values["audio"] as? Bool ?? true,
                       video: values["video"] as? Bool ?? true,
                       uuid: uuid,
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
            self.startedAnswers.remove(action.callUUID)
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
        cancelPendingStart(action.callUUID, error: CancellationError())
        stopOutgoingRingback(action.callUUID)
        pendingAnswers.removeValue(forKey: action.callUUID)?.fail()
        startedAnswers.remove(action.callUUID)
        incomingCalls.removeValue(forKey: action.callUUID)
        if activeCallUUID == action.callUUID { activeCallUUID = nil }
        viewModel?.stopCall()
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
            startedAnswers.remove(uuid)
            finishFailedCall(uuid, message: "Timed out while answering the call.")
            return
        }
        if let endAction = action as? CXEndCallAction {
            let uuid = endAction.callUUID
            cancelPendingStart(uuid, error: FlowError.actionTimedOut)
            stopOutgoingRingback(uuid)
            disableCallAudioEngine()
            pendingAnswers.removeValue(forKey: uuid)
            startedAnswers.remove(uuid)
            incomingCalls.removeValue(forKey: uuid)
            if activeCallUUID == uuid { activeCallUUID = nil }
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
            viewModel?.stopCall()
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
        disableCallAudioEngine()
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
        incomingCalls.removeAll()
        activeCallUUID = nil
        viewModel?.stopCall()
    }

    private func startPendingAnswer(_ uuid: UUID) {
        guard pendingAnswers[uuid] != nil,
              !startedAnswers.contains(uuid),
              let incoming = incomingCalls[uuid],
              let viewModel else { return }
        startedAnswers.insert(uuid)
        viewModel.answerInternetCall(callID: incoming.callID,
                                     media: incoming.media) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      let action = self.pendingAnswers.removeValue(forKey: uuid) else {
                    return
                }
                self.startedAnswers.remove(uuid)
                switch result {
                case .success:
                    action.fulfill()
                case .failure(let error):
                    action.fail()
                    self.finishFailedCall(uuid, message: error.localizedDescription)
                }
            }
        }
    }

    private func finishFailedCall(_ uuid: UUID, message: String) {
        NSLog("TRINET: call media failed: %@", message)
        cancelPendingStart(uuid, error: FlowError.mediaFailed(message))
        stopOutgoingRingback(uuid)
        disableCallAudioEngine()
        startedAnswers.remove(uuid)
        incomingCalls.removeValue(forKey: uuid)
        if activeCallUUID == uuid { activeCallUUID = nil }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        viewModel?.stopCall()
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
