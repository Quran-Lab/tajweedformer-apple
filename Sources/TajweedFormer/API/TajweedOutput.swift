import Foundation

/// What ran or will run the model: the CPU engine or the Neural Engine's build, and where the promotion stands.
/// Plain data, read from a Model, a Session or a chunk.
public struct TajweedBackend: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// The exact CPU engine: the same bits on every device.
        case cpu
        /// The CoreML build on the Neural Engine.
        case accelerator
    }

    public enum Stage: String, Sendable, Hashable {
        /// No accelerator here, or its promotion has not started.
        case cpu
        case downloading
        case compiling
        case testing
        /// The accelerator's build passed its tests: takes run on it.
        case promoted
        /// The build failed a stage or a take and is set aside; the CPU engine serves.
        case demoted
    }

    public let kind: Kind
    /// `cpu`, `coreml` or `coreml-compact` (the build keys of the model's manifest).
    public let name: String
    public let stage: Stage
    /// The stable reason code of a failed or demoted promotion (the codes of the incident reports), else nil.
    public let reason: String?

    public var description: String { reason.map { "\(name) (\(stage.rawValue): \($0))" } ?? "\(name) (\(stage.rawValue))" }

    static let cpu = TajweedBackend(kind: .cpu, name: "cpu", stage: .cpu, reason: nil)
}

/// One raw head of the network for a span of audio: `frames` rows of `classes` values, row major.
public struct TajweedHead: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A CTC head over the model's tokens: log-probabilities, greedy tokens apply.
        case ctc
        /// A per-frame attribute: class probabilities, or one logit (`boundary`, `conf`).
        case attribute
    }

    /// One of the twelve head names (`log_probs`, `inter1_log_probs`, ..., `conf`).
    public let name: String
    public let kind: Kind
    /// Milliseconds per frame: 40 or 20.
    public let frameMs: Int
    public let frames: Int
    /// Values per frame.
    public let classes: Int
    /// `frames * classes` values, frames first.
    public let values: [Float]
}

/// A token the model heard: a run of frames with the same non-blank top token.
public struct TajweedToken: Sendable, Hashable {
    public let id: Int
    /// The token's name in the model's vocabulary.
    public let name: String
    /// The start of the run's first frame, of its strongest frame and of its last frame, in milliseconds of the take.
    public let firstMs: Int
    public let peakMs: Int
    public let lastMs: Int
    /// The mean of the `conf` head over the run, 0 to 1; nil where `conf` is not there (greedy tokens of a raw head).
    public let confidence: Double?
}

/// The tokens between two word bars.
public struct TajweedWord: Sendable, Hashable {
    public let index: Int
    /// Indexes into the decoded layer's `tokens`.
    public let tokens: [Int]
    /// The token names joined by spaces.
    public let text: String
    public let firstMs: Int
    public let lastMs: Int
    /// The lowest token confidence; nil without the `conf` head.
    public let confidence: Double?
}

/// One 40 ms frame of `log_probs`: the top token, the runner-up and their margin.
public struct TajweedFrame: Sendable, Hashable {
    public let top1: Int
    public let top1LogProb: Float
    public let runnerUp: Int
    public let runnerUpLogProb: Float
    /// `top1LogProb - runnerUpLogProb`.
    public let margin: Double
    /// With `topK` set on the Session: the K best token ids of the frame, best first, and their log-probabilities.
    public let topK: [Int]
    public let topKLogProbs: [Float]
}

/// The decoded layer: what the model heard in the take so far, ready to show. No known text is involved.
public struct TajweedDecoded: Sendable, Hashable {
    /// The token names joined by single spaces.
    public let text: String
    public let tokens: [TajweedToken]
    public let words: [TajweedWord]
    public let frames: [TajweedFrame]
    /// How many leading tokens will not change in this take. It never decreases, except once after a
    /// `backendChanged` event that replaced chunks.
    public let settled: Int
    /// True on the last one of the take.
    public let isFinal: Bool

    /// The public shape of the engine's decoded layer. A token whose run reaches the last frame can still grow, so
    /// it is tentative until the take is final.
    init(_ d: DecodedTake, isFinal: Bool, topK: Int) {
        let ms = DecodedTake.frameMs
        let toks = d.tokens.map {
            TajweedToken(id: $0.id, name: $0.unit, firstMs: ms * $0.frame0, peakMs: ms * $0.peakFrame, lastMs: ms * $0.frame1,
                         confidence: $0.confidence)
        }
        tokens = toks
        words = d.words.map { w in
            TajweedWord(index: w.index, tokens: w.tokens, text: w.units.joined(separator: " "),
                        firstMs: w.tokens.first.map { toks[$0].firstMs } ?? 0, lastMs: w.tokens.last.map { toks[$0].lastMs } ?? 0,
                        confidence: w.confidence)
        }
        let ranked = topK > 0 ? d.ranked : nil
        var frames: [TajweedFrame] = []
        frames.reserveCapacity(d.frames.count)
        for (t, f) in d.frames.enumerated() {
            let entries = ranked?.entries(frame: t) ?? []
            frames.append(TajweedFrame(top1: f.top1, top1LogProb: f.top1LogProb, runnerUp: f.runnerUp, runnerUpLogProb: f.runnerUpLogProb,
                                       margin: f.margin, topK: entries.map(\.id), topKLogProbs: entries.map(\.value)))
        }
        self.frames = frames
        text = d.transcript
        var settled = d.tokens.count
        if !isFinal, let last = d.tokens.last, last.frame1 >= d.frames.count - 1 { settled -= 1 }
        self.settled = settled
        self.isFinal = isFinal
    }
}

