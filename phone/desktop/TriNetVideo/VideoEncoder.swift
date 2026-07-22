// VideoEncoder.swift — H.264 encoding via VideoToolbox (macOS)
import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreImage

// Downscale a camera pixel buffer to the ladder's target size before encoding, reusing a pool. Identity when
// src == dst so the top rung costs nothing. Mirrors iOS FrameScaler.
final class FrameScaler {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var pw = 0, ph = 0
    func scale(_ pb: CVPixelBuffer, toW w: Int, toH h: Int) -> CVPixelBuffer {
        let sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb)
        if sw == w && sh == h { return pb }
        if pool == nil || pw != w || ph != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pb),
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool); pw = w; ph = h
        }
        var out: CVPixelBuffer?
        guard let p = pool, CVPixelBufferPoolCreatePixelBuffer(nil, p, &out) == kCVReturnSuccess,
              let dst = out else { return pb }
        let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: CGFloat(w)/CGFloat(sw),
                                                                               y: CGFloat(h)/CGFloat(sh)))
        ci.render(img, to: dst)
        return dst
    }
}

class VideoEncoder {
    private var session: VTCompressionSession?
    var onNALUnit: ((Data) -> Void)?
    // Dimensions come from the first captured frame — cameras that ignore
    // the session preset would otherwise get scale-squashed by VideoToolbox
    private var width: Int32 = 0
    private var height: Int32 = 0

    // Adaptive-resolution ladder — picks the frame size from the AIMD's curBitrate. Weak link -> small SHARP
    // picture; strong Wi-Fi -> 720p. Recreating the session on a step forces one IDR + new SPS, which the
    // decoder already handles (SPS change -> re-init). Mirrors iOS.
    // The ladder is keyed to target HEIGHT only; WIDTH is computed from the camera frame's real aspect at
    // encode time, so the scale is always UNIFORM and the picture is NEVER squished — whatever the camera's
    // aspect. This is why the "stretched picture" can't come back. Mirrors iOS.
    private struct Rung { let h: Int32; let minBitrate: Int }
    private static let ladder: [Rung] = [
        Rung(h: 720, minBitrate: 650_000),
        Rung(h: 540, minBitrate: 380_000),
        Rung(h: 360, minBitrate: 200_000),
        Rung(h: 270, minBitrate: 110_000),
        Rung(h: 180, minBitrate: 0),
    ]
    private let scaler = FrameScaler()
    private var lastResStep = Date.distantPast
    private func targetRung() -> Rung {
        let cap: Int32 = meshMode ? 240 : 4096
        return VideoEncoder.ladder.first { $0.minBitrate <= curBitrate && $0.h <= cap } ?? VideoEncoder.ladder.last!
    }

    func setup(width: Int32, height: Int32) -> Bool {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        // Low-latency rate control: the RTC-tuned rate controller (fast reaction, no big VBV buffer) — better
        // quality-under-motion than the default, and the gate for LTR/temporal-SVC later. macOS 11.3+ (target 14).
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue]
        let r = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
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
        // FIXED ceiling (not tied to the encoded size) so curBitrate can climb high enough to unlock the 720p
        // rung; the ladder picks the frame size from curBitrate. Preserve curBitrate across a resolution step.
        maxBitrate = meshMode ? VideoEncoder.meshBitrate : 900_000
        if curBitrate == 0 { curBitrate = min(maxBitrate, 900_000) }   // first call: start ~540p, then climb
        curBitrate = min(curBitrate, maxBitrate)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // High profile: 8x8 transform + better intra prediction -> ~5-10% better quality-per-bit than Main at
        // the same bitrate; all Apple decoders support it. Verified accepted in a VideoToolbox harness.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel as CFString)
        // Hard cap over AverageBitRate: clamp keyframe bursts that overflow the UDP link -> less macroblocking.
        let capBytes = (curBitrate * 5 / 4) / 8
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [capBytes, 1] as CFArray)
        // Rare keyframes (~5s, not ~1s): an I-frame is ~5-10x a P-frame; recovery is PLI-driven (peer asks for
        // an IDR on loss/join), so a long interval frees bits for detail. Harness: 1 IDR / 60 frames.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 150 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 5.0 as CFNumber)
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
        // Mesh mode no longer caps bitrate. The NODE steers the rate through
        // link feedback measured on the real link; the 150k constant was a
        // pre-feedback guess that only fought the ABR (watched live: the cap
        // and the node advice pulling the encoder in opposite directions).
        // Mesh mode still enforces the per-NAL ceiling in emit() — a NAL over
        // 17850B is undeliverable at ANY bitrate, that part is wire format.
        maxBitrate = meshMode ? VideoEncoder.meshBitrate : 900_000
        curBitrate = min(curBitrate, maxBitrate)
        bitrateKbps = curBitrate / 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        NSLog("%@", "TRINET: mesh mode \(meshMode ? "ON" : "off") — NAL ceiling only, rate governed by the node")
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
    private var maxBitrate = 900_000
    private var curBitrate = 0   // 0 = uninitialized; setup() seeds it (~540p worth) on the first frame
    private(set) var bitrateKbps: Int = 0
    // AIMD, tuned on hardware (see specs/video_bridge.t27 dead-zone note).
    // Multiplicative DECREASE recovers fast from congestion; ADDITIVE INCREASE
    // seeks the ceiling without oscillating. The old x1.2/x0.7 swung 36% and sat
    // at 70% of the link; +10 kbps / x0.9 settles near 80% and holds, with zero
    // steady-state loss. (Swept in frags/s as +15/x0.9; ~15 frags/s = ~10 kbps.)
    func nudgeBitrate(down: Bool) {
        guard let s = session, maxBitrate > 0 else { return }
        let floor = 100_000   // absolute, so the resolution ladder can reach its small rungs on a weak link
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
        if curBitrate == 0 { curBitrate = meshMode ? VideoEncoder.meshBitrate : 900_000 }  // seed before the ladder reads it
        let srcW = Int(CVPixelBufferGetWidth(pb)), srcH = Int(CVPixelBufferGetHeight(pb))
        guard srcW > 0, srcH > 0 else { return }
        // Target HEIGHT from the ladder (rate-limited to one step / 3s); WIDTH preserves the camera's real
        // aspect -> uniform scale -> never squished.
        let wantH: Int32
        if session == nil {
            wantH = min(Int32(srcH), targetRung().h)
        } else {
            let t = min(Int32(srcH), targetRung().h)
            if t != height, Date().timeIntervalSince(lastResStep) > 3.0 { wantH = t; lastResStep = Date() }
            else { wantH = height }
        }
        let wantW = Int32(((Int(wantH) * srcW / srcH) + 1) & ~1)   // even width at the source aspect
        let frame = scaler.scale(pb, toW: Int(wantW), toH: Int(wantH))
        if session == nil || width != wantW || height != wantH {
            if let old = session { VTCompressionSessionInvalidate(old); session = nil }
            guard setup(width: wantW, height: wantH) else {
                NSLog("TRINET: encoder setup FAILED \(wantW)x\(wantH)")
                return
            }
            NSLog("TRINET: encoder resolution \(wantW)x\(wantH) @ \(curBitrate/1000)kbps")
            forceKeyframeNext = true   // a fresh session must lead with an IDR + new SPS for the peer
        }
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: frame, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
}
