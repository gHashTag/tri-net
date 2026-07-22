// VideoPipeline.swift — Camera + H.264 encode/decode + UDP transport (iOS)
import SwiftUI
import AVFoundation
import AudioToolbox
import VideoToolbox
import Vision
import CoreImage
import Network
import CryptoKit
import UIKit   // UIDevice for the discovery default name

// MARK: - Camera Controller

class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var encoder: H264Encoder?
    var onFrame: ((Data, Bool) -> Void)?
    var previewSession: AVCaptureSession { session }

    func startPreview() {
        guard !session.isRunning else { return }
        setupSession()
        DispatchQueue.global().async { self.session.startRunning() }
    }

    private var position: AVCaptureDevice.Position = .front
    private var currentDevice: AVCaptureDevice?
    private var rotCoord: Any?   // AVCaptureDevice.RotationCoordinator (iOS 17+); kept alive for KVO-free reads

    private func setupSession() {
        session.beginConfiguration()
        // 720p (16:9) — the camera's native aspect, so nothing is squished. The FrameScaler shrinks each frame
        // to the ladder's current 16:9 rung before the encoder; the display layers preserve aspect.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720
            : (session.canSetSessionPreset(.vga640x480) ? .vga640x480
               : AVCaptureSession.Preset(rawValue: "AVCaptureSessionPreset352x288"))
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            currentDevice = cam
            if let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
            }
            configureDevice(cam)   // lock frame rate + continuous auto-exposure (steadier, less shimmer)
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        applyOrientation()
    }

    func switchCamera() {
        position = (position == .front) ? .back : .front
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            currentDevice = cam
            if let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
            }
            configureDevice(cam)
        }
        session.commitConfiguration()
        // input swap re-creates the output connection — orientation must be re-applied
        applyOrientation()
        // restart the encoder so its lazy setup matches the new camera's frames
        if encoder != nil {
            let enc = H264Encoder()
            enc.onFrame = { [weak self] data, isKey in self?.onFrame?(data, isKey) }
        enc.meshMode = meshMode
            encoder = enc
        }
    }

    // Lock the capture frame rate (min==max kills capture-interval jitter -> steadier video) and use
    // continuous auto-exposure. Bracketed in lock/unlockForConfiguration as AVFoundation requires.
    private func configureDevice(_ cam: AVCaptureDevice) {
        guard (try? cam.lockForConfiguration()) != nil else { return }
        let fps: Int32 = 24
        if cam.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }) {
            let d = CMTime(value: 1, timescale: fps)
            cam.activeVideoMinFrameDuration = d
            cam.activeVideoMaxFrameDuration = d          // min==max => hard-locked FPS
        }
        if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
        if cam.isLowLightBoostSupported { cam.automaticallyEnablesLowLightBoostWhenAvailable = true }
        cam.unlockForConfiguration()
    }

    // Raw H.264 carries no orientation metadata, so the frame must be upright at CAPTURE. The data
    // output delivers sensor-native LANDSCAPE buffers, so without this the (portrait) front camera is
    // 90 deg off. Apple's RotationCoordinator is the gravity-aware source of truth for the correct
    // angle PER CAMERA (front vs back differ) -- more robust than a hardcoded 90. Front camera is sent
    // UN-mirrored so the remote reads text correctly. Also enable .standard stabilization (not
    // cinematic -- that adds latency) to calm handheld shake.
    private func applyOrientation() {
        guard let conn = output.connection(with: .video) else { return }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = false
        }
        if #available(iOS 17.0, *), let dev = currentDevice {
            let rc = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
            rotCoord = rc                                             // keep alive
            let angle = rc.videoRotationAngleForHorizonLevelCapture
            if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            else if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        } else if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        if let dev = currentDevice, dev.activeFormat.isVideoStabilizationModeSupported(.standard) {
            conn.preferredVideoStabilizationMode = .standard   // .standard not .cinematic (cinematic adds latency)
        }
    }

    func start() {
        guard encoder == nil else { return }
        let enc = H264Encoder()
        enc.onFrame = { [weak self] data, isKey in self?.onFrame?(data, isKey) }
        enc.meshMode = meshMode
        encoder = enc
        if !session.isRunning { startPreview() }
    }

    func forceKeyframe() { encoder?.forceKeyframe() }
    func nudgeBitrate(down: Bool) { encoder?.nudgeBitrate(down: down) }
    // Full-mesh group uploads its stream to EVERY peer, so uplink = peers x bitrate. Split the target
    // across peers (floored) so a 4-6 way call doesn't saturate the uplink.
    func reduceForGroup(peers: Int) { encoder?.setMaxBitrate(max(90_000, 220_000 / max(1, peers))) }
    // Held here too: the encoder is re-created on a camera switch and would
    // otherwise silently revert to the Wi-Fi cap.
    var meshMode = false { didSet { encoder?.meshMode = meshMode } }
    var bitrateKbps: Int { encoder?.bitrateKbps ?? 0 }
    var activeHeight: Int32 { encoder?.activeHeight ?? 0 }   // adaptive send resolution for the in-call badge

    // Virtual background: blur all but the person on the outgoing frame.
    var blurBackground = false
    private let blur = BackgroundBlur()

    // Camera off: keep the stream ALIVE but send BLACK frames, so the peer sees a black screen instead of a
    // frozen last frame (Zoom-style). A cached black buffer + true black via CoreImage, format-agnostic.
    var blackout = false
    private var blackPB: CVPixelBuffer?
    private let ciBlack = CIContext(options: [.cacheIntermediates: false])
    private func blackFrame(like pb: CVPixelBuffer) -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if blackPB == nil || CVPixelBufferGetWidth(blackPB!) != w || CVPixelBufferGetHeight(blackPB!) != h {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, CVPixelBufferGetPixelFormatType(pb),
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out)
            if let b = out { ciBlack.render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)), to: b) }
            blackPB = out
        }
        return blackPB ?? pb
    }

    func stop() { encoder = nil }
    func stopAll() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if blackout {
            encoder?.encode(pixelBuffer: blackFrame(like: pb), pts: pts)
        } else if blurBackground {
            encoder?.encode(pixelBuffer: blur.process(pb), pts: pts)
        } else {
            encoder?.encode(pixelBuffer: pb, pts: pts)
        }
    }
}

// MARK: - Frame scaler (adaptive resolution)
// Downscale a camera pixel buffer to the ladder's target size before encoding, reusing a pool. CoreImage on
// the GPU; mirrors the BackgroundBlur pool pattern. Identity when src == dst so the top rung costs nothing.
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

// MARK: - H.264 Encoder

class H264Encoder {
    private var session: VTCompressionSession?
    var onFrame: ((Data, Bool) -> Void)?

