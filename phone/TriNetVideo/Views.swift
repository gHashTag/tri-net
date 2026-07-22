// Views.swift — FaceTime-style video call UI for iOS
import SwiftUI
import AVFoundation
import AudioToolbox

// MARK: - Home Screen

struct HomeView: View {
    @StateObject var vm = StreamViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            if vm.phase == .live || vm.phase == .connecting {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                VStack(spacing: 22) {
                    HStack {
                        Text("TRI-NET").font(DS.display(22, .bold)).tracking(1).foregroundColor(DS.text)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape").font(.system(size: 18)).foregroundColor(DS.dim)
                                .frame(width: 42, height: 42).overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("Encrypted mesh · forward-secret")
                        .font(DS.ui(13)).foregroundColor(DS.dim)

                    Spacer()

                    // Primary call button — the one white CTA
                    Button(action: { vm.startCall() }) {
                        ZStack {
                            Circle().fill(vm.cameraAuthorized ? DS.fill : DS.surface)
                                .overlay(Circle().stroke(vm.cameraAuthorized ? Color.clear : DS.hairlineStrong, lineWidth: 1))
                                .frame(width: 128, height: 128)
                            Image(systemName: "video.fill").font(.system(size: 46))
                                .foregroundColor(vm.cameraAuthorized ? DS.onFill : DS.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.cameraAuthorized)

                    // Peer field
                    VStack(spacing: 14) {
                        HStack {
                            SectionLabel(text: "Peer")
                            TextField("Mac IP", text: $vm.remoteIP)
                                .keyboardType(.decimalPad).font(DS.mono(16)).foregroundColor(DS.text)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(DS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline, lineWidth: 1))

                        Text("SELF · \(vm.myIP)").font(DS.mono(12)).foregroundColor(DS.faint)

                        if !vm.recentIPs.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(vm.recentIPs.prefix(3), id: \.self) { ip in
                                    Button(action: { vm.remoteIP = ip }) {
                                        Text(ip).font(DS.mono(11)).foregroundColor(DS.dim)
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                                    }
                                }
                            }
                        }

                        iPeerRoster(vm: vm, discovery: vm.discovery)

                        // Missed calls — one-tap call back (newest first, capped at 5).
                        if !vm.missedCalls.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(vm.missedCalls) { m in
                                    HStack(spacing: 8) {
                                        Image(systemName: "phone.arrow.down.left").font(.system(size: 12)).foregroundColor(DS.danger)
                                        Text("Missed · \(m.name)").font(DS.ui(13)).foregroundColor(DS.text).lineLimit(1)
                                        Text(m.at, style: .time).font(DS.mono(10)).foregroundColor(DS.faint)
                                        Spacer()
                                        Button("Call back") { vm.remoteIP = m.ip; vm.startCall() }
                                            .font(DS.mono(12)).foregroundColor(.green)
                                    }
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(DS.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.hairline, lineWidth: 1))
                        }

                        // Recent-call journal: duration + average link quality of past completed calls.
                        if !vm.recentCalls.isEmpty {
                            VStack(spacing: 6) {
                                HStack {
                                    Text("RECENT").font(DS.mono(9)).foregroundColor(DS.faint).tracking(1)
                                    Spacer()
                                    if #available(iOS 16.0, *) {
                                        ShareLink(item: vm.callJournalText) {
                                            Text("Share log").font(DS.mono(9)).foregroundColor(DS.dim)
                                        }
                                    }
                                }
                                ForEach(vm.recentCalls.prefix(4)) { r in
                                    HStack(spacing: 8) {
                                        Image(systemName: "phone.connection").font(.system(size: 12)).foregroundColor(DS.dim)
                                        Text(r.peer).font(DS.mono(12)).foregroundColor(DS.text).lineLimit(1)
                                        Spacer()
                                        Text("\(r.durationSec/60)m\(String(format: "%02d", r.durationSec%60))s · \(r.avgKbps)k\(r.stalls > 0 ? " · ⚠︎\(r.stalls)" : "")")
                                            .font(DS.mono(10)).foregroundColor(r.avgJitterMs > 40 || r.stalls > 0 ? DS.danger : DS.faint)
                                        Button("Call") { vm.remoteIP = r.peer; vm.startCall() }
                                            .font(DS.mono(11)).foregroundColor(.green)
                                    }
                                }
                                // Aggregate stability across the whole journal.
                                let s = vm.callStats
                                Divider().overlay(DS.hairline)
                                HStack(spacing: 8) {
                                    Text("\(s.count) calls").font(DS.mono(9)).foregroundColor(DS.dim)
                                    Spacer()
                                    Text("avg \(s.avgDurationSec/60)m\(String(format: "%02d", s.avgDurationSec%60))s · \(s.avgKbps)k · \(s.totalStalls) stalls")
                                        .font(DS.mono(9)).foregroundColor(s.totalStalls > 0 ? DS.danger : DS.faint)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(DS.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.hairline, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Text(vm.cameraAuthorized ? "Tap to call" : "Camera access needed")
                        .font(DS.ui(13, .medium)).foregroundColor(vm.cameraAuthorized ? DS.dim : DS.text)
                        .padding(.bottom, 40)
                }
            }
        }
        // Incoming call: full-screen ringing takeover (iOS convention) with Accept/Decline.
        .overlay {
            if let inc = vm.incomingCall {
                IncomingCallOverlay(vm: vm, inc: inc).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.incomingCall)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: vm.phase)
        .onAppear { vm.checkPermission(); if vm.cameraAuthorized { vm.camera.startPreview() } }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
        .sheet(item: $vm.shareFile) { f in
            ShareSheet(items: [f.url])
        }
    }
}

// Wraps UIActivityViewController so a finished recording can be saved/sent.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// A distinctive SYNTHESIZED ring — three ascending chirps ("tri"-tone, fitting TRI-NET) + a gap, looped. Not a
// stock ringtone, so an incoming call is instantly recognizable. Sets the session to .playback so it sounds.
final class RingSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    init() {
        engine.attach(player)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        buffer = makeRing(fmt)
    }
    private func makeRing(_ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = 44100.0
        let notes: [(f: Double, dur: Double)] = [(659.25, 0.10), (987.77, 0.10), (1318.51, 0.16)]  // E5 B5 E6
        let gap = 0.55
        let total = notes.reduce(0) { $0 + $1.dur } + gap
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        var i = 0
        for n in notes {
            let cnt = Int(n.dur * sr)
            for k in 0..<cnt {
                let t = Double(k) / sr
                let env = sin(Double.pi * Double(k) / Double(cnt))
                p[i] = Float(0.34 * env * sin(2 * Double.pi * n.f * t)); i += 1
            }
        }
        while i < Int(frames) { p[i] = 0; i += 1 }
        return buf
    }
    func start() {
        guard let buffer = buffer else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }
    func stop() { player.stop(); engine.stop() }
}

// MARK: - Incoming call (full-screen ring + Accept/Decline)
// iOS convention: a full-screen takeover, caller identity top, two circular action buttons at the
// bottom — Decline (red, LEFT), Accept (green, RIGHT). Ring vibrates + plays the tri-tone until answered.
struct IncomingCallOverlay: View {
    @ObservedObject var vm: StreamViewModel
    let inc: StreamViewModel.IncomingCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var ringTimer: Timer?
    @State private var ring = RingSynth()

