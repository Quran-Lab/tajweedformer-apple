internal import COpus
import Foundation

/// The Opus settings sessions are shared with, in one place. The defaults are the measured choice
/// of the opus-bench study (libopus 1.6.1): the lowest bitrate at which every objective score is
/// indistinguishable from an inaudible change of the source, about 89 MB per hour of recitation.
struct OpusSettings: Sendable, Hashable {
    enum Application: Int32, Sendable, Hashable {
        /// `OPUS_APPLICATION_AUDIO`: no voice high-pass, the whole band as it is.
        case audio = 2049
        /// `OPUS_APPLICATION_VOIP`.
        case voip = 2048
        /// `OPUS_APPLICATION_RESTRICTED_LOWDELAY`.
        case restrictedLowDelay = 2051
    }

    enum Bandwidth: Int32, Sendable, Hashable {
        case narrowband = 1101, mediumband = 1102, wideband = 1103, superwideband = 1104, fullband = 1105
    }

    enum Signal: Int32, Sendable, Hashable {
        /// `OPUS_AUTO`: the encoder's own speech/music detector.
        case auto = -1000
        case voice = 3001
        case music = 3002
    }

    /// The rate Opus codes at; the sharing path always encodes at it.
    static let codedRate = 48_000

    var application = Application.audio
    var bitrate = 192_000
    /// 0 (fastest) to 10 (best).
    var complexity = 10
    var vbr = true
    /// Constrained VBR; unconstrained lets bright or reverberant passages take the bits they need.
    var constrainedVBR = false
    var bandwidth = Bandwidth.fullband
    var signal = Signal.auto
    /// 2.5, 5, 10, 20, 40 or 60.
    var frameMs = 20.0

    static let shared = OpusSettings()

    /// Samples per packet at 48 kHz.
    var packetFrames: Int { Int(48 * frameMs) }
    /// Packets on a full Ogg page: about one second (50 at 20 ms).
    var pagePackets: Int { max(1, Int((1000 / frameMs).rounded())) }
}

/// An Opus encoder: PCM in at `sampleRate`, Opus packets out. The Ogg writer and the outbox depend
/// only on this, not on the implementation behind it.
protocol OpusEncoding: AnyObject {
    init(sampleRate: Int, channels: Int, settings: OpusSettings) throws(RecognizerError)
    /// The encoder's lookahead in 48 kHz samples (OpusHead pre-skip).
    var preSkip: Int { get }
    /// Encodes interleaved samples; returns the packets completed so far (possibly none).
    func encode(_ pcm: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [Data]
    /// Encodes what is buffered and the lookahead, padded with silence to whole packets; returns
    /// the last packets. The encoder cannot be used afterwards.
    func flush() throws(RecognizerError) -> [Data]
    /// The granule position of the last Ogg page: the pre-skip plus the input in 48 kHz samples,
    /// which trims the padding `flush()` adds.
    var finalGranulePosition: Int64 { get }
}

/// Opus from libopus 1.6.1 (the `COpus` target, float build with NEON), set up per
/// `OpusSettings`. Non-finite input samples are coded as silence. Not thread safe: one instance
/// from one thread or actor at a time.
final class LibOpusEncoder: OpusEncoding {
    static let rates: Set<Int> = [8000, 12000, 16000, 24000, 48000]

    let sampleRate: Int
    let channels: Int
    let settings: OpusSettings
    /// Samples per channel per packet at the input rate.
    let frameSize: Int
    let preSkip: Int
    /// Input samples per channel consumed so far (at the input rate).
    private(set) var samplesIn: Int64 = 0
    /// Non-finite input samples replaced with 0 so far.
    private(set) var nonFiniteSamples: Int64 = 0

    var finalGranulePosition: Int64 { Int64(preSkip) + samplesIn * 48_000 / Int64(sampleRate) }

    private let enc: OpaquePointer
    private var frame: [Float]
    private var filled = 0
    private var packet = [UInt8](repeating: 0, count: 4_000)
    private var finished = false

