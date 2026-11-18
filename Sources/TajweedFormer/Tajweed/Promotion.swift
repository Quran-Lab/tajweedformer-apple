import Foundation
#if canImport(IOKit) && os(macOS)
import IOKit.ps
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

// The promotion pipeline's vocabulary and its record on disk: one record per key, written atomically after every
// stage, so a restart (app killed, reboot) resumes at the stage after the last one recorded.
//
// Key: model revision + context + build (coreml, coreml-compact) + OS build + device model. A new revision or OS build
// is a new key: a fresh pipeline with a fresh retry budget.
//
// Stages, in order: download, compile, warmup, golden, measure, promote. Any failure keeps the CPU engine and records
// the stage and the reason. Retries for the same key: 1 h, 6 h, 24 h after the failures, then none (3 retries after the
// first attempt). Deterministic failures (golden_mismatch, cpu_mismatch, non_finite, crash) are never retried for the
// key. Speed is never a failure: a build that downloads, compiles and passes the golden test is promoted.
//
// Since 2.0.2 a promoted build is demoted by the cause of a session's failure (Failover.swift): deadline misses in 3
// sessions within 24 h, or a single confirmed blank disagreement with the CPU engine, are transient (a 6 h backoff,
// the build stays verified, never off for good); NaN, inf, a head out of range and a repeated confirmed disagreement
// turn the build off for good for the key; an exception keeps 2.0.1's rule (demoted, golden-tested again no sooner
// than 24 h later, within the retry budget). The first launch of 2.0.2 clears 2.0.1's blank and deadline demotions
// (`PromotionStore.migrate`).

/// A stage of the promotion pipeline.
enum PromotionStage: String, Sendable, Codable, CaseIterable, Comparable {
    /// The accelerator's files (CoreML package, keep table, self-test set), verified like the CPU set.
    case download
    /// The device-specific compile: the first load of the package with the Neural Engine allowed.
    case compile
    /// The compiled model loaded and run on silence and the first self-test clip: no NaN or inf.
    case warmup
    /// Every self-test clip through the accelerator and the CPU engine in the same run: the same decisions.
    case golden
    /// Speedup and the accelerator's chunk times from the golden run (telemetry, and the failover deadline).
    case measure
    /// Ready: the next session uses it.
    case promote

    var order: Int { Self.allCases.firstIndex(of: self)! }
    static func < (a: PromotionStage, b: PromotionStage) -> Bool { a.order < b.order }
    /// The stage after this one, nil after `promote`.
    var next: PromotionStage? { order + 1 < Self.allCases.count ? Self.allCases[order + 1] : nil }
}

/// Why an attempt failed (the `reasons` keys of the `promotions` telemetry).
enum PromotionReason: String, Sendable, Codable, CaseIterable {
    case network, storage, verify
    case compileError = "compile_error"
    case compileTimeout = "compile_timeout"
    case loadError = "load_error"
    case crash, hang
    case nonFinite = "non_finite"
    case goldenMismatch = "golden_mismatch"
    case cpuMismatch = "cpu_mismatch"
    case failover, denylist, other

    /// Failures that the same model revision on the same OS build would repeat: never retried for the key.
    var deterministic: Bool { [.goldenMismatch, .cpuMismatch, .nonFinite, .crash].contains(self) }

    /// The cause class of an incident report (`promotion_failed`, PLATFORM_CLIENT 7.1).
    var incidentCause: String {
        switch self {
        case .crash: return "crash_on_last_run"
        case .hang: return "timeout"
        case .nonFinite: return "nan"
        case .failover, .denylist: return "other"
        default: return rawValue
        }
    }
}

/// A stage that failed, and why.
struct PromotionFailure: Error, Sendable, Equatable {
    var reason: PromotionReason
    var detail: String
    /// The NSError domain and code behind it, when there was one (incident reports).
    var errorDomain: String?
    var errorCode: String?
    /// The self-test clip that failed and how far it diverged (golden).
    var clip: String?
    var divergence: Divergence?

