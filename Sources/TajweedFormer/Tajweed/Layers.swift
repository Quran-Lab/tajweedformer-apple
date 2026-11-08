import Foundation
import TajweedFormerCore

// SDK 2.0.0's three layers, one shape across Android, Apple, Web and Native: the raw heads, the
// decoded layer (no known text needed), and the tajweed layer (`TajweedResult`, a known surah:ayah).

/// One output head of the network.
public enum TajweedHead: String, CaseIterable, Sendable, Hashable, Codable {
    case logProbs = "log_probs"
    case inter1LogProbs = "inter1_log_probs"
    case inter4LogProbs = "inter4_log_probs"
    case idLogProbs = "id_log_probs"
    case timingLogProbs = "timing_log_probs"
    case gem
    case tafkheem = "attr_tafkheem"
    case ghunna = "attr_ghunna"
    case qalqalah = "attr_qalqalah"
    case face = "attr_face"
    case boundary
    case conf

    /// What the values are.
    public enum Kind: String, Sendable { case logSoftmax, softmax, logit }

    /// Values per frame.
    public var width: Int { TajweedHeads.layout.first { $0.name == rawValue }!.width }
    /// Milliseconds per frame: 40 for the CTC heads, 20 for the others.
    public var frameMs: Int { TajweedHeads.layout.first { $0.name == rawValue }!.ms }

    public var kind: Kind {
        switch self {
        case .logProbs, .inter1LogProbs, .inter4LogProbs, .idLogProbs, .timingLogProbs: return .logSoftmax
        case .gem, .tafkheem, .ghunna, .qalqalah, .face: return .softmax
        case .boundary, .conf: return .logit
        }
    }

    /// The name of each value of a frame: tokens.txt's units for the 38-wide heads (the timing head's 0 is the
    /// pause state), the classes for the attribute heads, one name for the logits.
    public func classNames(vocabulary: Vocabulary) -> [String] {
        switch self {
        case .logProbs, .inter1LogProbs, .inter4LogProbs, .idLogProbs, .timingLogProbs: return vocabulary.symbols
        case .gem: return ["single", "held"]
        case .tafkheem: return ["thin", "heavy", "low_heavy"]
        case .ghunna: return ["none", "plain", "geminate", "ikhfa", "idgham"]
        case .qalqalah: return ["none", "sughra", "kubra"]
        case .face: return ["none", "imala", "tasheel", "sakt"]
        case .boundary: return ["unit_starts"]
        case .conf: return ["truthful"]
        }
    }

    /// The heads the scorer reads (kept for every take whatever the app selected).
    public static let scorer: Set<TajweedHead> = [.logProbs, .inter1LogProbs, .timingLogProbs, .gem, .qalqalah]

    /// The head's bit in the engine's head mask (zf_tajweed.h `ZF_TAJWEED_HEAD_*`, bit 0 log_probs to bit 11 conf, in
    /// the order of the network's outputs).
    var engineBit: UInt32 {
        switch self {
        case .logProbs: return 1 << 0
        case .inter1LogProbs: return 1 << 1
        case .inter4LogProbs: return 1 << 2
        case .idLogProbs: return 1 << 3
        case .timingLogProbs: return 1 << 4
        case .gem: return 1 << 5
        case .tafkheem: return 1 << 6
        case .ghunna: return 1 << 7
        case .qalqalah: return 1 << 8
        case .face: return 1 << 9
        case .boundary: return 1 << 10
        case .conf: return 1 << 11
        }
    }
}

/// Which heads a recognizer hands out per chunk. The default is what the scorer needs plus `conf` (the decoded
/// layer's confidence); `.all` is every head. The take always keeps the scorer's heads, so scoring works whatever
/// is selected. The exact CPU engine computes only the selected heads and the scorer's (zf_tajweed.h API 3 lazy heads),
/// so a head nobody asked for costs nothing; the CoreML package computes all twelve, with the same API.
public struct HeadSelection: Sendable, Hashable {
    public var heads: Set<TajweedHead>

