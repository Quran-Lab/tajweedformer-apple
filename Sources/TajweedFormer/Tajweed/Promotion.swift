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

/// A stage of the promotion pipeline.
public enum PromotionStage: String, Sendable, Codable, CaseIterable, Comparable {
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
    public static func < (a: PromotionStage, b: PromotionStage) -> Bool { a.order < b.order }
    /// The stage after this one, nil after `promote`.
    var next: PromotionStage? { order + 1 < Self.allCases.count ? Self.allCases[order + 1] : nil }
}

/// Why an attempt failed (the `reasons` keys of the `promotions` telemetry).
public enum PromotionReason: String, Sendable, Codable, CaseIterable {
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
    public var deterministic: Bool { [.goldenMismatch, .cpuMismatch, .nonFinite, .crash].contains(self) }

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

/// How far an accelerator's (or a replayed) decode is from the CPU engine's: counts only, never the tokens.
struct Divergence: Codable, Sendable, Equatable, Hashable {
    var tokensExpected = 0
    var tokensDiffer = 0
    var sitesDiffer = 0
    var wordsDiffer = 0

    enum CodingKeys: String, CodingKey {
        case tokensExpected = "tokens_expected", tokensDiffer = "tokens_differ", sitesDiffer = "sites_differ", wordsDiffer = "words_differ"
    }

    /// Token edits (Levenshtein), and the symmetric differences of the flagged sites and words.
    init(expected: [Int], tokens: [Int], expectedSites: Set<String>, sites: Set<String>, expectedWords: Set<Int>, words: Set<Int>) {
        tokensExpected = expected.count
        tokensDiffer = Self.edits(expected, tokens)
        sitesDiffer = expectedSites.symmetricDifference(sites).count
        wordsDiffer = expectedWords.symmetricDifference(words).count
    }

    init() {}

    var isZero: Bool { tokensDiffer == 0 && sitesDiffer == 0 && wordsDiffer == 0 }

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
    /// A failover demotes the build; it is tested again no sooner than this.
    static let failoverRetest: TimeInterval = 24 * 3600
    /// The first run of a key starts after the first session ends, or after this much time without one.
    static let idleStartDelay: TimeInterval = 20
    /// While conditions are bad (metered network for a download, Low Power Mode, battery, thermal), check again after.
    static let conditionsRecheck: TimeInterval = 120
    /// The least battery charge the pipeline runs on when not charging.
    static let minimumBattery: Float = 0.2

    /// The per-chunk deadline of the accelerator: min(300 ms, max(4 x p90, 2 x median, 50 ms)) from the measure
    /// stage's chunk times; 300 ms before a measurement exists. The 50 ms floor keeps a scheduling hiccup on a very fast
    /// build (a 4 ms ANE chunk would give 16 ms) from demoting a healthy accelerator for a day.
    static func deadlineMs(p90Ms: Double?, medianMs: Double?) -> Double {
        guard let p90Ms, let medianMs, p90Ms > 0, medianMs > 0 else { return 300 }
        return min(300, max(4 * p90Ms, 2 * medianMs, 50))
    }

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

    init(key: String) { self.key = key }

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
    var sentinelURL: URL { dir.appendingPathComponent("promotion-sentinel.json") }

    struct Sentinel: Codable, Equatable, Sendable {
        var key: String
        var stage: PromotionStage
    }

    private static let lock = NSLock()

    func all() -> [String: PromotionRecord] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return read()
    }

    private func read() -> [String: PromotionRecord] {
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

    /// Written before every compile, load and first inference; removed after. Found at launch: the process died there.
    func writeSentinel(_ key: String, _ stage: PromotionStage) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Sentinel(key: key, stage: stage)) { try? d.write(to: sentinelURL, options: .atomic) }
    }

    func clearSentinel() { try? FileManager.default.removeItem(at: sentinelURL) }

    func sentinel() -> Sentinel? { (try? Data(contentsOf: sentinelURL)).flatMap { try? JSONDecoder().decode(Sentinel.self, from: $0) } }
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
public struct PromotionTelemetry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A pipeline attempt ended: promoted, or failed at `stage` with `reason`.
        case attempt(promoted: Bool, stage: PromotionStage?, reason: PromotionReason?, compileMs: Double?, speedup: Double?)
        /// A promoted build was demoted (after a failover, or the deny-list): counted under `reasons`.
        case demoted(PromotionReason)
        /// A session switched from the accelerator to the CPU engine.
        case failover(cause: FailoverCause, stallMs: Double)
    }

    /// "ane" (as cohort backends).
    public var backend: String
    public var revision: String
    public var context: String
    public var kind: Kind

    public init(backend: String, revision: String, context: String, kind: Kind) {
        self.backend = backend
        self.revision = revision
        self.context = context
        self.kind = kind
    }
}

/// What made a session leave the accelerator (the `failover_causes` keys).
public enum FailoverCause: String, Sendable, Codable, CaseIterable {
    /// The accelerator call threw.
    case exception
    /// A head came out NaN or infinite.
    case nonFinite = "non_finite"
    /// A head left its known range (a log-probability above 0, below the floor, a probability outside 0...1).
    case outOfRange = "out_of_range"
    /// Chunks heard nothing while the audio had energy in it.
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
