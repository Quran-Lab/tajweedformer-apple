@preconcurrency import AVFoundation
import Foundation
import TajweedFormerCore

/// Audio into the model's format: 16 kHz, mono, Float in -1...1.
enum AudioFormat {
    static let modelRate = 16_000.0

    /// The samples of a PCM buffer, downmixed to mono (the channels averaged, in channel order),
    /// with the buffer's sample rate. Float32 and Int16 buffers, interleaved or not.
    static func samples(from buffer: AVAudioPCMBuffer) throws(RecognizerError) -> (samples: [Float], rate: Double) {
        let (ch, rate) = try channels(from: buffer)
        return (downmix(ch), rate)
    }

    /// A PCM buffer's channels as Float (Int16 scaled by 1/32768), one array per channel.
    static func channels(from buffer: AVAudioPCMBuffer) throws(RecognizerError) -> (channels: [[Float]], rate: Double) {
        let fmt = buffer.format
        let n = Int(buffer.frameLength), ch = Int(fmt.channelCount)
        guard ch > 0 else { throw .unsupportedAudioFormat("no channels") }
        let interleaved = fmt.isInterleaved && ch > 1
        let stride = interleaved ? ch : 1
        var out = [[Float]](repeating: [], count: ch)
        switch fmt.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { throw .unsupportedAudioFormat("no float data") }
            for c in 0..<ch {
                let p = interleaved ? data[0] + c : data[c]
                out[c] = (0..<n).map { p[$0 * stride] }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { throw .unsupportedAudioFormat("no int16 data") }
            for c in 0..<ch {
                let p = interleaved ? data[0] + c : data[c]
                out[c] = (0..<n).map { Float(p[$0 * stride]) / 32768 }
            }
        default:
            throw .unsupportedAudioFormat("sample format \(fmt.commonFormat.rawValue); use Float32 or Int16")
        }
        return (out, fmt.sampleRate)
    }

    /// Mono: the channels summed in channel order into zero, then scaled by 1/count when there is
    /// more than one. The one downmix: a live session and a file read back both go through it, so
    /// the same channels give the same bits.
    static func downmix(_ channels: [[Float]]) -> [Float] {
        guard let n = channels.first?.count else { return [] }
        var out = [Float](repeating: 0, count: n)
        for c in channels {
            for i in 0..<n { out[i] += c[i] }
        }
        if channels.count > 1 {
            let k = 1 / Float(channels.count)
            for i in 0..<n { out[i] *= k }
        }
        return out
    }

    /// A sample on the 24-bit grid a recording stores (n / 2^23, n in -2^23 ... 2^23 - 1): rounded
    /// to nearest, clipped to the range, non-finite as 0. Every such value is exact in Float32 and
    /// survives 24-bit Apple Lossless unchanged, so a recording session feeds the model exactly
    /// the samples its file decodes to. Int16 audio and 24-bit converters are already on the grid.
    @inline(__always)
    static func quantize24(_ x: Float) -> Float {
        guard x.isFinite else { return 0 }
        let v = (Double(x) * 8_388_608).rounded()
        return Float(Int32(max(-8_388_608, min(8_388_607, v)))) / 8_388_608
    }

    /// A whole audio file, mono, at its own rate.
    static func read(file url: URL) throws(RecognizerError) -> (samples: [Float], rate: Double) {
        let f: AVAudioFile
        do {
            f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw .unsupportedAudioFormat("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let frames = AVAudioFrameCount(f.length)
        guard frames > 0 else { return ([], f.processingFormat.sampleRate) }
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: frames) else {
            throw .unsupportedAudioFormat("cannot allocate \(frames) frames")
        }
        do {
            try f.read(into: buf)
        } catch {
            throw .unsupportedAudioFormat("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try samples(from: buf)
    }
}

/// Converts one session's audio to 16 kHz with the engine's deterministic resampler
/// (zf_resampler_*, a rational polyphase FIR in plain scalar IEEE arithmetic): the same samples on
/// every device and OS version, like the rest of the pipeline, and the same bits however the audio
/// is split into pieces. 16 kHz passes through untouched. Rates: 8000, 11025, 16000, 22050, 24000,
/// 32000, 44100 and 48000 Hz.
final class SampleRateConverter {
    static let rates: Set<Int> = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000]

    let inputRate: Double
    private let resampler: OpaquePointer?
    private var out: [Float] = []

    init(inputRate: Double) throws(RecognizerError) {
        let r = Int(inputRate)
        guard Double(r) == inputRate, Self.rates.contains(r) else {
            throw .unsupportedAudioFormat("\(inputRate) Hz; supported: \(Self.rates.sorted().map(String.init).joined(separator: ", "))")
        }
        self.inputRate = inputRate
        if r == 16_000 {
            resampler = nil
        } else {
            guard let p = zf_resampler_create(Int32(r)) else { throw .unsupportedAudioFormat("\(r) Hz") }
            resampler = p
        }
    }

    deinit { if let resampler { zf_resampler_destroy(resampler) } }

    /// Samples at `inputRate` in, samples at 16 kHz out.
    func process(_ samples: [Float]) -> [Float] {
        guard let resampler else { return samples }
        let cap = Int(zf_resampler_max_out(resampler, Int32(samples.count)))
        if out.count < cap { out = [Float](repeating: 0, count: cap) }
        let n = samples.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { zf_resampler_push(resampler, i.baseAddress, Int32(i.count), $0.baseAddress, Int32(cap)) }
        }
        return n > 0 ? Array(out[0..<Int(n)]) : []
    }

    /// The end of the stream: whatever the filter still holds.
    func flush() -> [Float] {
        guard let resampler else { return [] }
        let cap = Int(zf_resampler_max_out(resampler, 0))
        if out.count < cap { out = [Float](repeating: 0, count: cap) }
        let n = out.withUnsafeMutableBufferPointer { zf_resampler_finish(resampler, $0.baseAddress, Int32(cap)) }
        zf_resampler_reset(resampler)
        return n > 0 ? Array(out[0..<Int(n)]) : []
    }
}
