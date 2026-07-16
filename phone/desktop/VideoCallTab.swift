// VideoCallTab.swift — duplex Mac<->iPhone video call tab for TriNetMonitor.
// Built on the shared components (CallManager/CameraCapture/VideoEncoder/
// VideoDecoder/MeshTransport) — BSD UDP :7000 both ways, SPS/PPS per keyframe.
// Previous receive-only VideoEngine version lives in git history.
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
            Color.black
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
        VStack(spacing: 16) {
            Image(systemName: "video.fill")
                .font(.system(size: 42))
                .foregroundColor(.blue)
            Text("TRI-NET Video")
                .font(.system(size: 24, weight: .bold))
            Text("Encrypted mesh video calls")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack {
                Image(systemName: "person.crop.circle")
                    .foregroundColor(.secondary)
                TextField("Peer IP", text: $call.remoteIP)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 220)
            }

            Text("You: \(call.localIP):\(call.port)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.green)

            if !call.recentIPs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(call.recentIPs, id: \.self) { ip in
                        Button(ip) { call.remoteIP = ip }
                            .buttonStyle(.bordered)
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }

            Picker(selection: Binding(get: { call.selectedCameraID },
                                      set: { call.selectCamera($0) })) {
                ForEach(call.cameras, id: \.uniqueID) { cam in
                    Text(cam.localizedName).tag(cam.uniqueID)
                }
            } label: {
                Label("Camera", systemImage: "camera")
            }
            .frame(width: 300)

            Button(action: { call.startCall() }) {
                Label("Start Video Call", systemImage: "phone.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
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
            MonitorRemoteVideo(decoder: call.decoder)

            // Self-preview PiP
            VStack {
                HStack {
                    Spacer()
                    if let s = call.previewSession {
                        MonitorCameraPreview(session: s)
                            .frame(width: 150, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3), lineWidth: 1.5))
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { pipOffset = $0.translation })
                            .padding(12)
                    }
                }
                Spacer()
            }

            // Bottom bar: stats + controls
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{2191}\(call.framesSent) \u{2193}\(call.framesReceived)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                        Text(call.status)
                            .font(.system(size: 11))
                            .foregroundColor(call.framesReceived > 0 ? .green : .orange)
                    }
                    Spacer()

                    Menu {
                        ForEach(call.cameras, id: \.uniqueID) { cam in
                            Button(cam.localizedName) { call.selectCamera(cam.uniqueID) }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 15))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 50)
                    .help("Switch camera")

                    Button(action: { call.cameraOff.toggle() }) {
                        Image(systemName: call.cameraOff ? "video.slash.fill" : "video.fill")
                            .font(.system(size: 15))
                            .frame(width: 40, height: 30)
                    }
                    .help("Camera on/off")

                    Button(action: { call.endCall() }) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .frame(width: 54, height: 30)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("End call")
                }
                .padding(14)
                .background(.black.opacity(0.4))
            }
        }
    }
}

// MARK: - Display helpers (self-contained: Monitor target does not compile
// the standalone app's Views.swift)

private struct MonitorRemoteVideo: View {
    @ObservedObject var decoder: VideoDecoder

    var body: some View {
        ZStack {
            Color.black
            if let frame = decoder.currentFrame {
                MonitorFrameView(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text("Waiting for remote video")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
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
        // Contents go on the view's own layer — a fresh sublayer sized to
        // nsView.bounds is zero-sized before layout and renders nothing
        nsView.layer?.contents = img
        nsView.layer?.contentsGravity = .resizeAspect
    }
}

private struct MonitorCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true // must be set BEFORE touching view.layer
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
