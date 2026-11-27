import Foundation
import Network
import Security

// SDK 4.0.5, contract section 35 (`sdk_4.0.0/SPLIT_40.md`): the transport side of the split. `SplitDecide` decides; this
// file carries out what it decides on the SDK's real requests. One CPU-set download (`SplitDownload`) has at most one
// split file, its largest; that file's requests and the ranges the decide starts are held by one `SplitSession`, whose
// lock is the lock of every write those requests make (`StreamControl.commit`), so a cut and a write never cross and the
// decide's position of a request is always what is on disk. A range of section 35 is written to its own file beside the
// partial file (`BackgroundRange.file`, the name the 4.0.1 background ranges have), and the installer's loop joins it
// when the partial file reaches its first byte, so no byte is written twice and the file's SHA-256 is still made as its
// bytes are joined in order.

/// SDK 4.0.5: `t` of every event of the decide, in ms of the process's monotonic clock.
enum SplitClock {
    /// Tests may replace it.
    static let source = Locked<@Sendable () -> Int>({ Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) })
    static func now() -> Int { source.withLock { $0 }() }
}

/// SDK 4.0.5: the connection type a split's memory and P are kept per: `wifi`, `cellular`, `wired` or
/// `other`. The interface's type only: never a network's name, a carrier or an SSID.
/// The system's path monitor is started once per process (`begin`, when the Client is made) and never waited for there:
/// the type is `other` until its first answer. Tried before (never released): `begin` waited up to 0.1 s for that answer,
/// so a P would not be kept under `other` a moment before the real type arrived; Client start-up must never wait for it.
enum NetworkType {
    static let kinds = ["wifi", "cellular", "wired", "other"]
    /// Tests only: the type in place of the system's.
    static let override = Locked<String?>(nil)
    /// Tests only: how the monitor is started; it is handed what to tell each type it sees. Nil: the system's
    /// `NWPathMonitor`.
    static let starter = Locked<(@Sendable (_ tell: @escaping @Sendable (String) -> Void) -> Void)?>(nil)
    private static let seen = Locked<String?>(nil)
    private static let started = Locked(false)
    /// The monitor, kept for the life of the process.
    private static let monitor = Locked<NWPathMonitor?>(nil)

    /// The type of the path the system uses now, for a download that starts (never for Client start-up): when the monitor
    /// has not answered yet, at most 0.3 s are waited for it, then the type is `other`.
    static func current() async -> String {
        if let o = override.withLock({ $0 }) { return o }
        begin()
        for _ in 0..<30 {
            if let s = seen.withLock({ $0 }) { return s }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return seen.withLock { $0 } ?? "other"
    }

    /// The last type seen, without a wait (`other` before the first).
    static var now: String { override.withLock { $0 } ?? seen.withLock { $0 } ?? "other" }

    static func of(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "other" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }

    /// Starts the path monitor of this process, once, and returns at once: nothing waits for its first answer.
    static func begin() {
        let first = started.withLock { (s: inout Bool) -> Bool in
            defer { s = true }
            return !s
        }
        guard first else { return }
        let tell: @Sendable (String) -> Void = { t in seen.withLock { $0 = t } }
        if let start = starter.withLock({ $0 }) {
            start(tell)
            return
        }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in tell(of(path)) }
        monitor.withLock { $0 = m }
        m.start(queue: DispatchQueue(label: "ai.quranlab.network-type", qos: .utility))
    }

    /// Tests only: as if this process had not started the monitor (the system's one, if any, is cancelled).
    static func forgetForTests() {
        monitor.withLock { m in
            m?.cancel()
            m = nil
        }
        seen.withLock { $0 = nil }
        started.withLock { $0 = false }
    }
}

