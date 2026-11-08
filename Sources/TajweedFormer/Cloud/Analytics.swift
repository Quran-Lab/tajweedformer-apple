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
    /// The correction could not rebuild the CPU weights; they were downloaded instead (host diagnostics only).
    case correctionFallback(reason: String)
}

/// Receives every analytics event besides the SDK's own daily aggregates. Called on the recognition path: return
/// at once.
public protocol AnalyticsSink: Sendable {
    func record(_ event: AnalyticsEvent)
}

/// On-device daily aggregates, telemetry v2: sums and histograms per UTC day and
/// cohort, the surah coverage, and the downloads. Recording is a lock and a few additions; the aggregates are saved
/// on a utility queue and sent once a day is complete, one `POST /v1/events` per day (at most 7 days kept).
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

    struct Day: Codable, Equatable {
        var day: String
        var cohorts: [String: Cohort] = [:]
        var coverage: [String: Int] = [:]
        var downloads: [String: Download] = [:]   // "revision|profile"
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

    private let file: JSONFile<[String: Day]>
    private let openFile: JSONFile<OpenSession>
    private let days: Locked<[String: Day]>
    private let enabled: Bool
    let context: Context
    private let saver = DispatchQueue(label: "ai.quranlab.analytics", qos: .utility)
    private let clock: @Sendable () -> Date

    init(storage: URL, enabled: Bool, context: Context, clock: @escaping @Sendable () -> Date = { Date() }) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/analytics-v2.json"))
        days = Locked(file.read() ?? [:])
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
        days.withLock { all in
            var x = all[d] ?? Day(day: d)
            body(&x)
            all[d] = x
        }
        let file = self.file, days = self.days
        saver.async { file.write(days.withLock { $0 }) }
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
            if (1...114).contains(s.surah) { mutate { $0.coverage[String(s.surah), default: 0] += 1 } }
        case .download(let rev, let profile, let bytes, let ok, let resumed):
            mutate { d in
                var x = d.downloads["\(rev)|\(profile)"] ?? Download()
                x.bytes += bytes
                if ok { x.success += 1 } else { x.failed += 1 }
                if resumed { x.resumed += 1 }
                d.downloads["\(rev)|\(profile)"] = x
            }
        case .correctionFallback:
            break
        }
    }

    /// Everything recorded and not yet sent, for tests and for a host that shows what is sent.
    var pending: [Day] { days.withLock { Array($0.values) }.sorted { $0.day < $1.day } }

    static func clip(_ n: Int) -> Int { max(0, min(10_000_000, n)) }
    static func hist(_ names: [String], _ v: [Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: zip(names, v.map(clip)))
    }

    /// The v2 body for one day (closed schema: exactly these fields). Cohorts beyond 16 are merged into the 16
    /// largest by sessions (the extras' counts go to the largest).
    func payload(_ d: Day) -> [String: Any] {
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
        return ["v": 2, "day": d.day, "product": "apple", "platform": context.platform, "sdk_version": context.sdkVersion,
                "app_version": context.appVersion, "device": device, "cohorts": cohorts,
                "coverage": d.coverage.mapValues(Self.clip), "downloads": downloads]
    }

    /// Uploads every complete day (`force`: today too). 202 deletes the day, 400/413 drops it, anything retryable
    /// keeps it. Days older than 7 are dropped unsent. Returns how many days the server accepted.
    func flush(send: (Data) async throws(CloudError) -> Void, force: Bool = false) async -> Int {
        let today = TelemetryDay.string(clock())
        let oldest = TelemetryDay.string(clock().addingTimeInterval(-7 * 86_400))
        let due = days.withLock { all -> [Day] in
            for (k, d) in all where d.day < oldest { all[k] = nil }
            return all.values.filter { force || $0.day < today }.sorted { $0.day < $1.day }
        }
        var sent = 0
        for d in due {
            guard let body = try? JSONSerialization.data(withJSONObject: payload(d), options: [.sortedKeys]) else { continue }
            var drop = true
            do throws(CloudError) {
                try await send(body)
                sent += 1
            } catch {
                if error.retryable { drop = false }
            }
            if drop { days.withLock { all in if all[d.day] == d { all[d.day] = nil } } }
            if !drop { break }
        }
        let file = self.file, days = self.days
        saver.async { file.write(days.withLock { $0 }) }
        waitForSave()
        return sent
    }

    /// Drops everything queued (the signed config's `flags.analytics` is false).
    func dropAll() {
        days.withLock { $0 = [:] }
        let file = self.file
        saver.async { file.delete() }
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
