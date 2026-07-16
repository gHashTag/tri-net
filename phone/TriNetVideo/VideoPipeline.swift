// VideoPipeline.swift — Camera + H.264 encode/decode + UDP transport (iOS)
import SwiftUI
import AVFoundation
import VideoToolbox
import Network
import CryptoKit

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

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = AVCaptureSession.Preset(rawValue: "AVCaptureSessionPreset352x288")
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
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
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        // input swap re-creates the output connection — orientation must be re-applied
        applyOrientation()
        // restart the encoder so its lazy setup matches the new camera's frames
        if encoder != nil {
            let enc = H264Encoder()
            enc.onFrame = { [weak self] data, isKey in self?.onFrame?(data, isKey) }
            encoder = enc
        }
    }

    // Raw H.264 carries no orientation metadata, so rotate at capture:
    // the app is portrait-locked, encode frames upright (90 deg from the
    // landscape sensor) and every receiver displays them as-is.
    private func applyOrientation() {
        guard let conn = output.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        } else if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }

    func start() {
        guard encoder == nil else { return }
        let enc = H264Encoder()
        enc.onFrame = { [weak self] data, isKey in self?.onFrame?(data, isKey) }
        encoder = enc
        if !session.isRunning { startPreview() }
    }

    func stop() { encoder = nil }
    func stopAll() { session.stopRunning() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder?.encode(sampleBuffer)
    }
}

// MARK: - H.264 Encoder

class H264Encoder {
    private var session: VTCompressionSession?
    var onFrame: ((Data, Bool) -> Void)?
    // Dimensions come from the first captured frame (rotation/preset aware) —
    // hardcoded values would make VideoToolbox scale-squash rotated buffers
    private var width: Int32 = 0
    private var height: Int32 = 0

    func setup(width: Int32, height: Int32) -> Bool {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        let r = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 200_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_3_0 as CFString)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 10 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 0.5 as CFNumber)
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
                onFrame?(spsData, true)
            }
            // PPS
            var ppsSize = 0
            var ppsPtr: UnsafePointer<UInt8>? = nil
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmtDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pp = ppsPtr, ppsSize > 0 {
                var ppsData = Data([0, 0, 0, 1])
                ppsData.append(Data(bytes: pp, count: ppsSize))
                onFrame?(ppsData, true)
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
            onFrame?(d, false)
            off += 4 + Int(nl)
        }
    }

    func encode(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if session == nil {
            let w = Int32(CVPixelBufferGetWidth(pb))
            let h = Int32(CVPixelBufferGetHeight(pb))
            guard setup(width: w, height: h) else { return }
            NSLog("TRINET: encoder session \(w)x\(h)")
        }
        guard let s = session else { return }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb), duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
}

// MARK: - H.264 Decoder

class H264Decoder: ObservableObject {
    @Published var frameCount: Int = 0
    @Published var currentFrame: CVImageBuffer?

    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var fedCount = 0
    var cbErrCount = 0
    private var decodeErrCount = 0

