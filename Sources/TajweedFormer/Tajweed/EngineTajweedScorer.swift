import ZipformerCore
import Foundation

/// The engine's tajweed scorer (zf_tajweed.h API 2, in ZipformerCore.xcframework from the pinned engine): double
/// precision with a fixed summation order, built without FMA contraction, so the same heads give the same verdicts as
/// on Android, the web and the engine's own conformance (it reproduces the reference vectors:
/// TajweedScorerVectorTests).
///
/// The model is opened for scoring only (`load_engine = 0`): calibration.json, tokens.txt and the expected table of
/// the folder. A score resolves the settings itself from the request's layers (the portal block, the app's options,
/// the debug flag) and reports where its resolution differs from the SDK's.
public final class EngineTajweedScorer: TajweedScoring, @unchecked Sendable {
    // a ZfTajweedModel: immutable after open, shareable across threads (zf_tajweed.h, Threads)
    private let handle: OpaquePointer
    public let context: String

    public init(directory: URL, context: String) throws(RecognizerError) {
        var o = zf_tajweed_open_default_options()
        o.load_engine = 0
        var err: UnsafePointer<CChar>?
        let m: OpaquePointer? = context.withCString { c in
            o.context = c
            return directory.path.withCString { zf_tajweed_model_open($0, &o, &err) }
        }
        guard let m else {
            throw .tajweedUnavailable("zf_tajweed_model_open(\(context)): \(err.map { String(cString: $0) } ?? "failed")")
        }
        handle = m
        self.context = context
    }

    public convenience init(model: TajweedModel, context: String) throws(RecognizerError) {
        try self.init(directory: model.directory, context: context)
    }

    deinit { zf_tajweed_model_close(handle) }

    /// The expected tj3 tokens of an ayah (the canonical reading), from the folder's table.
    public func expectedTokens(surah: Int, ayah: Int) -> [Int] {
        var p: UnsafePointer<Int32>?
        let n = zf_tajweed_expected_tokens(handle, Int32(surah), Int32(ayah), &p)
        guard n > 0, let p else { return [] }
        return (0..<Int(n)).map { Int(p[$0]) }
    }

    public func ayahCount(surah: Int) -> Int { Int(zf_tajweed_ayah_count(handle, Int32(surah))) }

    public func score(heads: TajweedHeads, _ r: TajweedScoreRequest) throws(RecognizerError) -> TajweedResult {
        guard let cfg = zf_tajweed_config_create(handle) else { throw .tajweedUnavailable("zf_tajweed_config_create") }
        defer { zf_tajweed_config_destroy(cfg) }
        var diffs: [String] = []
        zf_tajweed_config_set_debug_build(cfg, r.debugBuild ? 1 : 0)
        // API 2: which calibration thresholds apply (int8 for the exact engine's heads, fp32 for CoreML / NPU / server)
        if zf_tajweed_config_set_backend(cfg, r.settings.backend.rawValue) != 0 { diffs.append("backend \(r.settings.backend.rawValue) refused") }
        if let remote = r.remote, remote.object != nil,
           let data = try? JSONSerialization.data(withJSONObject: remote.any) {
            _ = data.withUnsafeBytes { b in
                zf_tajweed_config_set_remote(cfg, b.baseAddress!.assumingMemoryBound(to: CChar.self), b.count)
            }
        }
        let o = r.options
        if let p = o.preset, zf_tajweed_config_set_preset(cfg, p.rawValue) != 0 { diffs.append("app preset \(p.rawValue) refused") }
        for (k, v) in o.overrides.sorted(by: { $0.key < $1.key }) {
            let rc: Int32
            switch v {
            case .preset(let p): rc = zf_tajweed_config_set_class_preset(cfg, k, p.rawValue)
            case .threshold(let t): rc = zf_tajweed_config_set_class_threshold(cfg, k, t)
            }
            if rc != 0 { diffs.append("app override \(k) refused by the engine") }
        }
        for (k, on) in o.checks.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if zf_tajweed_config_set_check(cfg, k.rawValue, on ? 1 : 0) != 0 { diffs.append("app check \(k.rawValue) refused") }
        }
        if let c = o.context, zf_tajweed_config_set_context(cfg, c) != 0 { diffs.append("app context \(c) refused") }
        if let w = o.word {
            let rc: Int32
            switch w {
            case .custom(let t): rc = zf_tajweed_config_set_word_threshold(cfg, t)
            case .off: rc = zf_tajweed_config_set_check(cfg, "word", 0)
            default: rc = zf_tajweed_config_set_word_preset(cfg, w.name)
            }
            if rc != 0 { diffs.append("app word level \(w.name) refused by the engine") }
        }
        diffs += compare(cfg, r.settings)

