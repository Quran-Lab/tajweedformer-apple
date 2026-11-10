import Foundation

/// Why a session or recognizer is not on the Neural Engine, as the server counts them.
public enum FallbackReason: String, Sendable, CaseIterable, Codable {
    /// A head came out NaN or infinite.
    case nonFinite = "non_finite"
    /// A chunk took more than three times its audio.
    case deadline
    /// The OS cannot run the package (older than iOS 18 / macOS 15), or the device has no Neural Engine.
    case aneUnavailable = "ane_unavailable"
    case npuUnavailable = "npu_unavailable"
    /// The package did not load, or failed its self-test.
    case modelLoad = "model_load"
    case thermal
    case memory
    case other
}

/// Histogram bucket names and upper bounds (the last bucket takes everything above).
enum Histogram {
    static let latency = (["le_5", "le_10", "le_20", "le_40", "le_80", "le_160", "le_320", "gt_320"], [5.0, 10, 20, 40, 80, 160, 320])
    static let rtf = (["le_0_1", "le_0_25", "le_0_5", "le_1", "gt_1"], [0.1, 0.25, 0.5, 1])
    static let startup = (["le_250", "le_500", "le_1000", "le_2000", "le_4000", "gt_4000"], [250.0, 500, 1000, 2000, 4000])
    static let flagPct = (["le_1", "le_2", "le_5", "le_10", "le_20", "gt_20"], [1.0, 2, 5, 10, 20])
    static let margin = (["le_0_5", "le_1", "le_2", "le_4", "le_8", "gt_8"], [0.5, 1, 2, 4, 8])
    static let confidence = (["le_0_5", "le_0_7", "le_0_8", "le_0_9", "le_0_95", "gt_0_95"], [0.5, 0.7, 0.8, 0.9, 0.95])
    static let compileMs = (["le_1000", "le_5000", "le_15000", "le_30000", "le_60000", "le_120000", "gt_120000"],
                            [1000.0, 5000, 15000, 30000, 60000, 120000])
    static let stallMs = (["le_50", "le_100", "le_200", "le_300", "le_500", "le_1000", "gt_1000"], [50.0, 100, 200, 300, 500, 1000])
    /// Speedup (CPU median / accelerator median): below 0.5, below 1, then up to 1.5, 2, 3, 5, above 5.
    static let speedupNames = ["lt_0_5", "lt_1", "le_1_5", "le_2", "le_3", "le_5", "gt_5"]
    static func speedupIndex(_ v: Double) -> Int {
        if v < 0.5 { return 0 }
        if v < 1 { return 1 }
        return 2 + (index(v, [1.5, 2, 3, 5]))
    }

    static func index(_ v: Double, _ bounds: [Double]) -> Int { bounds.firstIndex { v <= $0 } ?? bounds.count }
}

/// What a cohort is: one per distinct revision, context, backend, preset and word level of a day.
public struct TelemetryCohort: Sendable, Hashable, Codable {
    public var revision: String
    public var context: String
    /// `cpu`, `ane` (what actually ran).
    public var backend: String
    /// The site preset in force, or `custom` when any raw site threshold is set.
    public var preset: String
    /// `strict`, `general`, `beginner`, `custom` or `off`.
    public var wordLevel: String
    /// Only for `custom`: `le_3` ... `gt_7`.
    public var wordBucket: String
    public var siteOverrides: Int

    var key: String { [revision, context, backend, preset, wordLevel, wordBucket].joined(separator: "|") }
}

/// One finished session, as telemetry counts it: no audio, no text, no ids, no times finer than the day.
public struct SessionTelemetry: Sendable, Hashable {
    public var cohort: TelemetryCohort
    public var audioSeconds: Double
    /// Processing time per chunk, and each chunk's audio length (for the real-time factor).
    public var chunkSeconds: [Double]
    public var chunkAudioSeconds: Double
    public var checksOn: [String]
    public var throttled: Bool
    public var thermalTransitions: Int
    /// Milliseconds from the recognizer's creation to its first chunk, for the first session of a launch.
    public var coldStartMs: Double?
}

/// One scored take: per class sites and flags, madd counts, words, the surah, and the decoded tokens' margins and
/// confidences (histograms only).
public struct ScoreTelemetry: Sendable, Hashable {
    public struct SiteCount: Sendable, Hashable {
        public var sites = 0
        public var flagged = 0
        public init(sites: Int = 0, flagged: Int = 0) { self.sites = sites; self.flagged = flagged }
    }
    public var cohort: TelemetryCohort
    public var surah: Int
    /// By calibration class name.
    public var classes: [String: SiteCount] = [:]
    /// Madd verdict counts (2, 4, 6) and how many were flagged.
    public var maddCounts: [Int: Int] = [:]
    public var maddFlagged = 0
    public var wordsScored = 0
    public var wordsFlagged = 0
    /// Qalqalah and gemination verdicts whose check ran, and how many were flagged (2.0.1).
    public var qalqalahChecked = 0
    public var qalqalahFlagged = 0
    public var geminationChecked = 0
    public var geminationFlagged = 0
    public var margins: [Double] = []
    public var confidences: [Double] = []

