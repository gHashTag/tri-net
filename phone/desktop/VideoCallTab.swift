// VideoCallTab.swift — Video receiver with logs + NO freeze
// Логи ВСЕ через DispatchQueue.main.async — SwiftUI не зависнет
import SwiftUI
import AppKit
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreImage
import Darwin

class VideoEngine: ObservableObject {
    @Published var status = "Press Start"
    @Published var frameCount = 0
    @Published var pktCount = 0
    @Published var isReceiving = false
    @Published var logs: [String] = []

    private var decoder = H264DecoderShared()
    private var sockFd: Int32 = -1
    private var running = false
    private var rxQueue = DispatchQueue(label: "video.rx")
    weak var displayView: NSView?

    // Thread-safe log accumulation
    private var pendingLogs: [String] = []
    private var logLock = NSLock()

    private func bgLog(_ msg: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let line = "\(f.string(from: Date())) \(msg)"
        logLock.lock()
        pendingLogs.append(line)
        // Keep only last 30 pending
        if pendingLogs.count > 30 { pendingLogs.removeFirst(pendingLogs.count - 30) }
        logLock.unlock()
    }

    // Called from main thread every 0.3s via Timer
    private func flushLogs() {
        logLock.lock()
        let batch = pendingLogs
        pendingLogs.removeAll()
        logLock.unlock()
        if !batch.isEmpty {
            logs.append(contentsOf: batch)
            if logs.count > 50 { logs.removeFirst(logs.count - 50) }
        }
    }

    func start() {
        guard !running else { return }
        running = true

        // Start log flush timer on main thread
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.flushLogs()
        }

        DispatchQueue.main.async { self.status = "Creating socket..." }

        bgLog("1️⃣ Creating BSD UDP socket...")
        sockFd = socket(AF_INET, SOCK_DGRAM, 0)
        guard sockFd >= 0 else {
            bgLog("❌ socket() failed: \(String(cString: strerror(errno)))")
            DispatchQueue.main.async { self.status = "❌ Socket error" }
            return
        }
        bgLog("✅ Socket fd=\(sockFd)")

        var on: Int32 = 1
        setsockopt(sockFd, SOL_SOCKET, SO_REUSEADDR, &on, 4)

        bgLog("2️⃣ Binding to 0.0.0.0:7000...")
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(7000).bigEndian
        addr.sin_addr.s_addr = 0
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { s in
                Darwin.bind(sockFd, s, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            bgLog("❌ bind() failed: \(String(cString: strerror(errno)))")
            DispatchQueue.main.async { self.status = "❌ Bind error" }
            running = false; return
        }
        bgLog("✅ Bound to :7000")

        DispatchQueue.main.async { self.status = "Listening :7000 — press green button on iPhone" }
        bgLog("3️⃣ Receive loop starting (blocking socket on bg queue)...")
        bgLog("⏳ Waiting for iPhone to send H.264 video...")

        rxQueue.async { [weak self] in self?.recvLoop() }
    }

    private func recvLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var localPkt = 0
        var localFrames = 0
        var loggedNALs: Set<Int> = []

