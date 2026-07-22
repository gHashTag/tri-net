// VideoCallTab.swift — duplex Mac<->iPhone video call tab for TriNetMonitor.
// Built on the shared components (CallManager/CameraCapture/VideoEncoder/
// VideoDecoder/MeshTransport) — BSD UDP :7000 both ways, SPS/PPS per keyframe,
// forward-secret handshake.
//
// UI: the shared TRI-NET design system (DesignSystem.swift) — jet-ink surface,
// hairline rings, pill controls, mono for technical data. Flat and restrained,
// consistent with the Network and RTI tabs. Video stays full color.
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

struct VideoCallTab: View {
    @StateObject private var call = CallManager()

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()
            if call.isInCall {
                InCallView(call: call)
            } else {
                StartCallView(call: call)
            }
        }
        .alert(item: $call.incomingMeshCall) { incoming in
            Alert(title: Text("Incoming local call"),
                  message: Text("@\(incoming.invite.nickname) wants to start an encrypted UDP call."),
                  primaryButton: .default(Text("Accept"), action: call.acceptIncomingMeshCall),
                  secondaryButton: .cancel(Text("Decline"), action: call.declineIncomingMeshCall))
        }
        .alert(item: $call.incomingInternetCall) { incoming in
            Alert(title: Text("Incoming Internet call"),
                  message: Text("@\(incoming.caller) is calling through WebRTC."),
                  primaryButton: .default(Text("Accept"), action: call.acceptIncomingInternetCall),
                  secondaryButton: .cancel(Text("Decline"), action: call.declineIncomingInternetCall))
        }
        // Incoming-call banner: macOS convention is a corner/top notification card,
        // not a full-screen takeover (a Mac is multi-window). Floats above either view.
        .overlay(alignment: .top) {
            if let inc = call.incomingCall {
                IncomingCallBanner(call: call, inc: inc)
                    .padding(.top, 18)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: call.incomingCall)
    }
}

// A distinctive SYNTHESIZED ring — three ascending chirps ("tri"-tone, fitting TRI-NET) + a gap, looped. Not a
// stock macOS alert sound, so an incoming call is instantly recognizable. AVAudioEngine plays a PCM buffer.
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
                let env = sin(Double.pi * Double(k) / Double(cnt))   // fade in/out so it's a clean "bip"
                p[i] = Float(0.34 * env * sin(2 * Double.pi * n.f * t)); i += 1
            }
        }
        while i < Int(frames) { p[i] = 0; i += 1 }   // trailing silence (the gap between rings)
        return buf
    }
    func start() {
        guard let buffer = buffer else { return }
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }
    func stop() { player.stop(); engine.stop() }
}

// MARK: - Incoming call banner (ring + Accept/Decline)
// Tap-to-expand link-quality panel: 60s sparklines of encode bitrate + peer jitter.
private struct LinkStatsPanel: View {
    @ObservedObject var call: CallManager
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LINK QUALITY · 60s").font(DS.mono(10)).foregroundColor(DS.faint).tracking(1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bitrate  \(call.bitrateKbps) kbps").font(DS.mono(11)).foregroundColor(DS.text)
                Sparkline(values: call.bitrateHistory.map(Double.init), tint: DS.live).frame(height: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Peer jitter  \(call.peerJitterMs) ms").font(DS.mono(11)).foregroundColor(call.peerJitterMs > 40 ? DS.danger : DS.text)
                Sparkline(values: call.jitterHistory.map(Double.init), tint: call.peerJitterMs > 40 ? DS.danger : DS.dim, threshold: 40).frame(height: 34)
            }
            Text("Jitter > 40ms triggers a bitrate back-off.").font(DS.ui(10)).foregroundColor(DS.faint)
        }
        .padding(14)
    }
}

