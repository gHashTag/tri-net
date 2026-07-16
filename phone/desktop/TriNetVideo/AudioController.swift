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
    // Live audio levels (0...1), reported per buffer for the TX/RX meters.
    var onTxLevel: ((Float) -> Void)?
    var onRxLevel: ((Float) -> Void)?
    // Raw incoming 16k Int16 PCM (magic stripped) — for the call recorder.
    var onRxPCM: ((Data) -> Void)?
    private var playing = false
    private var capturing = false
    private var rxCount = 0
    // Adaptive jitter buffer: grow the pre-roll target when inter-packet gaps
    // are erratic, shrink it when they're steady (packets ≈20ms apart).
    private var preRollTarget = 3
    private var lastRxAt: CFTimeInterval = 0
    private var jitterEwma: Double = 0.02
    private var txCount = 0

    // RMS -> perceptual 0...1 (sqrt gives a livelier meter than raw RMS)
    static func level(_ sumSq: Float, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        let rms = (sumSq / Float(n)).squareRoot()
        return min(1, rms * 3) // gain so normal speech fills the meter
    }

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
            // Don't start the player yet — jitter buffer: let a few packets
            // queue first (pre-roll) so a burst of network jitter at the start
            // doesn't underrun into choppiness.
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
            let n = Int(out.frameLength)
            var sumSq: Float = 0
            var pkt = Data(capacity: n * 2 + 2)
            pkt.append(contentsOf: [0xFD, 0xAD])
            for i in 0..<n {
                let f = max(-1.0, min(1.0, ch[i]))
                sumSq += f * f
                let v = Int16(f * 32767)
                withUnsafeBytes(of: v.littleEndian) { pkt.append(contentsOf: $0) }
            }
            self.onTxLevel?(Self.level(sumSq, n))
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
            NSLog("TRINET: audio rx #\(rxCount) \(d.count)B engineRunning=\(playEngine.isRunning) playerPlaying=\(player.isPlaying) mixerVol=\(playEngine.mainMixerNode.outputVolume)")
        }
        // Track inter-packet gap to size the pre-roll adaptively.
        let now = CFAbsoluteTimeGetCurrent()
        if lastRxAt > 0 {
            let gap = now - lastRxAt
            jitterEwma = jitterEwma * 0.9 + abs(gap - 0.02) * 0.1  // deviation from 20ms
            preRollTarget = jitterEwma > 0.04 ? min(8, preRollTarget + 1)
                          : jitterEwma < 0.015 ? max(2, preRollTarget - 1) : preRollTarget
        }
        lastRxAt = now

        player.scheduleBuffer(buf, completionHandler: nil)
        // Adaptive jitter buffer: start (or restart after an underrun) once the
        // pre-roll target is queued, so network jitter doesn't cause choppiness.
        if !player.isPlaying && rxCount >= preRollTarget { player.play() }
    }

    func stop() {
        if capturing { capEngine.inputNode.removeTap(onBus: 0); capEngine.stop(); capturing = false }
        if playing { player.stop(); playEngine.stop(); playing = false }
    }
}
