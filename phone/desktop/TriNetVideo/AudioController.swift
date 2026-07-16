// AudioController.swift — capture -> 16kHz mono int16 PCM over UDP -> playback.
// Wire format: [0xFD 0xAD] + little-endian Int16 samples (~20ms per packet,
// fits one datagram — never fragmented). Voice processing gives echo
// cancellation where the platform supports it.
import Foundation
import AVFoundation

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
        // Voice processing (echo cancellation) fuses I/O into one VPIO unit
        // that can fail to init on Macs with a multichannel/aggregate default
        // device (err -10875). Try it, and on failure rebuild without it.
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
    }
}