    public init(cohort: TelemetryCohort, surah: Int) {
        self.cohort = cohort
        self.surah = surah
    }
}

/// Every event the SDK counts. A host can receive them too (`QuranLab.Options.analyticsSink`).
public enum AnalyticsEvent: Sendable, Hashable {
    case modelLoaded(revision: String, milliseconds: Double, cohort: TelemetryCohort)
    case selfTest(passed: Bool, cohort: TelemetryCohort)
    /// A recognizer left (or never reached) the Neural Engine.
    case fallback(FallbackReason, cohort: TelemetryCohort)
    case sessionFinished(SessionTelemetry)
    case sessionAborted(cohort: TelemetryCohort)
    case scored(ScoreTelemetry)
    case download(revision: String, profile: String, bytes: Int64, success: Bool, resumed: Bool)
    /// The Neural Engine's promotion pipeline and in-session failovers (telemetry `promotions`).
    case promotion(PromotionTelemetry)
}

/// Receives every analytics event besides the SDK's own daily aggregates. Called on the recognition path: return
/// at once.
public protocol AnalyticsSink: Sendable {
    func record(_ event: AnalyticsEvent)
}

/// On-device telemetry v2 with the 2.0.1 deltas: sums and histograms per UTC day and cohort, the surah coverage, the
/// downloads and the 2.0.1 counters. Recording is a lock and a few additions into the day's open counts (saved on a
/// utility queue). At each send point (`flush`) the open counts of each day are sealed into a delta: the v2 body of what
/// was counted since that day's previous delta, with a fresh random `report_id`, saved before it is sent. A retry sends
/// the same bytes with the same id (the server counts it once). Counts go to the UTC day they happened in, so a delta
/// never spans midnight; unsent deltas are kept 7 days and sent oldest first.
/// Tried and rejected: one payload per completed day (2.0.0: a day's sessions reached the portal a day late);
/// re-sending the whole day so far at each send point (the server would count every send).
final class AnalyticsStore: Sendable {
    struct Cohort: Codable, Equatable {
        var cohort: TelemetryCohort
        var sessions = 0, minutes = 0.0, chunks = 0, aborted = 0
        var fallbacks: [String: Int] = [:]
        var selfTestPass = 0, selfTestFail = 0
        var latency = [Int](repeating: 0, count: 8)
        var rtf = [Int](repeating: 0, count: 5)
        var coldStart = [Int](repeating: 0, count: 6)
        var modelLoad = [Int](repeating: 0, count: 6)
        var thermalTransitions = 0, throttledSessions = 0
        var checksOn: [String: Int] = [:]
        var classes: [String: [Int]] = [:]
        var sessionFlagPct = [Int](repeating: 0, count: 6)
        var margin = [Int](repeating: 0, count: 6)
        var confidence = [Int](repeating: 0, count: 6)
        var madd = [0, 0, 0, 0]   // c2, c4, c6, flagged
        var words = [0, 0]        // scored, flagged

        init(_ c: TelemetryCohort) { cohort = c }

        mutating func merge(_ o: Cohort) {
            sessions += o.sessions; minutes += o.minutes; chunks += o.chunks; aborted += o.aborted
            for (k, v) in o.fallbacks { fallbacks[k, default: 0] += v }
            selfTestPass += o.selfTestPass; selfTestFail += o.selfTestFail
            for i in latency.indices { latency[i] += o.latency[i] }
            for i in rtf.indices { rtf[i] += o.rtf[i] }
            for i in coldStart.indices { coldStart[i] += o.coldStart[i] }
            for i in modelLoad.indices { modelLoad[i] += o.modelLoad[i] }
            thermalTransitions += o.thermalTransitions; throttledSessions += o.throttledSessions
            for (k, v) in o.checksOn { checksOn[k, default: 0] += v }
            for (k, v) in o.classes { var x = classes[k] ?? [0, 0]; x[0] += v[0]; x[1] += v[1]; classes[k] = x }
            for i in sessionFlagPct.indices { sessionFlagPct[i] += o.sessionFlagPct[i] }
            for i in margin.indices { margin[i] += o.margin[i] }
            for i in confidence.indices { confidence[i] += o.confidence[i] }
            for i in madd.indices { madd[i] += o.madd[i] }
            for i in words.indices { words[i] += o.words[i] }
        }
    }

