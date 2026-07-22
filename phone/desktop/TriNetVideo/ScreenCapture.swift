// ScreenCapture.swift — macOS display capture via ScreenCaptureKit, encoded by
// the same H.264 path as the camera so screen frames ride the existing mesh
// transport. Toggled from CallManager; the peer just sees a different video
// source. Requires the Screen Recording permission (prompted on first use).
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

@available(macOS 12.3, *)
final class ScreenCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let encoder = VideoEncoder()
    private let queue = DispatchQueue(label: "screen.capture")
    var onNALUnit: ((Data) -> Void)?
    var onStarted: ((Bool, String?) -> Void)?   // (success, error) on the main queue
    private(set) var running = false
    private var frameCount = 0
    private var nalCount = 0

    func start() {
        guard !running else { return }
        encoder.onNALUnit = { [weak self] nal in
            guard let self = self else { return }
            self.nalCount += 1
            if self.nalCount == 1 || self.nalCount % 150 == 0 { NSLog("TRINET: screen NAL #\(self.nalCount) \(nal.count)B") }
            self.onNALUnit?(nal)
        }
        Task { await begin() }
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                NSLog("TRINET: no display to capture")
                DispatchQueue.main.async { self.onStarted?(false, "no display found") }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            // Cap at 720p and 15fps — screen content is large; keeps NALs and
            // bitrate in line with the camera path over UDP.
            let scale = min(1.0, 1280.0 / Double(display.width))
            cfg.width = Int(Double(display.width) * scale)
            cfg.height = Int(Double(display.height) * scale)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.queueDepth = 4
            cfg.showsCursor = true

            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            running = true
            frameCount = 0
            NSLog("TRINET: screen capture up \(cfg.width)x\(cfg.height)")
            DispatchQueue.main.async { self.onStarted?(true, nil) }
        } catch {
            // The usual cause: Screen Recording permission not granted (and, once granted, the app must be
            // RESTARTED — ScreenCaptureKit caches the denial for the process lifetime).
            NSLog("TRINET: screen capture failed: \(error)")
            DispatchQueue.main.async {
                self.onStarted?(false, "grant Screen Recording in System Settings ▸ Privacy, then RESTART the app")
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, running, sb.isValid, CMSampleBufferGetImageBuffer(sb) != nil else { return }
        // Skip ONLY frames we can positively read as idle/incomplete. If the attachment format differs (it has
        // across macOS versions) and we can't read the status, ENCODE anyway — dropping every frame on a failed
        // cast is exactly what made "screen share does nothing" with the permission already granted.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw),
           st != .complete && st != .started {
            return
        }
        frameCount += 1
        if frameCount == 1 || frameCount % 150 == 0 { NSLog("TRINET: screen frame #\(frameCount) encoded") }
        encoder.encode(sb)
    }
}
