import Foundation

// The tajweed settings of a V4 model: calibration.json's defaults, the portal's `tajweed` block (remote config)
// and the app's own choices, resolved with the precedence app code > remote config > calibration.json.
// The rules are the shared ones of every TajweedFormer SDK;
// Tests/TajweedFormerTests/TajweedSettingsTests.swift reproduces the shared vectors exactly.

/// A sensitivity preset: how many correct sites may be flagged (calibration.json `presets.*.site_fa`).
public enum TajweedPreset: String, CaseIterable, Sendable, Codable {
    case strict, balanced, sensitive
    case verySensitive = "very_sensitive"
}

/// A site class: one single-unit alternative family scored by the fused CTC LLR.
public enum TajweedClass: String, CaseIterable, Sendable, Codable {
    case vowelSub = "vowel_sub", vowelDel = "vowel_del", vowelIns = "vowel_ins"
    case shortToLong = "short_to_long", longToShort = "long_to_short"
    case consSub = "cons_sub", consDel = "cons_del", insertion

    /// The check that switches this class.
    public var check: TajweedCheck {
        switch self {
        case .vowelSub, .vowelDel, .vowelIns: return .vowels
        case .shortToLong, .longToShort: return .length
        case .consSub, .consDel, .insertion: return .letters
        }
    }
}

/// A switch the app or the portal turns on and off.
public enum TajweedCheck: String, CaseIterable, Sendable, Codable {
    case letters, vowels, length, madd, gemination, qalqalah, lazim
}

/// calibration.json's status of a class or check.
public enum TajweedStatus: String, Sendable, Codable {
    /// On by default.
    case validated
    /// Off by default; the app or the portal may turn it on.
    case experimental
    /// Never reported, unless the app turns it on in a debug build.
    case off
}

/// Where a setting in force came from.
public enum TajweedSource: String, Sendable, Codable {
    case app, remote, calibration
}

/// Which heads the thresholds are for: the exact engine's int8 heads, or fp16/fp32 heads (CoreML, NPUs, a
/// server). calibration.json may carry per-backend thresholds (`backend_overrides`).
public enum TajweedBackend: String, Sendable, Codable {
    case int8, fp32
}

/// A per-class (or madd / qalqalah / gemination) override: a preset, or for a class a fused-LLR threshold.
public enum TajweedOverride: Sendable, Hashable {
    case preset(TajweedPreset)
    case threshold(Double)
}

/// The per-word decision level (calibration.json's `word` block per context): a preset fitted on learner data, or a
/// custom score threshold. A word is flagged when its score (the largest fused LLR of any single-unit alternative
/// inside it) reaches the threshold.
public enum TajweedWordLevel: Sendable, Hashable {
    /// Fewest word flags.
    case strict
    /// The default for most apps.
    case general
    /// More forgiving thresholds for early learners.
    case beginner
    /// A raw word-score threshold, within calibration's `custom_range` (else floor..30).
    case custom(Double)
    /// No word flags (scores are still reported).
    case off

    public var name: String {
        switch self {
        case .strict: return "strict"
        case .general: return "general"
        case .beginner: return "beginner"
        case .custom: return "custom"
        case .off: return "off"
        }
    }

    static func preset(_ s: String) -> TajweedWordLevel? {
        switch s {
        case "strict": return .strict
        case "general": return .general
        case "beginner": return .beginner
        default: return nil
        }
    }
}

/// The app's own tajweed settings: each one set here wins over the portal and calibration.json.
public struct TajweedOptions: Sendable, Hashable {
    public var preset: TajweedPreset?
    /// Keys: a class name (`TajweedClass.rawValue`), or `madd`, `qalqalah`, `gemination` (preset only).
    public var overrides: [String: TajweedOverride]
    public var checks: [TajweedCheck: Bool]
    /// A context calibration.json ships ("c16_l64", "c24_l72", ...); nil for the portal's or the default.
    public var context: String?
    /// The per-word level; nil for the portal's or calibration's default.
    public var word: TajweedWordLevel?

    public init(preset: TajweedPreset? = nil, overrides: [String: TajweedOverride] = [:],
                checks: [TajweedCheck: Bool] = [:], context: String? = nil, word: TajweedWordLevel? = nil) {
        self.preset = preset
        self.overrides = overrides
        self.checks = checks
        self.context = context
        self.word = word
    }