    struct Download: Codable, Equatable {
        var bytes: Int64 = 0, success = 0, failed = 0, resumed = 0
    }

    /// One `promotions` entry: a backend, revision and context.
    struct Promotion: Codable, Equatable {
        var backend: String
        var revision: String
        var context: String
        var attempts = 0, promoted = 0
        var failedAt: [String: Int] = [:]
        var reasons: [String: Int] = [:]
        var compileMs = [Int](repeating: 0, count: 7)
        var speedup = [Int](repeating: 0, count: 7)
        var failovers = 0
        var failoverCauses: [String: Int] = [:]
        var failoverStall = [Int](repeating: 0, count: 7)
        /// Promoted builds taken back to the CPU after an in-session failure.
        var demoted = 0

        var activity: Int { attempts + failovers + demoted + reasons.values.reduce(0, +) }
    }

    /// One UTC day's counts not sealed yet.
    struct Day: Codable, Equatable {
        var day: String
        var cohorts: [String: Cohort] = [:]
        var coverage: [String: Int] = [:]
        var downloads: [String: Download] = [:]   // "revision|profile"
        // 2.0.1
        var launches = 0
        var ayahs = 0
        var surahAyahs: [String: Int] = [:]
        var words = 0
        var ruleChecks: [String: Int] = [:]
        var ruleFlags: [String: Int] = [:]
        var shareAsked = 0
        var shareYes = 0
        var shareNo = 0
        var promotions: [String: Promotion] = [:]   // "backend|revision|context"

        var isEmpty: Bool {
            cohorts.isEmpty && coverage.isEmpty && downloads.isEmpty && launches == 0 && ayahs == 0 && surahAyahs.isEmpty && words == 0
                && ruleChecks.isEmpty && shareAsked == 0 && shareYes == 0 && shareNo == 0 && promotions.isEmpty
        }
    }

    /// A sealed delta: its body exactly as it is sent and resent.
    struct Sealed: Codable, Equatable {
        var reportID: String
        var day: String
        var seq: Int
        var body: Data
    }

    struct State: Codable {
        var open: [String: Day] = [:]
        var sealed: [Sealed] = []
        var seq = 0
    }

    /// The 2.0.1 counters besides sessions and scores.
    enum Counter: Sendable {
        /// A cold start or a return to the foreground.
        case launch
        /// A consent sheet was shown, or the app's own UI was handed a consent ask.
        case shareAsked
        /// A grant from a sheet answer (the SDK's sheet or the app's own UI).
        case shareYes
        /// A decline from a sheet answer.
        case shareNo
    }

    /// Retries of unsent deltas on the timer: 1 minute, then 10 minutes, then the next launch or app switch.
    struct Backoff {
        var failures = 0
        var notBefore: Date?
    }

    struct Context: Sendable {
        var platform: String
        var sdkVersion: String
        var appVersion: String
        var deviceClass: String
        var soc: String?
        var osMajor: Int
        var ramTier: String
    }

    /// The session running now, kept on disk while it runs: if it is still there at the next launch, the session
    /// never finished (killed or crashed) and counts as aborted.
    struct OpenSession: Codable, Equatable {
        var cohort: TelemetryCohort
        var pid: Int32
    }

    private let file: JSONFile<State>
    private let openFile: JSONFile<OpenSession>
    private let state: Locked<State>
    private let sending = Locked(false)
    private let backoff = Locked(Backoff())
    private let enabled: Bool
    let context: Context
    private let saver = DispatchQueue(label: "ai.quranlab.analytics", qos: .utility)
    private let clock: @Sendable () -> Date

    init(storage: URL, enabled: Bool, context: Context, clock: @escaping @Sendable () -> Date = { Date() }) {
        let f = JSONFile<State>(url: storage.appendingPathComponent("cloud/analytics-deltas.json"))
        file = f
        var s = f.read()
        if s == nil {
            // 2.0.0 kept whole days until they were complete: they are sealed under their own day at the next send point
            let legacy = JSONFile<[String: Day]>(url: storage.appendingPathComponent("cloud/analytics-v2.json"))
            var fresh = State()
            fresh.open = legacy.read() ?? [:]
            if !fresh.open.isEmpty { f.write(fresh) }
            legacy.delete()
            s = fresh
        }
        state = Locked(s ?? State())
        self.enabled = enabled
        self.clock = clock
        self.context = context
        openFile = JSONFile(url: storage.appendingPathComponent("cloud/session-open-v2.json"))
        recordAbortedSession()
    }

    func markSessionOpen(_ c: TelemetryCohort) {
        guard enabled else { return }
        let f = openFile, o = OpenSession(cohort: c, pid: ProcessInfo.processInfo.processIdentifier)
        saver.async { f.write(o) }
    }

