// ViewModel.swift — Direct Mac↔iPhone video call via BSD UDP
import SwiftUI
import AVFoundation
import AudioToolbox
import Combine
import CryptoKit
import UserNotifications

// A short "Trinity"-style chat blip: a quick bright two-note chirp (C6 -> G6), synthesized ONCE to a CAF and
// played via AudioServices — session-safe (never touches the call's AVAudioEngine, so it can't kill the mic).
final class ChatChime {
    private var soundID: SystemSoundID = 0
    init() { if let u = ChatChime.render() { AudioServicesCreateSystemSoundID(u as CFURL, &soundID) } }
    func play() { if soundID != 0 { AudioServicesPlaySystemSound(soundID) } }
    private static func render() -> URL? {
        let sr = 44100.0
        let notes: [(f: Double, dur: Double)] = [(1046.5, 0.055), (1567.98, 0.085)]  // C6 -> G6, quick
        let frames = AVAudioFrameCount(notes.reduce(0) { $0 + $1.dur } * sr)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let p = buf.floatChannelData![0]; var i = 0
        for n in notes {
            let cnt = Int(n.dur * sr)
            for k in 0..<cnt {
                let env = sin(Double.pi * Double(k) / Double(cnt))
                p[i] = Float(0.3 * env * sin(2 * Double.pi * n.f * Double(k) / sr)); i += 1
            }
        }
        guard let library = FileManager.default.urls(for: .libraryDirectory,
                                                      in: .userDomainMask).first else {
            return nil
        }
        let sounds = library.appendingPathComponent("Sounds", isDirectory: true)
        let url = sounds.appendingPathComponent("trinet-chat.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do {
            try FileManager.default.createDirectory(at: sounds,
                                                    withIntermediateDirectories: true)
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buf)
            return url
        }
        catch { NSLog("TRINET: chat chime render failed: \(error)"); return nil }
    }
}

// A synthesized standard telephone ringback tone (440Hz + 480Hz dual-tone, 2s tone + 3.5s gap), looped.
final class OutgoingRingbackSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var isPlaying = false

    init() {
        engine.attach(player)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        buffer = makeRingback(fmt)
    }

    private func makeRingback(_ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = 44100.0
        let toneDuration = 2.0
        let gapDuration = 3.5
        let total = toneDuration + gapDuration
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        var i = 0
        let toneFrames = Int(toneDuration * sr)
        for k in 0..<toneFrames {
            let t = Double(k) / sr
            let env = min(1.0, min(Double(k)/500.0, Double(toneFrames - k)/500.0))
            let sample = Float(0.22 * env * (sin(2 * Double.pi * 440.0 * t) + sin(2 * Double.pi * 480.0 * t)))
            p[i] = sample
            i += 1
        }
        while i < Int(frames) { p[i] = 0; i += 1 }
        return buf
    }

    func start() {
        guard !isPlaying, let buffer = buffer else { return }
        isPlaying = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        player.stop()
        engine.stop()
    }
}

struct DirectChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let sender: String
    let recipient: String
    let text: String
    let timestamp: Date
    var isRead: Bool
    var delivery: DirectChatDelivery? = nil
}

enum DirectChatDelivery: String, Codable {
    case sent
    case failed
    case received
}

enum DirectChatTimestampPolicy {
    static let maximumSkewMilliseconds: Int64 = 30_000

    static func isFresh(_ timestamp: Int64, now: Int64) -> Bool {
        guard timestamp != 0 else { return false }
        if timestamp > now {
            let (latest, overflow) = now.addingReportingOverflow(maximumSkewMilliseconds)
            return overflow || timestamp <= latest
        }
        let (earliest, overflow) = now.subtractingReportingOverflow(maximumSkewMilliseconds)
        return overflow || timestamp >= earliest
    }
}

struct ChatLine: Identifiable {
    let id = UUID()
    enum Who { case me, them }
    let who: Who
    let text: String
}

#if DEBUG
struct DebugPhysicalE2EPlan: Equatable {
    enum Role: String, Equatable {
        case caller
        case callee
    }

    enum ParseResult: Equatable {
        case disabled
        case invalid(String)
        case enabled(DebugPhysicalE2EPlan)
    }

    let runID: String
    let role: Role
    let peer: String
    let media: InternetCallMedia
    let autoAccept: Bool
    let chatToken: String?
    let timeout: TimeInterval

    var mediaName: String { media.video ? "video" : "audio" }

    static func parse(arguments: [String]) -> ParseResult {
        let valueArguments: Set<String> = [
            "--trinet-e2e-run",
            "--trinet-e2e-role",
            "--trinet-e2e-peer",
            "--trinet-e2e-media",
            "--trinet-e2e-chat",
            "--trinet-e2e-timeout"
        ]
        var values: [String: String] = [:]
        var autoAccept = false
        var sawE2EArgument = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--trinet-e2e-auto-accept" {
                guard !autoAccept else { return .invalid("duplicate_auto_accept") }
                autoAccept = true
                sawE2EArgument = true
                index += 1
                continue
            }
            if valueArguments.contains(argument) {
                sawE2EArgument = true
                guard values[argument] == nil else {
                    return .invalid("duplicate_\(argument.dropFirst(2))")
                }
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      !arguments[valueIndex].hasPrefix("--") else {
                    return .invalid("missing_value_\(argument.dropFirst(2))")
                }
                values[argument] = arguments[valueIndex]
                index += 2
                continue
            }
            if argument.hasPrefix("--trinet-e2e-") {
                return .invalid("unknown_argument")
            }
            index += 1
        }

        guard sawE2EArgument else { return .disabled }
        guard let runID = values["--trinet-e2e-run"], isSafeToken(runID, maximum: 64) else {
            return .invalid("invalid_run")
        }
        guard let roleText = values["--trinet-e2e-role"],
              let role = Role(rawValue: roleText) else {
            return .invalid("invalid_role")
        }
        guard let rawPeer = values["--trinet-e2e-peer"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPeer.isEmpty,
              rawPeer.count <= 80,
              !rawPeer.contains("\n"),
              !rawPeer.contains("\r") else {
            return .invalid("invalid_peer")
        }
        let media: InternetCallMedia
        switch values["--trinet-e2e-media"] {
        case "audio":
            media = .audioOnly
        case "video":
            media = .audioVideo
        default:
            return .invalid("invalid_media")
        }
        if role == .callee, !autoAccept {
            return .invalid("callee_requires_auto_accept")
        }
        if role == .caller, autoAccept {
            return .invalid("caller_cannot_auto_accept")
        }
        let chatToken: String?
        if let rawChatToken = values["--trinet-e2e-chat"] {
            guard isSafeToken(rawChatToken, maximum: 160) else {
                return .invalid("invalid_chat")
            }
            chatToken = rawChatToken
        } else {
            chatToken = nil
        }
        let timeout: TimeInterval
        if let rawTimeout = values["--trinet-e2e-timeout"] {
            guard let parsed = TimeInterval(rawTimeout), (10 ... 90).contains(parsed) else {
                return .invalid("invalid_timeout")
            }
            timeout = parsed
        } else {
            timeout = 35
        }
        return .enabled(DebugPhysicalE2EPlan(runID: runID,
                                             role: role,
                                             peer: rawPeer,
                                             media: media,
                                             autoAccept: autoAccept,
                                             chatToken: chatToken,
                                             timeout: timeout))
    }

    func matchesPeer(nickname: String, displayName: String) -> Bool {
        let expected = NicknamePolicy.normalize(peer)
        return NicknamePolicy.normalize(nickname) == expected ||
            NicknamePolicy.normalize(displayName) == expected
    }

    func matchesChatSender(_ sender: String) -> Bool {
        let expected = NicknamePolicy.normalize(peer)
        let candidate = NicknamePolicy.normalize(sender)
        return candidate == expected || candidate.hasPrefix(expected + "_")
    }

    private static func isSafeToken(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximum else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48 ... 57).contains(value) ||
                (65 ... 90).contains(value) ||
                (97 ... 122).contains(value) ||
                value == 45 || value == 46 || value == 95
        }
    }
}

enum DebugPhysicalE2EResultPolicy {
    static func passes(plan: DebugPhysicalE2EPlan,
                       isLive: Bool,
                       isMeshRoute: Bool,
                       activeMedia: InternetCallMedia,
                       signedSignalComplete: Bool,
                       audioPacketsReceived: Int,
                       framesSent: Int,
                       framesReceived: Int,
                       cameraOff: Bool,
                       chatReceived: Bool) -> Bool {
        guard isLive,
              isMeshRoute,
              activeMedia == plan.media,
              signedSignalComplete,
              audioPacketsReceived >= 3 else { return false }
        if plan.role == .callee, plan.chatToken != nil, !chatReceived {
            return false
        }
        if plan.media.video {
            return !cameraOff && framesSent > 0 && framesReceived > 0
        }
        return cameraOff && framesSent == 0 && framesReceived == 0
    }
}
#endif

// Wraps a saved recording URL so it can drive a SwiftUI share sheet.
struct RecFile: Identifiable {
    let id = UUID()
    let url: URL
}

class StreamViewModel: ObservableObject {
    @Published var phase: CallPhase = .idle {
        didSet {
            if phase == .connecting {
                ringbackSynth.start()
            } else {
                ringbackSynth.stop()
            }
        }
    }
    @Published var remoteIP: String = UserDefaults.standard.string(forKey: "remoteIP") ?? "192.168.1.105"
    @Published var callee: String = UserDefaults.standard.string(forKey: "internetCallee") ?? "ssd26"
    @Published var route: CallRoute = .automatic
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
    @Published var cameraOff = false { didSet { camera.blackout = cameraOff } }
    @Published private(set) var activeMeshMedia: InternetCallMedia = .audioVideo
    @Published var unreadChat = 0
    var chatOpen = false { didSet { if chatOpen { unreadChat = 0 } } }
    private let chatChime = ChatChime()
    private let ringbackSynth = OutgoingRingbackSynth()
    private var seenInviteMACs: [Data: Date] = [:]
    @Published var recentIPs: [String] = []
    @Published var txLevel: Float = 0
    @Published var rxLevel: Float = 0
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?
    @Published var isBlurred = false
    @Published var rtiSlewAngle: Int = 0
    @Published var rtiSlewDirection: String = "none"
    @Published var rtiSlewActive: Bool = false

    // Profile & Avatar state
    @Published var avatarData: Data? = UserDefaults.standard.data(forKey: "userAvatarData")
    @Published var avatarColorHex: String = UserDefaults.standard.string(forKey: "userAvatarColorHex") ?? "#4CD972"

    func saveAvatar(data: Data?, colorHex: String) {
        self.avatarData = data
        self.avatarColorHex = colorHex
        if let d = data {
            UserDefaults.standard.set(d, forKey: "userAvatarData")
        } else {
            UserDefaults.standard.removeObject(forKey: "userAvatarData")
        }
        UserDefaults.standard.set(colorHex, forKey: "userAvatarColorHex")
    }

    // Per-contact direct chat storage
    @Published var directChats: [String: [DirectChatMessage]] = StreamViewModel.loadDirectChats()
    @Published var activeChatContact: String? = nil

    private static let directChatsKey = "trinetDirectChats"
    private static func loadDirectChats() -> [String: [DirectChatMessage]] {
        guard let d = UserDefaults.standard.data(forKey: directChatsKey),
              let dict = try? JSONDecoder().decode([String: [DirectChatMessage]].self, from: d) else { return [:] }
        return dict
    }
    private static func saveDirectChats(_ chats: [String: [DirectChatMessage]]) {
        if let d = try? JSONEncoder().encode(chats) {
            UserDefaults.standard.set(d, forKey: directChatsKey)
        }
    }