    /// A class override (the typed form).
    public mutating func set(_ cls: TajweedClass, _ o: TajweedOverride?) { overrides[cls.rawValue] = o }
}

/// The portal's `tajweed` block after validation: what survived, and what was dropped.
public struct RemoteTajweedBlock: Sendable, Hashable {
    public var preset: TajweedPreset?
    public var overrides: [String: TajweedOverride] = [:]
    public var checks: [TajweedCheck: Bool] = [:]
    public var context: String?
    /// `{"preset": "strict" | "general" | "beginner"}` or `{"threshold": number}` (range checked against calibration).
    public var word: TajweedWordLevel?
    var hasOverrides = false, hasChecks = false

    /// Field paths dropped as invalid or unknown ("remote.preset", "remote.overrides.cons_sub", ...).
    public internal(set) var dropped: [String] = []

    static let featureKeys: Set<String> = ["madd", "qalqalah", "gemination"]
    static let classKeys: Set<String> = Set(TajweedClass.allCases.map(\.rawValue))

    /// Validates a block. Never throws: an invalid field is dropped, never the config. A block
    /// that is not an object, or whose `v` is not 1, is ignored whole (nil) and reported in `droppedIfIgnored`.
    public static func parse(_ raw: JSONValue?) -> (block: RemoteTajweedBlock?, dropped: [String]) {
        guard let raw, raw != .null else { return (nil, []) }
        guard let obj = raw.object else { return (nil, ["remote"]) }
        guard let v = obj["v"]?.number, v == 1 else { return (nil, ["remote.v"]) }
        var b = RemoteTajweedBlock()
        var dropped: [String] = []
        for (k, value) in obj where k != "v" {
            switch k {
            case "preset":
                if let s = value.string, let p = TajweedPreset(rawValue: s) { b.preset = p } else { dropped.append("remote.preset") }
            case "context":
                if let s = value.string, !s.isEmpty { b.context = s } else { dropped.append("remote.context") }
            case "overrides":
                guard let ov = value.object else { dropped.append("remote.overrides"); continue }
                b.hasOverrides = true
                for (c, o) in ov {
                    let isFeature = featureKeys.contains(c)
                    guard classKeys.contains(c) || isFeature, let oo = o.object else { dropped.append("remote.overrides.\(c)"); continue }
                    let hasP = oo["preset"] != nil, hasT = oo["threshold"] != nil
                    if hasP == hasT || (isFeature && hasT) { dropped.append("remote.overrides.\(c)"); continue }
                    if hasP {
                        if let s = oo["preset"]?.string, let p = TajweedPreset(rawValue: s) { b.overrides[c] = .preset(p) }
                        else { dropped.append("remote.overrides.\(c)") }
                    } else {
                        if let t = oo["threshold"]?.number, t.isFinite, t >= -20, t <= 20 { b.overrides[c] = .threshold(t) }
                        else { dropped.append("remote.overrides.\(c)") }
                    }
                }
            case "word":
                guard let w = value.object, w.count == 1 else { dropped.append("remote.word"); continue }
                if let p = w["preset"]?.string, let l = TajweedWordLevel.preset(p) { b.word = l }
                else if let t = w["threshold"]?.number, t.isFinite { b.word = .custom(t) }
                else { dropped.append("remote.word") }
            case "checks":
                guard let ch = value.object else { dropped.append("remote.checks"); continue }
                b.hasChecks = true
                for (c, v) in ch {
                    if let key = TajweedCheck(rawValue: c), let on = v.bool { b.checks[key] = on } else { dropped.append("remote.checks.\(c)") }
                }
            default:
                dropped.append("remote.\(k)")
            }
        }
        b.dropped = Array(Set(dropped)).sorted()
        return (b, b.dropped)
    }

    /// The block inside a whole /v1/config document, or the block itself.
    public static func parse(configData: Data) -> (block: RemoteTajweedBlock?, dropped: [String]) {
        guard let v = JSONValue(data: configData) else { return (nil, ["remote"]) }
        if let inner = v["tajweed"] { return parse(inner) }
        if v["v"] != nil { return parse(v) }
        return (nil, [])
    }
}

/// calibration.json (`quranlab.tajweed-calibration/1`), kept as parsed: read through accessors.
public struct TajweedCalibration: Sendable, Hashable {
    public let json: JSONValue

