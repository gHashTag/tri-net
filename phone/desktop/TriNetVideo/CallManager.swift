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
    @Published var bitrateKbps: Int = 0

    // Adaptive bitrate: sample the incoming PLI rate every 3s. Sustained PLIs
    // mean the peer is losing our video → back off; a clean window → recover.
    private var pliCount = 0
    private var abrTimer: Timer?
    private func startABR() {
        abrTimer?.invalidate()
        abrTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self = self, self.isInCall else { return }
            if self.pliCount >= 3 { self.camera.nudgeBitrate(down: true) }
            else if self.pliCount == 0 { self.camera.nudgeBitrate(down: false) }
            self.pliCount = 0
            self.bitrateKbps = self.camera.bitrateKbps
        }
    }

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
    private let recorder = CallRecorder()
    private var recSink: AnyCancellable?
    @Published var isRecording = false
    @Published var lastRecordingPath: String?
    @Published var isBlurred = false

    func toggleBlur() {
        isBlurred.toggle()
        camera.blurBackground = isBlurred
    }

    func toggleRecording() {
        if isRecording {
            recorder.stop { [weak self] url in self?.lastRecordingPath = url?.path }
            isRecording = false
            recSink = nil
        } else {
            recorder.start()
            isRecording = recorder.recording
            // Append every decoded frame to the recording.
            recSink = decoder.$currentFrame.sink { [weak self] buf in
                guard let self = self, self.isRecording, let b = buf else { return }
                self.recorder.append(b)
            }
        }
    }

    // Local preview
    @Published var previewSession: AVCaptureSession?
    @Published var isScreenSharing = false

    // Chat + reactions
    @Published var chat: [ChatLine] = []
    @Published var liveReaction: String?    // transient emoji overlay

    // Group / roster — participants heard from (by source IP) + self.
    @Published var roster: [String] = []
    @Published var isGroup = false
    private var lastSeen: [String: Date] = [:]
    // Per-source decoders for conference video (1-1 keeps the single `decoder`).
    var groupDecoders: [String: VideoDecoder] = [:]

    private func noteSender(_ ip: String) {
        lastSeen[ip] = Date()
        let active = lastSeen.filter { Date().timeIntervalSince($0.value) < 6 }.keys.sorted()
        let list = ([localIP] + active).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if list != roster { DispatchQueue.main.async { self.roster = list } }
    }

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
                self.pliCount += 1   // adaptive bitrate: PLI = loss signal
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

        // Per-source routing (roster in both modes; group video decode).
        transport.onReceiveFrom = { [weak self] data, ip in
            guard let self = self else { return }
            self.noteSender(ip)
            guard self.isGroup else { return }  // 1-1 already handled in onReceive
            // Control packets are broadcast to all — handle once
            if data.count == 2, data[0] == 0xFC { return }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD {
                self.audio.playPacket(data.subdata(in: 2..<data.count)); return
            }
            if data.count > 2, data[0] == 0xFB, data[1] == 0xCA {
                let msg = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.chat.append(ChatLine(who: .them, text: msg)) }
                return
            }
            if data.count > 2, data[0] == 0xFE, data[1] == 0xAC {
                let emoji = String(decoding: data.subdata(in: 2..<data.count), as: UTF8.self)
                DispatchQueue.main.async { self.showReaction(emoji) }
                return
            }
            // Video → per-source decoder
            let dec = self.groupDecoders[ip] ?? {
                let d = VideoDecoder(); self.groupDecoders[ip] = d
                DispatchQueue.main.async { self.objectWillChange.send() }
                return d
            }()
            dec.feed(data)
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

        // Group if the peer field lists several IPs (comma/space separated);
        // otherwise a 1-1 forward-secret call.
        let hosts = remoteIP.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if hosts.count > 1 {
            isGroup = true
            transport.connectGroup(peerHosts: hosts, peerPort: p, listenPort: p)
            NSLog("TRINET: group call — \(hosts.count) peers")
        } else {
            isGroup = false
            transport.connect(peerHost: remoteIP, peerPort: p, listenPort: p)
        }

        isInCall = true
        isStarting = false
        status = "Waiting for video..."
        startABR()
    }

    func endCall() {
        if #available(macOS 12.3, *) { (screen as? ScreenCapture)?.stop() }
        isScreenSharing = false
        if isRecording { recorder.stop { [weak self] url in self?.lastRecordingPath = url?.path }; isRecording = false; recSink = nil }
        abrTimer?.invalidate(); abrTimer = nil
        camera.stop()
        audio.stop()
        transport.disconnect()
        isInCall = false
        isGroup = false
        roster = []
        groupDecoders = [:]
        lastSeen = [:]
        status = "Idle"
        framesSent = 0
        framesReceived = 0
        previewSession = nil
    }
}