    func openChat(with contact: String) {
        let norm = NicknamePolicy.normalize(contact)
        let key = norm.isEmpty ? contact : norm
        activeChatContact = key
        markChatAsRead(key)
    }

    func markChatAsRead(_ contact: String) {
        guard var list = directChats[contact] else { return }
        for i in 0..<list.count {
            list[i].isRead = true
        }
        directChats[contact] = list
        StreamViewModel.saveDirectChats(directChats)
    }

    func unreadCount(for contact: String) -> Int {
        let key = NicknamePolicy.normalize(contact)
        let target = key.isEmpty ? contact : key
        let list = directChats[target] ?? []
        return list.filter { !$0.isRead && $0.sender != (directory.currentNickname ?? identity.displayName) }.count
    }

    // AI Speech Transcription Agent
    @Published var aiTranscriptionActive: Bool = false
    @Published var liveTranscripts: [String] = []

    static let chatMagic: [UInt8] = [0xFD, 0x22]

    func toggleAITranscription() {
        aiTranscriptionActive.toggle()
        if aiTranscriptionActive {
            appendAITranscript("🤖 AI Agent: Live speech transcription started.")
        }
    }

    func appendAITranscript(_ line: String) {
        liveTranscripts.append(line)
        if liveTranscripts.count > 10 {
            liveTranscripts.removeFirst()
        }
    }

    func startAudioCall(to target: String) {
        callee = target
        cameraOff = true
        initiateCallToContact(target)
    }

    func startVideoCall(to target: String) {
        callee = target
        cameraOff = false
        initiateCallToContact(target)
    }

    func initiateCallToContact(_ target: String) {
        let norm = NicknamePolicy.normalize(target)
        if let peer = discovery.peers.first(where: { NicknamePolicy.normalize($0.name) == norm || $0.name == target }) {
            discovery.resolveIP(peer) { [weak self] ip in
                guard let self = self, let ip = ip, !ip.isEmpty else {
                    self?.startCall()
                    return
                }
                self.remoteIP = ip
                self.startCall()
            }
        } else {
            startCall()
        }
    }

    func sendDirectText(to contact: String, text: String) {
        let trimmed = MeshTextEnvelope.clamp(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return }
        let key = NicknamePolicy.normalize(contact).isEmpty ? contact : NicknamePolicy.normalize(contact)
        let senderName = directory.currentNickname ?? identity.displayName
        var msg = DirectChatMessage(sender: senderName,
                                    recipient: key,
                                    text: trimmed,
                                    timestamp: Date(),
                                    isRead: true,
                                    delivery: .failed)
        guard let signedContact = directory.meshContact(named: key),
              signedContact.online,
              signedContact.source == .mesh,
              signedContact.meshAddress != nil,
              signedContact.meshPort == MeshCallSignaling.port,
              signedContact.signingPublicKey != nil,
              signedContact.textEncryptionPublicKey != nil else {
            if directChats[key] == nil { directChats[key] = [] }
            directChats[key]?.append(msg)
            StreamViewModel.saveDirectChats(directChats)
            callError = "@\(key) has no live signed encrypted-chat route. Message was not sent."
            return
        }
        do {
            _ = try directory.sendMeshText(trimmed, to: signedContact)
            msg.delivery = .sent
        } catch {
            callError = "Encrypted message to @\(key) was not sent: \(error.localizedDescription)"
        }
        if directChats[key] == nil { directChats[key] = [] }
        directChats[key]?.append(msg)
        StreamViewModel.saveDirectChats(directChats)

        // Play sound chime + vibration locally
        chatChime.play()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

    }

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

    // Group call: enter several IPs (comma/space separated) -> full-mesh conference. Each remote
    // sender decodes into its OWN tile (per-source decoder), so 2 iPhones + a Mac = a 3-way group.
    @Published var isGroup = false
    @Published var roster: [String] = []           // remote source IPs currently heard
    @Published private(set) var groupTick = 0      // bumps when any group decoder gets a new frame (redraw)
    var groupDecoders: [String: H264Decoder] = [:]

    // Local-network presence: pick people by NAME instead of typing IPs (Bonjour). Resolves a tapped
    // peer to an IP for the transport. Rooms + in-call status live in the TXT record.
    let discovery = PeerDiscovery()
    @Published var selectedUIDs: Set<String> = []
    func toggleSelect(_ uid: String) {
        if selectedUIDs.contains(uid) { selectedUIDs.remove(uid) } else { selectedUIDs.insert(uid) }
        // UX: ticking peers auto-fills the peer field with their resolved IPs — no typing "ip1, ip2" by hand.
        let sel = discovery.peers.filter { selectedUIDs.contains($0.uid) }
        guard !sel.isEmpty else { return }
        var ips: [String] = []
        let g = DispatchGroup()
        for p in sel { g.enter(); discovery.resolveIP(p) { ip in if let ip = ip, !ip.isEmpty { ips.append(ip) }; g.leave() } }
        g.notify(queue: .main) { [weak self] in
            guard let self = self, !ips.isEmpty else { return }
            self.remoteIP = ips.sorted().joined(separator: ", ")
        }
    }
    func callPeer(_ peer: PeerDiscovery.Peer) {
        discovery.resolveIP(peer) { [weak self] ip in
            guard let self = self, let ip = ip, !ip.isEmpty else { return }
            // A roster entry can be another app on THIS device/host (e.g. a Simulator) — it resolves to our
            // own IP and "calling" it is a self-call that floods undecryptable noise. Refuse loudly.
            if ip == self.myIP {
                NSLog("TRINET: refusing self-call — '\(peer.name)' resolved to our own IP \(ip)")
                return
            }
            self.remoteIP = ip; self.startCall()
        }
    }
    func callEveryone() { selectedUIDs = Set(discovery.peers.map { $0.uid }); startGroupFromSelection() }
    func startGroupFromSelection() {
        let sel = discovery.peers.filter { selectedUIDs.contains($0.uid) }
        guard !sel.isEmpty else { return }
        var ips: [String] = []
        let g = DispatchGroup()
        for p in sel { g.enter(); discovery.resolveIP(p) { ip in if let ip = ip, !ip.isEmpty { ips.append(ip) }; g.leave() } }
        g.notify(queue: .main) { [weak self] in
            guard let self = self, !ips.isEmpty else { return }
            self.remoteIP = ips.joined(separator: ","); self.selectedUIDs = []; self.startCall()
        }
    }

    private var bytesSent = 0
    private var bytesRecv = 0
    private var timer: Timer?
    private var callKitUUID: UUID?
    private var meshAttemptID: UUID?
    private var meshSessionID: UUID?
    private var internetAttemptID: UUID?
    private var internetCallTask: Task<Void, Never>?
    private var internetParticipantObserver: AnyCancellable?
    private var groupUnreadObserver: AnyCancellable?
    private var internetAnswerTimer: Timer?
    private var outgoingInternetAwaitingRemote = false
    private var pendingInternetVideo = false
    private var appBecameActiveObserver: AnyCancellable?
    private var outboundMeshControl: MeshCallControlExpectation?
    private var outboundMeshControlPort: UInt16?
    private var outboundMeshAccepted = false
    private var acceptedIncomingMeshCall: IncomingMeshCall?
    #if DEBUG
    private var debugE2EPlan: DebugPhysicalE2EPlan?
    private var debugE2EPhaseObserver: AnyCancellable?
    private var debugE2EDeadline = Date.distantPast
    private var debugE2EStage = "disabled"
    private var debugE2EAudioPacketsReceived = 0
    private var debugE2EChatReceived = false
    private var debugE2EReady = false
    private var debugE2EResultEmitted = false
    private var debugE2EEvaluationActive = false
    private var debugE2ELastWaitLog = Date.distantPast
    #endif

