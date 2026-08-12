// Views.swift — FaceTime-style video call UI for iOS
import SwiftUI
import PhotosUI
import AVFoundation
import AudioToolbox

// Group the 11-digit safety number into readable blocks (e.g. 164 0819 8304) for reading aloud.
func groupDigits(_ s: String) -> String {
    let d = Array(s)
    guard d.count == 11 else { return s }
    return String(d[0..<3]) + " " + String(d[3..<7]) + " " + String(d[7..<11])
}

// MARK: - Home Screen

struct HomeView: View {
    @StateObject var vm = StreamViewModel()
    @State private var showSettings = false
    @State private var dialNick = ""
    @State private var showProfile = false

    private var query: String { PeerDiscovery.normalizeNick(dialNick) }

    private func matchesQuery(_ nick: String) -> Bool {
        guard !query.isEmpty else { return true }
        return nick.contains(query) || displayName(nick).lowercased().contains(query)
    }

    /// A contact's name comes from whoever is advertising that handle right now; before we
    /// have ever seen them, the handle is the only name we have.
    private func displayName(_ nick: String) -> String {
        vm.discovery.peer(byNick: nick)?.name ?? nick
    }

    /// A typed handle worth offering to add: not empty, not us, not already a contact.
    private var addableHandle: String? {
        guard !query.isEmpty, query != PeerDiscovery.myNick,
              !vm.chatStore.contacts.contains(query) else { return nil }
        return query
    }



    /// A typed handle that matches nothing we know: offer to open it anyway.

    /// Last thing said in a thread, or the handle when nothing has been said yet.
    /// Split out because the inline expression made the type-checker give up.
    private func preview(_ nick: String, fallback: String) -> String {
        guard let m = vm.chatStore.lastMessage(nick) else { return fallback }
        return (m.mine ? "you: " : "") + m.text
    }

