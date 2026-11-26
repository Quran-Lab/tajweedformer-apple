import Foundation

// Live promotion (SDK 4.0.5, contract section 30, `sdk_4.0.0/LIVE_PROMOTION_41.md`): the rules and the take's decide,
// pure (no clock, no I/O, Foundation only), one to one with the contract's reference `tools/live41.py`, so the vectors
// (`live_41.json`, format 2) replay them as they are. The take runner (Failover.swift) feeds `LiveTake` the events of a
// take that started on the CPU engine and carries out the actions it returns; LivePromotion.swift holds what needs the
// SDK (the window's judgement with the golden test's rule, the config's value, diagnose()).

enum LiveRules {
    static let rate = 16_000
    /// 30.3: the take's audio ring (the failover's).
    static let ringSeconds = 30
    static let ringSamples = ringSeconds * rate
    /// The take's 20-minute limit, and 30.2 item 10: no attempt after 60 s before it.
    static let takeLimitSeconds = 1200
    static let latestStartSeconds = Double(takeLimitSeconds - 60)
    /// 30.2 item 11: a take from samples or a file needs this much of its source left.
    static let sourceLeftMinSeconds = 10.0
    /// 30.4: a window covers this much audio, and at least `shadowMinChunks` chunks.
    static let shadowMs = 2000
    static let shadowMinChunks = 4
    /// 30.4: windows a replay that is not exact may take to pass.
    static let inexactWindows = 3
    /// 30.4: an accelerator stream's per-chunk tables are steady from this chunk of its own on.
    static let steadyChunks = 33
    /// 30.5: a pause is this many 40 ms frames of blank or word bar at the end of a chunk.
    static let pauseFrames = 2
    /// 30.5: no pause within this much audio from the commit's chunk on: the swap is made anyway.
    static let swapCapMs = 8000
    /// 30.5: a stall that keeps the swap off this long from the commit's chunk on ends the attempt.
    static let stallWaitMs = 20_000
    static let blank = 0

    /// 30.2: why an attempt does not start, in the section's order.
    static let reasons = ["config_off", "app_cpu", "not_on_cpu", "attempted", "failed_over", "low_power", "battery", "thermal",
                          "stall", "near_limit", "near_source_end", "finishing"]
    /// 30.9: the reasons a take is counted under in `held`.
    static let held = ["config_off", "failed_over", "low_power", "battery", "thermal", "stall", "near_limit", "near_source_end",
                       "finishing"]
    /// 30.6, in the order of 30.9.
    static let outcomes = ["swapped", "mismatch", "mismatch_inexact", "accel_failed", "stalled", "aborted"]
    static let latencyBounds = [500, 1000, 2000, 5000, 10_000, 20_000]
    static let latencyKeys = ["le_500", "le_1000", "le_2000", "le_5000", "le_10000", "le_20000", "gt_20000"]
    /// 30.9: the bounds the server checks.
    static let countMax = 10_000_000
    static let secondsMax = 10_000_000.0

    /// 30.1: the chunk of a context `c<C>_l<L>`, ms (C frames of 20 ms).
    static func chunkMs(context: String) -> Int? {
        let parts = String(context.dropFirst()).components(separatedBy: "_l")
        guard context.hasPrefix("c"), parts.count == 2, let c = Int(parts[0]), Int(parts[1]) != nil, c > 0 else { return nil }
        return c * 20
    }

    /// The samples between two chunks' starts.
    static func advance(chunkMs: Int) -> Int { chunkMs * rate / 1000 }

    static func ceilDiv(_ a: Int, _ b: Int) -> Int { b <= 0 ? 0 : (a >= 0 ? (a + b - 1) / b : -((-a) / b)) }

    // MARK: 30.2

    /// The pipeline's own conditions and what the Session knows (items 6 to 8, 11, 12).
    struct Device: Sendable, Equatable {
        var lowPower = false
        /// 0...1; nil when the device has no battery or does not say.
        var battery: Double?
        var charging = false
        /// `nominal`, `fair`, `serious` or `critical`.
        var thermal = "nominal"
        /// The app asked the take to finish.
        var finishing = false
        /// A take from samples or a file: seconds of its source not taken yet; nil for the microphone.
        var sourceLeftSeconds: Double?
    }