    // Adaptive-resolution ladder: pick the frame size from the AIMD's curBitrate. A weak link drops to a
    // small SHARP picture instead of a big blocky one; a strong Wi-Fi link climbs to 720p. Recreating the
    // session on a step forces one IDR + new SPS, which the decoder already handles (SPS change -> re-init).
    // The ladder is keyed to target HEIGHT only; the WIDTH is computed from the camera frame's real aspect at
    // encode time, so the scale is always UNIFORM and the picture is NEVER squished — whatever the camera's
    // aspect (16:9 FaceTime HD, 4:3 webcam, anything). This is why the "stretched picture" can't come back.
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
        // Mesh/radio: cap height so keyframes stay under the 17850B NAL ceiling.
        let cap: Int32 = meshMode ? 240 : 4096
        return H264Encoder.ladder.first { $0.minBitrate <= curBitrate && $0.h <= cap } ?? H264Encoder.ladder.last!
    }
    // Dimensions come from the first captured frame (rotation/preset aware) —
    // hardcoded values would make VideoToolbox scale-squash rotated buffers
    private var width: Int32 = 0
    private var height: Int32 = 0

    func setup(width: Int32, height: Int32) -> Bool {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        // Low-latency rate control: the RTC-tuned rate controller (fast reaction, no big VBV buffer) — better
        // quality-under-motion than the default, and the gate for LTR/temporal-SVC later. iOS 14.5+ (target 15).
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue]
        let r = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, buf in
                guard status == noErr, let buf = buf else { return }
                Unmanaged<H264Encoder>.fromOpaque(ref!).takeUnretainedValue().process(buf)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s
        )
        guard r == noErr, let s = s else { return false }
        session = s
        // Ceiling the AIMD climbs to — FIXED (not tied to the encoded size), so curBitrate can rise high enough
        // to unlock the 720p rung on good Wi-Fi; the ladder picks the frame size from curBitrate. Mesh stays
        // capped so keyframes fit the NAL ceiling.
        maxBitrate = meshMode ? H264Encoder.meshBitrate : 900_000
        if curBitrate == 0 { curBitrate = min(maxBitrate, 900_000) }   // first call: start ~540p, then climb
        curBitrate = min(curBitrate, maxBitrate)                       // resolution step: PRESERVE the rate
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // High profile adds the 8x8 transform + better intra prediction: ~5-10% better quality-per-bit than
        // Main at the same bitrate, and every Apple decoder supports it. CABAC + no B-frames (no latency).
        // Verified accepted in a standalone VideoToolbox harness.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel as CFString)
        // Hard data-rate cap on TOP of AverageBitRate: clamps keyframe/scene-cut bursts that would
        // overflow the UDP link and cause loss -> macroblocking. [bytes, seconds] pairs.
        let capBytes = (curBitrate * 5 / 4) / 8   // ~1.25x avg per second
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [capBytes, 1] as CFArray)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 24 as CFNumber)  // rate controller allocates bits correctly
        // Rare keyframes: an I-frame is ~5-10x a P-frame, so one every 0.5s was burning the budget on
        // I-frames and starving P-frames of detail. Recovery is PLI-driven (peer requests an IDR on
        // loss/join), so a long interval is safe AND frees bits for quality. Harness: 1 IDR / 60 frames.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 150 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 5.0 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    private func process(_ sb: CMSampleBuffer) {
        // UDP is lossy and receivers can join mid-stream, so SPS/PPS must be
        // re-sent with every keyframe, not once per session
        var isKeyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFDictionary.self)
            isKeyframe = !CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        }
        // Extract SPS/PPS from formatDescription and send FIRST
        if isKeyframe, let fmtDesc = CMSampleBufferGetFormatDescription(sb) {
            // SPS
            var spsSize = 0
            var spsPtr: UnsafePointer<UInt8>? = nil
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmtDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let sp = spsPtr, spsSize > 0 {
                var spsData = Data([0, 0, 0, 1])
                spsData.append(Data(bytes: sp, count: spsSize))
                emit(spsData, key: true)
            }
            // PPS
            var ppsSize = 0
            var ppsPtr: UnsafePointer<UInt8>? = nil
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmtDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pp = ppsPtr, ppsSize > 0 {
                var ppsData = Data([0, 0, 0, 1])
                ppsData.append(Data(bytes: pp, count: ppsSize))
                emit(ppsData, key: true)
            }
        }

        // Extract and send NAL units from the compressed data
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
            emit(d, key: false)
            off += 4 + Int(nl)
        }
    }

    // Set by a peer Picture-Loss-Indication (0xFC): force the next frame to IDR
    // MARK: mesh profile — mirrors desktop/TriNetVideo/VideoEncoder.swift.
    // The bridge addresses fragments with a one-byte index carrying <=70B each,
    // so max_nal_size = 255*70 = 17850 B (specs/video_bridge.t27): an I-frame
    // above that is UNDELIVERABLE at any bitrate, not merely ugly.
    static let meshMaxNAL = 17_850
    static let meshBitrate = 150_000
    private(set) var oversizedNALs = 0
    var meshMode = false { didSet { applyCeiling() } }

    private func applyCeiling() {
        guard let s = session else { return }
        maxBitrate = meshMode ? H264Encoder.meshBitrate : 900_000
        curBitrate = min(curBitrate, maxBitrate)
        bitrateKbps = curBitrate / 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        NSLog("TRINET: mesh mode \(meshMode ? "ON" : "off") - cap \(maxBitrate / 1000) kbps")
    }

    // Every NAL leaves through here so the ceiling is enforced in ONE place.
    private func emit(_ d: Data, key: Bool) {
        if meshMode && d.count > H264Encoder.meshMaxNAL {
            oversizedNALs += 1
            if oversizedNALs <= 3 {
                NSLog("TRINET: NAL \(d.count)B over mesh ceiling - undeliverable, backing off")
            }
            nudgeBitrate(down: true)
        }
        onFrame?(d, key)
    }

    private var forceKeyframeNext = false
    func forceKeyframe() { forceKeyframeNext = true }

    // Adaptive bitrate (PLI-driven), mirrors the macOS encoder.
    private var maxBitrate = 900_000
    private var curBitrate = 0   // 0 = uninitialized; setup() seeds it (~540p worth) on the first frame
    private(set) var bitrateKbps = 0
    var activeHeight: Int32 { height }   // current adaptive send resolution (ladder rung), for the in-call badge
    // AIMD, tuned on hardware (see specs/video_bridge.t27 dead-zone note).
    // Multiplicative decrease recovers fast; additive increase seeks the ceiling
    // without oscillating. Matches the Mac encoder.
    func setMaxBitrate(_ bps: Int) {   // group: split the uplink across peers
        maxBitrate = max(80_000, bps)
        curBitrate = min(curBitrate, maxBitrate)
        if let s = session {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        }
        bitrateKbps = curBitrate / 1000
    }

    // Escalating additive increase (slow-start style, as in TCP/GCC probing): every consecutive clean tick
    // DOUBLES the climb step (8k -> 16k -> 32k -> 64k cap), any loss resets it — reaches the 720p rung in a
    // few ticks on a clean link instead of ~100s of flat +8k, while still backing off instantly on loss.
    private var climbStep = 8_000
    func nudgeBitrate(down: Bool) {
        guard let s = session, maxBitrate > 0 else { return }
        let floor = 80_000   // absolute, so the resolution ladder can reach its small rungs on a weak link
        if down {
            climbStep = 8_000
            curBitrate = max(floor, Int(Double(curBitrate) * 0.92))
        } else {
            curBitrate = min(maxBitrate, curBitrate + climbStep)
            climbStep = min(64_000, climbStep * 2)
        }
        bitrateKbps = curBitrate / 1000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: curBitrate as CFNumber)
        let cap = (curBitrate * 5 / 4) / 8
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [cap, 1] as CFArray)
    }

    func encode(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        encode(pixelBuffer: pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
    }

    func encode(pixelBuffer pb: CVPixelBuffer, pts: CMTime) {
        if curBitrate == 0 { curBitrate = meshMode ? H264Encoder.meshBitrate : 900_000 }  // seed before the ladder reads it
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
            guard setup(width: wantW, height: wantH) else { return }
            NSLog("TRINET: encoder resolution \(wantW)x\(wantH) @ \(curBitrate/1000)kbps")
            forceKeyframeNext = true   // a fresh session must lead with an IDR + new SPS for the peer
        }
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(s, imageBuffer: frame, presentationTimeStamp: pts, duration: .invalid, frameProperties: props, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
}

// MARK: - H.264 Decoder

class H264Decoder: ObservableObject {
    @Published var frameCount: Int = 0
    private(set) var decodedHeight: Int32 = 0   // resolution of the frames we're RECEIVING from the peer
    @Published var currentFrame: CVImageBuffer?

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var fedCount = 0
    var cbErrCount = 0
    private var decodeErrCount = 0
    // After a session (re)start or decode failure, P-frames reference an IDR
    // we never saw — skip them and ask the sender for a keyframe until an IDR
    // arrives, rather than decoding garbage.
    var awaitingIDR = true
    private var lastPLI = Date.distantPast
    var onKeyframeNeeded: (() -> Void)?

    func feed(_ nalUnit: Data) {
        guard nalUnit.count > 4 else { return }
        let nalType = nalUnit[4] & 0x1F
        fedCount += 1
        if fedCount <= 10 || fedCount % 500 == 0 {
            NSLog("TRINET: NAL #\(fedCount) type=\(nalType) \(nalUnit.count)B session=\(session != nil) awaitIDR=\(awaitingIDR)")
        }
        switch nalType {
        // CMVideoFormatDescriptionCreateFromH264ParameterSets expects raw
        // parameter sets — strip the 4-byte Annex-B start code.
        // A changed SPS/PPS (peer restarted with new dimensions) must
        // re-create the session, or old-format frames decode as garbage.
        case 7:
            let s = nalUnit.subdata(in: 4..<nalUnit.count)
            if s != sps { sps = s; formatDesc = nil; session = nil; awaitingIDR = true }
            tryInitSession()
        case 8:
            let p = nalUnit.subdata(in: 4..<nalUnit.count)
            if p != pps { pps = p; formatDesc = nil; session = nil; awaitingIDR = true }
            tryInitSession()
        case 5: // IDR — resync, but only if session is ready
            guard session != nil, formatDesc != nil else {
                requestKeyframe()
                return
            }
            awaitingIDR = false
            decodeFrame(nalUnit)
        case 1 where awaitingIDR:
            requestKeyframe()
        default: decodeFrame(nalUnit)
        }
    }

    // Ask the sender for an IDR, throttled to ~3x/sec
    func requestKeyframe() {
        let now = Date()
        if now.timeIntervalSince(lastPLI) > 0.33 {
            lastPLI = now
            onKeyframeNeeded?()
        }
    }

    private func tryInitSession() {
        guard let sps = sps, let pps = pps, formatDesc == nil else { return }
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                let paramPointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                ]
                let paramSizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: paramPointers, parameterSetSizes: paramSizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc
                )
                NSLog("TRINET: CMVideoFormatDescriptionCreate status=\(status)")
                guard status == noErr, let desc = desc else { return }
                self.formatDesc = desc
                self.decodedHeight = CMVideoFormatDescriptionGetDimensions(desc).height   // received resolution, for the badge
                let refCon = Unmanaged.passUnretained(self).toOpaque()
                var callback = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                        if status != noErr {
                            let d = Unmanaged<H264Decoder>.fromOpaque(refCon!).takeUnretainedValue()
                            d.cbErrCount += 1
                            if d.cbErrCount <= 5 || d.cbErrCount % 500 == 0 {
                                NSLog("TRINET: decode callback status=\(status) (#\(d.cbErrCount))")
                            }
                            // A single dropped P-frame is normal on lossy UDP; the
                            // 0.5s keyframe cadence resyncs on its own. Forcing an
                            // IDR per failure caused a PLI storm.
                        }
                        guard status == noErr, let imageBuffer = imageBuffer else { return }
                        let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon!).takeUnretainedValue()
                        DispatchQueue.main.async {
                            if decoder.frameCount == 0 { NSLog("TRINET: FIRST FRAME DECODED!") }
                            decoder.currentFrame = imageBuffer
                            decoder.frameCount += 1
                        }
                    },
                    decompressionOutputRefCon: refCon
                )
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
                ]
                var newSession: VTDecompressionSession?
                let vtStatus = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: desc,
                    decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: &callback, decompressionSessionOut: &newSession
                )
                NSLog("TRINET: VTDecompressionSessionCreate status=\(vtStatus) session=\(newSession != nil)")
                self.session = newSession
            }
        }
    }

    private func decodeFrame(_ nalUnit: Data) {
        guard let session = session, let formatDesc = formatDesc else { return }
        var avccData = Data()
        let nalData = nalUnit.subdata(in: 4..<nalUnit.count)
        var nalLength = UInt32(nalData.count).bigEndian
        avccData.append(Data(bytes: &nalLength, count: 4))
        avccData.append(nalData)
        var blockBuffer: CMBlockBuffer?
        let dataCount = avccData.count
        avccData.withUnsafeMutableBytes { rawBuf in
            let ptr = rawBuf.bindMemory(to: Int8.self).baseAddress!
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataCount,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: dataCount, flags: 0, blockBufferOut: &blockBuffer
            )
            if let bb = blockBuffer {
                CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: bb, offsetIntoDestination: 0, dataLength: dataCount)
            }
        }
        guard let bb = blockBuffer else { return }
        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(), decodeTimeStamp: CMTime())
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: bb, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        )
        guard let sb = sampleBuffer else { return }
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if st != noErr {
            decodeErrCount += 1
            if decodeErrCount <= 5 || decodeErrCount % 500 == 0 {
                NSLog("TRINET: DecodeFrame status=\(st) (#\(decodeErrCount))")
            }
        }
    }
}

