// CallRecorder.swift — records the incoming call (decoded video + incoming
// 16k mono PCM audio) to a .mov in ~/Movies via AVAssetWriter. Video sizing is
// locked from the first frame; audio is wrapped into CMSampleBuffers.
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

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
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // Timestamp built from a monotonic counter, not Date (kept simple).
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
        NSLog("TRINET: recording → \(out.path)")
    }

    // Called per decoded frame (main thread from the decoder callback).
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
            // Audio track: 16k mono AAC. Added before startWriting alongside video.
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

    // Incoming 16k mono Int16 PCM → CMSampleBuffer → audio track. Only writes
    // once the video track has opened the session (started == true).
    private var audioAppendCount = 0
    func appendAudio(_ pcm: Data) {
        guard recording, started, let aInp = audioInput else {
            return
        }
        guard aInp.isReadyForMoreMediaData else { return }
        let n = pcm.count / 2
        guard n > 0 else { return }
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
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeN, sampleBufferOut: &sb)
        if let s = sb {
            let ok = aInp.append(s)
            audioAppendCount += 1
            if audioAppendCount <= 2 || audioAppendCount % 100 == 0 {
                NSLog("TRINET: rec audio append #\(audioAppendCount) n=\(n) ok=\(ok)")
            }
        } else {
            NSLog("TRINET: rec audio CMSampleBufferCreateReady failed status=\(st)")
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