    /// A change of some of `Device` (a `cond` event): the fields set here replace the take's.
    struct DeviceChange: Sendable, Equatable {
        var lowPower: Bool?
        var battery: Double?
        var charging: Bool?
        var thermal: String?
        var finishing: Bool?
        var sourceLeftSeconds: Double?

        init(lowPower: Bool? = nil, battery: Double? = nil, charging: Bool? = nil, thermal: String? = nil, finishing: Bool? = nil,
             sourceLeftSeconds: Double? = nil) {
            self.lowPower = lowPower
            self.battery = battery
            self.charging = charging
            self.thermal = thermal
            self.finishing = finishing
            self.sourceLeftSeconds = sourceLeftSeconds
        }

        /// Every field of `d`.
        init(_ d: Device) {
            self.init(lowPower: d.lowPower, battery: d.battery, charging: d.charging, thermal: d.thermal, finishing: d.finishing,
                      sourceLeftSeconds: d.sourceLeftSeconds)
        }

        func apply(to d: inout Device) {
            if let v = lowPower { d.lowPower = v }
            if let v = battery { d.battery = v }
            if let v = charging { d.charging = v }
            if let v = thermal { d.thermal = v }
            if let v = finishing { d.finishing = v }
            if let v = sourceLeftSeconds { d.sourceLeftSeconds = v }
        }
    }

    /// What the start rule reads.
    struct Conditions: Sendable, Equatable {
        /// `flags.live_promotion` is not false.
        var flagOn = true
        /// The app asked for the CPU engine.
        var appCPU = false
        var onCPU = true
        var attempted = false
        var failedOver = false
        var stall = false
        /// The take's audio so far, seconds.
        var takeSeconds = 0.0
        var device = Device()
    }

    /// 30.2 items 6 to 8, the promotion pipeline's own conditions (also while an attempt runs).
    static func pipelineBlocker(_ d: Device) -> String? {
        if d.lowPower { return "low_power" }
        if let b = d.battery, b < 0.2, !d.charging { return "battery" }
        if d.thermal != "nominal" && d.thermal != "fair" { return "thermal" }
        return nil
    }

    /// 30.2: nil when a live promotion starts now, else the first reason in the section's order.
    static func start(_ c: Conditions) -> String? {
        if !c.flagOn { return "config_off" }
        if c.appCPU { return "app_cpu" }
        if !c.onCPU { return "not_on_cpu" }
        if c.attempted { return "attempted" }
        if c.failedOver { return "failed_over" }
        if let r = pipelineBlocker(c.device) { return r }
        if c.stall { return "stall" }
        if c.takeSeconds > latestStartSeconds { return "near_limit" }
        if let left = c.device.sourceLeftSeconds, left < sourceLeftMinSeconds { return "near_source_end" }
        if c.device.finishing { return "finishing" }
        return nil
    }

    // MARK: 30.3

    struct ReplayPlan: Sendable, Equatable {
        let fromSample: Int
        let samples: Int
        let firstChunk: Int
        /// The whole take is replayed.
        let exact: Bool
    }

    /// 30.3: `from_sample = ceil(max(0, n - ring) / advance) x advance`.
    static func replayPlan(chunkMs: Int, taken n: Int) -> ReplayPlan {
        let a = advance(chunkMs: chunkMs)
        let s0 = ceilDiv(max(0, n - ringSamples), a) * a
        return ReplayPlan(fromSample: s0, samples: n - s0, firstChunk: s0 / a, exact: s0 == 0)
    }

    // MARK: 30.4

    /// The chunks of one window: max(4, ceil(2000 ms / chunk)).
    static func shadowChunks(chunkMs: Int) -> Int { max(shadowMinChunks, ceilDiv(shadowMs, chunkMs)) }

    /// The first take chunk both engines' outputs may be compared at.
    static func comparableFrom(_ p: ReplayPlan) -> Int { p.firstChunk + (p.exact ? 0 : steadyChunks) }

    /// The first window from the newest take chunk both engines had computed when the accelerator caught up: the newest
    /// W comparable chunks, or the first W comparable ones when fewer exist yet. Inclusive bounds.
    static func firstWindow(chunkMs: Int, plan: ReplayPlan, newest: Int) -> ClosedRange<Int> {
        let w = shadowChunks(chunkMs: chunkMs)
        let last = max(newest, comparableFrom(plan) + w - 1)
        return (last - w + 1)...last
    }

