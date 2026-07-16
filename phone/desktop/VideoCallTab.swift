// VideoCallTab.swift — duplex Mac<->iPhone video call tab for TriNetMonitor.
// Built on the shared components (CallManager/CameraCapture/VideoEncoder/
// VideoDecoder/MeshTransport) — BSD UDP :7000 both ways, SPS/PPS per keyframe,
// forward-secret handshake.
//
// UI: glassmorphism on pure black (#000) — frosted translucent panels
// (.ultraThinMaterial), hairline light borders, soft depth shadows, a cool
// accent. Full-color video behind glass chrome.
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

enum Glass {
    static let bg = Color.black                       // #000
    static let stroke = Color.white.opacity(0.14)     // hairline glass edge
    static let strokeStrong = Color.white.opacity(0.28)
    static let text = Color.white.opacity(0.95)
    static let subtle = Color.white.opacity(0.5)
    static let accent = Color(red: 0.36, green: 0.7, blue: 1.0)  // cool cyan-blue
    static func font(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .rounded)
    }
}

// Frosted-glass surface: translucent material + hairline edge + soft shadow.
private struct GlassCard: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Glass.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }
}
private extension View {
    func glass(_ r: CGFloat = 20) -> some View { modifier(GlassCard(radius: r)) }
}

struct VideoCallTab: View {
    @StateObject private var call = CallManager()

    var body: some View {
        ZStack {
            Glass.bg.ignoresSafeArea()
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
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(Glass.stroke, lineWidth: 1))
                    .frame(width: 84, height: 84)
                Image(systemName: "video.fill").font(.system(size: 32)).foregroundColor(Glass.accent)
            }

            Text("TRI-NET Video").font(Glass.font(26, .semibold)).foregroundColor(Glass.text)
            Text("Encrypted mesh calls · forward-secret")
                .font(Glass.font(12)).foregroundColor(Glass.subtle)

            HStack(spacing: 8) {
                Image(systemName: "person.fill").foregroundColor(Glass.subtle).font(.system(size: 12))
                TextField("Peer IP", text: $call.remoteIP)
                    .textFieldStyle(.plain).font(Glass.font(15)).foregroundColor(Glass.text)
                    .frame(width: 180)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .glass(14).frame(width: 260)

            Text("You · \(call.localIP):\(call.port)")
                .font(Glass.font(11)).foregroundColor(Glass.subtle)

            if !call.recentIPs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(call.recentIPs, id: \.self) { ip in
                        Button(ip) { call.remoteIP = ip }
                            .buttonStyle(.plain).font(Glass.font(11)).foregroundColor(Glass.subtle)
                            .padding(.horizontal, 10).padding(.vertical, 6).glass(10)
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "camera.fill").foregroundColor(Glass.subtle).font(.system(size: 12))
                Picker("", selection: Binding(get: { call.selectedCameraID },
                                              set: { call.selectCamera($0) })) {
                    ForEach(call.cameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName).tag(cam.uniqueID)
                    }
                }
                .labelsHidden().frame(width: 220)
            }

            Button(action: { call.startCall() }) {
                Text("Start Call")
                    .font(Glass.font(16, .semibold)).foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Glass.accent.opacity(0.8), lineWidth: 1.5))
                    .shadow(color: Glass.accent.opacity(0.4), radius: 14, y: 5)
            }
            .buttonStyle(.plain).padding(.top, 6)
        }
        .padding(30)
    }
}

// MARK: - In-call screen

private struct InCallView: View {
    @ObservedObject var call: CallManager
    @State private var pipOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                // Full-color video behind a glass edge
                MonitorRemoteVideo(decoder: call.decoder)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Glass.stroke, lineWidth: 1))
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 8)

                // Status pill
                HStack(spacing: 6) {
                    Circle().fill(call.framesReceived > 0 ? Glass.accent : Glass.subtle)
                        .frame(width: 7, height: 7)
                    Text(call.framesReceived > 0 ? "Secure" : "Connecting")
                        .font(Glass.font(11, .semibold)).foregroundColor(Glass.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Glass.stroke, lineWidth: 1))
                .padding(12)

                // Self preview glass card
                VStack {
                    Spacer().frame(height: 44)
                    if let s = call.previewSession {
                        MonitorCameraPreview(session: s)
                            .frame(width: 150, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Glass.strokeStrong, lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { pipOffset = $0.translation })
                            .padding(.trailing, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Controls + meters in a glass bar
            HStack(spacing: 18) {
                GlassMeter(label: "Mic", level: call.txLevel, muted: call.isMuted)
                GlassMeter(label: "In", level: call.rxLevel, muted: false)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("↑\(call.framesSent)  ↓\(call.framesReceived)")
                        .font(Glass.font(11)).foregroundColor(Glass.subtle)
                    Text(call.status).font(Glass.font(11, .medium))
                        .foregroundColor(call.framesReceived > 0 ? Glass.text : Glass.subtle)
                }
                GlassButton(system: call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted) { call.isMuted.toggle() }
                Menu {
                    ForEach(call.cameras, id: \.uniqueID) { cam in
                        Button(cam.localizedName) { call.selectCamera(cam.uniqueID) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 17)).foregroundColor(Glass.text)
                        .frame(width: 50, height: 50)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Glass.stroke, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).frame(width: 50)
                GlassButton(system: call.cameraOff ? "video.slash.fill" : "video.fill", active: call.cameraOff) { call.cameraOff.toggle() }
                Button(action: { call.endCall() }) {
                    Image(systemName: "phone.down.fill").font(.system(size: 18)).foregroundColor(.white)
                        .frame(width: 56, height: 50)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .shadow(color: Color.red.opacity(0.5), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glass(22)
        }
        .padding(16)
    }
}

// Glass audio meter: translucent track + glowing accent fill.
private struct GlassMeter: View {
    let label: String
    let level: Float
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(muted ? "\(label) · muted" : label)
                .font(Glass.font(10, .medium))
                .foregroundColor(muted ? Glass.subtle : Glass.text)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 92, height: 8)
                    .overlay(Capsule().stroke(Glass.stroke, lineWidth: 0.5))
                if !muted {
                    Capsule()
                        .fill(LinearGradient(colors: [Glass.accent.opacity(0.7), Glass.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, 92 * CGFloat(min(1, level))), height: 8)
                        .shadow(color: Glass.accent.opacity(0.7), radius: 5)
                }
            }
        }
    }
}

// Glass round toggle.
private struct GlassButton: View {
    let system: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 17))
                .foregroundColor(active ? .red : Glass.text)
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(active ? Color.red.opacity(0.6) : Glass.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Display helpers (self-contained: the Monitor target does not compile
// the standalone app's Views.swift)

private struct MonitorRemoteVideo: View {
    @ObservedObject var decoder: VideoDecoder

    var body: some View {
        ZStack {
            Color.black
            if let frame = decoder.currentFrame {
                MonitorFrameView(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Waiting for video").font(Glass.font(13)).foregroundColor(Glass.subtle)
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
