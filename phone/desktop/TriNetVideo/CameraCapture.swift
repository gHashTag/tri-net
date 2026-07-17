// CameraCapture.swift — macOS camera capture (AVFoundation)
import Foundation
import AVFoundation
import CoreMedia
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
        // preset after input: some cameras ignore it when set before
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else {
            NSLog("TRINET: vga640x480 preset unsupported, keeping \(session.sessionPreset.rawValue)")
        }

        // Width/height keys force the output to scale — cameras ignore the
        // session preset and deliver 1080p, whose I-frames exceed a single
        // UDP datagram (drops/EMSGSIZE) and the peer can never start decoding
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 480
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
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
    // Mesh profile — held here too, because the encoder is re-created on a camera
    // switch and would otherwise silently revert to the Wi-Fi bitrate cap.
    var meshMode = false { didSet { encoder?.meshMode = meshMode } }
    var oversizedNALs: Int { encoder?.oversizedNALs ?? 0 }

    // Virtual background: blur everything but the person on the outgoing frame.
    var blurBackground = false
    private let blur = BackgroundBlur()

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
        if blurBackground, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let out = blur.process(pb)
            encoder?.encode(pixelBuffer: out, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        } else {
            encoder?.encode(sampleBuffer)
        }
    }
}