// MARK: - Network Transport (BSD UDP socket)
// NWListener delivered ZERO datagrams on both macOS and iOS (it spawned a new
// flow per datagram and receiveMessage never fired) — a plain AF_INET socket
// bound to :recvPort receives and sends reliably, and the peer sees our
// source port = recvPort (symmetric UDP).

class BSDTransport {
    private var fd: Int32 = -1
    private var peer = sockaddr_in()
    private var peerHostStr = ""              // the connected peer's IP, for drop diagnostics
    private var dropByIP: [String: Int] = [:] // undecryptable datagrams per source IP
    private var running = false
    private let rxQueue = DispatchQueue(label: "mesh.rx", qos: .userInitiated)
    // Separate queue: rxQueue is parked forever in a blocking recv(), so a
    // timer scheduled on it would never fire.
    private let hsQueue = DispatchQueue(label: "mesh.hs", qos: .userInitiated)
    var onData: ((Data) -> Void)?
    var isReady = false
    // Conference (group) mode: >1 peers share ONE static conference key (HKDF of the PSK), full-mesh,
    // NO pairwise handshake -- mirrors the Mac (MeshTransport). recvfrom routes by SOURCE IP so each
    // sender decodes into its own tile. Kept ISOLATED from the working 1-1 path (own key, own reassembly).
    private var groupMode = false
    private var peers: [sockaddr_in] = []
    var onDataFrom: ((Data, String) -> Void)?
    private static let confKey = SymmetricKey(
        data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: SHA256.hash(data: Data("tri-net-psk-v1".utf8))),
            salt: Data("trios-mesh/v1/conference".utf8),
            info: Data("group-aead".utf8), outputByteCount: 32))
    // per-(source, seq) fragment buffers -- group only, so two phones' same-seq NALs never collide
    private var groupFrag: [String: (parts: [Data?], have: Int)] = [:]
    private var groupFec: [String: (xor: [UInt8], lastLen: Int, total: Int)] = [:]   // per-source parity (group FEC)

    // MARK: link feedback (see specs/video_bridge.t27)
    //
    // The node knows its load exactly; we do not. Without this the encoder finds
    // the link's capacity by overrunning it and waiting for the FAR end's
    // decoder to complain (PLI) — which only happens after frames are already
    // broken, and whose absence makes us climb until we break them again.
    //
    // `advice` is the node's VERDICT and the only thing to act on: the
    // thresholds live in the spec and nowhere else, because t27c cannot generate
    // Swift and a second copy here would drift until the node and the encoder
    // disagreed about "full". The numbers are for the log.
    //
    // Plaintext by design: local telemetry from our own node, no payload bytes,
    // nothing about content. Never put content here.
    var onLinkFeedback: ((_ advice: UInt8, _ utilPct: Int, _ dropPct: Int, _ rate: Int) -> Void)?
    private var fbFd: Int32 = -1
    // A fresh report proves a NODE is relaying for us; used only to route audio.
    private var lastFeedbackAt: Date?
    private static let audioPort: UInt16 = 7002
    private var expressTx = 0
    private var expressErrs = 0
    private let fbQueue = DispatchQueue(label: "mesh.fb", qos: .utility)
    private static let feedbackPort: UInt16 = 7003
    private static let feedbackType: UInt8 = 10
    private static let feedbackLen = 6

    private func startFeedbackListener() {
        stopFeedbackListener()
        fbFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fbFd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fbFd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = BSDTransport.feedbackPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fbFd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            // Not fatal: a direct peer-to-peer call has no node to report, so
            // silence here is normal. Say so rather than looking broken.
            NSLog("TRINET: link feedback port busy — running without node telemetry")
            close(fbFd); fbFd = -1
            return
        }
        let fd = fbFd
        fbQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 32)
            while true {
                guard let self = self, self.fbFd == fd else { break }
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                guard n >= BSDTransport.feedbackLen,
                      buf[0] == BSDTransport.feedbackType else { continue }
                let util = Int(buf[1]), drop = Int(buf[2])
                let rate = Int(buf[3]) | (Int(buf[4]) << 8)
                let advice = buf[5]
                self.lastFeedbackAt = Date()
                DispatchQueue.main.async { self.onLinkFeedback?(advice, util, drop, rate) }
            }
        }
    }

    private func stopFeedbackListener() {
        if fbFd >= 0 { close(fbFd); fbFd = -1 }
    }

    func connect(host: String, port: UInt16, recvPort: UInt16) {
        disconnect()
        startFeedbackListener()

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            NSLog("TRINET: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = recvPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            NSLog("TRINET: bind(:\(recvPort)) failed: \(String(cString: strerror(errno)))")
            close(fd); fd = -1
            return
        }

        peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = port.bigEndian
        peer.sin_addr.s_addr = inet_addr(host)
        // inet_addr can't parse IPv6/garbage — it returns INADDR_NONE, which as an address is the broadcast
        // 255.255.255.255. Fail LOUD instead of silently spraying the whole subnet.
        guard host.firstIndex(of: ":") == nil, peer.sin_addr.s_addr != INADDR_NONE else {
            NSLog("TRINET: connect() rejected non-IPv4 host '\(host)' (IPv6/garbage) — not dialing")
            close(fd); fd = -1; return
        }
        peerHostStr = host; dropByIP.removeAll()

        running = true
        isReady = true
        NSLog("TRINET: BSD transport up — listen :\(recvPort), peer \(host):\(port)")

        // Drive the forward-secret handshake until a session is established
        let timer = DispatchSource.makeTimerSource(queue: hsQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.crypto.established { self.handshakeTimer?.cancel(); self.handshakeTimer = nil; return }
            self.rawSendWire(self.crypto.handshakePacket())
        }
        handshakeTimer = timer
        timer.resume()

        startRx(fd)
    }

    // Group / conference call: full-mesh to 2-4 peers under the shared conference key, no handshake.
    // Mac's connectGroup mirrored. Two iPhones + a Mac = a real 3-way group.
    func connectGroup(hosts: [String], port: UInt16, recvPort: UInt16) {
        disconnect()
        groupMode = true
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { NSLog("TRINET: group socket() failed"); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = recvPort.bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
            Darwin.bind(fd, s, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { NSLog("TRINET: group bind(:\(recvPort)) failed: \(String(cString: strerror(errno)))"); close(fd); fd = -1; return }
        peers = hosts.map { host in
            var pa = sockaddr_in()
            pa.sin_family = sa_family_t(AF_INET)
            pa.sin_port = port.bigEndian
            pa.sin_addr.s_addr = inet_addr(host)
            return pa
        }
        running = true; isReady = true
        NSLog("TRINET: GROUP transport up — listen :\(recvPort), \(peers.count) peers: \(hosts.joined(separator: ","))")
        startRx(fd)
    }

    // recvfrom-based receive loop shared by 1-1 and group. In group mode datagrams are sealed under the
    // conference key and routed by SOURCE IP (per-source reassembly -> onDataFrom -> that sender's tile).
    private func startRx(_ sock: Int32) {
        rxQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var from = sockaddr_in()
            var count = 0
            while true {
                guard let self = self, self.running else { break }
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { fp in fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                    recvfrom(sock, &buf, buf.count, 0, s, &fromLen) } }
                if n < 0 {
                    // UDP + ICMP gotcha: an unreachable peer's ICMP error (EHOSTDOWN / ECONNREFUSED /
                    // ENETUNREACH / EHOSTUNREACH) surfaces on the NEXT recvfrom. Transient -> keep going,
                    // or one dead group peer ends the whole call. Only a closed socket (EBADF) exits.
                    let e = errno
                    if e == EINTR || e == EHOSTDOWN || e == ECONNREFUSED || e == ENETUNREACH
                        || e == EHOSTUNREACH || e == EAGAIN || e == EWOULDBLOCK { continue }
                    break
                }
                if n == 0 { continue }   // zero-length UDP datagram (no EOF in UDP) -> ignore
                let pkt = Data(bytes: buf, count: n)
                let src = String(cString: inet_ntoa(from.sin_addr))
                if self.groupMode {
                    guard let box = try? ChaChaPoly.SealedBox(combined: pkt),
                          let plain = try? ChaChaPoly.open(box, using: BSDTransport.confKey),
                          let msg = self.groupReassemble(plain, from: src) else { continue }
                    DispatchQueue.main.async { self.onDataFrom?(msg, src) }
                    continue
                }
                if self.crypto.isHandshake(pkt) {
                    self.crypto.consumeHandshake(pkt)
                    self.rawSendWire(self.crypto.handshakePacket())
                    continue
                }
                count += 1
                if count == 1 || count % 200 == 0 { NSLog("TRINET: rx #\(count) \(n)B from \(src)") }
                if let plain = self.crypto.unseal(pkt) {
                    if let msg = self.reassemble(plain) { self.onData?(msg) }
                } else {
                    // Undecryptable: OUR peer (real bug) vs a stray peer blasting :7000 (benign). IP tells apart.
                    self.dropByIP[src, default: 0] += 1
                    let c = self.dropByIP[src]!
                    if c <= 3 || c % 500 == 0 {
                        let who = src == self.peerHostStr ? "OUR PEER — REAL BUG" : "stray peer (ignore)"
                        NSLog("TRINET: DROP undecryptable \(n)B from \(src) [\(who), peer=\(self.peerHostStr)] — \(c) from this IP")
                    }
                }
            }
        }
    }

    // Per-source reassembly for group mode: keyed by "src#seq" so two senders' equal seqs never mix.
    // Handles FEC parity too (group loss resilience) -- one lost fragment per NAL recovers without a keyframe.
    private func groupReassemble(_ d: Data, from src: String) -> Data? {
        // FEC parity [0xFA 0xEC seqLo seqHi total lastLenLo lastLenHi] + xor(maxPayload)
        if d.count > 7, d[0] == 0xFA, d[1] == 0xEC {
            let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
            let total = Int(d[4]); let lastLen = Int(d[5]) | (Int(d[6]) << 8)
            guard total >= 2 else { return nil }
            groupFec["\(src)#\(seq)"] = (Array(d[7...]), lastLen, total)
            return groupTryFEC(src, seq)
        }
        if d.count > 1, d[0] == 0xFA, d[1] != 0xFB { return nil }   // other control
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4]); let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        let key = "\(src)#\(seq)"
        var st = groupFrag[key] ?? (parts: [Data?](repeating: nil, count: total), have: 0)
        if st.parts.count != total { st = (parts: [Data?](repeating: nil, count: total), have: 0) }
        if st.parts[idx] == nil { st.parts[idx] = d.subdata(in: 6..<d.count); st.have += 1 }
        groupFrag[key] = st
        if st.have == total {
            groupFrag[key] = nil; groupFec[key] = nil
            if groupFrag.count > 48 { groupFrag.removeAll(); groupFec.removeAll() }   // bound memory
            return st.parts.compactMap { $0 }.reduce(Data(), +)
        }
        return groupTryFEC(src, seq)   // one short? maybe parity can fill it
    }

    // Recover a single missing fragment from parity (mirror of the 1-1 FEC), per source.
    private func groupTryFEC(_ src: String, _ seq: UInt16) -> Data? {
        let key = "\(src)#\(seq)"
        guard let fec = groupFec[key], var st = groupFrag[key],
              st.parts.count == fec.total, st.have == fec.total - 1,
              let miss = st.parts.firstIndex(where: { $0 == nil }) else { return nil }
        var xor = fec.xor
        for p in st.parts where p != nil { let b = [UInt8](p!); for k in 0..<b.count { xor[k] ^= b[k] } }
        let len = (miss == fec.total - 1) ? fec.lastLen : maxPayload
        guard len <= xor.count else { return nil }
        st.parts[miss] = Data(xor[0..<len])
        groupFrag[key] = nil; groupFec[key] = nil
        return st.parts.compactMap { $0 }.reduce(Data(), +)
    }

    // MARK: forward-secret session (see MeshCrypto). Data is sealed under a
    // per-connection ephemeral session key; the static PSK only authenticates
    // the handshake, so a later PSK leak can't decrypt recorded traffic.
    private let crypto = MeshCrypto()
    private var handshakeTimer: DispatchSourceTimer?

    // MARK: application-level fragmentation
    // UDP datagrams are capped (~9KB default on Apple platforms) and anything
    // over the WiFi MTU relies on lossy IP fragmentation, so large NALs
    // (I-frames) are split into [0xFA 0xFB seqLo seqHi idx total]+chunk
    // datagrams and reassembled on receive. Raw NALs always start
    // 00 00 00 01, so the magic prefix is unambiguous.
    private let maxPayload = 1200
    private var fragSeqOut: UInt16 = 0
    // `tick` orders partial groups by arrival so GC can evict the OLDEST rather
    // than everything but the current seq (see reassemble).
    private var fragBufs: [UInt16: (parts: [Data?], have: Int, tick: UInt64)] = [:]
    private var fragTick: UInt64 = 0
    private let fragBufsCap = 24
    // FEC parity per fragment group (XOR over padded cells, last-cell length).
    private var fecBufs: [UInt16: (xor: [UInt8], lastLen: Int, total: Int)] = [:]
    // Send parity only when the peer is known to understand it (see send()).
    // Receiving parity is always safe, so only the send side is gated.
    private let fecEnabled = true

    func send(_ data: Data) {
        guard fd >= 0 else { return }
        if data.count <= maxPayload {
            rawSend(data)
            return
        }
        let total = (data.count + maxPayload - 1) / maxPayload
        guard total <= 255 else { return }
        fragSeqOut &+= 1
        for i in 0..<total {
            let start = i * maxPayload
            let end = min(start + maxPayload, data.count)
            var pkt = Data([0xFA, 0xFB, UInt8(fragSeqOut & 0xFF), UInt8(fragSeqOut >> 8), UInt8(i), UInt8(total)])
            pkt.append(data.subdata(in: start..<end))
            rawSend(pkt)
        }
        // Forward error correction: one XOR-parity packet over all fragments so
        // the peer can rebuild ANY single lost fragment without a keyframe.
        //
        // OFF until BOTH ends run >= v0.9 — a pre-v0.9 receiver hands any unknown
        // magic straight to its H.264 decoder (see MeshTransport.send), which
        // caused a PLI/keyframe storm and frozen video.
        if fecEnabled, total >= 2 {
            var xor = [UInt8](repeating: 0, count: maxPayload)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<total {
                    let start = i * maxPayload
                    let end = min(start + maxPayload, data.count)
                    for k in 0..<(end - start) { xor[k] ^= raw[start + k] }
                }
            }
            let lastLen = data.count - (total - 1) * maxPayload
            var parity = Data([0xFA, 0xEC, UInt8(fragSeqOut & 0xFF), UInt8(fragSeqOut >> 8),
                               UInt8(total), UInt8(lastLen & 0xFF), UInt8(lastLen >> 8)])
            parity.append(contentsOf: xor)
            rawSend(parity)
        }
    }

    // Encrypt a fragment under the session key, then wire it out
    private func rawSend(_ data: Data) {
        guard fd >= 0 else { return }
        if groupMode {
            guard let wire = try? ChaChaPoly.seal(data, using: BSDTransport.confKey).combined else { return }
            for i in peers.indices {
                _ = wire.withUnsafeBytes { raw in withUnsafePointer(to: &peers[i]) { pp in
                    pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                        sendto(fd, raw.baseAddress, wire.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
            }
            return
        }
        guard let wire = crypto.seal(data) else { return } // 1-1: drop until session up
        rawSendWire(wire)
    }

    /// Audio to the node's express ingress (AUDIO_IN_PORT 7002) -- its own
    /// budget, never paced, no parity duplicate. Mirrors the Mac transport.
    /// Falls back to the normal path when no node report is fresh (direct call).
    func sendAudio(_ data: Data) {
        let viaNode = lastFeedbackAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        if !viaNode {
            send(data)
            return
        }
        guard fd >= 0, let wire = crypto.seal(data) else { return }
        var addr = peer
        addr.sin_port = BSDTransport.audioPort.bigEndian
        // Never fail silently in an audio path: a discarded sendto result made
        // vanishing audio indistinguishable from working audio -- the tx
        // counter counts hand-offs, not deliveries.
        let sent = wire.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    sendto(fd, raw.baseAddress, wire.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            expressErrs += 1
            if expressErrs % 100 == 1 {
                NSLog("%@", "TRINET: audio express sendto FAILED: \(String(cString: strerror(errno))) (#\(expressErrs))")
            }
        } else {
            expressTx += 1
            if expressTx == 1 { NSLog("%@", "TRINET: audio express up -> :7002 (\(sent)B)") }
            if expressTx % 2500 == 0 { NSLog("%@", "TRINET: audio express #\(expressTx)") }
        }
    }

    // Send bytes verbatim (handshake packets are already self-authenticating)
    private func rawSendWire(_ wire: Data) {
        guard fd >= 0 else { return }
        var p = peer
        _ = wire.withUnsafeBytes { raw in
            withUnsafePointer(to: &p) { pp in
                pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                    sendto(fd, raw.baseAddress, wire.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // Returns a complete NAL when the datagram finishes one, nil otherwise.
    // Multi-slot: chunks of several NALs may interleave (video + a peer
    // restart, or future multi-stream), so partial buffers are keyed by seq.
    private func reassemble(_ d: Data) -> Data? {
        // FEC parity packet: store it, then try to recover a single lost fragment.
        if d.count > 7, d[0] == 0xFA, d[1] == 0xEC {
            let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
            let total = Int(d[4])
            let lastLen = Int(d[5]) | (Int(d[6]) << 8)
            guard total >= 2 else { return nil }
            fecBufs[seq] = (Array(d[7...]), lastLen, total)
            return tryFEC(seq)
        }
        // 0xFA is reserved for this framing layer (raw NALs start 00 00 00 01 and
        // control packets use 0xFB..0xFE). Drop an unknown 0xFA subtype instead of
        // returning it as a finished NAL — handing unknown magic to the decoder is
        // exactly what made pre-v0.9 peers storm on FEC parity.
        if d.count > 1, d[0] == 0xFA, d[1] != 0xFB { return nil }
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4])
        let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        var entry = fragBufs[seq] ?? (Array(repeating: nil, count: total), 0, 0)
        if entry.parts.count != total { entry = (Array(repeating: nil, count: total), 0, 0) }
        if entry.parts[idx] == nil {
            entry.parts[idx] = d.subdata(in: 6..<d.count)
            entry.have += 1
        }
        if entry.have == total {
            fragBufs.removeValue(forKey: seq); fecBufs.removeValue(forKey: seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragTick &+= 1
        entry.tick = fragTick
        fragBufs[seq] = entry
        if let recovered = tryFEC(seq) { return recovered }  // parity may already be here
        // GC by RECENCY, never "keep only the current seq" — audio and video
        // fragments interleave, so wiping every other partial group silently
        // destroyed in-flight audio groups once video filled the table.
        if fragBufs.count > fragBufsCap {
            let keep = Set(fragBufs.sorted { $0.value.tick > $1.value.tick }
                                   .prefix(fragBufsCap).map { $0.key })
            fragBufs = fragBufs.filter { keep.contains($0.key) }
            fecBufs = fecBufs.filter { keep.contains($0.key) }
        }
        return nil
    }

    // XOR-reconstruct exactly one missing fragment from parity + the rest.
    private func tryFEC(_ seq: UInt16) -> Data? {
        guard let fec = fecBufs[seq], var entry = fragBufs[seq],
              entry.parts.count == fec.total else { return nil }
        let missing = (0..<fec.total).filter { entry.parts[$0] == nil }
        guard missing.count == 1 else { return nil }
        let j = missing[0]
        var rec = fec.xor
        for i in 0..<fec.total where i != j {
            guard let part = entry.parts[i] else { return nil }
            part.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for k in 0..<part.count { rec[k] ^= raw[k] }
            }
        }
        let len = (j == fec.total - 1) ? fec.lastLen : maxPayload
        guard len >= 0, len <= rec.count else { return nil }
        entry.parts[j] = Data(rec.prefix(len))
        entry.have += 1
        if entry.have == fec.total {
            fragBufs.removeValue(forKey: seq); fecBufs.removeValue(forKey: seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragBufs[seq] = entry
        return nil
    }

    func disconnect() {
        running = false
        handshakeTimer?.cancel(); handshakeTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
        isReady = false
        groupMode = false; peers = []; groupFrag.removeAll(); groupFec.removeAll()
        stopFeedbackListener()
    }

    deinit { disconnect() }
}

// MARK: - Camera Preview (UIView)

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.session = session
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var rotCoord: Any?                 // AVCaptureDevice.RotationCoordinator (iOS 17+)
    private var rotObs: NSKeyValueObservation?
    var session: AVCaptureSession? {
        didSet { previewLayer.session = session; setupPreviewRotation() }
    }

    // Keep the SELF-PREVIEW upright as the phone turns to landscape. This is the PREVIEW connection (what you
    // see locally); the CAPTURE connection stays upright separately so the peer always reads a level picture.
    // A RotationCoordinator bound to THIS preview layer is gravity-aware, and KVO updates the angle live.
    private func setupPreviewRotation() {
        rotObs = nil; rotCoord = nil
        guard #available(iOS 17.0, *),
              let device = (session?.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first)?.device else { return }
        let coord = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotCoord = coord
        applyPreviewAngle(coord)
        rotObs = coord.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
            DispatchQueue.main.async { self?.applyPreviewAngle(c) }
        }
    }
    @available(iOS 17.0, *)
    private func applyPreviewAngle(_ coord: AVCaptureDevice.RotationCoordinator) {
        guard let conn = previewLayer.connection else { return }
        let angle = coord.videoRotationAngleForHorizonLevelPreview
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    }
}

// MARK: - Remote Video Display (UIView from CVImageBuffer)

struct RemoteVideoDisplay: UIViewRepresentable {
    let imageBuffer: CVImageBuffer
    let frameId: Int

    func makeUIView(context: Context) -> VideoDisplayView { VideoDisplayView() }
    func updateUIView(_ uiView: VideoDisplayView, context: Context) {
        uiView.update(imageBuffer)
    }
}

class VideoDisplayView: UIView {
    // One shared CIContext — creating one per frame re-initializes Metal
    // 30x/sec and stalls the main thread
    private static let ciContext = CIContext()

    func update(_ buffer: CVImageBuffer) {
        let ci = CIImage(cvImageBuffer: buffer)
        guard let cg = VideoDisplayView.ciContext.createCGImage(ci, from: ci.extent) else { return }
        // Contents go on the view's own layer — a recreated sublayer sized
        // to pre-layout zero bounds renders nothing
        layer.contents = cg
        layer.contentsGravity = .resizeAspect
    }
}

// MARK: - Audio (capture -> 16kHz mono int16 PCM over UDP -> playback)
// Wire format: [0xFD 0xAD] + little-endian Int16 samples (~20ms per packet,
// fits one datagram — never fragmented). Voice processing gives echo
// cancellation where the platform supports it.

final class AudioController {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 16000, channels: 1, interleaved: false)!
    var onPacket: ((Data) -> Void)?
    // Live audio levels (0...1) for the TX/RX meters.
    var onTxLevel: ((Float) -> Void)?
    var onRxLevel: ((Float) -> Void)?
    // Raw incoming / outgoing 16k Int16 PCM (magic stripped) — for the recorder.
    var onRxPCM: ((Data) -> Void)?
    var onTxPCM: ((Data) -> Void)?
    // Opus: ~65B per 20ms instead of 642B (256 -> ~25 kbps). RECEIVE is always on;
    // SENDING waits until both ends run this build — a pre-Opus peer feeds unknown
    // magic straight to its H.264 decoder (how FEC parity froze video).
    static let opusEnabled = true
    private let opus = OpusCodec()
    private var started = false
    private var rxCount = 0
    private var txCount = 0
    private var opusTx = 0
    private var pcmTx = 0
    // Leftover samples between taps, so no frame is ever short (see the tap).
    private var txAccum = [Float]()
    private var vpEnabled = true
    private var observers: [NSObjectProtocol] = []
    private var converterInFormat: AVAudioFormat?

    // RMS -> perceptual 0...1 (sqrt gives a livelier meter than raw RMS)
    static func level(_ sumSq: Float, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        let rms = (sumSq / Float(n)).squareRoot()
        return min(1, rms * 3)
    }

    // AVAudioEngine STOPS and drops every installed tap when the audio graph is
    // reconfigured (route settling into .defaultToSpeaker, voice processing
    // re-tuning the I/O, an interruption, media services resetting). Nothing here
    // observed that, so the mic tap died a couple of buffers after the call
    // started and never came back — audio silently gone for the whole call while
    // video kept flowing. Rebuild the graph whenever that happens.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            NSLog("TRINET: audio engine configuration change -> rebuild")
            self?.rebuild()
        })
        #if os(iOS)
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                NSLog("TRINET: audio interruption ended -> rebuild")
                self?.rebuild()
            } else {
                NSLog("TRINET: audio interruption began")
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            NSLog("TRINET: media services reset -> rebuild")
            self?.rebuild()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.started, !self.engine.isRunning else { return }
            NSLog("TRINET: route change left engine stopped -> rebuild")
            self.rebuild()
        })
        #endif
    }

    // Tear the capture graph down and stand it back up. Safe to call repeatedly.
    private func rebuild() {
        guard started else { return }
        started = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        let sess = AVAudioSession.sharedInstance()
        try? sess.setCategory(.playAndRecord, mode: .videoChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
        try? sess.setActive(true)
        #endif
        if !buildAndStart(voiceProcessing: vpEnabled) {
            engine.reset()
            _ = buildAndStart(voiceProcessing: false)
        }
        rxCount = 0   // re-arm the jitter pre-roll
        NSLog("TRINET: audio rebuilt (running=\(engine.isRunning))")
    }

    func start() {
        guard !started else { return }
        installObservers()
        #if os(iOS)
        let sess = AVAudioSession.sharedInstance()
        try? sess.setCategory(.playAndRecord, mode: .videoChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
        try? sess.setActive(true)
        // Mic capture stays silent (no tap callbacks) without record
        // permission — request it, then (re)start once granted
        if sess.recordPermission == .undetermined {
            sess.requestRecordPermission { [weak self] granted in
                NSLog("TRINET: mic permission granted=\(granted)")
                DispatchQueue.main.async { if granted, self?.started == false { self?.start() } }
            }
            return
        } else if sess.recordPermission == .denied {
            NSLog("TRINET: mic permission DENIED — outgoing audio disabled")
        }
        #endif
        // Voice processing (echo cancellation) fuses I/O into one VPIO unit
        // that can fail to init on some devices (err -10875). Try it, and on
        // failure rebuild the graph without it.
        // Opus was proven by harness on macOS and ASSUMED on iOS. Say it out loud.
        NSLog("TRINET: opus codec \(opus == nil ? "UNAVAILABLE (falling back to raw PCM both ways)" : "ready") send=\(AudioController.opusEnabled)")
        if !buildAndStart(voiceProcessing: true) {
            NSLog("TRINET: audio retry without voice processing")
            engine.reset()
            _ = buildAndStart(voiceProcessing: false)
        }
    }

    private func buildAndStart(voiceProcessing: Bool) -> Bool {
        // Idempotent: rebuild() re-enters here after a configuration change.
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)
        vpEnabled = voiceProcessing

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: wireFormat)

        NSLog("TRINET: audio start vp=\(voiceProcessing)")
        // format: nil -> the framework uses the bus's CURRENT format. A snapshot
        // from outputFormat(forBus:) is STALE: the Remote I/O -> voice-processing
        // I/O switch is not finished when setVoiceProcessingEnabled returns, so
        // the hardware re-negotiates format ~200ms after start. Pinning the tap to
        // the pre-start snapshot is exactly why it died after ~2 buffers. This
        // race cannot be won by ordering — only by reading the live format.
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self else { return }
            // Rebuild the converter whenever the live input format changes.
            if self.converterInFormat != buf.format {
                self.converter = AVAudioConverter(from: buf.format, to: self.wireFormat)
                self.converterInFormat = buf.format
                NSLog("TRINET: audio tap format -> \(Int(buf.format.sampleRate))Hz ch=\(buf.format.channelCount)")
            }
            guard let conv = self.converter else { return }
            guard let out = AVAudioPCMBuffer(pcmFormat: self.wireFormat, frameCapacity: 4096) else { return }
            var served = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true
                status.pointee = .haveData
                return buf
            }
            guard out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
            let n = Int(out.frameLength)
            var sumSq: Float = 0
            for i in 0..<n { let f = max(-1.0, min(1.0, ch[i])); sumSq += f * f }
            self.onTxLevel?(Self.level(sumSq, n))
            // Slice into 20ms packets (320 samples @16k -> 642B). iOS hands us
            // ~100ms buffers, and a single 3200B audio datagram exceeds maxPayload,
            // so it used to be FRAGMENTED and then starved by the video-dominated
            // reassembly table — audio died while video kept flowing.
            // Emit ONLY whole 20ms frames. The tap's buffer is not a multiple of
            // 320, so slicing it directly left a short remainder every time, and
            // Opus cannot encode a partial frame — it declined those and the code
            // silently fell back to raw PCM. Measured on a live call:
            // [opus 2636 / pcm 364] — 12% of packets but 234KB of 405KB, so the
            // fallback ate MORE bandwidth than all the Opus. Carry the remainder.
            for i in 0..<n { self.txAccum.append(max(-1.0, min(1.0, ch[i]))) }
            while self.txAccum.count >= 320 {
                var raw = Data(capacity: 320 * 2)
                for f in self.txAccum.prefix(320) {
                    let v = Int16(f * 32767)
                    withUnsafeBytes(of: v.littleEndian) { raw.append(contentsOf: $0) }
                }
                self.txAccum.removeFirst(320)
                // Report what ACTUALLY went out, never the flag. Opus can decline
                // a buffer (the encoder primes before its first packet), and the
                // code then falls back to raw PCM — logging `opus=true` there
                // claimed a 10x saving that never happened.
                var pkt: Data
                var sentOpus = false
                if AudioController.opusEnabled, let frame = self.opus?.encode(raw) {
                    pkt = Data([0xFD, 0xC0]); pkt.append(frame)   // ~65B
                    sentOpus = true
                    self.opusTx += 1
                } else {
                    pkt = Data([0xFD, 0xAD]); pkt.append(raw)     // 642B
                    self.pcmTx += 1
                }
                self.txCount += 1
                if self.txCount <= 2 || self.txCount % 500 == 0 {
                    NSLog("TRINET: audio tx #\(self.txCount) \(pkt.count)B sent=\(sentOpus ? "OPUS" : "pcm") [opus \(self.opusTx) / pcm \(self.pcmTx)]")
                }
                self.onPacket?(pkt)
                if let txpcm = self.onTxPCM { txpcm(raw) }
            }
        }

        do {
            try engine.start()
            // Player starts after a small pre-roll in playPacket (jitter buffer)
            started = true
            return true
        } catch {
            NSLog("TRINET: audio engine start failed (vp=\(voiceProcessing)): \(error)")
            engine.inputNode.removeTap(onBus: 0)
            return false
        }
    }

    // One Opus frame off the wire -> PCM -> normal playback. Always accepted;
    // receiving a better codec is never the risky direction.
    // A silent `return` here dropped EVERY incoming Opus packet with no log, no
    // meter, nothing — indistinguishable from the peer not sending at all. That
    // is precisely how "no audio from the Mac" looked from this side.
    func playOpus(_ frame: Data) {
        guard let codec = opus else {
            opusDecodeFails += 1
            if opusDecodeFails <= 3 { NSLog("TRINET: opus RX dropped — codec unavailable on this device") }
            return
        }
        guard let pcm = codec.decode(frame) else {
            opusDecodeFails += 1
            if opusDecodeFails <= 3 || opusDecodeFails % 200 == 0 {
                NSLog("TRINET: opus decode FAILED (\(frame.count)B) #\(opusDecodeFails) — audio dropped")
            }
            return
        }
        opusRx += 1
        playPacket(pcm, wire: "OPUS \(frame.count)B")
    }
    private var opusDecodeFails = 0
    private var opusRx = 0
    private var pcmRx = 0

    // `wire` says what ACTUALLY arrived: this logs the DECODED size, so Opus and
    // raw both read as 640B and the line could not tell them apart.
    func playPacket(_ d: Data, wire: String? = nil) {
        if wire == nil { pcmRx += 1 }
        guard started else { return }
        let n = d.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let ch = buf.floatChannelData![0]
        var sumSq: Float = 0
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let v = Int16(bitPattern: lo | (hi << 8))
                let f = Float(v) / 32768.0
                ch[i] = f
                sumSq += f * f
            }
        }
        onRxLevel?(Self.level(sumSq, n))
        onRxPCM?(d)
        rxCount += 1
        if rxCount <= 2 || rxCount % 200 == 0 {
            NSLog("TRINET: audio rx #\(rxCount) wire=\(wire ?? "pcm \(d.count)B") [opus \(opusRx) / pcm \(pcmRx)]")
        }
        player.scheduleBuffer(buf, completionHandler: nil)
        // Jitter buffer: begin playback after ~3 packets are queued (~60ms).
        if !player.isPlaying && rxCount >= 3 { player.play() }
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        started = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }
}

