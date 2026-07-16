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
        session.sessionPreset = .vga640x480

        session.inputs.forEach { session.removeInput($0) }
        if let cam = device ?? AVCaptureDevice.default(for: .video) {
            if let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
            }
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        queue.async { self.session.startRunning() }

        // Start encoder
        let enc = VideoEncoder()
        if enc.setup() {
            enc.onNALUnit = { [weak self] data in self?.onNALUnit?(data) }
            encoder = enc
        }
    }

    func switchTo(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
    }

    func stop() {
        session.stopRunning()
        encoder = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
        encoder?.encode(sampleBuffer)
    }
}
