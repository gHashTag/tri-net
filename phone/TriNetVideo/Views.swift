// Views.swift — FaceTime & Messenger UI for iOS
import SwiftUI
import AVFoundation
import LiveKit
import AudioToolbox
import UIKit

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
    var colorHex: String = "#15846E"
    var size: CGFloat = 40

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "T" }
        if trimmed.starts(with: "@") {
            return String(trimmed.dropFirst().prefix(1)).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    private var initialForeground: Color {
        var value = colorHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 8 { value = String(value.suffix(6)) }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return DS.onFill
        }
        let components = [
            Double((rgb >> 16) & 0xff) / 255,
            Double((rgb >> 8) & 0xff) / 255,
            Double(rgb & 0xff) / 255
        ].map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * components[0] +
            0.7152 * components[1] +
            0.0722 * components[2]
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast ? .white : .black
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
                    .foregroundColor(initialForeground)
            }
        }
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

// A quiet Dala-style constellation for identity and empty states. It stays
// static so Reduce Motion users receive the same hierarchy without animation.
private struct ConstellationField: View {
    private let points: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.68), CGPoint(x: 0.25, y: 0.30),
        CGPoint(x: 0.43, y: 0.56), CGPoint(x: 0.62, y: 0.18),
        CGPoint(x: 0.78, y: 0.48), CGPoint(x: 0.92, y: 0.23)
    ]
    private let links = [(0, 1), (1, 2), (2, 3), (2, 4), (3, 5), (4, 5)]

    var body: some View {
        Canvas { context, size in
            let resolved = points.map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            }
            for link in links {
                var path = Path()
                path.move(to: resolved[link.0])
                path.addLine(to: resolved[link.1])
                context.stroke(path, with: .color(DS.silver.opacity(0.28)), lineWidth: 1)
            }
            for (index, point) in resolved.enumerated() {
                let diameter: CGFloat = index == 2 ? 7 : 4
                let rect = CGRect(x: point.x - diameter / 2,
                                  y: point.y - diameter / 2,
                                  width: diameter,
                                  height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(DS.silver))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - Home Screen (Clean Messenger Layout)

struct HomeView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var directory: NicknameDirectoryController
    @ObservedObject private var groupChat: GroupChatController
    @ObservedObject private var directMessages: InternetDirectMessageController
    @State private var showSettings = false
    @State private var showGroupChats = false
    @State private var showAvatarPicker = false
    @State private var nicknameInput: String = ""

    init(vm: StreamViewModel) {
        self.vm = vm
        directory = vm.directory
        groupChat = vm.groupChat
        directMessages = vm.directMessages
    }

    private var homeUnreadCount: Int {
        groupChat.totalUnreadCount + max(vm.unreadChat, directMessages.totalUnreadCount)
    }

    private var normalizedNicknameInput: String {
        NicknamePolicy.normalize(nicknameInput)
    }

    private var nicknameHasChanges: Bool {
        !normalizedNicknameInput.isEmpty &&
            normalizedNicknameInput != directory.currentNickname
    }

    private var nicknameValidationError: String? {
        guard !normalizedNicknameInput.isEmpty else { return nil }
        return NicknamePolicy.validationError(normalizedNicknameInput)
    }

    private var publicDirectoryConfigured: Bool {
        vm.internetConfiguration.isPublicHTTPSAPI
    }

    private var publicRouteLive: Bool {
        publicDirectoryConfigured && vm.publicRouteHealth == .live
    }

    private var publicRouteLabel: String {
        if publicRouteLive { return "PUBLIC API REACHABLE" }
        if publicDirectoryConfigured { return "PUBLIC ROUTE SET" }
        return "WI-FI ROUTE ONLY"
    }

    private var recentContactNames: [String] {
        vm.directChats
            .filter { !$0.value.isEmpty }
            .sorted {
                ($0.value.last?.timestamp ?? .distantPast) >
                    ($1.value.last?.timestamp ?? .distantPast)
            }
            .map(\.key)
    }

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            if vm.phase == .live || vm.phase == .connecting || vm.showEndedCallState {
                CallScreen(vm: vm)
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("tri-net.")
                            .font(DS.display(23, .regular))
                            .foregroundColor(DS.text)
                        Circle()
                            .fill(publicRouteLive ? DS.verdant : DS.amber)
                            .frame(width: 6, height: 6)
                        Text(publicRouteLabel)
                            .font(DS.mono(9, .medium))
                            .tracking(0.5)
                            .foregroundColor(DS.dim)

                        Spacer()

                        Button(action: { showGroupChats = true }) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(DS.text)
                                    .frame(width: 44, height: 44)
                                if homeUnreadCount > 0 {
                                    Text(homeUnreadCount > 99 ? "99+" : "\(homeUnreadCount)")
                                        .font(DS.mono(9, .bold))
                                        .foregroundColor(DS.onDanger)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(DS.danger, in: Capsule())
                                        .offset(x: 2, y: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Group chats")

                        Button(action: { showSettings = true }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(DS.text)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 30) {
                            ZStack(alignment: .trailing) {
                                ConstellationField()
                                    .frame(width: 190, height: 126)
                                    .opacity(0.90)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Call anyone.\nNo numbers.")
                                        .font(DS.display(42, .regular))
                                        .tracking(-1.2)
                                        .foregroundColor(DS.text)
                                        .minimumScaleFactor(0.78)
                                    Text("Use one exact nickname on Wi-Fi or the public route.")
                                        .font(DS.ui(13))
                                        .foregroundColor(DS.dim)
                                        .frame(maxWidth: 245, alignment: .leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 142)

                            VStack(alignment: .leading, spacing: 12) {
                                SectionLabel(text: "Your call address")

                                HStack(spacing: 12) {
                                    Button(action: { showAvatarPicker = true }) {
                                        ZStack(alignment: .bottomTrailing) {
                                            AvatarView(
                                                name: nicknameInput.isEmpty ? (directory.currentNickname ?? vm.identity.displayName) : nicknameInput,
                                                data: vm.avatarData,
                                                colorHex: vm.avatarColorHex,
                                                size: 48
                                            )
                                            Image(systemName: "pencil.circle.fill")
                                                .font(.system(size: 15))
                                                .foregroundColor(DS.text)
                                                .background(Circle().fill(DS.ink))
                                        }
                                        .frame(width: 52, height: 52)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Edit profile picture")

                                    HStack(spacing: 3) {
                                        Text("@").foregroundColor(DS.dim)
                                        TextField("your_nickname", text: $nicknameInput)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .font(DS.mono(16, .medium))
                                            .foregroundColor(DS.text)
                                            .submitLabel(.done)
                                            .onSubmit { saveNickname() }
                                    }
                                    .padding(.vertical, 12)
                                    .overlay(alignment: .bottom) { Hairline() }

                                    if nicknameHasChanges && nicknameValidationError == nil {
                                        Button("Save") { saveNickname() }
                                            .font(DS.mono(11, .bold))
                                            .foregroundColor(DS.onFill)
                                            .frame(minWidth: 64, minHeight: 44)
                                            .background(DS.iris, in: Capsule())
                                            .buttonStyle(.plain)
                                    }
                                }

                                if let error = nicknameValidationError {
                                    Text(error)
                                        .font(DS.ui(12))
                                        .foregroundColor(DS.amber)
                                } else if directory.isWorking {
                                    HStack(spacing: 7) {
                                        ProgressView().tint(DS.silver)
                                        Text("Checking this nickname...")
                                    }
                                    .font(DS.ui(12))
                                    .foregroundColor(DS.dim)
                                } else if let message = directory.statusMessage {
                                    Text(message)
                                        .font(DS.ui(12))
                                        .foregroundColor(
                                            directory.claimKind == .verified &&
                                            message.localizedCaseInsensitiveContains("globally verified")
                                                ? DS.verdant : DS.amber)
                                } else if let current = directory.currentNickname {
                                    Text(directory.claimKind == .verified
                                         ? "@\(current) is globally verified."
                                         : "@\(current) is available on this Wi-Fi network.")
                                        .font(DS.ui(12))
                                        .foregroundColor(directory.claimKind == .verified ? DS.verdant : DS.amber)
                                }

                                if !directory.suggestions.isEmpty {
                                    HStack(spacing: 8) {
                                        ForEach(directory.suggestions, id: \.self) { suggestion in
                                            Button("@\(suggestion)") { nicknameInput = suggestion }
                                                .font(DS.mono(10, .medium))
                                                .foregroundColor(DS.text)
                                                .frame(minHeight: 44)
                                                .padding(.horizontal, 10)
                                                .overlay(Capsule().stroke(DS.hairlineStrong, lineWidth: 1))
                                                .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                SectionLabel(text: "Find by exact nickname")
                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(DS.dim)
                                    Text("@")
                                        .font(DS.mono(15, .medium))
                                        .foregroundColor(DS.dim)
                                    TextField("nickname", text: Binding(
                                        get: { directory.searchQuery },
                                        set: { directory.searchQuery = $0 }
                                    ))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(DS.mono(15, .medium))
                                    .foregroundColor(DS.text)
                                    .submitLabel(.search)
                                    .onSubmit { vm.searchNicknames() }

                                    if directory.isWorking {
                                        ProgressView().tint(DS.silver)
                                    } else if !directory.searchQuery.isEmpty {
                                        Button(action: { directory.searchQuery = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(DS.dim)
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Clear nickname search")
                                    }
                                }
                                .padding(.leading, 14)
                                .padding(.trailing, 4)
                                .frame(minHeight: 54)
                                .background(DS.surfaceHi, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                                if !directory.results.isEmpty {
                                    VStack(spacing: 0) {
                                        ForEach(directory.results) { contact in
                                            DirectoryContactButton(contact: contact) {
                                                vm.selectContact(contact)
                                                vm.openChat(with: contact.nickname)
                                            }
                                        }
                                    }
                                } else if let error = directory.searchStatusMessage {
                                    Text("Search failed: \(error)")
                                        .font(DS.ui(12))
                                        .foregroundColor(DS.amber)
                                        .padding(.horizontal, 2)
                                } else if !directory.searchQuery.isEmpty && !directory.isWorking {
                                    Text(directory.hasCompletedExactSearch
                                         ? (publicDirectoryConfigured
                                            ? "No exact match. Check the spelling or ask for the contact link."
                                            : "No match on this Wi-Fi. A public HTTPS call service is not configured on this build.")
                                         : "Press Search to look up this exact nickname.")
                                        .font(DS.ui(12))
                                        .foregroundColor(DS.dim)
                                        .padding(.horizontal, 2)
                                }
                            }

                            if !recentContactNames.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    SectionLabel(text: "Conversations")
                                        .padding(.bottom, 10)
                                    ForEach(recentContactNames, id: \.self) { name in
                                        ConversationRow(name: name,
                                                        lastMessage: vm.directChats[name]?.last) {
                                            vm.openChat(with: name)
                                        }
                                    }
                                }
                            }

                            if !directory.meshPeers.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    SectionLabel(text: "Nearby now")
                                        .padding(.bottom, 10)
                                    ForEach(directory.meshPeers.filter(\.online)) { contact in
                                        DirectoryContactButton(contact: contact) {
                                            vm.selectContact(contact)
                                            vm.openChat(with: contact.nickname)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 36)
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
            vm.checkPublicRouteHealth()
            if let curr = directory.currentNickname, !curr.isEmpty {
                nicknameInput = curr
                vm.discovery.setName(curr)
            } else {
                nicknameInput = ""
            }
        }
        .onChange(of: directory.currentNickname) { nickname in
            guard let nickname, !nickname.isEmpty else { return }
            nicknameInput = nickname
            vm.discovery.setName(nickname)
        }
    }

    private func saveNickname() {
        let candidate = NicknamePolicy.normalize(nicknameInput)
        guard NicknamePolicy.validationError(candidate) == nil else { return }
        nicknameInput = candidate
        directory.proposedNickname = candidate
        vm.claimNickname()
    }
}

struct IdentifiableString: Identifiable {
    var id: String { value }
    let value: String
}

private struct ConversationRow: View {
    let name: String
    let lastMessage: DirectChatMessage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: name, data: nil, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(name)")
                        .font(DS.mono(14, .medium))
                        .foregroundColor(DS.text)
                    Text(lastMessage?.text ?? "Open conversation")
                        .font(DS.ui(12))
                        .foregroundColor(DS.dim)
                        .lineLimit(1)
                }
                Spacer()
                if let timestamp = lastMessage?.timestamp {
                    Text(timestamp, style: .time)
                        .font(DS.mono(9))
                        .foregroundColor(DS.faint)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.faint)
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Hairline() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Conversation with @\(name)")
    }
}

// MARK: - Direct Chat View (Tap on Nickname -> Direct Conversation + Action Bar)

struct DirectChatView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var directory: NicknameDirectoryController
    @ObservedObject private var discovery: PeerDiscovery
    let contact: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        if directory.results.contains(where: {
            $0.source == .internet && NicknamePolicy.normalize($0.nickname) == target
        }) { return true }
        return discovery.peers.contains {
            NicknamePolicy.normalize($0.name) == target
        }
    }

    private var contactRouteLabel: String {
        let target = NicknamePolicy.normalize(contact)
        if directory.meshContact(named: target)?.online == true { return "nearby now" }
        if directory.results.contains(where: {
            $0.source == .internet && NicknamePolicy.normalize($0.nickname) == target
        }) { return "internet account" }
        return "route not confirmed"
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
                            StatusTag(text: contactRouteLabel,
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
                                    .font(.system(size: 16))
                                    .foregroundColor(DS.text)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Audio call @\(contact)")

                            Button(action: {
                                dismiss()
                                vm.startVideoCall(to: contact)
                            }) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(DS.text)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Video call @\(contact)")

                            Button(action: {
                                vm.toggleAITranscription()
                            }) {
                                HStack(spacing: 4) {
                                    Text("🤖")
                                        .font(.system(size: 14))
                                    Text(vm.aiTranscriptionActive ? "AI ON" : "AI")
                                        .font(DS.mono(10, .bold))
                                        .foregroundColor(vm.aiTranscriptionActive ? DS.verdant : DS.dim)
                                }
                                .frame(minWidth: 52, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(vm.aiTranscriptionActive ? "Turn AI transcription off" : "Turn AI transcription on")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

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
                                    let isMe = NicknamePolicy.normalize(msg.sender) ==
                                        NicknamePolicy.normalize(vm.directory.currentNickname ?? vm.identity.displayName)
                                    HStack(alignment: .bottom, spacing: 8) {
                                        if isMe { Spacer(minLength: 50) }
                                        else {
                                            AvatarView(name: msg.sender, data: nil, size: 28)
                                        }

                                        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                                            Text(msg.text)
                                                .font(DS.ui(14))
                                                .foregroundColor(DS.text)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 9)
                                                .background(isMe ? Color.white.opacity(0.13) : DS.surfaceHi,
                                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                                            HStack(spacing: 4) {
                                                Text(msg.timestamp, style: .time)
                                                    .font(DS.mono(9))
                                                    .foregroundColor(DS.faint)
                                                if isMe {
                                                    switch msg.delivery {
                                                    case .none:
                                                        Image(systemName: "clock")
                                                            .font(.system(size: 9, weight: .medium))
                                                            .foregroundColor(DS.dim)
                                                            .accessibilityLabel("Sending")
                                                    case .some(.sent), .some(.received):
                                                        Image(systemName: "checkmark")
                                                            .font(.system(size: 9, weight: .bold))
                                                            .foregroundColor(DS.verdant)
                                                            .accessibilityLabel("Sent")
                                                    case .some(.failed):
                                                        Button {
                                                            vm.retryDirectMessage(msg, to: contact)
                                                        } label: {
                                                            Image(systemName: "exclamationmark.circle.fill")
                                                                .font(.system(size: 13, weight: .semibold))
                                                                .foregroundColor(DS.amber)
                                                                .frame(width: 44, height: 44)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .accessibilityLabel("Message failed. Try again")
                                                    case .some(.uncertain):
                                                        Image(systemName: "questionmark.circle.fill")
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .foregroundColor(DS.amber)
                                                            .frame(width: 44, height: 44)
                                                            .accessibilityLabel(
                                                                "Delivery could not be confirmed. Check the conversation before sending again"
                                                            )
                                                    }
                                                }
                                            }
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
                                if reduceMotion {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                } else {
                                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
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
                                .frame(width: 44, height: 44)
                                .background(DS.iris, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .background(DS.surfaceHi, in: Capsule())
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
    @State private var selectedColorHex = "#15846E"
    @State private var showImagePicker = false

    private let presetColors = ["#15846E", "#FFB829", "#BDBDBD", "#FFFFFF", "#5C5C5C", "#1F4F46"]

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
                                                .stroke(selectedColorHex == colorHex && vm.avatarData == nil ? DS.text : Color.clear, lineWidth: 3)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
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
                            .frame(minHeight: 54)
                            .overlay(alignment: .bottom) { Hairline() }
                        }
                        .buttonStyle(.plain)

                        if vm.avatarData != nil {
                            Button(action: {
                                vm.saveAvatar(data: nil, colorHex: selectedColorHex)
                            }) {
                                Text("Remove photo & use preset color")
                                    .font(DS.ui(12))
                                    .foregroundColor(DS.danger)
                                    .frame(maxWidth: .infinity,
                                           minHeight: 44,
                                           alignment: .leading)
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

    private var routeLabel: String {
        if contact.source == .internet { return "INTERNET" }
        return contact.online ? "NEARBY" : "SAVED"
    }

    private var safeDisplayName: String {
        DeviceDisplayNamePolicy.safe(contact.displayName, fallback: "@\(contact.nickname)")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AvatarView(name: contact.nickname, data: nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(contact.nickname)")
                        .font(DS.mono(14, .medium))
                        .foregroundColor(DS.text)
                    Text(safeDisplayName)
                        .font(DS.ui(11))
                        .foregroundColor(DS.dim)
                }
                Spacer()
                HStack(spacing: 7) {
                    Circle()
                        .fill(contact.online ? DS.verdant : DS.faint)
                        .frame(width: 6, height: 6)
                    Text(routeLabel)
                        .font(DS.mono(9, .medium))
                        .foregroundColor(contact.online ? DS.verdant : DS.dim)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.faint)
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Hairline() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("@\(contact.nickname), \(routeLabel.lowercased()) route")
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
    @State private var ringTimer: Timer?
    @State private var ring = RingSynth()

    private var callerName: String {
        let displayName = inc.invite.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = NicknamePolicy.normalize(inc.invite.nickname)
        let fallback = nickname.isEmpty || DeviceDisplayNamePolicy.isRawIPAddress(nickname)
            ? "Local TRI-NET peer"
            : "@\(nickname)"
        return DeviceDisplayNamePolicy.safe(displayName, fallback: fallback)
    }

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield.fill")
                    Text("SIGNED INVITE")
                        .tracking(1.1)
                }
                .font(DS.mono(11, .bold))
                .foregroundColor(DS.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .padding(.top, 34)

                Spacer()

                ZStack(alignment: .bottomTrailing) {
                    AvatarView(name: callerName, data: nil, colorHex: "#F3F3F3", size: 124)

                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundColor(DS.onFill)
                        .frame(width: 44, height: 44)
                        .background(DS.verdant, in: Circle())
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

                Text("Verified invitation for a local call")
                    .font(DS.ui(14))
                    .foregroundColor(DS.dim)
                    .padding(.top, 9)

                meshDetail(label: "INVITE KEY", value: inc.invite.keyFingerprint)
                .padding(.vertical, 14)
                .frame(maxWidth: 330)
                .overlay(alignment: .top) { Hairline() }
                .overlay(alignment: .bottom) { Hairline() }
                .padding(.top, 20)
                .padding(.horizontal, 24)

                Spacer()

                HStack(spacing: 70) {
                    answerButton(
                        system: "phone.down.fill",
                        label: "Decline",
                        foreground: DS.text,
                        background: DS.danger,
                        border: Color.clear
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
        .accessibilityLabel("Signed local-call invitation from \(callerName)")
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
            .accessibilityLabel("\(label) signed local-call invitation from \(callerName)")
            .accessibilityHint(label == "Accept"
                ? "Connects local media through its separate encrypted handshake"
                : "Rejects the local call")

            Text(label)
                .font(DS.mono(12, .medium))
                .foregroundColor(DS.dim)
        }
    }

    private func startRing() {
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
    @State private var ringTimer: Timer?
    @State private var ring = RingSynth()

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                AvatarView(name: inc.name, data: nil, size: 124)

                Text(inc.name)
                    .font(DS.display(28, .bold))
                    .foregroundColor(DS.text)
                    .padding(.top, 28)
                    .lineLimit(1)

                Text("Incoming local call · TRI-NET")
                    .font(DS.ui(14))
                    .foregroundColor(DS.dim)
                    .padding(.top, 6)

                Spacer()

                HStack(spacing: 70) {
                    answerButton(system: "phone.down.fill", label: "Decline", bg: DS.danger) {
                        stopRing(); vm.declineIncoming()
                    }
                    answerButton(system: "phone.fill", label: "Accept", bg: DS.iris) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) call")
            Text(label)
                .font(DS.mono(12, .medium))
                .foregroundColor(DS.dim)
        }
    }

    private func startRing() {
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
        .background(DS.ink.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(DS.amber).frame(height: 1)
        }
        .overlay(alignment: .bottom) { Hairline() }
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
            } else {
                ForEach(discovery.peers) { peer in
                    let displayName = peer.displayName
                    let unread = vm.unreadCount(for: displayName)
                    Button(action: {
                        vm.openChat(with: displayName)
                    }) {
                        HStack(spacing: 12) {
                            AvatarView(name: displayName, data: nil, size: 42)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName)
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
                                    .foregroundColor(DS.onDanger)
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
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Hairline() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var showChat = false
    @State private var showLog = false
    @State private var draft = ""
    @State private var pipOffset = CGSize.zero
    @GestureState private var dragAmount = CGSize.zero
    private let reactions = ["👍", "❤️", "😂", "👏", "🔥"]

    private var mediaConnected: Bool {
        if vm.activeRoute == .internet {
            return vm.internet.state == .connected && vm.internet.hasRemoteParticipant
        }
        return vm.phase == .live
    }

    private var callStateLabel: String {
        if vm.showEndedCallState { return "Ended" }
        if vm.activeRoute == .internet { return vm.internet.state.rawValue }
        return vm.callStatusText
    }

    private var endedPeerLabel: String {
        let safe = DeviceDisplayNamePolicy.safe(vm.callee, fallback: "Local TRI-NET peer")
        if safe == "Local TRI-NET peer" || safe.hasPrefix("@") { return safe }
        return "@\(safe)"
    }

    var body: some View {
        ZStack {
            DS.ink.ignoresSafeArea()

            Group {
                if vm.showEndedCallState {
                    VStack(spacing: 10) {
                        Text(vm.callee.isEmpty ? "TRI-NET call" : endedPeerLabel)
                            .font(DS.display(26, .regular))
                            .foregroundColor(DS.text)
                        Text("ENDED")
                            .font(DS.mono(11, .medium))
                            .tracking(1)
                            .foregroundColor(DS.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.ink)
                } else if vm.activeRoute == .internet {
                    InternetVideoArea(controller: vm.internet, phase: vm.phase, peer: vm.callee)
                } else {
                    RemoteVideoArea(decoder: vm.decoder,
                                    phase: vm.phase,
                                    media: vm.activeMeshMedia)
                }
            }
            .ignoresSafeArea()
            .onTapGesture {
                if reduceMotion {
                    showControls.toggle()
                } else {
                    withAnimation { showControls.toggle() }
                }
            }

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
                    .padding(.bottom, 110)
                }
                .allowsHitTesting(false)
            }

            // Self camera PIP
            if !vm.showEndedCallState &&
                (vm.activeRoute != .mesh || vm.activeMeshMedia.video) {
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
            if showControls && !vm.showEndedCallState {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            StatusTag(text: callStateLabel, live: mediaConnected)
                                .background(Color.black.opacity(0.6), in: Capsule())
                            if vm.activeRoute == .mesh, vm.mitmWarning {
                                Text("MEDIA IDENTITY CHANGED")
                                    .font(DS.mono(9, .bold))
                                    .tracking(0.7)
                                    .foregroundColor(DS.danger)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Color.black.opacity(0.6), in: Capsule())
                                    .accessibilityLabel("Media identity changed")
                            } else if vm.activeRoute == .mesh,
                                      let safetyNumber = vm.safetyNumber {
                                Text("MEDIA CODE \(groupDigits(safetyNumber))")
                                    .font(DS.mono(9, .bold))
                                    .tracking(0.7)
                                    .foregroundColor(DS.dim)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(Color.black.opacity(0.6), in: Capsule())
                                    .accessibilityLabel("Media safety code \(groupDigits(safetyNumber))")
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.top, 10)

                    Spacer()

                    HStack(spacing: 12) {
                        iBtn(system: vm.isMuted ? "mic.slash.fill" : "mic.fill", active: vm.isMuted) { vm.toggleMute() }
                        if vm.activeRoute == .mesh, vm.activeMeshMedia.video {
                            iBtn(system: "arrow.triangle.2.circlepath.camera.fill", active: false) { vm.camera.switchCamera() }
                        }
                        if vm.activeRoute != .mesh || vm.activeMeshMedia.video {
                            iBtn(system: vm.cameraOff ? "video.slash.fill" : "video.fill", active: vm.cameraOff) { vm.toggleCamera() }
                        }
                        Button(action: { vm.stopCall() }) {
                            Image(systemName: "phone.down.fill").font(.system(size: 17)).foregroundColor(DS.onFill)
                                .frame(width: 44, height: 44).background(DS.danger, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("End call")
                    }
                    .padding(16)
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

    private var safePeer: String {
        let safe = DeviceDisplayNamePolicy.safe(peer, fallback: "TRI-NET peer")
        guard safe != "TRI-NET peer", !safe.hasPrefix("@") else { return safe }
        let nickname = NicknamePolicy.normalize(safe)
        return NicknamePolicy.validationError(nickname) == nil ? "@\(nickname)" : safe
    }

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
                    Text(safePeer)
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
                .frame(width: 44, height: 44)
                .background(active ? DS.danger.opacity(0.15) : DS.surfaceHi, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if system.hasPrefix("mic") { return active ? "Unmute microphone" : "Mute microphone" }
        if system.hasPrefix("video") { return active ? "Turn camera on" : "Turn camera off" }
        if system.contains("camera") { return "Switch camera" }
        return "Call control"
    }
}

private struct GroupChatCenterView: View {
    @ObservedObject var vm: StreamViewModel
    @ObservedObject private var group: GroupChatController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "New group")
                    TextField("Group title (optional)", text: $group.titleInput)
                        .font(DS.ui(14))
                        .foregroundColor(DS.text)
                        .frame(minHeight: 50)
                        .padding(.horizontal, 14)
                        .background(DS.surfaceHi,
                                    in: RoundedRectangle(cornerRadius: 16,
                                                         style: .continuous))

                    TextField("@alice, @bob", text: $group.membersInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(DS.mono(14))
                        .foregroundColor(DS.text)
                        .frame(minHeight: 50)
                        .padding(.horizontal, 14)
                        .background(DS.surfaceHi,
                                    in: RoundedRectangle(cornerRadius: 16,
                                                         style: .continuous))

                    Text("Use exact nicknames, separated by spaces or commas.")
                        .font(DS.ui(11))
                        .foregroundColor(DS.dim)

                    Button(action: { group.createGroup() }) {
                        HStack {
                            if group.isWorking {
                                ProgressView().tint(DS.onFill)
                            }
                            Spacer()
                            Text("Create Group")
                                .font(DS.mono(13, .bold))
                                .foregroundColor(DS.onFill)
                            Spacer()
                        }
                        .frame(minHeight: 48)
                        .background(DS.fill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(group.isWorking ||
                              group.membersInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Create group chat")
                }

                if let message = group.statusMessage {
                    Text(message)
                        .font(DS.ui(12))
                        .foregroundColor(message == "Group created." ? DS.verdant : DS.amber)
                        .accessibilityLabel("Group chat status. \(message)")
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Conversations")
                        .padding(.bottom, 10)

                    if group.chats.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("No groups yet")
                                .font(DS.ui(15, .medium))
                                .foregroundColor(DS.text)
                            Text("Create one with exact nicknames above.")
                                .font(DS.ui(12))
                                .foregroundColor(DS.dim)
                        }
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                        .overlay(alignment: .bottom) { Hairline() }
                    } else {
                        ForEach(group.chats) { chat in
                            Button(action: { group.open(chat) }) {
                                HStack(spacing: 12) {
                                    AvatarView(name: chat.title, data: nil, size: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(chat.title)
                                            .font(DS.ui(15, .medium))
                                            .foregroundColor(DS.text)
                                            .lineLimit(1)
                                        Text(chat.lastMessage ?? chat.members.map { "@\($0)" }.joined(separator: ", "))
                                            .font(DS.ui(11))
                                            .foregroundColor(DS.dim)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if let timestamp = chat.lastMessageAt {
                                        Text(Date(timeIntervalSince1970: TimeInterval(timestamp)),
                                             style: .time)
                                            .font(DS.mono(9))
                                            .foregroundColor(DS.faint)
                                    }
                                    if chat.unreadCount > 0 {
                                        Text(chat.unreadCount > 99 ? "99+" : "\(chat.unreadCount)")
                                            .font(DS.mono(9, .bold))
                                            .foregroundColor(DS.onDanger)
                                            .frame(minWidth: 22, minHeight: 22)
                                            .padding(.horizontal, 3)
                                            .background(DS.danger, in: Capsule())
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(DS.faint)
                                }
                                .frame(minHeight: 62)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) { Hairline() }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(chat.title), \(chat.unreadCount) unread")
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear { group.refresh() }
    }

    private func conversation(_ chat: GroupChatSummary) -> some View {
        VStack(spacing: 0) {
            Text(chat.members.map { "@\($0)" }.joined(separator: "  "))
                .font(DS.mono(10))
                .foregroundColor(DS.dim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            Hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if group.messages.isEmpty {
                            VStack(spacing: 8) {
                                Text("No messages yet")
                                    .font(DS.ui(15, .medium))
                                    .foregroundColor(DS.dim)
                                Text("Say hello to the group")
                                    .font(DS.mono(11))
                                    .foregroundColor(DS.faint)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 96)
                        }

                        ForEach(group.messages) { message in
                            let mine = message.senderUserID == vm.identity.userID
                            HStack(alignment: .bottom, spacing: 8) {
                                if mine { Spacer(minLength: 45) }
                                VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                                    if !mine {
                                        Text("@\(message.senderNickname)")
                                            .font(DS.mono(9, .medium))
                                            .foregroundColor(DS.dim)
                                    }
                                    Text(message.text)
                                        .font(DS.ui(14))
                                        .foregroundColor(DS.text)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(mine ? Color.white.opacity(0.13) : DS.surfaceHi,
                                                    in: RoundedRectangle(cornerRadius: 16,
                                                                         style: .continuous))
                                    Text(Date(timeIntervalSince1970: TimeInterval(message.createdAt)),
                                         style: .time)
                                        .font(DS.mono(9))
                                        .foregroundColor(DS.faint)
                                }
                                if !mine { Spacer(minLength: 45) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: group.messages.count) { _ in
                    if let last = group.messages.last {
                        if reduceMotion {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            if let message = group.statusMessage {
                Text(message)
                    .font(DS.ui(11))
                    .foregroundColor(DS.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            Hairline()
            HStack(spacing: 10) {
                TextField("Message \(chat.title)", text: $group.draft)
                    .font(DS.ui(14))
                    .foregroundColor(DS.text)
                    .frame(minHeight: 48)
                    .submitLabel(.send)
                    .onSubmit { group.send() }

                Button(action: { group.send() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(DS.onFill)
                        .frame(width: 44, height: 44)
                        .background(DS.iris, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(group.isWorking ||
                          group.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send group message")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .background(DS.surfaceHi, in: Capsule())
            .padding(12)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var vm: StreamViewModel
    @Environment(\.dismiss) var dismiss
    @State private var apiBaseURL: String
    @State private var liveKitURL: String
    @State private var developmentRoomToken: String
    @State private var accessToken: String
    @State private var showDeveloperRouting = false

    init(vm: StreamViewModel) {
        self.vm = vm
        _apiBaseURL = State(initialValue: vm.internetConfiguration.apiBaseURL)
        _liveKitURL = State(initialValue: vm.internetConfiguration.liveKitURL)
        _developmentRoomToken = State(initialValue: vm.internetConfiguration.developmentRoomToken)
        _accessToken = State(initialValue: vm.internetConfiguration.accessToken)
    }

    private var routeIsPublic: Bool {
        InternetCallConfiguration(apiBaseURL: apiBaseURL,
                                  liveKitURL: liveKitURL,
                                  accessToken: accessToken,
                                  developmentRoomToken: developmentRoomToken)
            .isPublicHTTPSAPI
    }

    private var routeIsLive: Bool {
        routeIsPublic &&
            apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) ==
                vm.internetConfiguration.apiBaseURL &&
            vm.publicRouteHealth == .live
    }

    private var routeHost: String {
        URL(string: apiBaseURL)?.host ?? "not configured"
    }

    var body: some View {
        NavigationView {
            ZStack {
                DS.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel(text: "Device identity")
                            VStack(spacing: 10) {
                                HRow("Device Name", vm.identity.displayName)
                                Hairline()
                                HRow("Device ID", String(vm.identity.deviceID.prefix(12)))
                            }
                            .padding(.vertical, 6)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel(text: "Calling route")
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(routeIsLive ? DS.verdant : DS.amber)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(routeIsLive
                                         ? "Public HTTPS call API reachable"
                                         : (routeIsPublic
                                            ? "Public Internet route configured"
                                            : "Local Wi-Fi route"))
                                        .font(DS.ui(15, .medium))
                                        .foregroundColor(DS.text)
                                    Text(routeHost)
                                        .font(DS.mono(11))
                                        .foregroundColor(DS.dim)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .frame(minHeight: 54)
                            .overlay(alignment: .bottom) { Hairline() }

                            Text(routeIsLive
                                 ? "The HTTPS call API answered its health check. Media, TURN, and push delivery are not verified by this check."
                                 : (routeIsPublic
                                    ? "The public URL is configured but has not passed its live health check."
                                 : "Nearby calls work on the same Wi-Fi. Calling from another network requires a public HTTPS service, public LiveKit/TURN, and APNs.")
                            )
                                .font(DS.ui(12))
                                .foregroundColor(DS.dim)
                        }

                        DisclosureGroup(isExpanded: $showDeveloperRouting) {
                            VStack(alignment: .leading, spacing: 12) {
                                routingField("Call API URL",
                                             placeholder: "https://api.example.com",
                                             text: $apiBaseURL)
                                    .textContentType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                routingField("Direct LiveKit URL",
                                             placeholder: "wss://project.livekit.cloud",
                                             text: $liveKitURL)
                                    .textContentType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Development room token")
                                        .font(DS.mono(10, .medium))
                                        .foregroundColor(DS.dim)
                                    SecureField("Short-lived development token",
                                                text: $developmentRoomToken)
                                        .font(DS.mono(12))
                                        .foregroundColor(DS.text)
                                        .frame(minHeight: 48)
                                        .padding(.horizontal, 14)
                                        .background(DS.surfaceHi,
                                                    in: RoundedRectangle(cornerRadius: 15,
                                                                         style: .continuous))
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Development service token")
                                        .font(DS.mono(10, .medium))
                                        .foregroundColor(DS.dim)
                                    SecureField("Optional development token", text: $accessToken)
                                        .font(DS.mono(12))
                                        .foregroundColor(DS.text)
                                        .frame(minHeight: 48)
                                        .padding(.horizontal, 14)
                                        .background(DS.surfaceHi,
                                                    in: RoundedRectangle(cornerRadius: 15,
                                                                         style: .continuous))
                                }

                                Text("Direct LiveKit and service tokens are development controls. Production builds should ship a fixed public API route and short-lived room tokens from the backend.")
                                    .font(DS.ui(11))
                                    .foregroundColor(DS.dim)
                            }
                            .padding(.top, 12)
                        } label: {
                            Text("Developer routing")
                                .font(DS.mono(12, .medium))
                                .foregroundColor(DS.text)
                                .frame(minHeight: 44)
                        }

                        Button(action: saveRouting) {
                            Text("Save routing")
                                .font(DS.mono(13, .bold))
                                .foregroundColor(DS.onFill)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(DS.iris, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Save calling route")
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

    private func routingField(_ label: String,
                              placeholder: String,
                              text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(DS.mono(10, .medium))
                .foregroundColor(DS.dim)
            TextField(placeholder, text: text)
                .font(DS.mono(12))
                .foregroundColor(DS.text)
                .frame(minHeight: 48)
                .padding(.horizontal, 14)
                .background(DS.surfaceHi,
                            in: RoundedRectangle(cornerRadius: 15,
                                                 style: .continuous))
        }
    }

    private func saveRouting() {
        vm.internetConfiguration.apiBaseURL = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.internetConfiguration.liveKitURL = liveKitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.internetConfiguration.developmentRoomToken =
            developmentRoomToken.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.internetConfiguration.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.saveInternetSettings()
        dismiss()
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
    static let ink = Color.black
    static let iris = Color(red: 128 / 255, green: 82 / 255, blue: 1)
    static let amber = Color(red: 1, green: 184 / 255, blue: 41 / 255)
    static let verdant = Color(red: 21 / 255, green: 132 / 255, blue: 110 / 255)
    static let silver = Color(red: 189 / 255, green: 189 / 255, blue: 189 / 255)
    static let surface = ink
    static let surfaceHi = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.09)
    static let hairlineStrong = Color.white.opacity(0.16)
    static let text = Color.white
    static let dim = silver
    static let faint = Color.white.opacity(0.52)
    // Compatibility aliases keep call controls coherent while screens migrate.
    static let fill = iris
    static let onFill = Color.white
    static let live = verdant
    static let warn = amber
    static let danger = Color(uiColor: .systemRed)
    static let onDanger = Color.black
    private static func textStyle(for size: CGFloat) -> UIFont.TextStyle {
        switch size {
        case 34...: return .largeTitle
        case 28...: return .title1
        case 22...: return .title2
        case 20...: return .title3
        case 17...: return .body
        case 15...: return .subheadline
        case 12...: return .footnote
        case 10...: return .caption1
        default: return .caption2
        }
    }

    private static func scaled(_ size: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: textStyle(for: size)).scaledValue(for: size)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: scaled(size), weight: weight, design: .monospaced)
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: scaled(size), weight: weight, design: .rounded)
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
        .padding(.vertical, 5)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(DS.mono(10, .medium)).tracking(1.2).foregroundColor(DS.faint)
    }
}
