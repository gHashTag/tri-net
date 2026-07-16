// VideoCallTab.swift — duplex Mac<->iPhone video call tab for TriNetMonitor.
// Built on the shared components (CallManager/CameraCapture/VideoEncoder/
// VideoDecoder/MeshTransport) — BSD UDP :7000 both ways, SPS/PPS per keyframe,
// forward-secret handshake.
//
// UI: monochrome tactical HUD — black field, white hairlines, monospaced
// uppercase labels, corner brackets, and segmented TX/RX audio meters so the
// operator can see the uplink/downlink audio live.
import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

// Tactical palette — grayscale only.
private enum Mil {
    static let bg = Color.black
    static let line = Color.white.opacity(0.85)
    static let dim = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.18)
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w, design: .monospaced)
    }
}

struct VideoCallTab: View {
    @StateObject private var call = CallManager()

    var body: some View {
        ZStack {
            Mil.bg
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
            Text("TRI-NET // SECURE LINK")
                .font(Mil.mono(20, .bold)).tracking(4)
                .foregroundColor(Mil.line)
            Text("ENCRYPTED MESH VIDEO — FWD-SECRET X25519 / CHACHA20")
                .font(Mil.mono(10)).tracking(2)
                .foregroundColor(Mil.dim)

            Rectangle().fill(Mil.faint).frame(height: 1).frame(maxWidth: 340)

            HStack(spacing: 10) {
                Text("PEER").font(Mil.mono(11, .bold)).foregroundColor(Mil.dim)
                TextField("", text: $call.remoteIP)
                    .textFieldStyle(.plain)
                    .font(Mil.mono(14))
                    .foregroundColor(Mil.line)
                    .frame(width: 200)
                    .padding(6)
                    .overlay(Rectangle().stroke(Mil.faint, lineWidth: 1))
            }

            Text("SELF \(call.localIP):\(call.port)")
                .font(Mil.mono(11)).tracking(1)
                .foregroundColor(Mil.dim)

            if !call.recentIPs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(call.recentIPs, id: \.self) { ip in
                        Button(ip) { call.remoteIP = ip }
                            .buttonStyle(.plain)
                            .font(Mil.mono(10))
                            .foregroundColor(Mil.dim)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .overlay(Rectangle().stroke(Mil.faint, lineWidth: 1))
                    }
                }
            }