// Minimal sparkline: auto-scales to its own max, optional dashed threshold line.
private struct Sparkline: View {
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
                    }.stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
        .background(DS.ink.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct IncomingCallBanner: View {
    @ObservedObject var call: CallManager
    let inc: CallManager.IncomingCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var ring = RingSynth()

    private var initial: String { String(inc.name.prefix(1)).uppercased() }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                // Expanding ring — signals a live, ringing call (Reduce-Motion aware).
                Circle().stroke(DS.live.opacity(0.55), lineWidth: 2)
                    .frame(width: 52, height: 52)
                    .scaleEffect(pulse ? 1.35 : 1.0)
                    .opacity(pulse ? 0 : 0.7)
                Circle().fill(DS.surfaceHi)
                    .overlay(Circle().stroke(DS.hairline, lineWidth: 1))
                    .frame(width: 44, height: 44)
                Text(initial).font(.system(size: 18, weight: .semibold)).foregroundColor(DS.text)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(inc.name).font(.system(size: 15, weight: .semibold)).foregroundColor(DS.text).lineLimit(1)
                Text("Incoming call · TRI-NET").font(DS.mono(10)).foregroundColor(DS.dim)
                Text(inc.ip).font(DS.mono(10)).foregroundColor(DS.faint)
            }
            Spacer(minLength: 8)
            // Decline (red, LEFT) — Accept (green, RIGHT): the iOS convention.
            ringButton(system: "phone.down.fill", bg: DS.danger, label: "Decline call") { call.declineIncoming() }
            ringButton(system: "phone.fill", bg: DS.live, label: "Accept call") { call.acceptIncoming() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: DS.radius).fill(DS.surface)
            .overlay(RoundedRectangle(cornerRadius: DS.radius).stroke(DS.hairlineStrong, lineWidth: 1)))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulse = true }
            }
            ring.start()   // distinctive TRI-NET tri-tone, looped — noticed even if you're not looking
        }
        .onDisappear { ring.stop() }
    }

    private func ringButton(system: String, bg: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white).frame(width: 46, height: 46)
                .background(Circle().fill(bg))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Start screen

private struct StartCallView: View {
    @ObservedObject var call: CallManager
    @ObservedObject private var groupChat: GroupChatController
    @State private var showNickname = false
    @State private var showInternetSettings = false
    @State private var showGroupChats = false

