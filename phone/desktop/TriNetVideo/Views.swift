// Views.swift — FaceTime-style video call UI
import SwiftUI
import AVFoundation
import AppKit

// MARK: - Main Entry View

struct CallView: View {
    @EnvironmentObject var call: CallManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if call.isInCall {
                ActiveCallView()
            } else {
                HomeScreen()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Home Screen (before call)

struct HomeScreen: View {
    @EnvironmentObject var call: CallManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon / camera button
            Button(action: { call.startCall() }) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 100, height: 100)
                        .shadow(color: .blue.opacity(0.5), radius: 20)

                    Image(systemName: "video.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .scaleEffect(call.isStarting ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: call.isStarting)

            VStack(spacing: 6) {
                Text("TRI-NET Video")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Encrypted mesh video calls")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }

            // IP configuration
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .foregroundColor(.gray)
                        .font(.system(size: 18))

                    TextField("Remote IP Address", text: $call.remoteIP)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 24)

                // Show your IP
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("You: \(call.localIP):7001")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green.opacity(0.8))
                }

                // Recent IPs
                if !call.recentIPs.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(call.recentIPs, id: \.self) { ip in
                            Button(action: { call.remoteIP = ip }) {
                                Text(ip)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer()

            // Start call button
            Button(action: { call.startCall() }) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                    Text("Start Video Call")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(30)
                .shadow(color: .green.opacity(0.3), radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(call.remoteIP.isEmpty)
            .opacity(call.remoteIP.isEmpty ? 0.5 : 1.0)

            Spacer()
        }
    }
}

// MARK: - Active Call View

struct ActiveCallView: View {
    @EnvironmentObject var call: CallManager
    @State private var showControls = true
    @State private var pipOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // Full-screen remote video
            RemoteVideoView(decoder: call.decoder)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                }

            // PiP self-view (draggable)
            VStack {
                HStack {
                    Spacer()
                    if let session = call.previewSession {
                        CameraPreview(session: session)
                            .frame(width: 140, height: 105)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3), lineWidth: 2))
                            .shadow(color: .black.opacity(0.5), radius: 8)
                            .offset(pipOffset)
                            .gesture(
                                DragGesture()
                                    .onChanged { pipOffset = $0.translation }
                            )
                            .padding(.trailing, 16)
                            .padding(.top, 16)
                    }
                }
                Spacer()
            }

            // Floating controls (FaceTime style)
            if showControls {
                VStack {
                    Spacer()

                    HStack(spacing: 24) {
                        // Stats
                        VStack(spacing: 2) {
                            Text("↑\(call.framesSent) ↓\(call.framesReceived)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                            Text(call.status)
                                .font(.system(size: 10))
                                .foregroundColor(call.framesReceived > 0 ? .green : .orange)
                            if !call.linkInfo.isEmpty {
                                Text(call.linkInfo)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.45))
                            }
                        }

                        Spacer()

                        // Mute toggle
                        ControlButton(icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                                      color: call.isMuted ? .red : Color.white.opacity(0.3)) {
                            call.isMuted.toggle()
                        }

                        // Camera toggle
                        ControlButton(icon: call.cameraOff ? "video.slash.fill" : "video.fill",
                                      color: call.cameraOff ? .red : Color.white.opacity(0.3)) {
                            call.cameraOff.toggle()
                        }

                        // End call
                        ControlButton(icon: "phone.down.fill",
                                      color: .red, size: 64) {
                            call.endCall()
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
                }
            }
        }
    }
}

// MARK: - Reusable Components

struct ControlButton: View {
    let icon: String
    let color: Color
    var size: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size == 52 ? 20 : 24))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(color)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.3), radius: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Camera Preview (macOS NSView wrapper)

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true // must be set BEFORE touching view.layer, else it's nil
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer?.addSublayer(layer)
        context.coordinator.previewLayer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = nsView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Remote Video Display

struct RemoteVideoView: View {
    @ObservedObject var decoder: VideoDecoder

    var body: some View {
        ZStack {
            Color.black

            if let frame = decoder.currentFrame {
                VideoFrameView(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Connecting...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.gray)
                    Text("Waiting for remote video")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct VideoFrameView: NSViewRepresentable {
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

        // Set contents on the view's own layer — a fresh sublayer sized to
        // nsView.bounds is zero-sized before layout and renders nothing
        nsView.layer?.contents = img
        nsView.layer?.contentsGravity = .resizeAspect
    }
}