        while running {
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                recvfrom(sockFd, p.baseAddress!, 65536, 0, nil, nil)
            }
            if n > 0 {
                localPkt += 1
                let data = Data(buf.prefix(n))

                // First packet!
                if localPkt == 1 {
                    bgLog("🎉 FIRST PACKET! \(n)B from iPhone — video incoming!")
                    DispatchQueue.main.async {
                        self.isReceiving = true
                        self.status = "✅ Receiving video..."
                    }
                }

                if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
                    let nalType = data.count > 4 ? Int(data[4] & 0x1f) : -1

                    // Log each NAL type once
                    if !loggedNALs.contains(nalType) {
                        loggedNALs.insert(nalType)
                        let name: String
                        switch nalType {
                        case 1: name = "P-frame (video data)"
                        case 5: name = "I-frame (KEY frame)"
                        case 6: name = "SEI (metadata)"
                        case 7: name = "SPS (decoder config — REQUIRED!)"
                        case 8: name = "PPS (decoder params — REQUIRED!)"
                        default: name = "type \(nalType)"
                        }
                        bgLog("📦 NAL type \(nalType) = \(name), \(n)B")
                    }

                    // Log every 100th packet
                    if localPkt % 100 == 0 {
                        bgLog("📥 pkt #\(localPkt) \(n)B NAL=\(nalType)")
                    }

                    decoder.feed(data) { [weak self] imgBuf in
                        guard let self = self else { return }
                        localFrames += 1
                        let fc = localFrames
                        let lp = localPkt

                        if fc == 1 {
                            self.bgLog("🎬 FIRST FRAME DECODED! Video should be visible!")
                            DispatchQueue.main.async {
                                self.status = "🎬 LIVE — video decoding!"
                                self.frameCount = 1
                                self.pktCount = lp
                            }
                        }

                        DispatchQueue.main.async {
                            self.displayView?.displayFrame(imgBuf)
                            if fc % 10 == 0 {
                                self.frameCount = fc
                                self.pktCount = lp
                            }
                        }
                    }

                    // Check decoder errors after each feed
                    if let err = decoder.lastError {
                        bgLog("❌ Decoder: \(err)")
                        decoder.lastError = nil
                    }
                }
            }
        }
        bgLog("🛑 recvLoop exited")
    }

    func stop() {
        running = false
        if sockFd >= 0 { close(sockFd); sockFd = -1 }
        DispatchQueue.main.async {
            self.status = "Stopped"
            self.isReceiving = false
        }
        bgLog("🛑 Stopped")
    }

    func copyLogs() {
        flushLogs()
        let text = logs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - NSView frame display
extension NSView {
    func displayFrame(_ buffer: CVImageBuffer) {
        let ci = CIImage(cvImageBuffer: buffer)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let l = CALayer(); l.contents = cg; l.contentsGravity = .resizeAspect; l.frame = bounds
        layer?.addSublayer(l)
    }
}

// MARK: - H.264 Decoder
class H264DecoderShared {
    var session: VTDecompressionSession?
    var fmtDesc: CMVideoFormatDescription?
    var sps: Data?; var pps: Data?
    var onFrame: ((CVImageBuffer) -> Void)?
    var lastError: String?

    func feed(_ nal: Data, callback: @escaping (CVImageBuffer) -> Void) {
        guard nal.count > 4 else { return }
        let t = nal[4] & 0x1F
        if t == 7 { sps = nal; initSession(callback) }
        else if t == 8 { pps = nal; initSession(callback) }
        else if t == 5 || t == 1 {
            // No SPS/PPS yet? Generate from known encoder params (480x272 Baseline 3.0)
            if fmtDesc == nil && sps == nil && pps == nil {
                sps = generateSPS()
                pps = generatePPS()
                initSession(callback)
            }
            if fmtDesc != nil { decode(nal) }
        }
        else { decode(nal) }
    }

    // Hardcoded SPS for 480x272 H.264 Baseline 3.0 (matches iPhone encoder)
    private func generateSPS() -> Data {
        // SPS NAL: profile_idc=66(Baseline), constraint flags, level_idc=30
        // width=480 (pic_width_in_mbs_minus1=29 → 30*16=480)
        // height=272 (pic_height_in_map_units_minus1=16 → 17*16=272)
        return Data([
            0x00, 0x00, 0x00, 0x01,  // start code
            0x67,                     // NAL type 7 = SPS
            0x42,                     // profile_idc = 66 (Baseline)
            0x00,                     // constraint_set0-3_flags + reserved
            0x1E,                     // level_idc = 30
            0xCE,                     // seq_parameter_set_id=0, log2_max_frame_num=4, pic_order_cnt_type=2
            0x3C, 0x48,               // max_num_ref_frames=1, gaps_in_frame_num=0, pic_width_in_mbs_minus1=29
            0xFA, 0x10,               // pic_height_in_map_units_minus1=16, frame_mbs_only=1
            0x11, 0x10,               // direct_8x8_inference, frame_cropping=0, vui_parameters_present=1
            0x10, 0x14, 0x04, 0x07,   // VUI: aspect_ratio, overscan, video_signal
            0xE8, 0x00, 0x14, 0x00,   // timing_info
            0x00, 0x03, 0x00, 0x04,   // ...
            0x00, 0x07, 0x8C, 0x18    // ...
        ])
    }

    // Hardcoded PPS for Baseline 3.0
    private func generatePPS() -> Data {
        return Data([
            0x00, 0x00, 0x00, 0x01,  // start code
            0x68,                     // NAL type 8 = PPS
            0xCE, 0x38, 0xA0          // minimal PPS params
        ])
    }

    private func initSession(_ cb: @escaping (CVImageBuffer) -> Void) {
        guard let s = sps, let p = pps, fmtDesc == nil else { return }
        // Strip start codes (00 00 00 01) — CMVideoFormatDescription needs raw NAL data
        let spsRaw = stripStartCode(s)
        let ppsRaw = stripStartCode(p)
        spsRaw.withUnsafeBytes { sp in
            ppsRaw.withUnsafeBytes { pp in
                let ptrs = [sp.bindMemory(to: UInt8.self).baseAddress!, pp.bindMemory(to: UInt8.self).baseAddress!]
                let szs = [spsRaw.count, ppsRaw.count]
                var d: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: szs, nalUnitHeaderLength: 4, formatDescriptionOut: &d)
                guard status == noErr, let desc = d else {
                    self.lastError = "CMFormatDesc failed status=\(status)"
                    return
                }
                fmtDesc = desc; onFrame = cb
                let ref = Unmanaged.passUnretained(self).toOpaque()
                var rec = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, st, _, buf, _, _ in
                    let dec = Unmanaged<H264DecoderShared>.fromOpaque(ref!).takeUnretainedValue()
                    if st != noErr {
                        dec.lastError = "decode status=\(st)"
                        return
                    }
                    guard let buf = buf else {
                        dec.lastError = "nil imageBuffer"
                        return
                    }
                    dec.onFrame?(buf)
                }, decompressionOutputRefCon: ref)
                let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
                var ns: VTDecompressionSession?
                VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: desc, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: &rec, decompressionSessionOut: &ns)
                session = ns
            }
        }
    }

    // Remove 00 00 00 01 start code prefix if present
    private func stripStartCode(_ data: Data) -> Data {
        if data.count >= 4 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1 {
            return data.subdata(in: 4..<data.count)
        }
        return data
    }

    private func decode(_ nal: Data) {
        guard let s = session, let fd = fmtDesc else { return }
        var avcc = Data()
        let body = nal.subdata(in: 4..<nal.count)
        var len = UInt32(body.count).bigEndian
        avcc.append(Data(bytes: &len, count: 4)); avcc.append(body)
        var bb: CMBlockBuffer?
        let n = avcc.count
        avcc.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int8.self).baseAddress!
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &bb)
            if let b = bb { CMBlockBufferReplaceDataBytes(with: p, blockBuffer: b, offsetIntoDestination: 0, dataLength: n) }
        }
        guard let b = bb else { return }
        var ss = n; var sb: CMSampleBuffer?; var ti = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(), decodeTimeStamp: CMTime())
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: b, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &ti, sampleSizeEntryCount: 1, sampleSizeArray: &ss, sampleBufferOut: &sb)
        guard let sbuf = sb else { return }
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sbuf, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }
}

