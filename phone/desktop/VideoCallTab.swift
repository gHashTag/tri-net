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
    }
}

// MARK: - Start screen

private struct StartCallView: View {
    @ObservedObject var call: CallManager

    var body: some View {
        VStack(spacing: 18) {
            Text("Video Call").font(DS.display(28, .semibold)).tracking(-0.5)
                .foregroundColor(DS.text)
            // Say what this actually is. The call is direct UDP between two IP
            // peers over whatever interface the OS routes by (Wi-Fi today) — the
            // radio mesh is a separate subsystem and is NOT in this path. The old
            // "Encrypted mesh" line implied otherwise.
            Text("Encrypted peer-to-peer · forward-secret")
                .font(DS.ui(13)).foregroundColor(DS.dim)

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    SectionLabel(text: "Peer")
                    TextField("IP", text: $call.remoteIP)
                        .textFieldStyle(.plain).font(DS.mono(14)).foregroundColor(DS.text)
                        .frame(width: 160)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).dsCard(12)

                Text("SELF · \(call.localIP):\(call.port)")
                    .font(DS.mono(11)).foregroundColor(DS.faint)

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
    }
}

// MARK: - In-call screen

private struct InCallView: View {
    @ObservedObject var call: CallManager
    @State private var pipOffset: CGSize = .zero
    @State private var showChat = false
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
                        if call.roster.count > 1 {
                            StatusTag(text: "\(call.roster.count) in call", live: true).background(DS.ink.opacity(0.5), in: Capsule())
                        }
                        if call.isScreenSharing {
                            StatusTag(text: "Sharing Screen", live: true).background(DS.ink.opacity(0.5), in: Capsule())
                        }
                        LinkBadge(link: call.link)
                    }
                    Spacer()
                    if let s = call.previewSession {
                        MonitorCameraPreview(session: s)
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
                    HStack { Spacer(); ChatPanel(call: call, draft: $draft, close: { showChat = false }) }
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
                Text("↑\(call.framesSent)  ↓\(call.framesReceived)")
                    .font(DS.mono(11)).foregroundColor(DS.faint)
                IconPill(system: call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted, tint: DS.danger) { call.isMuted.toggle() }
                IconPill(system: call.isScreenSharing ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle",
                         active: call.isScreenSharing, tint: DS.live) { call.toggleScreenShare() }
                IconPill(system: "bubble.left.and.bubble.right\(call.chat.isEmpty ? "" : ".fill")", active: showChat) { showChat.toggle() }
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
                                    .aspectRatio(4/3, contentMode: .fit)
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
    @State private var paused = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "Log")
                Spacer()
                Text("\(bus.lines.count)").font(DS.mono(9)).foregroundColor(DS.faint)
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
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }

    // Surface failures without hunting: errors red, milestones green.
    private static func tint(_ l: String) -> Color {
        let s = l.lowercased()
        if s.contains("failed") || s.contains("error") || s.contains("denied") || s.contains("dropped") { return DS.danger }
        if s.contains("first frame") || s.contains("established") || s.contains("engine up") || s.contains("rebuilt") { return DS.live }
        return DS.dim
    }
}