    private var initial: String { String(inc.name.prefix(1)).uppercased() }

    var body: some View {
        ZStack {
            DS.ink.opacity(0.98).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    // Two expanding rings — "ringing, live now" (Reduce-Motion aware).
                    Circle().stroke(DS.live.opacity(0.55), lineWidth: 3)
                        .frame(width: 150, height: 150)
                        .scaleEffect(pulse ? 1.45 : 1.0).opacity(pulse ? 0 : 0.7)
                    Circle().stroke(DS.live.opacity(0.30), lineWidth: 2)
                        .frame(width: 150, height: 150)
                        .scaleEffect(pulse ? 1.18 : 0.9).opacity(pulse ? 0 : 0.5)
                    Circle().fill(DS.surfaceHi)
                        .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                        .frame(width: 118, height: 118)
                    Text(initial).font(.system(size: 46, weight: .semibold)).foregroundColor(DS.text)
                }
                Text(inc.name).font(DS.display(26, .semibold)).foregroundColor(DS.text)
                    .padding(.top, 26).lineLimit(1)
                Text("Incoming call · TRI-NET").font(DS.ui(14)).foregroundColor(DS.dim).padding(.top, 6)
                Text(inc.ip).font(DS.mono(12)).foregroundColor(DS.faint).padding(.top, 2)
                Spacer()
                HStack(spacing: 80) {
                    answerButton(system: "phone.down.fill", label: "Decline", bg: DS.danger) {
                        stopRing(); vm.declineIncoming()
                    }
                    answerButton(system: "phone.fill", label: "Accept", bg: DS.live) {
                        stopRing(); vm.acceptIncoming()
                    }
                }
                .padding(.bottom, 70)
            }
        }
        .onAppear { startRing() }
        .onDisappear { stopRing() }
    }

    private func answerButton(system: String, label: String, bg: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: system).font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white).frame(width: 76, height: 76)
                    .background(Circle().fill(bg))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) call")
            Text(label).font(DS.ui(13)).foregroundColor(DS.dim)
        }
    }

    private func startRing() {
        if !reduceMotion {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
        ring.start()   // distinctive TRI-NET tri-tone, looped
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
    private func stopRing() { ring.stop(); ringTimer?.invalidate(); ringTimer = nil }
}

// MARK: - Call Screen (FaceTime style)

struct RemoteVideoArea: View {
    @ObservedObject var decoder: H264Decoder
    let phase: StreamViewModel.CallPhase
    let remoteIP: String

    var body: some View {
        ZStack {
            DS.surface
            if decoder.frameCount > 0, let frame = decoder.currentFrame {
                RemoteVideoDisplay(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(DS.dim)
                    Text(phase == .connecting ? "CONNECTING" : "WAITING FOR SIGNAL")
                        .font(DS.mono(12, .medium)).tracking(1).foregroundColor(DS.dim)
                    Text(remoteIP).font(DS.mono(11)).foregroundColor(DS.faint)
                }
            }
        }
    }
}

// Group conference: one tile per remote source (roster). Each tile observes ITS OWN decoder, so a
// new frame from any participant redraws only that tile.
struct GroupGrid: View {
    @ObservedObject var vm: StreamViewModel
    var body: some View {
        let cols = vm.roster.count <= 1 ? 1 : (vm.roster.count <= 4 ? 2 : 3)   // adaptive grid for 4-6 way
        let grid = Array(repeating: GridItem(.flexible(), spacing: 2), count: cols)
        ZStack {
            DS.surface
            if vm.roster.isEmpty {
                VStack(spacing: 12) {
                    ProgressView().tint(DS.dim)
                    Text("WAITING FOR PARTICIPANTS").font(DS.mono(12, .medium)).tracking(1).foregroundColor(DS.dim)
                }
            } else {
                LazyVGrid(columns: grid, spacing: 2) {
                    ForEach(vm.roster, id: \.self) { ip in
                        if let dec = vm.groupDecoders[ip] { GroupTile(decoder: dec, ip: ip) }
                    }
                }
            }
        }
    }
}

struct GroupTile: View {
    @ObservedObject var decoder: H264Decoder
    let ip: String
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.black)
            if decoder.frameCount > 0, let frame = decoder.currentFrame {
                RemoteVideoDisplay(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                ProgressView().tint(DS.dim)
            }
            Text(ip).font(DS.mono(10)).foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.black.opacity(0.55)).cornerRadius(4).padding(5)
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)   // matches the 16:9 camera/encoder
        .clipped()
    }
}