    init(call: CallManager) {
        self.call = call
        groupChat = call.groupChat
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer().frame(width: 76)
                Spacer()
                Text("Video Call").font(DS.display(28, .semibold)).tracking(-0.5)
                    .foregroundColor(DS.text)
                Spacer()
                HStack(spacing: 4) {
                    Button(action: { showGroupChats = true }) {
                        Image(systemName: groupChat.chats.isEmpty ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill")
                            .foregroundColor(DS.dim).frame(width: 36, height: 36)
                    }.buttonStyle(.plain)
                    Button(action: { showInternetSettings = true }) {
                        Image(systemName: "gearshape").foregroundColor(DS.dim).frame(width: 36, height: 36)
                    }.buttonStyle(.plain)
                }
            }
            // Say what this actually is. The call is direct UDP between two IP
            // peers over whatever interface the OS routes by (Wi-Fi today) — the
            // radio mesh is a separate subsystem and is NOT in this path. The old
            // "Encrypted mesh" line implied otherwise.
            Text("Encrypted local UDP | LiveKit WebRTC")
                .font(DS.ui(13)).foregroundColor(DS.dim)

            Button(action: { showNickname = true }) {
                HStack(spacing: 8) {
                    Image(systemName: call.directory.currentNickname == nil ?
                          "person.crop.circle.badge.plus" : "checkmark.seal.fill")
                    Text(call.directory.currentNickname.map { "@\($0)" } ?? "Create your nickname")
                        .font(DS.mono(12, .medium))
                    Text(call.directory.claimKind == .verified ? "VERIFIED" :
                         call.directory.claimKind == .meshLocal ? "MESH-LOCAL" : "NEW")
                        .font(DS.mono(9, .bold))
                        .foregroundColor(call.directory.claimKind == .verified ? DS.live : .orange)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .dsCard(12)
            }.buttonStyle(.plain)

            VStack(spacing: 12) {
                Picker("Route", selection: $call.route) {
                    Text("Auto").tag(CallRoute.automatic)
                    Text("Local/Mesh UDP").tag(CallRoute.mesh)
                    Text("Internet").tag(CallRoute.internet)
                }
                .pickerStyle(.segmented)
                .frame(width: 430)

                HStack(spacing: 8) {
                    SectionLabel(text: "Find")
                    TextField(call.route == .mesh ? "nickname or IP" : "nickname",
                              text: Binding(get: { call.directory.searchQuery },
                                            set: { call.directory.searchQuery = $0 }))
                        .textFieldStyle(.plain).font(DS.mono(14)).foregroundColor(DS.text)
                        .frame(width: 250)
                        .onSubmit { call.searchNicknames() }
                    Button(action: { call.searchNicknames() }) {
                        Image(systemName: "magnifyingglass").foregroundColor(DS.text)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).dsCard(12)

                if !call.directory.results.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(call.directory.results.prefix(3)) { contact in
                            Button("@\(contact.nickname) [\(contact.source.rawValue)]") {
                                call.selectContact(contact)
                            }
                            .buttonStyle(.plain).font(DS.mono(10, .medium)).foregroundColor(DS.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                        }
                    }
                }

                Text("SELF | \(call.directory.currentNickname.map { "@\($0)" } ?? call.identity.displayName) | \(call.localIP):\(call.port)")
                    .font(DS.mono(11)).foregroundColor(DS.faint)

                if call.isStarting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(call.status).font(DS.ui(11)).foregroundColor(DS.dim)
                    }
                }

                if let error = call.error {
                    Text(error).font(DS.ui(11)).foregroundColor(DS.danger)
                        .multilineTextAlignment(.center)
                }

                // Missed calls — one-tap call back (newest first, capped at 5).
                if !call.missedCalls.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(call.missedCalls) { m in
                            HStack(spacing: 8) {
                                Image(systemName: "phone.arrow.down.left").font(.system(size: 11)).foregroundColor(DS.danger)
                                Text("Missed · \(m.name)").font(DS.ui(12)).foregroundColor(DS.text)
                                Text(m.at, style: .time).font(DS.mono(10)).foregroundColor(DS.faint)
                                Spacer()
                                Button("Call back") { call.remoteIP = m.ip; call.startCall() }
                                    .buttonStyle(.plain).font(DS.mono(11)).foregroundColor(DS.live)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .overlay(Capsule().stroke(DS.live.opacity(0.4), lineWidth: 1))
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10).dsCard(12)
                    .frame(maxWidth: 420)
                }

                // Recent-call journal: duration + average link quality of past completed calls.
                if !call.recentCalls.isEmpty {
                    VStack(spacing: 5) {
                        HStack {
                            Text("RECENT").font(DS.mono(9)).foregroundColor(DS.faint).tracking(1)
                            Spacer()
                            Button("Copy log") { call.copyJournal() }
                                .buttonStyle(.plain).font(DS.mono(9)).foregroundColor(DS.dim)
                        }
                        ForEach(call.recentCalls.prefix(4)) { r in
                            HStack(spacing: 8) {
                                Image(systemName: "phone.connection").font(.system(size: 11)).foregroundColor(DS.dim)
                                Text(r.peer).font(DS.mono(11)).foregroundColor(DS.text)
                                Spacer()
                                Text("\(r.durationSec/60)m\(String(format: "%02d", r.durationSec%60))s · \(r.avgKbps)k · \(r.avgJitterMs)ms\(r.stalls > 0 ? " · ⚠︎\(r.stalls)" : "")")
                                    .font(DS.mono(10)).foregroundColor(r.avgJitterMs > 40 || r.stalls > 0 ? DS.danger : DS.faint)
                                Button("Call") { call.remoteIP = r.peer; call.startCall() }
                                    .buttonStyle(.plain).font(DS.mono(10)).foregroundColor(DS.live)
                            }
                        }
                        // Aggregate stability across the whole journal.
                        let s = call.callStats
                        Divider().overlay(DS.hairline)
                        HStack(spacing: 8) {
                            Text("\(s.count) calls").font(DS.mono(9)).foregroundColor(DS.dim)
                            Spacer()
                            Text("avg \(s.avgDurationSec/60)m\(String(format: "%02d", s.avgDurationSec%60))s · \(s.avgKbps)k · \(s.totalStalls) stalls")
                                .font(DS.mono(9)).foregroundColor(s.totalStalls > 0 ? DS.danger : DS.faint)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10).dsCard(12).frame(maxWidth: 420)
                }

                if !call.recentIPs.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(call.recentIPs, id: \.self) { ip in
                            Button(ip) { call.remoteIP = ip }
                                .buttonStyle(.plain).font(DS.mono(11)).foregroundColor(DS.dim)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                        }
                    }
                }

                PeerRoster(call: call, discovery: call.discovery)

                HStack(spacing: 8) {
                    SectionLabel(text: "Optic")
                    Picker("", selection: Binding(get: { call.selectedCameraID },
                                                  set: { call.selectCamera($0) })) {
                        ForEach(call.cameras, id: \.uniqueID) { cam in
                            Text(cam.localizedName).tag(cam.uniqueID)
                        }
                    }.labelsHidden().frame(width: 220)
                }
            }

            PillButton(title: "Start Call", icon: "phone.fill", filled: true) { call.startCall() }
                .padding(.top, 6)
        }
        .padding(30)
        .sheet(isPresented: $showNickname) { MonitorNicknamePanel(call: call) }
        .sheet(isPresented: $showInternetSettings) { MonitorInternetSettingsPanel(call: call) }
        .sheet(isPresented: $showGroupChats) { MonitorGroupChatPanel(call: call) }
    }
}

private struct MonitorNicknamePanel: View {
    @ObservedObject var call: CallManager
    @ObservedObject private var directory: NicknameDirectoryController
    @Environment(\.dismiss) private var dismiss

