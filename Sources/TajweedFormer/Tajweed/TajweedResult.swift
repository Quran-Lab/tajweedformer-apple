import Foundation

/// The verdicts of one scored take (zf_tajweed.h's result, field for field). Decisions come from these, never
/// from the greedy text.
public struct TajweedResult: Sendable, Hashable {
    /// One scored site: the expected unit, the best single-unit alternative of its class, the per-head and fused
    /// LLRs (log P(alternative) - log P(expected)), the threshold in force and whether it is flagged.
    public struct Site: Sendable, Hashable {
        public let cls: TajweedClass
        public let status: TajweedStatus
        /// Index into the expected tokens (an insertion: the unit it follows, -1 at the start).
        public let position: Int
        public let word: Int
        /// tj3 id expected (nil for an insertion) and the best alternative (nil for a deletion).
        public let expected: Int?
        public let alternative: Int?
        public let llrFinal: Double
        public let llrInter1: Double
        /// a * llrFinal + (1 - a) * llrInter1, `a` from calibration's fusion for the class.
        public let llr: Double
        public let threshold: Double
        public let flagged: Bool
        /// 40 ms frames the expected unit holds on the best path; nil when unknown.
        public let frames: ClosedRange<Int>?
    }

    /// One madd long vowel counted from the timing head.
    public struct Madd: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable { case none, fixed2, muttasil, free, lazim }
        public let position: Int, word: Int, token: Int
        public let kind: Kind
        public let status: TajweedStatus
        /// Held frames over the take's median short-vowel frames.
        public let ratio: Double
        /// The verdict count: 2, 4 or 6.
        public let count: Int
        /// A smooth count for display only (never for verdicts).
        public let displayCount: Double
        public let allowed: ClosedRange<Int>
        public let flagged: Bool
        /// 20 ms frames.
        public let frames: ClosedRange<Int>?
    }

    /// A letter feature: qalqalah (mean P(burst) after the letter) or gemination (mean P(held) over it).
    /// flagged = the feature is missing (score below the threshold) and the check is on.
    public struct Letter: Sendable, Hashable {
        public let position: Int, word: Int, token: Int
        public let status: TajweedStatus
        public let score: Double
        public let threshold: Double
        public let flagged: Bool
        public let frames: ClosedRange<Int>?
    }

    public let surah: Int, ayah: Int
    public let sites: [Site]
    public let madd: [Madd]
    public let qalqalah: [Letter]
    public let gemination: [Letter]
    /// Median short-vowel frames (the madd unit), nil when the take has too few short vowels for counts.
    public let shortVowelFrames: Double?
    /// The settings the take was scored with.
    public let settings: EffectiveTajweed
    /// The scorer's own JSON (the reference scorer's verdict layout), for logging and support.
    public let json: String
    /// Where the engine's resolution of the settings differs from the SDK's (an API 1 engine cannot take the
    /// int8/fp32 backend or madd/qalqalah/gemination presets); empty when they agree.
    public let settingsDifferences: [String]

    /// One word of the ayah (the engine's `site.word`): the v4_bench "rel" word score, the largest fused LLR of any
    /// scored single-unit alternative inside the word (every class, enabled or not), with the site it came from, and
    /// the word decision in force (`settings.word`).
    public struct Word: Sendable, Hashable {
        public let index: Int
        /// Nil when the word has no scored site.
        public let score: Double?
        /// Index into `sites` of the alternative that gave the score (the first on ties).
        public let evidence: Int?
        public let threshold: Double?
        /// Nil when word flags are not reported (no word threshold in force).
        public let flagged: Bool?
        /// 40 ms frame times of the word's sites on the best path; nil when none has frames.
        public let startMs: Int?
        public let endMs: Int?
        /// The best edit inside the word (from the engine's word scorer): its class, the expected token, the token put in
        /// (nil for a deletion) and its per-head LLRs; nil when the engine's word check is off.
        public let bestClass: TajweedClass?
        public let bestExpected: Int?
        public let bestAlternative: Int?
        public let llrFinal: Double?
        public let llrInter1: Double?
        /// Indexes of the word's flagged items, so a UI can mark it.
        public let flaggedSites: [Int]
        public let flaggedMadd: [Int]
        public let flaggedQalqalah: [Int]
        public let flaggedGemination: [Int]
    }

    /// Every word of the ayah, in order.
    public internal(set) var words: [Word] = []

    public var flagged: [Site] { sites.filter(\.flagged) }

    /// The words from the sites and the word setting (API_LAYERS section 3: an aggregation of the engine's numbers,
    /// no new arithmetic).
    /// One word as the engine scored it (zf_tajweed.h API 3 `ZfTajweedWord`).
    struct EngineWord: Sendable {
        let word: Int
        let score: Double?
        let threshold: Double
        let flagged: Bool
        let cls: TajweedClass?
        let expected: Int?
        let alternative: Int?
        let llrFinal: Double
        let llrInter1: Double
    }

    static func makeWords(sites: [Site], madd: [Madd], qalqalah: [Letter], gemination: [Letter], count: Int,
                          setting: EffectiveTajweed.Word, engine: [EngineWord] = []) -> [Word] {
        let byWord = Dictionary(engine.map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })
        let n = max(count, (sites.map(\.word) + madd.map(\.word) + qalqalah.map(\.word) + gemination.map(\.word) + engine.map(\.word))
            .max().map { $0 + 1 } ?? 0)
        return (0..<n).map { w in
            var best: Int?
            var lo: Int?, hi: Int?
            for (i, s) in sites.enumerated() where s.word == w {
                if best == nil || s.llr > sites[best!].llr { best = i }
                if let f = s.frames {
                    lo = min(lo ?? f.lowerBound, f.lowerBound)
                    hi = max(hi ?? f.upperBound, f.upperBound)
                }
            }
            let e = byWord[w]
            let score = e.map { $0.score } ?? best.map { sites[$0].llr }
            return Word(index: w, score: score, evidence: best,
                        threshold: e.map { $0.threshold } ?? (setting.enabled ? setting.threshold : nil),
                        flagged: e.map { $0.flagged } ?? setting.flags(score), startMs: lo.map { 40 * $0 }, endMs: hi.map { 40 * ($0 + 1) },
                        bestClass: e?.cls, bestExpected: e?.expected, bestAlternative: e?.alternative,
                        llrFinal: e?.llrFinal, llrInter1: e?.llrInter1,
                        flaggedSites: sites.indices.filter { sites[$0].word == w && sites[$0].flagged },
                        flaggedMadd: madd.indices.filter { madd[$0].word == w && madd[$0].flagged },
                        flaggedQalqalah: qalqalah.indices.filter { qalqalah[$0].word == w && qalqalah[$0].flagged },
                        flaggedGemination: gemination.indices.filter { gemination[$0].word == w && gemination[$0].flagged })
        }
    }
}

