// ViewModel.swift — Direct Mac↔iPhone video call via BSD UDP
import SwiftUI
import AVFoundation
import Combine

struct ChatLine: Identifiable {
    let id = UUID()
    enum Who { case me, them }
    let who: Who
    let text: String
}

// Wraps a saved recording URL so it can drive a SwiftUI share sheet.
struct RecFile: Identifiable {
    let id = UUID()
    let url: URL
}

class StreamViewModel: ObservableObject {
    @Published var phase: CallPhase = .idle
    @Published var remoteIP: String = UserDefaults.standard.string(forKey: "remoteIP") ?? "192.168.1.105"
    @Published var callee: String = UserDefaults.standard.string(forKey: "internetCallee") ?? "ssd26"
    @Published var route: CallRoute = CallRoute(rawValue: UserDefaults.standard.string(forKey: "callRoute") ?? "Auto") ?? .automatic
    @Published private(set) var activeRoute: CallRoute?
    @Published var callError: String?
    @Published var identity: DeviceIdentity
    @Published var internetConfiguration: InternetCallConfiguration
    @Published var incomingMeshCall: IncomingMeshCall?
    @Published var myIP: String = ""
    @Published var framesSent: Int = 0
    @Published var framesReceived: Int = 0
    @Published var txKBps: Double = 0
    @Published var rxKBps: Double = 0
    @Published var cameraAuthorized = false
    @Published var isMuted = false
    @Published var cameraOff = false
    @Published var recentIPs: [String] = []
    // Live audio levels (0...1) for the TX/RX meters, peak-held with decay.
    @Published var txLevel: Float = 0
    @Published var rxLevel: Float = 0
    // Chat + reactions (shown live on both ends)
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?
    @Published var isBlurred = false

    func toggleBlur() {
        isBlurred.toggle()
        camera.blurBackground = isBlurred
    }

    // Mesh profile: 150 kbps cap for the ~200-400 kbps half-duplex radio budget,
    // and watches the 17850B per-NAL ceiling the bridge can address.
    @Published var isMeshProfile = false
    func toggleMeshProfile() {
        isMeshProfile.toggle()
        camera.meshMode = isMeshProfile
    }

    // Call recording (video + mixed audio) → shareable .mov in Documents.
    @Published var isRecording = false
    @Published var shareFile: RecFile?
    private let recorder = CallRecorder()
    private var recSink: AnyCancellable?

    func toggleRecording() {
        if isRecording {
            recorder.stop { [weak self] url in
                DispatchQueue.main.async {
                    if let u = url { self?.shareFile = RecFile(url: u) }
                }
            }
            isRecording = false
            recSink = nil
        } else {
            recorder.start()
            isRecording = recorder.recording
            // Append every decoded remote frame to the recording.
            recSink = decoder.$currentFrame.sink { [weak self] buf in
                guard let self = self, self.isRecording, let b = buf else { return }
                self.recorder.append(b)
            }
        }
    }

    // Adaptive bitrate. Driven by the NODE's verdict when a node is relaying for
    // us, and only by PLI when none is — PLI is the far end's decoder
    // complaining, which arrives once frames are already broken and whose
    // absence makes us climb until we break them again.
    private var pliCount = 0
    private var abrTimer: Timer?
    private var linkAdvice: UInt8?
    private var linkUtil = 0
    private var linkDrop = 0
    private var linkRate = 0
    private var linkSeenAt: Date?
    // The node's own view of the link, for the HUD. Empty on a direct call.
    @Published var linkInfo = ""
    // Mirrors ADVICE_* in specs/video_bridge.t27. Values only — no thresholds:
    // the node decides, we obey.
    private static let adviceBackOff: UInt8 = 1
    private static let adviceClimb: UInt8 = 2

    func noteLinkFeedback(advice: UInt8, util: Int, drop: Int, rate: Int) {
        linkAdvice = advice
        linkUtil = util
        linkDrop = drop
        linkRate = rate
        linkSeenAt = Date()
        let word = advice == StreamViewModel.adviceBackOff ? "slow"
                 : (advice == StreamViewModel.adviceClimb ? "climb" : "hold")
        linkInfo = "node \(util)% · loss \(drop)% · \(rate)/s · \(word)"
        if drop > 0 {
            NSLog("%@", "TRINET: node is dropping \(drop)% of our payloads (util \(util)% of \(rate)/s)")
        }
    }