    init(_ reason: PromotionReason, _ detail: String, errorDomain: String? = nil, errorCode: String? = nil, clip: String? = nil,
         divergence: Divergence? = nil) {
        self.reason = reason
        self.detail = detail
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.clip = clip
        self.divergence = divergence
    }
}

/// How far an accelerator's output is from the CPU engine's, as an incident report carries it (SDK 3.0.0): the raw
/// golden test's measures per compared head, the tolerance they were judged against, the measures that failed, and
/// the CPU run's token count. Numbers only, never the tokens. Every part is optional.
struct Divergence: Codable, Sendable, Equatable, Hashable {
    /// The measures of one head (a CTC head, or `attr` for the attribute heads together), or one head's tolerance.
    struct Head: Codable, Sendable, Equatable, Hashable {
        var tokenEdits: Int?
        var lpMean: Double?
        var lpP99: Double?
        var pMean: Double?
        var frames: Int?
        var values: Int?

        enum CodingKeys: String, CodingKey {
            case tokenEdits = "token_edits", lpMean = "lp_mean", lpP99 = "lp_p99", pMean = "p_mean", frames, values
        }

        init(tokenEdits: Int? = nil, lpMean: Double? = nil, lpP99: Double? = nil, pMean: Double? = nil, frames: Int? = nil,
             values: Int? = nil) {
            self.tokenEdits = tokenEdits
            self.lpMean = lpMean
            self.lpP99 = lpP99
            self.pMean = pMean
            self.frames = frames
            self.values = values
        }

        /// The values inside what the server takes: counts 0 to 100,000 (edits) and 100,000,000 (compared), distances 0
        /// to 30, a probability difference 0 to 1.
        var bounded: Head {
            Head(tokenEdits: tokenEdits.map { max(0, min(100_000, $0)) }, lpMean: lpMean.map { max(0, min(30, $0)) },
                 lpP99: lpP99.map { max(0, min(30, $0)) }, pMean: pMean.map { max(0, min(1, $0)) },
                 frames: frames.map { max(0, min(100_000_000, $0)) }, values: values.map { max(0, min(100_000_000, $0)) })
        }
    }

    /// The CPU run's greedy tokens (over the clean clips in the golden test; in the window of a failover).
    var tokensExpected: Int?
    /// Per compared head; nil for a head whose shapes differed.
    var heads: [String: Head?]?
    /// The build's `golden_raw_tolerance` entry, left out when it signs none.
    var tolerance: [String: Head]?
    /// The measures out of tolerance, each `<head>.<measure>`.
    var failed: [String]?

    enum CodingKeys: String, CodingKey {
        case tokensExpected = "tokens_expected", heads, tolerance, failed
    }

    init() {}

    /// A failover's divergence: the tokens the CPU engine heard in the window, and how many edits away the
    /// accelerator's were.
    init(expected: [Int], tokens: [Int]) {
        tokensExpected = expected.count
        heads = ["log_probs": .some(Head(tokenEdits: Self.edits(expected, tokens)))]
    }

    /// The token edits of `log_probs`, when the divergence has them.
    var tokenEdits: Int? { heads?["log_probs"]??.tokenEdits }

    /// The report's form: every number inside what the server takes.
    var bounded: Divergence {
        var d = self
        d.tokensExpected = tokensExpected.map { max(0, min(10_000_000, $0)) }
        d.heads = heads?.mapValues { $0?.bounded }
        d.tolerance = tolerance?.mapValues(\.bounded)
        d.failed = failed.map { Array($0.prefix(32)) }
        return d
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(tokensExpected, forKey: .tokensExpected)
        if let heads {
            // a head whose shapes differed is written as null
            var h = c.nestedContainer(keyedBy: Name.self, forKey: .heads)
            for (name, m) in heads {
                if let m { try h.encode(m, forKey: Name(name)) } else { try h.encodeNil(forKey: Name(name)) }
            }
        }
        try c.encodeIfPresent(tolerance, forKey: .tolerance)
        try c.encodeIfPresent(failed, forKey: .failed)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokensExpected = try c.decodeIfPresent(Int.self, forKey: .tokensExpected)
        if c.contains(.heads) {
            let h = try c.nestedContainer(keyedBy: Name.self, forKey: .heads)
            var out: [String: Head?] = [:]
            for k in h.allKeys { out[k.stringValue] = .some(try h.decodeNil(forKey: k) ? nil : try h.decode(Head.self, forKey: k)) }
            heads = out
        }
        tolerance = try c.decodeIfPresent([String: Head].self, forKey: .tolerance)
        failed = try c.decodeIfPresent([String].self, forKey: .failed)
    }

