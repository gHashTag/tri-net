// CallManager.swift — Orchestrates camera → encode → transport → decode → display
import Foundation
import Combine
import AVFoundation
import CoreVideo

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

    // Local preview
    @Published var previewSession: AVCaptureSession?

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

        // Camera → Encoder → Transport
        camera.onNALUnit = { [weak self] nal in
            guard let self = self, !self.cameraOff else { return }
            self.transport.send(nal)
            DispatchQueue.main.async { self.framesSent += 1 }
        }

        // Peer asks for a fresh keyframe after loss → force an IDR now
        decoder.onKeyframeNeeded = { [weak self] in
            self?.transport.send(Data([0xFC, 0x00]))
        }

        // Transport → audio player / PLI / Decoder → Display
        transport.onReceive = { [weak self] data in
            guard let self = self else { return }
            if data.count == 2, data[0] == 0xFC { // Picture Loss Indication
                self.camera.forceKeyframe()
                return
            }
            if data.count > 2, data[0] == 0xFD, data[1] == 0xAD {
                self.audio.playPacket(data.subdata(in: 2..<data.count))
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