// Live "who's on this network" roster (Bonjour). Tap a name to CALL, tick several for a GROUP call, or
// set a ROOM code and "Call room" — no typing IPs. Observes PeerDiscovery so it redraws as peers come/go.
struct iPeerRoster: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject var discovery: PeerDiscovery
    @State private var myName = PeerDiscovery.myName
    @State private var room = PeerDiscovery.myRoom

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").foregroundColor(DS.dim)
                TextField("Your name", text: $myName).font(DS.ui(13)).foregroundColor(DS.text)
                    .onSubmit { discovery.setName(myName) }
                Text("ROOM").font(DS.mono(9)).foregroundColor(DS.faint)
                TextField("open", text: $room).font(DS.mono(13)).foregroundColor(DS.text).frame(width: 62)
                    .onSubmit { discovery.setRoom(room) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Text(room.isEmpty ? "ON THIS NETWORK" : "ROOM \(room.uppercased())").font(DS.mono(10)).foregroundColor(DS.faint)
                Spacer()
                if !room.isEmpty && !discovery.peers.isEmpty {
                    Button("Call room (\(discovery.peers.count))") { vm.callEveryone() }.font(DS.mono(11)).foregroundColor(.green)
                } else if !vm.selectedUIDs.isEmpty {
                    Button("Group (\(vm.selectedUIDs.count))") { vm.startGroupFromSelection() }.font(DS.mono(11)).foregroundColor(.green)
                }
            }
            if discovery.peers.isEmpty {
                Text("searching for TRI-NET peers…").font(DS.mono(11)).foregroundColor(DS.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(discovery.peers) { peer in
                    HStack(spacing: 10) {
                        Image(systemName: vm.selectedUIDs.contains(peer.uid) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(vm.selectedUIDs.contains(peer.uid) ? .green : DS.faint)
                            .onTapGesture { vm.toggleSelect(peer.uid) }
                        Circle().fill(peer.status == "call" ? Color.orange : Color.green).frame(width: 7, height: 7)
                        Text(peer.name).font(DS.ui(14)).foregroundColor(DS.text).lineLimit(1)
                        if peer.status == "call" { Text("in call").font(DS.mono(9)).foregroundColor(.orange) }
                        Spacer()
                        Button("Call") { vm.callPeer(peer) }.font(DS.mono(12)).foregroundColor(DS.text)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                    }
                }
            }
        }
    }
}

