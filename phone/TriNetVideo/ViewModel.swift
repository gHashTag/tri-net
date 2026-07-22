// ViewModel.swift — Direct Mac↔iPhone video call via BSD UDP
import SwiftUI
import AVFoundation
import AudioToolbox
import Combine

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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trinet-chat-chime.caf")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: buf); return url }
        catch { NSLog("TRINET: chat chime render failed: \(error)"); return nil }
    }
}

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
    @Published var cameraOff = false { didSet { camera.blackout = cameraOff } }  // off => send BLACK frames, not a freeze
    @Published var unreadChat = 0                       // badge count on the chat icon
    var chatOpen = false { didSet { if chatOpen { unreadChat = 0 } } }  // panel open => clear the badge
    private let chatChime = ChatChime()                 // Trinity-style blip on an incoming chat message
    @Published var recentIPs: [String] = []
    // Live audio levels (0...1) for the TX/RX meters, peak-held with decay.
    @Published var txLevel: Float = 0
    @Published var rxLevel: Float = 0
    // Chat + reactions (shown live on both ends)
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?
    @Published var isBlurred = false
    // RTI fusion: camera slew directive from the mesh (RTI detected object).
    @Published var rtiSlewAngle: Int = 0
    @Published var rtiSlewDirection: String = "none"
    @Published var rtiSlewActive: Bool = false

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
        discovery.start()   // advertise + browse from launch
        startIdleListener() // listen on :7000 for incoming mesh calls while idle
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
    @Published var peerJitterMs = 0
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
        DispatchQueue.main.async {
            self.peerJitterMs = j
            if j > 40 {
                self.highJitterStreak += 1
                self.cleanStreak = 0
                if self.highJitterStreak >= 2 {
                    self.camera.nudgeBitrate(down: true)
                    NSLog("TRINET: BWE back-off — peer jitter \(j)ms")
                }
            } else if j < 20 {    // GCC probe-up: confirmed spare capacity -> an EXTRA climb tick (real stream,
                self.highJitterStreak = 0   // never padding bursts). Overshoot is caught instantly by back-off.
                self.cleanStreak += 1
                if self.cleanStreak >= 3 {
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
                guard n >= 2, buf[0] == StreamViewModel.inviteMagic[0], buf[1] == StreamViewModel.inviteMagic[1] else { continue }
                // payload = "name\nip1,ip2,ip3" — the full participant list lets Accept rebuild the whole mesh.
                let payload = n > 2 ? (String(bytes: buf[2..<Int(n)], encoding: .utf8) ?? "") : ""
                let parts = payload.components(separatedBy: "\n")
                let name = (parts.first?.isEmpty == false) ? parts[0] : "TRI-NET"
                let participants = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                let room = parts.count > 2 ? parts[2] : ""
                let ip = String(cString: inet_ntoa(from.sin_addr))
                DispatchQueue.main.async {
                    guard let self = self, self.phase == .idle, self.incomingCall == nil else { return }  // don't ring mid-call / twice
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
        // payload = "name\nip1,ip2\nROOM" — the room lets a same-room callee auto-accept (one-tap group).
        let payload = PeerDiscovery.myName + "\n" + participants.joined(separator: ",") + "\n" + PeerDiscovery.myRoom
        NSLog("TRINET: ringing \(ips.joined(separator: ",")) with INVITE (participants: \(participants.joined(separator: ",")))")
        // MUST NOT use idleQueue: startCall() just closed the idle socket, but a blocked recvfrom on that
        // serial queue may not wake (POSIX close() doesn't reliably interrupt it), which would leave the
        // INVITE stuck in the queue forever — the callee never rings. A fresh queue always runs.
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var pkt = StreamViewModel.inviteMagic; pkt.append(contentsOf: Array(payload.utf8))
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
        startCall()
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
        callStartedAt = Date()    // for the recent-call journal duration
        callStalls = 0
        discovery.inCall = true   // advertise "in call" in the roster
        stopIdleListener()        // the encrypted transport is about to own :7000
        // Caller-side ring feedback: if nothing arrives in 30s, say "No answer" instead of connecting forever.
        noAnswer = false
        noAnswerTimer?.invalidate()
        noAnswerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self, self.phase != .idle, self.framesReceived == 0 else { return }
            self.noAnswer = true
            NSLog("TRINET: no answer from \(self.remoteIP) after 30s")
        }

        // Several IPs (comma/space) => group conference; one IP => normal 1-1 (untouched path).
        let hosts = remoteIP.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        sendInvite(to: hosts, participants: [myIP] + hosts)   // ring the callee(s); carry the full roster
        if hosts.count > 1 { isGroup = true; startGroupCall(hosts: hosts); return }
        isGroup = false
        let attemptID = UUID()
        meshAttemptID = attemptID

        // UDP: send to remoteIP:7000, listen on 7000 (same port for both)
        transport.onSecureSessionReady = { [weak self] in
            guard let self, self.meshAttemptID == attemptID else { return }
            self.meshAttemptID = nil
            self.phase = .live
        }
        transport.connect(host: remoteIP, port: 7000, recvPort: 7000)
        startBWE()

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
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)); self.chatChime.play(); if !self.chatOpen { self.unreadChat += 1 } }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            if data.count >= 5, data[0] == 0xFD, data[1] == 0x53, data[2] == 0x4C { // SLEW command (RTI fusion)
                // Format: [0xFD 0x53 0x4C][slew_angle u16 LE][direction u8]
                let slew = UInt16(data[3]) | (UInt16(data[4]) << 8)
                let dirByte: UInt8 = data.count >= 6 ? data[5] : 2
                let dirName = dirByte == 0 ? "CCW" : dirByte == 1 ? "CW" : "none"
                DispatchQueue.main.async {
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
            // Doctrine: NEVER hand an unknown control subtype to the H.264 decoder. Real NALs start 00 00 00 01.
            if data.first.map({ $0 >= 0xFB }) == true { return }
            self.noteVideoArrival()
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
            guard let self = self else { return }   // camera-off sends BLACK frames (blackout), so don't skip
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

    // Group conference: full-mesh to all hosts under the conference key. onDataFrom routes by source
    // IP so each remote decodes into its own tile. Mirrors the 1-1 startCall's capture/encode path.
    private func startGroupCall(hosts: [String]) {
        transport.connectGroup(hosts: hosts, port: 7000, recvPort: 7000)
        startBWE()

        // Incoming, routed by SOURCE (onDataFrom is delivered on the main queue by the transport):
        transport.onDataFrom = { [weak self] data, src in
            guard let self = self else { return }
            self.bytesRecv += data.count
            if data.count == 2, data[0] == 0xFC { self.camera.forceKeyframe(); return }        // PLI
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD { self.audio.playPacket(data.subdata(in: 2..<data.count)); return }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xC0 { self.audio.playOpus(data.subdata(in: 2..<data.count)); return }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA {
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                self.chat.append(ChatLine(who: .them, text: msg)); self.chatChime.play(); if !self.chatOpen { self.unreadChat += 1 }; return
            }
            if data.count == 6, data[0] == 0xFD, data[1] == 0xBE { self.handleBWEReport(data); return }
            if data.count > 1, data[0] >= 0xFB { return }   // other control -> ignore in group MVP
            self.noteVideoArrival()
            // video: decode into THIS sender's tile
            let dec = self.groupDecoders[src] ?? {
                let d = H264Decoder(); self.groupDecoders[src] = d
                if !self.roster.contains(src) { self.roster.append(src) }
                d.onKeyframeNeeded = { [weak self] in self?.transport.send(Data([0xFC, 0x00])) }
                NSLog("TRINET: GROUP video from \(src)")   // receiving from a peer
                return d
            }()
            dec.feed(data)
            self.groupTick &+= 1
            if self.phase != .live { self.phase = .live }
        }

        // Outgoing audio + video fan out to ALL peers (rawSend fans out in group mode).
        audio.onPacket = { [weak self] pkt in
            guard let self = self, !self.isMuted else { return }
            self.transport.sendAudio(pkt)
        }
        audio.onTxLevel = { [weak self] lvl in DispatchQueue.main.async { self?.txLevel = max(lvl, (self?.txLevel ?? 0) * 0.8) } }
        audio.onRxLevel = { [weak self] lvl in DispatchQueue.main.async { self?.rxLevel = max(lvl, (self?.rxLevel ?? 0) * 0.8) } }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }

        camera.onFrame = { [weak self] h264Data, _ in
            guard let self = self else { return }   // camera-off sends BLACK frames (blackout), so don't skip
            self.transport.send(h264Data)
            self.bytesSent += h264Data.count
            DispatchQueue.main.async { self.framesSent += 1 }
        }
        camera.start()
        camera.reduceForGroup(peers: hosts.count)   // split the uplink across the mesh

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                self.txKBps = Double(self.bytesSent) / 1024
                self.rxKBps = Double(self.bytesRecv) / 1024
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.phase == .connecting { self.phase = .live }
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
        // Journal a COMPLETED call (frames flowed) with duration + average link quality, before resets.
        if let started = callStartedAt, framesReceived > 0 || framesSent > 0 {
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
