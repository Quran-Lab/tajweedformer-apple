import Foundation

// In-session failover: a take that runs on the accelerator switches to the exact CPU engine at the chunk that failed,
// without losing audio and without an error the app sees.
//
// Detection, per chunk: the call threw; a head is NaN or infinite; a head left its known range; chunks heard nothing
// while the audio had energy (3 in a row, about a second); or a chunk missed its deadline. The deadline is enforced by
// running every accelerator call on the accelerator's own serial queue and waiting for it with a timer: a call that
// does not return in time is abandoned (never awaited again, its result dropped) and the accelerator is never used
// again in this process.
//
// No standby in memory. The exact engine maps its weight file and, on every chip with the SDOT instruction (A13 and
// later, every M chip), rewrites the int8 weights of every linear layer into the SDOT layout at load, in place: the
// mapping's pages become private copies, about 64 MB of resident memory the OS cannot drop. A CPU engine kept ready
// behind the Neural Engine would therefore cost that much for the whole session. So while the accelerator serves, the
// CPU engine is closed, and the switch is a fast cold one: open the engine (the file is usually still in the page
// cache), make the stream, and replay the take's recent audio.
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

/// The accelerator's own serial queue: every call runs there and is waited for with a deadline; a call that misses it
/// is abandoned and the executor refuses every later call.
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

    init(_ backend: any AcceleratorBackend, label: String = "ai.quranlab.accelerator") {
        self.backend = backend
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// A call missed its deadline: nothing runs here again.
    var abandoned: Bool { lock.lock(); defer { lock.unlock() }; return _abandoned }

    private final class Slot: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<[TajweedHeads], RecognizerError>?
        var nsError: NSError?
        var seconds: [Double] = []
    }

    /// Runs `body` on the queue and waits for it at most `timeout` seconds (synchronously: called from the
    /// recognizer's synchronous chunk path, never from the queue itself).
    func run(timeout: TimeInterval, _ body: @escaping @Sendable (any AcceleratorBackend) throws(RecognizerError) -> [TajweedHeads]) -> Outcome {
        if abandoned { return .threw(.neuralEngineUnavailable("the accelerator was abandoned after a missed deadline"), nsError: nil) }
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
            lock.lock()
            _abandoned = true
            lock.unlock()
            return .timedOut(elapsedMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        switch slot.result {
        case .success(let h)?: return .done(h, seconds: slot.seconds)
        case .failure(let e)?: return .threw(e, nsError: slot.nsError)
        case nil: return .threw(.neuralEngineUnavailable("no result"), nsError: nil)
        }
    }

    /// Resets the backend for a new take (on the queue, so it never overlaps a call).
    func reset() -> Bool {
        if abandoned { return false }
        let box = UncheckedBox(backend)
        queue.sync { box.value.reset() }
        return true
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

/// Runs one take on the accelerator or the CPU engine, watches every accelerator chunk, and switches to the CPU engine
/// at a failed chunk (see the top of this file). Not thread-safe: the recognizer (an actor) drives it; tests drive it
/// with fakes.
final class TakeRunner {
    /// What a push or finish adds to the take: drop the take's chunks from `truncateTo` on (when set), then append
    /// `chunks` in order.
    struct Output {
        var truncateTo: Int?
        var chunks: [TajweedHeads] = []
    }

    /// A switch to the CPU engine during this take.
    struct Failover: Sendable, Equatable {
        var cause: FailoverCause
        var detail: String
        /// The chunk index that failed.
        var chunk: Int
        /// The chunk the CPU engine replayed from (0: the whole take, exact).
        var replayFrom: Int
        /// From the failure detected to the failed chunk's CPU result.
        var stallMs: Double
        /// Whether the CPU engine had to be opened (it was closed while the accelerator served).
        var cold: Bool
        /// How long the failed call ran, and its deadline.
        var elapsedMs: Double?
        var deadlineMs: Double
        var errorDomain: String?
        var errorCode: String?
        var exact: Bool { replayFrom == 0 }
    }

    struct Policy {
        /// The accelerator's per-chunk deadline, ms.
        var deadlineMs: Double = PromotionPolicy.deadlineMs(p90Ms: nil, medianMs: nil)
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
        /// Chunks with no token while the audio has energy, in a row, before the take leaves the accelerator.
        var blankChunks = 3
        /// The RMS above which pushed audio counts as having energy (about -40 dBFS).
        var energyRMS: Float = 0.01

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
    /// Whether a failure switches to the CPU engine (a session) or fails the call (the golden test).
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

    /// A new take, on `accelerator` when given (the CPU engine is then closed), else on the CPU engine.
    func start(accelerator a: AcceleratorExecutor?) throws(RecognizerError) {
        ring.reset()
        chunks = 0
        blankRun = 0
        failover = nil
        detected = nil
        chunkSeconds = []
        if let a, a.reset() {
            cpuHasWholeTake = false
            accelerator = a
            if !policy.keepCPUOpen { closeCPU() }
        } else {
            cpuHasWholeTake = true
            accelerator = nil
            try ensureCPU().reset()
        }
    }

    /// 16 kHz samples in; what they add to the take out.
    func push(_ s: [Float]) throws(RecognizerError) -> Output {
        defer { ring.append(s) }
        guard let a = accelerator else { return Output(chunks: try cpuPush(s)) }
        let expected = max(1, s.count / max(1, chunkSamples) + 1)
        let deadline = policy.deadlineMs
        let r = a.run(timeout: deadline / 1000 * Double(expected)) { (b: any AcceleratorBackend) throws(RecognizerError) -> [TajweedHeads] in
            try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try b.push(p) }
        }
        return try judge(r, audio: s, finishing: false)
    }

    /// The end of the take (the flush); what it adds to the take.
    func finish() throws(RecognizerError) -> Output {
        guard let a = accelerator else {
            guard let cpu else { throw .sessionClosed }
            return Output(chunks: try timed { () throws(RecognizerError) in try cpu.finish() })
        }
        // the flush runs about four chunks (1.05 s of zeros and the fbank's tail)
        let r = a.run(timeout: policy.deadlineMs / 1000 * 6) { (b: any AcceleratorBackend) throws(RecognizerError) -> [TajweedHeads] in
            try b.finish()
        }
        return try judge(r, audio: [], finishing: true)
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

    private func judge(_ r: AcceleratorExecutor.Outcome, audio s: [Float], finishing: Bool) throws(RecognizerError) -> Output {
        let deadline = policy.deadlineMs
        switch r {
        case .threw(let e, let ns):
            return try fail(.exception, "the accelerator threw: \(e)", at: chunks, good: [], audio: s, finishing: finishing,
                            elapsedMs: nil, ns: ns)
        case .timedOut(let ms):
            return try fail(.deadline, String(format: "no answer within %.0f ms", ms), at: chunks, good: [], audio: s,
                            finishing: finishing, elapsedMs: ms, ns: nil)
        case .done(let out, let seconds):
            let energy = s.isEmpty ? 0 : (s.reduce(Float(0)) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
            for (i, c) in out.enumerated() {
                let ms = i < seconds.count ? seconds[i] * 1000 : 0
                if let bad = HeadsCheck.check(c) {
                    return try fail(bad.0, bad.1, at: chunks + i, good: Array(out[..<i]), audio: s, finishing: finishing, elapsedMs: ms, ns: nil)
                }
                if ms > deadline {
                    return try fail(.deadline, String(format: "a chunk took %.1f ms (deadline %.0f ms)", ms, deadline), at: chunks + i,
                                    good: Array(out[..<i]), audio: s, finishing: finishing, elapsedMs: ms, ns: nil)
                }
                blankRun = c.greedy.isEmpty && energy > policy.energyRMS ? blankRun + 1 : 0
                if blankRun >= policy.blankChunks {
                    let first = chunks + i - (blankRun - 1)
                    return try fail(.blank, "\(blankRun) chunks in a row heard nothing in audio with energy", at: first,
                                    good: Array(out[..<i]), audio: s, finishing: finishing, elapsedMs: ms, ns: nil)
                }
            }
            chunkSeconds += seconds.count == out.count ? seconds : Array(repeating: seconds.last ?? 0, count: out.count)
            chunks += out.count
            return Output(chunks: out)
        }
    }

    /// The switch: chunk `k` failed (chunks before it are good: the take's first `chunks` plus `good` from this call).
    private func fail(_ cause: FailoverCause, _ why: String, at k: Int, good: [TajweedHeads], audio s: [Float], finishing: Bool,
                      elapsedMs: Double?, ns: NSError?) throws(RecognizerError) -> Output {
        let t0 = CFAbsoluteTimeGetCurrent()
        accelerator = nil
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
                            deadlineMs: policy.deadlineMs, errorDomain: ns?.domain, errorCode: ns.map { String($0.code) })
        cpuHasWholeTake = from == 0
        chunks = kept + add.count
        chunkSeconds = Array(chunkSeconds.prefix(kept))
        chunkSeconds += Array(repeating: stall / 1000 / Double(max(1, out.count)), count: add.count)
        blankRun = 0
        return Output(truncateTo: kept, chunks: add)
    }
}