// MARK: - Forward-secret session crypto (see desktop/TriNetVideo/MeshCrypto.swift
// for the Mac copy — the two folder targets duplicate shared types, same as
// H264Encoder/VideoEncoder). Mirrors trios-mesh/src/crypto.rs: ephemeral
// X25519 -> HKDF session key -> ChaCha20-Poly1305, with the ephemeral exchange
// authenticated by a PSK (HMAC). Forward secrecy: a later PSK leak can't
// decrypt recorded traffic, because ephemeral private keys are never persisted.
// Wire (handshake): [0x54 0x48] + ephPub(32) + HMAC-SHA256(PSK, ephPub)(32) = 66B
final class MeshCrypto {
    private static let psk = SymmetricKey(data: SHA256.hash(data: Data("tri-net-psk-v1".utf8)))
    private static let hkdfSalt = Data("trios-mesh/v1/session".utf8)
    private static let hkdfInfo = Data("aead-key".utf8)
    static let handshakeMagic: [UInt8] = [0x54, 0x48]

    private let ephPriv = Curve25519.KeyAgreement.PrivateKey()
    private var sessionKey: SymmetricKey?
    private var dropCount = 0

    var established: Bool { sessionKey != nil }

    func handshakePacket() -> Data {
        let pub = ephPriv.publicKey.rawRepresentation
        let mac = HMAC<SHA256>.authenticationCode(for: pub, using: MeshCrypto.psk)
        var d = Data(MeshCrypto.handshakeMagic)
        d.append(pub)
        d.append(Data(mac))
        return d
    }

