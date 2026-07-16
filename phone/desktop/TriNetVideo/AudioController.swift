// AudioController.swift — capture -> 16kHz mono int16 PCM over UDP -> playback.
// Wire format: [0xFD 0xAD] + little-endian Int16 samples (~20ms per packet,
// fits one datagram — never fragmented).
//
// Two SEPARATE engines. A single engine with voice processing fused the mic
// input and speaker output into one VPIO unit that failed to initialize on
// this Mac (err -10875) — and because the graph was shared, the failure took
// the *playback* path down with it. Splitting them means playback (a plain
// player -> mixer -> speakers graph, no input) always starts, so incoming
// audio is heard even if mic capture can't start. Trade-off: no hardware echo
// cancellation on macOS (acceptable — the Mac is usually on headphones/the
// far end handles AEC).
import Foundation
import AVFoundation

final class AudioController {
    private let playEngine = AVAudioEngine()
    private let capEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 16000, channels: 1, interleaved: false)!
    var onPacket: ((Data) -> Void)?
    private var playing = false
    private var capturing = false
    private var rxCount = 0
    private var txCount = 0

    func start() {
        startPlayback()
        startCapture()
    }

    // Playback: player -> mixer -> speakers. No input node, so it's immune to
    // the mic/VPIO format problems that broke the combined engine.
    private func startPlayback() {
        guard !playing else { return }
        playEngine.attach(player)
        // Connect through the main mixer; let the engine resample 16k mono ->
        // whatever the speakers want (48k stereo here).
        playEngine.connect(player, to: playEngine.mainMixerNode, format: wireFormat)
        playEngine.prepare()
        do {
            try playEngine.start()
            player.play()
            playing = true
            NSLog("TRINET: audio playback engine up (out \(playEngine.outputNode.outputFormat(forBus: 0)))")
        } catch {
            NSLog("TRINET: audio playback start failed: \(error)")
        }
    }

    // Capture: mic tap -> convert to 16k mono -> packetize. If this can't start
    // (odd input device), playback still works.
    private func startCapture() {
        guard !capturing else { return }
        let inFmt = capEngine.inputNode.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            NSLog("TRINET: audio capture input format invalid (\(inFmt)) — mic disabled")
            return
        }
        converter = AVAudioConverter(from: inFmt, to: wireFormat)
        capEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
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
        capEngine.prepare()
        do {
            try capEngine.start()
            capturing = true
            NSLog("TRINET: audio capture engine up in=\(Int(inFmt.sampleRate))Hz ch=\(inFmt.channelCount)")
        } catch {
            NSLog("TRINET: audio capture start failed: \(error) — mic disabled, playback still on")
            capEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // payload = Int16 LE samples (magic already stripped)
    func playPacket(_ d: Data) {
        guard playing else { return }
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
        if capturing { capEngine.inputNode.removeTap(onBus: 0); capEngine.stop(); capturing = false }
        if playing { player.stop(); playEngine.stop(); playing = false }
    }
}
