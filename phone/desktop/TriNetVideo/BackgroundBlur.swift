// BackgroundBlur.swift — virtual background: blur everything but the person.
// Vision person-segmentation produces a mask; CoreImage blurs the background
// and composites the sharp foreground back over it. Applied to the outgoing
// camera frame before H.264 encode, so the peer receives the blurred video.
import Foundation
import Vision
import CoreImage
import CoreVideo

final class BackgroundBlur {
    private let ci = CIContext()
    private let request = VNGeneratePersonSegmentationRequest()
    // Reused output buffer pool for the composited frame.
    private var pool: CVPixelBufferPool?

    init() {
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    // Returns a new pixel buffer with the background blurred, or the original
    // if segmentation fails (never blocks the video path).
    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return pb }

        let frame = CIImage(cvPixelBuffer: pb)
        var maskImg = CIImage(cvPixelBuffer: mask)
        // Scale the mask to the frame size.
        let sx = frame.extent.width / maskImg.extent.width
        let sy = frame.extent.height / maskImg.extent.height
        maskImg = maskImg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let blurred = frame
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 12)
            .cropped(to: frame.extent)

        guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: frame,           // sharp person (mask = white)
            kCIInputBackgroundImageKey: blurred, // blurred background
            kCIInputMaskImageKey: maskImg
        ])?.outputImage else { return pb }

        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pb),
                kCVPixelBufferWidthKey as String: W,
                kCVPixelBufferHeightKey as String: H,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let p = pool, CVPixelBufferPoolCreatePixelBuffer(nil, p, &out) == kCVReturnSuccess,
              let outBuf = out else { return pb }
        ci.render(blend, to: outBuf)
        return outBuf
    }
}