    /// A head name as a coding key.
    struct Name: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func edits(_ a: [Int], _ b: [Int]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
/// The constants of the pipeline and the failover, in one place.
enum PromotionPolicy {
    /// The compile stage (the first load with the Neural Engine allowed runs the ANE compiler).
    static let compileTimeout: TimeInterval = 600
    /// A later launch's load of a build compiled before (the OS's compiled cache usually answers in seconds).
    static let loadTimeout: TimeInterval = 600
    /// The warm-up's chunks (silence and the first self-test clip).
    static let warmupTimeout: TimeInterval = 120
    /// The whole golden test: every self-test clip through both engines.
    static let goldenTimeout: TimeInterval = 900
    /// Waits after failed attempts 1, 2 and 3 of a key; the 4th failure ends the key's budget.
    static let backoff: [TimeInterval] = [3600, 6 * 3600, 24 * 3600]
    /// Background stops of one attempt in a row (the system ended the app in the background during a compile, load or
    /// first inference) that end the attempt as `hang` (3.1.5); fewer cost nothing.
    static let backgroundStopsInARow = 3
    /// A failover demotes the build; it is tested again no sooner than this.
    static let failoverRetest: TimeInterval = 24 * 3600
    /// The first run of a key starts after the first session ends, or after this much time without one.
    static let idleStartDelay: TimeInterval = 20
    /// While conditions are bad (metered network for a download, Low Power Mode, battery, thermal), check again after.
    static let conditionsRecheck: TimeInterval = 120
    /// The least battery charge the pipeline runs on when not charging.
    static let minimumBattery: Float = 0.2

    /// The per-chunk deadline of the accelerator's warm chunks: min(300 ms, max(4 x p90, 2 x median, 50 ms)) from warm
    /// chunk times only (never the first chunk of a take, a warm-up or the first chunk after the app became active);
    /// 300 ms before a warm measurement exists. The 50 ms floor keeps a scheduling hiccup on a very fast build (a 4 ms
    /// ANE chunk would give 16 ms) from switching a healthy accelerator.
    static func deadlineMs(p90Ms: Double?, medianMs: Double?) -> Double {
        guard let p90Ms, let medianMs, p90Ms > 0, medianMs > 0 else { return 300 }
        return min(300, max(4 * p90Ms, 2 * medianMs, 50))
    }

    /// The limit of a cold chunk (the first of a take, the first after the app became active: the Neural Engine may be
    /// powering up): max(1000 ms, 10 x the warm p90).
    static func firstChunkLimitMs(p90Ms: Double?) -> Double { max(1000, 10 * max(0, p90Ms ?? 0)) }

    /// The fewest warm chunk times the limits are computed from; with fewer, the measure stage's p90 and median.
    static let minWarmSamples = 8
    /// Warm chunk times kept per key (the most recent).
    static let warmSamplesKept = 64

    /// Both limits from warm chunk times (ms), or from the measure stage's p90 and median when there are too few.
    static func limits(warmMs: [Double], p90Ms: Double?, medianMs: Double?) -> (firstMs: Double, laterMs: Double) {
        var p90 = p90Ms, med = medianMs
        if warmMs.count >= minWarmSamples {
            p90 = AcceleratorController.percentile(warmMs, 0.9)
            med = AcceleratorController.percentile(warmMs, 0.5)
        }
        return (firstChunkLimitMs(p90Ms: p90), deadlineMs(p90Ms: p90, medianMs: med))
    }

    /// A call that has not answered this long after its deadline is a hang: it is abandoned and the accelerator is not
    /// used again in this process (a late answer before it is only a deadline miss).
    static let hangGraceMs: Double = 2000

    /// Deadline misses demote (transiently) only when they happen in this many different sessions of a key ...
    static let missSessions = 3
    /// ... within this window.
    static let missWindow: TimeInterval = 24 * 3600
    /// The backoff of a transient demotion (deadline misses, a single confirmed blank disagreement): the build stays
    /// verified and is used again after it, without a new golden test. Not the pipeline's retry budget.
    static let transientBackoff: TimeInterval = 6 * 3600
    /// Confirmed blank disagreements with the CPU engine (any sessions) that turn the build off for good for the key.
    static let disagreementsOffForGood = 2
    /// At most one blank verification per this much audio of a session.
    static let verifyEverySeconds: Double = 10
    /// How long the end of a take waits for a blank verification still running.
    static let verifyWaitAtFinish: TimeInterval = 30

    /// The failover's target: from the failure detected to the failed chunk's CPU result. The replay window is sized so
    /// the expected stall stays under it.
    static let stallBudgetMs: Double = 250
    /// The CPU engine's chunk time and the cold open (mmap, the SDOT layout conversion, the stream) when this device
    /// has no measurement yet: an iPhone 12-class CPU, conservative.
    static let defaultCPUChunkMs: Double = 25
    static let defaultCPUOpenMs: Double = 120
    /// The audio the take keeps for a replay (16 kHz float: 30 s is 1.9 MB).
    static let ringSeconds: Double = 30
}

/// The persisted state of one key.
struct PromotionRecord: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        /// Nothing failed for good: an attempt may run (or is running) when conditions allow.
        case pending
        /// An attempt failed; the next may start at `notBefore`.
        case retry
        /// Promoted: sessions use the build once it is loaded and warm in this launch.
        case ready
        /// No more attempts for this key (a deterministic failure, or the budget is used up).
        case failed
    }

