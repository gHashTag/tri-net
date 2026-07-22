// Views.swift — FaceTime-style video call UI for iOS
import SwiftUI
import AVFoundation
import LiveKit

// MARK: - Home Screen

struct HomeView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var directory: NicknameDirectoryController
    @ObservedObject private var groupChat: GroupChatController
    @State private var showSettings = false
    @State private var showNicknameSetup = false
    @State private var showGroupChats = false

    init(vm: StreamViewModel) {
        self.vm = vm
        directory = vm.directory
        groupChat = vm.groupChat
    }

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
                        Button(action: { showGroupChats = true }) {
                            Image(systemName: groupChat.chats.isEmpty ? "bubble.left.and.bubble.right" : "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 18)).foregroundColor(DS.dim)
                                .frame(width: 42, height: 42)
                                .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                        }
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape").font(.system(size: 18)).foregroundColor(DS.dim)
                                .frame(width: 42, height: 42).overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 24)

                    Text("Encrypted mesh | WebRTC internet")
                        .font(DS.ui(13)).foregroundColor(DS.dim)

                    Button(action: { showNicknameSetup = true }) {
                        HStack(spacing: 8) {
                            Image(systemName: directory.currentNickname == nil ? "person.crop.circle.badge.plus" : "checkmark.seal.fill")
                            Text(directory.currentNickname.map { "@\($0)" } ?? "Create your nickname")
                                .font(DS.mono(13, .medium))
                            Text(directory.claimKind == .verified ? "VERIFIED" :
                                 directory.claimKind == .meshLocal ? "MESH" : "NEW")
                                .font(DS.mono(9, .bold))
                                .foregroundColor(directory.claimKind == .verified ? DS.live :
                                                 directory.claimKind == .meshLocal ? DS.warn : DS.dim)
                        }
                        .foregroundColor(DS.text)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(DS.surface, in: Capsule())
                        .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

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
                        Picker("Route", selection: $vm.route) {
                            ForEach(CallRoute.allCases) { route in
                                Text(route.displayName).tag(route)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            SectionLabel(text: "Find")
                            TextField(vm.route == .mesh ? "nickname or IP" : "nickname", text: Binding(
                                get: { vm.directory.searchQuery },
                                set: { vm.directory.searchQuery = $0 }
                            ))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(DS.mono(16)).foregroundColor(DS.text)
                                .multilineTextAlignment(.center)
                                .onSubmit { vm.searchNicknames() }
                            Button(action: { vm.searchNicknames() }) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(DS.text)
                                    .frame(width: 34, height: 34)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(DS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairline, lineWidth: 1))

                        if !vm.directory.results.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(vm.directory.results.prefix(3)) { contact in
                                    DirectoryContactButton(contact: contact) {
                                        vm.selectContact(contact)
                                        vm.directory.searchQuery = contact.nickname
                                    }
                                }
                            }
                        }

                        if !vm.callee.isEmpty {
                            Text("CALL TARGET | @\(vm.callee)")
                                .font(DS.mono(11, .medium)).foregroundColor(DS.live)
                        }

                        Text("SELF | \(directory.currentNickname.map { "@\($0)" } ?? vm.identity.displayName) | \(vm.identity.keyFingerprint)")
                            .font(DS.mono(12)).foregroundColor(DS.faint)

                        if let error = vm.callError {
                            Text(error).font(DS.ui(12)).foregroundColor(DS.danger).multilineTextAlignment(.center)
                        }

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
        .sheet(isPresented: $showNicknameSetup) {
            NicknameSetupView(vm: vm)
        }
        .sheet(isPresented: $showGroupChats) {
            GroupChatCenterView(vm: vm)
        }
        .sheet(item: $vm.shareFile) { f in
            ShareSheet(items: [f.url])
        }
        .alert(item: $vm.incomingMeshCall) { incoming in
            Alert(title: Text("Incoming local call"),
                  message: Text("@\(incoming.invite.nickname) wants to start an encrypted UDP call."),
                  primaryButton: .default(Text("Accept"), action: vm.acceptIncomingMeshCall),
                  secondaryButton: .cancel(Text("Decline"), action: vm.declineIncomingMeshCall))
        }
    }
}

