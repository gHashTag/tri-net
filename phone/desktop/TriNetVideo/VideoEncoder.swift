// VideoEncoder.swift — H.264 encoding via VideoToolbox (macOS)
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

class VideoEncoder {
    private var session: VTCompressionSession?
    var onNALUnit: ((Data) -> Void)?
    let width: Int32 = 640
    let height: Int32 = 480

    func setup() -> Bool {
        var s: VTCompressionSession?
        let r = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, buf in
                guard status == noErr, let buf = buf else { return }
                let enc = Unmanaged<VideoEncoder>.fromOpaque(ref!).takeUnretainedValue()
                enc.handleEncoded(buf)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s
        )
        guard r == noErr, let s = s else { return false }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 500_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_3_1 as CFString)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        guard let db = CMSampleBufferGetDataBuffer(sb) else { return }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(db, atOffset: 0, lengthAtOffsetOut: &len, totalLengthOut: &total, dataPointerOut: &ptr)
        guard let p = ptr else { return }
        var off = 0
        while off < total - 4 {
            var nl: UInt32 = 0
            memcpy(&nl, p + off, 4)
            nl = CFSwapInt32BigToHost(nl)
            if off + 4 + Int(nl) > total { break }
            var d = Data([0, 0, 0, 1])
            d.append(Data(bytes: p + off + 4, count: Int(nl)))
            onNALUnit?(d)
            off += 4 + Int(nl)
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let s = session, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
}
