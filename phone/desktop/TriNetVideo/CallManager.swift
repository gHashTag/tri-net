// CallManager.swift — Orchestrates camera → encode → transport → decode → display
import Foundation
import Combine
import AVFoundation
import AudioToolbox
import AppKit
import CoreVideo

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

class CallManager: ObservableObject {
    @Published var isInCall = false
    @Published var isStarting = false
    @Published var remoteIP = "192.168.1.103"
    @Published var port = "7000"
    @Published var localIP = ""
    @Published var framesSent = 0
    @Published var framesReceived = 0
    @Published var status = "Ready"
    @Published var error: String?
    @Published var isMuted = false
    @Published var cameraOff = false { didSet { camera.blackout = cameraOff } }  // off => send BLACK frames, not a freeze
    @Published var unreadChat = 0                       // badge count on the chat icon
    var chatOpen = false { didSet { if chatOpen { unreadChat = 0 } } }  // panel open => clear the badge
    private let chatChime = ChatChime()                 // Trinity-style blip on an incoming chat message
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
            // Rolling 60s history for the tap-to-expand link-quality sparkline.
            self.bitrateHistory.append(self.bitrateKbps); if self.bitrateHistory.count > 60 { self.bitrateHistory.removeFirst() }
            self.jitterHistory.append(self.peerJitterMs); if self.jitterHistory.count > 60 { self.jitterHistory.removeFirst() }
            self.evalLinkHealth()
        }
    }
    @Published var bitrateHistory: [Int] = []   // last 60s, for the link-quality sparkline
    @Published var jitterHistory: [Int] = []

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
        let next = LinkHealth.classify(framesFlowed: isInCall && framesReceived > 0,
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
            if plan.dropToFloor { camera.nudgeBitrate(down: true) }   // prolonged stall: trade resolution for reach
            NSLog("TRINET: stall %dms — requested keyframe%@", stalledMs, plan.dropToFloor ? " + dropped to floor" : "")
        }
        if prev != .stalled, next == .stalled { callStalls += 1 }   // count stalls for the call journal
        if prev == .stalled, next == .good {   // recovered — flash it, then clear
            linkRestored = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.linkRestored = false }
        }
        linkHealth = next
    }



    // Honest link reporting + the app's own log, live in the UI.
    // Both are plain references — the views observe them directly.
    let link = LinkStatus()
    let log = LogBus.shared

    // Local-network presence: advertise ourselves + browse for TRI-NET peers so the user picks people
    // by NAME instead of typing IPs. Resolves the tapped peer to an IP for the existing transport.
    let discovery = PeerDiscovery()
    @Published var selectedUIDs: Set<String> = []

    init() {
        LogBus.shared.start()   // tee stderr (where every NSLog lands) into the UI
        localIP = MeshTransport.getLocalIP()
        // Load recent IPs from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: "recentIPs") as? [String] {
            recentIPs = saved
        }
        cameras = CameraCapture.availableCameras()
        selectedCameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID ?? ""
        discovery.start()   // advertise + browse from launch
        startIdleListener() // listen on :7000 for incoming calls while idle
    }

    // MARK: - Incoming call ("take the call")
    // A caller sends a tiny plaintext INVITE datagram to our :7000; while idle we hold a light listener
    // there and pop a ringing screen. The listener is torn down the moment a call starts (the encrypted
    // transport then owns :7000) and restarted when the call ends.
    struct IncomingCall: Equatable { let name: String; let ip: String; let participants: [String] }
    @Published var incomingCall: IncomingCall?
    // Missed calls: an incoming that timed out unanswered (NOT a decline — that was a choice). Newest first.
    // Persisted across restarts so you don't lose "who called while I was away".
    struct MissedCall: Identifiable, Equatable, Codable { var id = UUID(); let name: String; let ip: String; let at: Date }
    @Published var missedCalls: [MissedCall] = CallManager.loadMissed() { didSet { CallManager.saveMissed(missedCalls) } }
    private static let missedKey = "trinetMissedCalls"
    private static func loadMissed() -> [MissedCall] {
        guard let d = UserDefaults.standard.data(forKey: missedKey),
              let arr = try? JSONDecoder().decode([MissedCall].self, from: d) else { return [] }
        return arr
    }
    private static func saveMissed(_ m: [MissedCall]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: missedKey) }
    }
    private var noAnswerTimer: Timer?

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
    @Published var recentCalls: [CallRecord] = CallManager.loadRecents() { didSet { CallManager.saveRecents(recentCalls) } }
    private static let recentsKey = "trinetRecentCalls"
    private static func loadRecents() -> [CallRecord] {
        guard let d = UserDefaults.standard.data(forKey: recentsKey),
              let a = try? JSONDecoder().decode([CallRecord].self, from: d) else { return [] }
        return a
    }
    private static func saveRecents(_ r: [CallRecord]) {
        if let d = try? JSONEncoder().encode(r) { UserDefaults.standard.set(d, forKey: recentsKey) }
    }
    // Tab-separated journal for export (link-quality diagnostics the user can paste anywhere).
    var callJournalText: String {
        let head = "peer\tstarted\tduration_s\tavg_kbps\tavg_jitter_ms\tstalls"
        let rows = recentCalls.map { "\($0.peer)\t\(ISO8601DateFormatter().string(from: $0.at))\t\($0.durationSec)\t\($0.avgKbps)\t\($0.avgJitterMs)\t\($0.stalls)" }
        return ([head] + rows).joined(separator: "\n")
    }
    func copyJournal() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(callJournalText, forType: .string)
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

    // MARK: - Delay-based BWE (receiver report)
    // The RECEIVER measures inter-arrival jitter of video datagrams (RFC3550-style EMA: J += (|D|-J)/16) and
    // reports it once a second in a tiny control packet [0xFD 0xBE jitterMsBE:2 pktsBE:2]. The SENDER backs its
    // bitrate off when the peer's jitter RISES — the queue is building — BEFORE any packet is lost. This is
    // the delay-based half of GCC; the loss-based AIMD (PLI) remains the hard trigger.
    private var lastVideoArrival: Date?
    private var meanGapMs = 0.0        // EMA of inter-arrival gap
    private var jitterMs = 0.0         // EMA of |gap - meanGap|
    private var rxPktsThisSec = 0
    private var bweTimer: Timer?
    private var highJitterStreak = 0
    @Published var peerJitterMs = 0    // what the far end reports (drives our sender)

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
            guard let self = self, self.isInCall else { return }
            // Report OUR receive-side jitter to the sender (they steer their encoder with it).
            let j = UInt16(min(65535, max(0, Int(self.jitterMs))))
            let p = UInt16(min(65535, self.rxPktsThisSec))
            self.rxPktsThisSec = 0
            var pkt = Data([0xFD, 0xBE])
            pkt.append(contentsOf: [UInt8(j >> 8), UInt8(j & 0xFF), UInt8(p >> 8), UInt8(p & 0xFF)])
            self.transport.send(pkt)
        }
    }

    // Sender side: the peer's report arrived — react to a rising queue before loss does.
    private func handleBWEReport(_ data: Data) {
        let j = Int(data[2]) << 8 | Int(data[3])
        DispatchQueue.main.async {
            self.peerJitterMs = j
            if j > 40 {           // sustained queueing at the receiver
                self.highJitterStreak += 1
                self.cleanStreak = 0
                if self.highJitterStreak >= 2 {
                    self.camera.nudgeBitrate(down: true)
                    NSLog("TRINET: BWE back-off — peer jitter \(j)ms")
                }
            } else if j < 20 {    // GCC probe-up: confirmed spare capacity -> an EXTRA climb tick (on the real
                self.highJitterStreak = 0   // stream, never padding bursts — the mesh's pacing is fragile).
                self.cleanStreak += 1       // Overshoot is caught instantly by the back-off above.
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
    private var cleanStreak = 0   // consecutive low-jitter reports, for GCC probe-up
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
        // changes. Without it, POSIX close() may not interrupt recvfrom, the loop hangs on the serial queue,
        // and the NEXT startIdleListener()'s loop is stuck behind it — incoming calls die after call #1.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CallManager.invitePort.bigEndian
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
                guard n >= 2, buf[0] == CallManager.inviteMagic[0], buf[1] == CallManager.inviteMagic[1] else { continue }
                // payload = "name\nip1,ip2,ip3" — the full participant list lets Accept rebuild the whole mesh.
                let payload = n > 2 ? (String(bytes: buf[2..<Int(n)], encoding: .utf8) ?? "") : ""
                let parts = payload.components(separatedBy: "\n")
                let name = (parts.first?.isEmpty == false) ? parts[0] : "TRI-NET"
                let participants = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                // Spam-hardening: a REAL INVITE always carries the caller's IP list ([myIP] + hosts, >= 1).
                // A payload with no participants (a 2-byte magic-only or empty-field datagram) can't be a call
                // -- reject it so any LAN host can't pop the incoming-call UI (and block real INVITEs for 40s).
                guard !participants.isEmpty else { continue }
                let room = parts.count > 2 ? parts[2] : ""
                let ip = String(cString: inet_ntoa(from.sin_addr))
                DispatchQueue.main.async {
                    guard let self = self, !self.isInCall, self.incomingCall == nil else { return }  // don't ring mid-call / twice
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
            var pkt = CallManager.inviteMagic; pkt.append(contentsOf: Array(payload.utf8))
            for ip in ips where !ip.isEmpty {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = CallManager.invitePort.bigEndian
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

    // Callee taps "Accept": call the caller back → bidirectional (full-mesh, each side sends its own media).
    func acceptIncoming() {
        guard let inc = incomingCall else { return }
        incomingTimer?.invalidate(); incomingCall = nil
        // Rebuild the exact call: caller + every other participant, minus myself. A 1-1 invite carries only
        // {caller, me}, so this collapses to a plain 1-1 back to the caller.
        var mesh = Set(inc.participants); mesh.insert(inc.ip); mesh.remove(localIP)
        let hosts = mesh.filter { !$0.isEmpty }.sorted()
        remoteIP = hosts.isEmpty ? inc.ip : hosts.joined(separator: ",")
        NSLog("TRINET: accepting call -> mesh back to \(remoteIP)")
        startCall()
    }
    func declineIncoming() { incomingTimer?.invalidate(); incomingCall = nil }

    func toggleSelect(_ uid: String) {
        if selectedUIDs.contains(uid) { selectedUIDs.remove(uid) } else { selectedUIDs.insert(uid) }
        syncPeerFieldToSelection()
    }

    // UX: ticking peers auto-fills the PEER field with their resolved IPs (comma-joined), so you never type
    // "ip1, ip2" by hand — just check the boxes and hit Start Call (or Group call). Unchecking all leaves the
    // field alone (you may have typed something manually).
    private func syncPeerFieldToSelection() {
        let sel = discovery.peers.filter { selectedUIDs.contains($0.uid) }
        guard !sel.isEmpty else { return }
        var ips: [String] = []
        let g = DispatchGroup()
        for p in sel { g.enter(); discovery.resolveIP(p) { ip in if let ip = ip, !ip.isEmpty { ips.append(ip) }; g.leave() } }
        g.notify(queue: .main) { [weak self] in
            guard let self = self, !ips.isEmpty else { return }
            self.remoteIP = ips.sorted().joined(separator: ", ")
            NSLog("TRINET: selection -> peer field '\(self.remoteIP)'")
        }
    }

    // Tap one discovered peer: resolve its Bonjour endpoint to an IP, then place a 1-1 call.
    func callPeer(_ peer: PeerDiscovery.Peer) {
        discovery.resolveIP(peer) { [weak self] ip in
            guard let self = self, let ip = ip, !ip.isEmpty else { NSLog("TRINET: could not resolve \(peer.name)"); return }
            // A roster entry can be ANOTHER APP ON THIS MACHINE (e.g. the iOS Simulator) — it resolves to our
            // own IP and "calling" it is a self-call that floods undecryptable-datagram noise. Refuse loudly.
            // (Typing 127.0.0.1 by hand stays allowed — that's a deliberate loopback test.)
            if ip == self.localIP {
                self.status = "\(peer.name) is this machine — not calling myself"
                NSLog("TRINET: refusing self-call — '\(peer.name)' resolved to our own IP \(ip)")
                return
            }
            self.remoteIP = ip
            self.startCall()
        }
    }

    // Room mode: call EVERYONE currently visible (they share your room code) in one group.
    func callEveryone() {
        selectedUIDs = Set(discovery.peers.map { $0.uid })
        startGroupFromSelection()
    }

    // Multi-select -> group: resolve every selected peer, then call the comma-joined IP list.
    func startGroupFromSelection() {
        let sel = discovery.peers.filter { selectedUIDs.contains($0.uid) }
        guard !sel.isEmpty else { return }
        var ips: [String] = []
        let g = DispatchGroup()
        for p in sel { g.enter(); discovery.resolveIP(p) { ip in if let ip = ip, !ip.isEmpty { ips.append(ip) }; g.leave() } }
        g.notify(queue: .main) { [weak self] in
            guard let self = self, !ips.isEmpty else { return }
            self.remoteIP = ips.joined(separator: ",")
            self.selectedUIDs = []
            self.startCall()
        }
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
        var d = Data([0xFB, 0xCA]); d.append(Data(t.utf8))
        transport.send(d)
        chat.append(ChatLine(who: .me, text: t))
    }

    func sendReaction(_ emoji: String) {
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
                // If the capture fails (usually the Screen Recording permission), REVERT so the camera resumes
                // instead of leaving a black call (camera suppressed + no screen frames).
                sc.onStarted = { [weak self] ok, msg in
                    guard let self = self else { return }
                    if ok { NSLog("TRINET: screen share ON") }
                    else {
                        self.isScreenSharing = false
                        self.status = "Screen share needs permission — enable TRI-NET Monitor, then restart"
                        NSLog("%@", "TRINET: screen share NOT started — \(msg ?? "")")
                        // Jump the user straight to the Screen Recording pane so they can flip the toggle.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                sc.start()
                isScreenSharing = true  // camera guard stops sending its NALs (reverted above on failure)
            }
        } else {
            NSLog("TRINET: screen share needs macOS 12.3+")
        }
    }

    func startCall() {
        guard let p = UInt16(port) else { NSLog("TRINET: invalid port"); return }
        NSLog("TRINET: startCall to \(remoteIP):\(p)")
        isStarting = true
        status = "Connecting to \(remoteIP)..."
        stopIdleListener()   // the encrypted transport is about to own :7000

        // Save IP to recent
        if !recentIPs.contains(remoteIP) {
            recentIPs.insert(remoteIP, at: 0)
            if recentIPs.count > 5 { recentIPs.removeLast() }
            UserDefaults.standard.set(recentIPs, forKey: "recentIPs")
        }

        // Camera → Encoder → Transport (suppressed while screen sharing). Camera-off keeps flowing: the
        // encoder now emits BLACK frames (blackout), so the peer sees black instead of a frozen last frame.
        camera.onNALUnit = { [weak self] nal in
            guard let self = self, !self.isScreenSharing else { return }
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
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)); self.chatChime.play(); if !self.chatOpen { self.unreadChat += 1 } }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction emoji
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
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
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)); self.chatChime.play(); if !self.chatOpen { self.unreadChat += 1 } }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC {
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            if data.count == 6, data[0] == 0xFD, data[1] == 0xBE { self.handleBWEReport(data); return }
            // Doctrine: NEVER hand an unknown control subtype to the H.264 decoder. Real NALs start 00 00 00 01.
            if data.first.map({ $0 >= 0xFB }) == true { return }
            self.noteVideoArrival()
            // Video → per-source decoder
            let dec = self.groupDecoders[ip] ?? {
                let d = VideoDecoder(); self.groupDecoders[ip] = d
                NSLog("TRINET: GROUP video from \(ip) — now \(self.groupDecoders.count) source(s)")
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
        } else {
            isGroup = false
            transport.connect(peerHost: remoteIP, peerPort: p, listenPort: p)
        }
        let hostStrs = hosts.map { String($0) }
        sendInvite(to: hostStrs, participants: [localIP] + hostStrs)   // ring the callee(s); carry the full roster

        isInCall = true
        callStartedAt = Date()     // for the recent-call journal duration
        callStalls = 0
        discovery.inCall = true    // advertise "in call" so the roster shows my status
        isStarting = false
        status = "Calling \(remoteIP)…"
        // Caller-side ring feedback: if nothing arrives in 30s, say so instead of "Waiting" forever.
        noAnswerTimer?.invalidate()
        noAnswerTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self = self, self.isInCall, self.framesReceived == 0 else { return }
            self.status = "No answer"
            NSLog("TRINET: no answer from \(self.remoteIP) after 30s")
        }
        startABR()
        startBWE()
        link.begin(peer: hosts.first ?? remoteIP)
    }

    func endCall() {
        // Journal a COMPLETED call (frames actually flowed) with its duration + average link quality,
        // BEFORE the history arrays are reset below.
        if let started = callStartedAt, framesReceived > 0 || framesSent > 0 {
            let dur = Int(Date().timeIntervalSince(started))
            let avgB = bitrateHistory.isEmpty ? bitrateKbps : bitrateHistory.reduce(0, +) / bitrateHistory.count
            let avgJ = jitterHistory.isEmpty ? peerJitterMs : jitterHistory.reduce(0, +) / jitterHistory.count
            recentCalls.insert(CallRecord(peer: remoteIP, at: started, durationSec: dur, avgKbps: avgB, avgJitterMs: avgJ, stalls: callStalls), at: 0)
            if recentCalls.count > 8 { recentCalls.removeLast() }
        }
        callStartedAt = nil
        noAnswerTimer?.invalidate(); noAnswerTimer = nil
        if #available(macOS 12.3, *) { (screen as? ScreenCapture)?.stop() }
        isScreenSharing = false
        if isRecording { recorder.stop { [weak self] url in self?.lastRecordingPath = url?.path }; isRecording = false; recSink = nil }
        abrTimer?.invalidate(); abrTimer = nil
        bweTimer?.invalidate(); bweTimer = nil
        lastVideoArrival = nil; meanGapMs = 0; jitterMs = 0; rxPktsThisSec = 0; highJitterStreak = 0; cleanStreak = 0; peerJitterMs = 0
        bitrateHistory = []; jitterHistory = []; linkHealth = .good; linkRestored = false; lastRecoveryAt = nil; stalledSince = nil
        link.end()
        camera.stop()
        audio.stop()
        transport.disconnect()
        isInCall = false
        discovery.inCall = false
        isGroup = false
        roster = []
        groupDecoders = [:]
        lastSeen = [:]
        status = "Idle"
        framesSent = 0
        framesReceived = 0
        previewSession = nil
        startIdleListener()   // resume listening for incoming calls
    }
}
