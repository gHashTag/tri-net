// Views.swift — FaceTime & Messenger UI for iOS
import SwiftUI
import AVFoundation
import LiveKit
import AudioToolbox

// Group the 11-digit safety number into readable blocks (e.g. 164 0819 8304) for reading aloud.
func groupDigits(_ s: String) -> String {
    let d = Array(s)
    guard d.count == 11 else { return s }
    return String(d[0..<3]) + " " + String(d[3..<7]) + " " + String(d[7..<11])
}

// MARK: - Avatar View Component

struct AvatarView: View {
    let name: String
    let data: Data?
    var colorHex: String = "#4CD972"
    var size: CGFloat = 40

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "T" }
        if trimmed.starts(with: "@") {
            return String(trimmed.dropFirst().prefix(1)).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if let data = data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hex: colorHex) ?? DS.live)
                    .frame(width: size, height: size)
                Text(initial)
                    .font(DS.display(size * 0.45, .bold))
                    .foregroundColor(DS.onFill)
            }
        }
        .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
    }
}

extension Color {
    init?(hex: String) {
        var c = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if c.count == 6 {
            c = "FF" + c
        }
        guard c.count == 8, let val = UInt64(c, radix: 16) else { return nil }
        let a = Double((val & 0xFF000000) >> 24) / 255.0
        let r = Double((val & 0x00FF0000) >> 16) / 255.0
        let g = Double((val & 0x0000FF00) >> 8) / 255.0
        let b = Double(val & 0x000000FF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Home Screen (Clean Messenger Layout)

struct HomeView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var directory: NicknameDirectoryController
    @ObservedObject private var groupChat: GroupChatController
    @State private var showSettings = false
    @State private var showGroupChats = false
    @State private var showAvatarPicker = false
    @State private var nicknameInput: String = ""

    init(vm: StreamViewModel) {
        self.vm = vm
        directory = vm.directory
        groupChat = vm.groupChat
    }

    private var homeUnreadCount: Int {
        max(vm.unreadChat, groupChat.totalUnreadCount)
    }

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            if vm.phase == .live || vm.phase == .connecting {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    // Top Header Bar
                    HStack(spacing: 12) {
                        Text("TRI-NET")
                            .font(DS.display(22, .bold))
                            .tracking(1)
                            .foregroundColor(DS.text)

                        StatusTag(text: "LIVE", live: true)

                        Spacer()

                        Button(action: { showGroupChats = true }) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(DS.dim)
                                    .frame(width: 40, height: 40)
                                    .background(DS.surface, in: Circle())
                                    .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                                if homeUnreadCount > 0 {
                                    Text(homeUnreadCount > 99 ? "99+" : "\(homeUnreadCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(DS.danger, in: Capsule())
                                        .offset(x: 4, y: -4)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 16))
                                .foregroundColor(DS.dim)
                                .frame(width: 40, height: 40)
                                .background(DS.surface, in: Circle())
                                .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 18) {
                            // Section 1: My Profile & Nickname Setup Card
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(text: "My Profile & Nickname")

                                HStack(spacing: 12) {
                                    Button(action: { showAvatarPicker = true }) {
                                        ZStack(alignment: .bottomTrailing) {
                                            AvatarView(
                                                name: nicknameInput.isEmpty ? (directory.currentNickname ?? vm.identity.displayName) : nicknameInput,
                                                data: vm.avatarData,
                                                colorHex: vm.avatarColorHex,
                                                size: 46
                                            )
                                            Image(systemName: "pencil.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(DS.fill)
                                                .background(Circle().fill(Color.black))
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 4) {
                                            Text("@").font(DS.mono(15, .bold)).foregroundColor(DS.dim)
                                            TextField("your_nickname", text: $nicknameInput)
                                                .textInputAutocapitalization(.never)
                                                .autocorrectionDisabled()
                                                .font(DS.mono(15, .bold))
                                                .foregroundColor(DS.text)
                                                .onSubmit { saveNickname() }
                                        }
                                        Text("Tap avatar to edit photo · Enter to save")
                                            .font(DS.ui(10))
                                            .foregroundColor(DS.faint)
                                    }

                                    Spacer()

                                    Button(action: { saveNickname() }) {
                                        Text(directory.currentNickname == nicknameInput && !nicknameInput.isEmpty ? "Saved" : "Save")
                                            .font(DS.mono(11, .bold))
                                            .foregroundColor(DS.onFill)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(DS.fill, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(14)
                                .dsCard()
                            }

                            // Section 2: Search Contact Bar
                            VStack(alignment: .leading, spacing: 10) {
                                SectionLabel(text: "Find Someone")

                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(DS.dim)
                                    TextField("Type @nickname or IP to find...", text: Binding(
                                        get: { vm.directory.searchQuery },
                                        set: { vm.directory.searchQuery = $0 }
                                    ))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(DS.mono(14))
                                    .foregroundColor(DS.text)
                                    .onSubmit { vm.searchNicknames() }

                                    if !vm.directory.searchQuery.isEmpty {
                                        Button(action: { vm.directory.searchQuery = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(DS.dim)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .dsCard()

                                if !vm.directory.results.isEmpty {
                                    VStack(spacing: 8) {
                                        ForEach(vm.directory.results) { contact in
                                            DirectoryContactButton(contact: contact) {
                                                vm.selectContact(contact)
                                                vm.openChat(with: contact.nickname)
                                            }
                                        }
                                    }
                                }
                            }

                            // Section 3: Contacts & Reachable Peers Roster
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    SectionLabel(text: "Contacts & Active Peers")
                                    Spacer()
                                    Text("\(vm.discovery.peers.count) online")
                                        .font(DS.mono(10))
                                        .foregroundColor(DS.dim)
                                }

                                iPeerRoster(vm: vm, discovery: vm.discovery)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(DS.ink)
        .overlay {
            if let inc = vm.incomingMeshCall {
                IncomingMeshCallOverlay(vm: vm, inc: inc).transition(.opacity)
            } else if let inc = vm.incomingCall {
                IncomingCallOverlay(vm: vm, inc: inc).transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = vm.callError,
               vm.incomingMeshCall == nil,
               vm.incomingCall == nil {
                CallErrorBanner(message: message)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: Binding(
            get: { vm.activeChatContact.map { IdentifiableString(value: $0) } },
            set: { vm.activeChatContact = $0?.value }
        )) { item in
            DirectChatView(vm: vm, contact: item.value)
        }
        .sheet(isPresented: $showAvatarPicker) {
            AvatarPickerSheet(vm: vm)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
        }
        .sheet(isPresented: $showGroupChats) {
            GroupChatCenterView(vm: vm)
        }
        .onAppear {
            vm.checkPermission()
            if let curr = directory.currentNickname, !curr.isEmpty {
                nicknameInput = curr
            } else {
                nicknameInput = vm.identity.displayName
            }
        }
    }

    private func saveNickname() {
        let trimmed = nicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        directory.proposedNickname = trimmed
        vm.claimNickname()
        vm.discovery.setName(trimmed)
    }
}

struct IdentifiableString: Identifiable {
    var id: String { value }
    let value: String
}

// MARK: - Direct Chat View (Tap on Nickname -> Direct Conversation + Action Bar)

struct DirectChatView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var directory: NicknameDirectoryController
    @ObservedObject private var discovery: PeerDiscovery
    let contact: String
    @Environment(\.dismiss) private var dismiss
    @State private var messageText = ""

    init(vm: StreamViewModel, contact: String) {
        self.vm = vm
        directory = vm.directory
        discovery = vm.discovery
        self.contact = contact
    }

    private var contactMessages: [DirectChatMessage] {
        vm.directChats[contact] ?? []
    }

    private var contactReachable: Bool {
        if directory.meshContact(named: contact)?.online == true { return true }
        let target = NicknamePolicy.normalize(contact)
        return discovery.peers.contains {
            NicknamePolicy.normalize($0.name) == target
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                DS.ink.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top Action Bar Header inside Chat
                    HStack(spacing: 12) {
                        AvatarView(name: contact, data: nil, size: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(contact)")
                                .font(DS.mono(15, .bold))
                                .foregroundColor(DS.text)
                            StatusTag(text: contactReachable ? "reachable" : "not reachable",
                                      live: contactReachable)
                        }

                        Spacer()

                        // Action Buttons: Audio Call, Video Call, AI Agent
                        HStack(spacing: 8) {
                            Button(action: {
                                dismiss()
                                vm.startAudioCall(to: contact)
                            }) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(DS.text)
                                    .frame(width: 38, height: 38)
                                    .background(DS.surfaceHi, in: Circle())
                                    .overlay(Circle().stroke(DS.hairlineStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                dismiss()
                                vm.startVideoCall(to: contact)
                            }) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(DS.onFill)
                                    .frame(width: 38, height: 38)
                                    .background(DS.fill, in: Circle())
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                vm.toggleAITranscription()
                            }) {
                                HStack(spacing: 4) {
                                    Text("🤖")
                                        .font(.system(size: 14))
                                    Text(vm.aiTranscriptionActive ? "AI ON" : "AI")
                                        .font(DS.mono(10, .bold))
                                        .foregroundColor(vm.aiTranscriptionActive ? DS.onFill : DS.text)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 38)
                                .background(vm.aiTranscriptionActive ? DS.live : DS.surfaceHi, in: Capsule())
                                .overlay(Capsule().stroke(vm.aiTranscriptionActive ? Color.clear : DS.hairlineStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(DS.surface)

                    Hairline()

                    // AI Subtitles Banner if Active
                    if vm.aiTranscriptionActive {
                        HStack(spacing: 8) {
                            Circle().fill(DS.live).frame(width: 6, height: 6)
                            Text(vm.liveTranscripts.last ?? "🤖 AI Transcriber Active — Listening for speech...")
                                .font(DS.mono(11))
                                .foregroundColor(DS.live)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(DS.surfaceHi)
                    }

                    // Messages Feed
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                if contactMessages.isEmpty {
                                    VStack(spacing: 8) {
                                        Text("No messages yet")
                                            .font(DS.ui(15, .medium))
                                            .foregroundColor(DS.dim)
                                        Text("Write first, call when you want to")
                                            .font(DS.mono(11))
                                            .foregroundColor(DS.faint)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 96)
                                }

                                ForEach(contactMessages) { msg in
                                    let isMe = msg.sender == (vm.directory.currentNickname ?? vm.identity.displayName)
                                    HStack(alignment: .bottom, spacing: 8) {
                                        if isMe { Spacer(minLength: 50) }
                                        else {
                                            AvatarView(name: msg.sender, data: nil, size: 28)
                                        }

                                        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                                            Text(msg.text)
                                                .font(DS.ui(14))
                                                .foregroundColor(isMe ? DS.onFill : DS.text)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 9)
                                                .background(isMe ? DS.fill : DS.surfaceHi,
                                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                                            Text(msg.timestamp, style: .time)
                                                .font(DS.mono(9))
                                                .foregroundColor(DS.faint)
                                        }

                                        if !isMe { Spacer(minLength: 50) }
                                    }
                                    .id(msg.id)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: contactMessages.count) { _ in
                            if let last = contactMessages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }

                    Hairline()

                    // Text Input Dock
                    HStack(spacing: 10) {
                        TextField("Message @\(contact)", text: $messageText)
                            .font(DS.ui(14))
                            .foregroundColor(DS.text)
                            .frame(minHeight: 48)
                            .onSubmit {
                                vm.sendDirectText(to: contact, text: messageText)
                                messageText = ""
                            }

                        Button(action: {
                            vm.sendDirectText(to: contact, text: messageText)
                            messageText = ""
                        }) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(DS.onFill)
                                .frame(width: 40, height: 40)
                                .background(DS.fill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .background(DS.surfaceHi, in: Capsule())
                    .overlay(Capsule().stroke(DS.hairline, lineWidth: 1))
                    .padding(12)
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            vm.markChatAsRead(contact)
        }
    }
}

// MARK: - Avatar Picker Modal Sheet

struct LegacyImagePicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: LegacyImagePicker
        init(_ parent: LegacyImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.8) {
                parent.imageData = data
            }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct AvatarPickerSheet: View {
    @ObservedObject var vm: StreamViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedColorHex = "#4CD972"
    @State private var showImagePicker = false

    private let presetColors = ["#4CD972", "#3B82F6", "#EC4899", "#F59E0B", "#8B5CF6", "#10B981"]

    var body: some View {
        NavigationView {
            ZStack {
                DS.ink.ignoresSafeArea()

                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        AvatarView(
                            name: vm.directory.currentNickname ?? vm.identity.displayName,
                            data: vm.avatarData,
                            colorHex: selectedColorHex,
                            size: 90
                        )

                        Text("Choose your avatar style")
                            .font(DS.ui(14))
                            .foregroundColor(DS.dim)
                    }
                    .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Preset Color Avatars")
                        HStack(spacing: 14) {
                            ForEach(presetColors, id: \.self) { colorHex in
                                Button(action: {
                                    selectedColorHex = colorHex
                                    vm.saveAvatar(data: nil, colorHex: colorHex)
                                }) {
                                    Circle()
                                        .fill(Color(hex: colorHex) ?? DS.live)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle()
                                                .stroke(selectedColorHex == colorHex && vm.avatarData == nil ? DS.fill : Color.clear, lineWidth: 3)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                        .dsCard()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Upload Photo")
                        Button(action: { showImagePicker = true }) {
                            HStack {
                                Image(systemName: "photo.on.rectangle")
                                    .foregroundColor(DS.text)
                                Text("Select Photo from Library")
                                    .font(DS.mono(13, .bold))
                                    .foregroundColor(DS.text)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(DS.dim)
                            }
                            .padding(14)
                            .dsCard()
                        }
                        .buttonStyle(.plain)

                        if vm.avatarData != nil {
                            Button(action: {
                                vm.saveAvatar(data: nil, colorHex: selectedColorHex)
                            }) {
                                Text("Remove photo & use preset color")
                                    .font(DS.ui(12))
                                    .foregroundColor(DS.danger)
                            }
                            .padding(.top, 4)
                        }
                    }

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Profile Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(DS.mono(13, .bold))
                        .foregroundColor(DS.text)
                }
            }
            .sheet(isPresented: $showImagePicker) {
                LegacyImagePicker(imageData: Binding(
                    get: { vm.avatarData },
                    set: { data in vm.saveAvatar(data: data, colorHex: selectedColorHex) }
                ))
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct DirectoryContactButton: View {
    let contact: DirectoryContact
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: contact.nickname, data: nil, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(contact.nickname)").font(DS.mono(13, .medium)).foregroundColor(DS.text)
                    Text(contact.displayName).font(DS.ui(10)).foregroundColor(DS.faint)
                }
                Spacer()
                Text(contact.source == .mesh && !contact.online ? "OFFLINE" : "ONLINE")
                    .font(DS.mono(9, .bold))
                    .foregroundColor(contact.online ? DS.live : DS.dim)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .dsCard(bg: DS.surfaceHi, radius: 14)
        }
        .buttonStyle(.plain)
    }
}

struct RingSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    init() {
        engine.attach(player)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        buffer = makeRing(fmt)
    }
    private func makeRing(_ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = 44100.0
        let notes: [(f: Double, dur: Double)] = [(659.25, 0.10), (987.77, 0.10), (1318.51, 0.16)]
        let gap = 0.55
        let total = notes.reduce(0) { $0 + $1.dur } + gap
        let frames = AVAudioFrameCount(total * sr)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let p = buf.floatChannelData![0]
        var i = 0
        for n in notes {
            let cnt = Int(n.dur * sr)
            for k in 0..<cnt {
                let t = Double(k) / sr
                let env = sin(Double.pi * Double(k) / Double(cnt))
                p[i] = Float(0.34 * env * sin(2 * Double.pi * n.f * t)); i += 1
            }
        }
        while i < Int(frames) { p[i] = 0; i += 1 }
        return buf
    }
    func start() {
        guard let buffer = buffer else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }
    func stop() { player.stop(); engine.stop() }
}

// MARK: - Incoming call (full-screen ring + Accept/Decline)

struct IncomingMeshCallOverlay: View {
    @ObservedObject var vm: StreamViewModel
    let inc: IncomingMeshCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var ringTimer: Timer?
    @State private var ring = RingSynth()

    private var callerName: String {
        let displayName = inc.invite.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? "@\(inc.invite.nickname)" : displayName
    }

    var body: some View {
        ZStack {
            DS.ink.opacity(0.99).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield.fill")
                    Text("SIGNED MESH")
                        .tracking(1.1)
                }
                .font(DS.mono(11, .bold))
                .foregroundColor(DS.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(DS.surface, in: Capsule())
                .overlay(Capsule().stroke(DS.hairlineStrong, lineWidth: 1))
                .padding(.top, 34)

                Spacer()

                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        Circle()
                            .stroke(DS.text.opacity(0.34), lineWidth: 2)
                            .frame(width: 170, height: 170)
                            .scaleEffect(pulse ? 1.42 : 0.96)
                            .opacity(pulse ? 0 : 0.75)
                        Circle()
                            .stroke(DS.text.opacity(0.16), lineWidth: 1)
                            .frame(width: 170, height: 170)
                            .scaleEffect(pulse ? 1.20 : 0.90)
                            .opacity(pulse ? 0 : 0.55)

                        AvatarView(name: callerName, data: nil, colorHex: "#F3F3F3", size: 124)
                    }

                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundColor(DS.onFill)
                        .frame(width: 44, height: 44)
                        .background(DS.fill, in: Circle())
                        .overlay(Circle().stroke(DS.ink, lineWidth: 4))
                        .offset(x: -8, y: -3)
                }

                Text(callerName)
                    .font(DS.display(28, .bold))
                    .foregroundColor(DS.text)
                    .padding(.top, 28)
                    .lineLimit(1)

                if callerName != "@\(inc.invite.nickname)" {
                    Text("@\(inc.invite.nickname)")
                        .font(DS.mono(13, .medium))
                        .foregroundColor(DS.dim)
                        .padding(.top, 5)
                }

                Text("Incoming encrypted local call")
                    .font(DS.ui(14))
                    .foregroundColor(DS.dim)
                    .padding(.top, 9)

                meshDetail(label: "SAFETY NUMBER", value: inc.invite.keyFingerprint)
                .padding(14)
                .frame(maxWidth: 330)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.hairline, lineWidth: 1)
                )
                .padding(.top, 20)
                .padding(.horizontal, 24)

                Spacer()

                HStack(spacing: 70) {
                    answerButton(
                        system: "phone.down.fill",
                        label: "Decline",
                        foreground: DS.text,
                        background: DS.surface,
                        border: DS.hairlineStrong
                    ) {
                        stopRing()
                        vm.declineIncomingMeshCall()
                    }
                    answerButton(
                        system: "phone.fill",
                        label: "Accept",
                        foreground: DS.onFill,
                        background: DS.fill,
                        border: Color.clear
                    ) {
                        stopRing()
                        vm.acceptIncomingMeshCall()
                    }
                }
                .padding(.bottom, 70)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signed mesh call from \(callerName)")
        .onAppear { startRing() }
        .onDisappear { stopRing() }
    }

    private func meshDetail(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(DS.mono(9, .bold))
                .tracking(1)
                .foregroundColor(DS.faint)
            Text(value)
                .font(DS.mono(11))
                .foregroundColor(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func answerButton(
        system: String,
        label: String,
        foreground: Color,
        background: Color,
        border: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Button(action: action) {
                Image(systemName: system)
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundColor(foreground)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(background))
                    .overlay(Circle().stroke(border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) signed mesh call from \(callerName)")
            .accessibilityHint(label == "Accept" ? "Connects the encrypted local call" : "Rejects the local call")

            Text(label)
                .font(DS.mono(12, .medium))
                .foregroundColor(DS.dim)
        }
    }

    private func startRing() {
        if !reduceMotion {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        ring.start()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private func stopRing() {
        ring.stop()
        ringTimer?.invalidate()
        ringTimer = nil
    }
}

struct IncomingCallOverlay: View {
    @ObservedObject var vm: StreamViewModel
    let inc: StreamViewModel.IncomingCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var ringTimer: Timer?
    @State private var ring = RingSynth()

    var body: some View {
        ZStack {
            DS.ink.opacity(0.98).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle().stroke(DS.live.opacity(0.45), lineWidth: 3)
                        .frame(width: 170, height: 170)
                        .scaleEffect(pulse ? 1.45 : 0.95).opacity(pulse ? 0 : 0.7)
                    Circle().stroke(DS.live.opacity(0.25), lineWidth: 2)
                        .frame(width: 170, height: 170)
                        .scaleEffect(pulse ? 1.18 : 0.88).opacity(pulse ? 0 : 0.5)

                    AvatarView(name: inc.name, data: nil, size: 124)
                }

                Text(inc.name)
                    .font(DS.display(28, .bold))
                    .foregroundColor(DS.text)
                    .padding(.top, 28)
                    .lineLimit(1)

                Text("Incoming Encrypted Call · TRI-NET")
                    .font(DS.ui(14))
                    .foregroundColor(DS.dim)
                    .padding(.top, 6)

                Text(inc.ip)
                    .font(DS.mono(12))
                    .foregroundColor(DS.faint)
                    .padding(.top, 4)

                Spacer()

                HStack(spacing: 70) {
                    answerButton(system: "phone.down.fill", label: "Decline", bg: DS.danger) {
                        stopRing(); vm.declineIncoming()
                    }
                    answerButton(system: "phone.fill", label: "Accept", bg: DS.live) {
                        stopRing(); vm.acceptIncoming()
                    }
                }
                .padding(.bottom, 70)
            }
        }
        .onAppear { startRing() }
        .onDisappear { stopRing() }
    }

    private func answerButton(system: String, label: String, bg: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Button(action: action) {
                Image(systemName: system)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(bg))
                    .shadow(color: bg.opacity(0.4), radius: 12, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) call")
            Text(label)
                .font(DS.mono(12, .medium))
                .foregroundColor(DS.dim)
        }
    }

    private func startRing() {
        if !reduceMotion {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
        }
        ring.start()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        ringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }
    private func stopRing() { ring.stop(); ringTimer?.invalidate(); ringTimer = nil }
}

private struct CallErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.text)
            Text(message)
                .font(DS.ui(12, .medium))
                .foregroundColor(DS.text)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DS.surfaceHi, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.hairlineStrong, lineWidth: 1)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Call error. \(message)")
    }
}

struct iPeerRoster: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject var discovery: PeerDiscovery

    var body: some View {
        VStack(spacing: 8) {
            if discovery.peers.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 22))
                            .foregroundColor(DS.faint)
                        Text("Searching for nearby TRI-NET peers...")
                            .font(DS.mono(11))
                            .foregroundColor(DS.dim)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
                .dsCard()
            } else {
                ForEach(discovery.peers) { peer in
                    let unread = vm.unreadCount(for: peer.name)
                    Button(action: {
                        vm.openChat(with: peer.name)
                    }) {
                        HStack(spacing: 12) {
                            AvatarView(name: peer.name, data: nil, size: 42)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(peer.name)
                                    .font(DS.ui(15, .semibold))
                                    .foregroundColor(DS.text)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(peer.status == "call" ? DS.warn : DS.live)
                                        .frame(width: 6, height: 6)
                                    Text(peer.status == "call" ? "in call" : "online")
                                        .font(DS.mono(10))
                                        .foregroundColor(peer.status == "call" ? DS.warn : DS.live)
                                }
                            }

                            Spacer()

                            if unread > 0 {
                                Text("\(unread)")
                                    .font(DS.mono(10, .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(DS.danger, in: Capsule())
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.system(size: 12))
                                Text("Chat")
                                    .font(DS.mono(11, .bold))
                            }
                            .foregroundColor(DS.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(DS.surfaceHi, in: Capsule())
                            .overlay(Capsule().stroke(DS.hairlineStrong, lineWidth: 1))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .dsCard(bg: DS.surface, radius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Call Screen (FaceTime style)

struct RemoteVideoArea: View {
    @ObservedObject var decoder: H264Decoder
    let phase: StreamViewModel.CallPhase
    let media: InternetCallMedia

    var body: some View {
        ZStack {
            DS.surface
            if !media.video {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(DS.dim)
                    Text(phase == .live ? "SECURE AUDIO CONNECTED" : "CONNECTING AUDIO...")
                        .font(DS.mono(12, .medium)).tracking(1).foregroundColor(DS.dim)
                }
            } else if decoder.frameCount > 0, let frame = decoder.currentFrame {
                RemoteVideoDisplay(imageBuffer: frame, frameId: decoder.frameCount)
            } else {
                VStack(spacing: 14) {
                    ProgressView().tint(DS.dim)
                    Text(phase == .connecting ? "CONNECTING..." : "WAITING FOR SIGNAL")
                        .font(DS.mono(12, .medium)).tracking(1).foregroundColor(DS.dim)
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
    @State private var pipOffset = CGSize.zero
    @GestureState private var dragAmount = CGSize.zero
    private let reactions = ["👍", "❤️", "😂", "👏", "🔥"]

    private var mediaConnected: Bool {
        if vm.activeRoute == .internet {
            return vm.internet.state == .connected
        }
        return vm.phase == .live
    }

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            Group {
                if vm.activeRoute == .internet {
                    InternetVideoArea(controller: vm.internet, phase: vm.phase, peer: vm.callee)
                } else {
                    RemoteVideoArea(decoder: vm.decoder,
                                    phase: vm.phase,
                                    media: vm.activeMeshMedia)
                }
            }
            .ignoresSafeArea()
            .onTapGesture { withAnimation { showControls.toggle() } }

            // AI Subtitles Overlay Banner on Call Screen
            if vm.aiTranscriptionActive {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Text("🤖")
                        Text(vm.liveTranscripts.last ?? "AI Subtitles: Speech-to-text active...")
                            .font(DS.mono(12, .medium))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .overlay(Capsule().stroke(DS.live.opacity(0.6), lineWidth: 1))
                    .padding(.bottom, 110)
                }
                .allowsHitTesting(false)
            }

            // Self camera PIP
            if vm.activeRoute != .mesh || vm.activeMeshMedia.video {
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            if vm.activeRoute == .internet, let track = vm.internet.localVideoTrack {
                                SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .mirror)
                            } else {
                                CameraPreviewView(session: vm.camera.previewSession)
                            }
                            if vm.activeRoute != .internet && vm.cameraOff {
                                Rectangle().fill(Color.black)
                                Image(systemName: "video.slash.fill").font(.system(size: 22)).foregroundColor(DS.dim)
                            }
                        }
                        .frame(width: 110, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.hairlineStrong, lineWidth: 1.5))
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                        .offset(x: pipOffset.width + dragAmount.width, y: pipOffset.height + dragAmount.height)
                        .gesture(
                            DragGesture()
                                .updating($dragAmount) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    pipOffset.width += value.translation.width
                                    pipOffset.height += value.translation.height
                                }
                        )
                        .padding(16)
                    }
                    Spacer()
                }
                .padding(.top, 54)
            }

            // Bottom Controls Bar
            if showControls {
                VStack {
                    HStack {
                        StatusTag(text: mediaConnected ? "Secure" : "Calling…", live: mediaConnected)
                            .background(Color.black.opacity(0.6), in: Capsule())
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 10)

                    Spacer()

                    HStack(spacing: 12) {
                        iBtn(system: vm.isMuted ? "mic.slash.fill" : "mic.fill", active: vm.isMuted) { vm.toggleMute() }
                        if vm.activeRoute != .mesh || vm.activeMeshMedia.video {
                            iBtn(system: "arrow.triangle.2.circlepath.camera.fill", active: false) { vm.camera.switchCamera() }
                            iBtn(system: vm.cameraOff ? "video.slash.fill" : "video.fill", active: vm.cameraOff) { vm.toggleCamera() }
                        }
                        Button(action: { vm.stopCall() }) {
                            Image(systemName: "phone.down.fill").font(.system(size: 17)).foregroundColor(DS.onFill)
                                .frame(width: 44, height: 44).background(DS.danger, in: Circle())
                        }.buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(DS.surface.opacity(0.9), in: Capsule())
                    .overlay(Capsule().stroke(DS.hairlineStrong, lineWidth: 1))
                    .padding(.bottom, 20)
                }
            }
        }
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

private struct iBtn: View {
    let system: String; let active: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 16))
                .foregroundColor(active ? DS.danger : DS.text)
                .frame(width: 42, height: 42)
                .background(active ? DS.danger.opacity(0.15) : DS.surfaceHi, in: Circle())
                .overlay(Circle().stroke(active ? DS.danger.opacity(0.6) : DS.hairlineStrong, lineWidth: 1))
        }.buttonStyle(.plain)
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
            ZStack {
                DS.ink.ignoresSafeArea()
                if let chat = group.activeChat {
                    conversation(chat)
                } else {
                    chatList
                }
            }
            .navigationTitle(group.activeChat?.title ?? "Group Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if group.activeChat != nil {
                        Button("Chats") { group.closeChat() }
                            .font(DS.mono(13))
                            .foregroundColor(DS.text)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(DS.mono(13, .bold))
                        .foregroundColor(DS.text)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var chatList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "New Group Chat")
                    TextField("@alice, @bob", text: $group.membersInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(DS.mono(14))
                        .foregroundColor(DS.text)
                        .padding(12).dsCard()

                    Button(action: { group.createGroup() }) {
                        HStack {
                            Spacer()
                            Text("Create Group")
                                .font(DS.mono(13, .bold))
                                .foregroundColor(DS.onFill)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(DS.fill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func conversation(_ chat: GroupChatSummary) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(group.messages) { message in
                        let mine = message.senderUserID == vm.identity.userID
                        HStack {
                            if mine { Spacer(minLength: 45) }
                            Text(message.text).font(DS.ui(13)).foregroundColor(DS.text)
                                .padding(12)
                                .background(mine ? Color.white.opacity(0.14) : DS.surfaceHi, in: RoundedRectangle(cornerRadius: 13))
                            if !mine { Spacer(minLength: 45) }
                        }
                    }
                }
                .padding()
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
            ZStack {
                DS.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel(text: "Device Identity")
                            VStack(spacing: 10) {
                                HRow("Device Name", vm.identity.displayName)
                                Hairline()
                                HRow("Device ID", String(vm.identity.deviceID.prefix(12)))
                            }
                            .padding(14)
                            .dsCard()
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(DS.mono(13, .bold))
                        .foregroundColor(DS.text)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct HRow: View {
    let title: String; let value: String
    init(_ t: String, _ v: String) { title = t; value = v }
    var body: some View {
        HStack {
            Text(title).font(DS.ui(13)).foregroundColor(DS.dim)
            Spacer()
            Text(value).font(DS.mono(12)).foregroundColor(DS.text)
        }
    }
}

// MARK: - Design System
enum DS {
    static let ink = Color(red: 0.039, green: 0.039, blue: 0.039)
    static let surface = Color(red: 0.082, green: 0.082, blue: 0.082)
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
    static func display(_ s: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: s, weight: w, design: .rounded) }
}

struct DSCardModifier: ViewModifier {
    var bg: Color = DS.surface
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(bg, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(DS.hairline, lineWidth: 1))
    }
}

extension View {
    func dsCard(bg: Color = DS.surface, radius: CGFloat = 16) -> some View {
        modifier(DSCardModifier(bg: bg, radius: radius))
    }
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