    func isHandshake(_ d: Data) -> Bool {
        d.count == 66 && d[0] == MeshCrypto.handshakeMagic[0] && d[1] == MeshCrypto.handshakeMagic[1]
    }

    @discardableResult
    func consumeHandshake(_ d: Data) -> Bool {
        guard isHandshake(d) else { return false }
        let pub = d.subdata(in: 2..<34)
        let mac = d.subdata(in: 34..<66)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: pub, using: MeshCrypto.psk) else {
            NSLog("TRINET: handshake HMAC invalid — rejected")
            return true
        }
        guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub),
              let shared = try? ephPriv.sharedSecretFromKeyAgreement(with: peerPub) else {
            return true
        }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                 salt: MeshCrypto.hkdfSalt,
                                                 sharedInfo: MeshCrypto.hkdfInfo,
                                                 outputByteCount: 32)
        if sessionKey == nil { NSLog("TRINET: session established (forward-secret)") }
        sessionKey = key
        return true
    }

    func seal(_ plain: Data) -> Data? {
        guard let key = sessionKey,
              let box = try? ChaChaPoly.seal(plain, using: key) else { return nil }
        return box.combined
    }

    func unseal(_ wire: Data) -> Data? {
        guard let key = sessionKey else { return nil }
        guard let box = try? ChaChaPoly.SealedBox(combined: wire),
              let plain = try? ChaChaPoly.open(box, using: key) else {
            dropCount += 1
            if dropCount <= 3 || dropCount % 1000 == 0 {
                NSLog("TRINET: dropped unauthenticated datagram \(wire.count)B (#\(dropCount))")
            }
            return nil
        }
        return plain
    }
}