    /// A window's verdict.
    enum Verdict: String, Sendable, Equatable {
        case within
        case outside
        /// An accelerator failure in it, whatever its values.
        case failed
    }

    /// 30.4, the commit rule: `commit`, `pending`, or the outcome; with the window that decided it (for `pending`, the
    /// number of windows judged).
    static func shadowOutcome(exact: Bool, windows: [Verdict]) -> (result: String, window: Int) {
        let limit = exact ? 1 : inexactWindows
        for (i, w) in windows.prefix(limit).enumerated() {
            if w == .failed { return ("accel_failed", i) }
            if w == .within { return ("commit", i) }
        }
        if windows.count < limit { return ("pending", windows.count) }
        return (exact ? "mismatch" : "mismatch_inexact", limit - 1)
    }

    // MARK: 30.5

    /// A pause: the last `pauseFrames` greedy ids of a chunk are each the blank or the word bar.
    static func isPause(tail: [Int], bar: Int?) -> Bool {
        let t = tail.suffix(pauseFrames)
        return t.count == pauseFrames && t.allSatisfy { $0 == blank || $0 == bar }
    }

    /// 30.5 for CPU chunk k (the newest handed out, k >= the commit's chunk): `swap` (the accelerator serves from
    /// k + 1), `wait` or `stalled`.
    static func swapStep(chunkMs: Int, commitChunk: Int, k: Int, tail: [Int], stalled: Bool, bar: Int?) -> String {
        let i = k - commitChunk + 1
        if !stalled && (isPause(tail: tail, bar: bar) || i >= ceilDiv(swapCapMs, chunkMs)) { return "swap" }
        if i >= ceilDiv(stallWaitMs, chunkMs) { return "stalled" }
        return "wait"
    }

    // MARK: 30.6, 30.9

    /// 30.6: what an outcome writes into the promotion record: `disagreement`, `deadline_miss`, `by_cause`, or nil.
    static func recordRule(_ outcome: String) -> String? {
        switch outcome {
        case "mismatch": return "disagreement"
        case "mismatch_inexact": return "deadline_miss"
        case "accel_failed": return "by_cause"
        default: return nil
        }
    }

    static func latencyKey(ms: Int) -> String {
        for (b, k) in zip(latencyBounds, latencyKeys) where ms <= b { return k }
        return latencyKeys[latencyKeys.count - 1]
    }

    /// Seconds of audio to 0.1, rounded down.
    static func tenths(samples: Int) -> Double { Double(max(0, samples) * 10 / rate) / 10 }

    /// 30.9: the first field of a promotions entry's `live` object the server refuses (400, the whole delta), or nil.
    /// `e` as JSONSerialization reads it.
    static func liveProblem(_ e: Any) -> String? {
        guard let o = e as? [String: Any] else { return "live" }
        let allowed = Set(["attempts"] + outcomes + ["held", "latency_ms", "seconds_after_swap"])
        for k in o.keys.sorted() where !allowed.contains(k) { return "live." + k }
        guard o["attempts"] != nil else { return "live.attempts" }
        for k in ["attempts"] + outcomes { if let v = o[k], count(v) == nil { return "live." + k } }
        for (field, keys) in [("held", held), ("latency_ms", latencyKeys)] {
            guard let v = o[field] else { continue }
            guard let m = v as? [String: Any] else { return "live." + field }
            for k in m.keys.sorted() {
                if !keys.contains(k) || count(m[k]!) == nil { return "live.\(field).\(k)" }
            }
        }
        var s = 0.0
        if let v = o["seconds_after_swap"] {
            guard let n = number(v) else { return "live.seconds_after_swap" }
            s = n
        }
        guard s.isFinite, s >= 0, s <= secondsMax, (s * 10).rounded() / 10 == s else { return "live.seconds_after_swap" }
        let attempts = count(o["attempts"]!) ?? 0
        if outcomes.reduce(0, { $0 + (o[$1].flatMap(count) ?? 0) }) > attempts { return "live.attempts" }
        let buckets = ((o["latency_ms"] as? [String: Any]) ?? [:]).values.reduce(0) { $0 + (count($1) ?? 0) }
        if buckets > (o["swapped"].flatMap(count) ?? 0) { return "live.latency_ms" }
        return nil
    }