    var key: String
    var status: Status = .pending
    /// The last stage completed by the attempt in progress (nil: the next attempt starts at `download`).
    var completed: PromotionStage?
    /// Attempts started, and attempts that failed (the retry budget).
    var attempts = 0
    var failures = 0
    /// When the attempt in progress started; nil when none is in progress.
    var attemptStarted: Date?
    /// The launch that started the attempt in progress (at most one attempt per launch for a key).
    var launch: String?
    var notBefore: Date?
    var lastStage: PromotionStage?
    var lastReason: PromotionReason?
    var lastDetail: String?
    /// Measured by the attempt that promoted (or the last one that got that far).
    var compileMs: Double?
    var acceleratorMedianMs: Double?
    var acceleratorP90Ms: Double?
    var cpuMedianMs: Double?
    /// The deny-list matched this key (counted once, not a failure of the budget).
    var denied = false
    /// The SHA-256 of the program the promoted build runs (its `weights/weight.bin`): a different or missing program
    /// at a later launch runs the golden test again.
    var programSHA256: String?
    // 2.0.2 (optional, so 2.0.1 records decode)
    /// The cause of the last session failure that demoted the build.
    var lastCause: FailoverCause?
    /// A transient demotion: the promoted build (still `ready`, still verified) is not used before this time.
    var backoffUntil: Date?
    /// The sessions with a deadline miss in the last 24 h.
    var missSessions: [DeadlineMiss]?
    /// Confirmed blank disagreements with the CPU engine, any sessions.
    var disagreements: Int?
    /// The most recent warm chunk times of the accelerator, ms (the golden test's, then the sessions'): the limits.
    var warmChunkMs: [Double]?
    // 3.0.0 (optional, so earlier records decode)
    /// What this key's last golden test measured against the CPU engine, per compared head: token edits and log-prob
    /// distances of the CTC heads, the mean probability difference of the attribute heads, and the tolerance in
    /// force when the build has one. Recorded also for a build judged on tokens alone, and for a test that failed
    /// (its `failed` then names the measures that decided it).
    var golden: Divergence?
    // 3.1.5 (optional, so earlier records decode)
    /// Stages this key's attempts were stopped in by a quit or by the system (never a failure), all attempts.
    var stops: Int?
    /// Background stops of the attempt in progress in a row (`PromotionPolicy.backgroundStopsInARow`).
    var backgroundStops: Int?
    /// Download stages in a row that the network stopped or that had no room: they set the backoff (1 h, 6 h, then
    /// 24 h) and never count against the retry budget.
    var downloadStops: Int?

