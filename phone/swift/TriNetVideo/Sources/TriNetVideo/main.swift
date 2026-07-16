// TriNetVideoApp.swift — Camera capture → H.264 → UDP → mesh node
// Pure Swift, ноль внешних зависимостей:
//   AVFoundation = camera capture
//   VideoToolbox = H.264 hardware encode
//   Network.framework = UDP transport
// SwiftUI = minimal UI

import SwiftUI
import AVFoundation
import Network
import VideoToolbox

// MARK: - H.264 Encoder

class H264Encoder {
    private var session: VTCompressionSession?
    let width: Int32 = 480
    let height: Int32 = 272
    let fps: Int32 = 15

    // Callback for encoded H.264 NAL units
    var onEncodedFrame: ((Data, Bool) -> Void)? // (data, isKeyFrame)

    func setup() -> Bool {
        let result = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer in
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }
                let encoder = Unmanaged<H264Encoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                encoder.handleEncodedFrame(sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard result == noErr else { return false }

        VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_AverageBitRate, value: 200_000 as CFNumber) // 200kbps
        VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps * 2 as CFNumber) // keyframe every 2s
        VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session!, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_3_0 as CFString)

        VTCompressionSessionPrepareToEncodeFrames(session!)
        return true
    }

    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer) {
        guard let array = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // Check if keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyFrame = false
        if let arr = attachments, CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
            let notSync = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque() as CFString)
            isKeyFrame = (notSync == nil) // NotSync absent = IS sync (keyframe)
        }

        // Extract SPS/PPS for keyframes
        if isKeyFrame {
            var sps: Data?
            var pps: Data?
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(array, 0, parameterSetPointerOut: &sps, nil, nil, nil)
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(array, 1, parameterSetPointerOut: &pps, nil, nil, nil)
            if let sps = sps { onEncodedFrame?(sps, true) }
            if let pps = pps { onEncodedFrame?(pps, true) }
        }

        // Extract H.264 data from sample buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else { return }

        // Convert AVCC to Annex-B (NAL units with start codes)
        var offset = 0
        while offset < totalLength - 4 {
            // Read NAL unit length (big-endian 32-bit)
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)

            // Annex-B start code
            let nalData = Data(bytes: pointer + offset + 4, count: Int(nalLength))
            var frame = Data([0x00, 0x00, 0x00, 0x01]) // start code
            frame.append(nalData)
            onEncodedFrame?(frame, isKeyFrame)

            offset += 4 + Int(nalLength)
        }
    }

    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
    }
}

// MARK: - UDP Transport

class UDPTransport {
    private var connection: NWConnection?
    var onDataReceived: ((Data) -> Void)?

    func connect(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let params = NWParameters.udp
        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("UDP connected to \(host):\(port)")
                self.startReceiving()
            case .failed(let error):
                print("UDP failed: \(error)")
            default:
                break
            }
        }
        connection?.start(queue: .global())
    }

    private func startReceiving() {
        connection?.receiveMessage { data, _, _, error in
            if let data = data {
                self.onDataReceived?(data)
            }
            // Continue receiving
            if error == nil {
                self.startReceiving()
            }
        }
    }

    func send(data: Data) {
        connection?.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("UDP send error: \(error)")
            }
        }))
    }

    func disconnect() {
        connection?.cancel()
    }
}

// MARK: - Camera Capture

class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let encoder = H264Encoder()
    var onFrameEncoded: ((Data, Bool) -> Void)?

    func setup() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .cif // 352x288 — close to 480x272

        // Front camera
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            print("No camera available")
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: camera) else { return false }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.queue"))

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()

        encoder.onEncodedFrame = { [weak self] data, isKey in
            self?.onFrameEncoded?(data, isKey)
        }

        return encoder.setup()
    }

    func start() {
        DispatchQueue.global().async {
            self.session.startRunning()
        }
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureVideoDataOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder.encode(sampleBuffer: sampleBuffer)
    }
}

// MARK: - SwiftUI App (simple console UI for iOS Simulator/device)

struct ContentView: View {
    @StateObject var viewModel = VideoMeshViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("TRI-NET Video Mesh")
                .font(.title)
                .fontWeight(.bold)

            Text(viewModel.status)
                .font(.body)
                .foregroundColor(viewModel.connected ? .green : .red)

            HStack {
                Text("TX: \(viewModel.framesSent)")
                Spacer()
                Text("RX: \(viewModel.framesReceived)")
            }
            .padding()

            TextField("Mesh Node IP", text: $viewModel.nodeIP)
                .textFieldStyle(.roundedBorder)

            Button(viewModel.capturing ? "Stop" : "Start Camera") {
                if viewModel.capturing {
                    viewModel.stop()
                } else {
                    viewModel.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding()

            Text("TX rate: \(viewModel.txBytesPerSec / 1024) KB/s")
                .font(.caption)
        }
        .padding()
    }
}

class VideoMeshViewModel: ObservableObject {
    @Published var status = "Idle"
    @Published var connected = false
    @Published var capturing = false
    @Published var framesSent = 0
    @Published var framesReceived = 0
    @Published var nodeIP = "192.168.1.11"
    @Published var txBytesPerSec = 0

    private let camera = CameraCapture()
    private let transport = UDPTransport()
    private var frameCount = 0
    private var byteCount = 0
    private var timer: Timer?

    func start() {
        // Connect UDP to mesh node
        transport.connect(host: nodeIP, port: 5000)
        transport.onDataReceived = { data in
            DispatchQueue.main.async {
                self.framesReceived += 1
            }
        }

        // Setup camera
        guard camera.setup() else {
            status = "Camera setup failed"
            return
        }
        camera.onFrameEncoded = { data, isKey in
            self.transport.send(data: data)
            self.frameCount += 1
            self.byteCount += data.count
            DispatchQueue.main.async {
                self.framesSent = self.frameCount
            }
        }
        camera.start()

        capturing = true
        status = "Streaming → \(nodeIP):5000"

        // Update TX rate every second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.txBytesPerSec = self.byteCount
            self.byteCount = 0
        }
    }

    func stop() {
        camera.stop()
        transport.disconnect()
        timer?.invalidate()
        capturing = false
        status = "Stopped"
    }
}

// Entry point
struct TriNetVideoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
