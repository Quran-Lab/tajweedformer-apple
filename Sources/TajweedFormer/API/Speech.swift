import Foundation

/// Speech and silence from the model's own output (SDK 3.0.0, the shared speech vectors): ONE definition for the
/// events, `chunk.speech` and the telemetry's `speech_s` and `silence_s`.
///
/// - A 40 ms frame is ACTIVE when the greedy id of `log_probs` is non-blank on it, or the greedy id of
///   `timing_log_probs` is non-blank on one of its two 20 ms frames. A speech frame is an active frame, a silence
///   frame an inactive one: there is no padding around a token.
/// - Why both heads: the CTC head shows a sound on one or a few frames and blank while the sound is held; the timing
///   head holds the sound's id for as long as it sounds. A held vowel is ordinary recitation (a madd of six counts
///   lasts well over two seconds), so silence measured on `log_probs` alone ends takes inside recitation. Every
///   take therefore computes `timing_log_probs`, whatever heads the app selected.
/// - A chunk holds speech when it has an active frame.
/// - The events are decided frame by frame as frames arrive (`step`); the timing rule is all in that one function.
struct SpeechTracker: Sendable {
    static let frameMs = 40
    /// The 20 ms frames of the timing head in one 40 ms frame.
    static let timingFramesPerFrame = 2
    /// The silence that ends speech when the Session names none.
    static let defaultWindowMs = 1500
    /// The values `endOnSilenceMs` takes when it is on.
    static let windowRangeMs = 500...60_000

    /// The inactive frames in a row that end speech: the window rounded up to whole frames (38 for 1500 ms).
    let windowFrames: Int
    /// The last active frame of the take so far.
    private(set) var lastActive: Int?
    private(set) var speaking = false

    /// - Parameter windowMs: `endOnSilenceMs` when the Session has it, else 1500.
    init(windowMs: Int = SpeechTracker.defaultWindowMs) {
        windowFrames = max(1, (windowMs + Self.frameMs - 1) / Self.frameMs)
    }

    /// Which 40 ms frames are active, from the greedy ids of `log_probs` (one per frame) and of `timing_log_probs`
    /// (two per frame; a timing frame that does not exist counts as blank).
    static func active(logProbs: [Int], timing: [Int], blank: Int = 0) -> [Bool] {
        var out = [Bool](repeating: false, count: logProbs.count)
        for f in out.indices {
            if logProbs[f] != blank {
                out[f] = true
                continue
            }
            for k in 0..<timingFramesPerFrame {
                let j = timingFramesPerFrame * f + k
                if j < timing.count, timing[j] != blank { out[f] = true }
            }
        }
        return out
    }

    /// One frame: the event it raises, if any.
    ///
    /// `speechStarted` at an active frame while the state is silence, at that frame's start. `speechEnded` while the
    /// state is speech, when `windowFrames` inactive frames in a row have arrived after the last active frame L: with
    /// frame L + windowFrames. It is dated at the end of the last active frame, 40 * (L + 1), and names the silence
    /// as 40 * windowFrames.
    mutating func step(active: Bool, frame f: Int) -> TajweedEvent? {
        if active {
            lastActive = f
            if !speaking {
                speaking = true
                return .speechStarted(atMs: Self.frameMs * f)
            }
            return nil
        }
        guard speaking, let last = lastActive, f == last + windowFrames else { return nil }
        speaking = false
        return .speechEnded(atMs: Self.frameMs * (last + 1), silenceMs: Self.frameMs * windowFrames)
    }

    /// The frames of a chunk, from `firstFrame` on: whether the chunk holds speech, and its events.
    mutating func feed(_ active: [Bool], firstFrame: Int) -> (speech: Bool, events: [TajweedEvent]) {
        var events: [TajweedEvent] = []
        var speech = false
        for (k, a) in active.enumerated() {
            if a { speech = true }
            if let e = step(active: a, frame: firstFrame + k) { events.append(e) }
        }
        return (speech, events)
    }

    mutating func reset() {
        lastActive = nil
        speaking = false
    }

    /// The speech frames of a finished take: its active frames.
    static func speechFrames(_ active: [Bool]) -> Int { active.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// The greedy tokens of a CTC head over a take: its runs of equal non-blank ids.
    static func tokens(_ top1: [Int], blank: Int = 0) -> Int {
        var n = 0
        var previous = blank
        for id in top1 {
            if id != blank && id != previous { n += 1 }
            previous = id
        }
        return n
    }
}