// MARK: - Virtual background (embedded; iOS target uses a static file list).
// Vision person-segmentation → CIBlendWithMask blurs the background on the
// outgoing frame so the peer sees the blur. Mirrors desktop/BackgroundBlur.swift.
final class BackgroundBlur {
    private let ci = CIContext()
    private let request = VNGeneratePersonSegmentationRequest()
    private var pool: CVPixelBufferPool?

    init() {
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func process(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return pb }
        let frame = CIImage(cvPixelBuffer: pb)
        var maskImg = CIImage(cvPixelBuffer: mask)
        let sx = frame.extent.width / maskImg.extent.width
        let sy = frame.extent.height / maskImg.extent.height
        maskImg = maskImg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let blurred = frame.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: frame.extent)
        guard let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: frame, kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: maskImg
        ])?.outputImage else { return pb }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(pb),
                kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
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

// MARK: - Call Recorder (iOS)
// Records the decoded remote video + a single AAC audio track that MIXES the
// incoming (remote) and local-mic PCM, so a recording carries both voices.
// Mirrors desktop/CallRecorder.swift (proven by harness); saves to Documents so
// the file is reachable via the share sheet / Files. Embedded here because the
// iOS target compiles a static file list (same pattern as MeshCrypto/DS).
final class CallRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var startTime: CFTimeInterval = 0
    private var started = false
    private(set) var recording = false
    private(set) var url: URL?

    func start() {
        guard !recording else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = "TRI-NET-\(Int(CFAbsoluteTimeGetCurrent())).mov"
        let out = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        guard let w = try? AVAssetWriter(outputURL: out, fileType: .mov) else {
            NSLog("TRINET: recorder writer init failed"); return
        }
        writer = w
        url = out
        recording = true
        started = false
        micLock.lock(); micFifo.removeAll(keepingCapacity: true); micLock.unlock()
        NSLog("TRINET: recording → \(out.path)")
    }

    func append(_ pb: CVImageBuffer) {
        guard recording, let w = writer else { return }
        if !started {
            let width = CVPixelBufferGetWidth(pb)
            let height = CVPixelBufferGetHeight(pb)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: nil)
            guard w.canAdd(inp) else { NSLog("TRINET: recorder can't add input"); recording = false; return }
            w.add(inp)
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000
            ]
            let aInp = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aInp.expectsMediaDataInRealTime = true
            if w.canAdd(aInp) { w.add(aInp); audioInput = aInp }
            w.startWriting()
            w.startSession(atSourceTime: .zero)
            input = inp; adaptor = adp
            startTime = CFAbsoluteTimeGetCurrent()
            started = true
        }
        guard let adp = adaptor, let inp = input, inp.isReadyForMoreMediaData else { return }
        let t = CMTime(seconds: CFAbsoluteTimeGetCurrent() - startTime, preferredTimescale: 600)
        adp.append(pb, withPresentationTime: t)
    }

    private var micFifo = [Int16]()
    private let micLock = NSLock()
    private let micFifoCap = 3200   // 200ms @ 16k

    func pushLocalAudio(_ pcm: Data) {
        guard recording else { return }
        let n = pcm.count / 2
        guard n > 0 else { return }
        micLock.lock()
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let lo = UInt16(raw[i * 2]); let hi = UInt16(raw[i * 2 + 1])
                micFifo.append(Int16(bitPattern: lo | (hi << 8)))
            }
        }
        if micFifo.count > micFifoCap { micFifo.removeFirst(micFifo.count - micFifoCap) }
        micLock.unlock()
    }

    private var audioAppendCount = 0
    func appendAudio(_ rxPcm: Data) {
        guard recording, started, let aInp = audioInput else { return }
        guard aInp.isReadyForMoreMediaData else { return }
        let n = rxPcm.count / 2
        guard n > 0 else { return }
        micLock.lock()
        let take = min(n, micFifo.count)
        let mic = Array(micFifo.prefix(take))
        if take > 0 { micFifo.removeFirst(take) }
        micLock.unlock()
        var pcm = Data(count: rxPcm.count)
        rxPcm.withUnsafeBytes { (rx: UnsafeRawBufferPointer) in
            pcm.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                for i in 0..<n {
                    let rlo = UInt16(rx[i * 2]); let rhi = UInt16(rx[i * 2 + 1])
                    let r = Int(Int16(bitPattern: rlo | (rhi << 8)))
                    let m = i < take ? Int(mic[i]) : 0
                    var s = (r * 4 + m * 4) / 5
                    if s > 32767 { s = 32767 } else if s < -32768 { s = -32768 }
                    let u = UInt16(bitPattern: Int16(s))
                    out[i * 2] = UInt8(u & 0xff)
                    out[i * 2 + 1] = UInt8(u >> 8)
                }
            }
        }
        if audioFormat == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &fmt)
            audioFormat = fmt
        }
        guard let fmt = audioFormat else { return }
        var block: CMBlockBuffer?
        let bytes = pcm.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let bb = block else { return }
        pcm.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        let t = CMTime(seconds: CFAbsoluteTimeGetCurrent() - startTime, preferredTimescale: 16000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16000),
            presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var sizeN = 2
        _ = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeN, sampleBufferOut: &sb)
        if let s = sb {
            _ = aInp.append(s)
            audioAppendCount += 1
            if audioAppendCount <= 2 { NSLog("TRINET: rec audio append #\(audioAppendCount)") }
        }
    }

    func stop(_ done: ((URL?) -> Void)? = nil) {
        guard recording else { done?(nil); return }
        recording = false
        let u = url
        input?.markAsFinished()
        audioInput?.markAsFinished()
        writer?.finishWriting { [weak self] in
            NSLog("TRINET: recording saved \(u?.path ?? "?")")
            self?.writer = nil; self?.input = nil; self?.adaptor = nil
            self?.audioInput = nil; self?.audioFormat = nil
            DispatchQueue.main.async { done?(u) }
        }
    }
}