    public init(_ heads: Set<TajweedHead>) { self.heads = heads }

    public static let `default` = HeadSelection(TajweedHead.scorer.union([.conf]))
    public static let all = HeadSelection(Set(TajweedHead.allCases))

    /// The default plus `extra`.
    public static func adding(_ extra: [TajweedHead]) -> HeadSelection { HeadSelection(HeadSelection.default.heads.union(extra)) }

    public func contains(_ h: TajweedHead) -> Bool { heads.contains(h) }

    /// The engine's head mask for a take with this selection: the selected heads, the scorer's (always kept) and
    /// log_probs (always computed). The CoreML package computes every head anyway; the API is the same on both.
    var engineMask: UInt32 { heads.union(TajweedHead.scorer).union([.logProbs]).reduce(UInt32(0)) { $0 | $1.engineBit } }
}

extension TajweedHeads {
    /// A typed head (empty when it was not kept).
    public subscript(head: TajweedHead) -> [Float] { self[head.rawValue] }

    /// Value `k` of frame `t` of a head.
    public func value(_ head: TajweedHead, frame t: Int, _ k: Int = 0) -> Float { self[head][t * head.width + k] }

    /// Only `keep`'s heads (the others emptied); the frame counts stay.
    public func keeping(_ keep: Set<TajweedHead>) -> TajweedHeads {
        var out = self
        for h in TajweedHead.allCases where !keep.contains(h) { out.set(h.rawValue, []) }
        return out
    }
}

/// One chunk of a take as it streams: its index and the selected heads.
public struct TajweedChunk: Sendable, Hashable {
    public let index: Int
    /// Milliseconds of audio from the start of the take to the start of this chunk's frames.
    public let startMs: Int
    public let heads: TajweedHeads
}

/// The decoded layer: what the model heard, from `log_probs` (and `conf` for confidences), without a known text.
/// For display, practice feedback and analysis; tajweed decisions come from the scorer (`TajweedResult`).
public struct DecodedTake: Sendable, Hashable {
    /// Each 40 ms frame of log_probs: the top token and the runner-up (lowest id on ties), and their margin.
    public struct Frame: Sendable, Hashable {
        public let top1: Int
        public let top1LogProb: Float
        public let runnerUp: Int
        public let runnerUpLogProb: Float
        /// top1LogProb - runnerUpLogProb, as the engine computes it.
        public let margin: Double

        init(top1: Int, top1LogProb: Float, runnerUp: Int, runnerUpLogProb: Float, margin: Double) {
            self.top1 = top1; self.top1LogProb = top1LogProb; self.runnerUp = runnerUp
            self.runnerUpLogProb = runnerUpLogProb; self.margin = margin
        }

        init(_ t: ZfTajweedTop2) {
            self.init(top1: Int(t.token), top1LogProb: t.log_prob, runnerUp: Int(t.runner_up), runnerUpLogProb: t.runner_up_log_prob,
                      margin: Double(t.margin))
        }
    }

    /// Per-frame top-1 and runner-up of log-probs from any source, from the engine (`zf_tajweed_top2`: one scan of
    /// each row, ties to the lower id, the greedy decode's argmax).
    static func top2(_ logProbs: [Float], frames: Int) -> [Frame] {
        let v = TajweedHeads.vocab
        guard frames > 0, logProbs.count >= frames * v else { return [] }
        var out = [ZfTajweedTop2](repeating: ZfTajweedTop2(), count: frames)
        let n = logProbs.withUnsafeBufferPointer { lp in
            out.withUnsafeMutableBufferPointer { zf_tajweed_top2(lp.baseAddress, Int32(frames), Int32(v), $0.baseAddress) }
        }
        guard n > 0 else { return [] }
        return out.prefix(Int(n)).map(Frame.init)
    }

