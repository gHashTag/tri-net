// Views.swift — FaceTime-style video call UI for iOS
import SwiftUI
import AVFoundation

// MARK: - Home Screen

struct HomeView: View {
    @StateObject var vm = StreamViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.phase == .live || vm.phase == .connecting {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                VStack(spacing: 22) {
                    // Header
                    HStack {
                        Text("TRI-NET // SECURE LINK")
                            .font(Mil.mono(16, .bold)).tracking(2)
                            .foregroundColor(Mil.line)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape").foregroundColor(Mil.dim)
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("ENCRYPTED MESH VIDEO — FWD-SECRET X25519 / CHACHA20")
                        .font(Mil.mono(9)).tracking(1)
                        .foregroundColor(Mil.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Spacer()

                    // Establish-link button (tactical)
                    Button(action: { vm.startCall() }) {
                        Text("[ ESTABLISH LINK ]")
                            .font(Mil.mono(18, .bold)).tracking(2)
                            .foregroundColor(.black)
                            .padding(.horizontal, 26).padding(.vertical, 16)
                            .background(vm.cameraAuthorized ? Mil.line : Mil.faint)
                    }
                    .disabled(!vm.cameraAuthorized)

                    // Peer IP input
                    VStack(spacing: 12) {
                        HStack {
                            Text("PEER").font(Mil.mono(11, .bold)).foregroundColor(Mil.dim)
                            TextField("MAC IP", text: $vm.remoteIP)
                                .keyboardType(.decimalPad)
                                .font(Mil.mono(16))
                                .foregroundColor(Mil.line)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .overlay(Rectangle().stroke(Mil.faint, lineWidth: 1))

                        Text("SELF \(vm.myIP)")
                            .font(Mil.mono(12)).tracking(1)
                            .foregroundColor(Mil.dim)

                        if !vm.recentIPs.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(vm.recentIPs.prefix(3), id: \.self) { ip in
                                    Button(action: { vm.remoteIP = ip }) {
                                        Text(ip)
                                            .font(Mil.mono(11))
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .overlay(Rectangle().stroke(Mil.faint, lineWidth: 1))
                                            .foregroundColor(Mil.dim)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Text(vm.cameraAuthorized ? "READY // AWAITING OPERATOR" : "OPTIC ACCESS REQUIRED")
                        .font(Mil.mono(11, .bold)).tracking(1)
                        .foregroundColor(vm.cameraAuthorized ? Mil.dim : Mil.line)
                        .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: vm.phase)
        .onAppear { vm.checkPermission(); if vm.cameraAuthorized { vm.camera.startPreview() } }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
    }
}

// MARK: - Call Screen (FaceTime style)

struct RemoteVideoArea: View {
    @ObservedObject var decoder: H264Decoder
    let phase: StreamViewModel.CallPhase
    let remoteIP: String

    var body: some View {
        ZStack {
            Color.black
            if decoder.frameCount > 0, let frame = decoder.currentFrame {
                RemoteVideoDisplay(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text(phase == .connecting ? "Connecting..." : "Waiting for video")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.gray)
                    Text("→ \(remoteIP)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// Tactical palette — grayscale HUD over a full-color video feed (mirrors the
// macOS Monitor's Video Call tab).
enum Mil {
    static let line = Color.white.opacity(0.85)
    static let dim = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.18)
    static func mono(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: s, weight: w, design: .monospaced)
    }
}

struct CallScreen: View {
    @ObservedObject var vm: StreamViewModel
    @State private var showControls = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Remote video full-screen, FULL COLOR. Only the HUD is monochrome.
            RemoteVideoArea(decoder: vm.decoder, phase: vm.phase, remoteIP: vm.remoteIP)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

            // HUD corner brackets over the whole feed
            CornerBrackets().stroke(Mil.line, lineWidth: 1.5)
                .padding(6).ignoresSafeArea().allowsHitTesting(false)

            // Self camera PiP with bracket frame + SELF tag
            VStack {
                HStack {
                    Spacer()
                    CameraPreviewView(session: vm.camera.previewSession)
                        .frame(width: 104, height: 138)
                        .overlay(CornerBrackets().stroke(Mil.line, lineWidth: 1.5))
                        .overlay(alignment: .topLeading) {
                            Text("SELF").font(Mil.mono(9, .bold))
                                .foregroundColor(Mil.line)
                                .padding(3).background(Color.black.opacity(0.6)).padding(2)
                        }
                        .padding(12)
                }
                Spacer()
            }

            if showControls {
                VStack(spacing: 0) {
                    // Top status strip
                    HStack {
                        Text("● REC").font(Mil.mono(12, .bold)).foregroundColor(Mil.line)
                        Text("DOWNLINK \(vm.remoteIP)").font(Mil.mono(11)).foregroundColor(Mil.dim)
                        Spacer()
                        Text(vm.framesReceived > 0 ? "SECURE" : "NEG…")
                            .font(Mil.mono(11, .bold)).foregroundColor(vm.framesReceived > 0 ? Mil.line : Mil.dim)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))

                    Spacer()

                    // Bottom: meters + telemetry
                    VStack(spacing: 12) {
                        HStack(alignment: .bottom, spacing: 20) {
                            AudioMeter(label: "TX", level: vm.txLevel, muted: vm.isMuted)
                            AudioMeter(label: "RX", level: vm.rxLevel, muted: false)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("TX \(vm.framesSent)  RX \(vm.framesReceived)")
                                    .font(Mil.mono(11)).foregroundColor(Mil.dim)
                                Text("FWD-SECRET").font(Mil.mono(10, .bold)).tracking(1).foregroundColor(Mil.line)
                            }
                        }

                        HStack(spacing: 14) {
                            MilButton(system: vm.isMuted ? "mic.slash" : "mic", on: !vm.isMuted, label: "MIC") { vm.isMuted.toggle() }
                            MilButton(system: "arrow.triangle.2.circlepath.camera", on: true, label: "FLIP") { vm.camera.switchCamera() }
                            MilButton(system: vm.cameraOff ? "video.slash" : "video", on: !vm.cameraOff, label: "CAM") { vm.cameraOff.toggle() }
                            Spacer()
                            Button(action: { vm.stopCall() }) {
                                Text("[ TERMINATE ]").font(Mil.mono(13, .bold)).tracking(1)
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Mil.line)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color.black.opacity(0.6))
                }
            }
        }
    }
}

// Segmented monochrome audio meter (matches the Monitor's).
struct AudioMeter: View {
    let label: String
    let level: Float
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
                    Rectangle().fill(lit ? Mil.line : Mil.faint).frame(width: 7, height: 16)
                }
            }
        }
    }
}

// Tactical toggle button.
struct MilButton: View {
    let system: String
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.system(size: 18))
                Text(label).font(Mil.mono(9, .bold))
            }
            .foregroundColor(on ? Mil.line : Mil.dim)
            .frame(width: 60, height: 52)
            .overlay(Rectangle().stroke(on ? Mil.line : Mil.faint, lineWidth: 1))
        }
    }
}

// L-shaped corner brackets around the frame.
struct CornerBrackets: Shape {
    var len: CGFloat = 26
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + len)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - len)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - len, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - len))
        return p
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
