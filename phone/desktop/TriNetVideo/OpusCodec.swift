// OpusCodec.swift — 16k mono wire PCM <-> Opus, 20ms frames.
//
// Why: the call sent RAW PCM — 16000 Hz x 16 bit = 256 kbps in each direction.
// Over Wi-Fi that is merely wasteful; over the radio mesh it is fatal, because
// the BPSK link is ~1 Mbps raw (4 MSPS / SPS 4 = 1 Msym/s) and half-duplex, so
// two-way raw audio alone (512 kbps) exceeds the whole budget before a single
// video frame. Opus at 24 kbps measures 63 B per 20ms frame here — a 10x cut
// that also drops an audio datagram under the mesh's 70-byte fragment payload,
// so it never fragments.
//
// Apple ships Opus in AudioToolbox; no third-party dependency.
import Foundation
import AVFoundation
import AudioToolbox

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
