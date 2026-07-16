// VideoPipeline.swift — Camera + H.264 encode/decode + UDP transport (iOS)
import SwiftUI
import AVFoundation
import VideoToolbox
import Network

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

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = AVCaptureSession.Preset(rawValue: "AVCaptureSessionPreset352x288")
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: cam),
           session.canAddInput(input) {
            session.addInput(input)
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
    }

    func start() {
        guard encoder == nil else { return }
        let enc = H264Encoder()
        guard enc.setup() else { return }
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
    let width: Int32 = 480
    let height: Int32 = 272

    func setup() -> Bool {
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
        guard let s = session, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
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

    func feed(_ nalUnit: Data) {
        guard nalUnit.count > 4 else { return }
        let nalType = nalUnit[4] & 0x1F
        switch nalType {
        // CMVideoFormatDescriptionCreateFromH264ParameterSets expects raw
        // parameter sets — strip the 4-byte Annex-B start code
        case 7: sps = nalUnit.subdata(in: 4..<nalUnit.count); tryInitSession()
        case 8: pps = nalUnit.subdata(in: 4..<nalUnit.count); tryInitSession()
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
                guard status == noErr, let desc = desc else { return }
                self.formatDesc = desc
                let refCon = Unmanaged.passUnretained(self).toOpaque()
                var callback = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                        guard status == noErr, let imageBuffer = imageBuffer else { return }
                        let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon!).takeUnretainedValue()
                        DispatchQueue.main.async {
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
                VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: desc,
                    decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: &callback, decompressionSessionOut: &newSession
                )
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
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }
}

// MARK: - Network Transport (NWConnection for iOS, works reliably)

class BSDTransport {
    private var conn: NWConnection?
    private var listener: NWListener?
    var onData: ((Data) -> Void)?
    var isReady = false

    func connect(host: String, port: UInt16, recvPort: UInt16) {
        disconnect()

        // Send connection to peer
        conn = NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: .udp)
        conn?.start(queue: .global())

        // Listen for incoming on recvPort
        do {
            listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: recvPort)!)
        } catch {
            // Fallback: bind NWConnection to any port
            return
        }
        listener?.newConnectionHandler = { [weak self] c in
            c.start(queue: .global())
            self?.receiveLoop(c)
        }
        listener?.start(queue: .global())
        isReady = true
    }

    private func receiveLoop(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, _ in
            if let d = data {
                self?.onData?(d)
            }
            self?.receiveLoop(c)
        }
    }

    func send(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    func disconnect() {
        conn?.cancel(); listener?.cancel()
        conn = nil; listener = nil
        isReady = false
    }
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
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    func update(_ buffer: CVImageBuffer) {
        let ci = CIImage(cvImageBuffer: buffer)
        let context = CIContext()
        if let cg = context.createCGImage(ci, from: ci.extent) {
            let img = UIImage(cgImage: cg)
            // Use a simple sublayer to display
            if let oldLayer = layer.sublayers?.first { oldLayer.removeFromSuperlayer() }
            let imgLayer = CALayer()
            imgLayer.frame = bounds
            imgLayer.contents = img.cgImage
            imgLayer.contentsGravity = .resizeAspect
            layer.addSublayer(imgLayer)
        }
    }
}
