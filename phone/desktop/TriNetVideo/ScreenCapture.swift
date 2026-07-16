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
    private(set) var running = false

    func start() {
        guard !running else { return }
        encoder.onNALUnit = { [weak self] nal in self?.onNALUnit?(nal) }
        Task { await begin() }
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                NSLog("TRINET: no display to capture"); return
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

            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            running = true
            NSLog("TRINET: screen capture up \(cfg.width)x\(cfg.height)")
        } catch {
            NSLog("TRINET: screen capture failed: \(error)")
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
        guard type == .screen, running, sb.isValid else { return }
        // Only forward complete frames (SCStream marks incomplete/idle ones).
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete else { return }
        encoder.encode(sb)
    }
}
