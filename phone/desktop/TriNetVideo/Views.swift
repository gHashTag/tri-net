// Views.swift — FaceTime-style video call UI
import SwiftUI
import AVFoundation
import AppKit
import LiveKit

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
        .alert(item: $call.incomingMeshCall) { incoming in
            Alert(title: Text("Incoming local call"),
                  message: Text("@\(incoming.invite.nickname) wants to start an encrypted UDP call."),
                  primaryButton: .default(Text("Accept"), action: call.acceptIncomingMeshCall),
                  secondaryButton: .cancel(Text("Decline"), action: call.declineIncomingMeshCall))
        }
        .alert(item: $call.incomingInternetCall) { incoming in
            Alert(title: Text("Incoming Internet call"),
                  message: Text("@\(incoming.caller) is calling through WebRTC."),
                  primaryButton: .default(Text("Accept"), action: call.acceptIncomingInternetCall),
                  secondaryButton: .cancel(Text("Decline"), action: call.declineIncomingInternetCall))
        }
    }
}

// MARK: - Home Screen (before call)

struct HomeScreen: View {
    @EnvironmentObject var call: CallManager
    @State private var showSettings = false
    @State private var showNicknameSetup = false

    var body: some View {
        VStack(spacing: 32) {
            HStack {
                Text("TRI-NET")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

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

                Text("Encrypted mesh and internet video calls")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }

            Button(action: { showNicknameSetup = true }) {
                HStack(spacing: 8) {
                    Image(systemName: call.directory.currentNickname == nil ? "person.crop.circle.badge.plus" : "checkmark.seal.fill")
                    Text(call.directory.currentNickname.map { "@\($0)" } ?? "Create your nickname")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text(call.directory.claimKind == .verified ? "VERIFIED" :
                         call.directory.claimKind == .meshLocal ? "MESH" : "NEW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(call.directory.claimKind == .verified ? .green :
                                         call.directory.claimKind == .meshLocal ? .orange : .gray)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)

            // IP configuration
            VStack(spacing: 12) {
                Picker("Route", selection: $call.route) {
                    ForEach(CallRoute.allCases) { route in
                        Text(route.displayName).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .foregroundColor(.gray)
                        .font(.system(size: 18))

                    TextField(call.route == .mesh ? "Nickname or IP" : "Nickname", text: Binding(
                        get: { call.directory.searchQuery },
                        set: { call.directory.searchQuery = $0 }
                    ))
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
                        .onSubmit { call.searchNicknames() }

                    Button(action: { call.searchNicknames() }) {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)

                if !call.directory.results.isEmpty {
                    VStack(spacing: 7) {
                        ForEach(call.directory.results.prefix(3)) { contact in
                            MacDirectoryContactButton(contact: contact) { call.selectContact(contact) }
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // Show your IP
                HStack {
                    Image(systemName: "wifi")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("You: \(call.identity.nickname.map { "@\($0)" } ?? call.identity.displayName) | \(call.identity.keyFingerprint)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.green.opacity(0.8))
                }

                if let error = call.error {
                    Text(error).font(.system(size: 12)).foregroundColor(.red).multilineTextAlignment(.center)
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
            .disabled(call.directory.searchQuery.isEmpty && call.callee.isEmpty)
            .opacity((call.directory.searchQuery.isEmpty && call.callee.isEmpty) ? 0.5 : 1.0)

            Spacer()
        }
        .sheet(isPresented: $showSettings) {
            MacCallSettingsView(call: call)
        }
        .sheet(isPresented: $showNicknameSetup) {
            MacNicknameSetupView(call: call)
        }
    }
}

private struct MacDirectoryContactButton: View {
    let contact: DirectoryContact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(contact.online ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text("@\(contact.nickname)").font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Text(contact.source.rawValue).font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(contact.source == .mesh ? .orange : .green)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct MacNicknameSetupView: View {
    @ObservedObject var call: CallManager
    @ObservedObject private var directory: NicknameDirectoryController
    @Environment(\.dismiss) private var dismiss

    init(call: CallManager) {
        self.call = call
        directory = call.directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Create Nickname").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            HStack {
                Text("@").foregroundColor(.secondary)
                TextField("nickname", text: $directory.proposedNickname)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Use 3-20 lowercase letters, numbers, or underscore. The first character must be a letter.")
                .font(.caption).foregroundColor(.secondary)
            Button(directory.isWorking ? "Checking..." : "Check and create") { call.claimNickname() }
                .disabled(directory.isWorking)
            if let message = directory.statusMessage {
                Text(message).font(.callout)
            }
            if !directory.suggestions.isEmpty {
                Text("Alternatives").font(.headline)
                HStack {
                    ForEach(directory.suggestions, id: \.self) { suggestion in
                        Button("@\(suggestion)") {
                            directory.proposedNickname = suggestion
                            call.claimNickname()
                        }
                    }
                }
            }
            Divider()
            Text(directory.claimKind == .verified ? "Globally verified" :
                 directory.claimKind == .meshLocal ? "Mesh-local until the Directory API confirms uniqueness" :
                 "Choose a nickname to register this device")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(width: 520, height: 340)
        .onChange(of: directory.currentNickname) { current in
            if current != nil { dismiss() }
        }
    }
}

private struct MacCallSettingsView: View {
    @ObservedObject var call: CallManager
    @ObservedObject private var account: AccountDeviceController
    @Environment(\.dismiss) private var dismiss

    init(call: CallManager) {
        self.call = call
        account = call.account
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Call Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            Form {
                Section("Identity") {
                    TextField("Device name", text: Binding(
                        get: { call.identity.displayName },
                        set: { call.renameDevice($0) }
                    ))
                    LabeledContent("Device ID", value: String(call.identity.deviceID.prefix(16)))
                    LabeledContent("Key fingerprint", value: call.identity.keyFingerprint)
                    LabeledContent("Nickname", value: call.identity.nickname.map { "@\($0)" } ?? "Not created")
                }

                Section("Owner account") {
                    LabeledContent("Account ID", value: String(account.accountID.prefix(16)))
                    Text("Each Mac or iPhone has a separate revocable signing key; no shared password or private key is copied between devices.")
                        .font(.caption).foregroundColor(.secondary)
                    Button(account.isWorking ? "Syncing..." : "Sync Account") { account.sync() }
                        .disabled(account.isWorking)
                }

                Section("Add Your Device") {
                    HStack {
                        Button("Create One-Time Code") { account.createLinkCode() }
                            .disabled(account.isWorking)
                        if let code = account.generatedLinkCode {
                            Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                        }
                    }
                    HStack {
                        TextField("link_... from trusted device", text: $account.linkCodeInput)
                        Button("Link This Mac") { account.joinAccount() }
                            .disabled(account.isWorking)
                    }
                    Text("The 128-bit code expires in 10 minutes and is accepted once. Passkey recovery will be enabled when the production HTTPS domain is associated with the app.")
                        .font(.caption).foregroundColor(.secondary)
                }

                if !account.devices.isEmpty {
                    Section("Your Devices") {
                        ForEach(account.devices) { device in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName + (device.current ? " (this Mac)" : ""))
                                    Text("\(device.platform) · \(device.keyFingerprint)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if device.revoked {
                                    Text("Revoked").foregroundColor(.secondary)
                                } else if !device.current {
                                    Button("Revoke", role: .destructive) { account.revoke(device) }
                                }
                            }
                        }
                    }
                }

                if let message = account.statusMessage {
                    Section("Account Status") { Text(message).font(.caption) }
                }

                Section("Routing") {
                    Picker("Route", selection: $call.route) {
                        ForEach(CallRoute.allCases) { route in
                            Text(route.displayName).tag(route)
                        }
                    }
                    TextField("Contact or device", text: $call.callee)
                    TextField("Mesh peer IP", text: $call.remoteIP)
                }

                Section("Internet service") {
                    TextField("API URL", text: $call.internetConfiguration.apiBaseURL)
                    TextField("LiveKit URL", text: $call.internetConfiguration.liveKitURL)
                    SecureField("Development room token", text: $call.internetConfiguration.developmentRoomToken)
                    SecureField("Service access token", text: $call.internetConfiguration.accessToken)
                }
            }

            HStack {
                if let error = call.error {
                    Text(error).foregroundColor(.red).font(.caption)
                }
                Spacer()
                Button("Save") {
                    call.saveInternetSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680, height: 720)
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
            Group {
                if call.activeRoute == .internet {
                    MacInternetVideoView(controller: call.internet, peer: call.callee)
                } else {
                    RemoteVideoView(decoder: call.decoder)
                }
            }
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
                    if call.activeRoute == .internet, let track = call.internet.localVideoTrack {
                        SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .mirror)
                            .frame(width: 140, height: 105)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3), lineWidth: 2))
                            .shadow(color: .black.opacity(0.5), radius: 8)
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { pipOffset = $0.translation })
                            .padding(.trailing, 16)
                            .padding(.top, 16)
                    } else if let session = call.previewSession {
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
                            call.toggleMute()
                        }

                        // Camera toggle
                        ControlButton(icon: call.cameraOff ? "video.slash.fill" : "video.fill",
                                      color: call.cameraOff ? .red : Color.white.opacity(0.3)) {
                            call.toggleCamera()
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

private struct MacInternetVideoView: View {
    @ObservedObject var controller: InternetCallController
    let peer: String

    var body: some View {
        ZStack {
            Color.black
            if let track = controller.remoteVideoTrack {
                SwiftUIVideoView(track, layoutMode: .fill)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(controller.state.rawValue.uppercased())
                        .font(.system(size: 12, design: .monospaced))
                    Text(controller.participantName.isEmpty ? peer : controller.participantName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
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