    /// A JSON number that is not a boolean (as JSONSerialization reads it, or a Swift number).
    static func number(_ v: Any) -> Double? {
        #if canImport(ObjectiveC)
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
        #else
        // the contract check on Linux (no CFBoolean): a boolean NSNumber is a char
        if let n = v as? NSNumber { return String(cString: n.objCType) == "c" ? nil : n.doubleValue }
        if v is Bool { return nil }
        if let i = v as? Int { return Double(i) }
        return v as? Double
        #endif
    }

    /// 30.8: `flags.live_promotion` as JSONSerialization reads it: only a literal false turns it off (absent, null,
    /// true, a string, a 0: on).
    static func flagOn(_ v: Any?) -> Bool {
        guard let v else { return true }
        #if canImport(ObjectiveC)
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return true }
        return n.boolValue
        #else
        if let n = v as? NSNumber, String(cString: n.objCType) == "c" { return n.boolValue }
        if let b = v as? Bool, !(v is NSNumber) { return b }
        return true
        #endif
    }

    /// A JSON integer from 0 to `countMax`.
    static func count(_ v: Any) -> Int? {
        guard let d = number(v), d.isFinite, d == d.rounded(), d >= 0, d <= Double(countMax) else { return nil }
        return Int(d)
    }
}

/// A take's part of the day's `live` object (30.9), the decide's last action.
struct LiveTally: Sendable, Hashable, Codable {
    var attempts = 0
    /// The attempt's outcome (30.6).
    var outcome: String?
    /// A take held under this reason (no attempt started while the build was ready).
    var held: String?
    /// The swap's latency bucket.
    var latency: String?
    /// Seconds of take audio the accelerator served after the swap, to 0.1 rounded down.
    var secondsAfterSwap: Double?

    var isEmpty: Bool { attempts == 0 && held == nil }

    /// As the vectors write it.
    var object: [String: Any] {
        var d: [String: Any] = [:]
        if attempts > 0 { d["attempts"] = attempts }
        if let o = outcome { d[o] = 1 }
        if let h = held { d["held"] = h }
        if let l = latency { d["latency_ms"] = l }
        if let s = secondsAfterSwap { d["seconds_after_swap"] = s }
        return d
    }
}

/// The `live` object of one promotions entry for a day (30.9): the takes' tallies added up.
struct LiveDay: Sendable, Equatable, Codable {
    var attempts = 0
    var outcomes: [String: Int] = [:]
    var held: [String: Int] = [:]
    var latency: [String: Int] = [:]
    /// Tenths of a second (sent as seconds with one decimal).
    var tenths = 0

    var isEmpty: Bool { attempts == 0 && held.isEmpty }

    mutating func add(_ t: LiveTally) {
        attempts += t.attempts
        if let o = t.outcome { outcomes[o, default: 0] += 1 }
        if let h = t.held { held[h, default: 0] += 1 }
        if let l = t.latency { latency[l, default: 0] += 1 }
        if let s = t.secondsAfterSwap { tenths += Int((s * 10).rounded()) }
    }

    /// The object as the server takes it: `attempts` always, each count left out when 0.
    var object: [String: Any] {
        func clip(_ n: Int) -> Int { min(LiveRules.countMax, max(0, n)) }
        var o: [String: Any] = ["attempts": clip(attempts)]
        for k in LiveRules.outcomes { if let n = outcomes[k], n > 0 { o[k] = clip(n) } }
        let h = held.filter { $0.value > 0 && LiveRules.held.contains($0.key) }.mapValues(clip)
        if !h.isEmpty { o["held"] = h }
        let l = latency.filter { $0.value > 0 && LiveRules.latencyKeys.contains($0.key) }.mapValues(clip)
        if !l.isEmpty { o["latency_ms"] = l }
        if tenths > 0 { o["seconds_after_swap"] = Double(min(tenths, Int(LiveRules.secondsMax) * 10)) / 10 }
        return o
    }
}

/// One take that started on the CPU engine, from the SDK's events to what it does (30.11). Pure: no clock, no I/O;
/// times are ms of a monotonic clock, given with each event.
struct LiveTake: Sendable {
    struct Init: Sendable, Equatable {
        var context: String
        /// The vocabulary's word bar; nil: the blank alone makes a pause.
        var wordBar: Int?
        /// The source is read as fast as possible: never a stall.
        var fast = false
        /// `flags.live_promotion` is not false.
        var flagOn = true
        var appCPU = false
        var chunksSoFar = 0
        var samplesSoFar = 0
        var device = LiveRules.Device()
    }

