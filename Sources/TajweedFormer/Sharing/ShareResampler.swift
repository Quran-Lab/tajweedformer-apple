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
        try run(final: false, sink)
    }

    /// The converter's tail. The resampler cannot be used afterwards.
    func flush(_ sink: (UnsafeBufferPointer<Float>) throws(RecognizerError) -> Void) throws(RecognizerError) {
        guard !ended else { return }
        ended = true
        input.frameLength = 0
        try run(final: true, sink)
    }

    private func run(final: Bool, _ sink: (UnsafeBufferPointer<Float>) throws(RecognizerError) -> Void) throws(RecognizerError) {
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
            if output.frameLength > 0 {
                try sink(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            // .haveData: the output buffer filled up and more is waiting
            if status != .haveData { break }
        }
    }
}