    init(call: CallManager) {
        self.call = call
        directory = call.directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your Nickname").font(DS.display(20, .semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack {
                Text("@").foregroundColor(DS.dim)
                TextField("nickname", text: $directory.proposedNickname)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Use 3-20 lowercase letters, numbers, or underscore.")
                .font(DS.ui(11)).foregroundColor(DS.dim)
            Button(directory.isWorking ? "Checking..." : "Check and create") {
                call.claimNickname()
            }.disabled(directory.isWorking)
            if let status = directory.statusMessage {
                Text(status).font(DS.ui(11)).foregroundColor(DS.text)
            }
            if !directory.suggestions.isEmpty {
                HStack {
                    ForEach(directory.suggestions, id: \.self) { suggestion in
                        Button("@\(suggestion)") {
                            directory.proposedNickname = suggestion
                            call.claimNickname()
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 300)
        .onChange(of: directory.currentNickname) { current in
            if current != nil { dismiss() }
        }
    }
}

private struct MonitorInternetSettingsPanel: View {
    @ObservedObject var call: CallManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Internet Calling").font(DS.display(20, .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            TextField("https://api.example.com", text: $call.internetConfiguration.apiBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("wss://project.livekit.cloud", text: $call.internetConfiguration.liveKitURL)
                .textFieldStyle(.roundedBorder)
            SecureField("Service access token", text: $call.internetConfiguration.accessToken)
                .textFieldStyle(.roundedBorder)
            SecureField("Development room token", text: $call.internetConfiguration.developmentRoomToken)
                .textFieldStyle(.roundedBorder)
            Text("Production uses the signed API. Direct LiveKit mode is for development tests only.")
                .font(DS.ui(11)).foregroundColor(DS.dim)
            HStack {
                Spacer()
                Button("Save") {
                    call.saveInternetSettings()
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 330)
    }
}

private struct MonitorGroupChatPanel: View {
    @ObservedObject var call: CallManager
    @ObservedObject private var group: GroupChatController
    @Environment(\.dismiss) private var dismiss

    init(call: CallManager) {
        self.call = call
        group = call.groupChat
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Group Chats").font(DS.display(22, .semibold)).foregroundColor(DS.text)
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "New group")
                    TextField("Title (optional)", text: $group.titleInput)
                        .textFieldStyle(.roundedBorder)
                    TextField("@alice, @bob", text: $group.membersInput)
                        .textFieldStyle(.roundedBorder)
                    Text("Separate unique nicknames with commas or spaces.")
                        .font(DS.ui(10)).foregroundColor(DS.dim)
                    Button(group.isWorking ? "Creating..." : "Create group") {
                        group.createGroup()
                    }
                    .disabled(group.isWorking)

                    Hairline()
                    SectionLabel(text: "Your chats")
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            if group.chats.isEmpty {
                                Text("No groups yet").font(DS.ui(11)).foregroundColor(DS.faint)
                            }
                            ForEach(group.chats) { chat in
                                Button(action: { group.open(chat) }) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(chat.title).font(DS.ui(13, .medium)).foregroundColor(DS.text)
                                        Text(chat.members.map { "@\($0)" }.joined(separator: ", "))
                                            .font(DS.mono(9)).foregroundColor(DS.faint).lineLimit(1)
                                        if let lastMessage = chat.lastMessage {
                                            Text(lastMessage).font(DS.ui(10)).foregroundColor(DS.dim).lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(9)
                                    .background(group.activeChatID == chat.chatID ? DS.surfaceHi : DS.surface,
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.hairline, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(width: 260)

                VStack(spacing: 0) {
                    if let chat = group.activeChat {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.title).font(DS.ui(16, .semibold)).foregroundColor(DS.text)
                                Text(chat.members.map { "@\($0)" }.joined(separator: ", "))
                                    .font(DS.mono(9)).foregroundColor(DS.faint).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(12)
                        Hairline()
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(group.messages) { message in
                                        let mine = message.senderUserID == call.identity.userID
                                        HStack {
                                            if mine { Spacer(minLength: 70) }
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(mine ? "You" : "@\(message.senderNickname)")
                                                    .font(DS.mono(9)).foregroundColor(DS.faint)
                                                Text(message.text).font(DS.ui(12)).foregroundColor(DS.text)
                                            }
                                            .padding(.horizontal, 11).padding(.vertical, 7)
                                            .background(mine ? Color.white.opacity(0.10) : DS.surfaceHi,
                                                        in: RoundedRectangle(cornerRadius: 11))
                                            if !mine { Spacer(minLength: 70) }
                                        }
                                        .id(message.messageID)
                                    }
                                }
                                .padding(12)
                            }
                            .onChange(of: group.messages.count) { _ in
                                if let last = group.messages.last {
                                    proxy.scrollTo(last.messageID, anchor: .bottom)
                                }
                            }
                        }
                        Hairline()
                        HStack(spacing: 8) {
                            TextField("Message", text: $group.draft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { group.send() }
                            Button(action: { group.send() }) {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                            }
                            .buttonStyle(.plain)
                            .disabled(group.isWorking || group.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(12)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 42)).foregroundColor(DS.faint)
                            Text("Select a group or create one by nickname.")
                                .font(DS.ui(13)).foregroundColor(DS.dim)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(DS.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.hairline, lineWidth: 1))
            }

            if let status = group.statusMessage {
                Text(status).font(DS.ui(10)).foregroundColor(DS.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 820, height: 600)
        .background(DS.ink)
        .onAppear { group.startPolling() }
    }
}

// Live "who's on this network" roster (Bonjour). Tap a name to CALL, tick several for a GROUP call —
// no typing IPs. Observes PeerDiscovery directly so it redraws as peers come and go.
private struct PeerRoster: View {
    @ObservedObject var call: CallManager
    @ObservedObject var discovery: PeerDiscovery
    @State private var myName = PeerDiscovery.myName
    @State private var room = PeerDiscovery.myRoom

    var body: some View {
        VStack(spacing: 8) {
            // Identity: your display name + optional ROOM code (only see/call peers in the same room).
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").foregroundColor(DS.dim)
                TextField("Your name", text: $myName)
                    .textFieldStyle(.plain).font(DS.ui(12)).foregroundColor(DS.text).frame(width: 120)
                    .onSubmit { discovery.setName(myName) }
                Divider().frame(height: 14)
                Text("ROOM").font(DS.mono(9)).foregroundColor(DS.faint)
                TextField("open", text: $room)
                    .textFieldStyle(.plain).font(DS.mono(12)).foregroundColor(DS.text).frame(width: 64)
                    .onSubmit { discovery.setRoom(room) }
            }
            Divider()
            HStack {
                SectionLabel(text: room.isEmpty ? "On this network" : "Room \(room.uppercased())")
                Spacer()
                if !room.isEmpty && !discovery.peers.isEmpty {
                    Button("Call room (\(discovery.peers.count))") { call.callEveryone() }
                        .buttonStyle(.plain).font(DS.mono(11, .semibold)).foregroundColor(.green)
                } else if !call.selectedUIDs.isEmpty {
                    Button("Group call (\(call.selectedUIDs.count))") { call.startGroupFromSelection() }
                        .buttonStyle(.plain).font(DS.mono(11, .semibold)).foregroundColor(.green)
                }
            }
            if discovery.peers.isEmpty {
                Text("searching for TRI-NET peers…")
                    .font(DS.mono(11)).foregroundColor(DS.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(discovery.peers) { peer in
                    HStack(spacing: 10) {
                        Image(systemName: call.selectedUIDs.contains(peer.uid) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(call.selectedUIDs.contains(peer.uid) ? .green : DS.faint)
                            .onTapGesture { call.toggleSelect(peer.uid) }
                        Circle().fill(peer.status == "call" ? Color.orange : Color.green).frame(width: 6, height: 6)
                        Text(peer.name).font(DS.ui(13)).foregroundColor(DS.text).lineLimit(1)
                        if peer.status == "call" { Text("in call").font(DS.mono(9)).foregroundColor(.orange) }
                        Spacer()
                        Button("Call") { call.callPeer(peer) }
                            .buttonStyle(.plain).font(DS.mono(11, .semibold)).foregroundColor(DS.text)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12).dsCard(12)
    }
}

// MARK: - In-call screen

private struct InCallView: View {
    @ObservedObject var call: CallManager
    @State private var pipOffset: CGSize = .zero
    @State private var showChat = false
    @State private var showLinkStats = false
    @State private var draft = ""
    private let reactions = ["👍", "❤️", "😂", "👏", "🔥"]

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                // Group → adaptive grid of per-source decoders; 1-1 → single feed
                if call.isGroup {
                    GroupGrid(call: call)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).stroke(DS.hairline, lineWidth: 1))
                } else {
                    MonitorRemoteVideo(decoder: call.decoder)
                        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).stroke(DS.hairline, lineWidth: 1))
                }

                // Floating reaction
                if let r = call.liveReaction {
                    Text(r).font(.system(size: 90))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusTag(text: call.framesReceived > 0 || !call.groupDecoders.isEmpty ? "Secure" : "Connecting",
                                  live: call.framesReceived > 0 || !call.groupDecoders.isEmpty)
                            .background(DS.ink.opacity(0.5), in: Capsule())
                        // Make link trouble visible instead of a silent freeze.
                        if call.linkHealth != .good {
                            StatusTag(text: call.linkHealth == .stalled ? "Reconnecting…" : "Weak connection", live: false)
                                .background((call.linkHealth == .stalled ? DS.danger : Color.orange).opacity(0.9), in: Capsule())
                        } else if call.linkRestored {
                            StatusTag(text: "Connection restored", live: true)
                                .background(DS.live.opacity(0.9), in: Capsule())
                                .transition(.opacity)
                        }
                        if call.roster.count > 1 {
                            StatusTag(text: "\(call.roster.count) in call", live: true).background(DS.ink.opacity(0.5), in: Capsule())
                        }
                        if call.isScreenSharing {
                            StatusTag(text: "Sharing Screen", live: true).background(DS.ink.opacity(0.5), in: Capsule())
                        }
                        LinkBadge(link: call.link)
                        // Live BWE readout: what the PEER's receiver measures (jitter) + our encode rate.
                        // Green under 40ms (the back-off threshold), red above — network health at a glance.
                        Text("net \(call.peerJitterMs)ms · \(call.camera.bitrateKbps)k")
                            .font(DS.mono(10)).foregroundColor(call.peerJitterMs > 40 ? DS.danger : DS.live)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(DS.ink.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    if let s = call.previewSession {
                        ZStack {
                            MonitorCameraPreview(session: s)
                            if call.cameraOff {   // local feedback: black out the self-preview too
                                Rectangle().fill(Color.black)
                                Image(systemName: "video.slash.fill").font(.system(size: 22)).foregroundColor(DS.dim)
                            }
                        }
                            .frame(width: 150, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.hairlineStrong, lineWidth: 1))
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { pipOffset = $0.translation })
                    }
                }
                .padding(12)

                // Chat panel (right overlay)
                if showChat {
                    HStack { Spacer(); ChatPanel(call: call, draft: $draft, close: { showChat = false; call.chatOpen = false }) }
                        .padding(12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.35), value: call.liveReaction)
            .animation(.spring(response: 0.3), value: showChat)

            // Reaction quick-row
            HStack(spacing: 8) {
                ForEach(reactions, id: \.self) { e in
                    Button(e) { call.sendReaction(e) }
                        .buttonStyle(.plain).font(.system(size: 18))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(DS.hairline, lineWidth: 1))
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            // Control bar
            HStack(spacing: 16) {
                Meter(label: "Mic", level: call.txLevel, muted: call.isMuted)
                Meter(label: "In", level: call.rxLevel, muted: false)
                Spacer()
                // Link-quality at a glance (what Zoom/Meet show as "bars"): encode bitrate + peer's jitter.
                // Tap to expand a 60s sparkline of both.
                Button { showLinkStats.toggle() } label: {
                    Text("\(call.bitrateKbps)k · jit \(call.peerJitterMs)ms")
                        .font(DS.mono(11)).foregroundColor(call.peerJitterMs > 40 ? DS.danger : DS.faint)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showLinkStats, arrowEdge: .top) {
                    LinkStatsPanel(call: call).frame(width: 300)
                }
                Text("↑\(call.framesSent)  ↓\(call.framesReceived)")
                    .font(DS.mono(11)).foregroundColor(DS.faint)
                IconPill(system: call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted, tint: DS.danger) { call.isMuted.toggle() }
                IconPill(system: call.isScreenSharing ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle",
                         active: call.isScreenSharing, tint: DS.live) { call.toggleScreenShare() }
                ZStack(alignment: .topTrailing) {
                    IconPill(system: "bubble.left.and.bubble.right\(call.chat.isEmpty ? "" : ".fill")", active: showChat) {
                        showChat.toggle(); call.chatOpen = showChat
                    }
                    if call.unreadChat > 0 && !showChat {
                        Text("\(call.unreadChat)").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(DS.danger, in: Capsule()).offset(x: 6, y: -6)
                    }
                }
                IconPill(system: call.isRecording ? "record.circle.fill" : "record.circle", active: call.isRecording, tint: DS.danger) { call.toggleRecording() }
                IconPill(system: call.isBlurred ? "person.crop.rectangle.badge.plus.fill" : "person.crop.rectangle", active: call.isBlurred, tint: DS.live) { call.toggleBlur() }
                IconPill(system: call.isMeshProfile ? "antenna.radiowaves.left.and.right.circle.fill" : "antenna.radiowaves.left.and.right",
                         active: call.isMeshProfile, tint: DS.live) { call.toggleMeshProfile() }
                Menu {
                    ForEach(call.cameras, id: \.uniqueID) { cam in
                        Button(cam.localizedName) { call.selectCamera(cam.uniqueID) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 14)).foregroundColor(DS.text)
                        .frame(width: 40, height: 40).overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                }.menuStyle(.borderlessButton).frame(width: 44)
                IconPill(system: call.cameraOff ? "video.slash.fill" : "video.fill", active: call.cameraOff, tint: DS.danger) { call.cameraOff.toggle() }
                Button(action: { call.endCall() }) {
                    Image(systemName: "phone.down.fill").font(.system(size: 15)).foregroundColor(DS.onFill)
                        .frame(width: 56, height: 40).background(DS.danger, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .dsCard(DS.radius)

            // Live telemetry, in the app. Everything below was already being
            // logged; it was just invisible outside a terminal.
            LogPane(bus: call.log)
        }
        .padding(14)
    }
}

// Slide-in chat panel (glassless, DS card).
private struct ChatPanel: View {
    @ObservedObject var call: CallManager
    @Binding var draft: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Chat")
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(DS.dim) }
                    .buttonStyle(.plain)
            }.padding(12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(call.chat) { line in
                        HStack {
                            if line.who == .me { Spacer(minLength: 24) }
                            Text(line.text).font(DS.ui(12)).foregroundColor(DS.text)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(line.who == .me ? Color.white.opacity(0.10) : DS.surfaceHi, in: RoundedRectangle(cornerRadius: 10))
                            if line.who == .them { Spacer(minLength: 24) }
                        }
                    }
                }.padding(12)
            }
            Hairline()
            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain).font(DS.ui(12)).foregroundColor(DS.text)
                    .onSubmit { call.sendChat(draft); draft = "" }
                Button(action: { call.sendChat(draft); draft = "" }) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundColor(DS.onFill)
                        .frame(width: 28, height: 28).background(DS.fill, in: Circle())
                }.buttonStyle(.plain)
            }.padding(10)
        }
        .frame(width: 260, height: 320)
        .dsCard(DS.radius)
    }
}