// Force the interface orientation (iOS 16+). The fullscreen button uses it; plain device rotation is handled
// by the OS now that landscape is in the Info.plist orientation set.
func setInterfaceOrientation(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
    if #available(iOS 16.0, *) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

// Tap-to-expand link-quality panel: 60s sparklines of encode bitrate + peer jitter.
private struct iLinkStatsPanel: View {
    @ObservedObject var vm: StreamViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LINK QUALITY · 60s").font(DS.mono(10)).foregroundColor(DS.faint).tracking(1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bitrate  \(vm.bitrateKbps) kbps").font(DS.mono(12)).foregroundColor(DS.text)
                iSparkline(values: vm.bitrateHistory.map(Double.init), tint: DS.live).frame(height: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Peer jitter  \(vm.peerJitterMs) ms").font(DS.mono(12)).foregroundColor(vm.peerJitterMs > 40 ? DS.danger : DS.text)
                iSparkline(values: vm.jitterHistory.map(Double.init), tint: vm.peerJitterMs > 40 ? DS.danger : DS.dim, threshold: 40).frame(height: 44)
            }
            Text("Jitter > 40ms triggers a bitrate back-off.").font(DS.ui(11)).foregroundColor(DS.faint)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ink)
    }
}

private struct iSparkline: View {
    let values: [Double]
    var tint: Color = .green
    var threshold: Double? = nil
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 1, threshold ?? 0, 1)
            ZStack {
                if let t = threshold {
                    let ty = h - CGFloat(t / maxV) * h
                    Path { p in p.move(to: CGPoint(x: 0, y: ty)); p.addLine(to: CGPoint(x: w, y: ty)) }
                        .stroke(DS.danger.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = w * CGFloat(i) / CGFloat(values.count - 1)
                            let y = h - CGFloat(v / maxV) * h
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }.stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct CallScreen: View {
    @ObservedObject var vm: StreamViewModel
    @State private var showControls = true
    @State private var showChat = false
    @State private var showLog = false
    @State private var showLinkStats = false
    @State private var draft = ""
    @State private var wantLandscape = false
    private let reactions = ["👍", "❤️", "😂", "👏", "🔥"]

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            Group {
                if vm.isGroup {
                    GroupGrid(vm: vm)
                } else {
                    RemoteVideoArea(decoder: vm.decoder, phase: vm.phase, remoteIP: vm.remoteIP)
                }
            }
            .ignoresSafeArea()
            .onTapGesture { withAnimation { showControls.toggle() } }

            // Live reaction — big transient emoji, seen the moment the peer taps.
            if let r = vm.liveReaction {
                Text(r).font(.system(size: 120))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // RTI fusion slew indicator — shows where RTI detected an object.
            if vm.rtiSlewActive {
                VStack(spacing: 6) {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("RTI SLEW")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                    Text("\(vm.rtiSlewAngle)° \(vm.rtiSlewDirection)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 60)
                .padding(.trailing, 12)
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            // Self camera PiP — reflects camera-off / blur so the toggles give LOCAL feedback (they affect the
            // OUTGOING stream, which the preview layer doesn't show on its own, so they felt like no-ops).
            VStack {
                HStack {
                    Spacer()
                    ZStack {
                        CameraPreviewView(session: vm.camera.previewSession)
                        if vm.cameraOff {
                            Rectangle().fill(Color.black)
                            Image(systemName: "video.slash.fill").font(.system(size: 22)).foregroundColor(DS.dim)
                        }
                        if vm.isBlurred && !vm.cameraOff {
                            Text("BLUR").font(DS.mono(9, .medium)).foregroundColor(DS.onFill)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DS.live, in: Capsule())
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(6)
                        }
                    }
                    .frame(width: 104, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.hairlineStrong, lineWidth: 1))
                    .padding(14)
                }
                Spacer()
            }
            .padding(.top, 44)

            // Chat panel
            if showChat {
                VStack { Spacer(); iChatPanel(vm: vm, draft: $draft, close: { showChat = false; vm.chatOpen = false }) }
                    .padding(12).transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showLog {
                VStack { Spacer(); iLogPanel(bus: LogBus.shared, close: { showLog = false }) }
                    .padding(12).transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showControls && !showChat {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        StatusTag(text: vm.framesReceived > 0 ? "Secure" : (vm.noAnswer ? "No answer" : "Calling…"),
                                  live: vm.framesReceived > 0)
                            .background(DS.ink.opacity(0.5), in: Capsule())
                        // Make link trouble visible instead of a silent freeze.
                        if vm.linkHealth != .good {
                            StatusTag(text: vm.linkHealth == .stalled ? "Reconnecting…" : "Weak connection", live: false)
                                .background((vm.linkHealth == .stalled ? DS.danger : Color.orange).opacity(0.9), in: Capsule())
                        } else if vm.linkRestored {
                            StatusTag(text: "Connection restored", live: true)
                                .background(DS.live.opacity(0.9), in: Capsule())
                                .transition(.opacity)
                        }
                        Spacer()
                        // Passive REC indicator (only while recording); the toggle now lives in the main
                        // control row, mirroring the macOS layout.
                        if vm.isRecording {
                            HStack(spacing: 5) {
                                Circle().fill(DS.danger).frame(width: 7, height: 7)
                                Text("REC").font(DS.mono(10, .medium)).tracking(0.5).foregroundColor(DS.danger)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(DS.danger.opacity(0.5), lineWidth: 1))
                        }
                        // Fullscreen: force landscape (the video fills the screen). Rotating the device does
                        // the same now that landscape is allowed; this button forces it without turning the phone.
                        Button(action: { wantLandscape.toggle(); setInterfaceOrientation(wantLandscape ? .landscapeRight : .portrait) }) {
                            Image(systemName: wantLandscape ? "arrow.down.forward.and.arrow.up.backward" : "arrow.up.backward.and.arrow.down.forward")
                                .font(.system(size: 11)).foregroundColor(wantLandscape ? DS.text : DS.dim)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                        }.buttonStyle(.plain)
                        Button(action: { withAnimation { showLog.toggle() } }) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 11))
                                .foregroundColor(showLog ? DS.text : DS.dim)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                        }.buttonStyle(.plain)
                        // Live BWE readout: peer's receive jitter + our encode rate. Green under the 40ms
                        // back-off threshold, red above — network health at a glance (Zoom-style indicator).
                        Text("\(vm.peerJitterMs)ms·\(vm.camera.bitrateKbps)k")
                            .font(DS.mono(10)).foregroundColor(vm.peerJitterMs > 40 ? DS.danger : .green)
                        Text(vm.remoteIP).font(DS.mono(11)).foregroundColor(DS.faint)
                    }
                    .padding(.horizontal, 16).padding(.top, 8)

                    Spacer()

                    // Reaction row
                    HStack(spacing: 10) {
                        ForEach(reactions, id: \.self) { e in
                            Button(e) { vm.sendReaction(e) }
                                .buttonStyle(.plain).font(.system(size: 22))
                                .frame(width: 42, height: 42)
                                .overlay(Circle().stroke(DS.hairline, lineWidth: 1))
                        }
                    }
                    .padding(.bottom, 10)

                    // Meters + controls
                    VStack(spacing: 14) {
                        HStack(spacing: 22) {
                            iMeter(label: "Mic", level: vm.txLevel, muted: vm.isMuted)
                            iMeter(label: "In", level: vm.rxLevel, muted: false)
                            Spacer()
                            // Link-quality at a glance: encode bitrate + peer-reported jitter (red = queueing).
                            // Tap to expand a 60s sparkline of both.
                            Button { showLinkStats = true } label: {
                                Text("\(vm.bitrateKbps)k · jit \(vm.peerJitterMs)ms")
                                    .font(DS.mono(11)).foregroundColor(vm.peerJitterMs > 40 ? DS.danger : DS.faint)
                            }.buttonStyle(.plain)
                            Text("↑\(vm.framesSent) ↓\(vm.framesReceived)")
                                .font(DS.mono(11)).foregroundColor(DS.faint)
                        }
                        // Equal-width flexible cells so the row always fits the
                        // phone width (6 controls; each cell centers a 46pt circle).
                        HStack(spacing: 4) {
                            iBtn(system: vm.isMuted ? "mic.slash.fill" : "mic.fill", active: vm.isMuted) { NSLog("TRINET: btn MUTE -> \(!vm.isMuted)"); vm.isMuted.toggle() }
                            iBtn(system: "arrow.triangle.2.circlepath.camera.fill", active: false) { NSLog("TRINET: btn FLIP camera"); vm.camera.switchCamera() }
                            iBtn(system: vm.cameraOff ? "video.slash.fill" : "video.fill", active: vm.cameraOff) { NSLog("TRINET: btn CAMERA-OFF -> \(!vm.cameraOff)"); vm.cameraOff.toggle() }
                            iBtn(system: vm.isBlurred ? "person.crop.rectangle.badge.plus.fill" : "person.crop.rectangle", active: vm.isBlurred) { NSLog("TRINET: btn BLUR -> \(!vm.isBlurred)"); vm.toggleBlur() }
                            ZStack(alignment: .topTrailing) {
                                iBtn(system: "bubble.left.and.bubble.right\(vm.chat.isEmpty ? "" : ".fill")", active: false) { NSLog("TRINET: btn CHAT"); vm.chatOpen = true; withAnimation { showChat = true } }
                                if vm.unreadChat > 0 && !showChat {
                                    Text("\(vm.unreadChat)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                        .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                                        .background(DS.danger, in: Capsule()).offset(x: 2, y: -2)
                                }
                            }
                            // Record — mirrors the Mac's main-row REC button; the button turns red while recording.
                            iBtn(system: vm.isRecording ? "record.circle.fill" : "record.circle", active: vm.isRecording) { NSLog("TRINET: btn RECORD -> \(!vm.isRecording)"); vm.toggleRecording() }
                            Button(action: { NSLog("TRINET: btn END CALL"); vm.stopCall() }) {
                                Image(systemName: "phone.down.fill").font(.system(size: 17)).foregroundColor(DS.onFill)
                                    .frame(width: 42, height: 42).background(DS.danger, in: Circle())
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .background(DS.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DS.hairline, lineWidth: 1))
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
        .animation(.spring(response: 0.35), value: vm.liveReaction)
        .animation(.spring(response: 0.3), value: showChat)
        .onDisappear { if wantLandscape { setInterfaceOrientation(.portrait) } }   // call ended -> home is portrait
        .sheet(isPresented: $showLinkStats) {
            if #available(iOS 16.0, *) {
                iLinkStatsPanel(vm: vm).presentationDetents([.height(240)])
            } else {
                iLinkStatsPanel(vm: vm)
            }
        }
    }
}

// iOS meter — flat segmented, DS tokens.
private struct iMeter: View {
    let label: String; let level: Float; let muted: Bool
    private let segs = 12
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(muted ? "\(label) · muted" : label.uppercased())
                .font(DS.mono(9, .medium)).tracking(0.5)
                .foregroundColor(muted ? DS.faint : DS.dim)
            HStack(spacing: 2) {
                ForEach(0..<segs, id: \.self) { i in
                    let lit = !muted && Float(i) / Float(segs) < level
                    Capsule().fill(lit ? DS.fill : DS.hairline).frame(width: 5, height: 14)
                }
            }
        }
    }
}

// iOS round control — DS hairline ring.
private struct iBtn: View {
    let system: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            // 42pt (was 46) so SEVEN controls fit one row on the narrowest iPhone; the tap area is the full
            // flexible cell (maxWidth: .infinity), so the target stays comfortable despite the smaller circle.
            Image(systemName: system).font(.system(size: 16))
                .foregroundColor(active ? DS.danger : DS.text)
                .frame(width: 42, height: 42)
                .overlay(Circle().stroke(active ? DS.danger.opacity(0.6) : DS.hairlineStrong, lineWidth: 1))
                .frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }
}

// iOS chat panel — DS card sliding from the bottom.
private struct iChatPanel: View {
    @ObservedObject var vm: StreamViewModel
    @Binding var draft: String
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Chat")
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 13)).foregroundColor(DS.dim) }
            }.padding(12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.chat) { line in
                        HStack {
                            if line.who == .me { Spacer(minLength: 40) }
                            Text(line.text).font(DS.ui(13)).foregroundColor(DS.text)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(line.who == .me ? Color.white.opacity(0.10) : DS.surfaceHi, in: RoundedRectangle(cornerRadius: 12))
                            if line.who == .them { Spacer(minLength: 40) }
                        }
                    }
                }.padding(12)
            }
            Hairline()
            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain).font(DS.ui(14)).foregroundColor(DS.text)
                    .onSubmit { vm.sendChat(draft); draft = "" }
                Button(action: { vm.sendChat(draft); draft = "" }) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundColor(DS.onFill)
                        .frame(width: 32, height: 32).background(DS.fill, in: Circle())
                }
            }.padding(12)
        }
        .frame(height: 360)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: StreamViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Connection") {
                    TextField("Remote Mac IP", text: $vm.remoteIP)
                        .keyboardType(.decimalPad)
                }
                Section("Your IP") {
                    Text(vm.myIP).font(.system(.body, design: .monospaced))
                }
                Section("Video") {
                    HRow("Resolution", "480×272")
                    HRow("Bitrate", "200 kbps")
                    HRow("Codec", "H.264 Baseline")
                }
                Section("About") {
                    HRow("Version", "1.0")
                    HRow("Transport", "BSD UDP (direct)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct HRow: View {
    let title: String; let value: String
    init(_ t: String, _ v: String) { title = t; value = v }
    var body: some View {
        HStack { Text(title); Spacer(); Text(value).foregroundColor(.gray) }
    }
}

// MARK: - Legacy components for MeshMapView compatibility
struct NodeStatusCard: View {
    @ObservedObject var vm: StreamViewModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            if !vm.linkInfo.isEmpty {
                Text(vm.linkInfo).font(DS.mono(9)).foregroundColor(DS.faint)
            }
            Text(vm.phase == .live ? "CONNECTED" : "IDLE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.5)).cornerRadius(10)
    }
}

struct SignalCard: View {
    @ObservedObject var vm: StreamViewModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("↑\(vm.framesSent) ↓\(vm.framesReceived)")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
            Text("\(vm.txKBps, specifier: "%.0f")KB/s")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.blue)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.5)).cornerRadius(10)
    }
}