// MARK: - Opus codec (iOS copy; see desktop/TriNetVideo/OpusCodec.swift)


final class OpusCodec {
    // Our wire PCM: 16k mono Int16 LE — the same bytes the transport carries.
    static let wireRate = 16000.0
    static let frameSamples = 320          // 20ms

    private let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: OpusCodec.wireRate,
                                       channels: 1, interleaved: true)!
    private let opusFmt: AVAudioFormat
    private let enc: AVAudioConverter
    private let dec: AVAudioConverter

    init?(bitrate: Int = 24000) {
        var d = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let of = AVAudioFormat(streamDescription: &d),
              let e = AVAudioConverter(from: pcmFmt, to: of),
              let x = AVAudioConverter(from: of, to: pcmFmt) else { return nil }
        e.bitRate = bitrate
        opusFmt = of; enc = e; dec = x
    }

    // 320-sample Int16 LE PCM -> one Opus frame (~63B). nil if the frame is short
    // or the converter yields nothing this call.
    func encode(_ pcm: Data) -> Data? {
        let n = pcm.count / 2
        guard n > 0, let src = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        src.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            memcpy(src.int16ChannelData![0], raw.baseAddress!, n * 2)
        }
        let out = AVAudioCompressedBuffer(format: opusFmt, packetCapacity: 4, maximumPacketSize: 1500)
        var fed = false
        var err: NSError?
        let st = enc.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true; s.pointee = .haveData; return src
        }
        guard st != .error, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }

    // One Opus frame off the wire -> Int16 LE PCM. The bytes arrive naked, so the
    // packet description the encoder produced is gone and must be rebuilt here —
    // without it the decoder silently returns nothing.
    func decode(_ opus: Data) -> Data? {
        guard !opus.isEmpty else { return nil }
        let comp = AVAudioCompressedBuffer(format: opusFmt, packetCapacity: 1, maximumPacketSize: max(opus.count, 1500))
        opus.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            memcpy(comp.data, raw.baseAddress!, opus.count)
        }
        comp.byteLength = UInt32(opus.count)
        comp.packetCount = 1
        if let pd = comp.packetDescriptions {
            pd[0] = AudioStreamPacketDescription(mStartOffset: 0,
                                                 mVariableFramesInPacket: 0,
                                                 mDataByteSize: UInt32(opus.count))
        }
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFmt,
                                         frameCapacity: AVAudioFrameCount(OpusCodec.frameSamples * 6)) else { return nil }
        var fed = false
        var err: NSError?
        let st = dec.convert(to: out, error: &err) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true; s.pointee = .haveData; return comp
        }
        guard st != .error, out.frameLength > 0 else { return nil }
        let n = Int(out.frameLength)
        return Data(bytes: out.int16ChannelData![0], count: n * 2)
    }
}