private struct DirectoryContactButton: View {
    let contact: DirectoryContact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(contact.online ? DS.live : DS.faint).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(contact.nickname)").font(DS.mono(13, .medium)).foregroundColor(DS.text)
                    Text(contact.displayName).font(DS.ui(10)).foregroundColor(DS.faint)
                }
                Spacer()
                Text(contact.source.rawValue).font(DS.mono(9, .bold))
                    .foregroundColor(contact.source == .mesh ? DS.warn : DS.live)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(DS.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct NicknameSetupView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var directory: NicknameDirectoryController
    @Environment(\.dismiss) private var dismiss

    init(vm: StreamViewModel) {
        self.vm = vm
        directory = vm.directory
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Your nickname") {
                    HStack {
                        Text("@").foregroundColor(.secondary)
                        TextField("nickname", text: $directory.proposedNickname)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text("3-20 characters: lowercase letters, numbers, and underscore. The first character must be a letter.")
                        .font(.caption).foregroundColor(.secondary)
                    Button(directory.isWorking ? "Checking..." : "Check and create") {
                        vm.claimNickname()
                    }
                    .disabled(directory.isWorking)
                }

                if let message = directory.statusMessage {
                    Section("Status") {
                        Text(message)
                    }
                }

                if !directory.suggestions.isEmpty {
                    Section("Available alternatives") {
                        ForEach(directory.suggestions, id: \.self) { suggestion in
                            Button("@\(suggestion)") {
                                directory.proposedNickname = suggestion
                                vm.claimNickname()
                            }
                        }
                    }
                }

                Section("Verification") {
                    HRow("Current", directory.currentNickname.map { "@\($0)" } ?? "Not created")
                    HRow("Scope", directory.claimKind == .verified ? "Global verified" :
                         directory.claimKind == .meshLocal ? "Mesh local" : "Not registered")
                    Text("Global uniqueness requires the Directory API. Mesh-local names are checked against currently reachable signed peers.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Nickname")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: directory.currentNickname) { current in
                if current != nil { dismiss() }
            }
        }
    }
}

// Wraps UIActivityViewController so a finished recording can be saved/sent.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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
    @State private var showLog = false
    @State private var draft = ""
    private let reactions = ["👍", "❤️", "😂", "👏", "🔥"]

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            Group {
                if vm.activeRoute == .internet {
                    InternetVideoArea(controller: vm.internet, phase: vm.phase, peer: vm.callee)
                } else {
                    RemoteVideoArea(decoder: vm.decoder, phase: vm.phase, remoteIP: vm.remoteIP)
                }
            }
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
                    Group {
                        if vm.activeRoute == .internet, let track = vm.internet.localVideoTrack {
                            SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .mirror)
                        } else {
                            CameraPreviewView(session: vm.camera.previewSession)
                        }
                    }
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

            if showLog {
                VStack { Spacer(); iLogPanel(bus: LogBus.shared, close: { showLog = false }) }
                    .padding(12).transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showControls && !showChat {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        StatusTag(text: vm.framesReceived > 0 ? "Secure" : "Connecting", live: vm.framesReceived > 0)
                            .background(DS.ink.opacity(0.5), in: Capsule())
                        Spacer()
                        // Record toggle — kept out of the bottom bar so the six
                        // primary controls stay one row on every iPhone.
                        Button(action: { vm.toggleRecording() }) {
                            HStack(spacing: 5) {
                                Circle().fill(vm.isRecording ? DS.danger : DS.faint).frame(width: 7, height: 7)
                                Text(vm.isRecording ? "REC" : "Rec").font(DS.mono(10, .medium)).tracking(0.5)
                                    .foregroundColor(vm.isRecording ? DS.danger : DS.dim)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(vm.isRecording ? DS.danger.opacity(0.5) : DS.hairline, lineWidth: 1))
                        }.buttonStyle(.plain)
                        Button(action: { withAnimation { showLog.toggle() } }) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 11))
                                .foregroundColor(showLog ? DS.text : DS.dim)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                        }.buttonStyle(.plain)
                        Text(vm.activeRoute == .internet ? vm.callee : vm.remoteIP).font(DS.mono(11)).foregroundColor(DS.faint)
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
                            iBtn(system: vm.isMuted ? "mic.slash.fill" : "mic.fill", active: vm.isMuted) { vm.toggleMute() }
                            iBtn(system: "arrow.triangle.2.circlepath.camera.fill", active: false) { vm.camera.switchCamera() }
                            iBtn(system: vm.cameraOff ? "video.slash.fill" : "video.fill", active: vm.cameraOff) { vm.toggleCamera() }
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