struct MetricPill: View {
    let icon: String; let value: String; let unit: String; let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(.white)
            Text(unit).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.15)).cornerRadius(12)
    }
}

// MARK: - Design System (grok-style, shared with the macOS Monitor via
// desktop/DesignSystem.swift — embedded here because the iOS target compiles a
// static file list, same pattern as MeshCrypto). See BRANDBOOK.md.
enum DS {
    static let ink = Color(red: 0.039, green: 0.039, blue: 0.039)      // #0a0a0a
    static let surface = Color(red: 0.082, green: 0.082, blue: 0.082)  // #151515
    static let surfaceHi = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.20)
    static let text = Color.white.opacity(0.95)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let fill = Color.white
    static let onFill = Color.black
    static let live = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.35)
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w, design: .monospaced) }
    static func display(_ s: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: s, weight: w) }
    static let radius: CGFloat = 12
}

struct Hairline: View {
    var body: some View { Rectangle().fill(DS.hairline).frame(height: 1) }
}

struct StatusTag: View {
    let text: String
    var live: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(live ? DS.live : DS.faint).frame(width: 6, height: 6)
            Text(text.uppercased()).font(DS.mono(10, .medium)).tracking(0.5)
                .foregroundColor(live ? DS.text : DS.dim)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(DS.mono(10, .medium)).tracking(1.2).foregroundColor(DS.faint)
    }
}

