@preconcurrency import AVFoundation
import Foundation

/// Mono float PCM at any rate to 48 kHz for the sharing encoder: AVAudioConverter at its best
/// quality (the mastering algorithm, `AVAudioQuality.max`). Streaming: output follows input with
/// the converter's own short delay, and `flush()` returns the tail, so the whole output is the
/// input's length at 48 kHz. Only the shared copy goes through it; recognition resamples the
/// original input with the engine's own resampler. Buffers are reused, so memory stays flat.
final class ShareResampler {
    let inputRate: Double
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private var input: AVAudioPCMBuffer
    private var output: AVAudioPCMBuffer
    private var ended = false
    /// The input's frames so far, and the output's given to the sinks.
    private var inputFrames: Int64 = 0
    private var outputFrames: Int64 = 0

    init(inputRate: Double) throws(RecognizerError) {
        guard inputRate >= 8_000, inputRate <= 384_000,
              let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(OpusSettings.codedRate), channels: 1, interleaved: false),
              let c = AVAudioConverter(from: inF, to: outF),
              let i = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: 4_800),
              let o = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: 4_800) else {
            throw .unsupportedAudioFormat("cannot resample \(inputRate) Hz to 48 kHz")
        }
        c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // .normal: the converter assumes silence before the first sample, so its output is aligned
        // with the input (no leading delay) and as long as the input once flushed
        c.primeMethod = .normal
        self.inputRate = inputRate
        converter = c
        inFormat = inF
        input = i
        output = o
    }

    /// Resamples `samples` and hands the 48 kHz output to `sink` (in one or more pieces).
    func process(_ samples: UnsafeBufferPointer<Float>, _ sink: (UnsafeBufferPointer<Float>) throws(RecognizerError) -> Void) throws(RecognizerError) {
        guard !ended, samples.count > 0 else { return }
        if Int(input.frameCapacity) < samples.count {
            guard let b = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw .storageFailed("out of memory resampling")
            }
            input = b
        }
        input.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        input.frameLength = AVAudioFrameCount(samples.count)
        inputFrames += Int64(samples.count)
        try run(final: false, limit: nil, sink)
    }

    /// The output's length for the input so far when it is upsampled: the input's length at 48 kHz, rounded down (what
    /// the converter gives on macOS); nil from 48 kHz up, where the converter's own end is whole on every platform.
    var upsampledLength: Int64? {
        let rate = Double(OpusSettings.codedRate)
        guard inputRate < rate else { return nil }
        if inputRate == inputRate.rounded() { return inputFrames * Int64(OpusSettings.codedRate) / Int64(inputRate) }
        return Int64((Double(inputFrames) * rate / inputRate).rounded(.down))
    }

    /// The converter's tail. The resampler cannot be used afterwards.
    ///
    /// SDK 4.0.5: when it upsamples, the input is followed by silence until the output reaches the input's length at
    /// 48 kHz, and nothing past that length is given; then the stream ends. iOS's converter (the mastering algorithm)
    /// ends its stream without the filter's tail when it upsamples by about 2 or more: 4 s at 16 kHz gave 699 samples
    /// short of 4 s at 48 kHz (14.6 ms), 229 at 22.05 kHz, 126 at 24 kHz, 2424 at 8 kHz, on the iPhone (iOS 26.6.1) and
    /// the Simulator alike, while macOS gives the whole. The output was aligned; only its end was missing.
    func flush(_ sink: (UnsafeBufferPointer<Float>) throws(RecognizerError) -> Void) throws(RecognizerError) {
        guard !ended else { return }
        ended = true
        let target = upsampledLength
        if let target {
            // a second of silence at most: the converters' tails are a few hundred input frames
            let block = 256
            var padded = 0
            while outputFrames < target, padded < Int(inputRate) {
                input.floatChannelData![0].update(repeating: 0, count: block)
                input.frameLength = AVAudioFrameCount(block)
                try run(final: false, limit: target, sink)
                padded += block
            }
        }
        input.frameLength = 0
        try run(final: true, limit: target, sink)
    }

    /// Converts what `input` holds (once) and hands the output to `sink`, no more than `limit` frames in all.
    private func run(final: Bool, limit: Int64?, _ sink: (UnsafeBufferPointer<Float>) throws(RecognizerError) -> Void) throws(RecognizerError) {
        // the input block runs synchronously inside convert(to:error:withInputFrom:), on this thread
        final class Once: @unchecked Sendable { var given = false }
        let once = Once()
        let input = self.input
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if !once.given, input.frameLength > 0 {
                    once.given = true
                    status.pointee = .haveData
                    return input
                }
                status.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error { throw .storageFailed("resampling to 48 kHz failed: \(error?.localizedDescription ?? "")") }
            var n = Int(output.frameLength)
            if let limit { n = min(n, Int(max(0, limit - outputFrames))) }
            if n > 0 {
                outputFrames += Int64(n)
                try sink(UnsafeBufferPointer(start: output.floatChannelData![0], count: n))
            }
            // .haveData: the output buffer filled up and more is waiting
            if status != .haveData { break }
        }
    }
}