    struct DeadlineMiss: Codable, Sendable, Equatable {
        var session: String
        var at: Date
    }

    init(key: String) { self.key = key }

    /// Whether a transient demotion keeps the build off now.
    func backedOff(_ now: Date) -> Bool { backoffUntil.map { now < $0 } ?? false }

    var speedup: Double? {
        guard let a = acceleratorMedianMs, let c = cpuMedianMs, a > 0 else { return nil }
        return c / a
    }

    /// Where the attempt in progress continues: the stage after the last one recorded.
    var resumeStage: PromotionStage { completed?.next ?? .download }
}

/// The records and the crash sentinel on disk (Application Support, excluded from backup).
struct PromotionStore: Sendable {
    let dir: URL
    var recordsURL: URL { dir.appendingPathComponent("promotions.json") }
    /// The one sentinel of SDKs to 3.1.4, shared by every process of the app (read once by 3.1.5, never written).
    var sentinelURL: URL { dir.appendingPathComponent("promotion-sentinel.json") }

    struct Sentinel: Codable, Equatable, Sendable {
        var key: String
        var stage: PromotionStage
        // 3.1.5 (optional, so an earlier SDK's sentinel decodes)
        /// The process that wrote it, and when.
        var pid: Int32?
        var at: Date?
    }

    /// How the process that left a sentinel ended, as far as the device can tell (3.1.5).
    enum Exit: String, Sendable, Equatable {
        /// No mark: the process died in the stage while the app was in front (or a process with no app state).
        case crash
        /// A normal exit (`exit`, returning from `main`), the app's willTerminate, or on the Mac SIGINT or SIGTERM.
        case quit
        /// The app was in the background when it ended: the system stopped it (suspended, then ended).
        case background
        /// A sentinel of an SDK to 3.1.4, which kept no mark.
        case unknown
    }

    /// A sentinel whose process is gone, with how it ended.
    struct Stranded: Sendable, Equatable {
        var sentinel: Sentinel
        var exit: Exit
    }

    /// 3.1.5: one sentinel per process, `promotion-sentinel-<pid>.json`, beside its lock (`.lock`, held with `flock`
    /// while the stage runs, so another process of the app can tell a stage under way from one whose process is gone:
    /// the system drops the lock when a process ends, however it ends) and its marks (`.quit`, `.background`).
    func sentinelURL(pid: Int32) -> URL { dir.appendingPathComponent("promotion-sentinel-\(pid).json") }
    func sentinelFile(pid: Int32, _ ext: String) -> URL { dir.appendingPathComponent("promotion-sentinel-\(pid).\(ext)") }

    private static let lock = NSLock()

