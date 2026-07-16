// CallManager.swift — Orchestrates camera → encode → transport → decode → display
import Foundation
import Combine
import AVFoundation
import CoreVideo

struct ChatLine: Identifiable {
    let id = UUID()
    enum Who { case me, them }
    let who: Who
    let text: String
}

class CallManager: ObservableObject {
    @Published var isInCall = false
    @Published var isStarting = false
    @Published var remoteIP = "192.168.1.103"
    @Published var port = "7000"
    @Published var localIP = ""
    @Published var framesSent = 0
    @Published var framesReceived = 0
    @Published var status = "Ready"
    @Published var error: String?
    @Published var isMuted = false
    @Published var cameraOff = false
    @Published var recentIPs: [String] = []
    @Published var cameras: [AVCaptureDevice] = []
    @Published var selectedCameraID: String = ""
    // Live audio levels (0...1) for the TX/RX meters. Decayed on the main
    // thread so the bars fall smoothly when a buffer is quiet or absent.
    @Published var txLevel: Float = 0
    @Published var rxLevel: Float = 0

    init() {
        localIP = MeshTransport.getLocalIP()
        // Load recent IPs from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: "recentIPs") as? [String] {
            recentIPs = saved
        }
        cameras = CameraCapture.availableCameras()
        selectedCameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID ?? ""
    }

    func selectCamera(_ id: String) {
        selectedCameraID = id
        guard let device = cameras.first(where: { $0.uniqueID == id }) else { return }
        if isInCall { camera.switchTo(device) }
    }

    let camera = CameraCapture()
    let decoder = VideoDecoder()
    let transport = MeshTransport()
    let audio = AudioController()
    private var screen: Any?  // ScreenCapture (macOS 12.3+), lazily created

    // Local preview
    @Published var previewSession: AVCaptureSession?
    @Published var isScreenSharing = false

    // Chat + reactions
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?    // transient emoji overlay

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

    // Toggle the outgoing video source between camera and screen. Both feed the
    // same encoder→transport path, so the peer just sees a new source.
    func toggleScreenShare() {
        if #available(macOS 12.3, *) {
            if isScreenSharing {
                (screen as? ScreenCapture)?.stop()
                isScreenSharing = false
            } else {
                let sc = (screen as? ScreenCapture) ?? ScreenCapture()
                screen = sc
                sc.onNALUnit = { [weak self] nal in
                    guard let self = self, self.isScreenSharing else { return }
                    self.transport.send(nal)
                    DispatchQueue.main.async { self.framesSent += 1 }
                }
                sc.start()
                isScreenSharing = true  // camera guard stops sending its NALs
            }
        } else {
            NSLog("TRINET: screen share needs macOS 12.3+")
        }
    }

    func startCall() {
        guard let p = UInt16(port) else { NSLog("TRINET: invalid port"); return }
        NSLog("TRINET: startCall to \(remoteIP):\(p)")
        isStarting = true
        status = "Connecting to \(remoteIP)..."

        // Save IP to recent
        if !recentIPs.contains(remoteIP) {
            recentIPs.insert(remoteIP, at: 0)
            if recentIPs.count > 5 { recentIPs.removeLast() }
            UserDefaults.standard.set(recentIPs, forKey: "recentIPs")
        }

        // Camera → Encoder → Transport (suppressed while screen sharing)
        camera.onNALUnit = { [weak self] nal in
            guard let self = self, !self.cameraOff, !self.isScreenSharing else { return }
            self.transport.send(nal)
            DispatchQueue.main.async { self.framesSent += 1 }
        }

        // Peer asks for a fresh keyframe after loss → force an IDR now
        decoder.onKeyframeNeeded = { [weak self] in
            self?.transport.send(Data([0xFC, 0x00]))
        }

        // Transport → audio / PLI / chat / reaction / Decoder → Display
        transport.onReceive = { [weak self] data in
            guard let self = self else { return }
            if data.count == 2, data[0] == 0xFC { // Picture Loss Indication
                self.camera.forceKeyframe()
                return
            }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD { // audio
                self.audio.playPacket(data.subdata(in: 2..<data.count))
                return
            }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA { // chat text
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)) }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC { // reaction emoji
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            self.decoder.feed(data)
            DispatchQueue.main.async {
                self.framesReceived = self.decoder.frameCount
                if self.framesReceived > 0 { self.status = "Connected" }
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
        // Off the main path: first touch of the mic can block ~60s on TCC
        // init, and audio must never hold up transport/video startup.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.audio.start() }

        // Start camera
        camera.start(device: cameras.first(where: { $0.uniqueID == selectedCameraID }))
        previewSession = camera.session

        // Start transport (send to peer:7000, listen on :7000 — same port both ways)
        transport.connect(peerHost: remoteIP, peerPort: p, listenPort: p)

        isInCall = true
        isStarting = false
        status = "Waiting for video..."
    }

    func endCall() {
        if #available(macOS 12.3, *) { (screen as? ScreenCapture)?.stop() }
        isScreenSharing = false
        camera.stop()
        audio.stop()
        transport.disconnect()
        isInCall = false
        status = "Idle"
        framesSent = 0
        framesReceived = 0
        previewSession = nil
    }
}