    init(sampleRate: Int, channels: Int, settings: OpusSettings) throws(RecognizerError) {
        guard Self.rates.contains(sampleRate) else {
            throw .unsupportedAudioFormat("Opus encodes 8, 12, 16, 24 or 48 kHz, not \(sampleRate) Hz")
        }
        guard channels == 1 || channels == 2 else { throw .unsupportedAudioFormat("Opus: 1 or 2 channels, not \(channels)") }
        let size = Double(sampleRate) * settings.frameMs / 1000
        guard [2.5, 5, 10, 20, 40, 60].contains(settings.frameMs), size == size.rounded() else {
            throw .unsupportedAudioFormat("Opus frames are 2.5, 5, 10, 20, 40 or 60 ms, not \(settings.frameMs)")
        }
        var err: Int32 = 0
        guard let e = opus_encoder_create(opus_int32(sampleRate), Int32(channels), settings.application.rawValue, &err), err == OPUS_OK else {
            throw .storageFailed("the Opus encoder is not available (\(err))")
        }
        let requests: [(String, Int32, Int32)] = [
            ("bitrate", OPUS_SET_BITRATE_REQUEST, Int32(settings.bitrate)),
            ("complexity", OPUS_SET_COMPLEXITY_REQUEST, Int32(settings.complexity)),
            ("vbr", OPUS_SET_VBR_REQUEST, settings.vbr ? 1 : 0),
            ("vbr constraint", OPUS_SET_VBR_CONSTRAINT_REQUEST, settings.constrainedVBR ? 1 : 0),
            ("bandwidth", OPUS_SET_BANDWIDTH_REQUEST, settings.bandwidth.rawValue),
            ("signal", OPUS_SET_SIGNAL_REQUEST, settings.signal.rawValue),
            ("lsb depth", OPUS_SET_LSB_DEPTH_REQUEST, 24),
            ("inband fec", OPUS_SET_INBAND_FEC_REQUEST, 0),
            ("dtx", OPUS_SET_DTX_REQUEST, 0),
        ]
        var lookahead: opus_int32 = 0
        for (name, request, value) in requests where copus_encoder_set(e, request, value) != OPUS_OK {
            opus_encoder_destroy(e)
            throw .storageFailed("the Opus encoder refused its \(name) (\(value))")
        }
        guard copus_encoder_get(e, OPUS_GET_LOOKAHEAD_REQUEST, &lookahead) == OPUS_OK else {
            opus_encoder_destroy(e)
            throw .storageFailed("the Opus encoder has no lookahead")
        }
        enc = e
        self.sampleRate = sampleRate
        self.channels = channels
        self.settings = settings
        frameSize = Int(size)
        frame = [Float](repeating: 0, count: frameSize * channels)
        // OpusHead pre-skip is in 48 kHz samples whatever the input rate (312 at 48 kHz)
        preSkip = Int(lookahead) * 48_000 / sampleRate
    }

    deinit { opus_encoder_destroy(enc) }

    /// A GET ctl read back from the encoder (`OPUS_GET_..._REQUEST`), for the tests.
    func get(_ request: Int32) -> Int32? {
        var v: opus_int32 = 0
        return copus_encoder_get(enc, request, &v) == OPUS_OK ? v : nil
    }

    func encode(_ pcm: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [Data] {
        if finished { throw .storageFailed("the Opus encoder was flushed") }
        var out: [Data] = []
        guard let base = pcm.baseAddress else { return out }
        let perFrame = frame.count
        var i = 0
        while i < pcm.count {
            let n = min(perFrame - filled, pcm.count - i)
            var bad = 0
            frame.withUnsafeMutableBufferPointer { f in
                for k in 0..<n {
                    let v = base[i + k]
                    if v.isFinite { f[filled + k] = v } else { f[filled + k] = 0; bad += 1 }
                }
            }
            nonFiniteSamples += Int64(bad)
            filled += n
            i += n
            if filled == perFrame { out.append(try encodeFrame()) }
        }
        samplesIn += Int64(pcm.count / channels)
        return out
    }

    func flush() throws(RecognizerError) -> [Data] {
        if finished { throw .storageFailed("the Opus encoder was flushed") }
        finished = true
        var out: [Data] = []
        // the samples still owed: what is buffered plus the lookahead held inside the codec
        var owed = filled / channels + preSkip * sampleRate / 48_000
        while owed > 0 {
            frame.withUnsafeMutableBufferPointer { f in
                for k in filled..<f.count { f[k] = 0 }
            }
            filled = frame.count
            out.append(try encodeFrame())
            owed -= frameSize
        }
        return out
    }

    private func encodeFrame() throws(RecognizerError) -> Data {
        let (enc, frameSize) = (self.enc, self.frameSize)
        let n = frame.withUnsafeBufferPointer { f in
            packet.withUnsafeMutableBufferPointer { p in
                opus_encode_float(enc, f.baseAddress!, Int32(frameSize), p.baseAddress!, opus_int32(p.count))
            }
        }
        filled = 0
        guard n > 0 else { throw .storageFailed("the Opus encoder failed (\(n))") }
        return Data(packet[0..<Int(n)])
    }
}

enum OpusVersion {
    /// "libopus 1.6.1".
    static var string: String { String(cString: opus_get_version_string()) }
}