    enum Event: Sendable, Equatable {
        /// The accelerator's build of the take's key is promoted, loaded and warm; `n` samples taken.
        case ready(t: Int, n: Int)
        case unready(t: Int)
        case cond(t: Int, LiveRules.DeviceChange)
        /// The CPU engine computed take chunk k; `n` samples taken; the greedy ids of its last frames; handed out more
        /// than one chunk after its audio.
        case cpu(t: Int, k: Int, n: Int, tail: [Int], late: Bool)
        case acc(t: Int, k: Int)
        case verdict(t: Int, LiveRules.Verdict)
        /// The accelerator failed before the swap (exception, non_finite, out_of_range, deadline).
        case fail(t: Int, cause: String)
        case interrupted(t: Int)
        case resumed(t: Int)
        /// After a swap: the failover took the take back to the CPU at chunk k.
        case failover(t: Int, k: Int)
        case end(t: Int, n: Int, why: String)
    }

    enum Engine: String, Sendable, Equatable { case cpu, acc }

    enum Action: Sendable, Equatable {
        case emit(Int, Engine)
        case replay(fromSample: Int, samples: Int, firstChunk: Int, exact: Bool)
        case judge(Int, Int)
        case outcome(String, record: String?)
        case closeCPU
        case changed(fromChunk: Int)
        case releaseAcc
        case tally(LiveTally)
    }

    enum State: String, Sendable { case cpu, rebuild, committed, accel, failedOver = "failed_over", done, ended }

    let chunkMs: Int
    let advance: Int
    let w: Int
    let bar: Int?
    let fast: Bool
    let flagOn: Bool
    let appCPU: Bool
    private(set) var device: LiveRules.Device
    private(set) var state = State.cpu
    private(set) var cpuHave: Int
    private(set) var accHave = -1
    private(set) var n: Int
    private(set) var ready = false
    private var seenReady = false
    private(set) var attempted = false
    private var heldReason: String?
    private(set) var stalled = false
    private var interrupted = false
    private var lastTail: [Int] = []
    private(set) var outcome: String?
    private(set) var plan: LiveRules.ReplayPlan?
    private var startT = 0
    /// The window to judge next (nil until the accelerator caught up), the one asked for, and the verdicts.
    private(set) var next: ClosedRange<Int>?
    private(set) var window: ClosedRange<Int>?
    private var judging = false
    private(set) var verdicts: [LiveRules.Verdict] = []
    private(set) var commitChunk: Int?
    private(set) var fromChunk: Int?
    private var latency = 0
    private var failoverChunk: Int?

    init(_ i: Init) {
        chunkMs = LiveRules.chunkMs(context: i.context) ?? 320
        advance = LiveRules.advance(chunkMs: chunkMs)
        w = LiveRules.shadowChunks(chunkMs: chunkMs)
        bar = i.wordBar
        fast = i.fast
        flagOn = i.flagOn
        appCPU = i.appCPU
        device = i.device
        cpuHave = i.chunksSoFar - 1
        n = i.samplesSoFar
    }

    /// An attempt runs (before the swap).
    var live: Bool { state == .rebuild || state == .committed }

    private func conditions() -> LiveRules.Conditions {
        LiveRules.Conditions(flagOn: flagOn, appCPU: appCPU, onCPU: true, attempted: attempted, failedOver: false, stall: stalled,
                             takeSeconds: Double(n) / Double(LiveRules.rate), device: device)
    }