    /// Identity strip above the list: who you are here, and the way into settings.
    private var listHeader: some View {
        HStack(spacing: 12) {
            Monogram(text: PeerDiscovery.myNick, size: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("TRI-NET").font(DS.display(17, .bold)).tracking(1).foregroundColor(DS.text)
                Text("@" + PeerDiscovery.myNick).font(DS.mono(11)).foregroundColor(DS.faint)
            }
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape").font(.system(size: 16)).foregroundColor(DS.dim)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(DS.ink)
    }

    /// fullmoon's list rows are headline + subheadline. Ours adds a live dot and a stamp,
    /// because a person is either reachable now or not and that changes what you do next.
    @ViewBuilder
    private func threadRow(title: String, subtitle: String, stamp: Date?, live: Bool) -> some View {
        HStack(spacing: 11) {
            Monogram(text: title, size: 38, photo: Profile.peerPhoto(title))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundColor(DS.text).lineLimit(1)
                HStack(spacing: 5) {
                    if live { Circle().fill(DS.live).frame(width: 6, height: 6) }
                    Text(subtitle).font(.subheadline).foregroundColor(DS.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let s = stamp {
                Text(s, style: .time).font(DS.mono(10)).foregroundColor(DS.faint)
            }
        }
        .padding(.vertical, 4)
    }

    /// Whether the thing is alive, shown where the list would otherwise be empty.
    private var aliveFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11)).foregroundColor(DS.live)
                Text("ready to receive").font(DS.mono(11)).foregroundColor(DS.dim)
            }
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.5).tint(DS.faint)
                Text("looking for people").font(DS.mono(11)).foregroundColor(DS.faint)
            }
        }
        .padding(.top, 10)
    }

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            if vm.phase == .live || vm.phase == .connecting {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                NavigationView {
                  // fullmoon's chat list: a plain List with search, thread title and a
                  // subtitle. No cards, no chrome -- the rows ARE the screen.
                  List {
                    // One list: the people YOU added by handle. Nothing arrives here on its
                    // own -- a device advertising itself nearby is not a contact, and the
                    // list used to fill with strangers and with duplicates of the same
                    // person under two sections.
                    ForEach(vm.chatStore.contacts.filter(matchesQuery), id: \.self) { nick in
                        NavigationLink(destination: ConversationView(vm: vm, store: vm.chatStore,
                                                                     nick: nick, name: displayName(nick))) {
                            threadRow(title: displayName(nick),
                                      subtitle: preview(nick, fallback: "@" + nick),
                                      stamp: vm.chatStore.lastMessage(nick)?.at,
                                      live: vm.discovery.peer(byNick: nick) != nil)
                        }
                        .swipeActions {
                            Button("delete", role: .destructive) { vm.chatStore.removeContact(nick) }
                        }
                    }

                    // A typed handle that is not yet a contact: adding is the only way in.
                    if let typed = addableHandle {
                        Button(action: { vm.chatStore.addContact(typed); dialNick = "" }) {
                            HStack(spacing: 11) {
                                Monogram(text: typed, size: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("@" + typed).font(.headline).foregroundColor(DS.text)
                                    Text(vm.discovery.peer(byNick: typed) != nil
                                         ? "on this network — add" : "add by handle")
                                        .font(.subheadline).foregroundColor(DS.faint)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22)).foregroundColor(DS.live)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }

                    if vm.chatStore.contacts.isEmpty && addableHandle == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("no one yet").font(.headline).foregroundColor(DS.dim)
                            Text("type a handle below to add someone")
                                .font(.subheadline).foregroundColor(DS.faint)
                        }
                        .padding(.vertical, 10)
                    }
                  }
                  .listStyle(.plain)
                  .background(DS.ink.ignoresSafeArea())
                  // .searchable lives IN the navigation bar. Hiding that bar and drawing our
                  // own header with safeAreaInset left the search with nowhere to be, and on
                  // the device that took the whole screen with it. Use the real bar.
                  .navigationTitle("TRI-NET")
                  .navigationBarTitleDisplayMode(.inline)
                  .searchable(text: $dialNick, prompt: "handle")
                  .toolbar {
                      ToolbarItem(placement: .navigationBarLeading) {
                          Button(action: { showProfile = true }) {
                              Monogram(text: vm.profile.displayName, size: 30, photo: vm.profile.photo)
                          }.buttonStyle(.plain)
                      }
                      ToolbarItem(placement: .navigationBarTrailing) {
                          Button(action: { showSettings = true }) {
                              Image(systemName: "gearshape").foregroundColor(DS.dim)
                          }
                      }
                  }
                }
                .navigationViewStyle(.stack)
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
        .sheet(isPresented: $showProfile) {
            ProfileView(vm: vm, profile: vm.profile)
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


/// Ringback: what the CALLER hears while the far end is ringing. Without it a call is a
/// silent guess -- you press call and nothing happens, so you press it again. It is a
/// different sound from the incoming ring on purpose: the two must never be confused,
/// because one means "answer me" and the other means "wait".
///
/// Cadence follows the telephone convention rather than the tri-tone: a low double beat,
/// then a long silence, repeating. A person recognises it as "it is ringing over there".
final class RingbackSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var running = false

    init() {
        engine.attach(player)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        buffer = makeRingback(fmt)
    }

    private func makeRingback(_ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = 44100.0
        let tone = 0.9, gap = 0.3, silence = 2.6      // beat, short gap, beat, long silence
        let total = tone + gap + tone + silence
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        var i = 0
        func beat(_ dur: Double) {
            let cnt = Int(dur * sr)
            for k in 0..<cnt {
                let t = Double(k) / sr
                // Short fades at both ends so the beat does not click.
                let fade = 0.02
                let env: Double = t < fade ? t / fade
                    : (t > dur - fade ? (dur - t) / fade : 1)
                // 440 + 480 Hz, the classic ringback pair.
                let v = sin(2 * Double.pi * 440 * t) + sin(2 * Double.pi * 480 * t)
                p[i] = Float(0.16 * env * v); i += 1
            }
        }
        func quiet(_ dur: Double) { for _ in 0..<Int(dur * sr) { p[i] = 0; i += 1 } }
        beat(tone); quiet(gap); beat(tone); quiet(silence)
        while i < Int(frames) { p[i] = 0; i += 1 }
        return buf
    }

    func start() {
        guard !running, let buffer = buffer else { return }
        running = true
        // .mixWithOthers so the ringback does not seize the session the call itself needs.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    func stop() {
        guard running else { return }
        running = false
        player.stop(); engine.stop()
    }
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
    @State private var myNick = PeerDiscovery.myNick
    @State private var dialNick = ""
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

            // Our handle -- this phone's short address. Dialling it is enough to reach us.
            HStack(spacing: 8) {
                Text("@").font(DS.mono(15)).foregroundColor(.green)
                TextField("your handle", text: $myNick)
                    .font(DS.mono(14)).foregroundColor(DS.text)
                    .autocapitalization(.none).disableAutocorrection(true)
                    .onSubmit {
                        myNick = PeerDiscovery.normalizeNick(myNick)
                        discovery.setNick(myNick); vm.startNickListener()
                    }
                Spacer()
                Text("YOUR ADDRESS").font(DS.mono(9)).foregroundColor(DS.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: 14))

            // Dial knowing only a handle.
            HStack(spacing: 8) {
                Text("@").font(DS.mono(15)).foregroundColor(DS.dim)
                TextField("their handle", text: $dialNick)
                    .font(DS.mono(14)).foregroundColor(DS.text)
                    .autocapitalization(.none).disableAutocorrection(true)
                    .onSubmit { vm.callByNick(dialNick) }
                if !PeerDiscovery.normalizeNick(dialNick).isEmpty {
                    Button("Call") { vm.callByNick(dialNick) }
                        .font(DS.mono(12)).foregroundColor(.green)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Color.green.opacity(0.5), lineWidth: 1))
                }
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
                        VStack(alignment: .leading, spacing: 1) {
                            Text(peer.name).font(DS.ui(14)).foregroundColor(DS.text).lineLimit(1)
                            if !peer.nick.isEmpty {
                                Text("@\(peer.nick)").font(DS.mono(10)).foregroundColor(.green).lineLimit(1)
                            }
                        }
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
                        if vm.mitmWarning {
                            StatusTag(text: "⚠︎ MITM?", live: false).background(DS.danger, in: Capsule())
                        }
                        if let sn = vm.safetyNumber {
                            StatusTag(text: "🔒 " + groupDigits(sn), live: false).background(DS.ink.opacity(0.6), in: Capsule())
                        }
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
                        Text("TX \(vm.camera.activeHeight > 0 ? "\(vm.camera.activeHeight)p·" : "")\(vm.peerJitterMs)ms·\(vm.camera.bitrateKbps)k")
                            .font(DS.mono(10)).foregroundColor(vm.peerJitterMs > 40 ? DS.danger : .green)
                        // Receive-side: frames/sec + resolution DECODED from the peer. Red at 0 fps (no video in).
                        Text("RX \(vm.rxFps)fps\(vm.isGroup ? "·\(vm.rxSources)src" : (vm.rxHeight > 0 ? "·\(vm.rxHeight)p" : ""))")
                            .font(DS.mono(10)).foregroundColor(vm.rxFps > 0 ? .green : DS.danger)
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
                // Addresses used to live here. A person picks another person, and the
                // machine works out how to reach them; an address on a settings screen is
                // an invitation to type one, which is the old console habit in a new place.
                Section("You") {
                    HRow("Name", vm.profile.displayName)
                    HRow("Handle", "@" + PeerDiscovery.myNick)
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




// MARK: - Profile
// Two things make you findable to a person: a name and a face. The handle is how the
// machine addresses you and is shown small, because nobody should have to type it twice.
struct ProfileView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject var profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picking = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    PhotosPicker(selection: $picked, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            Monogram(text: name.isEmpty ? "?" : name, size: 116, photo: profile.photo)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13)).foregroundColor(DS.onFill)
                                .frame(width: 34, height: 34)
                                .background(DS.fill, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)

                    VStack(spacing: 6) {
                        TextField("your name", text: $name)
                            .font(DS.display(21, .semibold)).foregroundColor(DS.text)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18).padding(.vertical, 13)
                            .background(DS.surfaceHi, in: RoundedRectangle(cornerRadius: 20))
                        Text("@" + PeerDiscovery.myNick)
                            .font(DS.mono(12)).foregroundColor(DS.faint)
                        Text("people find you by name; the handle is how their phone reaches yours")
                            .font(DS.ui(12)).foregroundColor(DS.faint)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30).padding(.top, 4)
                    }

                    if profile.photo != nil {
                        Button("remove photo") { profile.photo = nil }
                            .font(DS.ui(13)).foregroundColor(DS.danger)
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 22)
            }
            .background(DS.ink.ignoresSafeArea())
            .navigationTitle("profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done") { save(); dismiss() }.foregroundColor(DS.text)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { name = profile.displayName }
        .onChange(of: picked) { _ in loadPhoto() }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        profile.displayName = n
        vm.discovery.setName(n)
    }

    /// Downscale before storing: a full-resolution camera roll image in UserDefaults is
    /// megabytes of plist reloaded on every launch.
    private func loadPhoto() {
        guard let item = picked else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: data) else { return }
            let side: CGFloat = 256
            let scale = max(side / img.size.width, side / img.size.height)
            let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let out = UIGraphicsImageRenderer(size: target).image { _ in
                img.draw(in: CGRect(origin: .zero, size: target))
            }
            if let jpeg = out.jpegData(compressionQuality: 0.8) {
                await MainActor.run { profile.photo = jpeg }
            }
        }
    }
}

