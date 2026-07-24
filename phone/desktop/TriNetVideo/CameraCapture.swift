// CameraCapture.swift — macOS camera capture (AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import AppKit

class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.queue")
    private var encoder: VideoEncoder?
    var onNALUnit: ((Data) -> Void)?
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    func start(device: AVCaptureDevice? = nil) {
        guard !session.isRunning else { return }
        session.beginConfiguration()

        session.inputs.forEach { session.removeInput($0) }
        if let cam = device ?? AVCaptureDevice.default(for: .video) {
            if let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
            }
        }
        // 720p (16:9) — the FaceTime HD camera is natively 16:9. Forcing a 4:3 output (640x480) SQUISHED the
        // 16:9 sensor frame ("stretched picture"). 1280x720 matches the sensor aspect, so no squish.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            NSLog("TRINET: 720p/vga presets unsupported, keeping \(session.sessionPreset.rawValue)")
        }

        // Width/height MATCH the 16:9 sensor so the output isn't anamorphically scaled. Caps at 720p (cameras
        // otherwise deliver 1080p+, whose I-frames exceed a UDP datagram). The ladder downscales 16:9 from here.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 1280,
            kCVPixelBufferHeightKey as String: 720
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        // Idempotent (WebRTC-style: the capturer OUTLIVES a call): stop() leaves the output attached, so on
        // the 2nd call the same instance is already in the session and canAddOutput correctly says false —
        // that is REUSE, not a failure. Only a genuine "can't attach a fresh output" is an error.
        if session.outputs.contains(output) {
            // already attached from a previous call — frames keep flowing through the same delegate
        } else if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            NSLog("TRINET: canAddOutput=false — data output NOT attached")
        }

        session.commitConfiguration()
        queue.async { self.session.startRunning() }

        // Start encoder (its session is created lazily from the first frame)
        let enc = VideoEncoder()
        enc.onNALUnit = { [weak self] data in self?.onNALUnit?(data) }
        enc.meshMode = meshMode   // survive encoder re-creation
        encoder = enc
    }

    func forceKeyframe() { encoder?.forceKeyframe() }
    func nudgeBitrate(down: Bool) { encoder?.nudgeBitrate(down: down) }
    var bitrateKbps: Int { encoder?.bitrateKbps ?? 0 }
    var activeHeight: Int32 { encoder?.activeHeight ?? 0 }   // adaptive send resolution for the in-call badge
    // Mesh profile — held here too, because the encoder is re-created on a camera
    // switch and would otherwise silently revert to the Wi-Fi bitrate cap.
    var meshMode = false { didSet { encoder?.meshMode = meshMode } }
    var oversizedNALs: Int { encoder?.oversizedNALs ?? 0 }

    // Virtual background: blur everything but the person on the outgoing frame.
    var blurBackground = false
    private let blur = BackgroundBlur()

    // Camera off: keep the stream ALIVE but send BLACK frames (Zoom-style), so the peer sees a black screen,
    // not a frozen last frame. Cached black buffer, true black via CoreImage, format-agnostic.
    var blackout = false
    private var blackPB: CVPixelBuffer?
    private let ciBlack = CIContext(options: [.cacheIntermediates: false])
    private func blackFrame(like pb: CVPixelBuffer) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if blackPB == nil || CVPixelBufferGetWidth(blackPB!) != w || CVPixelBufferGetHeight(blackPB!) != h {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, CVPixelBufferGetPixelFormatType(pb),
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out)
            if let b = out { ciBlack.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), to: b) }
            blackPB = out
        }
        return blackPB ?? pb
    }

    func switchTo(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        // new camera may deliver different dimensions — restart the encoder
        // so its lazy setup (and the SPS the peer sees) matches the frames
        if encoder != nil {
            let enc = VideoEncoder()
            enc.onNALUnit = { [weak self] data in self?.onNALUnit?(data) }
            enc.meshMode = meshMode   // must survive the switch, or the cap reverts
            encoder = enc
        }
    }

    func stop() {
        session.stopRunning()
        encoder = nil
    }

    private var capCount = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        capCount += 1
        if capCount == 1 { NSLog("TRINET: captureOutput first frame, encoder=\(encoder != nil)") }
        onSampleBuffer?(sampleBuffer)
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { encoder?.encode(sampleBuffer); return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if blackout {
            encoder?.encode(pixelBuffer: blackFrame(like: pb), pts: pts)
        } else if blurBackground {
            encoder?.encode(pixelBuffer: blur.process(pb), pts: pts)
        } else {
            encoder?.encode(pixelBuffer: pb, pts: pts)
        }
    }
}
