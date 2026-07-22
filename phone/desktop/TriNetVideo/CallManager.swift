// CallManager.swift — Orchestrates camera → encode → transport → decode → display
import Foundation
import Combine
import AVFoundation
import CoreVideo

struct ChatLine: Identifiable {
    let id = UUID()
    enum Who { case me, them }
    let who: Who
    let text: String
}

class CallManager: ObservableObject {
    @Published var isInCall = false
    @Published var isStarting = false
    @Published var remoteIP = "192.168.1.103"
    @Published var callee = UserDefaults.standard.string(forKey: "internetCallee") ?? "ssd26"
    @Published var route = CallRoute(rawValue: UserDefaults.standard.string(forKey: "callRoute") ?? "Auto") ?? .automatic
    @Published private(set) var activeRoute: CallRoute?
    @Published var identity: DeviceIdentity
    @Published var internetConfiguration: InternetCallConfiguration
    @Published var incomingMeshCall: IncomingMeshCall?
    @Published var incomingInternetCall: IncomingInternetCall?
    @Published var port = "7000"
    @Published var localIP = ""
    @Published var framesSent = 0
    @Published var framesReceived = 0
    @Published var status = "Ready"
    @Published var error: String?
    @Published var isMuted = false
    @Published var cameraOff = false
    @Published var recentIPs: [String] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String = ""
    // Live audio levels (0...1) for the TX/RX meters. Decayed on the main
    // thread so the bars fall smoothly when a buffer is quiet or absent.
    @Published var txLevel: Float = 0
    @Published var rxLevel: Float = 0
    @Published var bitrateKbps: Int = 0
    // The node's own view of the link, for the HUD. Empty on a direct call.
    @Published var linkInfo = ""

    // Adaptive bitrate: sample the incoming PLI rate every 3s. Sustained PLIs
    // mean the peer is losing our video → back off; a clean window → recover.
    private var pliCount = 0
    private var abrTimer: Timer?
    private var meshAttemptID: UUID?
    // The node's verdict on the link, if one is relaying for us. Nil on a direct
    // peer-to-peer call: there is no node, so there is nothing to hear.
    private var linkAdvice: UInt8?
    private var linkUtil = 0
    private var linkDrop = 0
    private var linkRate = 0
    private var linkSeenAt: Date?
    // Mirrors ADVICE_* in specs/video_bridge.t27. Values only — no thresholds.
    private static let adviceBackOff: UInt8 = 1
    private static let adviceClimb: UInt8 = 2

