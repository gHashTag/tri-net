// Views.swift — FaceTime-style video call UI for iOS
import SwiftUI
import AVFoundation

// MARK: - Home Screen

struct HomeView: View {
    @StateObject var vm = StreamViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            GlassBackdrop()

            if vm.phase == .live || vm.phase == .connecting {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                VStack(spacing: 22) {
                    // Header
                    HStack {
                        Text("TRI-NET Video")
                            .font(Neu.font(24, .semibold))
                            .foregroundColor(Neu.text)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 18)).foregroundColor(Neu.subtle)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Neu.specular, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("Encrypted mesh calls · forward-secret")
                        .font(Neu.font(12)).foregroundColor(Neu.subtle)

                    Spacer()

                    // Big glass call button
                    Button(action: { vm.startCall() }) {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .overlay(Circle().stroke(vm.cameraAuthorized ? Neu.accent.opacity(0.8) : Neu.stroke, lineWidth: 1.5))
                                .frame(width: 128, height: 128)
                                .shadow(color: vm.cameraAuthorized ? Neu.accent.opacity(0.5) : .black.opacity(0.4), radius: 16, y: 6)
                            Image(systemName: "video.fill")
                                .font(.system(size: 46))
                                .foregroundColor(vm.cameraAuthorized ? Neu.accent : Neu.subtle)
                        }
                    }
                    .disabled(!vm.cameraAuthorized)

                    // Peer IP input (glass field)
                    VStack(spacing: 14) {
                        HStack {
                            Image(systemName: "person.fill").foregroundColor(Neu.subtle).font(.system(size: 13))
                            TextField("Mac IP", text: $vm.remoteIP)
                                .keyboardType(.decimalPad)
                                .font(Neu.font(17))
                                .foregroundColor(Neu.text)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Neu.specular, lineWidth: 1))

                        Text("You · \(vm.myIP)")
                            .font(Neu.font(12)).foregroundColor(Neu.subtle)

                        if !vm.recentIPs.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(vm.recentIPs.prefix(3), id: \.self) { ip in
                                    Button(action: { vm.remoteIP = ip }) {
                                        Text(ip)
                                            .font(Neu.font(11))
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(.ultraThinMaterial, in: Capsule())
                                            .overlay(Capsule().strokeBorder(Neu.specular, lineWidth: 1))
                                            .foregroundColor(Neu.subtle)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Text(vm.cameraAuthorized ? "Tap to call" : "Camera access needed")
                        .font(Neu.font(13, .medium))
                        .foregroundColor(vm.cameraAuthorized ? Neu.subtle : Neu.accent)
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

// Neumorphic palette + soft light/shadow (mirrors the macOS Monitor).
// Glassmorphism palette on pure black (#000). "Neu" name kept so HomeView
// refs stay valid; values are now glass tones (mirrors the macOS Monitor).
enum Neu {
    static let base = Color.black                     // #000
    static let stroke = Color.white.opacity(0.14)
    static let strokeStrong = Color.white.opacity(0.28)
    static let text = Color.white.opacity(0.95)
    static let subtle = Color.white.opacity(0.55)
    static let accent = Color.white                    // monochrome accent
    static func font(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font {
        .system(size: s, weight: w, design: .rounded)
    }
    // Specular edge: light-refracting rim, brightest at top-left.
    static var specular: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12), .white.opacity(0.03)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// #000 base with dim grayscale light pools so frosted glass has something
// varied to refract (a flat black field makes the blur invisible). Monochrome
// soft white "studio lights" — reads black-and-white, stays near-black.
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            Circle().fill(.white).frame(width: 380).blur(radius: 120).opacity(0.13)
                .offset(x: -140, y: -220)
            Circle().fill(.white).frame(width: 340).blur(radius: 120).opacity(0.07)
                .offset(x: 160, y: 260)
            Circle().fill(.white).frame(width: 300).blur(radius: 110).opacity(0.05)
                .offset(x: 120, y: -60)
        }
        .ignoresSafeArea()
    }
}

struct CallScreen: View {
    @ObservedObject var vm: StreamViewModel
    @State private var showControls = true

    var body: some View {
        ZStack {
            GlassBackdrop()

            // Remote video full-screen, FULL COLOR.
            RemoteVideoArea(decoder: vm.decoder, phase: vm.phase, remoteIP: vm.remoteIP)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

            // Self camera PiP — glass card
            VStack {
                HStack {
                    Spacer()
                    CameraPreviewView(session: vm.camera.previewSession)
                        .frame(width: 104, height: 138)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Neu.specular, lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        .padding(14)
                }
                Spacer()
            }
            .padding(.top, 44)

            if showControls {
                VStack(spacing: 0) {
                    // Top glass pills
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(vm.framesReceived > 0 ? Neu.accent : Neu.subtle)
                                .frame(width: 7, height: 7)
                            Text(vm.framesReceived > 0 ? "Secure" : "Connecting")
                                .font(Neu.font(12, .semibold)).foregroundColor(Neu.text)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Neu.specular, lineWidth: 1))
                        Spacer()
                        Text(vm.remoteIP).font(Neu.font(11)).foregroundColor(Neu.subtle)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Neu.specular, lineWidth: 1))
                    }
                    .padding(.horizontal, 16).padding(.top, 8)

                    Spacer()

                    // Meters + controls in a glass panel
                    VStack(spacing: 16) {
                        HStack(spacing: 22) {
                            SoftMeter(label: "Mic", level: vm.txLevel, muted: vm.isMuted)
                            SoftMeter(label: "In", level: vm.rxLevel, muted: false)
                            Spacer()
                            Text("↑\(vm.framesSent) ↓\(vm.framesReceived)")
                                .font(Neu.font(11)).foregroundColor(Neu.subtle)
                        }

                        HStack(spacing: 18) {
                            SoftButton(system: vm.isMuted ? "mic.slash.fill" : "mic.fill", active: vm.isMuted) { vm.isMuted.toggle() }
                            SoftButton(system: "arrow.triangle.2.circlepath.camera.fill", active: false) { vm.camera.switchCamera() }
                            SoftButton(system: vm.cameraOff ? "video.slash.fill" : "video.fill", active: vm.cameraOff) { vm.cameraOff.toggle() }
                            Spacer()
                            Button(action: { vm.stopCall() }) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 22)).foregroundColor(.white)
                                    .frame(width: 66, height: 58)
                                    .background(Color.red.opacity(0.85), in: Capsule())
                                    .shadow(color: Color.red.opacity(0.5), radius: 10, y: 4)
                            }
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Neu.specular, lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
    }
}

// Glass audio meter: translucent track + glowing accent fill.
struct SoftMeter: View {
    let label: String
    let level: Float
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(muted ? "\(label) · muted" : label)
                .font(Neu.font(10, .medium))
                .foregroundColor(muted ? Neu.subtle : Neu.text)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 92, height: 8)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                if !muted {
                    Capsule()
                        .fill(LinearGradient(colors: [Neu.accent.opacity(0.7), Neu.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, 92 * CGFloat(min(1, level))), height: 8)
                        .shadow(color: Neu.accent.opacity(0.7), radius: 5)
                }
            }
        }
    }
}

// Glass round toggle.
struct SoftButton: View {
    let system: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20))
                .foregroundColor(active ? .red : Neu.text)
                .frame(width: 58, height: 58)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(active ? AnyView(Circle().stroke(Color.red.opacity(0.6), lineWidth: 1)) : AnyView(Circle().strokeBorder(Neu.specular, lineWidth: 1)))
        }
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