// MARK: - Conversation
// You write first and call from inside the thread, which is the order a messenger works in.
// The header carries the two actions that belong to a conversation and nowhere else: place a
// call to this person, and switch our own assistant on for this conversation only.
struct ConversationView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject var store: ChatStore
    let nick: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    private var online: Bool { vm.discovery.peer(byNick: nick) != nil }

    private enum Item { case message(TextFrame.Message), call(StreamViewModel.CallRecord) }

    /// Messages and this peer's calls, merged and sorted by time.
    private var timeline: [(key: String, value: Item)] {
        var out: [(Double, String, Item)] = store.messages(nick).map {
            (Double($0.atMs) / 1000, $0.id, .message($0))
        }
        for r in vm.recentCalls where r.peer == nick || r.peer == name {
            out.append((r.at.timeIntervalSince1970, "call-\(r.id)", .call(r)))
        }
        return out.sorted { $0.0 < $1.0 }.map { (key: $0.1, value: $0.2) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            messages
            Hairline()
            composer
        }
        .background(DS.ink.ignoresSafeArea())
        .navigationBarHidden(true)
        .alert("Call not placed", isPresented: Binding(
            get: { vm.callProblem != nil },
            set: { if !$0 { vm.callProblem = nil } })) {
            Button("OK", role: .cancel) { vm.callProblem = nil }
        } message: {
            Text(vm.callProblem ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DS.dim).frame(width: 32, height: 32)
            }.buttonStyle(.plain)

            Monogram(text: name, size: 36, photo: Profile.peerPhoto(nick))

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(DS.ui(15, .semibold)).foregroundColor(DS.text).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(online ? DS.live : DS.faint).frame(width: 6, height: 6)
                    Text(online ? "on this network" : "not reachable")
                        .font(DS.mono(10)).foregroundColor(DS.faint)
                }
            }
            Spacer()

            // Our assistant, per conversation. Off by default and it says what it does when on.
            // Three things you can do with a person, in the order you reach for them:
            // let the assistant listen, talk, or see each other.
            Button(action: { store.setAi(!store.isAiOn(nick), for: nick) }) {
                Image(systemName: store.isAiOn(nick) ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 21))
                    .foregroundColor(store.isAiOn(nick) ? DS.live : DS.faint)
                    .frame(width: 36, height: 36)
            }.buttonStyle(.plain)

            Button(action: { place(video: false) }) {
                Image(systemName: "phone.fill").font(.system(size: 15))
                    .foregroundColor(DS.text)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
            }.buttonStyle(.plain)

            Button(action: { place(video: true) }) {
                Image(systemName: "video.fill").font(.system(size: 16))
                    .foregroundColor(DS.onFill)
                    .frame(width: 36, height: 36)
                    .background(DS.fill, in: Circle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.messages(nick).isEmpty {
                        VStack(spacing: 8) {
                            Text("No messages yet").font(DS.ui(14)).foregroundColor(DS.faint)
                            Text("Write first, call when you want to")
                                .font(DS.mono(11)).foregroundColor(DS.faint)
                        }.padding(.top, 60)
                    }
                    // Messages and calls in one timeline: a call is a thing that happened in
                    // this conversation, not a separate log to go and find.
                    ForEach(timeline, id: \.key) { item in
                        switch item.value {
                        case .message(let m): Bubble(message: m).padding().id(m.id)
                        case .call(let r):    CallSummaryRow(record: r).padding(.horizontal).padding(.vertical, 6)
                        }
                    }
                    if store.isAiOn(nick) {
                        Text("assistant on — it will transcribe your calls on this device")
                            .font(DS.mono(10)).foregroundColor(DS.live.opacity(0.8))
                            .frame(maxWidth: .infinity).padding(.top, 6)
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
            }
            .onChange(of: store.messages(nick).count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        // One container, radius 24, minimum height 48 -- field and send button live inside it
        // together, as in fullmoon. A separate circular button beside the field reads as two
        // controls; this reads as one place to write.
        HStack(alignment: .bottom, spacing: 0) {
            TextField("message", text: $draft)
                .textFieldStyle(.plain)
                .font(DS.ui(16)).foregroundColor(DS.text)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(minHeight: 48)
                .onSubmit { send() }
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespaces).isEmpty ? DS.faint : DS.text)
                    .padding(.trailing, 10).padding(.bottom, 10)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .background(RoundedRectangle(cornerRadius: 24).fill(DS.surfaceHi))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Audio-only is a video call with the camera off, which is what the far end sees too:
    /// black frames, no bandwidth spent on a picture nobody asked for.
    private func place(video: Bool) {
        vm.cameraOff = !video
        if let p = vm.discovery.peer(byNick: nick) { vm.callPeer(p) } else { vm.callByNick(nick) }
    }

    private func send() {
        vm.sendText(draft, to: nick)
        draft = ""
    }
}


/// A finished call, shown in the thread where it happened rather than in a separate log.
/// Compact by default; a tap opens the rest. Metrics the link did not report are omitted
/// entirely -- a zero would read as a measurement, and it is not one.
struct CallSummaryRow: View {
    let record: StreamViewModel.CallRecord
    @State private var open = false

    private var duration: String {
        record.durationSec >= 60
            ? "\(record.durationSec / 60)m\(String(format: "%02d", record.durationSec % 60))s"
            : "\(record.durationSec)s"
    }

    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.18)) { open.toggle() } }) {
            VStack(alignment: .leading, spacing: open ? 8 : 0) {
                HStack(spacing: 8) {
                    Image(systemName: "video.fill").font(.system(size: 11)).foregroundColor(DS.faint)
                    Text("Call").font(DS.ui(13, .medium)).foregroundColor(DS.dim)
                    Text(duration).font(DS.mono(11)).foregroundColor(DS.faint)
                    if record.avgKbps > 0 {
                        Text("\(record.avgKbps)k").font(DS.mono(11)).foregroundColor(DS.faint)
                    }
                    if record.stalls > 0 {
                        Text("\(record.stalls) stalls").font(DS.mono(11)).foregroundColor(DS.danger)
                    }
                    Spacer()
                    Text(record.at, style: .time).font(DS.mono(10)).foregroundColor(DS.faint)
                }
                if open {
                    Hairline()
                    // One row per metric the link actually reported.
                    VStack(spacing: 5) {
                        metric("duration", duration)
                        if record.avgKbps > 0 { metric("throughput", "\(record.avgKbps) kbit/s") }
                        if record.avgJitterMs > 0 { metric("jitter", "\(record.avgJitterMs) ms",
                                                           warn: record.avgJitterMs > 40) }
                        metric("stalls", "\(record.stalls)", warn: record.stalls > 0)
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(DS.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metric(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack {
            Text(label).font(DS.mono(10)).foregroundColor(DS.faint)
            Spacer()
            Text(value).font(DS.mono(11)).foregroundColor(warn ? DS.danger : DS.dim)
        }
    }
}

struct Bubble: View {
    let message: TextFrame.Message

    // fullmoon's signature asymmetry: YOUR message sits in a filled rounded container, the
    // other side is plain text with no chrome at all. It reads as a transcript rather than a
    // ladder of opposing boxes, and the 48pt inset on the far side does the work a Spacer
    // would have done, without a second bubble to balance against.
    var body: some View {
        HStack {
            if message.mine { Spacer(minLength: 0) }
            if message.mine {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(DS.surfaceHi)
                    .mask(RoundedRectangle(cornerRadius: 24))
                    .padding(.leading, 48)
            } else {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.trailing, 48)
            }
            if !message.mine { Spacer(minLength: 0) }
        }
        .font(DS.ui(16))
        .foregroundColor(DS.text)
    }
}

// MARK: - Home components
// The home screen is a roster, not a console. A person is a row and a row is the call
// button; the addresses, counters and logs that used to sit in the middle of the screen
// live behind one disclosure at the bottom, where an operator can still reach them.

/// Telegram-style identity disc: first letter of a handle on a hairline ring. No images,
/// no avatars to fetch — the handle is the identity, so the handle is the picture.
struct Monogram: View {
    let text: String
    var size: CGFloat = 40
    var photo: Data? = nil
    private var letter: String { String(text.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() }
    var body: some View {
        if let d = photo, let img = UIImage(data: d) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(DS.hairline, lineWidth: 1))
        } else {
            monogram
        }
    }
    private var monogram: some View {
        ZStack {
            Circle().fill(DS.surfaceHi)
            Circle().stroke(DS.hairlineStrong, lineWidth: 1)
            Text(letter.isEmpty ? "?" : letter)
                .font(DS.display(size * 0.42, .semibold)).foregroundColor(DS.text)
        }
        .frame(width: size, height: size)
    }
}

/// One tappable person. The whole row calls — a small "Call" button beside a name is a
/// smaller target for the same intent.
struct PersonRow: View {
    let title: String
    let subtitle: String
    var live: Bool = false
    var busy: Bool = false
    var trailing: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            PersonRowBody(title: title, subtitle: subtitle, live: live, busy: busy, trailing: trailing)
        }
        .buttonStyle(.plain)
    }
}

