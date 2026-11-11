import Foundation
import TajweedFormerCore

// What the SDK gives, one shape across Android, Apple, Web and Native: the raw heads and the decoded layer (what
// the model heard; no known text is involved). The public types over them are in API/.

/// One output head of the network.
enum HeadID: String, CaseIterable, Sendable, Hashable, Codable {
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
    enum Kind: String, Sendable { case logSoftmax, softmax, logit }

    /// Values per frame.
    var width: Int { HeadsBuffer.layout.first { $0.name == rawValue }!.width }
    /// Milliseconds per frame: 40 for the CTC heads, 20 for the others.
    var frameMs: Int { HeadsBuffer.layout.first { $0.name == rawValue }!.ms }

    var kind: Kind {
        switch self {
        case .logProbs, .inter1LogProbs, .inter4LogProbs, .idLogProbs, .timingLogProbs: return .logSoftmax
        case .gem, .tafkheem, .ghunna, .qalqalah, .face: return .softmax
        case .boundary, .conf: return .logit
        }
    }

    /// The name of each value of a frame: tokens.txt's units for the 38-wide heads (the timing head's 0 is the
    /// pause state), the classes for the attribute heads, one name for the logits.
    func classNames(vocabulary: Vocabulary) -> [String] {
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

    /// The six heads a Session hands out when nothing else is asked for.
    static let defaults: Set<HeadID> = [.logProbs, .inter1LogProbs, .timingLogProbs, .gem, .qalqalah, .conf]

    /// The heads every take computes and keeps whatever the app selected: the decoded layer reads `log_probs` and
    /// `conf`, and speech and silence are read from `log_probs` and `timing_log_probs` (`SpeechTracker`). A kept head
    /// the app did not select is not handed to the app.
    static let kept: Set<HeadID> = [.logProbs, .conf, .timingLogProbs]

    /// The CTC heads, in the network's order.
    static let ctc: [HeadID] = [.logProbs, .inter1LogProbs, .inter4LogProbs, .idLogProbs, .timingLogProbs]

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

/// Which heads a recognizer hands out per chunk. The default is the six of `HeadID.defaults`; `.all` is every head.
/// The take always keeps `HeadID.kept` (`log_probs` and `conf` for the decoded layer, `timing_log_probs` for speech
/// and silence). The exact CPU engine computes only the selected heads and those three (zf_tajweed.h lazy heads), so
/// another head nobody asked for costs nothing; the CoreML package computes all twelve, with the same API.
struct HeadSelection: Sendable, Hashable {
    var heads: Set<HeadID>

    init(_ heads: Set<HeadID>) { self.heads = heads }

    static let `default` = HeadSelection(HeadID.defaults)
    static let all = HeadSelection(Set(HeadID.allCases))

    /// The default plus `extra`.
    static func adding(_ extra: [HeadID]) -> HeadSelection { HeadSelection(HeadSelection.default.heads.union(extra)) }

    func contains(_ h: HeadID) -> Bool { heads.contains(h) }

    /// The engine's head mask for a take with this selection: the selected heads and log_probs (always computed).
    /// The CoreML package computes every head anyway; the API is the same on both.
    var engineMask: UInt32 { heads.union([.logProbs]).reduce(UInt32(0)) { $0 | $1.engineBit } }
}

extension HeadsBuffer {
    /// A typed head (empty when it was not kept).
    subscript(head: HeadID) -> [Float] { self[head.rawValue] }

    /// Value `k` of frame `t` of a head.
    func value(_ head: HeadID, frame t: Int, _ k: Int = 0) -> Float { self[head][t * head.width + k] }

    /// The top value's index of each frame of a head (the lowest index on ties): the greedy ids of a CTC head. Empty
    /// when the head was not kept.
    func top1(_ head: HeadID) -> [Int] {
        let v = self[head]
        let w = head.width
        guard w > 0, !v.isEmpty else { return [] }
        var out = [Int](repeating: 0, count: v.count / w)
        for f in out.indices {
            var best = 0
            for k in 1..<w where v[f * w + k] > v[f * w + best] { best = k }
            out[f] = best
        }
        return out
    }

    /// Only `keep`'s heads (the others emptied); the frame counts stay.
    func keeping(_ keep: Set<HeadID>) -> HeadsBuffer {
        var out = self
        for h in HeadID.allCases where !keep.contains(h) { out.set(h.rawValue, []) }
        return out
    }
}

/// One chunk of a take as it streams: its index and the selected heads.
struct RawChunk: Sendable, Hashable {
    let index: Int
    /// Milliseconds of audio from the start of the take to the start of this chunk's frames.
    let startMs: Int
    let heads: HeadsBuffer
    /// Which of the chunk's 40 ms frames are active (`SpeechTracker.active`): from `log_probs` and
    /// `timing_log_probs` as the engine gave them, also when the app did not select the timing head.
    let active: [Bool]
    /// True when a chunk with this `index` was handed out before in this take (2.0.2): the CPU engine confirmed that
    /// the Neural Engine missed speech there, and the take continues on the CPU from the first such chunk. Replace what
    /// you kept or drew for this index, and drop what you kept for later indexes (they come again in order).
    let replaces: Bool

    init(index: Int, startMs: Int, heads: HeadsBuffer, replaces: Bool = false, active: [Bool]? = nil) {
        self.index = index
        self.startMs = startMs
        self.heads = heads
        self.replaces = replaces
        // without the engine's own chunk: what the handed-out heads say
        self.active = active ?? SpeechTracker.active(logProbs: heads.top1(.logProbs), timing: heads.top1(.timingLogProbs))
    }
}

/// The decoded layer: what the model heard, from `log_probs` (and `conf` for confidences), without a known text.
/// For display, practice feedback and analysis. The public form is `TajweedDecoded`.
struct DecodedTake: Sendable, Hashable {
    /// Each 40 ms frame of log_probs: the top token and the runner-up (lowest id on ties), and their margin.
    struct Frame: Sendable, Hashable {
        let top1: Int
        let top1LogProb: Float
        let runnerUp: Int
        let runnerUpLogProb: Float
        /// top1LogProb - runnerUpLogProb, as the engine computes it.
        let margin: Double

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
        let v = HeadsBuffer.vocab
        guard frames > 0, logProbs.count >= frames * v else { return [] }
        var out = [ZfTajweedTop2](repeating: ZfTajweedTop2(), count: frames)
        let n = logProbs.withUnsafeBufferPointer { lp in
            out.withUnsafeMutableBufferPointer { zf_tajweed_top2(lp.baseAddress, Int32(frames), Int32(v), $0.baseAddress) }
        }
        guard n > 0 else { return [] }
        return out.prefix(Int(n)).map(Frame.init)
    }

    /// A greedy CTC token: a run of equal non-blank top-1 frames.
    struct Token: Sendable, Hashable {
        let id: Int
        let unit: String
        /// First and last 40 ms frame of the run (inclusive).
        let frame0: Int, frame1: Int
        let startMs: Int, endMs: Int
        /// The run's frame with the largest top-1 log-prob (first on ties); the values below are at it.
        let peakFrame: Int
        let logProb: Float
        let runnerUp: Int
        let runnerUpLogProb: Float
        let margin: Double
        /// Mean of sigmoid(conf) over the run's 20 ms frames; nil without the conf head.
        let confidence: Double?
    }

    /// Tokens between word boundaries ("|"). V4 rarely emits "|", so for a known ayah use the tajweed layer's words.
    struct Word: Sendable, Hashable {
        let index: Int
        /// Indexes into `tokens`.
        let tokens: [Int]
        let units: [String]
        let startMs: Int, endMs: Int
        /// The lowest token confidence; nil without the conf head.
        let confidence: Double?
        /// The lowest token margin.
        let margin: Double
    }

    /// Per 40 ms frame the top token and the runner-up (top-K at k = 2), kept as the convenient view.
    let frames: [Frame]
    /// log_probs ranked to the depth asked for (`TajweedRecognizer.decoded(topK:)`, 2 by default; 38 is the whole
    /// list), from the engine.
    var ranked: TajweedRanking?
    let tokens: [Token]
    let words: [Word]
    /// The token units joined by single spaces.
    let transcript: String

    static let frameMs = 40

    /// The decoded layer of `h`; `frames` is the engine's top-2 of the same log_probs when the caller has it (the
    /// exact engine's stream keeps it), else it is computed by the engine here.
    init(heads h: HeadsBuffer, vocabulary: Vocabulary) { self.init(heads: h, vocabulary: vocabulary, frames: nil) }

    init(heads h: HeadsBuffer, vocabulary: Vocabulary, frames given: [Frame]?) {
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