/// SDK 4.0.5: the share's draw is made from a random value of 16 bytes kept on the device and never sent,
/// and the UTC day.
enum SplitSeed {
    static func file(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/split-seed") }

    /// The device's value, made the first time.
    static func read(_ storage: URL) -> Data {
        let f = file(storage)
        if let d = try? Data(contentsOf: f), d.count == 16 { return d }
        var d = Data(count: 16)
        let ok = d.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) -> Bool in
            SecRandomCopyBytes(kSecRandomDefault, 16, b.baseAddress!) == errSecSuccess
        }
        if !ok { d = Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: f, options: StorageProtection.atomic)
        return d
    }

    /// `YYYY-MM-DD` of `date` in UTC.
    static func day(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The decide's names of hosts: a models host's name, and `:port` when its origin names a port (two stand-ins on one
/// loopback address are two hosts). Production origins name no port, so a key is the host's name there.
enum SplitHosts {
    static func key(_ url: URL?) -> String {
        guard let url else { return "" }
        return Endpoints.asciiLower(url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
    }

    /// The host's name a key stands for (the telemetry's `host`, `no_helper`).
    static func name(_ key: String) -> String {
        key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key
    }
}

/// SDK 4.0.5 (sections 34.4 and 35): what the installer holds of one model request while it runs. Every write the request
/// makes goes through `commit` under `lock` (a split session's lock is shared by all its requests): nothing is written at
/// or past `stop`, and what arrived past it is discarded and counted. A cut that finds the request at its stop already
/// cancels its transfer, so a request that waits for its next byte ends at once; its end is the cut's, never a failure.
final class StreamControl: @unchecked Sendable {
    let id: String
    /// A range of section 35: its own file, written from its byte 0; its 206 must name exactly `lower`, `end - 1` and
    /// the file's size (35.7 item 1). Nil: the file's own request, written to the partial file.
    let side: URL?
    let lower: Int64
    let end: Int64
    let lock: NSRecursiveLock
    private var stopAt: Int64
    private var reachedStop = false
    private var cutting = false
    private var byUs = false
    private var wasTaken = false
    private var takenHost: String?
    private var answerStatus: Int?
    private var answerRetryAfter = false
    private var count: Int64 = 0
    private var cancelTransfer: (@Sendable () -> Void)?

    /// Told under `lock` when the answer was taken (its status read and held to the file or the range), with its host
    /// key and whether it is a whole file written beside the partial one (16.1).
    var onTaken: ((_ host: String, _ whole: Bool) -> Void)?
    /// Told under `lock` after every write, with the bytes written.
    var onBytes: ((_ n: Int) -> Void)?
    /// Told, on another task, the bytes a cut request discarded: those past its stop that arrived, and those the system
    /// had received for it when it was cancelled.
    var onDiscarded: (@Sendable (_ host: String, _ bytes: Int64) -> Void)?
    /// Told under `lock` that a host is out for this download (34.4: the first host of a hedge that lost).
    var onHostOut: ((_ host: String, _ why: String) -> Void)?

    init(id: String, side: URL? = nil, lower: Int64, end: Int64, lock: NSRecursiveLock = NSRecursiveLock()) {
        self.id = id
        self.side = side
        self.lower = lower
        self.end = end
        self.lock = lock
        stopAt = end
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The first byte not to be written.
    var stop: Int64 { locked { stopAt } }
    /// The request ended at its stop (a cut, or its own end).
    var reached: Bool { locked { reachedStop } }
    /// A cut cancelled the request's transfer.
    var isCutting: Bool { locked { cutting } }
    /// The installer cancelled the request (the call, the app's leaving, a refusal on another range): not a failure of
    /// its host.
    var cancelledByUs: Bool { locked { byUs } }
    var taken: Bool { locked { wasTaken } }
    var host: String? { locked { takenHost } }
    var status: Int? { locked { answerStatus } }
    var retryAfter: Bool { locked { answerRetryAfter } }
    var written: Int64 { locked { count } }

    /// 35.6 `cut`: nothing at or past `at` is written; a request there already is cancelled now. A later cut may raise it.
    func cut(at: Int64) {
        locked {
            stopAt = at
            if wasTaken, lower + count >= at, !reachedStop {
                reachedStop = true
                cutting = true
                cancelTransfer?()
            }
        }
    }

    /// The installer ends the request (not a cut).
    func cancelNow() {
        let c = locked { () -> (@Sendable () -> Void)? in
            byUs = true
            return cancelTransfer
        }
        c?()
    }

    /// The answer's status (before it is held to the file).
    func answered(status: Int, retryAfter: Bool) {
        locked {
            answerStatus = status
            answerRetryAfter = retryAfter
        }
    }

    /// The answer was taken on `host`; `cancel` ends its transfer.
    func attach(host: String, whole: Bool, cancel: @escaping @Sendable () -> Void) {
        locked {
            wasTaken = true
            takenHost = host
            cancelTransfer = cancel
            if whole { stopAt = Int64.max }
            onTaken?(host, whole)
            if byUs { cancel() }
            if !whole, lower + count >= stopAt, !reachedStop {
                reachedStop = true
                cutting = true
                cancel()
            }
        }
    }

    /// Writes what may be written of `n` bytes that arrived (`write` is given how many, from the first): what is past the
    /// stop is discarded. Returns the bytes written, a write's failure, and whether the request is at its stop now.
    func commit(_ n: Int, write: (Int) -> String?) -> (written: Int, error: String?, atStop: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let allowed = Int(max(0, min(Int64(n), stopAt - (lower + count))))
        if allowed > 0, let e = write(allowed) { return (0, e, false) }
        count += Int64(allowed)
        if allowed > 0 { onBytes?(allowed) }
        let atStop = lower + count >= stopAt
        if atStop { reachedStop = true }
        return (allowed, nil, atStop)
    }

    /// 34.4: `host` is out for this download (the first host of a hedge, when the second's answer was taken).
    func hostOut(_ host: String, _ why: String) { locked { onHostOut?(host, why) } }
}

/// SDK 4.0.5 (34.4): the two requests of one file when the first had no status 1.5 s after it was sent. The first status
/// that is taken, a refusal or a slow down decides; the other request is cancelled at once, before it touches the
/// partial file. An unreachable status decides nothing: that request is over, and the other goes on and decides in turn.
final class HedgeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var winner: Int?
    private var cls: AnswerClass?
    private var cancels: [Int: @Sendable () -> Void] = [:]
    /// Told (outside the lock) when request 2 decided: before its answer is taken by the installer.
    var onSecond: (@Sendable () -> Void)?

    var decided: Int? { lock.withLock { winner } }
    var outcome: AnswerClass? { lock.withLock { cls } }

    func register(_ k: Int, cancel: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            cancels[k] = cancel
            return winner != nil && winner != k
        }
        if now { cancel() }
    }

    /// Request `k`'s answer is of class `c`: true when it is the answer of the file (the first that decides).
    func claim(_ k: Int, _ c: AnswerClass) -> Bool {
        guard c != .unreachable else { return false }
        let others = lock.withLock { () -> [@Sendable () -> Void]? in
            if let w = winner { return w == k ? [] : nil }
            winner = k
            cls = c
            return cancels.filter { $0.key != k }.map(\.value)
        }
        guard let others else { return false }
        if k == 2 { onSecond?() }
        others.forEach { $0() }
        return true
    }

    /// The contract's `hedge` vectors (STEERING_40 34.4, `steering_40.json`): the first request's status (seconds after
    /// it was sent, and its class: `taken`, `refused`, `slow_down`, `unreachable`), the second's (seconds after it was
    /// sent), and the hedge's delay. Which decided, when, what, and when the second went out.
    static func replay(first: (Double, String), second: (Double, String)?, hedgeS: Double)
        -> (decidedBy: String?, at: Double, outcome: String, secondSentAt: Double?) {
        let g = HedgeGate()
        let secondSent: Double? = first.0 > hedgeS ? hedgeS : nil
        var answers: [(t: Double, k: Int, c: String)] = [(first.0, 1, first.1)]
        if let s = secondSent, let second { answers.append((s + second.0, 2, second.1)) }
        answers.sort { $0.t < $1.t }
        func of(_ c: String) -> AnswerClass {
            switch c {
            case "taken": return .taken
            case "refused": return .refused
            case "slow_down": return .slowDown
            default: return .unreachable
            }
        }
        for a in answers where g.claim(a.k, of(a.c)) {
            return (a.k == 1 ? "first" : "second", a.t, a.c, secondSent)
        }
        return (nil, answers.map(\.t).max() ?? first.0, "unreachable", secondSent)
    }
}

/// One request of a hedge (34.4): its gate and its number, and whether its answer has begun.
final class HedgeTicket: @unchecked Sendable {
    let gate: HedgeGate
    let k: Int
    /// The status came.
    let answered = Locked(false)
    /// No status came within the hedge's delay, so a second request went out (34.6 `hedged`, on this request's host).
    let hedged = Locked(false)

    init(_ gate: HedgeGate, _ k: Int) {
        self.gate = gate
        self.k = k
    }

    func claim(_ c: AnswerClass) -> Bool { gate.claim(k, c) }
}

/// SDK 4.0.5: what one CPU-set download is told for its split, read at its start from the config in force:
/// whether it is in the switch's share, the hosts that never help, the connection type, the process's memory, and where
/// the decide's counts, the bytes discarded and P go.
struct SplitPlan: Sendable {
    var shareOn: Bool
    /// Host names (35.2 `no_helper`).
    var noHelper: [String] = []
    var conn: String = "other"
    var memory: SplitMemory = .process
    var clock: @Sendable () -> Int = { SplitClock.now() }
    /// 35.9: adds `n` to `field` of the day's entry of `host` (a key of `SplitHosts`); for `gain`, `n` is the bucket.
    var count: @Sendable (_ field: String, _ host: String, _ n: Int) -> Void = { _, _, _ in }
    /// The bytes a cut discarded, on the host (a key of `SplitHosts`) that sent them.
    var wasted: @Sendable (_ host: String, _ bytes: Int64) -> Void = { _, _ in }
    /// 35.6 `p`: P becomes this origin for the connection type (28.3 item 5).
    var settle: @Sendable (_ origin: URL) -> Void = { _ in }
    /// For tests and the stand-in: every event fed to the decide and every action it returned, in order.
    var trace: (@Sendable (String) -> Void)? = nil

    init(shareOn: Bool) { self.shareOn = shareOn }
}

/// One CPU-set download's split (35.1): the file that may be split (the set's largest), its session while its request
/// runs, and the bytes of the other files by host (`lane`, so files in parallel never make a host look slow).
final class SplitDownload: @unchecked Sendable {
    let plan: SplitPlan
    let splitPath: String?
    private let lock = NSLock()
    private var current: SplitSession?
    /// The bytes of each range file the progress was told as they arrived (the join tells only the rest).
    private var metered: [String: Int64] = [:]

    init(plan: SplitPlan, files: [ModelManifest.File]) {
        self.plan = plan
        splitPath = ModelInstaller.queue(files).first.map { files[$0].path }
    }

    /// A new session for `f` when it is the split file and its source can send ranges to a named host.
    func session(for f: ModelManifest.File, part: URL, source: any ModelFileSource, meter: ProgressMeter?) -> SplitSession? {
        guard f.path == splitPath, let cdn = source as? CDNFileSource else { return nil }
        let s = SplitSession(plan: plan, path: f.path, size: f.size, part: part, source: cdn, download: self, meter: meter)
        lock.withLock { current = s }
        return s
    }

    func ended(_ s: SplitSession) { lock.withLock { if current === s { current = nil } } }

    /// The control of another file's request: its bytes are told to the split file's decide as its host's (`lane`).
    func laneControl(lower: Int64, end: Int64) -> StreamControl {
        let c = StreamControl(id: "lane", lower: lower, end: end)
        let host = Locked<String?>(nil)
        c.onTaken = { h, _ in host.withLock { $0 = h } }
        c.onBytes = { [weak self] n in
            guard let h = host.withLock({ $0 }), let s = self?.lock.withLock({ self?.current }) else { return }
            s.lane(h, n)
        }
        return c
    }

    func addMetered(_ side: URL, _ n: Int) { lock.withLock { metered[side.path, default: 0] += Int64(n) } }

    /// What the progress was told of a range file already; forgotten.
    func takeMetered(_ side: URL) -> Int64 { lock.withLock { metered.removeValue(forKey: side.path) ?? 0 } }
}

/// The split file's requests and the decide (35.6): the file's own request (`fileRequest`), the ranges the decide starts,
/// a tick at least every `TICK_MS`, and what the decide asks back (a resume of 16.2, a refusal that ends the call, a
/// restart after a mismatch).
final class SplitSession: @unchecked Sendable {
    enum HashOutcome: Sendable, Equatable {
        /// The file is right.
        case passed
        /// The other hosts' ranges were fetched again from the host with the most bytes: check again.
        case refetched
        /// The file starts again from byte 0, without the hosts marked bad (16.1, 35.7 item 3).
        case restart
    }

    let lock = NSRecursiveLock()
    let plan: SplitPlan
    let path: String
    let size: Int64
    let part: URL
    private let source: CDNFileSource
    private weak var download: SplitDownload?
    private let meter: ProgressMeter?
    private let decide: SplitDecide
    private let origins: [String: URL]
    private var controls: [String: StreamControl] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var running: Set<String> = []
    private var errors: [String: CloudError] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resumeAsked: (lo: Int64, end: Int64)?
    private var refusalError: CloudError?
    private var restartAsked = false
    private var refetchFailed = false
    private var fed = false
    private var n = 0
    private var ticker: Task<Void, Never>?
    private var finished = false

    init(plan: SplitPlan, path: String, size: Int64, part: URL, source: CDNFileSource, download: SplitDownload?, meter: ProgressMeter?) {
        self.plan = plan
        self.path = path
        self.size = size
        self.part = part
        self.source = source
        self.download = download
        self.meter = meter
        let order = source.splitOrigins(path)
        var o: [String: URL] = [:]
        for u in order { o[SplitHosts.key(u)] = u }
        origins = o
        let keys = order.map { SplitHosts.key($0) }
        let noHelper = keys.filter { plan.noHelper.contains(SplitHosts.name($0)) }
        decide = SplitDecide(size: Int(size), order: keys, noHelper: noHelper, shareOn: plan.shareOn, memory: plan.memory, conn: plan.conn)
        plan.trace?("init size=\(size) order=\(keys) no_helper=\(noHelper) share_on=\(plan.shareOn) conn=\(plan.conn)")
        // 35.6 `host_out`: a host held by 28.11 for this path is out from the start
        for k in source.heldKeys(path) { feed(.hostOut(t: plan.clock(), host: k, why: "held")) }
    }

    // MARK: what the installer asks

    /// The control of the file's own request from `lower` (a first request, or 16.2's resume) when it runs to the end of
    /// the file, so it is the decide's (`main`, then `req`); nil for a request that ends before a kept range.
    func fileRequest(lower: Int64, end: Int64) -> StreamControl? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, end == size, ["single", "split"].contains(decide.phase) else { return nil }
        n += 1
        let c = StreamControl(id: "r\(n)", lower: lower, end: end, lock: lock)
        c.onTaken = { [weak self, weak c] host, whole in
            guard let self, let c else { return }
            self.taken(c, host: host, whole: whole)
        }
        c.onBytes = { [weak self, weak c] k in
            guard let self, let c else { return }
            self.feed(.bytes(t: self.plan.clock(), id: c.id, n: k))
        }
        c.onHostOut = { [weak self] host, why in
            guard let self else { return }
            self.feed(.hostOut(t: self.plan.clock(), host: host, why: why))
        }
        // 35.5 item 4: what the file's request brings past its cut at m is discarded and counted on its host
        let plan = self.plan
        c.onDiscarded = { host, bytes in plan.wasted(host, bytes) }
        controls[c.id] = c
        startTicker()
        return c
    }

    /// The file's request ended: told to the decide when it had been taken (`end`).
    func fileRequestEnded(_ c: StreamControl, failed: Bool, cancelled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard controls.removeValue(forKey: c.id) != nil, c.taken, fed else { return }
        let how = cancelled || c.cancelledByUs ? "cancelled" : (c.reached || !failed ? "done" : "broken")
        feed(.end(t: plan.clock(), id: c.id, how: how))
    }

    /// Another file's bytes from `host` (35.3 item 5).
    func lane(_ host: String, _ n: Int) { feed(.lane(t: plan.clock(), host: host, n: n)) }

    /// Waits until no range of the decide is running.
    func idle() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if running.isEmpty {
                lock.unlock()
                c.resume()
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    /// The remainder the decide asked the SDK to resume (16.2), once.
    func takeResume() -> (lo: Int64, end: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        defer { resumeAsked = nil }
        return resumeAsked
    }

    /// The decide is alive (it may still act for this file).
    var alive: Bool { lock.withLock { !finished && ["single", "split"].contains(decide.phase) } }
    /// The refusal a range got: the call's answer (35.3 item 3).
    var refusal: CloudError? { lock.withLock { refusalError } }
    var verdict: String? { lock.withLock { decide.verdict } }
    var phase: String { lock.withLock { decide.phase } }
    /// Whether the file's hash goes to the decide (35.7): in the share, once the decide has the file's request.
    var verifies: Bool { lock.withLock { plan.shareOn && fed && ["single", "split"].contains(decide.phase) } }
    /// The hosts this process found serving bad bytes (keys).
    var badHosts: Set<String> { Set(plan.memory.snapshot.bad) }

    /// Ends every request of the session (the call was cancelled, the app left): what they wrote stays in their files.
    func cancelAll() {
        lock.lock()
        let all = Array(controls.values)
        let ts = Array(tasks.values)
        lock.unlock()
        for c in all { c.cancelNow() }
        for t in ts { t.cancel() }
    }

    /// The file's SHA-256 was checked (35.6 `hash`): what follows. A mismatch with two hosts fetches the other hosts'
    /// ranges again from the host with the most bytes, written over them in the partial file.
    func hashed(_ ok: Bool) async -> HashOutcome {
        feed(.hash(t: plan.clock(), ok: ok))
        if lock.withLock({ restartAsked }) { return .restart }
        if ok { return .passed }
        await idle()
        let failed = lock.withLock { refetchFailed || resumeAsked != nil || restartAsked || decide.phase != "verify" }
        return failed ? .restart : .refetched
    }

    /// The session is over: the tick stops, and a range still running is cancelled (its bytes stay in its file).
    func finish() {
        lock.lock()
        finished = true
        let t = ticker
        ticker = nil
        let ts = Array(tasks.values)
        lock.unlock()
        t?.cancel()
        for x in ts { x.cancel() }
        download?.ended(self)
    }

    // MARK: the decide

    private func taken(_ c: StreamControl, host: String, whole: Bool) {
        // a whole file written beside the partial one (16.1) is not the decide's
        guard !whole else {
            controls[c.id] = nil
            return
        }
        if !fed {
            fed = true
            feed(.main(t: plan.clock(), id: c.id, host: host, lo: Int(c.lower)))
        } else {
            feed(.req(t: plan.clock(), id: c.id, host: host, lo: Int(c.lower), end: Int(c.end)))
        }
    }

    private func feed(_ e: SplitEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        let phaseBefore = decide.phase
        let acts = decide.event(e)
        // SDK 4.0.5 (STEERING_40 34.9.7): 34.5's cut (35.5 item 3) moves the file from its host to the next, `slow`. Read
        // from the actions it makes in phase single: the cut host's `slow_switches` and a range of the rest on another
        // host. A range of section 35's split (two hosts at once) is no move.
        if phaseBefore == "single" {
            var cutHost: String?
            var to: String?
            for a in acts {
                if case .count("slow_switches", let h, _) = a { cutHost = h }
                if case .start(_, let h, _, _) = a { to = h }
            }
            if let cutHost, let to, cutHost != to { source.slowMove(path, from: cutHost, to: to) }
        }
        if let trace = plan.trace {
            trace("event \(e)")
            for a in acts { trace("action \(a)") }
        }
        for a in acts { run(a) }
    }

    private func run(_ a: SplitAction) {
        switch a {
        case .start(let id, let host, let lo, let end):
            startRange(id, host, Int64(lo), Int64(end))
        case .cut(let id, let at):
            controls[id]?.cut(at: Int64(at))
        case .resume(let lo, let end):
            resumeAsked = (Int64(lo), Int64(end))
        case .verdict:
            break
        case .p(let host):
            if let o = origins[host] { plan.settle(o) }
        case .count(let field, let host, let k):
            plan.count(field, host, k)
        case .refused:
            refusalError = refusalError ?? errors.values.first
            let all = Array(controls.values)
            for c in all { c.cancelNow() }
            for t in tasks.values { t.cancel() }
        case .restart:
            restartAsked = true
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let clock = plan.clock
        ticker = Task { [weak self] in
            let every = SplitConstants.tickMs
            var next = clock() + every
            while !Task.isCancelled {
                let wait = max(1, next - clock())
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = clock()
                self.feed(.tick(t: now))
                next += every
                if next <= now { next = now + every }
            }
        }
    }

    /// 35.6 `start`: `GET` with `Range: bytes=lo-(end-1)`, no `If-Range`, to `host`, written to its own file: beside the
    /// partial file at `lo` (joined by the installer), or for a refetch of 35.7 item 3, a file written over the partial
    /// file's bytes when it is whole.
    private func startRange(_ id: String, _ host: String, _ lo: Int64, _ end: Int64) {
        let refetch = decide.phase == "verify"
        let side = refetch ? URL(fileURLWithPath: part.path + ".v\(lo)") : BackgroundRange.file(part: part, lower: lo)
        let c = StreamControl(id: id, side: side, lower: lo, end: end, lock: lock)
        let plan = self.plan
        c.onTaken = { [weak self] _, _ in
            guard let self else { return }
            self.feed(.status(t: self.plan.clock(), id: id, kind: "taken"))
        }
        c.onBytes = { [weak self] k in
            guard let self else { return }
            self.feed(.bytes(t: self.plan.clock(), id: id, n: k))
        }
        // the progress is told a range's bytes as they arrive, outside the session's lock (a refetch moves nothing)
        let meter = refetch ? nil : self.meter
        let download = refetch ? nil : self.download
        let received: @Sendable (Int64) -> Void = { n in
            meter?.add(n)
            download?.addMetered(side, Int(n))
        }
        c.onDiscarded = { host, bytes in plan.wasted(host, bytes) }
        controls[id] = c
        running.insert(id)
        guard let origin = origins[host] else {
            // not a host of the file's order (the decide only names those): no answer
            Task { [weak self] in self?.rangeEnded(c, .failure(.offline("no origin for \(host)")), refetch: refetch) }
            return
        }
        let source = self.source, path = self.path, size = self.size
        tasks[id] = Task { [weak self] in
            let result: Result<HTTPClient.Streamed, CloudError>
            do throws(CloudError) {
                result = .success(try await source.range(path, origin: origin, size: size, control: c, received: received))
            } catch {
                result = .failure(error)
            }
            self?.rangeEnded(c, result, refetch: refetch)
        }
    }

    /// A range ended: its status (when it got no answer it could take) or its end goes to the decide.
    private func rangeEnded(_ c: StreamControl, _ result: Result<HTTPClient.Streamed, CloudError>, refetch: Bool) {
        // a refetch is written over the bytes it replaces, before the decide hears of its end
        var patchFailed = false
        if refetch, case .success = result, let side = c.side {
            patchFailed = !Self.patch(part, at: c.lower, from: side, length: c.written)
            try? FileManager.default.removeItem(at: side)
        } else if refetch, let side = c.side {
            try? FileManager.default.removeItem(at: side)
        }
        lock.lock()
        defer { lock.unlock() }
        controls[c.id] = nil
        tasks[c.id] = nil
        running.remove(c.id)
        if patchFailed { refetchFailed = true }
        if !finished {
            if !c.taken {
                if case .failure(let e) = result {
                    errors[c.id] = e
                    // cancelled before its answer by the session itself: the decide is over already
                    if !c.cancelledByUs { feed(.status(t: plan.clock(), id: c.id, kind: Self.statusKind(c, e))) }
                }
            } else {
                let how: String
                switch result {
                case .success: how = "done"
                case .failure: how = c.isCutting || c.reached ? "done" : (c.cancelledByUs ? "cancelled" : "broken")
                }
                if refetch, case .failure = result { refetchFailed = true }
                feed(.end(t: plan.clock(), id: c.id, how: how))
            }
        }
        if running.isEmpty {
            let w = waiters
            waiters = []
            for x in w { x.resume() }
        }
    }

    /// 35.6 `status` of a range whose answer was not taken: a 2xx that is not its range is `ignored`; a 429, a 503 with
    /// Retry-After or a hold of 28.11 is `slow_down`; a refusal of the API (a 4xx with a JSON `error`) is `refusal`;
    /// anything else (no answer, a 5xx, a 416, a redirect) is `unreachable`.
    static func statusKind(_ c: StreamControl, _ e: CloudError) -> String {
        if case .offline(let m) = e, m == HTTPClient.heldNotAsked { return "slow_down" }
        if case .rejected(429, _, _, _) = e { return "slow_down" }
        guard let s = c.status else { return "unreachable" }
        if (200..<300).contains(s) { return "ignored" }
        if s == 503, c.retryAfter { return "slow_down" }
        if s != 416, FileHosts.answerClass(e) == .refused { return "refusal" }
        return "unreachable"
    }

    /// Writes `length` bytes of `from` over the partial file at `at`.
    static func patch(_ part: URL, at: Int64, from: URL, length: Int64) -> Bool {
        do {
            let input = try FileHandle(forReadingFrom: from)
            defer { try? input.close() }
            let out = try FileHandle(forWritingTo: part)
            defer { try? out.close() }
            try out.seek(toOffset: UInt64(at))
            var left = length
            while left > 0, let piece = try input.read(upToCount: Int(min(left, 1 << 20))), !piece.isEmpty {
                try out.write(contentsOf: piece)
                left -= Int64(piece.count)
            }
            try out.synchronize()
            return left == 0
        } catch {
            return false
        }
    }
}
