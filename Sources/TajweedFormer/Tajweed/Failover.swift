import Foundation

// In-session failover: a take that runs on the accelerator switches to the exact CPU engine at the chunk that failed,
// without losing audio and without an error the app sees.
//
// Detection, per chunk: the call threw; a head is NaN or infinite; a head left its known range; or a chunk missed its
// deadline. The deadline is enforced by running every accelerator call on the accelerator's own serial queue and
// waiting for it with a timer. Since 2.0.2:
// - Cold chunks have their own limit: the first chunk of a take and the first chunk after the app became active get
//   max(1000 ms, 10 x the warm p90) (the Neural Engine powers down when idle; its first prediction after that is slow).
//   A warm-up (one prediction on silence, on the accelerator's queue, off the audio path) runs at take start and when
//   the app becomes active; the first chunk waits for it under the first-chunk limit.
// - Later chunks: min(300 ms, max(4 x p90, 2 x median, 50 ms)) from WARM chunk times only (the key's, then the take's
//   own; never a cold chunk or a warm-up), 300 ms before any warm measurement.
// - A miss sends the session to the CPU engine from that chunk; the build is demoted only for misses in 3 different
//   sessions within 24 h (AcceleratorController.failedOver). A call that has not answered `hangGraceMs` after its
//   deadline is a hang: it is abandoned (never awaited again, its result dropped) and the accelerator is not used again
//   in this process.
// - Blank is a suspicion, never a failure by itself. Chunks that hear nothing while the audio has energy (3 in a row)
//   are normal during long madd and held vowels. When the rule fires, the same audio (the ring below) is replayed
//   through the CPU engine on a background queue while the session continues on the accelerator: if the CPU hears
//   nothing there either (within the build's golden tolerance of tokens), the take stays on the accelerator and the
//   CPU engine is closed again; if it writes tokens there, the disagreement is confirmed and the take switches to that
//   CPU engine (its state is already rebuilt by the replay; it catches up with the audio since), the chunks from the
//   first suspicious one replaced and handed out again. At most one verification in flight, at most one per 10 s of
//   audio.
//
// No standby in memory. The exact engine maps its weight file and, on every chip with the SDOT instruction (A13 and
// later, every M chip), rewrites the int8 weights of every linear layer into the SDOT layout at load, in place: the
// mapping's pages become private copies, about 64 MB of resident memory the OS cannot drop. A CPU engine kept ready
// behind the Neural Engine would therefore cost that much for the whole session. So while the accelerator serves, the
// CPU engine is closed, and the switch is a fast cold one: open the engine (the file is usually still in the page
// cache), make the stream, and replay the take's recent audio. A blank verification opens it the same way, off the
// audio path, and closes it again when the CPU agrees.
//
// Replay. The take's audio is kept in a ring (30 s, 1.9 MB). The streaming encoder carries caches of 1.28 s of left
// context at c16_l64 (attention keys and values, convolution taps; up to 5.12 s at c24_l256), but each layer's cache is
// computed from the layer below's earlier output, so the exact state depends on far older audio (the receptive field
// of 16 layers: tens of seconds). Two cases:
// - the take so far fits the replay budget (the CPU engine can rerun it within the stall target on this device, from
//   the measured CPU chunk time): the whole take is replayed from its first sample. That is exact: the take ends with
//   exactly the CPU-only run's heads (and scores), and only chunks not handed out yet are handed out.
// - a longer take: the last N chunks are replayed (N from the same budget, at least the cache span plus one chunk), the
//   CPU continues from the failed chunk, the chunks before it stay as the accelerator gave them. Not exact; the
//   divergence is measured by FailoverTests on the self-test clips.
// A blank verification has no stall budget (it runs beside the session): it replays the whole ring, so a take of up to
// 30 s is verified exactly.

/// The exact CPU engine as a take sees it (TajweedExactEngine; a fake in tests).
protocol CPUStreamEngine: AnyObject {
    var chunkMs: Int { get }
    func reset()
    func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [TajweedHeads]
    func finish() throws(RecognizerError) -> [TajweedHeads]
}

extension TajweedExactEngine: CPUStreamEngine {}

