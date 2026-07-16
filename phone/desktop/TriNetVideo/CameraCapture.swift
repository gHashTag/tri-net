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

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
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
        encoder = enc
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
        encoder?.encode(sampleBuffer)
    }
}
