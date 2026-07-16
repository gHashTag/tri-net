// VideoCallTab.swift — duplex Mac<->iPhone video call tab for TriNetMonitor.
// Built on the shared components (CallManager/CameraCapture/VideoEncoder/
// VideoDecoder/MeshTransport) — BSD UDP :7000 both ways, SPS/PPS per keyframe,
// forward-secret handshake.
//
// UI: soft neumorphic design — a single dark base tone, elements defined by
// paired highlight/shadow so controls read as gently extruded, meters as
// inset channels. Full-color video in a raised rounded frame.
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

// Neumorphic palette + soft light/shadow.
enum Neu {
    static let base = Color(red: 0.145, green: 0.155, blue: 0.180)  // dark slate
    static let raised = Color(red: 0.165, green: 0.176, blue: 0.204)
    static let light = Color.white.opacity(0.055)   // top-left highlight
    static let dark = Color.black.opacity(0.55)      // bottom-right shadow
    static let text = Color.white.opacity(0.92)
    static let subtle = Color.white.opacity(0.42)
    static let accent = Color(red: 0.40, green: 0.62, blue: 1.0)     // soft blue
    static func font(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .rounded)
    }
}

// Extruded surface: fill + paired soft shadows.
private struct Raised: ViewModifier {
    var radius: CGFloat = 18
    var pressed: Bool = false
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Neu.raised)
                .shadow(color: pressed ? .clear : Neu.dark, radius: 7, x: 5, y: 5)
                .shadow(color: pressed ? .clear : Neu.light, radius: 7, x: -5, y: -5)
        )
    }
}
private extension View {
    func raised(_ r: CGFloat = 18, pressed: Bool = false) -> some View {
        modifier(Raised(radius: r, pressed: pressed))
    }
}

// Inset channel: base fill + inner-shadow-like edge, for meter tracks & fields.
private struct InsetTrack: View {
    var radius: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Neu.base)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [Neu.dark, Neu.light],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 2.5)
                    .blur(radius: 1.5)
                    .mask(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
    }
}

struct VideoCallTab: View {
    @StateObject private var call = CallManager()

