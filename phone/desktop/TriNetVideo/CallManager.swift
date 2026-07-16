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

    init() {
        localIP = MeshTransport.getLocalIP()
        // Load recent IPs from UserDefaults
        if let saved = UserDefaults.standard.array(forKey: "recentIPs") as? [String] {
            recentIPs = saved
        }
    }

    let camera = CameraCapture()
    let decoder = VideoDecoder()
    let transport = MeshTransport()

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

        // Transport → Decoder → Display
        transport.onReceive = { [weak self] data in
            guard let self = self else { return }
            self.decoder.feed(data)
            DispatchQueue.main.async { 
                self.framesReceived = self.decoder.frameCount
                if self.framesReceived > 0 { self.status = "Connected" }
            }
        }

        // Start camera
        camera.start()
        previewSession = camera.session

        // Start transport (send to peer:7000, listen on :7000 — same port both ways)
        transport.connect(peerHost: remoteIP, peerPort: p, listenPort: p)

        isInCall = true
        isStarting = false
        status = "Waiting for video..."
    }

    func endCall() {
        camera.stop()
        transport.disconnect()
        isInCall = false
        status = "Idle"
        framesSent = 0
        framesReceived = 0
        previewSession = nil
    }
}