    public init(json: JSONValue) throws(RecognizerError) {
        guard json["format"]?.string == "quranlab.tajweed-calibration/1" else {
            throw .manifestInvalid("calibration.json: format is not quranlab.tajweed-calibration/1")
        }
        guard let ctxs = json["contexts"]?.object, !ctxs.isEmpty, let d = json["default_context"]?.string, ctxs[d] != nil else {
            throw .manifestInvalid("calibration.json: no contexts, or the default context is not one of them")
        }
        guard let p = json["default_preset"]?.string, TajweedPreset(rawValue: p) != nil else {
            throw .manifestInvalid("calibration.json: default_preset is not a preset")
        }
        guard json["classes"]?.array != nil else { throw .manifestInvalid("calibration.json: no classes") }
        self.json = json
    }

    public init(data: Data) throws(RecognizerError) {
        guard let v = JSONValue(data: data) else { throw .manifestInvalid("calibration.json is not JSON") }
        try self.init(json: v)
    }

    public var modelID: String? { json["model_id"]?.string }
    public var tokensSHA256: String? { json["tokens_sha256"]?.string }
    public var defaultContext: String { json["default_context"]!.string! }
    public var defaultPreset: TajweedPreset { TajweedPreset(rawValue: json["default_preset"]!.string!)! }
    /// The shipped contexts, sorted; the default first.
    public var contexts: [String] {
        let all = (json["contexts"]?.object?.keys).map(Array.init) ?? []
        return [defaultContext] + all.filter { $0 != defaultContext }.sorted()
    }
    /// The class names in calibration.json's order.
    public var classes: [String] { json["classes"]?.array?.compactMap(\.string) ?? [] }
    /// A preset's display label ("Balanced").
    public func label(_ p: TajweedPreset) -> String? { json["presets"]?[p.rawValue]?["label"]?.string }
    /// A context's block.
    public func context(_ name: String) -> JSONValue? { json["contexts"]?[name] }

    /// A context's `word` block (per-word thresholds), when calibration carries one.
    public func word(_ context: String) -> JSONValue? { self.context(context)?["word"] }

    /// The custom word-threshold range: `word.custom_range` when given, else [floor (default 2.0), 30].
    public func wordRange(_ context: String) -> ClosedRange<Double> {
        let w = word(context)
        if let r = w?["custom_range"]?.array, r.count == 2, let lo = r[0].number, let hi = r[1].number, lo <= hi { return lo...hi }
        let floor = w?["floor"]?.number ?? 2.0
        return floor...max(floor, 30)
    }
}

/// The settings in force for one session.
public struct EffectiveTajweed: Sendable, Hashable {
    public struct Site: Sendable, Hashable {
        public let status: TajweedStatus
        public let enabled: Bool
        /// The fused-LLR cut (flag when the best alternative's fused LLR is above it); nil when calibration has
        /// no threshold for the preset in force (the class is then disabled).
        public let threshold: Double?
        /// The preset the threshold comes from; nil for a threshold override.
        public let preset: TajweedPreset?
        public let source: TajweedSource
    }
    public struct Feature: Sendable, Hashable {
        public let status: TajweedStatus
        public let enabled: Bool
        public let preset: TajweedPreset?
        public let source: TajweedSource?
        /// qalqalah and gemination: the score cut (preset_tau of the preset, else tau).
        public let tau: Double?
    }
    public let context: String
    public let backend: TajweedBackend
    public let preset: TajweedPreset
    /// By class name.
    public let sites: [String: Site]
    public let madd: Feature
    public let lazim: Feature
    public let gemination: Feature
    public let qalqalah: Feature
    /// The per-word decision in force.
    public let word: Word
    /// Remote fields dropped as invalid or unknown.
    public let dropped: [String]
    /// Checks that something tried to turn on for an `off` item and that stayed off ("remote:lazim", "app:insertion").
    public let refused: [String]

    public struct Word: Sendable, Hashable {
        /// calibration.json's word status (nil when calibration has no word block).
        public let status: TajweedStatus?
        /// strict, general, beginner, custom or off.
        public let level: String
        /// The score a word must reach to be flagged; nil when no threshold is in force (no word block and no
        /// custom level, or the level is off).
        public let threshold: Double?
        public let source: TajweedSource
        /// True when flags are reported (a threshold, and the status allows it from where the level came).
        public let enabled: Bool
        /// calibration's flag rule: true for `score >= tau` (the default), false for `score > tau`.
        public let inclusive: Bool