/// The take's most recent 16 kHz audio, with absolute sample positions.
struct AudioRing: Sendable {
    let capacity: Int
    private var buf: [Float]
    private var head = 0          // where the next sample goes
    private(set) var count = 0
    /// Samples appended since the start of the take.
    private(set) var total = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        buf = [Float](repeating: 0, count: self.capacity)
    }

    /// The absolute position of the oldest sample kept.
    var oldest: Int { total - count }

    mutating func reset() {
        head = 0
        count = 0
        total = 0
    }

    mutating func append(_ s: [Float]) {
        total += s.count
        let take = s.suffix(capacity)
        for x in take {
            buf[head] = x
            head = (head + 1) % capacity
        }
        count = min(capacity, count + take.count)
    }

    /// The samples from absolute position `from` (clamped to what is kept) to the newest.
    func samples(from: Int) -> [Float] {
        let start = max(from, oldest)
        let n = total - start
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        var i = (head - n + capacity) % capacity
        for k in 0..<n {
            out[k] = buf[i]
            i = (i + 1) % capacity
        }
        return out
    }
}

/// The accelerator's own serial queue: every call runs there and is waited for with a deadline. A call that misses its
/// deadline is left running; one that has not answered `grace` seconds later is a hang, and the executor is abandoned
/// (it refuses every later call).
final class AcceleratorExecutor: @unchecked Sendable {
    enum Outcome {
        case done([TajweedHeads], seconds: [Double])
        case threw(RecognizerError, nsError: NSError?)
        /// The deadline passed first; the call may still be running.
        case timedOut(elapsedMs: Double)
    }

    let backend: any AcceleratorBackend
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _abandoned = false
    private var _warming = false
    private var _cold = false
    private var _warmUps = 0
    private var _lastWarmUpMs: Double?

    init(_ backend: any AcceleratorBackend, label: String = "ai.quranlab.accelerator") {
        self.backend = backend
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// A call hung: nothing runs here again.
    var abandoned: Bool { lock.lock(); defer { lock.unlock() }; return _abandoned }

    /// Warm-ups that ran, and how long the last one took (ms).
    var warmUps: Int { lock.lock(); defer { lock.unlock() }; return _warmUps }
    var lastWarmUpMs: Double? { lock.lock(); defer { lock.unlock() }; return _lastWarmUpMs }

    private func abandon() {
        lock.lock()
        _abandoned = true
        lock.unlock()
    }

    private final class Slot: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<[TajweedHeads], RecognizerError>?
        var nsError: NSError?
        var seconds: [Double] = []
    }