    func markSessionClosed() {
        let f = openFile
        saver.async { f.delete() }
    }

    func recordAbortedSession() {
        guard let o = openFile.read(), o.pid != ProcessInfo.processInfo.processIdentifier else { return }
        openFile.delete()
        record(.sessionAborted(cohort: o.cohort))
    }

    private func mutate(_ body: (inout Day) -> Void) {
        guard enabled else { return }
        let d = TelemetryDay.string(clock())
        state.withLock { s in
            var x = s.open[d] ?? Day(day: d)
            body(&x)
            s.open[d] = x
        }
        let file = self.file, state = self.state
        saver.async { file.write(state.withLock { $0 }) }
    }

    private func cohort(_ c: TelemetryCohort, _ body: (inout Cohort) -> Void) {
        mutate { d in
            var x = d.cohorts[c.key] ?? Cohort(c)
            x.cohort.siteOverrides = c.siteOverrides
            body(&x)
            d.cohorts[c.key] = x
        }
    }

    func waitForSave() { saver.sync {} }

    /// Writes the state now (sealed deltas are on disk before they are sent).
    private func saveNow() {
        let file = self.file, state = self.state
        saver.sync { file.write(state.withLock { $0 }) }
    }

    func count(_ c: Counter) {
        mutate { d in
            switch c {
            case .launch: d.launches += 1
            case .shareAsked: d.shareAsked += 1
            case .shareYes: d.shareYes += 1
            case .shareNo: d.shareNo += 1
            }
        }
    }

    func record(_ event: AnalyticsEvent) {
        switch event {
        case .sessionFinished(let s):
            cohort(s.cohort) { c in
                c.sessions += 1
                c.minutes += s.audioSeconds / 60
                c.chunks += s.chunkSeconds.count
                for t in s.chunkSeconds {
                    c.latency[Histogram.index(t * 1000, Histogram.latency.1)] += 1
                    if s.chunkAudioSeconds > 0 { c.rtf[Histogram.index(t / s.chunkAudioSeconds, Histogram.rtf.1)] += 1 }
                }
                for k in s.checksOn { c.checksOn[k, default: 0] += 1 }
                if s.throttled { c.throttledSessions += 1 }
                c.thermalTransitions += s.thermalTransitions
                if let ms = s.coldStartMs { c.coldStart[Histogram.index(ms, Histogram.startup.1)] += 1 }
            }
        case .sessionAborted(let co):
            cohort(co) { $0.aborted += 1 }
        case .modelLoaded(_, let ms, let co):
            cohort(co) { $0.modelLoad[Histogram.index(ms, Histogram.startup.1)] += 1 }
        case .selfTest(let passed, let co):
            cohort(co) { c in if passed { c.selfTestPass += 1 } else { c.selfTestFail += 1 } }
        case .fallback(let reason, let co):
            cohort(co) { $0.fallbacks[reason.rawValue, default: 0] += 1 }
        case .scored(let s):
            cohort(s.cohort) { c in
                var sites = 0, flagged = 0
                for (k, v) in s.classes {
                    var x = c.classes[k] ?? [0, 0]
                    x[0] += v.sites; x[1] += v.flagged
                    c.classes[k] = x
                    sites += v.sites; flagged += v.flagged
                }
                if sites > 0 { c.sessionFlagPct[Histogram.index(100 * Double(flagged) / Double(sites), Histogram.flagPct.1)] += 1 }
                c.madd[0] += s.maddCounts[2] ?? 0
                c.madd[1] += s.maddCounts[4] ?? 0
                c.madd[2] += s.maddCounts[6] ?? 0
                c.madd[3] += s.maddFlagged
                c.words[0] += s.wordsScored
                c.words[1] += s.wordsFlagged
                for m in s.margins { c.margin[Histogram.index(m, Histogram.margin.1)] += 1 }
                for v in s.confidences { c.confidence[Histogram.index(v, Histogram.confidence.1)] += 1 }
            }
            mutate { d in
                if (1...114).contains(s.surah) {
                    d.coverage[String(s.surah), default: 0] += 1
                    d.surahAyahs[String(s.surah), default: 0] += 1
                }
                d.ayahs += 1
                d.words += s.wordsScored
                // what was checked and flagged, by rule: each site class, then madd, qalqalah, gemination and words
                var rules: [(String, Int, Int)] = []
                for (k, v) in s.classes { rules.append((k, v.sites, v.flagged)) }
                rules.append(("madd", s.maddCounts.values.reduce(0, +), s.maddFlagged))
                rules.append(("qalqalah", s.qalqalahChecked, s.qalqalahFlagged))
                rules.append(("gemination", s.geminationChecked, s.geminationFlagged))
                rules.append(("word", s.wordsScored, s.wordsFlagged))
                for (k, checked, flagged) in rules where checked > 0 {
                    d.ruleChecks[k, default: 0] += checked
                    if flagged > 0 { d.ruleFlags[k, default: 0] += min(flagged, checked) }
                }
            }
        case .download(let rev, let profile, let bytes, let ok, let resumed):
            mutate { d in
                var x = d.downloads["\(rev)|\(profile)"] ?? Download()
                x.bytes += bytes
                if ok { x.success += 1 } else { x.failed += 1 }
                if resumed { x.resumed += 1 }
                d.downloads["\(rev)|\(profile)"] = x
            }
        case .promotion(let t):
            let k = "\(t.backend)|\(t.revision)|\(t.context)"
            mutate { d in
                var p = d.promotions[k] ?? Promotion(backend: t.backend, revision: t.revision, context: t.context)
                switch t.kind {
                case .attempt(let promoted, let stage, let reason, let compileMs, let speedup):
                    p.attempts += 1
                    if promoted { p.promoted += 1 }
                    if !promoted, let stage, [.download, .compile, .warmup, .golden].contains(stage) { p.failedAt[stage.rawValue, default: 0] += 1 }
                    if !promoted, let reason { p.reasons[reason.rawValue, default: 0] += 1 }
                    if let compileMs { p.compileMs[Histogram.index(compileMs, Histogram.compileMs.1)] += 1 }
                    if let speedup { p.speedup[Histogram.speedupIndex(speedup)] += 1 }
                case .demoted(let reason):
                    p.reasons[reason.rawValue, default: 0] += 1
                    // a deny-list match is not a demotion (reasons.denylist only)
                    if reason == .failover { p.demoted += 1 }
                case .failover(let cause, let stallMs):
                    p.failovers += 1
                    p.failoverCauses[cause.rawValue, default: 0] += 1
                    p.failoverStall[Histogram.index(stallMs, Histogram.stallMs.1)] += 1
                }
                d.promotions[k] = p
            }
        }
    }