    func all() -> [String: PromotionRecord] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return read()
    }

    private func read() -> [String: PromotionRecord] {
        // unreadable is taken as not there here (3.1.4 leaves the accelerator's verdicts as they were): the
        // pipeline then starts again for this model, on the CPU meanwhile
        (try? Data(contentsOf: recordsURL)).flatMap { try? PromotionRecord.decoder().decode([String: PromotionRecord].self, from: $0) } ?? [:]
    }

    func record(_ key: String) -> PromotionRecord? { all()[key] }

    /// Writes one record (atomically: the whole file is replaced).
    func save(_ r: PromotionRecord) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var a = read()
        a[r.key] = r
        write(a)
    }

    private func write(_ a: [String: PromotionRecord]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var u = dir
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(a) { try? d.write(to: recordsURL, options: .atomic) }
    }

    /// Written before every compile, load and first inference; removed after. Found later with its process gone: the
    /// process ended there (`takeStranded`). This process's own, under its lock (3.1.5).
    /// Tried before (to 3.1.4): one file for every process of the app and no way to tell how a process ended, so a
    /// normal exit during a stage (a command-line tool returning from `main`, an app quit in its first seconds) and a
    /// second process of the app starting while the first was in a stage were both taken for a crash, which turns the
    /// build off for good for the key.
    func writeSentinel(_ key: String, _ stage: PromotionStage) {
        let pid = ProcessInfo.processInfo.processIdentifier
        writeSentinel(Sentinel(key: key, stage: stage, pid: pid, at: Date()))
    }

    /// A sentinel as given (tests: another process's, by its pid).
    func writeSentinel(_ s: Sentinel) {
        Self.sentinelLock.lock()
        defer { Self.sentinelLock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pid = s.pid ?? ProcessInfo.processInfo.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier {
            // the lock first: a sentinel is never on disk without its process holding the lock
            StageSentinel.shared.begin(lock: sentinelFile(pid: pid, "lock"), quit: sentinelFile(pid: pid, "quit"),
                                       background: sentinelFile(pid: pid, "background"))
        }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: sentinelURL(pid: pid), options: .atomic) }
    }

    /// Removes this process's sentinel, its marks and its lock.
    func clearSentinel() {
        Self.sentinelLock.lock()
        defer { Self.sentinelLock.unlock() }
        let pid = ProcessInfo.processInfo.processIdentifier
        let fm = FileManager.default
        StageSentinel.shared.disarm()
        try? fm.removeItem(at: sentinelURL(pid: pid))
        try? fm.removeItem(at: sentinelFile(pid: pid, "quit"))
        try? fm.removeItem(at: sentinelFile(pid: pid, "background"))
        StageSentinel.shared.end(lock: sentinelFile(pid: pid, "lock"))
    }

    private static let sentinelLock = NSLock()

    // unreadable is taken as not there here (3.1.4 leaves the accelerator's files as they were): a crash of the
    // launch before is then not counted against the accelerator
    /// This process's sentinel, while one of its stages runs.
    func sentinel() -> Sentinel? {
        let url = sentinelURL(pid: ProcessInfo.processInfo.processIdentifier)
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Sentinel.self, from: $0) }
    }

    /// The sentinels whose process is gone, each with how it ended, removed as they are read: an earlier SDK's one
    /// sentinel (`unknown`), and every process's own whose lock no process holds. A sentinel whose lock is held belongs
    /// to a stage under way in a process of this app (another one, or this one): it is left as it is.
    func takeStranded() -> [Stranded] {
        Self.sentinelLock.lock()
        defer { Self.sentinelLock.unlock() }
        let fm = FileManager.default
        var out: [Stranded] = []
        if let d = try? Data(contentsOf: sentinelURL) {
            if let s = try? JSONDecoder().decode(Sentinel.self, from: d) { out.append(Stranded(sentinel: s, exit: .unknown)) }
            try? fm.removeItem(at: sentinelURL)
        }
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        for name in names where name.hasPrefix("promotion-sentinel-") && name.hasSuffix(".json") {
            guard let pid = Int32(name.dropFirst("promotion-sentinel-".count).dropLast(".json".count)) else { continue }
            if StageSentinel.isHeld(sentinelFile(pid: pid, "lock")) { continue }
            let quit = fm.fileExists(atPath: sentinelFile(pid: pid, "quit").path)
            let background = fm.fileExists(atPath: sentinelFile(pid: pid, "background").path)
            if let d = try? Data(contentsOf: sentinelURL(pid: pid)), let s = try? JSONDecoder().decode(Sentinel.self, from: d) {
                out.append(Stranded(sentinel: s, exit: quit ? .quit : background ? .background : .crash))
            }
            for ext in ["json", "quit", "background", "lock"] { try? fm.removeItem(at: sentinelFile(pid: pid, ext)) }
        }
        return out
    }

    /// Forgets this device's verdict on one key (`TajweedModel.prepareAccelerator(again: true)`, 3.1.5).
    func remove(_ key: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var a = read()
        guard a.removeValue(forKey: key) != nil else { return }
        write(a)
    }

    // MARK: the upgrade to 3.1.5

    var migrated315URL: URL { dir.appendingPathComponent("migrated-3.1.5") }

    /// Once per store (a marker file written after it): the verdicts an SDK to 3.1.4 could not get right get one more
    /// attempt, at the next run of their key.
    /// - `crash` at compile, warm-up or golden: SDKs to 3.1.4 took a normal exit or a stop by the system in the
    ///   background for a crash (the server saw them on every iPhone generation alike). A real crash is seen again,
    ///   and 3.1.5 tells it from a quit.
    /// - `verify` at download, and a download stage that used up the retry budget (`network`, `storage`): SDKs to
    ///   3.1.4 refused a correct download after an interrupted one (the working file in the CoreML package).
    /// Every other verdict stays. Returns the keys given another attempt.
    @discardableResult
    func migrate315() -> [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !FileManager.default.fileExists(atPath: migrated315URL.path) else { return [] }
        var all = read()
        var again: [String] = []
        for (k, r0) in all where r0.status == .failed || r0.status == .retry {
            let stages: [PromotionStage] = [.compile, .warmup, .golden]
            let reasons: [PromotionReason] = [.verify, .network, .storage]
            let crash = r0.lastReason == .crash && (r0.lastStage.map { stages.contains($0) } ?? false)
            let download = r0.lastStage == .download && (r0.lastReason.map { reasons.contains($0) } ?? false)
            guard crash || download else { continue }
            var r = r0
            r.status = .retry
            r.notBefore = nil
            r.launch = nil
            r.failures = min(r.failures, PromotionPolicy.backoff.count)
            all[k] = r
            again.append(k)
        }
        if !again.isEmpty { write(all) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("3.1.5\n".utf8).write(to: migrated315URL, options: .atomic)
        return again.sorted()
    }

    // MARK: the upgrade from 2.0.1

    var migratedURL: URL { dir.appendingPathComponent("migrated-2.0.2") }

    /// Once per store (a marker file written after it): every 2.0.1 record demoted or turned off by a blank or deadline
    /// failover (2.0.1 recorded reason `failover`, the cause only in its detail text) is cleared and goes back to the
    /// golden stage: the next run loads and warms the build, runs the golden test again in the background and promotes
    /// as usual. Records with any other cause (NaN, a golden or CPU mismatch, a crash, an exception, ...) stay as they
    /// are. Returns the keys cleared.
    @discardableResult
    func migrate(now: Date) -> [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !FileManager.default.fileExists(atPath: migratedURL.path) else { return [] }
        var all = read()
        var cleared: [String] = []
        for (k, r0) in all where Self.isBlankOrDeadline201(r0) {
            var r = r0
            r.status = .pending
            // the attempt resumes after the warm-up: the build is loaded and warmed again, then the golden test
            r.completed = .warmup
            r.attemptStarted = now
            r.launch = nil
            r.failures = 0
            r.notBefore = nil
            r.lastStage = nil
            r.lastReason = nil
            r.lastDetail = nil
            r.lastCause = nil
            r.backoffUntil = nil
            r.missSessions = nil
            r.disagreements = nil
            all[k] = r
            cleared.append(k)
        }
        if !cleared.isEmpty { write(all) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("2.0.2\n".utf8).write(to: migratedURL, options: .atomic)
        return cleared.sorted()
    }

    /// A 2.0.1 record (not promoted now) whose demotion or off-for-good came from a blank or deadline failover.
    static func isBlankOrDeadline201(_ r: PromotionRecord) -> Bool {
        guard r.status != .ready, r.lastReason == .failover, let d = r.lastDetail else { return false }
        if r.lastCause == .blank || r.lastCause == .deadline { return true }
        // 2.0.1's detail texts: "failover: 3 chunks in a row heard nothing in audio with energy", "failover: no answer
        // within 55 ms", "failover: a chunk took 61.2 ms (deadline 50 ms)"
        return d.contains("heard nothing") || d.contains("no answer within") || d.contains("(deadline ")
    }
}

extension PromotionRecord {
    // dates as seconds since 1970, as the store writes them
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

/// Whether the device is in a state to run the pipeline now; why not, when it is not.
struct PromotionConditions: Sendable, Equatable {
    var lowPower = false
    var battery: Float?        // 0...1, nil when unknown or no battery
    var charging = false
    var thermal: ProcessInfo.ThermalState = .nominal
    var unmetered = true

    /// Nil when the pipeline may run a stage (`download` also needs an unmetered network); else why it waits.
    func blocker(for stage: PromotionStage) -> String? {
        if lowPower { return "Low Power Mode" }
        if let b = battery, b >= 0, b < PromotionPolicy.minimumBattery, !charging { return "battery below 20 %" }
        if thermal == .serious || thermal == .critical { return "thermal state" }
        if stage == .download && !unmetered { return "a metered network" }
        return nil
    }

    var thermalName: String {
        switch thermal {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    /// The device now. The network check runs only when `network` is true (it waits for a path update).
    static func current(network: Bool) async -> PromotionConditions {
        var c = PromotionConditions()
        c.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        c.thermal = ProcessInfo.processInfo.thermalState
        let (level, charging) = await battery()
        c.battery = level
        c.charging = charging
        if network { c.unmetered = await ModelUpdater.onUnmeteredNetwork() }
        return c
    }

    /// The battery charge (nil without a battery) and whether it is charging or full.
    static func battery() async -> (Float?, Bool) {
        #if canImport(UIKit) && os(iOS)
        return await MainActor.run { () -> (Float?, Bool) in
            let d = UIDevice.current
            let was = d.isBatteryMonitoringEnabled
            d.isBatteryMonitoringEnabled = true
            defer { d.isBatteryMonitoringEnabled = was }
            let level = d.batteryLevel
            let state = d.batteryState
            return (level < 0 ? nil : level, state == .charging || state == .full)
        }
        #elseif canImport(IOKit) && os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return (nil, true) }
        for ps in (list as NSArray) {
            guard let d = IOPSGetPowerSourceDescription(info, ps as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (max > 0 ? Float(cur) / Float(max) : nil, onAC || (d[kIOPSIsChargingKey] as? Bool ?? false))
        }
        return (nil, true)
        #else
        return (nil, true)
        #endif
    }
}

/// One promotions telemetry event: an attempt that ended (promoted, or failed at a stage), a demotion, or a failover.
struct PromotionTelemetry: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        /// A pipeline attempt ended: promoted, or failed at `stage` with `reason`.
        case attempt(promoted: Bool, stage: PromotionStage?, reason: PromotionReason?, compileMs: Double?, speedup: Double?)
        /// A promoted build was demoted (after a failover, or the deny-list): counted under `reasons`.
        case demoted(PromotionReason)
        /// A session switched from the accelerator to the CPU engine.
        case failover(cause: FailoverCause, stallMs: Double)
        /// The blank rule fired and the CPU engine, replaying the same audio, agreed (it heard nothing either): no
        /// failover, no demotion (`blank_confirmed_ok`).
        case blankConfirmedOK
    }

    /// "ane" (as cohort backends).
    var backend: String
    /// The model version (SDK 3.0.0), and its build (empty when it is not known).
    var revision: String
    var build: String
    var context: String
    var kind: Kind

    init(backend: String, revision: String, build: String = "", context: String, kind: Kind) {
        self.backend = backend
        self.revision = revision
        self.build = build
        self.context = context
        self.kind = kind
    }
}

/// What made a session leave the accelerator (the `failover_causes` keys).
enum FailoverCause: String, Sendable, Codable, CaseIterable {
    /// The accelerator call threw.
    case exception
    /// A head came out NaN or infinite.
    case nonFinite = "non_finite"
    /// A head left its known range (a log-probability above 0, below the floor, a probability outside 0...1).
    case outOfRange = "out_of_range"
    /// Chunks heard nothing while the audio had energy in it, and the CPU engine, replaying the same audio, heard
    /// something there (since 2.0.2 only a confirmed disagreement is a failover).
    case blank
    /// A chunk missed its deadline (a hung call is abandoned).
    case deadline

    /// The cause class of an incident report (`accelerator_failover`, PLATFORM_CLIENT 7.1).
    var incidentCause: String {
        switch self {
        case .exception: return "exception"
        case .nonFinite: return "nan"
        case .outOfRange: return "out_of_range"
        case .blank: return "blank"
        case .deadline: return "timeout"
        }
    }
}
