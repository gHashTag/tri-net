// ViewModel.swift — Direct Mac↔iPhone video call via BSD UDP
import SwiftUI
import AVFoundation
import Combine

struct ChatLine: Identifiable {
    let id = UUID()
    enum Who { case me, them }
    let who: Who
    let text: String
}

class StreamViewModel: ObservableObject {
    @Published var phase: CallPhase = .idle
    @Published var remoteIP: String = UserDefaults.standard.string(forKey: "remoteIP") ?? "192.168.1.105"
    @Published var myIP: String = ""
    @Published var framesSent: Int = 0
    @Published var framesReceived: Int = 0
    @Published var txKBps: Double = 0
    @Published var rxKBps: Double = 0
    @Published var cameraAuthorized = false
    @Published var isMuted = false
    @Published var cameraOff = false
    @Published var recentIPs: [String] = []
    // Live audio levels (0...1) for the TX/RX meters, peak-held with decay.
    @Published var txLevel: Float = 0
    @Published var rxLevel: Float = 0
    // Chat + reactions (shown live on both ends)
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?
    @Published var isBlurred = false

    func toggleBlur() {
        isBlurred.toggle()
        camera.blurBackground = isBlurred
    }

    // Adaptive bitrate: sample incoming PLI rate every 3s.
    private var pliCount = 0
    private var abrTimer: Timer?
    func startABR() {
        abrTimer?.invalidate()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, self.phase == .live else { return }
            if self.pliCount >= 3 { self.camera.nudgeBitrate(down: true) }
            else if self.pliCount == 0 { self.camera.nudgeBitrate(down: false) }
            self.pliCount = 0
        }
    }
    func notePLI() { pliCount += 1 }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var d = Data([0xFB, 0xCA]); d.append(Data(t.utf8))
        transport.send(d)
        chat.append(ChatLine(who: .me, text: t))
    }

    func sendReaction(_ emoji: String) {
        var d = Data([0xFE, 0xAC]); d.append(Data(emoji.utf8))
        transport.send(d)
        showReaction(emoji)
    }

    private var reactionTask: DispatchWorkItem?
    func showReaction(_ emoji: String) {
        liveReaction = emoji
        reactionTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.liveReaction = nil }
        reactionTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    enum CallPhase: Equatable {
        case idle, connecting, live
    }

    let camera = CameraController()
    let transport = BSDTransport()
    let decoder = H264Decoder()
    let audio = AudioController()

    private var bytesSent = 0
    private var bytesRecv = 0
    private var timer: Timer?

    init() {
        myIP = getLocalIP()
        if let saved = UserDefaults.standard.array(forKey: "recentCallIPs") as? [String] {
            recentIPs = saved
        }
    }

    func checkPermission() {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthorized = (s == .authorized)
        if s == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.cameraAuthorized = granted }
            }
        }
    }

    func startCall() {
        UserDefaults.standard.set(remoteIP, forKey: "remoteIP")
        if !recentIPs.contains(remoteIP) {
            recentIPs.insert(remoteIP, at: 0)
            if recentIPs.count > 5 { recentIPs.removeLast() }
            UserDefaults.standard.set(recentIPs, forKey: "recentCallIPs")
        }

        phase = .connecting

        // UDP: send to remoteIP:7000, listen on 7000 (same port for both)
        transport.connect(host: remoteIP, port: 7000, recvPort: 7000)

        // Peer PLI → force an IDR from our encoder
        decoder.onKeyframeNeeded = { [weak self] in
            self?.transport.send(Data([0xFC, 0x00]))
        }

        // Incoming: UDP → PLI / audio / chat / reaction / H.264 decoder → display
        transport.onData = { [weak self] data in
            guard let self = self else { return }
            self.bytesRecv += data.count
            if data.count == 2, data[0] == 0xFC { // Picture Loss Indication
                self.camera.forceKeyframe()
                self.notePLI()   // adaptive bitrate signal
                return
            }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD { // audio
                self.audio.playPacket(data.subdata(in: 2..<data.count))
                return
            }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA { // chat
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)) }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            self.decoder.feed(data)
            DispatchQueue.main.async {
                self.framesReceived = self.decoder.frameCount
                if self.phase != .live { self.phase = .live }
            }
        }

        // Outgoing audio: mic → 16k PCM → UDP (mute drops packets at source)
        audio.onPacket = { [weak self] pkt in
            guard let self = self, !self.isMuted else { return }
            self.transport.send(pkt)
        }
        // Audio levels -> meters (peak-hold with decay so bars don't flicker)
        audio.onTxLevel = { [weak self] lvl in
            DispatchQueue.main.async { self?.txLevel = max(lvl, (self?.txLevel ?? 0) * 0.8) }
        }
        audio.onRxLevel = { [weak self] lvl in
            DispatchQueue.main.async { self?.rxLevel = max(lvl, (self?.rxLevel ?? 0) * 0.8) }
        }
        // Off the main path: first touch of the mic can block on permission /
        // session init, and audio must never hold up transport/video startup.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }

        // Outgoing: camera → H.264 → UDP
        camera.onFrame = { [weak self] h264Data, _ in
            guard let self = self, !self.cameraOff else { return }
            self.transport.send(h264Data)
            self.bytesSent += h264Data.count
            DispatchQueue.main.async { self.framesSent += 1 }
        }
        camera.start()

        // Metrics timer
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                self.txKBps = Double(self.bytesSent) / 1024
                self.rxKBps = Double(self.bytesRecv) / 1024
            }
        }

        startABR()

        // Fallback: go live after 2s even without remote video
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.phase == .connecting { self.phase = .live }
        }
    }

    func stopCall() {
        camera.stop()
        camera.stopAll()
        audio.stop()
        transport.disconnect()
        timer?.invalidate(); timer = nil
        abrTimer?.invalidate(); abrTimer = nil
        phase = .idle
        framesSent = 0; framesReceived = 0
        bytesSent = 0; bytesRecv = 0
        txKBps = 0; rxKBps = 0
    }

    // Get local WiFi IP
    private func getLocalIP() -> String {
        var address = "?.?.?.?"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr!.pointee.ifa_next }
                let iface = ptr!.pointee
                let family = iface.ifa_addr.pointee.sa_family
                if family == UInt8(AF_INET) {
                    let name = String(cString: iface.ifa_name)
                    if name.hasPrefix("en") || name.hasPrefix("pdp") || name.hasPrefix("wl") {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        let s = String(cString: hostname)
                        if !s.hasPrefix("169.254") && s != "127.0.0.1" {
                            address = s
                        }
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