// iOS log panel — the phone's own telemetry, copyable. Without this the phone is
// a black box and every diagnosis is an inference from what the Mac received.
private struct iLogPanel: View {
    @ObservedObject var bus: LogBus
    let close: () -> Void
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionLabel(text: "Log")
                Spacer()
                Text("\(bus.lines.count)").font(DS.mono(9)).foregroundColor(DS.faint)
                Button(action: {
                    UIPasteboard.general.string = bus.transcript()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9))
                        Text(copied ? "Copied" : "Copy").font(DS.mono(9, .medium))
                    }
                    .foregroundColor(copied ? DS.live : DS.dim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(copied ? DS.live.opacity(0.5) : DS.hairline, lineWidth: 1))
                }.buttonStyle(.plain)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(DS.dim)
                }.buttonStyle(.plain)
            }.padding(10)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(bus.lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(DS.mono(8))
                                .foregroundColor(Self.tint(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }.padding(10)
                }
                .onChange(of: bus.lines.count) { n in
                    guard n > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .frame(height: 300)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }

    private static func tint(_ l: String) -> Color {
        let s = l.lowercased()
        if s.contains("failed") || s.contains("error") || s.contains("denied") || s.contains("division") { return DS.danger }
        if s.contains("first frame") || s.contains("established") || s.contains("engine up") || s.contains("rebuilt") { return DS.live }
        return DS.dim
    }
}
