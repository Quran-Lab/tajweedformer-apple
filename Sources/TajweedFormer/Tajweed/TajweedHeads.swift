import Foundation

/// Every head of the V4 network for a take (or one chunk), row major, frames first. Two frame rates: `n40`
/// frames at 40 ms (the CTC heads) and `n20 = 2 * n40` frames at 20 ms, aligned (20 ms frames 2k and 2k + 1 lie in
/// 40 ms frame k). The same layout as the engine's ZfTajweedHeads (zf_tajweed.h), so heads from the Neural Engine
/// can be scored by the engine's scorer.
public struct TajweedHeads: Sendable, Hashable {
    public static let vocab = 38

    public private(set) var n40 = 0
    public private(set) var n20 = 0
    /// [n40, 38] final CTC, log-softmax over tj3 (blank 0).
    public internal(set) var logProbs: [Float] = []
    /// [n40, 38] stack-1 InterCTC, log-softmax: listens more to the sound (consonant mistakes).
    public internal(set) var inter1LogProbs: [Float] = []
    /// [n40, 38] stack-4 InterCTC, log-softmax (diagnostic).
    public internal(set) var inter4LogProbs: [Float] = []
    /// [n20, 38] identity CTC, log-softmax.
    public internal(set) var idLogProbs: [Float] = []
    /// [n20, 38] H-time chain, log-softmax; index 0 is the pause state (durations, madd counts).
    public internal(set) var timingLogProbs: [Float] = []
    /// [n20, 2] softmax: single, held (shadda).
    public internal(set) var gem: [Float] = []
    /// [n20, 3] softmax: thin, heavy, low heavy.
    public internal(set) var tafkheem: [Float] = []
    /// [n20, 5] softmax: none, plain, geminate, ikhfa, idgham with ghunna.
    public internal(set) var ghunna: [Float] = []
    /// [n20, 3] softmax: none, sughra, kubra.
    public internal(set) var qalqalah: [Float] = []
    /// [n20, 4] softmax: none, imala, tasheel, sakt.
    public internal(set) var face: [Float] = []
    /// [n20] logit: a unit starts here (apply a sigmoid).
    public internal(set) var boundary: [Float] = []
    /// [n20] logit: the frame's label is truthful (apply a sigmoid).
    public internal(set) var conf: [Float] = []

    public init() {}

    /// The head names of the network (README_heads.txt), with their width per frame and frame rate in ms.
    public static let layout: [(name: String, width: Int, ms: Int)] = [
        ("log_probs", 38, 40), ("inter1_log_probs", 38, 40), ("inter4_log_probs", 38, 40),
        ("id_log_probs", 38, 20), ("timing_log_probs", 38, 20), ("gem", 2, 20), ("attr_tafkheem", 3, 20),
        ("attr_ghunna", 5, 20), ("attr_qalqalah", 3, 20), ("attr_face", 4, 20), ("boundary", 1, 20), ("conf", 1, 20),
    ]

    /// A head by its network name.
    public subscript(name: String) -> [Float] {
        switch name {
        case "log_probs": return logProbs
        case "inter1_log_probs": return inter1LogProbs
        case "inter4_log_probs": return inter4LogProbs
        case "id_log_probs": return idLogProbs
        case "timing_log_probs": return timingLogProbs
        case "gem": return gem
        case "attr_tafkheem": return tafkheem
        case "attr_ghunna": return ghunna
        case "attr_qalqalah": return qalqalah
        case "attr_face": return face
        case "boundary": return boundary
        case "conf": return conf
        default: return []
        }
    }

    mutating func set(_ name: String, _ v: [Float]) {
        switch name {
        case "log_probs": logProbs = v
        case "inter1_log_probs": inter1LogProbs = v
        case "inter4_log_probs": inter4LogProbs = v
        case "id_log_probs": idLogProbs = v
        case "timing_log_probs": timingLogProbs = v
        case "gem": gem = v
        case "attr_tafkheem": tafkheem = v
        case "attr_ghunna": ghunna = v
        case "attr_qalqalah": qalqalah = v
        case "attr_face": face = v
        case "boundary": boundary = v
        case "conf": conf = v
        default: break
        }
    }

    /// Appends one chunk's heads (the take grows chunk by chunk).
    public mutating func append(_ c: TajweedHeads) {
        for (name, _, _) in Self.layout { set(name, self[name] + c[name]) }
        n40 += c.n40
        n20 += c.n20
    }

    /// Keeps the first `k` frames at 40 ms (and 2k at 20 ms) of every head: the take before chunk n is the frames of
    /// its first n chunks.
    mutating func truncate(n40 k: Int) {
        guard k >= 0, k < n40 else { return }
        for (name, width, ms) in Self.layout {
            let v = self[name]
            if !v.isEmpty { set(name, Array(v.prefix((ms == 40 ? k : 2 * k) * width))) }
        }
        n40 = k
        n20 = 2 * k
    }

    /// One chunk from per-head arrays (each already [frames, width]); the frame counts come from log_probs.
    init(chunk: [String: [Float]]) {
        for (name, _, _) in Self.layout { set(name, chunk[name] ?? []) }
        n40 = (chunk["log_probs"]?.count ?? 0) / Self.vocab
        n20 = 2 * n40
    }

    /// Greedy CTC on log_probs (blank 0, repeats merged): what the model heard. For display only; tajweed
    /// decisions come from the scorer, never from this text.
    public var greedy: [Int] {
        var out: [Int] = [], prev = -1
        for f in 0..<n40 {
            var best = 0
            var bv = -Float.infinity
            for v in 0..<Self.vocab where logProbs[f * Self.vocab + v] > bv { bv = logProbs[f * Self.vocab + v]; best = v }
            if best != prev && best != 0 { out.append(best) }
            prev = best
        }
        return out
    }

    /// True when every value of every head is finite.
    public var isFinite: Bool { Self.layout.allSatisfy { self[$0.name].allSatisfy(\.isFinite) } }
}
