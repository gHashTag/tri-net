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
            Text("Encrypted mesh · forward-secret")
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
                MonitorRemoteVideo(decoder: call.decoder)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).stroke(DS.hairline, lineWidth: 1))

                // Floating reaction
                if let r = call.liveReaction {
                    Text(r).font(.system(size: 90))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusTag(text: call.framesReceived > 0 ? "Secure" : "Connecting", live: call.framesReceived > 0)
                            .background(DS.ink.opacity(0.5), in: Capsule())
                        if call.isScreenSharing {
                            StatusTag(text: "Sharing Screen", live: true).background(DS.ink.opacity(0.5), in: Capsule())
                        }
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