    private func startABR() {
        abrTimer?.invalidate()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, self.isInCall else { return }

            // Prefer the NODE's report over PLI. PLI is the far end's decoder
            // complaining — it only arrives once frames are already broken, and
            // its absence makes us climb until we break them again. The node
            // says what the link is doing before anything is lost.
            let fresh = self.linkSeenAt.map { Date().timeIntervalSince($0) < 5 } ?? false
            if fresh, let advice = self.linkAdvice {
                if advice == CallManager.adviceBackOff {
                    self.camera.nudgeBitrate(down: true)
                    NSLog("%@", "TRINET: ABR down — node: util=\(self.linkUtil)% drops=\(self.linkDrop)% of \(self.linkRate)/s -> \(self.camera.bitrateKbps)kbps")
                } else if advice == CallManager.adviceClimb {
                    self.camera.nudgeBitrate(down: false)
                }
                // Anything else: hold. The node's hysteresis band, not ours.
            } else {
                // No node relaying (direct call): the old PLI loop is all there is.
                if self.pliCount >= 3 { self.camera.nudgeBitrate(down: true) }
                else if self.pliCount == 0 { self.camera.nudgeBitrate(down: false) }
            }
            self.pliCount = 0
            self.bitrateKbps = self.camera.bitrateKbps
        }
    }



    // Honest link reporting + the app's own log, live in the UI.
    // Both are plain references — the views observe them directly.
    let link = LinkStatus()
    let log = LogBus.shared

    init() {
        let loadedIdentity: DeviceIdentity
        do {
            loadedIdentity = try DeviceIdentityStore.shared.loadOrCreate(defaultName: "TRI-NET Mac")
        } catch {
            loadedIdentity = DeviceIdentity(userID: UUID().uuidString.lowercased(),
                                            deviceID: UUID().uuidString.lowercased(),
                                            displayName: "TRI-NET Mac",
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
        LogBus.shared.start()   // tee stderr (where every NSLog lands) into the UI
        localIP = MeshTransport.getLocalIP()
        // Load recent IPs from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: "recentIPs") as? [String] {
            recentIPs = saved
        }
        cameras = CameraCapture.availableCameras()
        selectedCameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID ?? ""
        internet.onChat = { [weak self] text in
            self?.chat.append(ChatLine(who: .them, text: text))
        }
        internet.onReaction = { [weak self] value in
            self?.showReaction(value)
        }
        internet.onIncomingCall = { [weak self] incoming in
            guard let self, !self.isInCall, !self.isStarting else { return }
            self.incomingInternetCall = incoming
        }
        directory.onIdentityChanged = { [weak self] updatedIdentity in
            guard let self else { return }
            self.identity = updatedIdentity
            self.internet.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.account.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.groupChat.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.internet.startIncomingPolling()
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
            guard let self, !self.isInCall, !self.isStarting else { return }
            self.incomingMeshCall = IncomingMeshCall(invite: invite, sourceAddress: address)
        }
        internet.startIncomingPolling()
        account.sync()
        groupChat.startPolling()
    }

    func selectCamera(_ id: String) {
        selectedCameraID = id
        guard let device = cameras.first(where: { $0.uniqueID == id }) else { return }
        if isInCall { camera.switchTo(device) }
    }

    let camera = CameraCapture()
    let decoder = VideoDecoder()
    let transport = MeshTransport()
    let audio = AudioController()
    let internet: InternetCallController
    let directory: NicknameDirectoryController
    let account: AccountDeviceController
    let groupChat: GroupChatController
    private var screen: Any?  // ScreenCapture (macOS 12.3+), lazily created
    private let recorder = CallRecorder()
    private var recSink: AnyCancellable?
    @Published var isRecording = false
    @Published var lastRecordingPath: String?
    @Published var isBlurred = false

    func toggleBlur() {
        isBlurred.toggle()
        camera.blurBackground = isBlurred
    }

    // Mesh profile: caps video at 150 kbps for the ~200-400 kbps half-duplex radio
    // budget, and watches the 17850B per-NAL ceiling the bridge can address
    // (255 fragments x 70B, specs/video_bridge.t27). Over Wi-Fi this is just a
    // lower-quality mode; over the radio it is the difference between a call and
    // silently undeliverable frames.
    @Published var isMeshProfile = false
    func toggleMeshProfile() {
        isMeshProfile.toggle()
        camera.meshMode = isMeshProfile
    }

    func toggleRecording() {
        if isRecording {
            recorder.stop { [weak self] url in self?.lastRecordingPath = url?.path }
            isRecording = false
            recSink = nil
        } else {
            recorder.start()
            isRecording = recorder.recording
            // Append every decoded frame to the recording.
            recSink = decoder.$currentFrame.sink { [weak self] buf in
                guard let self = self, self.isRecording, let b = buf else { return }
                self.recorder.append(b)
            }
        }
    }

    // Local preview
    @Published var previewSession: AVCaptureSession?
    @Published var isScreenSharing = false

    // Chat + reactions
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?    // transient emoji overlay

    // Group / roster — participants heard from (by source IP) + self.
    @Published var roster: [String] = []
    @Published var isGroup = false
    private var lastSeen: [String: Date] = [:]
    // Per-source decoders for conference video (1-1 keeps the single `decoder`).
    var groupDecoders: [String: VideoDecoder] = [:]

    private func noteSender(_ ip: String) {
        lastSeen[ip] = Date()
        let active = lastSeen.filter { Date().timeIntervalSince($0.value) < 6 }.keys.sorted()
        let list = ([localIP] + active).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if list != roster { DispatchQueue.main.async { self.roster = list } }
    }

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

    // Toggle the outgoing video source between camera and screen. Both feed the
    // same encoder→transport path, so the peer just sees a new source.
    func toggleScreenShare() {
        if #available(macOS 12.3, *) {
            if isScreenSharing {
                (screen as? ScreenCapture)?.stop()
                isScreenSharing = false
            } else {
                let sc = (screen as? ScreenCapture) ?? ScreenCapture()
                screen = sc
                sc.onNALUnit = { [weak self] nal in
                    guard let self = self, self.isScreenSharing else { return }
                    self.transport.send(nal)
                    DispatchQueue.main.async { self.framesSent += 1 }
                }
                sc.start()
                isScreenSharing = true  // camera guard stops sending its NALs
            }
        } else {
            NSLog("TRINET: screen share needs macOS 12.3+")
        }
    }

    func startCall() {
        error = nil
        let typedTarget = directory.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = NicknamePolicy.normalize(typedTarget.isEmpty ? callee : typedTarget)
        callee = target
        let meshContact = directory.meshContact(named: target)
        let selected: CallRoute
        if route == .automatic {
            if isMeshAddress(target) {
                remoteIP = target
                selected = .mesh
            } else if let address = meshContact?.meshAddress {
                remoteIP = address
                selected = .mesh
            } else {
                selected = .internet
            }
        } else {
            selected = route
        }
        if selected == .mesh {
            if isMeshAddress(target) {
                remoteIP = target
            } else if let address = meshContact?.meshAddress {
                remoteIP = address
            } else {
                error = "@\(target) is not visible in the current mesh."
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
                self.error = error.localizedDescription
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

    func acceptIncomingInternetCall() {
        guard let incoming = incomingInternetCall else { return }
        incomingInternetCall = nil
        callee = incoming.caller
        activeRoute = .internet
        isStarting = true
        status = "Joining Internet call..."
        internet.update(identity: identity, configuration: internetConfiguration)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.internet.join(callID: incoming.callID,
                                             audio: incoming.audio,
                                             video: incoming.video)
                await MainActor.run {
                    self.isStarting = false
                    self.isInCall = true
                    self.status = "Connected via WebRTC"
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.activeRoute = nil
                    self.status = "Ready"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func declineIncomingInternetCall() {
        incomingInternetCall = nil
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
        directory.searchQuery = contact.nickname
        if let address = contact.meshAddress { remoteIP = address }
        route = .automatic
    }

    private func startInternetCall() {
        let target = callee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            error = "Enter a contact or device name."
            activeRoute = nil
            return
        }
        UserDefaults.standard.set(target, forKey: "internetCallee")
        internet.update(identity: identity, configuration: internetConfiguration)
        isStarting = true
        status = "Connecting to \(target)..."
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.internet.start(callee: target, audio: true, video: true)
                await MainActor.run {
                    self.isStarting = false
                    self.isInCall = true
                    self.status = "Connected via WebRTC"
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.isInCall = false
                    self.activeRoute = nil
                    self.status = "Ready"
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func startMeshCall() {
        guard let p = UInt16(port) else { NSLog("TRINET: invalid port"); return }
        NSLog("TRINET: startCall to \(remoteIP):\(p)")
        isStarting = true
        status = "Connecting to \(remoteIP)..."
        let attemptID = UUID()
        meshAttemptID = attemptID

        // Save IP to recent
        if !recentIPs.contains(remoteIP) {
            recentIPs.insert(remoteIP, at: 0)
            if recentIPs.count > 5 { recentIPs.removeLast() }
            UserDefaults.standard.set(recentIPs, forKey: "recentIPs")
        }

        // Camera → Encoder → Transport (suppressed while screen sharing)
        camera.onNALUnit = { [weak self] nal in
            guard let self = self, !self.cameraOff, !self.isScreenSharing else { return }
            self.transport.send(nal)
            DispatchQueue.main.async { self.framesSent += 1 }
        }

        // Peer asks for a fresh keyframe after loss → force an IDR now
        decoder.onKeyframeNeeded = { [weak self] in
            self?.transport.send(Data([0xFC, 0x00]))
        }

        // Transport → audio / PLI / chat / reaction / Decoder → Display
        // The node tells us what the link is doing. Nothing else does: PLI only
        // arrives once the far end's decoder is already broken.
        transport.onLinkFeedback = { [weak self] advice, util, drop, rate in
            guard let self = self else { return }
            self.linkAdvice = advice
            self.linkUtil = util
            self.linkDrop = drop
            self.linkRate = rate
            self.linkSeenAt = Date()
            let word = advice == CallManager.adviceBackOff ? "slow"
                     : (advice == CallManager.adviceClimb ? "climb" : "hold")
            self.linkInfo = "node \(util)% · loss \(drop)% · \(rate)/s · \(word)"
            if drop > 0 {
                NSLog("%@", "TRINET: node is dropping \(drop)% of our payloads (util \(util)% of \(rate)/s)")
            }
        }

        transport.onReceive = { [weak self] data in
            guard let self = self else { return }
            if data.count == 2, data[0] == 0xFC { // Picture Loss Indication
                self.camera.forceKeyframe()
                self.pliCount += 1   // adaptive bitrate: PLI = loss signal
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
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA { // chat text
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)) }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction emoji
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            self.decoder.feed(data)
            DispatchQueue.main.async {
                self.framesReceived = self.decoder.frameCount
                if self.framesReceived > 0 { self.status = "Connected" }
            }
        }

        // Per-source routing (roster in both modes; group video decode).
        transport.onReceiveFrom = { [weak self] data, ip in
            guard let self = self else { return }
            self.noteSender(ip)
            guard self.isGroup else { return }  // 1-1 already handled in onReceive
            // Control packets are broadcast to all — handle once
            if data.count == 2, data[0] == 0xFC { return }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD {
                self.audio.playPacket(data.subdata(in: 2..<data.count)); return
            }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA {
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)) }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC {
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            // Video → per-source decoder
            let dec = self.groupDecoders[ip] ?? {
                let d = VideoDecoder(); self.groupDecoders[ip] = d
                DispatchQueue.main.async { self.objectWillChange.send() }
                return d
            }()
            dec.feed(data)
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
        // Incoming PCM → recorder audio track while recording
        audio.onRxPCM = { [weak self] pcm in
            guard let self = self, self.isRecording else { return }
            self.recorder.appendAudio(pcm)
        }
        // Outgoing (local mic) PCM → buffered and mixed into the recording so it
        // captures both sides of the call.
        audio.onTxPCM = { [weak self] pcm in
            guard let self = self, self.isRecording else { return }
            self.recorder.pushLocalAudio(pcm)
        }
        // Off the main path: first touch of the mic can block ~60s on TCC
        // init, and audio must never hold up transport/video startup.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }

        // Start camera
        camera.start(device: cameras.first(where: { $0.uniqueID == selectedCameraID }))
        previewSession = camera.session

        // Group if the peer field lists several IPs (comma/space separated);
        // otherwise a 1-1 forward-secret call.
        let hosts = remoteIP.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if hosts.count > 1 {
            isGroup = true
            transport.connectGroup(peerHosts: hosts, peerPort: p, listenPort: p)
            NSLog("TRINET: group call — \(hosts.count) peers")
            meshAttemptID = nil
            isInCall = true
            isStarting = false
            status = "Connected to encrypted UDP group"
        } else {
            isGroup = false
            transport.onSecureSessionReady = { [weak self] in
                guard let self, self.meshAttemptID == attemptID else { return }
                self.meshAttemptID = nil
                self.isInCall = true
                self.isStarting = false
                self.status = "Connected via encrypted local UDP"
            }
            transport.connect(peerHost: remoteIP, peerPort: p, listenPort: p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.meshAttemptID == attemptID, self.isStarting else { return }
                self.error = "The local peer did not accept the call within 30 seconds."
                self.endCall()
            }
        }

        startABR()
        link.begin(peer: hosts.first ?? remoteIP)
    }

    func endCall() {
        if activeRoute == .internet {
            internet.disconnect()
            isInCall = false
            isStarting = false
            activeRoute = nil
            status = "Idle"
            return
        }
        if #available(macOS 12.3, *) { (screen as? ScreenCapture)?.stop() }
        isScreenSharing = false
        if isRecording { recorder.stop { [weak self] url in self?.lastRecordingPath = url?.path }; isRecording = false; recSink = nil }
        abrTimer?.invalidate(); abrTimer = nil
        link.end()
        camera.stop()
        audio.stop()
        transport.disconnect()
        meshAttemptID = nil
        isInCall = false
        isGroup = false
        roster = []
        groupDecoders = [:]
        lastSeen = [:]
        status = "Idle"
        framesSent = 0
        framesReceived = 0
        previewSession = nil
        activeRoute = nil
    }

    func saveInternetSettings() {
        internetConfiguration.save()
        UserDefaults.standard.set(route.rawValue, forKey: "callRoute")
        internet.update(identity: identity, configuration: internetConfiguration)
        directory.update(identity: identity, configuration: internetConfiguration)
        account.update(identity: identity, configuration: internetConfiguration)
        groupChat.update(identity: identity, configuration: internetConfiguration)
        internet.startIncomingPolling()
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
            self.error = error.localizedDescription
        }
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
}