private struct InternetVideoArea: View {
    @ObservedObject var controller: InternetCallController
    let phase: StreamViewModel.CallPhase
    let peer: String

    var body: some View {
        ZStack {
            DS.surface
            if let track = controller.remoteVideoTrack {
                SwiftUIVideoView(track, layoutMode: .fill)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(DS.dim)
                    Text(controller.state.rawValue.uppercased())
                        .font(DS.mono(12, .medium)).tracking(1).foregroundColor(DS.dim)
                    Text(controller.participantName.isEmpty ? peer : controller.participantName)
                        .font(DS.mono(11)).foregroundColor(DS.faint)
                }
            }
        }
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

private struct GroupChatCenterView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var group: GroupChatController
    @Environment(\.dismiss) private var dismiss

    init(vm: StreamViewModel) {
        self.vm = vm
        group = vm.groupChat
    }

    var body: some View {
        NavigationView {
            Group {
                if let chat = group.activeChat {
                    conversation(chat)
                } else {
                    chatList
                }
            }
            .navigationTitle(group.activeChat?.title ?? "Group Chats")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if group.activeChat != nil {
                        Button("Chats") { group.closeChat() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { group.startPolling() }
    }

    private var chatList: some View {
        Form {
            Section("New group") {
                TextField("Title (optional)", text: $group.titleInput)
                TextField("@alice, @bob", text: $group.membersInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Enter unique participant nicknames separated by commas or spaces. Offline members receive messages when they reconnect.")
                    .font(.caption).foregroundColor(.secondary)
                Button(group.isWorking ? "Creating..." : "Create group") {
                    group.createGroup()
                }
                .disabled(group.isWorking)
            }

            Section("Your chats") {
                if group.chats.isEmpty {
                    Text("No groups yet").foregroundColor(.secondary)
                }
                ForEach(group.chats) { chat in
                    Button(action: { group.open(chat) }) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(chat.title).font(.headline).foregroundColor(.primary)
                            Text(chat.members.map { "@\($0)" }.joined(separator: ", "))
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            if let lastMessage = chat.lastMessage {
                                Text(lastMessage).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }

            if let status = group.statusMessage {
                Section { Text(status).font(.caption).foregroundColor(.secondary) }
            }
        }
    }

    private func conversation(_ chat: GroupChatSummary) -> some View {
        VStack(spacing: 0) {
            Text(chat.members.map { "@\($0)" }.joined(separator: ", "))
                .font(.caption).foregroundColor(.secondary).lineLimit(2)
                .padding(.horizontal).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(group.messages) { message in
                            let mine = message.senderUserID == vm.identity.userID
                            HStack {
                                if mine { Spacer(minLength: 45) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mine ? "You" : "@\(message.senderNickname)")
                                        .font(.caption2).foregroundColor(.secondary)
                                    Text(message.text).font(.body)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(mine ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 13))
                                if !mine { Spacer(minLength: 45) }
                            }
                            .id(message.messageID)
                        }
                    }
                    .padding()
                }
                .onChange(of: group.messages.count) { _ in
                    if let last = group.messages.last {
                        withAnimation { proxy.scrollTo(last.messageID, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                TextField("Message", text: $group.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { group.send() }
                Button(action: { group.send() }) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
                .disabled(group.isWorking || group.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            if let status = group.statusMessage {
                Text(status).font(.caption).foregroundColor(.secondary).padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var account: AccountDeviceController
    @Environment(\.dismiss) var dismiss

    init(vm: StreamViewModel) {
        self.vm = vm
        account = vm.account
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Identity") {
                    TextField("Device name", text: Binding(
                        get: { vm.identity.displayName },
                        set: { vm.renameDevice($0) }
                    ))
                    HRow("Device ID", String(vm.identity.deviceID.prefix(12)))
                    HRow("Key", vm.identity.keyFingerprint)
                }
                Section("Owner account") {
                    HRow("Nickname", account.nickname.map { "@\($0)" } ?? "Not created")
                    HRow("Account ID", String(account.accountID.prefix(12)))
                    Text("No password or private key is shared. Every installation has its own revocable signing key. Passkey sign-in becomes the primary recovery method after a production HTTPS domain is connected.")
                        .font(.caption).foregroundColor(.secondary)
                    Button(account.isWorking ? "Syncing..." : "Sync account") { account.sync() }
                        .disabled(account.isWorking)
                }
                Section("Add your device") {
                    Button("Create one-time link code") { account.createLinkCode() }
                        .disabled(account.isWorking)
                    if let code = account.generatedLinkCode {
                        Text(code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy link code") { UIPasteboard.general.string = code }
                    }
                    TextField("link_... from trusted device", text: $account.linkCodeInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Link this device to my account") { account.joinAccount() }
                        .disabled(account.isWorking)
                    Text("The code contains 128 bits of randomness, expires in 10 minutes, and works once. Create it on a device already in your account.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if !account.devices.isEmpty {
                    Section("Your devices") {
                        ForEach(account.devices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.displayName + (device.current ? " (this device)" : ""))
                                    Text("\(device.platform) · \(device.keyFingerprint)")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                if device.revoked {
                                    Text("Revoked").font(.caption).foregroundColor(.secondary)
                                } else if !device.current {
                                    Button("Revoke", role: .destructive) { account.revoke(device) }
                                }
                            }
                        }
                    }
                }
                if let message = account.statusMessage {
                    Section("Account status") { Text(message).font(.caption) }
                }
                Section("Connection") {
                    Picker("Route", selection: $vm.route) {
                        ForEach(CallRoute.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Contact or device", text: $vm.callee)
                    TextField("Mesh peer IP", text: $vm.remoteIP).keyboardType(.decimalPad)
                }
                Section("Internet service") {
                    TextField("API URL", text: $vm.internetConfiguration.apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("LiveKit URL", text: $vm.internetConfiguration.liveKitURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Development room token", text: $vm.internetConfiguration.developmentRoomToken)
                    SecureField("Service access token", text: $vm.internetConfiguration.accessToken)
                    Button("Save internet settings") { vm.saveInternetSettings() }
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
                    HRow("Transport", "Local/Mesh UDP + LiveKit WebRTC")
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
            if !vm.linkInfo.isEmpty {
                Text(vm.linkInfo).font(DS.mono(9)).foregroundColor(DS.faint)
            }
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
    static let warn = Color(red: 0.96, green: 0.66, blue: 0.22)
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

// iOS log panel — the phone's own telemetry, copyable. Without this the phone is
// a black box and every diagnosis is an inference from what the Mac received.
private struct iLogPanel: View {
    @ObservedObject var bus: LogBus
    let close: () -> Void
    @State private var copied = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectionLabel(text: "Log")
                Spacer()
                Text("\(bus.lines.count)").font(DS.mono(9)).foregroundColor(DS.faint)
                Button(action: {
                    UIPasteboard.general.string = bus.transcript()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9))
                        Text(copied ? "Copied" : "Copy").font(DS.mono(9, .medium))
                    }
                    .foregroundColor(copied ? DS.live : DS.dim)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(copied ? DS.live.opacity(0.5) : DS.hairline, lineWidth: 1))
                }.buttonStyle(.plain)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(DS.dim)
                }.buttonStyle(.plain)
            }.padding(10)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(bus.lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(DS.mono(8))
                                .foregroundColor(Self.tint(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }.padding(10)
                }
                .onChange(of: bus.lines.count) { n in
                    guard n > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .frame(height: 300)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }

    private static func tint(_ l: String) -> Color {
        let s = l.lowercased()
        if s.contains("failed") || s.contains("error") || s.contains("denied") || s.contains("division") { return DS.danger }
        if s.contains("first frame") || s.contains("established") || s.contains("engine up") || s.contains("rebuilt") { return DS.live }
        return DS.dim
    }
}