    /// Counted and not sealed yet, by day, for tests and for a host that shows what is sent.
    var pending: [Day] { state.withLock { Array($0.open.values) }.sorted { $0.day < $1.day } }

    /// Sealed deltas not sent yet, oldest first.
    var sealed: [Sealed] {
        state.withLock { $0.sealed }.sorted { (a: Sealed, b: Sealed) -> Bool in a.day != b.day ? a.day < b.day : a.seq < b.seq }
    }

    static func clip(_ n: Int) -> Int { max(0, min(10_000_000, n)) }
    static func hist(_ names: [String], _ v: [Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(names, v.map(clip)))
    }

    /// A rule key the server takes: `^[a-z][a-z0-9_]{0,23}$`.
    static func ruleKey(_ k: String) -> Bool {
        let u = Array(k.utf8)
        guard (1...24).contains(u.count), (97...122).contains(u[0]) else { return false }
        return u.allSatisfy { (c: UInt8) -> Bool in (97...122).contains(c) || (48...57).contains(c) || c == 95 }
    }

    /// 16 random bytes, 32 lower-case hex: drawn per delta, never per install or user.
    static func reportID() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<16).map { (_: Int) -> String in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// The v2 body of one delta (closed schema: exactly these fields, the 2.0.1 ones left out when zero, `report_id`
    /// always). Cohorts beyond 16 are merged into the 16 largest by sessions (the extras' counts go to the largest).
    func payload(_ d: Day, reportID: String) -> [String: Any] {
        var cs = d.cohorts.values.sorted { ($0.sessions, $0.cohort.key) > ($1.sessions, $1.cohort.key) }
        if cs.count > 16 {
            for extra in cs[16...] { cs[0].merge(extra) }
            cs = Array(cs[..<16])
        }
        let checks = ["letters", "vowels", "length", "madd", "gemination", "qalqalah", "lazim"]
        var cohorts: [[String: Any]] = []
        for c in cs {
            var classes: [String: Any] = [:]
            for (k, v) in c.classes { classes[k] = ["sites": Self.clip(v[0]), "flagged": Self.clip(v[1])] }
            var fallbacks: [String: Int] = [:]
            for r in FallbackReason.allCases { fallbacks[r.rawValue] = Self.clip(c.fallbacks[r.rawValue] ?? 0) }
            var on: [String: Int] = [:]
            for k in checks { on[k] = Self.clip(c.checksOn[k] ?? 0) }
            var o: [String: Any] = [:]
            o["revision"] = String(c.cohort.revision.prefix(64))
            o["context"] = c.cohort.context
            o["backend"] = c.cohort.backend
            o["preset"] = c.cohort.preset
            o["word_level"] = c.cohort.wordLevel
            o["word_bucket"] = c.cohort.wordBucket
            o["site_overrides"] = max(0, min(8, c.cohort.siteOverrides))
            o["sessions"] = Self.clip(c.sessions)
            o["minutes"] = (c.minutes * 1000).rounded() / 1000
            o["chunks"] = Self.clip(c.chunks)
            o["aborted"] = Self.clip(c.aborted)
            o["fallbacks"] = fallbacks
            o["self_test"] = ["pass": Self.clip(c.selfTestPass), "fail": Self.clip(c.selfTestFail)]
            o["latency_ms"] = Self.hist(Histogram.latency.0, c.latency)
            o["rtf"] = Self.hist(Histogram.rtf.0, c.rtf)
            o["cold_start_ms"] = Self.hist(Histogram.startup.0, c.coldStart)
            o["model_load_ms"] = Self.hist(Histogram.startup.0, c.modelLoad)
            o["thermal"] = ["transitions": Self.clip(c.thermalTransitions), "throttled_sessions": Self.clip(c.throttledSessions)]
            o["checks_on"] = on
            o["classes"] = classes
            o["session_flag_pct"] = Self.hist(Histogram.flagPct.0, c.sessionFlagPct)
            o["margin"] = Self.hist(Histogram.margin.0, c.margin)
            o["confidence"] = Self.hist(Histogram.confidence.0, c.confidence)
            o["madd"] = ["c2": Self.clip(c.madd[0]), "c4": Self.clip(c.madd[1]), "c6": Self.clip(c.madd[2]), "flagged": Self.clip(c.madd[3])]
            o["words"] = ["scored": Self.clip(c.words[0]), "flagged": Self.clip(c.words[1])]
            cohorts.append(o)
        }
        var device: [String: Any] = ["class": context.deviceClass, "os_major": context.osMajor, "ram_tier": context.ramTier]
        if let soc = context.soc { device["soc"] = soc }
        var downloads: [[String: Any]] = []
        for (k, v) in d.downloads.sorted(by: { $0.key < $1.key }) {
            let p = k.split(separator: "|", maxSplits: 1).map(String.init)
            var o: [String: Any] = ["revision": String(p[0].prefix(64)), "bytes": v.bytes]
            o["profile"] = p.count > 1 ? p[1] : "apple"
            o["success"] = Self.clip(v.success)
            o["failed"] = Self.clip(v.failed)
            o["resumed"] = Self.clip(v.resumed)
            downloads.append(o)
        }
        var p: [String: Any] = ["v": 2, "day": d.day, "product": "apple", "platform": context.platform, "sdk_version": context.sdkVersion,
                                "app_version": context.appVersion, "device": device, "cohorts": cohorts,
                                "coverage": d.coverage.mapValues(Self.clip), "downloads": downloads]
        // 2.0.1: the delta's id, and the counters (each left out when zero or empty)
        p["report_id"] = reportID
        if d.launches > 0 { p["launches"] = Self.clip(d.launches) }
        if d.ayahs > 0 { p["ayahs"] = Self.clip(d.ayahs) }
        var surahs: [String: Int] = [:]
        for (k, v) in d.surahAyahs {
            if let n = Int(k), (1...114).contains(n), v > 0 { surahs[String(n)] = min(1_000_000, v) }
        }
        if !surahs.isEmpty { p["surah_ayahs"] = surahs }
        if d.words > 0 { p["words"] = Self.clip(d.words) }
        // at most 32 rules, the most checked first; a flag count never above its check count
        let rules = d.ruleChecks.filter { (e: (key: String, value: Int)) -> Bool in e.value > 0 && Self.ruleKey(e.key) }
            .sorted { (a: (key: String, value: Int), b: (key: String, value: Int)) -> Bool in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(32)
        var ruleChecks: [String: Int] = [:], ruleFlags: [String: Int] = [:]
        for e in rules {
            ruleChecks[e.key] = Self.clip(e.value)
            let f = min(d.ruleFlags[e.key] ?? 0, e.value)
            if f > 0 { ruleFlags[e.key] = Self.clip(f) }
        }
        if !ruleChecks.isEmpty { p["rule_checks"] = ruleChecks }
        if !ruleFlags.isEmpty { p["rule_flags"] = ruleFlags }
        if d.shareAsked > 0 { p["share_asked"] = Self.clip(d.shareAsked) }
        if d.shareYes > 0 { p["share_yes"] = Self.clip(d.shareYes) }
        if d.shareNo > 0 { p["share_no"] = Self.clip(d.shareNo) }
        let promotions = Self.promotions(d.promotions)
        if !promotions.isEmpty { p["promotions"] = promotions }
        return p
    }

    /// The `promotions` array: at most 8 entries (the busiest), zero counts and empty objects left out, an entry with
    /// nothing counted left out.
    static func promotions(_ all: [String: Promotion]) -> [[String: Any]] {
        func counts(_ m: [String: Int]) -> [String: Int] { m.filter { $0.value > 0 }.mapValues(clip) }
        func hist(_ names: [String], _ v: [Int]) -> [String: Int] {
            var o: [String: Int] = [:]
            for (n, x) in zip(names, v) where x > 0 { o[n] = clip(x) }
            return o
        }
        var out: [[String: Any]] = []
        let ranked = all.values.filter { $0.activity > 0 }
            .sorted { (a: Promotion, b: Promotion) -> Bool in a.activity != b.activity ? a.activity > b.activity : (a.revision, a.context) < (b.revision, b.context) }
        for e in ranked.prefix(8) {
            var o: [String: Any] = ["backend": e.backend, "revision": String(e.revision.prefix(64)), "context": e.context]
            if e.attempts > 0 { o["attempts"] = clip(e.attempts) }
            if e.promoted > 0 { o["promoted"] = clip(e.promoted) }
            let fields: [(String, [String: Int])] = [
                ("failed_at", counts(e.failedAt)), ("reasons", counts(e.reasons)),
                ("compile_ms", hist(Histogram.compileMs.0, e.compileMs)), ("speedup", hist(Histogram.speedupNames, e.speedup)),
                ("failover_causes", counts(e.failoverCauses)), ("failover_stall_ms", hist(Histogram.stallMs.0, e.failoverStall)),
            ]
            for (k, v) in fields where !v.isEmpty { o[k] = v }
            if e.failovers > 0 { o["failovers"] = clip(e.failovers) }
            if e.demoted > 0 { o["demoted"] = clip(e.demoted) }
            out.append(o)
        }
        return out
    }

    /// Seals the open counts of every day into deltas (each its own day, a fresh report id), saved before anything is
    /// sent; deltas and counts older than 7 days go unsent. Returns how many were sealed.
    @discardableResult
    func seal() -> Int {
        let oldest = TelemetryDay.string(clock().addingTimeInterval(-7 * 86_400))
        let made = state.withLock { s -> Int in
            var n = 0
            for k in s.open.keys.sorted() {
                guard let d = s.open[k] else { continue }
                s.open[k] = nil
                guard d.day >= oldest, !d.isEmpty else { continue }
                let id = Self.reportID()
                guard let body = try? JSONSerialization.data(withJSONObject: payload(d, reportID: id), options: [.sortedKeys]) else { continue }
                s.seq += 1
                s.sealed.append(Sealed(reportID: id, day: d.day, seq: s.seq, body: body))
                n += 1
            }
            s.sealed.removeAll { $0.day < oldest }
            return n
        }
        saveNow()
        return made
    }

    /// A send point: seals what was counted, then sends every sealed delta, oldest first. 202 deletes it; a refusal
    /// (400, 413) drops it; a retryable failure (network, 5xx, 429, 401 after a new token) keeps it and the rest for
    /// later, the same bytes. Returns how many the server accepted.
    func flush(send: (Data) async throws(CloudError) -> Void) async -> Int {
        seal()
        let mine = sending.withLock { (busy: inout Bool) -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard mine else { return 0 }
        var sent = 0
        var tried = Set<String>()
        var kept = false
        while true {
            let next: Sealed? = sealed.first { !tried.contains($0.reportID) }
            guard let r = next else { break }
            tried.insert(r.reportID)
            var keep = false
            do throws(CloudError) {
                try await send(r.body)
                sent += 1
            } catch {
                keep = error.retryable
            }
            if keep {
                kept = true
                break
            }
            state.withLock { s in s.sealed.removeAll { $0.reportID == r.reportID } }
        }
        let now = clock()
        backoff.withLock { b in
            if kept {
                b.failures += 1
                b.notBefore = b.failures == 1 ? now.addingTimeInterval(60) : b.failures == 2 ? now.addingTimeInterval(600) : nil
            } else {
                b = Backoff()
            }
        }
        saveNow()
        sending.withLock { $0 = false }
        return sent
    }

    /// The timer may retry unsent deltas now (1 minute after a failure, then 10 minutes; after that only the next send
    /// point of the app's life cycle does).
    func retryDue(_ now: Date) -> Bool {
        guard state.withLock({ !$0.sealed.isEmpty }) else { return false }
        return backoff.withLock { b -> Bool in
            if b.failures == 0 { return true }
            guard let t = b.notBefore else { return false }
            return now >= t
        }
    }

    /// Drops everything queued (the signed config's `flags.analytics` is false).
    func dropAll() {
        state.withLock { $0 = State() }
        let file = self.file
        saver.async { file.delete() }
    }
}

extension AnalyticsStore.Day {
    /// Days saved by SDK 2.0.0 lack the 2.0.1 counters.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        cohorts = try c.decodeIfPresent([String: AnalyticsStore.Cohort].self, forKey: .cohorts) ?? [:]
        coverage = try c.decodeIfPresent([String: Int].self, forKey: .coverage) ?? [:]
        downloads = try c.decodeIfPresent([String: AnalyticsStore.Download].self, forKey: .downloads) ?? [:]
        launches = try c.decodeIfPresent(Int.self, forKey: .launches) ?? 0
        ayahs = try c.decodeIfPresent(Int.self, forKey: .ayahs) ?? 0
        surahAyahs = try c.decodeIfPresent([String: Int].self, forKey: .surahAyahs) ?? [:]
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        ruleChecks = try c.decodeIfPresent([String: Int].self, forKey: .ruleChecks) ?? [:]
        ruleFlags = try c.decodeIfPresent([String: Int].self, forKey: .ruleFlags) ?? [:]
        shareAsked = try c.decodeIfPresent(Int.self, forKey: .shareAsked) ?? 0
        shareYes = try c.decodeIfPresent(Int.self, forKey: .shareYes) ?? 0
        shareNo = try c.decodeIfPresent(Int.self, forKey: .shareNo) ?? 0
        promotions = try c.decodeIfPresent([String: AnalyticsStore.Promotion].self, forKey: .promotions) ?? [:]
    }
}

/// UTC day strings, the finest time anything the SDK sends carries.
enum TelemetryDay {
    static func string(_ date: Date = Date()) -> String { Day.string(date) }
}

/// An error report: the error's code and where it happened, never a message, a path, audio or an identifier.
struct IssueReport: Codable, Equatable, Sendable {
    var day: String
    var platform: String
    var sdk_version: String
    var app_version: String
    var os_version: String
    var device_class: String
    var backend: String?
    var revision: String?
    var kind: String
    var code: String
    /// Accelerator incidents only (`accelerator_failover`, `promotion_failed`): the path-stripped error message and
    /// the closed detail object.
    var message: String?
    var detail: IncidentDetail?
}

/// Error reports waiting to be sent: a capped queue on disk, at most one report per signature per day, flushed on
/// launch and shortly after a report is added.
final class IssueQueue: Sendable {
    private let file: JSONFile<[IssueReport]>
    private let items: Locked<[IssueReport]>
    let cap: Int

    init(storage: URL, cap: Int = 50) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/issues.json"))
        items = Locked(file.read() ?? [])
        self.cap = cap
    }

    var pending: [IssueReport] { items.withLock { $0 } }

    func add(_ r: IssueReport) {
        let snapshot = items.withLock { q -> [IssueReport] in
            if q.contains(r) { return q }
            q.append(r)
            if q.count > cap { q.removeFirst(q.count - cap) }
            return q
        }
        file.write(snapshot)
    }

    func dropAll() {
        items.withLock { $0 = [] }
        file.delete()
    }

    func flush(send: (Data) async throws(CloudError) -> Void) async -> Int {
        let batch = pending
        var done = 0, sent = 0
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        for r in batch {
            guard let d = try? enc.encode(r) else { done += 1; continue }
            do throws(CloudError) {
                try await send(d)
                sent += 1
                done += 1
            } catch {
                if error.retryable { break }
                done += 1
            }
        }
        let snapshot = items.withLock { q -> [IssueReport] in
            q.removeAll { r in batch.prefix(done).contains(r) }
            return q
        }
        file.write(snapshot)
        return sent
    }

    /// Kind and code for an error; nil for errors that are not faults (cancellation and misuse).
    static func classify(_ e: RecognizerError) -> (kind: String, code: String)? {
        switch e {
        case .modelMissing: return ("model_load", "model_missing")
        case .checksumMismatch: return ("checksum_mismatch", "checksum_mismatch")
        case .signatureInvalid: return ("signature_invalid", "signature_invalid")
        case .manifestInvalid: return ("model_load", "manifest_invalid")
        case .unsupportedAudioFormat: return ("audio_input", "unsupported_audio_format")
        case .neuralEngineUnavailable: return ("fallback", "ane_unavailable")
        case .engineFailed(let code, _): return ("engine_failed", "engine:\(code)")
        case .storageFailed: return ("other", "storage_failed")
        case .tajweedUnavailable: return ("model_load", "tajweed_unavailable")
        case .sessionActive, .sessionClosed, .cancelled, .serviceUnavailable,
             .offline, .serverRejected, .insufficientStorage, .updateDeferred,
             .contributionUnavailable, .microphoneUnavailable, .invalidArgument:
            return nil
        }
    }
}
