// VideoEncoder.swift — H.264 encoding via VideoToolbox (macOS)
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

class VideoEncoder {
    private var session: VTCompressionSession?
    var onNALUnit: ((Data) -> Void)?
    // Dimensions come from the first captured frame — cameras that ignore
    // the session preset would otherwise get scale-squashed by VideoToolbox
    private var width: Int32 = 0
    private var height: Int32 = 0

    func setup(width: Int32, height: Int32) -> Bool {
        self.width = width
        self.height = height
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
        guard r == noErr, let s = s else {
            NSLog("TRINET: VTCompressionSessionCreate status=\(r)")
            return false
        }
        session = s
        // AutoLevel: a fixed level (e.g. 3.1, max 1280x720) makes the encoder
        // silently reject every frame from cameras that ignore the session
        // preset and deliver 1080p. Bitrate scales with the actual dimensions.
        maxBitrate = min(2_000_000, Int(width) * Int(height) * 2)
        curBitrate = maxBitrate
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel as CFString)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    private func handleEncoded(_ sb: CMSampleBuffer) {
        // UDP is lossy and receivers can join mid-stream, so SPS/PPS must be
        // re-sent with every keyframe — the peer's decoder can't start without them
        var isKeyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFDictionary.self)
            isKeyframe = !CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        }
        if isKeyframe, let fmtDesc = CMSampleBufferGetFormatDescription(sb) {
            for i in 0..<2 {
                var size = 0
                var psPtr: UnsafePointer<UInt8>? = nil
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmtDesc, parameterSetIndex: i, parameterSetPointerOut: &psPtr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let p = psPtr, size > 0 {
                    var d = Data([0, 0, 0, 1])
                    d.append(Data(bytes: p, count: size))
                    emit(d, key: true)
                }
            }
        }
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
            emit(d, key: isKeyframe)
            off += 4 + Int(nl)
        }
    }

    // MARK: mesh profile
    //
    // Two hard limits the radio path imposes, neither of which exists on Wi-Fi:
    //  * throughput — the BPSK link is 1 Mbps raw (4 MSPS / SPS 4) and HALF-DUPLEX,
    //    so a realistic two-way budget is ~200-400 kbps for BOTH directions.
    //  * per-NAL ceiling — the bridge addresses fragments with a one-byte index
    //    and carries <=70B each, so max_nal_size = 255*70 = 17850 B
    //    (specs/video_bridge.t27). An I-frame above that is UNDELIVERABLE at any
    //    bitrate: it cannot be expressed on the wire, so it is silently dropped.
    static let meshMaxNAL = 17_850
    static let meshBitrate = 150_000   // leaves room for Opus (~25 kbps each way)
    private(set) var oversizedNALs = 0
    var meshMode = false { didSet { applyCeiling() } }

    // Re-apply the ceiling; mesh mode is usually toggled after setup().
    private func applyCeiling() {
        guard let s = session else { return }
        maxBitrate = meshMode ? VideoEncoder.meshBitrate
                              : min(2_000_000, Int(width) * Int(height) * 2)
        curBitrate = min(curBitrate, maxBitrate)
        bitrateKbps = curBitrate / 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        NSLog("TRINET: mesh mode \(meshMode ? "ON" : "off") — cap \(maxBitrate / 1000) kbps")
    }

    // Every NAL leaves through here so the mesh ceiling is enforced in ONE place.
    // A frame over the ceiling is not a quality problem, it is an undeliverable
    // one, so react by backing the bitrate off rather than shipping it blind.
    private var loggedFirstKey = false
    private func emit(_ d: Data, key: Bool) {
        if meshMode && d.count > VideoEncoder.meshMaxNAL {
            oversizedNALs += 1
            if oversizedNALs <= 3 || oversizedNALs % 50 == 0 {
                NSLog("TRINET: NAL \(d.count)B over mesh ceiling \(VideoEncoder.meshMaxNAL)B (#\(oversizedNALs)) — undeliverable, backing off")
            }
            nudgeBitrate(down: true)
        }
        if key && !loggedFirstKey && d.count > 1000 {
            loggedFirstKey = true
            NSLog("TRINET: first keyframe \(d.count)B (mesh ceiling \(VideoEncoder.meshMaxNAL)B, mesh=\(meshMode))")
        }
        onNALUnit?(d)
    }

    // Set by a peer Picture-Loss-Indication (0xFC control packet): forces the
    // next encoded frame to be an IDR so the far decoder can resync after loss.
    private var forceKeyframeNext = false
    func forceKeyframe() { forceKeyframeNext = true }

    // Adaptive bitrate: the PLI rate is a live loss estimate. Drop the encode
    // bitrate on sustained loss, recover it toward the cap when the link is clean.
    private var maxBitrate = 1_000_000
    private var curBitrate = 1_000_000
    private(set) var bitrateKbps: Int = 0
    // AIMD, tuned on hardware (see specs/video_bridge.t27 dead-zone note).
    // Multiplicative DECREASE recovers fast from congestion; ADDITIVE INCREASE
    // seeks the ceiling without oscillating. The old x1.2/x0.7 swung 36% and sat
    // at 70% of the link; +10 kbps / x0.9 settles near 80% and holds, with zero
    // steady-state loss. (Swept in frags/s as +15/x0.9; ~15 frags/s = ~10 kbps.)
    func nudgeBitrate(down: Bool) {
        guard let s = session, maxBitrate > 0 else { return }
        let floor = max(120_000, maxBitrate / 8)
        curBitrate = down ? max(floor, Int(Double(curBitrate) * 0.9))
                          : min(maxBitrate, curBitrate + 10_000)
        bitrateKbps = curBitrate / 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encode(pixelBuffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // Encode a raw pixel buffer (used when a filter — e.g. background blur —
    // has already produced a processed frame).
    func encode(pixelBuffer pb: CVPixelBuffer, pts: CMTime) {
        if session == nil {
            let w = Int32(CVPixelBufferGetWidth(pb))
            let h = Int32(CVPixelBufferGetHeight(pb))
            guard setup(width: w, height: h) else {
                NSLog("TRINET: encoder setup FAILED \(w)x\(h)")
                return
            }
            NSLog("TRINET: encoder session \(w)x\(h)")
        }
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            NSLog("TRINET: forcing keyframe (peer PLI)")
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
}