    var body: some View {
        ZStack {
            Neu.base.ignoresSafeArea()
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
                Circle().fill(Neu.raised)
                    .frame(width: 84, height: 84)
                    .shadow(color: Neu.dark, radius: 8, x: 6, y: 6)
                    .shadow(color: Neu.light, radius: 8, x: -6, y: -6)
                Image(systemName: "video.fill")
                    .font(.system(size: 32)).foregroundColor(Neu.accent)
            }

            Text("TRI-NET Video")
                .font(Neu.font(26, .semibold)).foregroundColor(Neu.text)
            Text("Encrypted mesh calls · forward-secret")
                .font(Neu.font(12)).foregroundColor(Neu.subtle)

            // Peer field (inset)
            HStack(spacing: 8) {
                Image(systemName: "person.fill").foregroundColor(Neu.subtle).font(.system(size: 12))
                TextField("Peer IP", text: $call.remoteIP)
                    .textFieldStyle(.plain)
                    .font(Neu.font(15)).foregroundColor(Neu.text)
                    .frame(width: 180)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(InsetTrack(radius: 14))
            .frame(width: 260)

            Text("You · \(call.localIP):\(call.port)")
                .font(Neu.font(11)).foregroundColor(Neu.subtle)

            if !call.recentIPs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(call.recentIPs, id: \.self) { ip in
                        Button(ip) { call.remoteIP = ip }
                            .buttonStyle(.plain)
                            .font(Neu.font(11)).foregroundColor(Neu.subtle)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .raised(10)
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "camera.fill").foregroundColor(Neu.subtle).font(.system(size: 12))
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
                    .font(Neu.font(16, .semibold)).foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .fill(Neu.accent)
                            .shadow(color: Neu.accent.opacity(0.5), radius: 12, y: 5)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
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
            // Video in a raised rounded frame (full color)
            ZStack(alignment: .topTrailing) {
                MonitorRemoteVideo(decoder: call.decoder)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Neu.light, lineWidth: 1)
                    )
                    .shadow(color: Neu.dark, radius: 10, x: 6, y: 6)
                    .shadow(color: Neu.light, radius: 10, x: -6, y: -6)

                // Status pill
                HStack(spacing: 6) {
                    Circle().fill(call.framesReceived > 0 ? Color.green : Neu.subtle)
                        .frame(width: 7, height: 7)
                    Text(call.framesReceived > 0 ? "Secure" : "Connecting")
                        .font(Neu.font(11, .semibold)).foregroundColor(Neu.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Neu.raised.opacity(0.9)))
                .padding(12)

                // Self preview PiP (raised)
                VStack {
                    Spacer().frame(height: 44)
                    if let s = call.previewSession {
                        MonitorCameraPreview(session: s)
                            .frame(width: 150, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Neu.dark, radius: 6, x: 4, y: 4)
                            .shadow(color: Neu.light, radius: 6, x: -4, y: -4)
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { pipOffset = $0.translation })
                            .padding(.trailing, 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Meters + telemetry
            HStack(spacing: 22) {
                SoftMeter(label: "Mic", level: call.txLevel, muted: call.isMuted)
                SoftMeter(label: "In", level: call.rxLevel, muted: false)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("↑\(call.framesSent)  ↓\(call.framesReceived)")
                        .font(Neu.font(11)).foregroundColor(Neu.subtle)
                    Text(call.status).font(Neu.font(11, .medium))
                        .foregroundColor(call.framesReceived > 0 ? Neu.text : Neu.subtle)
                }
            }
            .padding(.horizontal, 6)

            // Controls (soft round)
            HStack(spacing: 16) {
                SoftButton(system: call.isMuted ? "mic.slash.fill" : "mic.fill",
                           active: call.isMuted, tint: .red) { call.isMuted.toggle() }
                Menu {
                    ForEach(call.cameras, id: \.uniqueID) { cam in
                        Button(cam.localizedName) { call.selectCamera(cam.uniqueID) }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                        .font(.system(size: 18)).foregroundColor(Neu.text)
                        .frame(width: 54, height: 54).raised(27)
                }
                .menuStyle(.borderlessButton).frame(width: 54)
                SoftButton(system: call.cameraOff ? "video.slash.fill" : "video.fill",
                           active: call.cameraOff, tint: .red) { call.cameraOff.toggle() }
                Spacer()
                Button(action: { call.endCall() }) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 20)).foregroundColor(.white)
                        .frame(width: 60, height: 54)
                        .background(RoundedRectangle(cornerRadius: 27, style: .continuous)
                            .fill(Color.red)
                            .shadow(color: Color.red.opacity(0.45), radius: 10, y: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6).padding(.bottom, 4)
        }
        .padding(16)
    }
}

// Soft horizontal audio meter: inset channel with an accent fill.
private struct SoftMeter: View {
    let label: String
    let level: Float
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(muted ? "\(label) · muted" : label)
                .font(Neu.font(10, .medium))
                .foregroundColor(muted ? Neu.subtle : Neu.text)
            ZStack(alignment: .leading) {
                InsetTrack(radius: 5).frame(width: 96, height: 8)
                if !muted {
                    Capsule()
                        .fill(LinearGradient(colors: [Neu.accent.opacity(0.7), Neu.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, 96 * CGFloat(min(1, level))), height: 8)
                        .shadow(color: Neu.accent.opacity(0.6), radius: 4)
                }
            }
        }
    }
}

// Soft round toggle button.
private struct SoftButton: View {
    let system: String
    let active: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18))
                .foregroundColor(active ? tint : Neu.text)
                .frame(width: 54, height: 54)
                .raised(27, pressed: active)
                .overlay(active ? RoundedRectangle(cornerRadius: 27).stroke(tint.opacity(0.5), lineWidth: 1) : nil)
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
            Neu.base
            if let frame = decoder.currentFrame {
                MonitorFrameView(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Waiting for video").font(Neu.font(13)).foregroundColor(Neu.subtle)
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
