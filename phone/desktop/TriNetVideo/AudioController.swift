// AudioController.swift — capture -> 16kHz mono int16 PCM over UDP -> playback.
// Wire format: [0xFD 0xAD] + little-endian Int16 samples (~20ms per packet,
// fits one datagram — never fragmented).
//
// Two SEPARATE engines. A single engine with voice processing fused the mic
// input and speaker output into one VPIO unit that failed to initialize on
// this Mac (err -10875) — and because the graph was shared, the failure took
// the *playback* path down with it. Splitting them means playback (a plain
// player -> mixer -> speakers graph, no input) always starts, so incoming
// audio is heard even if mic capture can't start.
//
// Echo cancellation is now attempted on the CAPTURE engine only (see
// startCapture). The split is what makes that safe: a VPIO failure can cost us
// the mic, never the far end's audio, and it falls back to an unprocessed tap.
// It matters because both ends often sit on one desk, where our speaker feeds
// our own mic and the call howls. The log states AEC=ON/off — never assume it.
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
    // Raw outgoing (local mic) 16k Int16 PCM — mixed into the recording so it
    // captures both sides of the call, not just the remote party.
    var onTxPCM: ((Data) -> Void)?
    private var playing = false
    private var capturing = false
    private var rxCount = 0
    // Adaptive jitter buffer: grow the pre-roll target when inter-packet gaps
    // are erratic, shrink it when they're steady (packets ≈20ms apart).
    private var preRollTarget = 3
    private var lastRxAt: CFTimeInterval = 0
    private var jitterEwma: Double = 0.02
    private var txCount = 0
    private var opusTx = 0
    private var pcmTx = 0
    // Leftover samples between taps, so no frame is ever short (see the tap).
    private var txAccum = [Float]()
    // RED (audio redundancy): rolling send seq + the last Opus frame to piggyback.
    private var redSeq: UInt8 = 0
    private var redRing: [Data] = []        // last few Opus frames, newest first, for RED redundancy
    // Frames carried per packet: 2 survives an isolated loss, 3 survives a 2-loss burst.
    // Raised by the call's loss controller only while the far end is dropping frames.
    var redDepth = 2

    // RMS -> perceptual 0...1 (sqrt gives a livelier meter than raw RMS)
    static func level(_ sumSq: Float, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        let rms = (sumSq / Float(n)).squareRoot()
        return min(1, rms * 3) // gain so normal speech fills the meter
    }

    private var observers: [NSObjectProtocol] = []
    // Did echo cancellation actually engage? Reported, never assumed.
    private(set) var vpActive = false

    // Opus cuts each 20ms datagram from 642B to ~65B (256 -> ~25 kbps). RECEIVE
    // is always enabled; SENDING waits until both ends run this build, because a
    // pre-Opus peer hands any unknown magic straight to its H.264 decoder (the
    // exact way the FEC parity froze video). Flip once the phone is updated.
    static let opusEnabled = true
    private let opus = OpusCodec()

    func start() {
        redSeq = 0; redRing = []; redRecv = AudioREDReceiver()        // fresh RED state per call
        opusTx = 0; opusRx = 0; redRecovered = 0                      // fresh delivery stats per call
        startPlayback()
        startCapture()
        installObservers()
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

    // AVAudioEngine STOPS and drops installed taps when the graph is
    // reconfigured (default device switched, format changed, hardware added or
    // removed). Nothing observed that, so a reconfiguration killed the mic tap
    // for the rest of the call. Rebuild both graphs when it happens.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: capEngine, queue: .main) { [weak self] _ in
            NSLog("TRINET: capture engine configuration change -> rebuild")
            guard let self = self, self.capturing else { return }
            self.capEngine.inputNode.removeTap(onBus: 0)
            self.capEngine.stop()
            self.capturing = false
            self.startCapture()   // re-attempts AEC
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: playEngine, queue: .main) { [weak self] _ in
            NSLog("TRINET: playback engine configuration change -> restart")
            guard let self = self, self.playing else { return }
            self.player.stop()
            self.playEngine.stop()
            self.playing = false
            self.startPlayback()
            self.rxCount = 0   // re-arm the jitter pre-roll
        })
    }

    // Capture: mic tap -> convert to 16k mono -> packetize. If this can't start
    // (odd input device), playback still works.
    //
    // Echo cancellation: macOS had none, which is fine on headphones but howls the
    // moment both ends sit on one desk — the far end's voice comes out our speaker,
    // back into our mic, and round again. The original attempt fused mic and
    // speaker into one VPIO unit that failed (-10875) and took PLAYBACK down with
    // it, so it was abandoned. That risk is gone now that the engines are split:
    // voice processing here can only ever cost us the mic, never the far end's
    // audio, and a failure falls back to an unprocessed tap.
    private func startCapture() { startCapture(voiceProcessing: true) }

    private func startCapture(voiceProcessing: Bool) {
        guard !capturing else { return }
        capEngine.inputNode.removeTap(onBus: 0)   // idempotent on rebuild
        if voiceProcessing {
            do { try capEngine.inputNode.setVoiceProcessingEnabled(true) }
            catch {
                NSLog("TRINET: voice processing unavailable (\(error)) — capture without AEC")
                return startCapture(voiceProcessing: false)
            }
        } else {
            try? capEngine.inputNode.setVoiceProcessingEnabled(false)
        }
        // Read the format AFTER enabling VP: it re-tunes the input chain and a
        // stale snapshot is what silently kills the tap.
        let inFmt = capEngine.inputNode.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else {
            NSLog("TRINET: audio capture input format invalid (\(inFmt)) vp=\(voiceProcessing)")
            if voiceProcessing { return startCapture(voiceProcessing: false) }
            NSLog("TRINET: mic disabled — playback still on")
            return
        }
        vpActive = voiceProcessing
        converter = AVAudioConverter(from: inFmt, to: wireFormat)
        // Voice processing RE-TUNES the input layout: this 3-channel built-in mic
        // becomes a 9-channel node once VP is on. AVAudioConverter will not
        // downmix an unlabelled 9->1 and silently produced SILENCE instead — the
        // mic metered flat and Opus dutifully encoded it into 10-byte frames, so
        // the far end heard nothing while every counter looked healthy. Take the
        // first channel explicitly rather than trusting an implicit downmix.
        if inFmt.channelCount > 1 {
            converter?.channelMap = [0]
            NSLog("TRINET: input is \(inFmt.channelCount)ch (voice processing re-tuned it) — taking channel 0")
        }
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
            for i in 0..<n { let f = max(-1.0, min(1.0, ch[i])); sumSq += f * f }
            self.onTxLevel?(Self.level(sumSq, n))
            // Emit ONLY whole 20ms frames (320 samples @16k -> 642B raw).
            //
            // The tap hands us whatever the device I/O buffer is (~100ms), which is
            // not a multiple of 320, so slicing it directly left a short remainder
            // every time. Opus cannot encode a partial frame: it declined those and
            // the code silently fell back to raw PCM. Measured on a live call that
            // was [opus 2636 / pcm 364] — only 12% of packets, but 234KB of the
            // 405KB sent, so the fallback ate MORE bandwidth than all the Opus.
            // Carrying the remainder across taps makes every frame encodable.
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
                    // RED: carry this frame AND the previous one, so a single lost
                    // packet is reconstructed from the next (audio has no FEC).
                    self.redRing.insert(frame, at: 0)
                    if self.redRing.count > AudioRED.maxFrames { self.redRing.removeLast() }
                    let depth = max(1, min(self.redDepth, self.redRing.count))
                    pkt = Data([0xFD, 0xC0]); pkt.append(AudioRED.pack(seq: self.redSeq, frames: Array(self.redRing.prefix(depth))))
                    self.redSeq = self.redSeq &+ 1
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
                if let txpcm = self.onTxPCM { txpcm(raw) }   // recorder always gets raw PCM
            }
        }
        capEngine.prepare()
        do {
            try capEngine.start()
            capturing = true
            NSLog("TRINET: audio capture engine up in=\(Int(inFmt.sampleRate))Hz ch=\(inFmt.channelCount) AEC=\(voiceProcessing ? "ON" : "off")")
        } catch {
            capEngine.inputNode.removeTap(onBus: 0)
            if voiceProcessing {
                NSLog("TRINET: capture start failed with voice processing (\(error)) — retrying without AEC")
                capEngine.reset()
                return startCapture(voiceProcessing: false)
            }
            NSLog("TRINET: audio capture start failed: \(error) — mic disabled, playback still on")
        }
    }

    // One Opus frame off the wire (magic stripped) -> PCM -> normal playback.
    // Always accepted regardless of opusEnabled: receiving a better codec is
    // never the risky direction, only sending one is.
    func playOpus(_ payload: Data) {
        // payload = RED-wrapped: [seq][count][lens][frames]. Reconstruct any lost
        // packets from the redundant copies, then decode+play each in order.
        guard let (seq, carried) = AudioRED.parse(payload) else {
            opusDecodeFails += 1
            if opusDecodeFails <= 3 { NSLog("TRINET: opus RED parse failed (\(payload.count)B)") }
            return
        }
        let frames = redRecv.receive(seq: seq, frames: carried)
        if frames.count > 1 { redRecovered += frames.count - 1 }   // lost packet(s) reconstructed from the copies
        for frame in frames {
            guard let pcm = opus?.decode(frame) else {
                opusDecodeFails += 1
                if opusDecodeFails <= 3 { NSLog("TRINET: opus decode failed (\(frame.count)B)") }
                continue
            }
            opusRx += 1
            playPacket(pcm, wire: "OPUS \(frame.count)B")
        }
    }
    private var redRecv = AudioREDReceiver()
    private var opusRx = 0
    private var pcmRx = 0
    private var redRecovered = 0
    private var opusDecodeFails = 0
    // Aligned call stats, sampled together (never from mismatched per-N log cadences,
    // which is how a loopback delivery ratio read a nonsensical "110%"). sent/decoded
    // are cumulative Opus-frame counts; recovered is frames rebuilt from RED redundancy.
    var audioStats: (sent: Int, decoded: Int, recovered: Int) { (opusTx, opusRx, redRecovered) }

    // payload = Int16 LE samples (magic already stripped). `wire` says what
    // ACTUALLY arrived: this logs the DECODED size, so an Opus frame and a raw
    // packet both read as 640B here and the line could not tell them apart.
    func playPacket(_ d: Data, wire: String? = nil) {
        if wire == nil { pcmRx += 1 }
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
            NSLog("TRINET: audio rx #\(rxCount) wire=\(wire ?? "pcm \(d.count)B") [opus \(opusRx) / pcm \(pcmRx)] playing=\(player.isPlaying)")
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
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if capturing { capEngine.inputNode.removeTap(onBus: 0); capEngine.stop(); capturing = false }
        if playing { player.stop(); playEngine.stop(); playing = false }
    }
}