// MARK: - Live log (iOS)
// The phone has been a black box all along: every diagnosis had to be inferred
// from what the Mac received, which is how "the mic dies after 2 buffers" took so
// many passes. Same trick as the Mac (desktop/TriNetVideo/LinkStatus.swift):
// dup2 our own stderr into a pipe so every existing NSLog shows up in-app, and
// hand the whole buffer to the clipboard on demand.
final class LogBus: ObservableObject {
    static let shared = LogBus()
    @Published private(set) var lines: [String] = []
    private let cap = 4000
    private var pipeRead: Int32 = -1
    private var origStderr: Int32 = -1
    private let q = DispatchQueue(label: "trinet.logbus.ios")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        pipeRead = fds[0]
        origStderr = dup(STDERR_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        setvbuf(stderr, nil, _IOLBF, 0)
        q.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        // Accumulate BYTES: a read can split a multi-byte UTF-8 char, and
        // decoding each chunk alone turns it into U+FFFD permanently.
        var pending = Data()
        while true {
            let n = read(pipeRead, &buf, buf.count)
            guard n > 0 else { break }
            if origStderr >= 0 { _ = write(origStderr, buf, n) }
            pending.append(contentsOf: buf[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending = pending[pending.index(after: nl)...]
                publish(line)
            }
        }
    }

    // Headed by the facts a reader would otherwise have to ask for.
    func transcript() -> String {
        let head = """
        === TRI-NET iPhone log ===
        iOS: \(UIDevice.current.systemVersion) \(UIDevice.current.model)
        opus send: \(AudioController.opusEnabled)   mesh NAL ceiling: \(H264Encoder.meshMaxNAL)B
        lines: \(lines.count) (buffer holds \(cap))
        ==========================
        """
        return head + "\n" + lines.joined(separator: "\n")
    }

    private func publish(_ raw: String) {
        var s = raw
        if let r = s.range(of: "] "), s.hasPrefix("20") { s = String(s[r.upperBound...]) }
        guard !s.isEmpty else { return }
        DispatchQueue.main.async {
            self.lines.append(s)
            if self.lines.count > self.cap { self.lines.removeFirst(self.lines.count - self.cap) }
        }
    }
}

// ===== PeerDiscovery (embedded — iOS target has a static file list; can't add a new file) =====
// TRI-NET local-network presence, so you pick people by NAME instead of typing IPs. Bonjour via
// Network.framework; resolve the ONE tapped peer to an IP for the existing UDP transport on 7000.
final class PeerDiscovery: ObservableObject {
    struct Peer: Identifiable, Equatable {
        let uid: String
        var name: String
        var room: String
        var status: String          // "idle" | "call"
        let endpoint: NWEndpoint
        var id: String { uid }
        static func == (a: Peer, b: Peer) -> Bool {
            a.uid == b.uid && a.name == b.name && a.status == b.status && a.room == b.room
        }
    }

    @Published var peers: [Peer] = []
    static let serviceType = "_trinet._udp"
    static let transportPort = 7000

    static let myUID: String = {
        let k = "trinetPeerUID"
        if let s = UserDefaults.standard.string(forKey: k) { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: k)
        return s
    }()

    static var myName: String {
        get {
            if let n = UserDefaults.standard.string(forKey: "trinetDisplayName"), !n.isEmpty { return n }
            return UIDevice.current.name
        }
        set { UserDefaults.standard.set(newValue, forKey: "trinetDisplayName") }
    }
    static var myRoom: String {
        get { UserDefaults.standard.string(forKey: "trinetRoom") ?? "" }
        set { UserDefaults.standard.set(newValue.uppercased(), forKey: "trinetRoom") }
    }

    @Published var inCall = false { didSet { if oldValue != inCall { republish() } } }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var started = false

    func start() { started = true; publish(); browse() }
    func stop() {
        started = false
        listener?.cancel(); browser?.cancel()
        listener = nil; browser = nil
        DispatchQueue.main.async { self.peers = [] }
    }

    func setName(_ name: String) { PeerDiscovery.myName = name; republish() }
    func setRoom(_ room: String) { PeerDiscovery.myRoom = room; republish() }

    private func republish() {
        guard started else { return }
        listener?.cancel(); listener = nil
        publish()
        DispatchQueue.main.async { self.peers = [] }
    }

    private func publish() {
        var txt = NWTXTRecord()
        txt["name"] = PeerDiscovery.myName
        txt["uid"] = PeerDiscovery.myUID
        txt["port"] = "\(PeerDiscovery.transportPort)"
        txt["room"] = PeerDiscovery.myRoom
        txt["status"] = inCall ? "call" : "idle"
        do {
            let l = try NWListener(using: .udp)
            l.service = NWListener.Service(name: PeerDiscovery.myName + "\u{00A0}" + String(PeerDiscovery.myUID.prefix(4)),
                                           type: PeerDiscovery.serviceType, domain: "local.", txtRecord: txt)
            l.newConnectionHandler = { $0.cancel() }
            l.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("TRINET: discovery publish failed: \(e)") } }
            l.start(queue: .main)
            listener = l
            NSLog("TRINET: discovery advertising '\(PeerDiscovery.myName)' room='\(PeerDiscovery.myRoom)' status=\(inCall ? "call" : "idle")")
        } catch { NSLog("TRINET: discovery NWListener failed: \(error)") }
    }

    private func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: PeerDiscovery.serviceType, domain: "local."), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            let room = PeerDiscovery.myRoom
            var list: [Peer] = []
            for r in results {
                guard case let .bonjour(txt) = r.metadata else { continue }
                let uid = txt["uid"] ?? ""
                if uid.isEmpty || uid == PeerDiscovery.myUID { continue }
                let peerRoom = txt["room"] ?? ""
                if !room.isEmpty && peerRoom != room { continue }
                if list.contains(where: { $0.uid == uid }) { continue }
                list.append(Peer(uid: uid, name: txt["name"] ?? "TRI-NET", room: peerRoom,
                                 status: txt["status"] ?? "idle", endpoint: r.endpoint))
            }
            let sorted = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async {
                self.peers = sorted
                NSLog("TRINET: roster \(sorted.count) peer(s): \(sorted.map { $0.name }.joined(separator: ", "))")
            }
        }
        b.stateUpdateHandler = { st in if case .failed(let e) = st { NSLog("TRINET: discovery browse failed: \(e)") } }
        b.start(queue: .main)
        browser = b
        NSLog("TRINET: discovery browsing \(PeerDiscovery.serviceType)")
    }

    func resolveIP(_ peer: Peer, completion: @escaping (String?) -> Void) {
        // Force IPv4: our UDP transport is sockaddr_in / inet_addr only. Bonjour on iOS otherwise resolves to
        // an IPv6 link-local (fe80::…) first, which inet_addr can't parse — so packets go nowhere. Ask the
        // NWConnection for IPv4 and never hand back a v6 address.
        let params = NWParameters.udp
        if let ipOpt = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpt.version = .v4
        }
        let conn = NWConnection(to: peer.endpoint, using: params)
        var done = false
        let finish: (String?) -> Void = { ip in
            if done { return }; done = true
            NSLog("TRINET: resolved '\(peer.name)' -> \(ip ?? "FAILED")")
            conn.cancel(); DispatchQueue.main.async { completion(ip) }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var ip: String?
                if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                    switch host {
                    case .ipv4(let a): ip = "\(a)".components(separatedBy: "%").first
                    case .ipv6: ip = nil   // IPv4-only transport — never use a v6 address
                    case .name(let n, _): ip = n
                    @unknown default: break
                    }
                }
                finish(ip)
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }
}