    init() {
        let loadedIdentity: DeviceIdentity
        do {
            loadedIdentity = try DeviceIdentityStore.shared.loadOrCreate(defaultName: PeerDiscovery.myName)
        } catch {
            loadedIdentity = DeviceIdentity(userID: UUID().uuidString.lowercased(),
                                            deviceID: UUID().uuidString.lowercased(),
                                            displayName: PeerDiscovery.myName,
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
            guard let self else { return }
            self.chat.append(ChatLine(who: .them, text: text))
            self.chatChime.play()
            if !self.chatOpen { self.unreadChat += 1 }
        }
        internet.onReaction = { [weak self] value in
            self?.showReaction(value)
        }
        internetParticipantObserver = internet.$hasRemoteParticipant
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard connected else { return }
                self?.completeOutgoingInternetCallIfReady()
            }
        groupChat.onNewUnread = { [weak self] newUnread in
            guard let self, newUnread > 0 else { return }
            self.chatChime.play()
        }
        groupUnreadObserver = groupChat.$totalUnreadCount
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { count in
                if #available(iOS 16.0, *) {
                    UNUserNotificationCenter.current().setBadgeCount(max(0, count))
                } else {
                    UIApplication.shared.applicationIconBadgeNumber = max(0, count)
                }
            }
        internet.onRemoteEnded = { [weak self] in
            guard let self,
                  InternetCallLifecyclePolicy.shouldEndAfterRemoteDeparture(
                    activeRoute: self.activeRoute
                  ) else { return }
            self.stopCall()
            self.callError = "The peer ended the call."
        }
        internet.onIncomingCall = { [weak self] incoming in
            guard let self else { return false }
            let caller = NicknamePolicy.normalize(incoming.caller)
            let signedMatch = self.incomingMeshCall.map {
                NicknamePolicy.normalize($0.invite.nickname) == caller
            } ?? false
            let legacyMatch = self.incomingCall.map {
                NicknamePolicy.normalize($0.name) == caller
            } ?? false
            if signedMatch || legacyMatch {
                self.incomingMeshCall = nil
                self.incomingTimer?.invalidate()
                self.incomingCall = nil
            }
            guard self.phase == .idle else { return false }
            CallKitCoordinator.shared.reportIncoming(callID: incoming.callID,
                                                     caller: incoming.caller,
                                                     audio: incoming.audio,
                                                     video: incoming.video) { [weak self] succeeded in
                guard IncomingCallDeliveryPolicy.shouldRetryAfterPresentation(
                    succeeded: succeeded
                ) else { return }
                self?.internet.allowIncomingRetry(callID: incoming.callID)
            }
            return true
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
        if let migratedNickname = NicknameMigrationPolicy.candidate(
            currentNickname: loadedIdentity.nickname,
            displayName: loadedIdentity.displayName,
            deviceID: loadedIdentity.deviceID
        ) {
            directory.proposedNickname = migratedNickname
            directory.claimProposedNickname()
        }
        account.onIdentityChanged = { [weak self] updatedIdentity in
            guard let self else { return }
            self.identity = updatedIdentity
            self.internet.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.directory.update(identity: updatedIdentity, configuration: self.internetConfiguration)
            self.groupChat.update(identity: updatedIdentity, configuration: self.internetConfiguration)
        }
        directory.onIncomingMeshInvite = { [weak self] invite, address in
            guard let self,
                  self.phase == .idle,
                  self.directory.verifiedMeshInviteSender(invite,
                                                          sourceAddress: address) != nil else {
                NSLog("TRINET CALL: rejected signed invite without a matching live signed contact")
                return
            }
            let incoming = IncomingMeshCall(invite: invite, sourceAddress: address)
            self.incomingMeshCall = incoming
            #if DEBUG
            self.debugE2EHandleVerifiedInvite(incoming)
            #endif
            let delay = max(0, Double(incoming.expiresAt) - Date().timeIntervalSince1970) + 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.incomingMeshCall?.invite.callID == invite.callID,
                      !incoming.isFresh() else { return }
                self.incomingMeshCall = nil
            }
        }
        directory.onMeshCallControl = { [weak self] control, address in
            self?.handleMeshCallControl(control, sourceAddress: address)
        }
        directory.onMeshText = { [weak self] message, address in
            guard let self,
                  message.recipientDeviceID == self.identity.deviceID,
                  let sender = self.directory.verifiedMeshTextSender(message,
                                                                    sourceAddress: address) else {
                NSLog("TRINET TEXT: rejected encrypted message without a matching live signed contact")
                return
            }
            let senderKey = NicknamePolicy.normalize(sender.nickname)
            let isCurrentChat = self.activeChatContact == senderKey
            let incoming = DirectChatMessage(id: UUID(uuidString: message.id) ?? UUID(),
                                             sender: senderKey,
                                             recipient: self.directory.currentNickname ?? self.identity.displayName,
                                             text: message.text,
                                             timestamp: Date(timeIntervalSince1970:
                                                Double(message.timestamp) / 1_000),
                                             isRead: isCurrentChat,
                                             delivery: .received)
            if self.directChats[senderKey]?.contains(where: { $0.id == incoming.id }) == true { return }
            if self.directChats[senderKey] == nil { self.directChats[senderKey] = [] }
            self.directChats[senderKey]?.append(incoming)
            StreamViewModel.saveDirectChats(self.directChats)
            if !isCurrentChat { self.unreadChat += 1 }
            self.chatChime.play()
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            #if DEBUG
            self.debugE2EHandleDirectChat(sender: senderKey, text: message.text)
            #endif
        }
        internet.startIncomingPolling(voipToken: UserDefaults.standard.string(forKey: "voipPushToken"))
        appBecameActiveObserver = NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.enablePendingInternetVideoIfPossible()
        }
        account.sync()
        groupChat.startPolling()
        discovery.start()   // advertise + browse from launch
        startIdleListener() // listen on :7000 for incoming mesh calls while idle
        autoConnectViaRendezvousIfConfigured()   // NAT-traversal path (no-op unless configured)
    }

    #if DEBUG
    func configureDebugE2E(arguments: [String]) {
        switch DebugPhysicalE2EPlan.parse(arguments: arguments) {
        case .disabled:
            return
        case .invalid(let reason):
            NSLog("TRINET_E2E event=FAIL reason=invalid_args detail=\(reason)")
        case .enabled(let plan):
            guard debugE2EPlan == nil else { return }
            debugE2EPlan = plan
            debugE2EDeadline = Date().addingTimeInterval(plan.timeout)
            debugE2EStage = "boot"
            debugE2EAudioPacketsReceived = 0
            debugE2EChatReceived = false
            debugE2EReady = false
            debugE2EResultEmitted = false
            debugE2EEvaluationActive = false
            debugE2ELastWaitLog = .distantPast
            debugE2ELog("BOOT",
                        "peer=\(NicknamePolicy.normalize(plan.peer)) media=\(plan.mediaName) timeout=\(Int(plan.timeout))")
            debugE2EPhaseObserver = $phase
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] phase in
                    self?.debugE2EPhaseChanged(phase)
                }
            DispatchQueue.main.asyncAfter(deadline: .now() + plan.timeout) { [weak self] in
                guard let self, !self.debugE2EResultEmitted else { return }
                self.debugE2EFail("timeout")
            }
            debugE2EPollForReadiness()
        }
    }

    private func debugE2EPollForReadiness() {
        guard let plan = debugE2EPlan,
              !debugE2EResultEmitted,
              !debugE2EReady else { return }
        guard Date() < debugE2EDeadline else {
            debugE2EFail("readiness_timeout")
            return
        }
        guard phase == .idle else {
            debugE2EWait("phase_not_idle")
            debugE2ERetryReadiness()
            return
        }
        guard let ownNickname = directory.currentNickname,
              !ownNickname.isEmpty else {
            debugE2EWait("nickname_missing")
            debugE2ERetryReadiness()
            return
        }

        if plan.role == .callee {
            debugE2EReady = true
            debugE2EStage = "ready"
            debugE2ELog("READY",
                        "nickname=\(NicknamePolicy.normalize(ownNickname)) device=\(identity.deviceID.prefix(8))")
            return
        }

        guard let contact = directory.meshContact(named: plan.peer),
              contact.online,
              let address = contact.meshAddress,
              !address.isEmpty else {
            let candidates = directory.meshPeers
                .filter { $0.online && $0.source == .mesh }
                .map { NicknamePolicy.normalize($0.nickname) }
                .sorted()
                .joined(separator: ",")
            debugE2EWait("peer_missing candidates=\(candidates.isEmpty ? "none" : candidates)")
            debugE2ERetryReadiness()
            return
        }
        debugE2EReady = true
        debugE2EStage = "peer_ready"
        callee = plan.peer
        directory.searchQuery = plan.peer
        route = .mesh
        remoteIP = address
        cameraOff = !plan.media.video
        debugE2ELog("PEER_READY",
                    "peer_device=\(contact.deviceID.prefix(8)) address=\(address) media=\(plan.mediaName)")

        if let chatToken = plan.chatToken {
            sendDirectText(to: plan.peer, text: chatToken)
            let delivery = directChats[NicknamePolicy.normalize(plan.peer)]?.last?.delivery
            guard delivery == .sent else {
                debugE2EFail("chat_send_failed")
                return
            }
            debugE2ELog("CHAT_SENT", "token=\(chatToken)")
            // The receiver rejects otherwise-valid encrypted text until its
            // live signed TXT contact is present. Retry the same user-visible
            // message with fresh cryptographic nonces while discovery settles;
            // the receiver deduplicates by message ID.
            for delay in [0.75, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self,
                          !self.debugE2EResultEmitted,
                          self.phase == .idle else { return }
                    self.sendDirectText(to: plan.peer, text: chatToken)
                    self.debugE2ELog("CHAT_RETRY", "token=\(chatToken)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.25) { [weak self] in
                self?.debugE2EStartCaller()
            }
        } else {
            debugE2EStartCaller()
        }
    }

    private func debugE2ERetryReadiness() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.debugE2EPollForReadiness()
        }
    }

    private func debugE2EWait(_ reason: String) {
        let now = Date()
        guard now.timeIntervalSince(debugE2ELastWaitLog) >= 2 else { return }
        debugE2ELastWaitLog = now
        debugE2ELog("WAIT", reason)
    }

    private func debugE2EStartCaller() {
        guard let plan = debugE2EPlan,
              plan.role == .caller,
              !debugE2EResultEmitted else { return }
        guard Date() < debugE2EDeadline else {
            debugE2EFail("start_timeout")
            return
        }
        guard phase == .idle else {
            debugE2EFail("caller_not_idle")
            return
        }
        debugE2EAudioPacketsReceived = 0
        debugE2EStage = "call_start"
        debugE2ELog("CALL_START",
                    "peer=\(NicknamePolicy.normalize(plan.peer)) address=\(remoteIP) media=\(plan.mediaName)")
        startCall()
        guard activeRoute == .mesh, phase != .idle else {
            debugE2EFail("call_not_started")
            return
        }
    }

    private func debugE2EHandleVerifiedInvite(_ incoming: IncomingMeshCall) {
        guard let plan = debugE2EPlan,
              plan.role == .callee,
              plan.autoAccept,
              !debugE2EResultEmitted else { return }
        guard plan.matchesPeer(nickname: incoming.invite.nickname,
                               displayName: incoming.invite.displayName),
              incoming.invite.media == plan.media else {
            debugE2ELog("INVITE_IGNORED",
                        "call_id=\(incoming.invite.callID) peer=\(NicknamePolicy.normalize(incoming.invite.nickname)) media=\(incoming.invite.media.video ? "video" : "audio")")
            return
        }
        debugE2EStage = "invite_verified"
        debugE2EAudioPacketsReceived = 0
        debugE2ELog("INVITE_VERIFIED",
                    "call_id=\(incoming.invite.callID) address=\(incoming.sourceAddress) media=\(plan.mediaName)")

        // The normal UI creates enough delay for the caller to install its
        // control expectation and bind the media socket. Preserve that ordering
        // when auto-answering from a launch argument.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, !self.debugE2EResultEmitted else { return }
            guard self.phase == .idle,
                  self.incomingMeshCall?.invite.callID == incoming.invite.callID,
                  incoming.isFresh() else {
                self.debugE2EFail("invite_unavailable")
                return
            }
            self.acceptIncomingMeshCall()
            guard self.activeRoute == .mesh,
                  self.acceptedIncomingMeshCall?.invite.callID == incoming.invite.callID,
                  self.phase != .idle else {
                self.debugE2EFail("accept_failed")
                return
            }
            self.debugE2EStage = "accept_sent"
            self.debugE2ELog("ACCEPT_SENT", "call_id=\(incoming.invite.callID)")
        }
    }

    private func debugE2EHandleVerifiedAcceptance(_ control: MeshCallControl) {
        guard let plan = debugE2EPlan,
              plan.role == .caller,
              !debugE2EResultEmitted else { return }
        debugE2EStage = "accept_verified"
        debugE2ELog("ACCEPT_VERIFIED", "call_id=\(control.callID)")
        if phase == .live {
            debugE2EStartEvaluation()
        }
    }

    private func debugE2EHandleDirectChat(sender: String, text: String) {
        guard let plan = debugE2EPlan,
              plan.role == .callee,
              let chatToken = plan.chatToken,
              text == chatToken,
              plan.matchesChatSender(sender),
              !debugE2EChatReceived,
              !debugE2EResultEmitted else { return }
        debugE2EChatReceived = true
        debugE2ELog("CHAT_RECEIVED", "token=\(chatToken)")
    }

    private func debugE2EPhaseChanged(_ phase: CallPhase) {
        guard debugE2EPlan != nil, !debugE2EResultEmitted else { return }
        debugE2ELog("PHASE", "value=\(debugE2EPhaseName(phase))")
        guard phase == .live else { return }
        debugE2EStage = "live"
        debugE2ELog("LIVE", debugE2EDiagnostics())
        debugE2EStartEvaluation()
    }

    private func debugE2EStartEvaluation() {
        guard !debugE2EEvaluationActive, !debugE2EResultEmitted else { return }
        debugE2EEvaluationActive = true
        debugE2EEvaluate()
    }

    private func debugE2EEvaluate() {
        guard let plan = debugE2EPlan, !debugE2EResultEmitted else {
            debugE2EEvaluationActive = false
            return
        }
        let signedSignalComplete = plan.role == .caller
            ? outboundMeshAccepted
            : acceptedIncomingMeshCall != nil
        if DebugPhysicalE2EResultPolicy.passes(
            plan: plan,
            isLive: phase == .live,
            isMeshRoute: activeRoute == .mesh,
            activeMedia: activeMeshMedia,
            signedSignalComplete: signedSignalComplete,
            audioPacketsReceived: debugE2EAudioPacketsReceived,
            framesSent: framesSent,
            framesReceived: framesReceived,
            cameraOff: cameraOff,
            chatReceived: debugE2EChatReceived
        ) {
            debugE2EResultEmitted = true
            debugE2EEvaluationActive = false
            debugE2EStage = "passed"
            debugE2ELog("PASS", debugE2EDiagnostics())
            return
        }
        guard Date() < debugE2EDeadline else {
            debugE2EFail("media_timeout")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.debugE2EEvaluate()
        }
    }

    private func debugE2EFail(_ reason: String) {
        guard debugE2EPlan != nil, !debugE2EResultEmitted else { return }
        debugE2EResultEmitted = true
        debugE2EEvaluationActive = false
        debugE2ELog("FAIL", "reason=\(reason) \(debugE2EDiagnostics())")
    }

    private func debugE2ELog(_ event: String, _ details: String = "") {
        guard let plan = debugE2EPlan else { return }
        let suffix = details.isEmpty ? "" : " \(details)"
        NSLog("TRINET_E2E run=\(plan.runID) role=\(plan.role.rawValue) event=\(event)\(suffix)")
    }

    private func debugE2EDiagnostics() -> String {
        guard let plan = debugE2EPlan else { return "stage=disabled" }
        let activeMedia = activeMeshMedia.video ? "video" : "audio"
        let routeName = activeRoute.map { route in
            switch route {
            case .automatic: return "automatic"
            case .mesh: return "mesh"
            case .internet: return "internet"
            }
        } ?? "none"
        let signedSignalComplete = plan.role == .caller
            ? outboundMeshAccepted
            : acceptedIncomingMeshCall != nil
        let error = debugE2ESafeLogValue(callError ?? "none")
        return "stage=\(debugE2EStage) phase=\(debugE2EPhaseName(phase)) route=\(routeName) " +
            "media=\(activeMedia) signed_signal=\(signedSignalComplete ? 1 : 0) " +
            "audio_rx=\(debugE2EAudioPacketsReceived) frames_tx=\(framesSent) " +
            "frames_rx=\(framesReceived) camera_off=\(cameraOff ? 1 : 0) " +
            "chat_rx=\(debugE2EChatReceived ? 1 : 0) error=\(error)"
    }

    private func debugE2EPhaseName(_ phase: CallPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .live: return "live"
        }
    }

    private func debugE2ESafeLogValue(_ value: String) -> String {
        String(value
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .prefix(120))
    }
    #endif

    func saveInternetSettings() {
        internetConfiguration.save()
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

    // NAT-TRAVERSAL PATH — mirrors desktop CallManager.autoConnectViaRendezvousIfConfigured().
    // Discover the peer through a blind rendezvous knowing only a shared room passphrase, then
    // place the call on the pair a connectivity check punched, ON the socket that punched it.
    // Additive and OFF unless configured, so the working same-subnet call is untouched:
    //   TRINET_RENDEZVOUS=<host>:<port>  TRINET_ROOM=<passphrase>  TRINET_MEDIA_PORT=<port>
    //   TRINET_TIEBREAK=<u64>            (optional ICE role tiebreaker)
    private var punchedFd: Int32?
    private var rzPeer: (host: String, port: UInt16)?
    private var rzLocalPort: UInt16?
    private func autoConnectViaRendezvousIfConfigured() {
        let env = ProcessInfo.processInfo.environment
        guard let rz = env["TRINET_RENDEZVOUS"], !rz.isEmpty,
              let configuredRoom = env["TRINET_ROOM"], !configuredRoom.isEmpty,
              let mediaPort = env["TRINET_MEDIA_PORT"].flatMap({ UInt16($0) }) else { return }
        let room = configuredRoom.uppercased()
        discovery.setRoom(room)
        let parts = rz.split(separator: ":")
        guard parts.count == 2, let rzPort = UInt16(parts[1]) else { NSLog("TRINET: bad TRINET_RENDEZVOUS"); return }
        let rzHost = String(parts[0])
        let tiebreak = env["TRINET_TIEBREAK"].flatMap { UInt64($0) } ?? UInt64.random(in: 0 ... UInt64.max)
        NSLog("%@", "TRINET RZ: discovering peer via \(rzHost):\(rzPort) room=\(room) mediaPort=\(mediaPort)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var cands = [Ice.Candidate(ip: "127.0.0.1", port: mediaPort, kind: .host)]
            for ip in Stun.hostCandidates() { cands.append(Ice.Candidate(ip: ip, port: mediaPort, kind: .host)) }
            if let srflx = Stun.gatherServerReflexive(host: "stun.l.google.com", port: 19302) {
                cands.append(Ice.Candidate(ip: srflx.ip, port: srflx.port, kind: .srflx))
            }
            let rh = Rendezvous.roomHash(room)
            let offer = CandidateOffer.make(candidates: cands, tiebreaker: tiebreak, room: room, ttlMs: 60_000)
            for _ in 0..<3 { Rendezvous.publish(roomHash: rh, selfTag: tiebreak, offer: offer, host: rzHost, port: rzPort) }
            guard let peerOffer = Rendezvous.fetch(roomHash: rh, selfTag: tiebreak, host: rzHost, port: rzPort, timeoutMs: 8000),
                  let opened = CandidateOffer.open(peerOffer, room: room) else {
                NSLog("%@", "TRINET RZ: no peer offer within 8s (relay down, or peer not in room yet)"); return
            }
            guard let connected = Ice.connect(localPort: mediaPort, remote: opened.candidates,
                                              timeoutMs: 4000, keepSocket: true) else {
                NSLog("%@", "TRINET RZ: connectivity check failed — no reachable candidate among \(opened.candidates.count)"); return
            }
            NSLog("%@", "TRINET RZ: connected pair -> \(connected.remote.ip):\(connected.remote.port) (local \(connected.localPort))")
            DispatchQueue.main.async {
                guard self.phase == .idle else { return }
                self.remoteIP = connected.remote.ip
                self.rzPeer = (connected.remote.ip, connected.remote.port)
                self.rzLocalPort = connected.localPort
                self.punchedFd = connected.fd
                self.activeRoute = .mesh
                self.startMeshCall()
            }
        }
    }

    // MARK: - Incoming call ("take the call")
    // While idle we hold a light listener on :7000; a caller sends a tiny plaintext INVITE there and we
    // pop the full-screen ringing sheet. Torn down when a call starts (the encrypted transport owns :7000),
    // restarted when it ends.
    struct IncomingCall: Equatable { let name: String; let ip: String; let participants: [String] }
    @Published var incomingCall: IncomingCall?
    // Missed calls: an incoming that timed out unanswered (NOT a decline — that was a choice). Newest first.
    // Persisted across restarts so you don't lose "who called while I was away".
    struct MissedCall: Identifiable, Equatable, Codable { var id = UUID(); let name: String; let ip: String; let at: Date }
    @Published var missedCalls: [MissedCall] = StreamViewModel.loadMissed() { didSet { StreamViewModel.saveMissed(missedCalls) } }
    private static let missedKey = "trinetMissedCalls"
    private static func loadMissed() -> [MissedCall] {
        guard let d = UserDefaults.standard.data(forKey: missedKey),
              let arr = try? JSONDecoder().decode([MissedCall].self, from: d) else { return [] }
        return arr
    }
    private static func saveMissed(_ m: [MissedCall]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: missedKey) }
    }

    // Recent-call journal: one record per COMPLETED call (frames actually flowed), with duration and the
    // average link quality it ran at. Persisted so "how did my last calls go" survives a restart.
    struct CallRecord: Identifiable, Equatable, Codable {
        var id = UUID(); let peer: String; let at: Date; let durationSec: Int; let avgKbps: Int; let avgJitterMs: Int
        var stalls: Int            // how many times the link stalled during this call
        init(peer: String, at: Date, durationSec: Int, avgKbps: Int, avgJitterMs: Int, stalls: Int) {
            self.peer = peer; self.at = at; self.durationSec = durationSec
            self.avgKbps = avgKbps; self.avgJitterMs = avgJitterMs; self.stalls = stalls
        }
        // Custom decode so records written before `stalls` existed still load (synthesized Codable does NOT
        // apply a property default for a missing key — it would throw and drop the whole journal).
        enum CodingKeys: String, CodingKey { case id, peer, at, durationSec, avgKbps, avgJitterMs, stalls }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            peer = try c.decode(String.self, forKey: .peer)
            at = try c.decode(Date.self, forKey: .at)
            durationSec = try c.decode(Int.self, forKey: .durationSec)
            avgKbps = try c.decode(Int.self, forKey: .avgKbps)
            avgJitterMs = try c.decode(Int.self, forKey: .avgJitterMs)
            stalls = try c.decodeIfPresent(Int.self, forKey: .stalls) ?? 0
        }
    }
    private var callStalls = 0     // stall count for the in-progress call
    @Published var recentCalls: [CallRecord] = StreamViewModel.loadRecents() { didSet { StreamViewModel.saveRecents(recentCalls) } }
    private static let recentsKey = "trinetRecentCalls"
    private static func loadRecents() -> [CallRecord] {
        guard let d = UserDefaults.standard.data(forKey: recentsKey),
              let a = try? JSONDecoder().decode([CallRecord].self, from: d) else { return [] }
        return a
    }
    private static func saveRecents(_ r: [CallRecord]) {
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: recentsKey) }
    }
    // Tab-separated journal for export (link-quality diagnostics the user can share anywhere).
    var callJournalText: String {
        let head = "peer\tstarted\tduration_s\tavg_kbps\tavg_jitter_ms\tstalls"
        let rows = recentCalls.map { "\($0.peer)\t\(ISO8601DateFormatter().string(from: $0.at))\t\($0.durationSec)\t\($0.avgKbps)\t\($0.avgJitterMs)\t\($0.stalls)" }
        return ([head] + rows).joined(separator: "\n")
    }

    // Aggregate stability across the journal — one glance at "how good has my link been overall".
    struct CallStats: Equatable {
        let count: Int; let avgDurationSec: Int; let totalStalls: Int; let avgKbps: Int
        // Pure summariser (verified by a swiftc harness): integer means over the records, empty => all zeros.
        static func summarize(durations: [Int], stalls: [Int], kbps: [Int]) -> CallStats {
            let n = durations.count
            guard n > 0 else { return CallStats(count: 0, avgDurationSec: 0, totalStalls: 0, avgKbps: 0) }
            return CallStats(count: n,
                             avgDurationSec: durations.reduce(0, +) / n,
                             totalStalls: stalls.reduce(0, +),
                             avgKbps: kbps.reduce(0, +) / n)
        }
    }
    var callStats: CallStats {
        CallStats.summarize(durations: recentCalls.map(\.durationSec),
                            stalls: recentCalls.map(\.stalls),
                            kbps: recentCalls.map(\.avgKbps))
    }
    private var callStartedAt: Date?
    @Published var noAnswer = false          // caller-side: 30s with no frames
    private var noAnswerTimer: Timer?

    // MARK: - Delay-based BWE (receiver report) — mirrors the Mac CallManager.
    // Receiver measures inter-arrival jitter of video datagrams (RFC3550 EMA) and reports it once a second in
    // [0xFD 0xBE jitterMsBE:2 pktsBE:2]; the sender backs off when the peer's jitter RISES — before loss.
    private var lastVideoArrival: Date?
    private var meanGapMs = 0.0
    private var jitterMs = 0.0
    private var rxPktsThisSec = 0
    private var bweTimer: Timer?
    private var highJitterStreak = 0
    private var cleanStreak = 0   // consecutive low-jitter reports, for GCC probe-up
    private var lossStreak = 0             // consecutive high-residual-loss reports (loss-based back-off)
    private var lastFramesSentSample = 0   // framesSent at the previous BWE report, for the per-second send delta
    private var statsTick = 0              // 1s BWE ticks; the aligned STATS line prints every 5th
    @Published var peerJitterMs = 0
    @Published var rxFps = 0           // frames/sec we're DECODING from the peer(s) (0 = no video arriving)
    @Published var rxHeight: Int32 = 0 // resolution of the received frames, for the in-call badge (1-1)
    @Published var rxSources = 0       // live decoding sources in a group call
    @Published var safetyNumber: String? = nil   // 1-1 identity code for out-of-band verification
    @Published var mitmWarning = false           // peer's pinned identity changed -> possible MITM
    private var lastRxFrameCount = 0
    private var rxFrozenSince: Date?   // start of a decoded-frame freeze while packets still arrive (1-1)
    @Published var bitrateKbps = 0           // current encode bitrate, for the link badge
    @Published var bitrateHistory: [Int] = []  // last 60s, for the link-quality sparkline
    @Published var jitterHistory: [Int] = []

    private func noteVideoArrival() {
        let now = Date()
        if let last = lastVideoArrival {
            let gap = now.timeIntervalSince(last) * 1000
            meanGapMs += (gap - meanGapMs) / 16
            jitterMs += (abs(gap - meanGapMs) - jitterMs) / 16
        }
        lastVideoArrival = now
        rxPktsThisSec += 1
    }

    private func startBWE() {
        bweTimer?.invalidate()
        bweTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.phase != .idle else { return }
            let j = UInt16(min(65535, max(0, Int(self.jitterMs))))
            let p = UInt16(min(65535, self.rxPktsThisSec))
            self.rxPktsThisSec = 0
            var pkt = Data([0xFD, 0xBE])
            pkt.append(contentsOf: [UInt8(j >> 8), UInt8(j & 0xFF), UInt8(p >> 8), UInt8(p & 0xFF)])
            self.transport.send(pkt)
            // Receive-side video health for the badge (frames DECODED in the last second). In a group call,
            // sum across every source's decoder and report the source count instead of one resolution.
            let fc: Int
            if self.isGroup {
                fc = self.groupDecoders.values.reduce(0) { $0 + $1.frameCount }
                self.rxSources = self.groupDecoders.values.filter { $0.frameCount > 0 }.count
                self.rxHeight = self.groupDecoders.values.first?.decodedHeight ?? 0
            } else {
                fc = self.decoder.frameCount
                self.rxSources = 0
                self.rxHeight = self.decoder.decodedHeight
            }
            self.rxFps = max(0, fc - self.lastRxFrameCount)
            self.lastRxFrameCount = fc
            // Security surface for the call UI (1-1 safety number + MITM alarm).
            let sn = self.isGroup ? nil : self.transport.peerSafetyNumber
            if self.safetyNumber != sn {
                self.safetyNumber = sn
                if let sn = sn { NSLog("TRINET: 1-1 peer identity verified — safety number \(sn)") }
            }
            if self.mitmWarning != self.transport.mitmDetected { self.mitmWarning = self.transport.mitmDetected }
            // framesReceived is otherwise set only in the 1-1 onData path; in a group call drive it from the
            // per-source decoders so LinkHealth and the STATS line reflect the real received video.
            if self.isGroup { self.framesReceived = fc }
            // ALIGNED delivery stats: sample sent vs decoded AT THE SAME INSTANT, every ~5s (the honest
            // end-to-end number; the per-N tx/rx log lines are sampled at different cadences and don't align).
            self.statsTick += 1
            if self.statsTick % 5 == 0 {
                let a = self.audio.audioStats
                if a.sent > 0 {
                    let d = a.decoded * 100 / max(1, a.sent)
                    NSLog("TRINET: STATS audio sent=\(a.sent) decoded=\(a.decoded) recovered=\(a.recovered) delivery=\(d)% | video sent=\(self.framesSent) recv=\(self.framesReceived)")
                }
            }
            // FROZEN-VIDEO recovery (1-1): if fragments keep ARRIVING but reassembly never completes a NAL, the
            // picture freezes (rxFps == 0) with packets flowing and nothing asks for an IDR (the decoder's own
            // request needs a NAL; the packet-stall needs packets to STOP). Detect it and request a keyframe.
            if !self.isGroup, self.framesReceived > 0, self.rxFps == 0 {
                let msSincePacket = self.lastVideoArrival.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 99_999
                if msSincePacket < 3_000 {
                    if self.rxFrozenSince == nil { self.rxFrozenSince = Date() }
                    if Date().timeIntervalSince(self.rxFrozenSince!) > 2.0 {
                        self.transport.send(Data([0xFC, 0x00]))
                        NSLog("TRINET: RX video frozen (0 fps, packets flowing) — requesting keyframe")
                        self.rxFrozenSince = Date()
                    }
                } else { self.rxFrozenSince = nil }
            } else { self.rxFrozenSince = nil }
            self.bitrateKbps = self.camera.bitrateKbps   // refresh the link badge once a second
            // Rolling 60s history for the tap-to-expand link-quality sparkline.
            self.bitrateHistory.append(self.bitrateKbps); if self.bitrateHistory.count > 60 { self.bitrateHistory.removeFirst() }
            self.jitterHistory.append(self.peerJitterMs); if self.jitterHistory.count > 60 { self.jitterHistory.removeFirst() }
            self.evalLinkHealth()
        }
    }

    // Make link trouble VISIBLE instead of a silent freeze (debugging doctrine): once frames have flowed, if
    // none arrive for STALL_SECS the call is stalled; sustained high peer jitter is a weak link.
    enum LinkHealth { case good, weak, stalled
        // Pure classifier (verified by a standalone swiftc harness): once frames have flowed, no frame for
        // stallMs => stalled; sustained peer jitter over weakJitterMs => weak; otherwise good.
        static func classify(framesFlowed: Bool, msSinceLastFrame: Int, jitterMs: Int,
                             stallMs: Int = 5000, weakJitterMs: Int = 40) -> LinkHealth {
            guard framesFlowed else { return .good }
            if msSinceLastFrame > stallMs { return .stalled }
            if jitterMs > weakJitterMs { return .weak }
            return .good
        }
        // Escalating recovery plan (verified by the swiftc harness). While stalled we ask the peer for a fresh
        // IDR, rate-limited. A PROLONGED stall (> prolongedMs of continuous silence) escalates: the request
        // cadence halves (2s -> 1s) AND we drop the encoder to its bitrate floor, trading resolution for a
        // better chance of punching a keyframe through a bad channel. Not stalled => do nothing.
        struct RecoveryPlan: Equatable { let requestKeyframe: Bool; let dropToFloor: Bool }
        static func recoveryPlan(health: LinkHealth, msSinceLastRecovery: Int?, msStalledContinuously: Int,
                                 baseCooldownMs: Int = 2000, prolongedMs: Int = 10000) -> RecoveryPlan {
            guard health == .stalled else { return RecoveryPlan(requestKeyframe: false, dropToFloor: false) }
            let prolonged = msStalledContinuously > prolongedMs
            let cooldown = prolonged ? baseCooldownMs / 2 : baseCooldownMs
            let ask = msSinceLastRecovery.map { $0 > cooldown } ?? true
            return RecoveryPlan(requestKeyframe: ask, dropToFloor: prolonged && ask)
        }
    }
    @Published var linkHealth: LinkHealth = .good
    @Published var linkRestored = false        // brief green "Connection restored" flash on stalled -> good
    private var lastRecoveryAt: Date?
    private var stalledSince: Date?            // start of the CURRENT continuous stall (for escalation)
    private func evalLinkHealth() {
        let ms = lastVideoArrival.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let inCall = (phase == .live || phase == .connecting)
        let next = LinkHealth.classify(framesFlowed: inCall && framesReceived > 0,
                                       msSinceLastFrame: ms, jitterMs: peerJitterMs)
        let prev = linkHealth
        if next != .stalled { stalledSince = nil }
        else if stalledSince == nil { stalledSince = Date() }
        // Auto-recovery: a stall means NO packets are arriving, so the decoder's own onKeyframeNeeded can't
        // fire. Ask the peer for a fresh IDR (rate-limited); a prolonged stall escalates to a faster cadence
        // and drops the encoder to its floor to punch a keyframe through.
        let sinceRecovery = lastRecoveryAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let stalledMs = stalledSince.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let plan = LinkHealth.recoveryPlan(health: next, msSinceLastRecovery: sinceRecovery, msStalledContinuously: stalledMs)
        if plan.requestKeyframe {
            transport.send(Data([0xFC, 0x00]))
            lastRecoveryAt = Date()
            if plan.dropToFloor { camera.nudgeBitrate(down: true) }
            NSLog("TRINET: stall %dms — requested keyframe%@", stalledMs, plan.dropToFloor ? " + dropped to floor" : "")
        }
        if prev != .stalled, next == .stalled { callStalls += 1 }   // count stalls for the call journal
        if prev == .stalled, next == .good {
            linkRestored = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.linkRestored = false }
        }
        linkHealth = next
    }

    private func handleBWEReport(_ data: Data) {
        let j = Int(data[2]) << 8 | Int(data[3])
        let rxCount = Int(data[4]) << 8 | Int(data[5])   // frames the peer DECODED last second (was parsed nowhere)
        DispatchQueue.main.async {
            self.peerJitterMs = j
            // LOSS-based controller — the missing half of GCC. The delay controller below only reacts to a rising
            // QUEUE (jitter); a low-latency-but-lossy path (Wi-Fi retransmit, an FEC radio) drops frames WITHOUT
            // adding delay, so nothing backed off — 25% induced loss produced ZERO step-down. Compare frames WE
            // sent last second to frames the peer actually received. 1-1 only: in a group the peer's count sums
            // every source, not just us. FEC/PLI repair some loss first, so this is RESIDUAL frame loss.
            var lossElevated = false
            if !self.isGroup {
                let sent = self.framesSent - self.lastFramesSentSample
                self.lastFramesSentSample = self.framesSent
                if sent >= 5 {
                    let lossPct = max(0, sent - rxCount) * 100 / sent
                    lossElevated = lossPct >= 5
                    if lossPct >= 15 {
                        self.lossStreak += 1
                        if self.lossStreak >= 2 {
                            self.camera.nudgeBitrate(down: true)
                            self.audio.redDepth = 3               // audio: survive a 2-burst
                            self.transport.fecGroup = VideoFEC.lossyGroup   // video: 1 parity per 4 frags
                            NSLog("TRINET: BWE back-off — residual loss \(lossPct)% (sent \(sent), peer rx \(rxCount))")
                        }
                    } else {
                        self.lossStreak = 0
                        if lossPct < 5 {                          // link clean -> relax both
                            self.audio.redDepth = 2
                            self.transport.fecGroup = VideoFEC.cleanGroup
                        }
                    }
                }
            }
            if j > 40 {
                self.highJitterStreak += 1
                self.cleanStreak = 0
                if self.highJitterStreak >= 2 {
                    self.camera.nudgeBitrate(down: true)
                    NSLog("TRINET: BWE back-off — peer jitter \(j)ms")
                }
            } else if j < 20 && !lossElevated {    // GCC probe-up: spare capacity AND no loss -> an EXTRA climb tick (real stream,
                self.highJitterStreak = 0   // never padding bursts). Overshoot is caught instantly by back-off.
                self.cleanStreak += 1
                // Probe every 2 clean reports (was 3): harness-proven to cut recovery ~26s -> ~17s on the
                // 900k->400k->900k step while still settling at the knee with no oscillation (freq-only change).
                if self.cleanStreak >= 2 {
                    self.camera.nudgeBitrate(down: false)
                    self.cleanStreak = 0
                    NSLog("TRINET: BWE probe-up — peer jitter \(j)ms, capacity spare")
                }
            } else {
                self.highJitterStreak = 0
                self.cleanStreak = 0
            }
        }
    }
    private var idleFd: Int32 = -1
    private var incomingTimer: Timer?
    private let idleQueue = DispatchQueue(label: "trinet.idle-listener")
    private static let invitePort: UInt16 = 7000
    private static let inviteMagic: [UInt8] = [0xFD, 0x11]   // "someone is calling you"
    // AUTH: authenticate the plaintext INVITE with an 8-byte HMAC. The key is now bound to the room
    // passphrase (empty room == the legacy PSK-only key), so with a room set only a peer that knows the
    // room secret can ring or auto-join. Wire: [FD 11][mac:8][payload]. MUST match the Mac derivation.
    static func inviteMAC(_ payload: Data) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: payload, using: MeshCrypto.inviteAuthKey(room: PeerDiscovery.myRoom)).prefix(8))
    }

    func startIdleListener() {
        stopIdleListener()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        // 1s recv timeout so the blocking recvfrom wakes periodically and the loop can EXIT when idleFd
        // changes. Without it a blocked recvfrom hangs the serial queue and the NEXT startIdleListener()'s
        // loop is stuck behind it — incoming calls die after call #1.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = StreamViewModel.invitePort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { NSLog("TRINET: idle listener bind(:7000) busy — skip"); close(fd); return }
        idleFd = fd
        idleQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            while self?.idleFd == fd {
                var from = sockaddr_in(); var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                        recvfrom(fd, &buf, buf.count, 0, s, &fl)
                    }
                }
                if n <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }  // recv timeout — re-check idleFd
                    break
                }
                guard n >= 2 else { continue }

                // Legacy plaintext direct chat is fail-closed. Secure off-call chat is
                // recipient-encrypted and received by MeshCallSignaling on signed port 7001.
                if buf[0] == StreamViewModel.chatMagic[0] && buf[1] == StreamViewModel.chatMagic[1] {
                    NSLog("TRINET TEXT: rejected legacy plaintext off-call frame")
                    continue
                }

                guard buf[0] == StreamViewModel.inviteMagic[0], buf[1] == StreamViewModel.inviteMagic[1] else { continue }
                // AUTH FIRST: [FD 11][mac:8][payload]. Reject anything without a valid PSK-keyed HMAC so an
                // unauthenticated LAN packet can never ring us or force an auto-join (the forced-camera vuln).
                guard n >= 10 else { continue }
                let payloadData = n > 10 ? Data(buf[10..<Int(n)]) : Data()
                guard Array(buf[2..<10]) == StreamViewModel.inviteMAC(payloadData) else { continue }
                // payload = "name\nip1,ip2,ip3" — the full participant list lets Accept rebuild the whole mesh.
                let payload = String(data: payloadData, encoding: .utf8) ?? ""
                let parts = payload.components(separatedBy: "\n")
                let name = (parts.first?.isEmpty == false) ? parts[0] : "TRI-NET"
                let participants = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                // Spam-hardening: a REAL INVITE always carries the caller's IP list ([myIP] + hosts, >= 1).
                // A payload with no participants (a 2-byte magic-only or empty-field datagram) can't be a call
                // -- reject it so any LAN host can't pop the incoming-call UI (and block real INVITEs for 40s).
                guard !participants.isEmpty else { continue }
                let room = parts.count > 2 ? parts[2] : ""
                // ANTI-REPLAY: reject a stale (or timestamp-less) INVITE. A valid HMAC only proves the sender
                // knew the PSK once; the freshness window stops a captured INVITE from being replayed later.
                let tsMs = parts.count > 3 ? (Int64(parts[3]) ?? 0) : 0
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                guard tsMs != 0, abs(nowMs - tsMs) <= 15_000 else { continue }
                let ip = String(cString: inet_ntoa(from.sin_addr))
                let macKey = Data(buf[2..<10])   // 8-byte auth tag, used as the replay-dedup key
                DispatchQueue.main.async {
                    guard let self = self, self.phase == .idle, self.incomingCall == nil else { return }  // don't ring mid-call / twice
                    // SEEN-MAC dedup closes the immediate-replay gap inside the 15s freshness window (the 4x UDP
                    // re-sends share a tag and are already ignored above, so dropping duplicates is safe).
                    self.seenInviteMACs = self.seenInviteMACs.filter { Date().timeIntervalSince($0.value) < 30 }
                    guard self.seenInviteMACs[macKey] == nil else { return }
                    self.seenInviteMACs[macKey] = Date()
                    self.incomingCall = IncomingCall(name: name, ip: ip, participants: participants)
                    // AUTO-ACCEPT a GROUP call (>2 participants = caller + me + others) or a same-room caller,
                    // so "call from the Mac -> both iPhones just join" works with no manual Accept. A plain
                    // 1-1 (participants == {caller, me}) still rings so you can pick up the handset.
                    if participants.count > 2 || (!room.isEmpty && room == PeerDiscovery.myRoom) {
                        NSLog("TRINET: auto-joining group from \(name) — \(participants.count) participants, room '\(room)'")
                        self.acceptIncoming()
                        return
                    }
                    NSLog("TRINET: INCOMING call from \(name) (\(ip))")
                    self.incomingTimer?.invalidate()
                    self.incomingTimer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        if let m = self.incomingCall {   // auto-miss after 40s -> log it for one-tap call-back
                            self.missedCalls.insert(MissedCall(name: m.name, ip: m.ip, at: Date()), at: 0)
                            if self.missedCalls.count > 5 { self.missedCalls.removeLast() }
                            NSLog("TRINET: MISSED call from \(m.name) (\(m.ip))")
                        }
                        self.incomingCall = nil
                    }
                }
            }
        }
        NSLog("TRINET: idle listener up on :7000 (waiting for calls)")
    }
    func stopIdleListener() { if idleFd >= 0 { close(idleFd); idleFd = -1 } }

    // Caller side: ring each target's :7000 a few times (UDP is lossy) from a throwaway socket.
    // `participants` = every IP in this call (including me), so the callee can rejoin the FULL mesh.
    func sendInvite(to ips: [String], participants: [String]) {
        // payload = "name\nip1,ip2\nROOM\nTS_MS" — TS_MS is a freshness timestamp so a sniffed-and-replayed
        // INVITE (even with a valid HMAC) is rejected as stale. The HMAC covers TS too, so it can't be rewritten.
        let tsMs = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = PeerDiscovery.myName + "\n" + participants.joined(separator: ",") + "\n" + PeerDiscovery.myRoom + "\n" + String(tsMs)
        NSLog("TRINET: ringing \(ips.joined(separator: ",")) with INVITE (participants: \(participants.joined(separator: ",")))")
        // MUST NOT use idleQueue: startCall() just closed the idle socket, but a blocked recvfrom on that
        // serial queue may not wake (POSIX close() doesn't reliably interrupt it), which would leave the
        // INVITE stuck in the queue forever — the callee never rings. A fresh queue always runs.
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            let payloadData = Data(payload.utf8)
            var pkt = StreamViewModel.inviteMagic                          // [FD 11]
            pkt.append(contentsOf: StreamViewModel.inviteMAC(payloadData))  // + HMAC(8)
            pkt.append(contentsOf: payloadData)                            // + payload
            for ip in ips where !ip.isEmpty {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = StreamViewModel.invitePort.bigEndian
                addr.sin_addr.s_addr = inet_addr(ip)
                for _ in 0..<4 {
                    _ = pkt.withUnsafeBytes { raw in
                        withUnsafePointer(to: &addr) { p in
                            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                                sendto(fd, raw.baseAddress, pkt.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    usleep(150_000)
                }
            }
            close(fd)
        }
    }

    func acceptIncoming() {
        guard let inc = incomingCall else { return }
        incomingTimer?.invalidate(); incomingCall = nil
        // Rebuild the exact call: caller + every other participant, minus myself. For a 1-1 invite the
        // participant list is just {caller, me}, so this collapses to a plain 1-1 back to the caller.
        var mesh = Set(inc.participants); mesh.insert(inc.ip); mesh.remove(myIP)
        let hosts = mesh.filter { !$0.isEmpty }.sorted()
        remoteIP = hosts.isEmpty ? inc.ip : hosts.joined(separator: ",")
        NSLog("TRINET: accepting call -> mesh back to \(remoteIP)")
        activeRoute = .mesh
        startMeshCall()
    }
    func declineIncoming() { incomingTimer?.invalidate(); incomingCall = nil }

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
        let targetIsMeshAddress = isMeshAddress(target)
        let hasLiveMeshContact = meshContact?.online == true && meshContact?.meshAddress != nil
        let selected = CallRoutePolicy.select(requested: route,
                                              targetIsMeshAddress: targetIsMeshAddress,
                                              hasLiveMeshContact: hasLiveMeshContact)
        if selected == .mesh {
            if targetIsMeshAddress {
                remoteIP = target
            } else if let address = meshContact?.meshAddress,
                      hasLiveMeshContact || (route == .mesh && MeshAddressPolicy.canPersist(address)) {
                remoteIP = address
            } else {
                callError = meshContact == nil
                    ? "@\(target) is not visible in the current mesh."
                    : "@\(target) is remembered, but is not online in the current mesh. Use Auto or Internet."
                activeRoute = nil
                return
            }
        }
        activeRoute = selected
        if selected == .internet {
            startInternetCall()
        } else {
            let fallbackTarget = route == .automatic && !targetIsMeshAddress ? target : nil
            let media = InternetCallMedia.outgoing(cameraOff: cameraOff)
            let sentInvite: MeshCallInvite
            do {
                sentInvite = try directory.sendMeshInvite(to: remoteIP,
                                                          port: meshContact?.meshPort,
                                                          media: media)
            } catch {
                if route == .automatic && !targetIsMeshAddress {
                    NSLog("TRINET: local signaling to %@ failed; falling back to Internet: %@",
                          target, error.localizedDescription)
                    activeRoute = .internet
                    startInternetCall()
                    return
                }
                callError = error.localizedDescription
                activeRoute = nil
                return
            }
            let controlExpectation = meshContact.map {
                MeshCallControlExpectation(callID: sentInvite.callID,
                                           localDeviceID: identity.deviceID,
                                           peerUserID: $0.userID,
                                           peerDeviceID: $0.deviceID,
                                           peerKeyFingerprint: $0.keyFingerprint,
                                           peerAddress: remoteIP)
            }
            startMeshCall(internetFallbackTarget: fallbackTarget,
                          sendLegacyInvite: fallbackTarget == nil,
                          outboundControl: controlExpectation,
                          outboundControlPort: meshContact?.meshPort,
                          media: media)
        }
    }

    func acceptIncomingMeshCall() {
        guard let incoming = incomingMeshCall else { return }
        incomingMeshCall = nil
        guard incoming.isFresh() else {
            callError = "The local invitation expired. Waiting for the Internet route."
            return
        }
        callee = incoming.invite.nickname
        remoteIP = incoming.sourceAddress
        do {
            try directory.sendMeshControl(.accepted,
                                          callID: incoming.invite.callID,
                                          recipientDeviceID: incoming.invite.deviceID,
                                          to: incoming.sourceAddress)
        } catch {
            incomingMeshCall = incoming
            callError = "Cannot confirm the local call: \(error.localizedDescription)"
            return
        }
        cameraOff = !incoming.invite.media.video
        activeRoute = .mesh
        startMeshCall(acceptedIncoming: incoming, media: incoming.invite.media)
    }

    func declineIncomingMeshCall() {
        let cancellationTarget = MeshCallCancellationPolicy.target(
            outbound: nil,
            outboundPort: nil,
            inbound: incomingMeshCall
        )
        sendMeshCancellation(cancellationTarget)
        incomingMeshCall = nil
    }

    private func handleMeshCallControl(_ control: MeshCallControl, sourceAddress: String) {
        switch control.kind {
        case .accepted:
            guard let expected = outboundMeshControl,
                  expected.matches(control, sourceAddress: sourceAddress),
                  activeRoute == .mesh,
                  meshSessionID != nil else { return }
            outboundMeshAccepted = true
            NSLog("TRINET: peer accepted signed local call %@", control.callID)
            #if DEBUG
            debugE2EHandleVerifiedAcceptance(control)
            #endif
        case .cancelled:
            if let expected = outboundMeshControl,
               expected.matches(control, sourceAddress: sourceAddress),
               activeRoute == .mesh,
               meshSessionID != nil {
                outboundMeshControl = nil
                outboundMeshControlPort = nil
                callStartedAt = nil
                stopCall()
                callError = "The peer declined the local call."
                NSLog("TRINET: peer cancelled signed local call %@", control.callID)
                return
            }
            if let incoming = incomingMeshCall,
               incoming.controlExpectation(localDeviceID: identity.deviceID)
                .matches(control, sourceAddress: sourceAddress) {
                incomingMeshCall = nil
            }
            guard let accepted = acceptedIncomingMeshCall,
                  accepted.controlExpectation(localDeviceID: identity.deviceID)
                    .matches(control, sourceAddress: sourceAddress),
                  activeRoute == .mesh,
                  meshSessionID != nil else { return }
            acceptedIncomingMeshCall = nil
            callStartedAt = nil
            stopCall()
            callError = nil
            NSLog("TRINET: caller cancelled signed local call %@", control.callID)
        }
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
        if contact.online, let address = contact.meshAddress {
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
        let media = InternetCallMedia.outgoing(cameraOff: cameraOff)
        UserDefaults.standard.set(target, forKey: "internetCallee")
        internet.update(identity: identity, configuration: internetConfiguration)
        phase = .connecting
        let controller = internet
        callKitUUID = CallKitCoordinator.shared.startOutgoing(
            handle: target,
            video: media.video
        ) { [weak self] uuid, result in
            guard let self, self.callKitUUID == uuid else { return }
            switch result {
            case .success:
                self.outgoingInternetAwaitingRemote = true
                self.internetAnswerTimer?.invalidate()
                self.internetAnswerTimer = Timer.scheduledTimer(
                    withTimeInterval: 45,
                    repeats: false
                ) { [weak self] _ in
                    guard let self,
                          self.outgoingInternetAwaitingRemote,
                          self.activeRoute == .internet,
                          self.phase == .connecting else { return }
                    self.callError = "No answer."
                    self.stopCall()
                }
                self.beginInternetAttempt(markOutgoingConnected: true) {
                    try await controller.start(callee: target,
                                               audio: media.audio,
                                               video: media.video)
                }
            case .failure(let error):
                self.outgoingInternetAwaitingRemote = false
                self.internetAnswerTimer?.invalidate()
                self.internetAnswerTimer = nil
                self.internetAttemptID = nil
                self.internetCallTask?.cancel()
                self.internetCallTask = nil
                self.callKitUUID = nil
                self.phase = .idle
                self.activeRoute = nil
                self.callError = error is CancellationError
                    ? nil
                    : "The system could not start the call: \(error.localizedDescription)"
            }
        }
    }

    func answerInternetCall(callID: String,
                            media: InternetCallMedia,
                            completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        activeRoute = .internet
        cameraOff = !media.video
        pendingInternetVideo = media.video
        internet.update(identity: identity, configuration: internetConfiguration)
        let controller = internet
        beginInternetAttempt(markOutgoingConnected: false, completion: { [weak self] result in
            if case .success = result {
                self?.enablePendingInternetVideoIfPossible()
            } else {
                self?.pendingInternetVideo = false
            }
            completion(result)
        }) {
            // A PushKit wake can arrive while the phone is locked and camera
            // capture is unavailable. Establish signaling and microphone first;
            // publish video as soon as the app becomes active after Answer.
            try await controller.join(callID: callID,
                                      audio: media.audio,
                                      video: false)
        }
    }

    private func beginInternetAttempt(markOutgoingConnected: Bool,
                                      completion: @escaping (Result<Void, Error>) -> Void = { _ in },
                                      operation: @escaping () async throws -> Void) {
        internetCallTask?.cancel()
        let attemptID = UUID()
        internetAttemptID = attemptID
        phase = .connecting
        internetCallTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation()
                await MainActor.run { [weak self] in
                    guard let self, self.internetAttemptID == attemptID else { return }
                    self.internetAttemptID = nil
                    self.internetCallTask = nil
                    if markOutgoingConnected {
                        self.completeOutgoingInternetCallIfReady()
                    } else {
                        self.phase = .live
                    }
                    completion(.success(()))
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.internetAttemptID == attemptID else { return }
                    self.internetAttemptID = nil
                    self.internetCallTask = nil
                    self.outgoingInternetAwaitingRemote = false
                    self.internetAnswerTimer?.invalidate()
                    self.internetAnswerTimer = nil
                    self.callError = error.localizedDescription
                    self.phase = .idle
                    self.activeRoute = nil
                    if let uuid = self.callKitUUID { CallKitCoordinator.shared.end(uuid) }
                    self.callKitUUID = nil
                    if error is CancellationError {
                        self.callError = nil
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    private func completeOutgoingInternetCallIfReady() {
        guard outgoingInternetAwaitingRemote,
              internet.hasRemoteParticipant,
              activeRoute == .internet,
              phase == .connecting else { return }
        outgoingInternetAwaitingRemote = false
        internetAnswerTimer?.invalidate()
        internetAnswerTimer = nil
        phase = .live
        if let uuid = callKitUUID {
            CallKitCoordinator.shared.markOutgoingConnected(uuid)
        }
    }

    func receiveAlertNotification(unreadCount: Int?) {
        guard !chatOpen else { return }
        if let unreadCount {
            unreadChat = max(unreadChat, unreadCount)
        } else {
            unreadChat += 1
        }
    }

    func markChatNotificationsRead() {
        unreadChat = 0
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    private func enablePendingInternetVideoIfPossible() {
        guard pendingInternetVideo,
              activeRoute == .internet,
              phase == .live,
              UIApplication.shared.applicationState == .active else { return }
        pendingInternetVideo = false
        internet.setCamera(enabled: true)
    }

    private func startMeshCall(internetFallbackTarget: String? = nil,
                               sendLegacyInvite: Bool = true,
                               outboundControl: MeshCallControlExpectation? = nil,
                               outboundControlPort: UInt16? = nil,
                               acceptedIncoming: IncomingMeshCall? = nil,
                               media requestedMedia: InternetCallMedia? = nil) {
        let media = requestedMedia ?? .outgoing(cameraOff: cameraOff)
        activeMeshMedia = media
        cameraOff = !media.video
        let sessionID = UUID()
        meshSessionID = sessionID
        self.outboundMeshControl = outboundControl
        self.outboundMeshControlPort = outboundControlPort
        outboundMeshAccepted = false
        acceptedIncomingMeshCall = acceptedIncoming
        UserDefaults.standard.set(remoteIP, forKey: "remoteIP")
        if !recentIPs.contains(remoteIP) {
            recentIPs.insert(remoteIP, at: 0)
            if recentIPs.count > 5 { recentIPs.removeLast() }
            UserDefaults.standard.set(recentIPs, forKey: "recentCallIPs")
        }

        phase = .connecting
        callStartedAt = Date()    // for the recent-call journal duration
        callStalls = 0
        discovery.inCall = true   // advertise "in call" in the roster
        stopIdleListener()        // the encrypted transport is about to own :7000
        // Caller-side ring feedback: if nothing arrives in 30s, say "No answer" instead of connecting forever.
        noAnswer = false
        noAnswerTimer?.invalidate()
        noAnswerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self,
                  self.meshSessionID == sessionID,
                  self.phase == .connecting else { return }
            self.noAnswer = true
            NSLog("TRINET: no answer from \(self.remoteIP) after 30s")
        }

        // Several IPs (comma/space) => group conference; one IP => normal 1-1 (untouched path).
        let hosts = remoteIP.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        // Legacy signaling has no authenticated media intent. Never use it for
        // audio-only, or an older peer could silently open its camera.
        if sendLegacyInvite && media.video {
            sendInvite(to: hosts, participants: [myIP] + hosts)
        }
        if hosts.count > 1 {
            isGroup = true
            startGroupCall(hosts: hosts, sessionID: sessionID, media: media)
            return
        }
        isGroup = false
        let attemptID = UUID()
        meshAttemptID = attemptID

        // UDP: send to remoteIP:7000, listen on 7000 (same port for both). The NAT-traversal path
        // overrides all three: the peer it DISCOVERED, the local port it punched, and the punched
        // socket itself (a symmetric NAT drops media from any other socket).
        transport.onSecureSessionReady = { [weak self] in
            guard let self,
                  self.meshSessionID == sessionID,
                  self.meshAttemptID == attemptID else { return }
            self.meshAttemptID = nil
            self.phase = .live
        }
        transport.connect(host: rzPeer?.host ?? remoteIP, port: rzPeer?.port ?? 7000,
                          recvPort: rzLocalPort ?? 7000, adoptFd: punchedFd)
        punchedFd = nil   // ownership moved to the transport (or never existed)
        rzPeer = nil
        rzLocalPort = nil
        startBWE()

        // Peer PLI → force an IDR from our encoder
        decoder.onKeyframeNeeded = { [weak self] in
            guard let self, self.meshSessionID == sessionID else { return }
            self.transport.send(Data([0xFC, 0x00]))
        }

        // Incoming: UDP → PLI / audio / chat / reaction / H.264 decoder → display
        transport.onLinkFeedback = { [weak self] advice, util, drop, rate in
            guard let self, self.meshSessionID == sessionID else { return }
            self.noteLinkFeedback(advice: advice, util: util, drop: drop, rate: rate)
        }

        transport.onData = { [weak self] data in
            guard let self, self.meshSessionID == sessionID else { return }
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
                DispatchQueue.main.async {
                    guard self.meshSessionID == sessionID else { return }
                    self.chat.append(ChatLine(who: .them, text: msg))
                    self.chatChime.play()
                    if !self.chatOpen { self.unreadChat += 1 }
                }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async {
                    guard self.meshSessionID == sessionID else { return }
                    self.showReaction(emoji)
                }
                return
            }
            if data.count >= 5, data[0] == 0xFD, data[1] == 0x53, data[2] == 0x4C { // SLEW command (RTI fusion)
                // Format: [0xFD 0x53 0x4C][slew_angle u16 LE][direction u8]
                let slew = UInt16(data[3]) | (UInt16(data[4]) << 8)
                let dirByte: UInt8 = data.count >= 6 ? data[5] : 2
                let dirName = dirByte == 0 ? "CCW" : dirByte == 1 ? "CW" : "none"
                DispatchQueue.main.async {
                    guard self.meshSessionID == sessionID else { return }
                    self.rtiSlewAngle = Int(slew)
                    self.rtiSlewDirection = dirName
                    self.rtiSlewActive = true
                    NSLog("TRINET: RTI FUSION slew %d° %@", slew, dirName)
                }
                return
            }
            if data.count == 6, data[0] == 0xFD, data[1] == 0xBE { // BWE receiver report
                self.handleBWEReport(data)
                return
            }
            if data.count == 4, data[0] == 0xFD, data[1] == 0x4E { // NACK: peer never got this NAL -> re-send it
                self.transport.resendNAL(UInt16(data[2]) | (UInt16(data[3]) << 8))
                return
            }
            if data.count >= 5, data[0] == 0xFD, data[1] == 0x4F { // per-fragment NACK -> re-send just those frags
                self.transport.resendFragments(UInt16(data[2]) | (UInt16(data[3]) << 8), data[4...].map { Int($0) })
                return
            }
            // Doctrine: NEVER hand an unknown control subtype to the H.264 decoder. Real NALs start 00 00 00 01.
            if data.first.map({ $0 >= 0xFB }) == true { return }
            self.noteVideoArrival()
            self.decoder.feed(data)
            DispatchQueue.main.async {
                guard self.meshSessionID == sessionID, self.activeRoute == .mesh else { return }
                self.framesReceived = self.decoder.frameCount
                if self.phase != .live { self.phase = .live }
            }
        }

        // Outgoing audio: mic → 16k PCM → UDP (mute drops packets at source)
        audio.onPacket = { [weak self] pkt in
            guard let self,
                  self.meshSessionID == sessionID,
                  !self.isMuted else { return }
            self.transport.sendAudio(pkt)
        }
        // Audio levels -> meters (peak-hold with decay so bars don't flicker)
        audio.onTxLevel = { [weak self] lvl in
            DispatchQueue.main.async {
                guard let self, self.meshSessionID == sessionID else { return }
                self.txLevel = max(lvl, self.txLevel * 0.8)
            }
        }
        audio.onRxLevel = { [weak self] lvl in
            DispatchQueue.main.async {
                guard let self, self.meshSessionID == sessionID else { return }
                #if DEBUG
                if self.debugE2EPlan != nil {
                    self.debugE2EAudioPacketsReceived += 1
                }
                #endif
                self.rxLevel = max(lvl, self.rxLevel * 0.8)
            }
        }
        // Incoming + local mic PCM → recorder (mixed) while recording.
        audio.onRxPCM = { [weak self] pcm in
            guard let self,
                  self.meshSessionID == sessionID,
                  self.isRecording else { return }
            self.recorder.appendAudio(pcm)
        }
        audio.onTxPCM = { [weak self] pcm in
            guard let self,
                  self.meshSessionID == sessionID,
                  self.isRecording else { return }
            self.recorder.pushLocalAudio(pcm)
        }
        // Off the main path: first touch of the mic can block on permission /
        // session init, and audio must never hold up transport/video startup.
        if media.audio {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }
        }

        // Outgoing: camera → H.264 → UDP
        if media.video {
            camera.onFrame = { [weak self] h264Data, _ in
                guard let self, self.meshSessionID == sessionID else { return }
                self.transport.send(h264Data)
                self.bytesSent += h264Data.count
                DispatchQueue.main.async {
                    guard self.meshSessionID == sessionID else { return }
                    self.framesSent += 1
                }
            }
            camera.start()
        } else {
            camera.onFrame = nil
            camera.stop()
            camera.stopAll()
        }

        // Metrics timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                guard self.meshSessionID == sessionID else { return }
                self.txKBps = Double(self.bytesSent) / 1024
                self.rxKBps = Double(self.bytesRecv) / 1024
            }
        }

        startABR()

        let timeout = internetFallbackTarget == nil
            ? 30
            : CallRoutePolicy.automaticMeshProbeTimeout +
                CallRoutePolicy.automaticMeshControlGrace
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self,
                  self.meshSessionID == sessionID,
                  self.meshAttemptID == attemptID,
                  self.phase == .connecting else { return }
            if let target = internetFallbackTarget {
                if self.outboundMeshAccepted {
                    let remaining = max(0,
                        CallRoutePolicy.automaticAcceptedMeshTimeout - timeout)
                    NSLog("TRINET: peer accepted signed local call; allowing %.0fs for secure session",
                          remaining)
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                        self?.fallbackAutomaticMeshCall(target: target,
                                                        sessionID: sessionID,
                                                        attemptID: attemptID)
                    }
                    return
                }
                self.fallbackAutomaticMeshCall(target: target,
                                               sessionID: sessionID,
                                               attemptID: attemptID)
                return
            }
            self.callError = "The local peer did not accept the call within 30 seconds."
            self.stopCall()
        }
    }

    private func fallbackAutomaticMeshCall(target: String,
                                           sessionID: UUID,
                                           attemptID: UUID) {
        guard meshSessionID == sessionID,
              meshAttemptID == attemptID,
              phase == .connecting else { return }
        NSLog("TRINET: local secure session to %@ was not established; falling back to Internet",
              target)
        callee = target
        callStartedAt = nil
        stopCall()
        callError = nil
        activeRoute = .internet
        startInternetCall()
    }

    private func sendMeshCancellation(_ target: MeshCallCancellationTarget?) {
        guard let target else { return }
        do {
            try directory.sendMeshControl(.cancelled,
                                          callID: target.callID,
                                          recipientDeviceID: target.recipientDeviceID,
                                          to: target.address,
                                          port: target.port)
        } catch {
            NSLog("TRINET: local route cancellation failed: %@",
                  error.localizedDescription)
        }
    }

    // Group conference: full-mesh to all hosts under the conference key. onDataFrom routes by source
    // IP so each remote decodes into its own tile. Mirrors the 1-1 startCall's capture/encode path.
    private func startGroupCall(hosts: [String],
                                sessionID: UUID,
                                media: InternetCallMedia) {
        transport.connectGroup(hosts: hosts, port: 7000, recvPort: 7000)
        startBWE()

        // Incoming, routed by SOURCE (onDataFrom is delivered on the main queue by the transport):
        transport.onDataFrom = { [weak self] data, src in
            guard let self, self.meshSessionID == sessionID else { return }
            self.bytesRecv += data.count
            if data.count == 2, data[0] == 0xFC { self.camera.forceKeyframe(); return }        // PLI
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD { self.audio.playPacket(data.subdata(in: 2..<data.count)); return }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xC0 { self.audio.playOpus(data.subdata(in: 2..<data.count)); return }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA {
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                self.chat.append(ChatLine(who: .them, text: msg)); self.chatChime.play(); if !self.chatOpen { self.unreadChat += 1 }; return
            }
            if data.count == 6, data[0] == 0xFD, data[1] == 0xBE { self.handleBWEReport(data); return }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC {   // reaction — handled 1-1 but the group MVP guard
                self.showReaction(String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)); return   // below dropped it
            }
            if data.count > 1, data[0] >= 0xFB { return }   // other control -> ignore in group MVP
            self.noteVideoArrival()
            // video: decode into THIS sender's tile
            let dec = self.groupDecoders[src] ?? {
                let d = H264Decoder(); self.groupDecoders[src] = d
                if !self.roster.contains(src) { self.roster.append(src) }
                d.onKeyframeNeeded = { [weak self] in
                    guard let self, self.meshSessionID == sessionID else { return }
                    self.transport.send(Data([0xFC, 0x00]))
                }
                NSLog("TRINET: GROUP video from \(src)")   // receiving from a peer
                return d
            }()
            dec.feed(data)
            self.groupTick &+= 1
            if self.phase != .live { self.phase = .live }
        }

        // Outgoing audio + video fan out to ALL peers (rawSend fans out in group mode).
        audio.onPacket = { [weak self] pkt in
            guard let self,
                  self.meshSessionID == sessionID,
                  !self.isMuted else { return }
            self.transport.sendAudio(pkt)
        }
        audio.onTxLevel = { [weak self] lvl in
            DispatchQueue.main.async {
                guard let self, self.meshSessionID == sessionID else { return }
                self.txLevel = max(lvl, self.txLevel * 0.8)
            }
        }
        audio.onRxLevel = { [weak self] lvl in
            DispatchQueue.main.async {
                guard let self, self.meshSessionID == sessionID else { return }
                self.rxLevel = max(lvl, self.rxLevel * 0.8)
            }
        }
        if media.audio {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }
        }

        if media.video {
            camera.onFrame = { [weak self] h264Data, _ in
                guard let self, self.meshSessionID == sessionID else { return }
                self.transport.send(h264Data)
                self.bytesSent += h264Data.count
                DispatchQueue.main.async {
                    guard self.meshSessionID == sessionID else { return }
                    self.framesSent += 1
                }
            }
            camera.start()
            camera.reduceForGroup(peers: hosts.count)
        } else {
            camera.onFrame = nil
            camera.stop()
            camera.stopAll()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                guard self.meshSessionID == sessionID else { return }
                self.txKBps = Double(self.bytesSent) / 1024
                self.rxKBps = Double(self.bytesRecv) / 1024
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.meshSessionID == sessionID else { return }
            if self.phase == .connecting { self.phase = .live }
        }
    }

    func stopCall() {
        let completedMeshCall = activeRoute == .mesh && phase == .live
        let cancellationTarget = MeshCallCancellationPolicy.target(
            outbound: outboundMeshControl,
            outboundPort: outboundMeshControlPort,
            inbound: acceptedIncomingMeshCall
        )
        sendMeshCancellation(cancellationTarget)
        internetAttemptID = nil
        internetCallTask?.cancel()
        internetCallTask = nil
        outgoingInternetAwaitingRemote = false
        internetAnswerTimer?.invalidate()
        internetAnswerTimer = nil
        pendingInternetVideo = false
        meshSessionID = nil
        meshAttemptID = nil
        outboundMeshControl = nil
        outboundMeshControlPort = nil
        outboundMeshAccepted = false
        acceptedIncomingMeshCall = nil
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
        // A secure audio-only call has no video frames, so the authenticated
        // transport state is the completion signal for its journal entry.
        if let started = callStartedAt,
           completedMeshCall || framesReceived > 0 || framesSent > 0 {
            let dur = Int(Date().timeIntervalSince(started))
            let avgB = bitrateHistory.isEmpty ? bitrateKbps : bitrateHistory.reduce(0, +) / bitrateHistory.count
            let avgJ = jitterHistory.isEmpty ? peerJitterMs : jitterHistory.reduce(0, +) / jitterHistory.count
            recentCalls.insert(CallRecord(peer: remoteIP, at: started, durationSec: dur, avgKbps: avgB, avgJitterMs: avgJ, stalls: callStalls), at: 0)
            if recentCalls.count > 8 { recentCalls.removeLast() }
        }
        callStartedAt = nil
        noAnswerTimer?.invalidate(); noAnswerTimer = nil; noAnswer = false
        bweTimer?.invalidate(); bweTimer = nil
        lastVideoArrival = nil; meanGapMs = 0; jitterMs = 0; rxPktsThisSec = 0; highJitterStreak = 0; cleanStreak = 0; peerJitterMs = 0
        lossStreak = 0; lastFramesSentSample = 0
        safetyNumber = nil; mitmWarning = false
        bitrateHistory = []; jitterHistory = []; linkHealth = .good; linkRestored = false; lastRecoveryAt = nil; stalledSince = nil
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
        isGroup = false; roster = []; groupDecoders.removeAll()
        discovery.inCall = false
        timer?.invalidate(); timer = nil
        abrTimer?.invalidate(); abrTimer = nil
        phase = .idle
        framesSent = 0; framesReceived = 0
        activeMeshMedia = .audioVideo
        rxFps = 0; rxHeight = 0; rxSources = 0; lastRxFrameCount = 0; rxFrozenSince = nil
        bytesSent = 0; bytesRecv = 0
        txKBps = 0; rxKBps = 0
        activeRoute = nil
        startIdleListener()   // resume listening for incoming mesh calls
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
        return MeshAddressPolicy.isNumericIPv4(address)
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