// MARK: - Video Display
struct VideoDisplayView: NSViewRepresentable {
    @ObservedObject var engine: VideoEngine
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor.black.cgColor
        engine.displayView = v; return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Video Call Tab
struct VideoCallTab: View {
    @StateObject private var engine = VideoEngine()

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                Text(engine.status)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(engine.isReceiving ? .green : .orange)
                Spacer()
                Text("\(engine.pktCount)p · \(engine.frameCount)f")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
            }
            .padding(10)

            // Video (left) + Logs (right)
            HStack(spacing: 0) {
                // Video
                ZStack {
                    Color.black
                    if !engine.isReceiving {
                        VStack(spacing: 10) {
                            Image(systemName: "video.slash").font(.system(size: 36)).foregroundColor(.gray)
                            Text("Waiting for iPhone...").font(.system(size: 13)).foregroundColor(.gray)
                        }
                    }
                    VideoDisplayView(engine: engine)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Logs
                VStack(spacing: 0) {
                    HStack {
                        Text("📋 LOGS").font(.system(size: 10, weight: .bold)).foregroundColor(.gray)
                        Spacer()
                        Button(action: { engine.copyLogs() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc.fill").font(.system(size: 9))
                                Text("Copy").font(.system(size: 9))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.purple.opacity(0.2)).cornerRadius(4)
                            .foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(engine.logs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(
                                            line.contains("❌") ? .red :
                                            line.contains("✅") ? .green :
                                            line.contains("🎉") ? .yellow :
                                            line.contains("🎬") ? .blue :
                                            line.contains("📦") ? .orange :
                                            line.contains("📥") ? .cyan :
                                            line.contains("⏳") ? .orange : .gray
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(4)
                        }
                        .onChange(of: engine.logs.count) { _ in
                            if let last = engine.logs.last { proxy.scrollTo(engine.logs.count - 1) }
                        }
                    }
                    .background(Color(white: 0.03))
                }
                .frame(width: 300)
            }

            // Bottom
            HStack {
                Spacer()
                Button("Restart") {
                    engine.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { engine.start() }
                }
                .buttonStyle(.plain).font(.system(size: 10))
                Button("Stop") { engine.stop() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.red)
            }
            .padding(8)
        }
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }
}
