import CallKit
import Foundation
import PushKit
import UIKit

final class TriNetAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CallKitCoordinator.shared.startPushRegistry()
        return true
    }
}

final class CallKitCoordinator: NSObject, CXProviderDelegate, PKPushRegistryDelegate {
    static let shared = CallKitCoordinator()

    private let provider: CXProvider
    private let callController = CXCallController()
    private var callIDs: [UUID: String] = [:]
    private var activeCallUUID: UUID?
    private weak var viewModel: StreamViewModel?
    private var pushRegistry: PKPushRegistry?

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func attach(viewModel: StreamViewModel) {
        self.viewModel = viewModel
        if let token = UserDefaults.standard.string(forKey: "voipPushToken"), !token.isEmpty {
            Task { try? await viewModel.internet.registerDevice(voipToken: token) }
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

    func startOutgoing(handle: String, video: Bool) -> UUID {
        // A failed or interrupted CallKit transaction can leave our single call
        // group occupied. Close only the call owned by this provider before a
        // new foreground attempt; otherwise CallKit rejects the next request
        // with maximumCallGroupsReached while WebRTC continues independently.
        if let staleUUID = activeCallUUID {
            provider.reportCall(with: staleUUID, endedAt: Date(), reason: .failed)
            callIDs.removeValue(forKey: staleUUID)
            activeCallUUID = nil
        }
        let uuid = UUID()
        activeCallUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = video
        callController.request(CXTransaction(action: action)) { error in
            guard let error else { return }
            NSLog("TRINET: CallKit start failed: %@", error.localizedDescription)
            DispatchQueue.main.async {
                if self.activeCallUUID == uuid {
                    self.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
                    self.activeCallUUID = nil
                }
            }
        }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        return uuid
    }

    func markOutgoingConnected(_ uuid: UUID) {
        guard activeCallUUID == uuid else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func reportIncoming(callID: String, caller: String, video: Bool, uuid: UUID = UUID(), completion: (() -> Void)? = nil) {
        if callIDs.contains(where: { $0.value == callID }) {
            completion?()
            return
        }
        callIDs[uuid] = callID
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = video
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                NSLog("TRINET: incoming CallKit report failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.callIDs.removeValue(forKey: uuid)
                    if self.activeCallUUID == uuid { self.activeCallUUID = nil }
                }
            }
            completion?()
        }
    }

    func end(_ uuid: UUID) {
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

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "voipPushToken")
        if let viewModel {
            Task { try? await viewModel.internet.registerDevice(voipToken: token) }
        }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        UserDefaults.standard.removeObject(forKey: "voipPushToken")
        if let viewModel {
            Task { try? await viewModel.internet.registerDevice(voipToken: nil) }
        }
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
                       video: values["video"] as? Bool ?? true,
                       uuid: uuid,
                       completion: completion)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callID = callIDs[action.callUUID], let viewModel else {
            action.fail()
            return
        }
        viewModel.answerInternetCall(callID: callID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        callIDs.removeValue(forKey: action.callUUID)
        if activeCallUUID == action.callUUID { activeCallUUID = nil }
        viewModel?.stopCall()
        action.fulfill()
    }

    func providerDidReset(_ provider: CXProvider) {
        callIDs.removeAll()
        activeCallUUID = nil
        viewModel?.stopCall()
    }
}