/// Raw model output for a span of audio (a chunk, or the whole take from `finish()`): every selected head, and
/// greedy tokens. Plain data.
public struct TajweedHeads: Sendable, Hashable {
    let buffer: HeadsBuffer
    let vocabulary: Vocabulary
    let held: [HeadID]
    let topK: Int
    let isFinal: Bool

    init(_ buffer: HeadsBuffer, vocabulary: Vocabulary, selection: Set<HeadID>, topK: Int = 0, isFinal: Bool = false) {
        self.buffer = buffer
        self.vocabulary = vocabulary
        held = HeadID.allCases.filter { selection.contains($0) && !buffer[$0].isEmpty }
        self.topK = topK
        self.isFinal = isFinal
    }

    /// The names of the heads it holds, in the network's order.
    public var names: [String] { held.map(\.rawValue) }

    /// One raw head by its name; nil when these Heads do not hold it (it was not selected for the Session).
    public subscript(name: String) -> TajweedHead? {
        guard let h = held.first(where: { $0.rawValue == name }) else { return nil }
        let values = buffer[h]
        return TajweedHead(name: name, kind: h.kind == .logSoftmax ? .ctc : .attribute, frameMs: h.frameMs,
                           frames: values.count / h.width, classes: h.width, values: values)
    }

    /// The greedy tokens of a CTC head: repeats merged, blank removed, with the times of each run. Empty for a head
    /// these Heads do not hold and for an attribute head.
    public func greedy(_ name: String = "log_probs") -> [TajweedToken] {
        guard let h = self[name], h.kind == .ctc, h.classes > 0 else { return [] }
        var out: [TajweedToken] = []
        var t = 0
        func best(_ f: Int) -> (id: Int, value: Float) {
            var id = 0
            var v = -Float.infinity
            let row = f * h.classes
            for k in 0..<h.classes where h.values[row + k] > v { v = h.values[row + k]; id = k }
            return (id, v)
        }
        while t < h.frames {
            let a = best(t)
            if a.id == vocabulary.blank { t += 1; continue }
            var e = t, peak = t
            var peakValue = a.value
            while e + 1 < h.frames {
                let n = best(e + 1)
                guard n.id == a.id else { break }
                e += 1
                if n.value > peakValue { peakValue = n.value; peak = e }
            }
            out.append(TajweedToken(id: a.id, name: vocabulary.symbol(a.id), firstMs: h.frameMs * t, peakMs: h.frameMs * peak,
                                    lastMs: h.frameMs * e, confidence: nil))
            t = e + 1
        }
        return out
    }

    /// The decoded layer of exactly these Heads (for the take's Heads from `finish()`: the final one). It needs
    /// `log_probs`, which every Session computes.
    public func decoded() -> TajweedDecoded {
        var d = DecodedTake(heads: buffer, vocabulary: vocabulary)
        if topK > 0 { d.ranked = try? TajweedRanking.rank(buffer.logProbs, head: .logProbs, k: topK, names: vocabulary.symbols) }
        return TajweedDecoded(d, isFinal: isFinal, topK: topK)
    }
}

/// One chunk of a take as it streams.
public struct TajweedChunk: Sendable, Hashable {
    /// The chunk's number in the take, from 0. After a `backendChanged` event the chunks from its `fromChunk` on
    /// come again with the same indexes: replace what you kept for them.
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    /// The chunk's first 40 ms frame in the take.
    public let firstFrame: Int
    /// The Backend that ran it.
    public let backend: TajweedBackend
    /// True when the chunk holds speech frames.
    public let speech: Bool
    /// The Heads of this chunk only.
    public let heads: TajweedHeads
    /// The decoded layer of the take so far.
    public let decoded: TajweedDecoded
}

/// What happened to a take, on `session.events`.
public enum TajweedEvent: Sendable, Hashable {
    public enum Cause: String, Sendable, Hashable {
        /// A call, or another app took the audio: the take is paused and no audio is read meanwhile.
        case interruption
        /// Headphones in or out, another input: the microphone was reopened and the take goes on.
        case routeChange
    }

    public enum EndReason: Sendable, Hashable {
        /// `endOnSilenceMs` of silence after speech.
        case silence
        /// The app left the foreground.
        case background
        /// The page lost visibility (the web SDK; never on Apple platforms).
        case hidden
        /// An interruption that cannot be resumed.
        case interrupted
        /// The clip or the samples of `listen(from:)` ran out.
        case sourceEnd
        /// The take reached 20 minutes of audio, the most a take holds.
        case limit
        case error(TajweedError)
    }

    /// The first speech frame after silence.
    case speechStarted(atMs: Int)
    /// Silence after speech: 1500 ms of it, or `endOnSilenceMs` when that option is set (the take then finishes here).
    case speechEnded(atMs: Int, silenceMs: Int)
    case interrupted(Cause)
    /// An interruption ended and the take goes on.
    case resumed
    /// The Backend of this take changed; the chunks from `fromChunk` on were replaced and come again.
    case backendChanged(backend: TajweedBackend, fromChunk: Int)
    /// The take ended without the app's `finish()`: the last chunk has `isFinal`, `chunks` ends, and `finish()`
    /// returns the take's Heads.
    case ended(EndReason)
}