    /// Runs `body` on the queue and waits for it at most `timeout` seconds (synchronously: called from the
    /// recognizer's synchronous chunk path, never from the queue itself). A call still running then is a hang if it
    /// has not answered `grace` seconds later (0: at once, as 2.0.1 did).
    func run(timeout: TimeInterval, grace: TimeInterval = 0,
             _ body: @escaping @Sendable (any AcceleratorBackend) throws(RecognizerError) -> [TajweedHeads]) -> Outcome {
        if abandoned { return .threw(.neuralEngineUnavailable("the accelerator was abandoned after a call that did not return"), nsError: nil) }
        let slot = Slot()
        let box = UncheckedBox(backend)
        let t0 = CFAbsoluteTimeGetCurrent()
        queue.async {
            let before = box.value.chunkSeconds.count
            do throws(RecognizerError) {
                slot.result = .success(try body(box.value))
            } catch {
                slot.result = .failure(error)
            }
            slot.nsError = box.value.lastError
            slot.seconds = Array(box.value.chunkSeconds.dropFirst(before))
            slot.done.signal()
        }
        if slot.done.wait(timeout: .now() + max(0.001, timeout)) == .timedOut {
            if grace <= 0 {
                abandon()
            } else {
                // a late answer within the grace is a deadline miss only; none by then is a hang
                DispatchQueue.global(qos: .utility).async { [self] in
                    if slot.done.wait(timeout: .now() + grace) == .timedOut { self.abandon() }
                }
            }
            return .timedOut(elapsedMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        switch slot.result {
        case .success(let h)?: return .done(h, seconds: slot.seconds)
        case .failure(let e)?: return .threw(e, nsError: slot.nsError)
        case nil: return .threw(.neuralEngineUnavailable("no result"), nsError: nil)
        }
    }

    /// Resets the backend for a new take, on the queue, so it never overlaps a call; without `wait` the caller does
    /// not wait for it (the take's first call runs after it, in order).
    @discardableResult
    func reset(wait: Bool = false) -> Bool {
        if abandoned { return false }
        let box = UncheckedBox(backend)
        if wait { queue.sync { box.value.reset() } } else { queue.async { box.value.reset() } }
        return true
    }

    /// One prediction on silence on the queue, off the caller's path (the backend resets before and after it), unless
    /// one is queued or running already. The next call waits for it in the queue.
    func warmUp() {
        lock.lock()
        if _abandoned || _warming {
            lock.unlock()
            return
        }
        _warming = true
        lock.unlock()
        let box = UncheckedBox(backend)
        queue.async { [self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            do throws(RecognizerError) { try box.value.warmUp() } catch {
                // the real chunks that follow are checked as usual
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            lock.lock()
            _warming = false
            _warmUps += 1
            _lastWarmUpMs = ms
            lock.unlock()
        }
    }

    /// The app became active: the next chunk is a cold one (its own limit, not a warm measurement).
    func markCold() {
        lock.lock()
        _cold = true
        lock.unlock()
    }

    /// Whether the app became active since the last call (and clears it).
    func takeCold() -> Bool {
        lock.lock()
        let c = _cold
        _cold = false
        lock.unlock()
        return c
    }
}

/// The per-chunk checks of an accelerator's heads.
enum HeadsCheck {
    /// Log-probabilities above this are out of range (log-softmax is at most 0; fp16 rounding stays far below it).
    static let logProbCeiling: Float = 0.01
    /// Log-probabilities below this are out of range: no V4 build produces a log-softmax below about -100 (fp16 logits
    /// are bounded by the layer norms before them); -10,000 is fp16 garbage, not a confident zero.
    static let logProbFloor: Float = -10_000
    /// Probability heads (softmax) outside -0.01...1.01, logits beyond 10,000 in magnitude.
    static let probSlack: Float = 0.01
    static let logitLimit: Float = 10_000

    static let logProbHeads: Set<String> = ["log_probs", "inter1_log_probs", "inter4_log_probs", "id_log_probs", "timing_log_probs"]
    static let probHeads: Set<String> = ["gem", "attr_tafkheem", "attr_ghunna", "attr_qalqalah", "attr_face"]

    /// Nil when the chunk is fine, else the cause and which head.
    static func check(_ c: TajweedHeads) -> (FailoverCause, String)? {
        for (name, _, _) in TajweedHeads.layout {
            let v = c[name]
            if v.isEmpty { continue }
            if !v.allSatisfy(\.isFinite) { return (.nonFinite, "\(name) is NaN or infinite") }
            if logProbHeads.contains(name) {
                if let bad = v.first(where: { $0 > logProbCeiling || $0 < logProbFloor }) { return (.outOfRange, "\(name) has \(bad)") }
            } else if probHeads.contains(name) {
                if let bad = v.first(where: { $0 < -probSlack || $0 > 1 + probSlack }) { return (.outOfRange, "\(name) has \(bad)") }
            } else if let bad = v.first(where: { abs($0) > logitLimit }) {
                return (.outOfRange, "\(name) has \(bad)")
            }
        }
        return nil
    }
}

/// A blank suspicion checked off the audio path: a CPU engine opened on a background queue replays the ring (the take
/// from chunk `from`) up to the end of the suspicious chunks. Its result is read by the take's next call.
final class BlankVerification: @unchecked Sendable {
    /// The first suspicious chunk, how many, the chunk the replay starts at, and the absolute sample position the
    /// replay ends at.
    let first: Int
    let count: Int
    let from: Int
    let end: Int
    /// The accelerator's greedy tokens over the suspicious chunks (blank chunks: none).
    let accTokens: [Int]

    struct Replayed {
        var engine: (any CPUStreamEngine)?
        /// CPU chunk i is the take's chunk `from + i`.
        var chunks: [TajweedHeads] = []
        var error: RecognizerError?
        var openMs = 0.0
        var replayMs = 0.0
    }

    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var _done = false
    private var _cancelled = false
    private var _result = Replayed()

    /// - Parameters:
    ///   - ring: the take's ring as it is now (a copy: the samples are read from it on the background queue, so the
    ///     audio path pays only the copy-on-write of the buffer at its next append), and `tail`, the call's audio not
    ///     in it yet; the replay is the ring from sample `from x piece` on, then `tail`.
    init(first: Int, count: Int, from: Int, end: Int, accTokens: [Int], ring: AudioRing, tail: [Float], piece: Int,
         openCPU: @escaping () throws(RecognizerError) -> any CPUStreamEngine) {
        self.first = first
        self.count = count
        self.from = from
        self.end = end
        self.accTokens = accTokens
        let open = Opener(openCPU)
        let start = from * max(1, piece)
        DispatchQueue.global(qos: .utility).async { [self] in
            self.replay(open.open, ring.samples(from: start) + tail, piece: max(1, piece))
        }
    }

    /// The same with the audio already gathered (tests and measurements).
    convenience init(first: Int, count: Int, from: Int, end: Int, accTokens: [Int], audio: [Float], piece: Int,
                     openCPU: @escaping () throws(RecognizerError) -> any CPUStreamEngine) {
        self.init(first: first, count: count, from: from, end: end, accTokens: accTokens, ring: AudioRing(capacity: 1), tail: audio,
                  piece: piece, openCPU: openCPU)
    }

    /// The opener across the queue hop (a class, not a generic box: a typed-throws function type as a generic argument
    /// needs iOS 18 / macOS 15 at run time).
    private final class Opener: @unchecked Sendable {
        let open: () throws(RecognizerError) -> any CPUStreamEngine
        init(_ open: @escaping () throws(RecognizerError) -> any CPUStreamEngine) { self.open = open }
    }

    private func replay(_ open: () throws(RecognizerError) -> any CPUStreamEngine, _ audio: [Float], piece: Int) {
        var r = Replayed()
        let t0 = CFAbsoluteTimeGetCurrent()
        do throws(RecognizerError) {
            let e = try open()
            let t1 = CFAbsoluteTimeGetCurrent()
            r.openMs = (t1 - t0) * 1000
            e.reset()
            var at = 0
            while at < audio.count, !isCancelled {
                let n = min(piece, audio.count - at)
                let lo = at
                r.chunks += try audio.withUnsafeBufferPointer { (p) throws(RecognizerError) -> [TajweedHeads] in
                    try e.push(UnsafeBufferPointer(rebasing: p[lo..<(lo + n)]))
                }
                at += n
            }
            r.replayMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
            r.engine = isCancelled ? nil : e
        } catch {
            r.error = error
        }
        lock.lock()
        _result = r
        _done = true
        lock.unlock()
        finished.signal()
    }

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    /// Waits until the replay ended (at most `seconds`); true when it did.
    @discardableResult
    func wait(_ seconds: TimeInterval) -> Bool {
        if isDone { return true }
        let ok = finished.wait(timeout: .now() + max(0, seconds)) == .success
        if ok { finished.signal() }   // later waits pass at once
        return ok
    }

    /// Stops the replay at its next piece and drops its engine.
    func cancel() {
        lock.lock()
        _cancelled = true
        _result.engine = nil
        lock.unlock()
    }

    /// The result, once done (the engine handed over: a second call gets none).
    func take() -> Replayed {
        lock.lock()
        defer { lock.unlock() }
        let r = _result
        _result.engine = nil
        return r
    }
}

/// Runs one take on the accelerator or the CPU engine, watches every accelerator chunk, and switches to the CPU engine
/// at a failed chunk (see the top of this file). Not thread-safe: the recognizer (an actor) drives it; tests drive it
/// with fakes.
final class TakeRunner {
    /// What a push or finish adds to the take: drop the take's chunks from `truncateTo` on (when set), then append
    /// `chunks` in order.
    struct Output {
        var truncateTo: Int?
        var chunks: [TajweedHeads] = []
        /// Hand the take's chunks out again from this index on (a confirmed blank disagreement: the CPU's chunks
        /// replace those the accelerator heard nothing in, with the same indexes).
        var redeliverFrom: Int?
    }

    /// A switch to the CPU engine during this take.
    struct Failover: Sendable, Equatable {
        var cause: FailoverCause
        var detail: String
        /// The chunk index that failed (a confirmed blank: the first suspicious chunk).
        var chunk: Int
        /// The chunk the CPU engine replayed from (0: the whole take, exact).
        var replayFrom: Int
        /// From the failure detected to the failed chunk's CPU result (a confirmed blank: the catch-up after the
        /// verification, which ran beside the session).
        var stallMs: Double
        /// Whether the CPU engine had to be opened (it was closed while the accelerator served).
        var cold: Bool
        /// How long the failed call ran, and the limit it had.
        var elapsedMs: Double?
        var deadlineMs: Double
        var errorDomain: String?
        var errorCode: String?
        /// A confirmed blank disagreement: the CPU's tokens (expected) against the accelerator's over the suspicious
        /// chunks.
        var divergence: Divergence? = nil
        var exact: Bool { replayFrom == 0 }
    }

    struct Policy {
        /// The warm chunks' deadline, ms, before (or without) enough warm chunk times.
        var deadlineMs: Double = PromotionPolicy.deadlineMs(p90Ms: nil, medianMs: nil)
        /// The limit of a cold chunk (the first of the take, the first after the app became active), ms.
        var firstChunkMs: Double = PromotionPolicy.firstChunkLimitMs(p90Ms: nil)
        /// The key's warm chunk times, ms: with the take's own warm chunks, the later chunks' deadline.
        var warmMs: [Double] = []
        /// After its deadline, how long a call may still answer before it is a hang (ms; 0: a hang at the deadline).
        var hangGraceMs: Double = PromotionPolicy.hangGraceMs
        /// One prediction on silence at take start, off the audio path.
        var warmUpAtStart = true
        /// The CPU engine's chunk time and cold open on this device, ms (for the replay window).
        var cpuChunkMs: Double = PromotionPolicy.defaultCPUChunkMs
        var cpuOpenMs: Double = PromotionPolicy.defaultCPUOpenMs
        var stallBudgetMs: Double = PromotionPolicy.stallBudgetMs
        /// The fewest chunks a bounded replay runs: the caches' span plus one chunk.
        var minReplayChunks = 5
        /// When set, the replay never runs more chunks than this (tests of the bounded path).
        var maxReplayChunks: Int?
        /// Measurement only: keep the CPU engine open behind the accelerator (the warm switch the tests time; the SDK
        /// never does this, it would cost the engine's resident weights for the whole session).
        var keepCPUOpen = false
        /// Chunks with no token while the audio has energy, in a row, before a blank suspicion.
        var blankChunks = 3
        /// The RMS above which pushed audio counts as having energy (about -40 dBFS).
        var energyRMS: Float = 0.01
        /// Token edits between the CPU and the accelerator over the suspicious chunks that still agree (the build's
        /// golden tolerance, `token_diffs`; 0 when the manifest gives none).
        var blankTokenTolerance = 0
        /// At most one blank verification per this much audio, seconds.
        var verifyEverySeconds = PromotionPolicy.verifyEverySeconds

        /// Chunks the CPU can rerun within the stall budget.
        var replayChunks: Int {
            let fit = Int(((stallBudgetMs - cpuOpenMs) / max(0.1, cpuChunkMs)).rounded(.down))
            var n = max(minReplayChunks, fit)
            if let m = maxReplayChunks { n = min(n, m) }
            return max(1, n)
        }
    }

    /// Opens the CPU engine (cold) when it is closed.
    let openCPU: () throws(RecognizerError) -> any CPUStreamEngine
    /// Samples a chunk advances by (chunk_ms x 16).
    let chunkSamples: Int
    var policy = Policy()
    /// Whether a failure switches to the CPU engine (a session) or fails the call (the golden test, which compares
    /// every clip with the CPU engine itself: no blank rule there).
    var failoverEnabled = true

    private(set) var cpu: (any CPUStreamEngine)?
    private(set) var accelerator: AcceleratorExecutor?
    private var ring: AudioRing
    /// Chunks in the take so far.
    private(set) var chunks = 0
    private var blankRun = 0
    /// The switch in this take, when there was one.
    private(set) var failover: Failover?
    /// The detection that failed a call with `failoverEnabled` off.
    private(set) var detected: (cause: FailoverCause, detail: String)?
    /// Per-chunk compute seconds of the take (the backend that ran each chunk).
    private(set) var chunkSeconds: [Double] = []
    /// Milliseconds the last cold open of the CPU engine took.
    private(set) var lastOpenMs: Double?
    /// Whether the CPU stream holds the whole take (it ran from the start, or replayed all of it).
    private(set) var cpuHasWholeTake = true
    /// The next accelerator chunk is a cold one.
    private var coldNext = false
    /// The accelerator's warm chunk times in this take, ms (cold chunks left out).
    private(set) var takeWarmMs: [Double] = []
    /// The blank verification in flight.
    private(set) var verification: BlankVerification?
    private var lastVerifyAt: Int?
    /// Blank verifications started in this take, and those where the CPU agreed (no failover).
    private(set) var verifications = 0
    private(set) var blankConfirmedOK = 0
    /// The last finished verification: the CPU's open and replay times, chunks replayed, and whether it agreed.
    private(set) var lastVerification: (openMs: Double, replayMs: Double, chunks: Int, agreed: Bool)?
    /// What starting the last verification cost the audio path, ms (the ring's buffer is copied once, at its next append).
    private(set) var lastSuspicionMs: Double?

    /// - Parameters:
    ///   - cpu: the CPU engine when it is already open (else the first CPU take opens it).
    ///   - openCPU: opens the CPU engine (cold).
    init(chunkMs: Int, ringSeconds: Double = PromotionPolicy.ringSeconds, cpu: (any CPUStreamEngine)? = nil,
         openCPU: @escaping () throws(RecognizerError) -> any CPUStreamEngine) {
        chunkSamples = chunkMs * 16
        ring = AudioRing(capacity: Int(ringSeconds * 16_000))
        self.cpu = cpu
        self.openCPU = openCPU
    }

    var chunkMs: Int { chunkSamples / 16 }

    var onAccelerator: Bool { accelerator != nil }

    /// The deadline of the next warm chunk, ms: from the key's and the take's warm chunk times (the most recent 64),
    /// else the policy's.
    var laterLimitMs: Double {
        let s = Array((policy.warmMs + takeWarmMs).suffix(PromotionPolicy.warmSamplesKept))
        guard s.count >= PromotionPolicy.minWarmSamples else { return policy.deadlineMs }
        return PromotionPolicy.deadlineMs(p90Ms: AcceleratorController.percentile(s, 0.9), medianMs: AcceleratorController.percentile(s, 0.5))
    }

    /// The CPU engine, opened now if it is closed.
    @discardableResult
    func ensureCPU() throws(RecognizerError) -> any CPUStreamEngine {
        if let cpu { return cpu }
        let t0 = CFAbsoluteTimeGetCurrent()
        let c = try openCPU()
        lastOpenMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        cpu = c
        return c
    }

    /// Closes the CPU engine (its private weight pages go back to the OS).
    func closeCPU() { cpu = nil }

    /// Stops a blank verification still running and drops its engine (waits at most a second for its current piece).
    func dropVerification() {
        guard let v = verification else { return }
        verification = nil
        v.cancel()
        v.wait(1)
        _ = v.take()
    }

    /// A new take, on `accelerator` when given (the CPU engine is then closed, and the accelerator warmed up off the
    /// audio path), else on the CPU engine.
    func start(accelerator a: AcceleratorExecutor?) throws(RecognizerError) {
        dropVerification()
        ring.reset()
        chunks = 0
        blankRun = 0
        failover = nil
        detected = nil
        chunkSeconds = []
        takeWarmMs = []
        lastVerifyAt = nil
        verifications = 0
        blankConfirmedOK = 0
        lastVerification = nil
        lastSuspicionMs = nil
        if let a, a.reset() {
            cpuHasWholeTake = false
            accelerator = a
            // the take's first chunk is cold whatever happened before
            coldNext = true
            _ = a.takeCold()
            if policy.warmUpAtStart { a.warmUp() }
            if !policy.keepCPUOpen { closeCPU() }
        } else {
            cpuHasWholeTake = true
            accelerator = nil
            coldNext = false
            try ensureCPU().reset()
        }
    }

    /// 16 kHz samples in; what they add to the take out.
    func push(_ s: [Float]) throws(RecognizerError) -> Output {
        defer { ring.append(s) }
        guard let a = accelerator else { return Output(chunks: try cpuPush(s)) }
        if let v = verification, v.isDone {
            verification = nil
            if let o = try settle(v, audio: s, finishing: false) { return o }
        }
        if a.takeCold() { coldNext = true }
        let expected = max(1, s.count / max(1, chunkSamples) + 1)
        let later = laterLimitMs
        let first = coldNext ? policy.firstChunkMs : later
        let timeout = (first + later * Double(expected - 1)) / 1000
        let r = a.run(timeout: timeout, grace: policy.hangGraceMs / 1000) { (b: any AcceleratorBackend) throws(RecognizerError) -> [TajweedHeads] in
            try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try b.push(p) }
        }
        return try judge(r, audio: s, finishing: false, firstLimit: first, laterLimit: later)
    }

    /// The end of the take (the flush); what it adds to the take. A blank verification still running is waited for
    /// (at most `PromotionPolicy.verifyWaitAtFinish`), so a confirmed disagreement still reaches the take.
    func finish() throws(RecognizerError) -> Output {
        guard let a = accelerator else {
            guard let cpu else { throw .sessionClosed }
            return Output(chunks: try timed { () throws(RecognizerError) in try cpu.finish() })
        }
        if let v = verification {
            verification = nil
            if v.wait(PromotionPolicy.verifyWaitAtFinish) {
                if let o = try settle(v, audio: [], finishing: true) { return o }
            } else {
                v.cancel()
            }
        }
        if a.takeCold() { coldNext = true }
        let later = laterLimitMs
        let first = coldNext ? policy.firstChunkMs : later
        // the flush runs about four chunks (1.05 s of zeros and the fbank's tail)
        let r = a.run(timeout: (first + later * 5) / 1000, grace: policy.hangGraceMs / 1000) {
            (b: any AcceleratorBackend) throws(RecognizerError) -> [TajweedHeads] in
            try b.finish()
        }
        return try judge(r, audio: [], finishing: true, firstLimit: first, laterLimit: later)
    }

    private func cpuPush(_ s: [Float]) throws(RecognizerError) -> [TajweedHeads] {
        guard let cpu else { throw .sessionClosed }
        let out = try timed { () throws(RecognizerError) in try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try cpu.push(p) } }
        chunks += out.count
        return out
    }

    private func timed(_ body: () throws(RecognizerError) -> [TajweedHeads]) throws(RecognizerError) -> [TajweedHeads] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try body()
        if !out.isEmpty {
            let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(out.count)
            chunkSeconds += Array(repeating: dt, count: out.count)
        }
        return out
    }

    private func judge(_ r: AcceleratorExecutor.Outcome, audio s: [Float], finishing: Bool, firstLimit: Double,
                       laterLimit: Double) throws(RecognizerError) -> Output {
        switch r {
        case .threw(let e, let ns):
            return try fail(.exception, "the accelerator threw: \(e)", at: chunks, good: [], audio: s, finishing: finishing,
                            elapsedMs: nil, limitMs: coldNext ? firstLimit : laterLimit, ns: ns)
        case .timedOut(let ms):
            return try fail(.deadline, String(format: "no answer within %.0f ms", ms), at: chunks, good: [], audio: s,
                            finishing: finishing, elapsedMs: ms, limitMs: coldNext ? firstLimit : laterLimit, ns: nil)
        case .done(let out, let seconds):
            let energy = s.isEmpty ? 0 : (s.reduce(Float(0)) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
            var warm: [Double] = []
            for (i, c) in out.enumerated() {
                let ms = i < seconds.count ? seconds[i] * 1000 : 0
                let cold = i == 0 && coldNext
                let limit = cold ? firstLimit : laterLimit
                if let bad = HeadsCheck.check(c) {
                    return try fail(bad.0, bad.1, at: chunks + i, good: Array(out[..<i]), audio: s, finishing: finishing, elapsedMs: ms,
                                    limitMs: limit, ns: nil)
                }
                if ms > limit {
                    let why = cold ? String(format: "the first chunk took %.1f ms (first-chunk limit %.0f ms)", ms, limit)
                        : String(format: "a chunk took %.1f ms (deadline %.0f ms)", ms, limit)
                    return try fail(.deadline, why, at: chunks + i, good: Array(out[..<i]), audio: s, finishing: finishing, elapsedMs: ms,
                                    limitMs: limit, ns: nil)
                }
                if !cold { warm.append(ms) }
                blankRun = c.greedy.isEmpty && energy > policy.energyRMS ? blankRun + 1 : 0
                if blankRun >= policy.blankChunks {
                    // a suspicion only: verified on the CPU engine off the audio path (sessions), ignored by the golden
                    // test (it compares every clip with the CPU engine itself)
                    if failoverEnabled { suspect(first: chunks + i - (blankRun - 1), count: blankRun, audio: s) }
                    blankRun = 0
                }
            }
            if !out.isEmpty { coldNext = false }
            takeWarmMs += warm
            chunkSeconds += seconds.count == out.count ? seconds : Array(repeating: seconds.last ?? 0, count: out.count)
            chunks += out.count
            return Output(chunks: out)
        }
    }

    /// The blank rule fired at chunks first..<first + count (the last one in this call): replay the ring through a CPU
    /// engine on a background queue, unless a verification is in flight or one started less than 10 s of audio ago.
    private func suspect(first: Int, count: Int, audio s: [Float]) {
        let pos = ring.total + s.count
        guard verification == nil else { return }
        if let last = lastVerifyAt, Double(pos - last) < policy.verifyEverySeconds * 16_000 { return }
        // the whole ring: from the first chunk it holds entirely (chunk 0 while the take fits in it)
        let from = ring.oldest == 0 ? 0 : (ring.oldest + chunkSamples - 1) / chunkSamples
        guard from <= first else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        lastVerifyAt = pos
        verifications += 1
        // blank chunks: the accelerator's tokens over them are none; the ring is read on the background queue
        verification = BlankVerification(first: first, count: count, from: from, end: pos, accTokens: [], ring: ring, tail: s,
                                         piece: chunkSamples, openCPU: openCPU)
        lastSuspicionMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// A finished verification: nil when the CPU agrees (or could not run: the take stays on the accelerator), else the
    /// switch to its engine.
    private func settle(_ v: BlankVerification, audio s: [Float], finishing: Bool) throws(RecognizerError) -> Output? {
        let r = v.take()
        guard r.error == nil, let engine = r.engine else { return nil }
        let lo = v.first - v.from, hi = lo + v.count
        guard lo >= 0, r.chunks.count >= hi else { return nil }
        var window = TajweedHeads()
        for c in r.chunks[lo..<hi] { window.append(c) }
        let d = Divergence(expected: window.greedy, tokens: v.accTokens, expectedSites: [], sites: [], expectedWords: [], words: [])
        let agreed = d.tokensDiffer <= policy.blankTokenTolerance
        lastVerification = (r.openMs, r.replayMs, r.chunks.count, agreed)
        if agreed {
            // the CPU heard nothing either (a madd, a held vowel): the engine goes (closed), the take stays
            blankConfirmedOK += 1
            return nil
        }
        return try switchConfirmed(v, engine: engine, replayed: r.chunks, divergence: d, audio: s, finishing: finishing)
    }

    /// A confirmed disagreement: the take continues on the verification's CPU engine, which catches up with the audio
    /// since its replay ended; the chunks from the first suspicious one are the CPU's and are handed out again.
    private func switchConfirmed(_ v: BlankVerification, engine: any CPUStreamEngine, replayed: [TajweedHeads], divergence d: Divergence,
                                 audio s: [Float], finishing: Bool) throws(RecognizerError) -> Output {
        let why = "the CPU engine heard \(d.tokensExpected) tokens in \(v.count) chunks where the accelerator heard none"
        // more audio since than the ring keeps (never with a 30 s ring and a verification of seconds): the usual switch
        guard v.end >= ring.oldest else {
            return try fail(.blank, why, at: v.first, good: [], audio: s, finishing: finishing, elapsedMs: nil, limitMs: laterLimitMs,
                            ns: nil, divergence: d)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        accelerator = nil
        let gap = ring.samples(from: v.end) + s
        var out = replayed
        out += try gap.withUnsafeBufferPointer { (p) throws(RecognizerError) in try engine.push(p) }
        if finishing { out += try engine.finish() }
        // CPU chunk i is the take's chunk v.from + i; a whole-take replay replaces the whole take (exact)
        let kept = v.from == 0 ? 0 : v.first
        let skip = kept - v.from
        let add: [TajweedHeads] = skip < out.count ? Array(out[skip...]) : []
        let stall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        failover = Failover(cause: .blank, detail: why, chunk: v.first, replayFrom: v.from, stallMs: stall, cold: true, elapsedMs: nil,
                            deadlineMs: laterLimitMs, errorDomain: nil, errorCode: nil, divergence: d)
        cpu = engine
        cpuHasWholeTake = v.from == 0
        chunks = kept + add.count
        chunkSeconds = Array(chunkSeconds.prefix(kept))
        chunkSeconds += Array(repeating: stall / 1000 / Double(max(1, add.count)), count: add.count)
        blankRun = 0
        return Output(truncateTo: kept, chunks: add, redeliverFrom: v.first)
    }

    /// The switch: chunk `k` failed (chunks before it are good: the take's first `chunks` plus `good` from this call).
    private func fail(_ cause: FailoverCause, _ why: String, at k: Int, good: [TajweedHeads], audio s: [Float], finishing: Bool,
                      elapsedMs: Double?, limitMs: Double, ns: NSError?, divergence: Divergence? = nil) throws(RecognizerError) -> Output {
        let t0 = CFAbsoluteTimeGetCurrent()
        accelerator = nil
        // a verification in flight holds a CPU engine: it goes first (one engine stream at a time)
        dropVerification()
        guard failoverEnabled else {
            detected = (cause, why)
            throw .neuralEngineUnavailable(why)
        }
        let cold = cpu == nil
        let engine = try ensureCPU()
        engine.reset()
        let before = chunks
        // the replay window: the whole take when the CPU can rerun it within the budget, else the last chunks
        let n = policy.replayChunks
        var from = k <= n && ring.oldest == 0 ? 0 : max(0, k - n)
        while from * chunkSamples < ring.oldest { from += 1 }
        let audio = ring.samples(from: from * chunkSamples) + s
        var out = try audio.withUnsafeBufferPointer { (p) throws(RecognizerError) in try engine.push(p) }
        if finishing { out += try engine.finish() }
        // CPU chunk i is the take's chunk from + i
        let kept = from == 0 ? 0 : min(k, before)
        var add: [TajweedHeads] = from == 0 ? [] : Array(good.prefix(max(0, k - before)))
        let skip = (from == 0 ? 0 : k - from)
        if skip < out.count { add += out[skip...] }
        let stall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        failover = Failover(cause: cause, detail: why, chunk: k, replayFrom: from, stallMs: stall, cold: cold, elapsedMs: elapsedMs,
                            deadlineMs: limitMs, errorDomain: ns?.domain, errorCode: ns.map { String($0.code) }, divergence: divergence)
        cpuHasWholeTake = from == 0
        chunks = kept + add.count
        chunkSeconds = Array(chunkSeconds.prefix(kept))
        chunkSeconds += Array(repeating: stall / 1000 / Double(max(1, out.count)), count: add.count)
        blankRun = 0
        return Output(truncateTo: kept, chunks: add, redeliverFrom: cause == .blank ? k : nil)
    }
}