    mutating func feed(_ ev: Event) -> [Action] {
        var out: [Action] = []
        if state == .ended { return out }
        let live = self.live
        switch ev {
        case .ready(let t, let samples):
            n = max(n, samples)
            ready = true
            if state == .cpu {
                seenReady = true
                tryStart(t, &out)
            }
        case .unready:
            ready = false
            if live { endAttempt("aborted", &out) }
        case .cond(let t, let change):
            change.apply(to: &device)
            if live && (LiveRules.pipelineBlocker(device) != nil || device.finishing) {
                endAttempt("aborted", &out)
            } else if state == .cpu && ready {
                tryStart(t, &out)
            }
        case .cpu(let t, let k, let samples, let tail, let late):
            // the CPU engine was closed at the swap: a chunk in flight is dropped
            if state == .accel || state == .failedOver { return out }
            cpuHave = k
            n = max(n, samples)
            lastTail = tail
            if !fast {
                if late {
                    stalled = true
                } else if !interrupted {
                    stalled = false
                }
            }
            out.append(.emit(k, .cpu))
            if state == .cpu && ready {
                tryStart(t, &out)
            } else if state == .rebuild {
                progress(&out)
            } else if state == .committed {
                trySwap(t, k, &out)
            }
        case .acc(_, let k):
            if live {
                accHave = k
                if state == .rebuild { progress(&out) }
            } else if state == .accel, let from = fromChunk, k >= from {
                accHave = k
                out.append(.emit(k, .acc))
            }
        case .verdict(let t, let v):
            guard state == .rebuild, judging, let win = window, let p = plan else { break }
            judging = false
            verdicts.append(v)
            let res = LiveRules.shadowOutcome(exact: p.exact, windows: verdicts).result
            if res == "commit" {
                state = .committed
                commitChunk = win.upperBound
                trySwap(t, cpuHave, &out)
            } else if res == "pending" {
                next = (win.upperBound + 1)...(win.upperBound + w)
                progress(&out)
            } else {
                endAttempt(res, &out)
            }
        case .fail:
            if live { endAttempt("accel_failed", &out) }
        case .interrupted:
            interrupted = true
            if !fast { stalled = true }
        case .resumed:
            interrupted = false
        case .failover(_, let k):
            if state == .accel {
                state = .failedOver
                failoverChunk = k
            }
        case .end(_, let samples, _):
            n = max(n, samples)
            if live { endAttempt("aborted", &out) }
            out.append(.tally(tally()))
            state = .ended
        }
        return out
    }

    private mutating func tryStart(_ t: Int, _ out: inout [Action]) {
        if attempted { return }
        if let why = LiveRules.start(conditions()) {
            heldReason = why
            return
        }
        attempted = true
        heldReason = nil
        startT = t
        let p = LiveRules.replayPlan(chunkMs: chunkMs, taken: n)
        plan = p
        accHave = p.firstChunk - 1
        next = nil
        window = nil
        judging = false
        verdicts = []
        state = .rebuild
        out.append(.replay(fromSample: p.fromSample, samples: p.samples, firstChunk: p.firstChunk, exact: p.exact))
        progress(&out)
    }

    /// 30.4: asks for the next window once both engines have computed its last chunk.
    private mutating func progress(_ out: inout [Action]) {
        if judging { return }
        if next == nil {
            // still replaying or catching up
            if accHave < cpuHave { return }
            guard let p = plan else { return }
            next = LiveRules.firstWindow(chunkMs: chunkMs, plan: p, newest: cpuHave)
        }
        guard let nx = next else { return }
        if accHave >= nx.upperBound && cpuHave >= nx.upperBound {
            window = nx
            judging = true
            out.append(.judge(nx.lowerBound, nx.upperBound))
        }
    }

    private mutating func trySwap(_ t: Int, _ k: Int, _ out: inout [Action]) {
        guard let commit = commitChunk else { return }
        let s = LiveRules.swapStep(chunkMs: chunkMs, commitChunk: commit, k: k, tail: lastTail, stalled: stalled, bar: bar)
        if s == "swap" {
            state = .accel
            outcome = "swapped"
            fromChunk = k + 1
            latency = t - startT
            out.append(.outcome("swapped", record: nil))
            out.append(.closeCPU)
            out.append(.changed(fromChunk: k + 1))
            if accHave >= k + 1 { for j in (k + 1)...accHave { out.append(.emit(j, .acc)) } }
        } else if s == "stalled" {
            endAttempt("stalled", &out)
        }
    }

    private mutating func endAttempt(_ o: String, _ out: inout [Action]) {
        state = .done
        outcome = o
        out.append(.outcome(o, record: LiveRules.recordRule(o)))
        out.append(.releaseAcc)
    }

    private func tally() -> LiveTally {
        var d = LiveTally()
        if attempted {
            d.attempts = 1
            d.outcome = outcome
            if outcome == "swapped", let from = fromChunk {
                d.latency = LiveRules.latencyKey(ms: latency)
                let end = state == .failedOver ? (failoverChunk ?? 0) * advance : n
                d.secondsAfterSwap = LiveRules.tenths(samples: max(0, end - from * advance))
            }
        } else if seenReady, let h = heldReason, LiveRules.held.contains(h) {
            d.held = h
        }
        return d
    }
}