        /// Whether `score` is flagged under this setting; nil when word flags are not reported.
        public func flags(_ score: Double?) -> Bool? {
            guard enabled, let t = threshold, let score else { return nil }
            return inclusive ? score >= t : score > t
        }
    }

    public func site(_ c: TajweedClass) -> Site? { sites[c.rawValue] }

    /// The telemetry name of the site preset: the preset, or `custom` when any class has a raw threshold.
    public var presetName: String { sites.values.contains { $0.preset == nil } ? "custom" : preset.rawValue }
    /// Classes set apart from the global preset (0 to 8).
    public var siteOverrides: Int { sites.values.filter { $0.preset != preset }.count }

    /// The JSON shape of the shared settings vectors (tests, diagnostics).
    public var jsonObject: [String: Any] {
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        var s: [String: Any] = [:]
        for (k, v) in sites {
            s[k] = ["status": v.status.rawValue, "enabled": v.enabled, "threshold": opt(v.threshold),
                    "preset": opt(v.preset?.rawValue), "source": v.source.rawValue]
        }
        func feat(_ f: Feature, _ keys: [String]) -> [String: Any] {
            var d: [String: Any] = ["status": f.status.rawValue, "enabled": f.enabled]
            if keys.contains("preset") { d["preset"] = opt(f.preset?.rawValue) }
            if keys.contains("source") { d["source"] = opt(f.source?.rawValue) }
            if keys.contains("tau") { d["tau"] = opt(f.tau) }
            return d
        }
        return ["context": context, "backend": backend.rawValue, "preset": preset.rawValue, "sites": s,
                "madd": feat(madd, ["preset", "source"]), "lazim": feat(lazim, []),
                "gemination": feat(gemination, ["preset", "source", "tau"]),
                "qalqalah": feat(qalqalah, ["preset", "source", "tau"]),
                "dropped": dropped, "refused": refused]
    }
}

public enum TajweedSettings {
    /// Checks app options against calibration.json: an invalid value is a programming error.
    public static func validate(_ app: TajweedOptions, _ cal: TajweedCalibration) throws(RecognizerError) {
        if let c = app.context, cal.context(c) == nil { throw .invalidArgument("tajweed context \(c) is not shipped") }
        if case .custom(let t) = app.word {
            let r = cal.wordRange(app.context ?? cal.defaultContext)
            guard t.isFinite, r.contains(t) else { throw .invalidArgument("word threshold \(t) is outside \(r)") }
        }
        for (k, o) in app.overrides {
            let feature = RemoteTajweedBlock.featureKeys.contains(k)
            guard RemoteTajweedBlock.classKeys.contains(k) || feature else { throw .invalidArgument("tajweed override \(k)") }
            if case .threshold(let t) = o {
                guard !feature, t.isFinite, t >= -20, t <= 20 else { throw .invalidArgument("tajweed override \(k): threshold") }
            }
        }
    }

