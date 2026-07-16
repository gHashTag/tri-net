// Views.swift — FaceTime-style video call UI for iOS
import SwiftUI
import AVFoundation

// MARK: - Home Screen

struct HomeView: View {
    @StateObject var vm = StreamViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            if vm.phase == .live || vm.phase == .connecting {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                VStack(spacing: 22) {
                    HStack {
                        Text("TRI-NET").font(DS.display(22, .bold)).tracking(1).foregroundColor(DS.text)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape").font(.system(size: 18)).foregroundColor(DS.dim)
                                .frame(width: 42, height: 42).overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("Encrypted mesh · forward-secret")
                        .font(DS.ui(13)).foregroundColor(DS.dim)

                    Spacer()

                    // Primary call button — the one white CTA
                    Button(action: { vm.startCall() }) {
                        ZStack {
                            Circle().fill(vm.cameraAuthorized ? DS.fill : DS.surface)
                                .overlay(Circle().stroke(vm.cameraAuthorized ? Color.clear : DS.hairlineStrong, lineWidth: 1))
                                .frame(width: 128, height: 128)
                            Image(systemName: "video.fill").font(.system(size: 46))
                                .foregroundColor(vm.cameraAuthorized ? DS.onFill : DS.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!vm.cameraAuthorized)

                    // Peer field
                    VStack(spacing: 14) {
                        HStack {
                            SectionLabel(text: "Peer")
                            TextField("Mac IP", text: $vm.remoteIP)
                                .keyboardType(.decimalPad).font(DS.mono(16)).foregroundColor(DS.text)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(DS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline, lineWidth: 1))

                        Text("SELF · \(vm.myIP)").font(DS.mono(12)).foregroundColor(DS.faint)

                        if !vm.recentIPs.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(vm.recentIPs.prefix(3), id: \.self) { ip in
                                    Button(action: { vm.remoteIP = ip }) {
                                        Text(ip).font(DS.mono(11)).foregroundColor(DS.dim)
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Text(vm.cameraAuthorized ? "Tap to call" : "Camera access needed")
                        .font(DS.ui(13, .medium)).foregroundColor(vm.cameraAuthorized ? DS.dim : DS.text)
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

struct CallScreen: View {
    @ObservedObject var vm: StreamViewModel
    @State private var showControls = true
    @State private var showChat = false
    @State private var draft = ""
    private let reactions = ["👍", "❤️", "😂", "👏", "🔥"]

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            RemoteVideoArea(decoder: vm.decoder, phase: vm.phase, remoteIP: vm.remoteIP)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

            // Live reaction — big transient emoji, seen the moment the peer taps.
            if let r = vm.liveReaction {
                Text(r).font(.system(size: 120))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // Self camera PiP
            VStack {
                HStack {
                    Spacer()
                    CameraPreviewView(session: vm.camera.previewSession)
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
                VStack { Spacer(); iChatPanel(vm: vm, draft: $draft, close: { showChat = false }) }
                    .padding(12).transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showControls && !showChat {
                VStack(spacing: 0) {
                    HStack {
                        StatusTag(text: vm.framesReceived > 0 ? "Secure" : "Connecting", live: vm.framesReceived > 0)
                            .background(DS.ink.opacity(0.5), in: Capsule())
                        Spacer()
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
                            Text("↑\(vm.framesSent) ↓\(vm.framesReceived)")
                                .font(DS.mono(11)).foregroundColor(DS.faint)
                        }
                        // Equal-width flexible cells so the row always fits the
                        // phone width (6 controls; each cell centers a 46pt circle).
                        HStack(spacing: 6) {
                            iBtn(system: vm.isMuted ? "mic.slash.fill" : "mic.fill", active: vm.isMuted) { vm.isMuted.toggle() }
                            iBtn(system: "arrow.triangle.2.circlepath.camera.fill", active: false) { vm.camera.switchCamera() }
                            iBtn(system: vm.cameraOff ? "video.slash.fill" : "video.fill", active: vm.cameraOff) { vm.cameraOff.toggle() }
                            iBtn(system: vm.isBlurred ? "person.crop.rectangle.badge.plus.fill" : "person.crop.rectangle", active: vm.isBlurred) { vm.toggleBlur() }
                            iBtn(system: "bubble.left.and.bubble.right\(vm.chat.isEmpty ? "" : ".fill")", active: false) { withAnimation { showChat = true } }
                            Button(action: { vm.stopCall() }) {
                                Image(systemName: "phone.down.fill").font(.system(size: 19)).foregroundColor(DS.onFill)
                                    .frame(width: 46, height: 46).background(DS.danger, in: Circle())
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
            Image(systemName: system).font(.system(size: 18))
                .foregroundColor(active ? DS.danger : DS.text)
                .frame(width: 46, height: 46)
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