    func feed(_ nalUnit: Data) {
        guard nalUnit.count > 4 else { return }
        let nalType = nalUnit[4] & 0x1F
        fedCount += 1
        if fedCount <= 10 || fedCount % 500 == 0 {
            NSLog("TRINET: NAL #\(fedCount) type=\(nalType) \(nalUnit.count)B session=\(session != nil)")
        }
        switch nalType {
        // CMVideoFormatDescriptionCreateFromH264ParameterSets expects raw
        // parameter sets — strip the 4-byte Annex-B start code.
        // A changed SPS/PPS (peer restarted with new dimensions) must
        // re-create the session, or old-format frames decode as garbage.
        case 7:
            let s = nalUnit.subdata(in: 4..<nalUnit.count)
            if s != sps { sps = s; formatDesc = nil; session = nil }
            tryInitSession()
        case 8:
            let p = nalUnit.subdata(in: 4..<nalUnit.count)
            if p != pps { pps = p; formatDesc = nil; session = nil }
            tryInitSession()
        default: decodeFrame(nalUnit)
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
                let refCon = Unmanaged.passUnretained(self).toOpaque()
                var callback = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                        if status != noErr {
                            let d = Unmanaged<H264Decoder>.fromOpaque(refCon!).takeUnretainedValue()
                            d.cbErrCount += 1
                            if d.cbErrCount <= 5 || d.cbErrCount % 500 == 0 {
                                NSLog("TRINET: decode callback status=\(status) (#\(d.cbErrCount))")
                            }
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
    private var running = false
    private let rxQueue = DispatchQueue(label: "mesh.rx", qos: .userInitiated)
    var onData: ((Data) -> Void)?
    var isReady = false

    func connect(host: String, port: UInt16, recvPort: UInt16) {
        disconnect()

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

        running = true
        isReady = true
        NSLog("TRINET: BSD transport up — listen :\(recvPort), peer \(host):\(port)")

        let sock = fd
        rxQueue.async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            var count = 0
            while true {
                guard let self = self, self.running else { break }
                let n = recv(sock, &buf, buf.count, 0)
                if n > 0 {
                    count += 1
                    if count == 1 || count % 200 == 0 {
                        NSLog("TRINET: rx #\(count) \(n)B")
                    }
                    if let plain = self.unseal(Data(bytes: buf, count: n)),
                       let msg = self.reassemble(plain) {
                        self.onData?(msg)
                    }
                } else {
                    break // socket closed by disconnect() or error
                }
            }
        }
    }

    // MARK: encryption
    // Every datagram is sealed with ChaCha20-Poly1305 (12B nonce + ct + 16B
    // tag) under a pre-shared key — unauthenticated LAN packets are dropped.
    // MVP: static PSK; key exchange belongs to the mesh layer (trios-mesh B').
    private static let cryptoKey = SymmetricKey(data: SHA256.hash(data: Data("tri-net-psk-v1".utf8)))
    private var dropCount = 0

    // MARK: application-level fragmentation
    // UDP datagrams are capped (~9KB default on Apple platforms) and anything
    // over the WiFi MTU relies on lossy IP fragmentation, so large NALs
    // (I-frames) are split into [0xFA 0xFB seqLo seqHi idx total]+chunk
    // datagrams and reassembled on receive. Raw NALs always start
    // 00 00 00 01, so the magic prefix is unambiguous.
    private let maxPayload = 1200
    private var fragSeqOut: UInt16 = 0
    private var fragBufs: [UInt16: (parts: [Data?], have: Int)] = [:]

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
    }

    private func rawSend(_ data: Data) {
        guard let sealed = try? ChaChaPoly.seal(data, using: BSDTransport.cryptoKey) else { return }
        let wire = sealed.combined
        var p = peer
        _ = wire.withUnsafeBytes { raw in
            withUnsafePointer(to: &p) { pp in
                pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                    sendto(fd, raw.baseAddress, wire.count, 0, s, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // Decrypt + authenticate; nil for foreign/corrupt datagrams
    private func unseal(_ d: Data) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: d),
              let plain = try? ChaChaPoly.open(box, using: BSDTransport.cryptoKey) else {
            dropCount += 1
            if dropCount <= 3 || dropCount % 1000 == 0 {
                NSLog("TRINET: dropped unauthenticated datagram \(d.count)B (#\(dropCount))")
            }
            return nil
        }
        return plain
    }

    // Returns a complete NAL when the datagram finishes one, nil otherwise.
    // Multi-slot: chunks of several NALs may interleave (video + a peer
    // restart, or future multi-stream), so partial buffers are keyed by seq.
    private func reassemble(_ d: Data) -> Data? {
        guard d.count > 6, d[0] == 0xFA, d[1] == 0xFB else { return d }
        let seq = UInt16(d[2]) | (UInt16(d[3]) << 8)
        let idx = Int(d[4])
        let total = Int(d[5])
        guard total > 0, idx < total else { return nil }
        var entry = fragBufs[seq] ?? (Array(repeating: nil, count: total), 0)
        if entry.parts.count != total { entry = (Array(repeating: nil, count: total), 0) }
        if entry.parts[idx] == nil {
            entry.parts[idx] = d.subdata(in: 6..<d.count)
            entry.have += 1
        }
        if entry.have == total {
            fragBufs.removeValue(forKey: seq)
            return entry.parts.compactMap { $0 }.reduce(Data(), +)
        }
        fragBufs[seq] = entry
        if fragBufs.count > 8 { fragBufs = fragBufs.filter { $0.key == seq } } // GC stale partials
        return nil
    }

    func disconnect() {
        running = false
        if fd >= 0 { close(fd); fd = -1 }
        isReady = false
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
    var session: AVCaptureSession? { didSet { previewLayer.session = session } }
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
    private var started = false
    private var rxCount = 0
    private var txCount = 0

    func start() {
        guard !started else { return }
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
        if !buildAndStart(voiceProcessing: true) {
            NSLog("TRINET: audio retry without voice processing")
            engine.reset()
            _ = buildAndStart(voiceProcessing: false)
        }
    }

    private func buildAndStart(voiceProcessing: Bool) -> Bool {
        try? engine.inputNode.setVoiceProcessingEnabled(voiceProcessing)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: wireFormat)

        let inFmt = engine.inputNode.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else {
            NSLog("TRINET: audio input format unavailable")
            return false
        }
        converter = AVAudioConverter(from: inFmt, to: wireFormat)
        NSLog("TRINET: audio start in=\(Int(inFmt.sampleRate))Hz ch=\(inFmt.channelCount) vp=\(voiceProcessing)")

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            guard let self = self, let conv = self.converter else { return }
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
            var pkt = Data(capacity: Int(out.frameLength) * 2 + 2)
            pkt.append(contentsOf: [0xFD, 0xAD])
            for i in 0..<Int(out.frameLength) {
                let v = Int16(max(-1.0, min(1.0, ch[i])) * 32767)
                withUnsafeBytes(of: v.littleEndian) { pkt.append(contentsOf: $0) }
            }
            self.txCount += 1
            if self.txCount == 1 { NSLog("TRINET: audio tx first packet \(pkt.count)B") }
            self.onPacket?(pkt)
        }

        do {
            try engine.start()
            player.play()
            started = true
            return true
        } catch {
            NSLog("TRINET: audio engine start failed (vp=\(voiceProcessing)): \(error)")
            engine.inputNode.removeTap(onBus: 0)
            return false
        }
    }

    // payload = Int16 LE samples (magic already stripped)
    func playPacket(_ d: Data) {
        guard started else { return }
        let n = d.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let ch = buf.floatChannelData![0]
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let v = Int16(bitPattern: lo | (hi << 8))
                ch[i] = Float(v) / 32768.0
            }
        }
        rxCount += 1
        if rxCount == 1 { NSLog("TRINET: audio rx first packet \(d.count)B") }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    func stop() {
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