    /// A greedy CTC token: a run of equal non-blank top-1 frames.
    public struct Token: Sendable, Hashable {
        public let id: Int
        public let unit: String
        /// First and last 40 ms frame of the run (inclusive).
        public let frame0: Int, frame1: Int
        public let startMs: Int, endMs: Int
        /// The run's frame with the largest top-1 log-prob (first on ties); the values below are at it.
        public let peakFrame: Int
        public let logProb: Float
        public let runnerUp: Int
        public let runnerUpLogProb: Float
        public let margin: Double
        /// Mean of sigmoid(conf) over the run's 20 ms frames; nil without the conf head.
        public let confidence: Double?
    }

    /// Tokens between word boundaries ("|"). V4 rarely emits "|", so for a known ayah use the tajweed layer's words.
    public struct Word: Sendable, Hashable {
        public let index: Int
        /// Indexes into `tokens`.
        public let tokens: [Int]
        public let units: [String]
        public let startMs: Int, endMs: Int
        /// The lowest token confidence; nil without the conf head.
        public let confidence: Double?
        /// The lowest token margin.
        public let margin: Double
    }

    /// Per 40 ms frame the top token and the runner-up (top-K at k = 2), kept as the convenient view.
    public let frames: [Frame]
    /// log_probs ranked to the depth asked for (`TajweedRecognizer.decoded(topK:)`, 2 by default; 38 is the whole
    /// list), from the engine.
    public internal(set) var ranked: TajweedRanking?
    public let tokens: [Token]
    public let words: [Word]
    /// The token units joined by single spaces.
    public let transcript: String

    public static let frameMs = 40

    /// The decoded layer of `h`; `frames` is the engine's top-2 of the same log_probs when the caller has it (the
    /// exact engine's stream keeps it), else it is computed by the engine here.
    public init(heads h: TajweedHeads, vocabulary: Vocabulary) { self.init(heads: h, vocabulary: vocabulary, frames: nil) }

    init(heads h: TajweedHeads, vocabulary: Vocabulary, frames given: [Frame]?) {
        let blank = 0, bar = 1
        let frames = given.flatMap { $0.count == h.n40 ? $0 : nil } ?? Self.top2(h.logProbs, frames: h.n40)
        let conf = h.conf
        var tokens: [Token] = []
        var t = 0
        while t < frames.count {
            let a = frames[t].top1
            if a == blank { t += 1; continue }
            var e = t
            while e + 1 < frames.count && frames[e + 1].top1 == a { e += 1 }
            var pk = t
            for k in (t + 1)..<(e + 1) where frames[k].top1LogProb > frames[pk].top1LogProb { pk = k }
            var c: Double?
            if conf.count >= 2 * (e + 1) {
                var s = 0.0
                for k in (2 * t)..<(2 * e + 2) { s += 1 / (1 + exp(-Double(conf[k]))) }
                c = s / Double(2 * (e - t + 1))
            }
            let f = frames[pk]
            tokens.append(Token(id: a, unit: vocabulary.symbol(a), frame0: t, frame1: e, startMs: Self.frameMs * t,
                                endMs: Self.frameMs * (e + 1), peakFrame: pk, logProb: f.top1LogProb, runnerUp: f.runnerUp,
                                runnerUpLogProb: f.runnerUpLogProb, margin: f.margin, confidence: c))
            t = e + 1
        }
        var words: [Word] = []
        var cur: [Int] = []
        func close() {
            guard !cur.isEmpty else { return }
            let toks = cur.map { tokens[$0] }
            let cs = toks.map(\.confidence)
            words.append(Word(index: words.count, tokens: cur, units: toks.map(\.unit), startMs: toks[0].startMs,
                              endMs: toks[toks.count - 1].endMs,
                              confidence: cs.contains(where: { $0 == nil }) ? nil : cs.compactMap { $0 }.min(),
                              margin: toks.map(\.margin).min()!))
        }
        for (i, tk) in tokens.enumerated() {
            if tk.id == bar { close(); cur = [] } else { cur.append(i) }
        }
        close()
        self.frames = frames
        self.tokens = tokens
        self.words = words
        transcript = tokens.map(\.unit).joined(separator: " ")
    }
}