            HStack(spacing: 10) {
                Text("OPTIC").font(Mil.mono(11, .bold)).foregroundColor(Mil.dim)
                Picker("", selection: Binding(get: { call.selectedCameraID },
                                              set: { call.selectCamera($0) })) {
                    ForEach(call.cameras, id: \.uniqueID) { cam in
                        Text(cam.localizedName.uppercased()).tag(cam.uniqueID)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            Button(action: { call.startCall() }) {
                Text("[ ESTABLISH LINK ]")
                    .font(Mil.mono(15, .bold)).tracking(2)
                    .foregroundColor(.black)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(Mil.line)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(30)
    }
}

// MARK: - In-call screen

private struct InCallView: View {
    @ObservedObject var call: CallManager
    @State private var pipOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // Remote feed stays in full color; only the HUD is monochrome
            MonitorRemoteVideo(decoder: call.decoder)

            // HUD corner brackets over the whole feed
            CornerBrackets()
                .stroke(Mil.line, lineWidth: 1.5)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Top status strip
                HStack {
                    Text("● REC").font(Mil.mono(11, .bold)).foregroundColor(Mil.line)
                    Text("DOWNLINK \(call.remoteIP)")
                        .font(Mil.mono(11)).foregroundColor(Mil.dim)
                    Spacer()
                    Text(call.framesReceived > 0 ? "SECURE // FWD-SECRET" : "NEGOTIATING…")
                        .font(Mil.mono(11, .bold)).tracking(1)
                        .foregroundColor(call.framesReceived > 0 ? Mil.line : Mil.dim)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.55))

                Spacer()

                // Bottom: meters + telemetry + controls
                VStack(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 18) {
                        AudioMeter(label: "TX", level: call.txLevel, muted: call.isMuted)
                        AudioMeter(label: "RX", level: call.rxLevel, muted: false)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("TX \(call.framesSent)  RX \(call.framesReceived)")
                                .font(Mil.mono(11)).foregroundColor(Mil.dim)
                            Text(call.status.uppercased())
                                .font(Mil.mono(11, .bold)).tracking(1)
                                .foregroundColor(call.framesReceived > 0 ? Mil.line : Mil.dim)
                        }
                    }

                    HStack(spacing: 10) {
                        MilButton(system: call.isMuted ? "mic.slash" : "mic",
                                  on: !call.isMuted, label: "MIC") { call.isMuted.toggle() }
                        Menu {
                            ForEach(call.cameras, id: \.uniqueID) { cam in
                                Button(cam.localizedName) { call.selectCamera(cam.uniqueID) }
                            }
                        } label: {
                            Text("OPTIC ▾").font(Mil.mono(12, .bold)).foregroundColor(Mil.line)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 74)
                        MilButton(system: call.cameraOff ? "video.slash" : "video",
                                  on: !call.cameraOff, label: "CAM") { call.cameraOff.toggle() }
                        Spacer()
                        Button(action: { call.endCall() }) {
                            Text("[ TERMINATE ]")
                                .font(Mil.mono(12, .bold)).tracking(1)
                                .foregroundColor(.black)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Mil.line)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.6))
            }

            // Self-preview PiP with bracket frame
            VStack {
                HStack {
                    Spacer()
                    if let s = call.previewSession {
                        MonitorCameraPreview(session: s)
                            .frame(width: 150, height: 112)
                            .overlay(CornerBrackets().stroke(Mil.line, lineWidth: 1.5))
                            .overlay(alignment: .topLeading) {
                                Text("SELF").font(Mil.mono(9, .bold))
                                    .foregroundColor(Mil.line)
                                    .padding(3).background(Color.black.opacity(0.6))
                                    .padding(2)
                            }
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { pipOffset = $0.translation })
                            .padding(12)
                    }
                }
                Spacer()
            }
            .padding(.top, 36)
        }
    }
}

// MARK: - Tactical audio meter (segmented, monochrome)

private struct AudioMeter: View {
    let label: String
    let level: Float      // 0...1
    let muted: Bool
    private let segments = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(muted ? "\(label) MUTE" : label)
                .font(Mil.mono(10, .bold)).tracking(1)
                .foregroundColor(muted ? Mil.dim : Mil.line)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    let lit = !muted && Float(i) / Float(segments) < level
                    Rectangle()
                        .fill(lit ? Mil.line : Mil.faint)
                        .frame(width: 6, height: 14)
                }
            }
        }
    }
}

// MARK: - Tactical toggle button

private struct MilButton: View {
    let system: String
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: system).font(.system(size: 14))
                Text(label).font(Mil.mono(8, .bold))
            }
            .foregroundColor(on ? Mil.line : Mil.dim)
            .frame(width: 48, height: 38)
            .overlay(Rectangle().stroke(on ? Mil.line : Mil.faint, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// L-shaped corner brackets around the frame.
private struct CornerBrackets: Shape {
    var len: CGFloat = 22
    func path(in r: CGRect) -> Path {
        var p = Path()
        // TL
        p.move(to: CGPoint(x: r.minX, y: r.minY + len)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        // TR
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        // BL
        p.move(to: CGPoint(x: r.minX, y: r.maxY - len)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.maxY))
        // BR
        p.move(to: CGPoint(x: r.maxX - len, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - len))
        return p
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
                    Text("ACQUIRING SIGNAL").font(Mil.mono(13, .bold)).tracking(2).foregroundColor(Mil.line)
                    Text("AWAITING DOWNLINK").font(Mil.mono(10)).tracking(1).foregroundColor(Mil.dim)
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