// Flat segmented meter (mono label + hairline track + white fill).
private struct Meter: View {
    let label: String
    let level: Float
    let muted: Bool
    private let segs = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(muted ? "\(label) · muted" : label.uppercased())
                .font(DS.mono(9, .medium)).tracking(0.5)
                .foregroundColor(muted ? DS.faint : DS.dim)
            HStack(spacing: 2) {
                ForEach(0..<segs, id: \.self) { i in
                    let lit = !muted && Float(i) / Float(segs) < level
                    Capsule().fill(lit ? DS.fill : DS.hairline).frame(width: 4, height: 12)
                }
            }
        }
    }
}

// MARK: - Display helpers (self-contained: the Monitor target does not compile
// the standalone app's Views.swift)

private struct MonitorRemoteVideo: View {
    @ObservedObject var decoder: VideoDecoder

    var body: some View {
        ZStack {
            DS.surface
            if let frame = decoder.currentFrame {
                MonitorFrameView(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("WAITING FOR SIGNAL").font(DS.mono(11, .medium)).tracking(1).foregroundColor(DS.faint)
                }
            }
        }
    }
}

private struct MonitorFrameView: NSViewRepresentable {
    let imageBuffer: CVImageBuffer
    let frameId: Int

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let ci = CIImage(cvImageBuffer: imageBuffer)
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        nsView.layer?.contents = img
        nsView.layer?.contentsGravity = .resizeAspect
    }
}

