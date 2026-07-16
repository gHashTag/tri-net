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
                VStack(spacing: 24) {
                    // Header
                    HStack {
                        Text("TRI-NET")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.title2).foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("VIDEO CALL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.blue).tracking(4)

                    Spacer()

                    // Big call button
                    Button(action: { vm.startCall() }) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color.green, Color.green.opacity(0.7)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .frame(width: 120, height: 120)
                                .shadow(color: .green.opacity(0.4), radius: 20)

                            Image(systemName: "video.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white)
                        }
                    }
                    .disabled(!vm.cameraAuthorized)

                    // Remote IP input
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .foregroundColor(.gray)
                            TextField("Enter Mac IP Address", text: $vm.remoteIP)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 18, design: .monospaced))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(14)

                        // Your IP for the other side
                        Text("Your IP: \(vm.myIP)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.cyan)

                        // Recent IPs
                        if !vm.recentIPs.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(vm.recentIPs.prefix(3), id: \.self) { ip in
                                    Button(action: { vm.remoteIP = ip }) {
                                        Text(ip)
                                            .font(.system(size: 12, design: .monospaced))
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(Color.blue.opacity(0.2))
                                            .cornerRadius(10)
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Text(vm.cameraAuthorized ? "Tap to call" : "Camera access needed")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(vm.cameraAuthorized ? .white : .orange)
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

struct CallScreen: View {
    @ObservedObject var vm: StreamViewModel
    @State private var showControls = true
    @State private var pipExpanded = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Remote video (full screen)
            if vm.decoder.frameCount > 0, let frame = vm.decoder.currentFrame {
                RemoteVideoDisplay(imageBuffer: frame, frameId: vm.decoder.frameCount)
                    .id(vm.decoder.frameCount)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showControls.toggle() } }
            } else {
                // Connecting state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text(vm.phase == .connecting ? "Connecting..." : "Waiting for video")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.gray)
                    Text("→ \(vm.remoteIP)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Self camera PiP
            VStack {
                HStack {
                    Spacer()
                    CameraPreviewView(session: vm.camera.previewSession)
                        .frame(width: pipExpanded ? 200 : 100, height: pipExpanded ? 150 : 75)
                        .clipShape(RoundedRectangle(cornerRadius: pipExpanded ? 16 : 12))
                        .overlay(RoundedRectangle(cornerRadius: pipExpanded ? 16 : 12)
                            .stroke(.white.opacity(0.3), lineWidth: 2))
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        .padding(16)
                        .onTapGesture { withAnimation(.spring()) { pipExpanded.toggle() } }
                }
                Spacer()
            }

            // Floating controls
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("LIVE")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                        }
                        Spacer()
                        Text("↑\(vm.framesSent) ↓\(vm.framesReceived)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .padding()

                    Spacer()

                    // Bottom controls
                    HStack(spacing: 40) {
                        // Mute
                        Button(action: { vm.isMuted.toggle() }) {
                            ZStack {
                                Circle()
                                    .fill(vm.isMuted ? Color.red : Color.white.opacity(0.2))
                                    .frame(width: 60, height: 60)
                                Image(systemName: vm.isMuted ? "mic.slash.fill" : "mic.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                            }
                        }

                        // End call
                        Button(action: { vm.stopCall() }) {
                            ZStack {
                                Circle().fill(Color.red).frame(width: 70, height: 70)
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 26))
                                    .foregroundColor(.white)
                            }
                        }

                        // Flip front/back camera
                        Button(action: { vm.camera.switchCamera() }) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(width: 60, height: 60)
                                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                            }
                        }

                        // Camera toggle
                        Button(action: { vm.cameraOff.toggle() }) {
                            ZStack {
                                Circle()
                                    .fill(vm.cameraOff ? Color.red : Color.white.opacity(0.2))
                                    .frame(width: 60, height: 60)
                                Image(systemName: vm.cameraOff ? "video.slash.fill" : "video.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
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