/// What a score needs besides the heads: the ayah and every settings layer, so the scorer resolves them itself (the
/// engine's own resolution is then compared with the SDK's: `TajweedResult.settingsDifferences`).
public struct TajweedScoreRequest: Sendable {
    public var surah: Int, ayah: Int
    public var settings: EffectiveTajweed
    public var options: TajweedOptions
    public var remote: JSONValue?
    public var debugBuild: Bool
    public init(surah: Int, ayah: Int, settings: EffectiveTajweed, options: TajweedOptions = .init(), remote: JSONValue? = nil,
                debugBuild: Bool = false) {
        self.surah = surah; self.ayah = ayah; self.settings = settings; self.options = options; self.remote = remote
        self.debugBuild = debugBuild
    }
}

/// Scores heads against an ayah's expected sequence with calibration.json and the settings in force.
public protocol TajweedScoring: Sendable {
    func score(heads: TajweedHeads, _ request: TajweedScoreRequest) throws(RecognizerError) -> TajweedResult
}

/// Used when the folder cannot be scored (no expected table, a scorer that refused it): every score throws why.
public struct UnavailableTajweedScorer: TajweedScoring {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public func score(heads: TajweedHeads, _ request: TajweedScoreRequest) throws(RecognizerError) -> TajweedResult {
        throw .tajweedUnavailable(reason)
    }
}