    func startABR() {
        abrTimer?.invalidate()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, self.phase == .live else { return }
            let fresh = self.linkSeenAt.map { Date().timeIntervalSince($0) < 5 } ?? false
            if fresh, let advice = self.linkAdvice {
                if advice == StreamViewModel.adviceBackOff {
                    self.camera.nudgeBitrate(down: true)
                    NSLog("%@", "TRINET: ABR down — node: util=\(self.linkUtil)% drops=\(self.linkDrop)% of \(self.linkRate)/s")
                } else if advice == StreamViewModel.adviceClimb {
                    self.camera.nudgeBitrate(down: false)
                }
                // Anything else: hold. The node's hysteresis band, not ours.
            } else {
                // No node relaying (direct call): the PLI loop is all there is.
                if self.pliCount >= 3 { self.camera.nudgeBitrate(down: true) }
                else if self.pliCount == 0 { self.camera.nudgeBitrate(down: false) }
            }
            self.pliCount = 0
        }
    }
    func notePLI() { pliCount += 1 }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if activeRoute == .internet {
            internet.sendChat(t)
            chat.append(ChatLine(who: .me, text: t))
            return
        }
        var d = Data([0xFB, 0xCA]); d.append(Data(t.utf8))
        transport.send(d)
        chat.append(ChatLine(who: .me, text: t))
    }

    func sendReaction(_ emoji: String) {
        if activeRoute == .internet {
            internet.sendReaction(emoji)
            showReaction(emoji)
            return
        }
        var d = Data([0xFE, 0xAC]); d.append(Data(emoji.utf8))
        transport.send(d)
        showReaction(emoji)
    }

    private var reactionTask: DispatchWorkItem?
    func showReaction(_ emoji: String) {
        liveReaction = emoji
        reactionTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.liveReaction = nil }
        reactionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    enum CallPhase: Equatable {
        case idle, connecting, live
    }

    let camera = CameraController()
    let transport = BSDTransport()
    let decoder = H264Decoder()
    let audio = AudioController()
    let internet: InternetCallController
    let directory: NicknameDirectoryController
    let account: AccountDeviceController
    let groupChat: GroupChatController

    private var bytesSent = 0
    private var bytesRecv = 0
    private var timer: Timer?
    private var callKitUUID: UUID?
    private var meshAttemptID: UUID?

    init() {
        let loadedIdentity: DeviceIdentity
        do {
            loadedIdentity = try DeviceIdentityStore.shared.loadOrCreate(defaultName: "ssd26")
        } catch {
            loadedIdentity = DeviceIdentity(userID: UUID().uuidString.lowercased(),
                                            deviceID: UUID().uuidString.lowercased(),
                                            displayName: "ssd26",
                                            nickname: nil,
                                            signingPublicKey: "",
                                            keyFingerprint: "unavailable")
        }
        let loadedConfiguration = InternetCallConfiguration.load()
        identity = loadedIdentity
        internetConfiguration = loadedConfiguration
        internet = InternetCallController(identity: loadedIdentity, configuration: loadedConfiguration)
        directory = NicknameDirectoryController(identity: loadedIdentity, configuration: loadedConfiguration)
        account = AccountDeviceController(identity: loadedIdentity, configuration: loadedConfiguration)
        groupChat = GroupChatController(identity: loadedIdentity, configuration: loadedConfiguration)
        myIP = getLocalIP()
        if let saved = UserDefaults.standard.array(forKey: "recentCallIPs") as? [String] {
            recentIPs = saved
        }
        internet.onChat = { [weak self] text in
            self?.chat.append(ChatLine(who: .them, text: text))
        }
        internet.onReaction = { [weak self] value in
            self?.showReaction(value)
        }
        internet.onIncomingCall = { [weak self] incoming in
            guard let self, self.phase == .idle else { return }
            CallKitCoordinator.shared.reportIncoming(callID: incoming.callID,
                                                     caller: incoming.caller,
                                                     video: incoming.video)
        }
        directory.onIdentityChanged = { [weak self] updatedIdentity in
            guard let self else { return }
            self.identity = updatedIdentity
            self.internet.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.account.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.groupChat.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.internet.startIncomingPolling(voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
            self.account.sync()
        }
        account.onIdentityChanged = { [weak self] updatedIdentity in
            guard let self else { return }
            self.identity = updatedIdentity
            self.internet.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.directory.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.groupChat.update(identity: updatedIdentity, configuration: self.internetConfiguration)
        }
        directory.onIncomingMeshInvite = { [weak self] invite, address in
            guard let self, self.phase == .idle else { return }
            self.incomingMeshCall = IncomingMeshCall(invite: invite, sourceAddress: address)
        }
        internet.startIncomingPolling(voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
        account.sync()
        groupChat.startPolling()
    }

    func saveInternetSettings() {
        internetConfiguration.save()
        UserDefaults.standard.set(route.rawValue, forKey: "callRoute")
        internet.update(identity: identity, configuration: internetConfiguration)
        directory.update(identity: identity, configuration: internetConfiguration)
        account.update(identity: identity, configuration: internetConfiguration)
        groupChat.update(identity: identity, configuration: internetConfiguration)
        internet.startIncomingPolling(voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
        account.sync()
    }

    func renameDevice(_ name: String) {
        do {
            identity = try DeviceIdentityStore.shared.rename(name)
            internet.update(identity: identity, configuration: internetConfiguration)
            directory.update(identity: identity, configuration: internetConfiguration)
            account.update(identity: identity, configuration: internetConfiguration)
            groupChat.update(identity: identity, configuration: internetConfiguration)
        } catch {
            callError = error.localizedDescription
        }
    }

    func checkPermission() {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = (s == .authorized)
        if s == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.cameraAuthorized = granted }
            }
        }
    }

    func startCall() {
        callError = nil
        let typedTarget = directory.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = NicknamePolicy.normalize(typedTarget.isEmpty ? callee : typedTarget)
        callee = target
        let meshContact = directory.meshContact(named: target)
        let selected: CallRoute
        switch route {
        case .automatic:
            if isMeshAddress(target) {
                remoteIP = target
                selected = .mesh
            } else if let meshContact, let address = meshContact.meshAddress {
                remoteIP = address
                selected = .mesh
            } else {
                selected = .internet
            }
        case .mesh, .internet:
            selected = route
        }
        if selected == .mesh {
            if isMeshAddress(target) {
                remoteIP = target
            } else if let address = meshContact?.meshAddress {
                remoteIP = address
            } else {
                callError = "@\(target) is not visible in the current mesh."
                activeRoute = nil
                return
            }
        }
        activeRoute = selected
        UserDefaults.standard.set(route.rawValue, forKey: "callRoute")
        if selected == .internet {
            startInternetCall()
        } else {
            do {
                _ = try directory.sendMeshInvite(to: remoteIP, port: meshContact?.meshPort)
            } catch {
                callError = error.localizedDescription
                activeRoute = nil
                return
            }
            startMeshCall()
        }
    }

    func acceptIncomingMeshCall() {
        guard let incoming = incomingMeshCall else { return }
        incomingMeshCall = nil
        callee = incoming.invite.nickname
        remoteIP = incoming.sourceAddress
        activeRoute = .mesh
        startMeshCall()
    }

    func declineIncomingMeshCall() {
        incomingMeshCall = nil
    }

    func claimNickname() {
        directory.claimProposedNickname()
    }

    func searchNicknames() {
        let target = NicknamePolicy.normalize(directory.searchQuery)
        if !target.isEmpty { callee = target }
        directory.search()
    }

    func selectContact(_ contact: DirectoryContact) {
        callee = contact.nickname
        if let address = contact.meshAddress {
            remoteIP = address
        }
        route = .automatic
    }

    private func startInternetCall() {
        let target = callee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            callError = "Enter a contact or device name."
            activeRoute = nil
            return
        }
        UserDefaults.standard.set(target, forKey: "internetCallee")
        internet.update(identity: identity, configuration: internetConfiguration)
        callKitUUID = CallKitCoordinator.shared.startOutgoing(handle: target, video: true)
        phase = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.internet.start(callee: target, audio: true, video: true)
                await MainActor.run {
                    self.phase = .live
                    if let uuid = self.callKitUUID { CallKitCoordinator.shared.markOutgoingConnected(uuid) }
                }
            } catch {
                await MainActor.run {
                    if let uuid = self.callKitUUID { CallKitCoordinator.shared.end(uuid) }
                    self.callKitUUID = nil
                    self.callError = error.localizedDescription
                    self.phase = .idle
                    self.activeRoute = nil
                }
            }
        }
    }

    func answerInternetCall(callID: String) {
        activeRoute = .internet
        phase = .connecting
        internet.update(identity: identity, configuration: internetConfiguration)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.internet.join(callID: callID, audio: true, video: true)
                await MainActor.run { self.phase = .live }
            } catch {
                await MainActor.run {
                    self.callError = error.localizedDescription
                    self.phase = .idle
                    self.activeRoute = nil
                }
            }
        }
    }

    private func startMeshCall() {
        UserDefaults.standard.set(remoteIP, forKey: "remoteIP")
        if !recentIPs.contains(remoteIP) {
            recentIPs.insert(remoteIP, at: 0)
            if recentIPs.count > 5 { recentIPs.removeLast() }
            UserDefaults.standard.set(recentIPs, forKey: "recentCallIPs")
        }

        phase = .connecting
        let attemptID = UUID()
        meshAttemptID = attemptID

        // UDP: send to remoteIP:7000, listen on 7000 (same port for both)
        transport.onSecureSessionReady = { [weak self] in
            guard let self, self.meshAttemptID == attemptID else { return }
            self.meshAttemptID = nil
            self.phase = .live
        }
        transport.connect(host: remoteIP, port: 7000, recvPort: 7000)

        // Peer PLI → force an IDR from our encoder
        decoder.onKeyframeNeeded = { [weak self] in
            self?.transport.send(Data([0xFC, 0x00]))
        }

        // Incoming: UDP → PLI / audio / chat / reaction / H.264 decoder → display
        transport.onLinkFeedback = { [weak self] advice, util, drop, rate in
            self?.noteLinkFeedback(advice: advice, util: util, drop: drop, rate: rate)
        }

        transport.onData = { [weak self] data in
            guard let self = self else { return }
            self.bytesRecv += data.count
            if data.count == 2, data[0] == 0xFC { // Picture Loss Indication
                self.camera.forceKeyframe()
                self.notePLI()   // adaptive bitrate signal
                return
            }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD { // audio (raw PCM)
                self.audio.playPacket(data.subdata(in: 2..<data.count))
                return
            }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xC0 { // audio (Opus)
                self.audio.playOpus(data.subdata(in: 2..<data.count))
                return
            }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA { // chat
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)) }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            self.decoder.feed(data)
            DispatchQueue.main.async {
                self.framesReceived = self.decoder.frameCount
                if self.phase != .live { self.phase = .live }
            }
        }

        // Outgoing audio: mic → 16k PCM → UDP (mute drops packets at source)
        audio.onPacket = { [weak self] pkt in
            guard let self = self, !self.isMuted else { return }
            self.transport.sendAudio(pkt)
        }
        // Audio levels -> meters (peak-hold with decay so bars don't flicker)
        audio.onTxLevel = { [weak self] lvl in
            DispatchQueue.main.async { self?.txLevel = max(lvl, (self?.txLevel ?? 0) * 0.8) }
        }
        audio.onRxLevel = { [weak self] lvl in
            DispatchQueue.main.async { self?.rxLevel = max(lvl, (self?.rxLevel ?? 0) * 0.8) }
        }
        // Incoming + local mic PCM → recorder (mixed) while recording.
        audio.onRxPCM = { [weak self] pcm in
            guard let self = self, self.isRecording else { return }
            self.recorder.appendAudio(pcm)
        }
        audio.onTxPCM = { [weak self] pcm in
            guard let self = self, self.isRecording else { return }
            self.recorder.pushLocalAudio(pcm)
        }
        // Off the main path: first touch of the mic can block on permission /
        // session init, and audio must never hold up transport/video startup.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }

        // Outgoing: camera → H.264 → UDP
        camera.onFrame = { [weak self] h264Data, _ in
            guard let self = self, !self.cameraOff else { return }
            self.transport.send(h264Data)
            self.bytesSent += h264Data.count
            DispatchQueue.main.async { self.framesSent += 1 }
        }
        camera.start()

        // Metrics timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                self.txKBps = Double(self.bytesSent) / 1024
                self.rxKBps = Double(self.bytesRecv) / 1024
            }
        }

        startABR()

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.meshAttemptID == attemptID, self.phase == .connecting else { return }
            self.callError = "The local peer did not accept the call within 30 seconds."
            self.stopCall()
        }
    }

    func stopCall() {
        if activeRoute == .internet {
            internet.disconnect()
            CallKitCoordinator.shared.endCurrent()
            callKitUUID = nil
            phase = .idle
            activeRoute = nil
            framesSent = 0
            framesReceived = 0
            return
        }
        if isRecording {
            recorder.stop { [weak self] url in
                DispatchQueue.main.async { if let u = url { self?.shareFile = RecFile(url: u) } }
            }
            isRecording = false
            recSink = nil
        }
        camera.stop()
        camera.stopAll()
        audio.stop()
        transport.disconnect()
        meshAttemptID = nil
        timer?.invalidate(); timer = nil
        abrTimer?.invalidate(); abrTimer = nil
        phase = .idle
        framesSent = 0; framesReceived = 0
        bytesSent = 0; bytesRecv = 0
        txKBps = 0; rxKBps = 0
        activeRoute = nil
    }

    func toggleMute() {
        isMuted.toggle()
        if activeRoute == .internet { internet.setMuted(isMuted) }
    }

    func toggleCamera() {
        cameraOff.toggle()
        if activeRoute == .internet { internet.setCamera(enabled: !cameraOff) }
    }

    private func isMeshAddress(_ value: String) -> Bool {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasSuffix(".local") { return true }
        let parts = address.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    // Get local WiFi IP
    private func getLocalIP() -> String {
        var address = "?.?.?.?"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr!.pointee.ifa_next }
                let iface = ptr!.pointee
                let family = iface.ifa_addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    let name = String(cString: iface.ifa_name)
                    if name.hasPrefix("en") || name.hasPrefix("pdp") || name.hasPrefix("wl") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        let s = String(cString: hostname)
                        if !s.hasPrefix("169.254") && s != "127.0.0.1" {
                            address = s
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
