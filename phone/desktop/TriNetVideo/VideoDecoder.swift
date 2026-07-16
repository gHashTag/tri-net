// VideoDecoder.swift — H.264 decoding + display via VideoToolbox (macOS)
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import SwiftUI

class VideoDecoder: ObservableObject {
    @Published var frameCount: Int = 0
    @Published var currentFrame: CVImageBuffer?

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var fedCount = 0

    func feed(_ nal: Data) {
        guard nal.count > 4 else { return }
        let type = nal[4] & 0x1F
        fedCount += 1
        if fedCount <= 10 || fedCount % 500 == 0 {
            NSLog("TRINET: NAL #\(fedCount) type=\(type) \(nal.count)B session=\(session != nil)")
        }
        switch type {
        // CMVideoFormatDescriptionCreateFromH264ParameterSets expects raw
        // parameter sets — strip the 4-byte Annex-B start code
        case 7: NSLog("TRINET: got SPS \(nal.count)B"); sps = nal.subdata(in: 4..<nal.count); tryInit()
        case 8: NSLog("TRINET: got PPS \(nal.count)B"); pps = nal.subdata(in: 4..<nal.count); tryInit()
        default: decode(nal)
        }
    }

    private func tryInit() {
        guard let sps = sps, let pps = pps, formatDesc == nil else { return }
        sps.withUnsafeBytes { sp in
            pps.withUnsafeBytes { pp in
                let ptrs: [UnsafePointer<UInt8>] = [
                    sp.bindMemory(to: UInt8.self).baseAddress!,
                    pp.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let fdStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc
                )
                NSLog("TRINET: CMVideoFormatDescriptionCreate status=\(fdStatus)")
                guard let d = desc else { return }
                formatDesc = d

                let ref = Unmanaged.passUnretained(self).toOpaque()
                var cb = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { ref, _, status, _, buf, _, _ in
                        guard status == noErr, let buf = buf else { return }
                        let dec = Unmanaged<VideoDecoder>.fromOpaque(ref!).takeUnretainedValue()
                        DispatchQueue.main.async {
                            if dec.frameCount == 0 { NSLog("TRINET: FIRST FRAME DECODED!") }
                            dec.currentFrame = buf
                            dec.frameCount += 1
                        }
                    },
                    decompressionOutputRefCon: ref
                )
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
                ]
                var ns: VTDecompressionSession?
                let vtStatus = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: d,
                    decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: &cb, decompressionSessionOut: &ns
                )
                NSLog("TRINET: VTDecompressionSessionCreate status=\(vtStatus) session=\(ns != nil)")
                session = ns
            }
        }
    }

    private func decode(_ nal: Data) {
        guard let s = session, let fd = formatDesc else { return }
        var avcc = Data()
        let body = nal.subdata(in: 4..<nal.count)
        var len = UInt32(body.count).bigEndian
        avcc.append(Data(bytes: &len, count: 4))
        avcc.append(body)

        var bb: CMBlockBuffer?
        let n = avcc.count
        avcc.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int8.self).baseAddress!
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                memoryBlock: nil, blockLength: n,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &bb)
            if let b = bb { CMBlockBufferReplaceDataBytes(with: p, blockBuffer: b, offsetIntoDestination: 0, dataLength: n) }
        }
        guard let b = bb else { return }
        var ss = n
        var sb: CMSampleBuffer?
        var ti = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(), decodeTimeStamp: CMTime())
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: b, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &ti,
            sampleSizeEntryCount: 1, sampleSizeArray: &ss, sampleBufferOut: &sb)
        guard let sbuf = sb else { return }
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sbuf, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }
}