/// The row's contents, split out so the same row can be a Button or a NavigationLink.
struct PersonRowBody: View {
    let title: String
    let subtitle: String
    var live: Bool = false
    var busy: Bool = false
    var trailing: String? = nil
    var body: some View {
        Group {
            HStack(spacing: 13) {
                Monogram(text: title, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(DS.ui(15, .medium)).foregroundColor(DS.text).lineLimit(1)
                        if busy {
                            Text("in call").font(DS.mono(9)).foregroundColor(DS.danger)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Capsule().stroke(DS.danger.opacity(0.4), lineWidth: 1))
                        }
                    }
                    HStack(spacing: 5) {
                        if live { Circle().fill(DS.live).frame(width: 6, height: 6) }
                        Text(subtitle).font(DS.mono(11)).foregroundColor(DS.faint).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let t = trailing {
                    Text(t).font(DS.mono(10)).foregroundColor(DS.faint)
                }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.faint)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
    }
}

/// A grouped card with a mono uppercase label, the shape every section on this screen uses.
struct SectionCard<Content: View>: View {
    let label: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(DS.mono(9, .medium)).tracking(1.2).foregroundColor(DS.faint)
                Spacer()
                if let t = trailing { t }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(DS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline, lineWidth: 1))
        }
    }
}

struct PeopleSection: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject var discovery: PeerDiscovery

    /// One line of the alive-check. Mono for the value, because it is data.
    @ViewBuilder
    func aliveRow(icon: String, label: String, value: String, ok: Bool, spinning: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13))
                .foregroundColor(ok ? DS.live : DS.faint).frame(width: 22)
            Text(label).font(DS.ui(13)).foregroundColor(DS.dim)
            Spacer()
            if spinning { ProgressView().scaleEffect(0.55).tint(DS.faint) }
            Text(value).font(DS.mono(11)).foregroundColor(ok ? DS.dim : DS.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    /// Show the last thing said, like a messenger, and fall back to the handle.
    func subtitleFor(_ peer: PeerDiscovery.Peer) -> String {
        if let last = vm.chatStore.lastMessage(peer.nick) {
            return (last.mine ? "you: " : "") + last.text
        }
        return peer.nick.isEmpty ? "no handle" : "@\(peer.nick)"
    }
    var body: some View {
        SectionCard(label: discovery.peers.isEmpty ? "NEARBY" : "NEARBY · \(discovery.peers.count)",
                    trailing: discovery.peers.count > 1
                        ? AnyView(Button("Call all") { vm.callEveryone() }
                            .font(DS.mono(10)).foregroundColor(DS.dim))
                        : nil) {
            if discovery.peers.isEmpty {
                // The empty state's job is to say whether the thing is alive, not to apologise
                // for being empty. Three facts, each one a yes/no a person can act on.
                VStack(spacing: 0) {
                    aliveRow(icon: "antenna.radiowaves.left.and.right",
                             label: "ready to receive", value: "", ok: true)
                    Hairline().padding(.leading, 46)
                    aliveRow(icon: "person.2", label: "people found", value: "none yet", ok: false,
                             spinning: true)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(discovery.peers.enumerated()), id: \.element.id) { i, peer in
                    if i > 0 { Hairline().padding(.leading, 69) }
                    // A tap opens the CONVERSATION, not a call. You write first; calling is an
                    // action inside the thread, where it belongs.
                    NavigationLink(destination: ConversationView(vm: vm, store: vm.chatStore,
                                                                 nick: peer.nick, name: peer.name)) {
                        PersonRowBody(title: peer.name,
                                      subtitle: subtitleFor(peer),
                                      live: peer.status != "call",
                                      busy: peer.status == "call",
                                      trailing: nil)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct HistorySection: View {
    @ObservedObject var vm: StreamViewModel

    /// One rule for every row on this screen: a tap opens the conversation. Calling back is
    /// then one tap inside it, next to the assistant switch, where both belong.
    var body: some View {
        let nicks = vm.chatStore.recentNicks
        if vm.missedCalls.isEmpty && vm.recentCalls.isEmpty && nicks.isEmpty {
            EmptyView()
        } else {
            SectionCard(label: "RECENT") {
                ForEach(Array(nicks.enumerated()), id: \.element) { i, nick in
                    if i > 0 { Hairline().padding(.leading, 69) }
                    NavigationLink(destination: ConversationView(vm: vm, store: vm.chatStore,
                                                                 nick: nick, name: nick)) {
                        PersonRowBody(title: nick,
                                      subtitle: vm.chatStore.lastMessage(nick).map { ($0.mine ? "you: " : "") + $0.text } ?? "@\(nick)",
                                      live: vm.discovery.peer(byNick: nick) != nil,
                                      busy: false,
                                      trailing: vm.chatStore.lastMessage(nick).map {
                                          DateFormatter.localizedString(from: $0.at, dateStyle: .none, timeStyle: .short) })
                    }.buttonStyle(.plain)
                }
                ForEach(Array(vm.missedCalls.enumerated()), id: \.element.id) { i, m in
                    if i > 0 || !nicks.isEmpty { Hairline().padding(.leading, 69) }
                    NavigationLink(destination: ConversationView(vm: vm, store: vm.chatStore,
                                                                 nick: m.name, name: m.name)) {
                        PersonRowBody(title: m.name, subtitle: "missed call", live: false, busy: false,
                                      trailing: DateFormatter.localizedString(from: m.at, dateStyle: .none, timeStyle: .short))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// Addresses, candidates, link statistics and the log share. Everything here was on the
/// front of the screen before; none of it is what a person opens the app to do.
struct AdvancedSection: View {
    @ObservedObject var vm: StreamViewModel
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } }) {
                HStack {
                    Text("NETWORK").font(DS.mono(9, .medium)).tracking(1.2).foregroundColor(DS.faint)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(DS.faint)
                    Spacer()
                }
                .padding(.horizontal, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(spacing: 12) {
                    // Addresses are deliberately absent. A person never needs one, and putting
                    // one on a screen invites typing it. What belongs here is how the link
                    // behaved, nothing about where it went.
                    if !vm.recentCalls.isEmpty {
                        let st = vm.callStats
                        HStack {
                            Text("\(st.count) calls · avg \(st.avgDurationSec/60)m\(String(format: "%02d", st.avgDurationSec%60))s · \(st.avgKbps)k")
                                .font(DS.mono(9)).foregroundColor(DS.faint)
                            Spacer()
                            if #available(iOS 16.0, *) {
                                ShareLink(item: vm.callJournalText) {
                                    Text("Share log").font(DS.mono(9)).foregroundColor(DS.dim)
                                }
                            }
                        }
                    } else {
                        Text("no calls yet").font(DS.mono(10)).foregroundColor(DS.faint)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 13)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline, lineWidth: 1))
            }
        }
    }
}

struct Hairline2: View { var body: some View { Rectangle().fill(DS.hairline).frame(height: 1) } }

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