    /// Resolves app > remote > calibration for `backend` (the exact engine is int8; CoreML, NPUs and servers fp32).
    /// `remote` is the raw block (nil when the config has none); `debugBuild` is the app's build, never the SDK's.
    public static func resolve(calibration cal: TajweedCalibration, remote: JSONValue?, app: TajweedOptions = .init(),
                               debugBuild: Bool, backend: TajweedBackend = .int8) throws(RecognizerError) -> EffectiveTajweed {
        try validate(app, cal)
        let parsed = RemoteTajweedBlock.parse(remote)
        var dropped = parsed.dropped
        var rem = parsed.block ?? RemoteTajweedBlock()
        if let c = rem.context, cal.context(c) == nil { dropped.append("remote.context"); rem.context = nil }
        let ctx = app.context ?? rem.context ?? cal.defaultContext
        let cc = cal.context(ctx)!
        let preset = app.preset ?? rem.preset ?? cal.defaultPreset
        var refused: [String] = []

        func flag(_ c: TajweedCheck) -> (Bool, TajweedSource)? {
            if let v = app.checks[c] { return (v, .app) }
            if let v = rem.checks[c] { return (v, .remote) }
            return nil
        }
        func enabled(_ item: String, _ check: TajweedCheck, _ status: TajweedStatus) -> Bool {
            guard let fl = flag(check) else { return status == .validated }
            let (f, src) = fl
            if !f { return false }
            if status != .off { return true }
            if src == .app && debugBuild { return true }
            refused.append("\(src.rawValue):\(item)")
            return false
        }
        func pick(_ key: String) -> (TajweedOverride, TajweedSource) {
            if let o = app.overrides[key] { return (o, .app) }
            if let o = rem.overrides[key] { return (o, .remote) }
            if let p = app.preset { return (.preset(p), .app) }
            if let p = rem.preset { return (.preset(p), .remote) }
            return (.preset(cal.defaultPreset), .calibration)
        }
        func status(_ v: JSONValue?) -> TajweedStatus { TajweedStatus(rawValue: v?.string ?? "off") ?? .off }

        let bo = cc["backend_overrides"]?[backend.rawValue]?["sites"]
        var sites: [String: EffectiveTajweed.Site] = [:]
        for name in cal.classes {
            let s = cc["sites"]?[name]
            let (o, src) = pick(name)
            let th = (bo?[name]?["thresholds"]?.object).flatMap { $0.isEmpty ? nil : $0 } ?? s?["thresholds"]?.object ?? [:]
            var thr: Double?, p: TajweedPreset?
            switch o {
            case .threshold(let t): thr = t
            case .preset(let pp): p = pp; thr = th[pp.rawValue]?.number
            }
            let st = status(s?["status"])
            let check = TajweedClass(rawValue: name)?.check ?? .letters
            let on = enabled(name, check, st)
            sites[name] = .init(status: st, enabled: on && thr != nil, threshold: thr, preset: p, source: src)
        }
        let madd = cc["madd"]
        let maddStatus = status(madd?["status"])
        let lazimStatus = status(madd?["cuts"]?["lazim"]?["status"])
        let maddOn = enabled("madd", .madd, maddStatus)
        let lazimOn = enabled("lazim", .lazim, lazimStatus)
        let (mo, msrc) = pick("madd")
        func feature(_ key: String, _ check: TajweedCheck) -> EffectiveTajweed.Feature {
            let b = cc[key]
            let st = status(b?["status"])
            let (o, src) = pick(key)
            var p: TajweedPreset?
            if case .preset(let pp) = o { p = pp }
            let tau = p.flatMap { b?["preset_tau"]?[$0.rawValue]?.number } ?? b?["tau"]?.number
            return .init(status: st, enabled: enabled(key, check, st), preset: p, source: src, tau: tau)
        }
        let qalqalah = feature("qalqalah", .qalqalah)
        let gemination = feature("gemination", .gemination)
        var maddPreset: TajweedPreset?
        if case .preset(let pp) = mo { maddPreset = pp }
        // the word level: app > portal > calibration's default_preset
        let wb = cal.word(ctx)
        var remoteWord = rem.word
        if case .custom(let t) = remoteWord, !cal.wordRange(ctx).contains(t) { dropped.append("remote.word"); remoteWord = nil }
        let wordStatus: TajweedStatus? = wb.map { status($0["status"]) }
        let wl: TajweedWordLevel
        let wsrc: TajweedSource
        if let a = app.word { wl = a; wsrc = .app }
        else if let r = remoteWord { wl = r; wsrc = .remote }
        else { wl = wb?["default_preset"]?.string.flatMap(TajweedWordLevel.preset) ?? .off; wsrc = .calibration }
        var wthr: Double?
        switch wl {
        case .custom(let t): wthr = t
        case .off: wthr = nil
        default: wthr = wb?["presets"]?[wl.name]?["tau"]?.number
        }
        var wenabled = wthr != nil
        if wenabled, let st = wordStatus {
            switch st {
            case .validated: break
            case .experimental: wenabled = wsrc != .calibration
            case .off:
                if !(wsrc == .app && debugBuild) {
                    if wsrc != .calibration { refused.append("\(wsrc.rawValue):word") }
                    wenabled = false
                }
            }
        }
        let inclusive = (wb?["flag_rule"]?.string ?? "score >= tau").contains(">=")
        let word = EffectiveTajweed.Word(status: wordStatus, level: wl.name, threshold: wthr, source: wsrc, enabled: wenabled,
                                         inclusive: inclusive)
        return EffectiveTajweed(
            context: ctx, backend: backend, preset: preset, sites: sites,
            madd: .init(status: maddStatus, enabled: maddOn, preset: maddPreset, source: msrc, tau: nil),
            lazim: .init(status: lazimStatus, enabled: lazimOn && maddOn, preset: nil, source: nil, tau: nil),
            gemination: gemination, qalqalah: qalqalah, word: word,
            dropped: Array(Set(dropped)).sorted(), refused: Array(Set(refused)).sorted())
    }
}