        // the heads, contiguous, for the call
        var owned: [UnsafeMutablePointer<Float>] = []
        defer { owned.forEach { $0.deallocate() } }
        func pin(_ a: [Float]) -> UnsafePointer<Float>? {
            guard !a.isEmpty else { return nil }
            let p = UnsafeMutablePointer<Float>.allocate(capacity: a.count)
            p.initialize(from: a, count: a.count)
            owned.append(p)
            return UnsafePointer(p)
        }
        var h = ZfTajweedHeads()
        h.n40 = Int32(heads.n40); h.n20 = Int32(heads.n20); h.vocab = Int32(TajweedHeads.vocab)
        h.log_probs = pin(heads.logProbs); h.inter1_log_probs = pin(heads.inter1LogProbs)
        h.inter4_log_probs = pin(heads.inter4LogProbs); h.id_log_probs = pin(heads.idLogProbs)
        h.timing_log_probs = pin(heads.timingLogProbs); h.gem = pin(heads.gem); h.attr_tafkheem = pin(heads.tafkheem)
        h.attr_ghunna = pin(heads.ghunna); h.attr_qalqalah = pin(heads.qalqalah); h.attr_face = pin(heads.face)
        h.boundary = pin(heads.boundary); h.conf = pin(heads.conf)

        var err: UnsafePointer<CChar>?
        guard let res = zf_tajweed_score(handle, cfg, &h, Int32(r.surah), Int32(r.ayah), &err) else {
            throw .tajweedUnavailable("zf_tajweed_score \(r.surah):\(r.ayah): \(err.map { String(cString: $0) } ?? "failed")")
        }
        defer { zf_tajweed_result_free(res) }
        func status(_ s: Int32) -> TajweedStatus { s == 2 ? .validated : s == 1 ? .experimental : .off }
        func frames(_ lo: Int32, _ hi: Int32) -> ClosedRange<Int>? { lo >= 0 && hi >= lo ? Int(lo)...Int(hi) : nil }
        var sp: UnsafePointer<ZfTajweedSite>?
        let ns = Int(zf_tajweed_result_sites(res, &sp))
        let sites: [TajweedResult.Site] = (0..<max(0, ns)).compactMap { i in
            let s = sp![i]
            guard s.cls >= 0, Int(s.cls) < TajweedClass.allCases.count else { return nil }
            return .init(cls: TajweedClass.allCases[Int(s.cls)], status: status(s.status), position: Int(s.pos), word: Int(s.word),
                         expected: s.expected >= 0 ? Int(s.expected) : nil, alternative: s.alt >= 0 ? Int(s.alt) : nil,
                         llrFinal: s.llr_final, llrInter1: s.llr_inter1, llr: s.llr, threshold: s.threshold,
                         flagged: s.flagged != 0, frames: frames(s.frame_lo, s.frame_hi))
        }
        var mp: UnsafePointer<ZfTajweedMadd>?
        let nm = Int(zf_tajweed_result_madd(res, &mp))
        let kinds: [TajweedResult.Madd.Kind] = [.none, .fixed2, .muttasil, .free, .lazim]
        let madd: [TajweedResult.Madd] = (0..<max(0, nm)).map { i in
            let m = mp![i]
            return .init(position: Int(m.pos), word: Int(m.word), token: Int(m.token),
                         kind: m.madd_class >= 0 && Int(m.madd_class) < kinds.count ? kinds[Int(m.madd_class)] : .none,
                         status: status(m.status), ratio: m.ratio, count: Int(m.count), displayCount: m.display_count,
                         allowed: Int(min(m.allowed_lo, m.allowed_hi))...Int(max(m.allowed_lo, m.allowed_hi)),
                         flagged: m.flagged != 0, frames: frames(m.frame_lo, m.frame_hi))
        }
        func letters(_ f: (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<ZfTajweedLetter>?>?) -> Int32) -> [TajweedResult.Letter] {
            var lp: UnsafePointer<ZfTajweedLetter>?
            let n = Int(f(res, &lp))
            return (0..<max(0, n)).map { i in
                let l = lp![i]
                return .init(position: Int(l.pos), word: Int(l.word), token: Int(l.token), status: status(l.status), score: l.score,
                             threshold: l.threshold, flagged: l.flagged != 0, frames: frames(l.frame_lo, l.frame_hi))
            }
        }
        var sum = ZfTajweedSummary()
        _ = zf_tajweed_result_summary(res, &sum)
        let json = zf_tajweed_result_json(res).map { String(cString: $0) } ?? ""
        let q = letters { zf_tajweed_result_qalqalah($0, $1) }
        let g = letters { zf_tajweed_result_gemination($0, $1) }
        var wot: UnsafePointer<Int32>?
        var nWords: Int32 = 0
        let nw = zf_tajweed_expected_words(handle, Int32(r.surah), Int32(r.ayah), &wot, &nWords) >= 0 ? Int(nWords) : 0
        // the engine's words (API 3: every single-unit edit inside each word) when its word check is on; else the
        // words from the sites, scores only
        var wp: UnsafePointer<ZfTajweedWord>?
        let ne = Int(zf_tajweed_result_words(res, &wp))
        let engineWords: [TajweedResult.EngineWord] = (0..<max(0, ne)).map { i in
            let w = wp![i]
            return .init(word: Int(w.word), score: w.has_score != 0 ? w.score : nil, threshold: w.threshold, flagged: w.flagged != 0,
                         cls: w.cls >= 0 && Int(w.cls) < TajweedClass.allCases.count ? TajweedClass.allCases[Int(w.cls)] : nil,
                         expected: w.expected >= 0 ? Int(w.expected) : nil, alternative: w.alt >= 0 ? Int(w.alt) : nil,
                         llrFinal: w.llr_final, llrInter1: w.llr_inter1)
        }
        return TajweedResult(surah: r.surah, ayah: r.ayah, sites: sites, madd: madd, qalqalah: q, gemination: g,
                             shortVowelFrames: sum.madd_unit_ok != 0 ? sum.short_vowel_frames : nil,
                             settings: r.settings, json: json, settingsDifferences: diffs,
                             words: TajweedResult.makeWords(sites: sites, madd: madd, qalqalah: q, gemination: g, count: nw,
                                                            setting: r.settings.word, engine: engineWords))
    }

    /// The engine's effective settings against the SDK's, per class and check.
    private func compare(_ cfg: OpaquePointer, _ s: EffectiveTajweed) -> [String] {
        var e = ZfTajweedEffective()
        guard zf_tajweed_config_effective(cfg, &e) == 0 else { return ["zf_tajweed_config_effective failed"] }
        var d: [String] = []
        let enabled = withUnsafeBytes(of: e.class_enabled) { Array($0.bindMemory(to: Int32.self)) }
        let thr = withUnsafeBytes(of: e.class_threshold) { Array($0.bindMemory(to: Double.self)) }
        for (i, c) in TajweedClass.allCases.enumerated() where i < enabled.count {
            guard let mine = s.site(c) else { continue }
            if (enabled[i] != 0) != mine.enabled { d.append("\(c.rawValue): enabled engine \(enabled[i] != 0) sdk \(mine.enabled)") }
            if mine.enabled, let t = mine.threshold, abs(thr[i] - t) > 1e-12 {
                d.append("\(c.rawValue): threshold engine \(thr[i]) sdk \(t)")
            }
        }
        return d
    }
}