private struct MonitorCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.first?.frame = nsView.bounds
    }
}

// Adaptive grid of per-source decoders for a conference call (full-mesh,
// 2-4 nodes). Columns scale with participant count.
private struct GroupGrid: View {
    @ObservedObject var call: CallManager
    var body: some View {
        let ids = call.groupDecoders.keys.sorted()
        let cols = ids.count <= 1 ? 1 : 2
        return ZStack {
            DS.surface
            if ids.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("WAITING FOR PARTICIPANTS").font(DS.mono(11, .medium)).tracking(1).foregroundColor(DS.faint)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: cols), spacing: 6) {
                    ForEach(ids, id: \.self) { ip in
                        if let dec = call.groupDecoders[ip] {
                            ZStack(alignment: .bottomLeading) {
                                MonitorRemoteVideo(decoder: dec)
                                    .aspectRatio(16.0/9.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(ip).font(DS.mono(9)).foregroundColor(DS.text)
                                    .padding(4).background(DS.ink.opacity(0.6), in: Capsule()).padding(6)
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
    }
}

// MARK: - Honest link badge
// Shows the path the datagrams ACTUALLY leave by, measured from the routing
// table. The app used to say "Encrypted mesh" while every byte went over plain
// Wi-Fi; a badge that can lie is worse than no badge, so MESH lights up only for
// a real radio path and otherwise states plainly what is carrying the call.
struct LinkBadge: View {
    @ObservedObject var link: LinkStatus
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: link.path.isMesh ? "antenna.radiowaves.left.and.right" : "wifi")
                .font(.system(size: 9))
                .foregroundColor(link.path.isMesh ? DS.live : DS.dim)
            Text(link.path.label).font(DS.mono(10, .medium)).tracking(0.5)
                .foregroundColor(link.path.isMesh ? DS.live : DS.text)
            Text(link.path.detail).font(DS.mono(9)).foregroundColor(DS.faint)
            if !link.path.isMesh {
                Text("· \(link.meshNote)").font(DS.mono(9)).foregroundColor(DS.faint)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(DS.ink.opacity(0.5), in: Capsule())
        .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
    }
}

// MARK: - Live log
// Tails the app's own stderr (every existing NSLog) in real time. Until now this
// telemetry was invisible unless the binary was launched from a terminal, which
// is precisely why an audio failure went undiagnosed for so long.
struct LogPane: View {
    @ObservedObject var bus: LogBus
    // Square corners on every tab (0). Rounded corners on the log pane read as
    // wrong across the app; keep it a flat panel everywhere.
    var cornerRadius: CGFloat = 0
    @State private var paused = false
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionLabel(text: "Log")
                Spacer()
                Text("\(bus.lines.count)").font(DS.mono(9)).foregroundColor(DS.faint)
                // Copy the WHOLE buffer, not the visible slice — the point is to
                // hand a complete session to someone (or something) that can read
                // it. Prefixed with the environment, because a log without the
                // build and link it came from invites the wrong conclusion.
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bus.transcript(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(copied ? "Copied" : "Copy")
                            .font(DS.mono(9, .medium))
                    }
                    .foregroundColor(copied ? DS.live : DS.dim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(copied ? DS.live.opacity(0.5) : DS.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Copy the full log to the clipboard")
                Button(action: { bus.revealLog() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text("Log file").font(DS.mono(9, .medium))
                    }
                    .foregroundColor(DS.dim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Reveal the persistent log file (~/Library/Logs/TriNetMonitor/monitor.log) in Finder")
                Button(action: { paused.toggle() }) {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9)).foregroundColor(DS.dim)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(bus.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(DS.mono(9))
                                .foregroundColor(Self.tint(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                }
                .onChange(of: bus.lines.count) { n in
                    guard !paused, n > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .frame(height: 150)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(DS.hairline, lineWidth: cornerRadius > 0 ? 1 : 0))
    }

    // Log line colour, syslog-style: SEVERITY first (a red error must read as an
    // error whatever subsystem it came from), then the FACILITY tint so the eye can
    // group NET / RTI / radio traffic at a glance. Keep it to a few hues — more than
    // ~5 colours stops being a signal and becomes noise.
    static let amber      = Color(red: 0.96, green: 0.70, blue: 0.30)  // warning
    static let netBlue    = Color(red: 0.44, green: 0.66, blue: 0.98)  // NET: scan/topology
    static let rtiCyan    = Color(red: 0.36, green: 0.82, blue: 0.86)  // RTI: radar/CSI
    static let meshViolet = Color(red: 0.72, green: 0.58, blue: 0.99)  // radio / mesh / SNR
    static let metric     = Color(red: 0.60, green: 0.78, blue: 0.60)  // bare telemetry summary
    private static func tint(_ l: String) -> Color {
        let s = l.lowercased()
        // 1) Severity — highest priority, any facility.
        if s.contains("fail") || s.contains("error") || s.contains("denied") || s.contains("dropped")
            || s.contains("offline") || s.contains("host is down") || s.contains("panic")
            || s.contains("unreachable") || s.contains("lost") { return DS.danger }
        if s.contains("warn") || s.contains("retry") || s.contains("timeout") || s.contains("degraded")
            || s.contains("weak") || s.contains("reconnect") || s.contains("stall") { return amber }
        // 2) Success / milestones.
        if s.contains("online") || s.contains("established") || s.contains("delivered")
            || s.contains("authenticated") || s.contains("ready") || s.contains(" pass")
            || s.contains("complete") || s.contains("first frame") || s.contains("rebuilt")
            || s.contains("connected") || s.contains("converged") { return DS.live }
        // 3) Telemetry summary lines (start with a bullet) read as data.
        if l.hasPrefix("·") || l.hasPrefix("▸") { return metric }
        // 4) Facility tint for the neutral remainder.
        if s.contains("net:") { return netBlue }
        if s.contains("rti:") { return rtiCyan }
        if s.contains("radiod") || s.contains("snr") || s.contains(" mesh") || s.contains("radio")
            || s.contains(" tx ") || s.contains(" rx ") { return meshViolet }
        if s.contains("===") || s.contains("session start") { return DS.text }
        return DS.dim
    }
}
