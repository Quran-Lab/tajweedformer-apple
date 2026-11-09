@preconcurrency import AVFoundation
import CoreML
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Something the microphone feeds (`Microphone.start(into:)`): buffers in order, without waiting.
public protocol AudioBufferSink: Sendable {
    func enqueue(_ buffer: AVAudioPCMBuffer) throws(RecognizerError)
}

/// V4 TajweedFormer: stream a take, keep every head, decode it, and score it against a known ayah with the calibrated
/// tajweed checks.
///
///     let model = try await TajweedModel.load()                      // this device's download profile, verified
///     let r = try TajweedRecognizer(model: model, options: TajweedOptions(preset: .balanced, word: .general))
///     try await r.startTake()
///     let chunks = try await r.append(samples, sampleRate: 48_000)    // each chunk's selected heads (raw layer)
///     try await r.finish()
///     let heard = await r.decoded()                                   // decoded layer: tokens, margins, confidence
///     let result = try await r.score(surah: 1, ayah: 2)               // tajweed layer: sites, madd, words
///     await r.endSession(feedback: true)                              // lets the SDK ask about sharing, at the right moment
///
/// Backends, CPU first: the exact CPU engine serves from the first take, always. With `.automatic` (the default, no
/// code needed) the CoreML package is prepared in the background and self-tested against the model folder's
/// self-test set; once it passes (`acceleratorState == .ready`), takes from the next one on run on the Neural Engine.
/// A fault during a take (a non-finite head, a chunk over budget, all-blank chunks with audio in them, an exception)
/// re-runs that take on the CPU engine from its start, hands out only the chunks not handed out yet, and keeps the CPU
/// engine for the rest of the launch; `fallbackReason` says why and telemetry counts it.
///
/// Settings precedence: the app's `options` > the portal's tajweed block (signed remote config) > calibration.json.
/// `debugBuild` is the APP's build: only a debug build may turn on a check calibration marks `off`, or force the
/// Neural Engine.
public actor TajweedRecognizer: AudioBufferSink {
    public enum Backend: String, Sendable {
        /// The exact CPU engine first; the Neural Engine once it is prepared and passed its self-test.
        case automatic
        /// Debug builds only: the Neural Engine at once, without the self-test; throws where it cannot load. A CPU-only
        /// context (`ModelContexts`) stays on the exact CPU engine, without an error.
        case neuralEngine
        /// The exact CPU engine only.
        case exact
    }

    public let model: TajweedModel
    /// The settings in force with the exact CPU engine's heads (int8 thresholds).
    public nonisolated let settings: EffectiveTajweed
    /// The same settings with the Neural Engine's heads (calibration's fp32 thresholds).
    public nonisolated let acceleratorSettings: EffectiveTajweed
    /// The heads handed out per chunk.
    public nonisolated let selection: HeadSelection
    /// The context running.
    public nonisolated var context: String { settings.context }
    public private(set) var activeBackend: ActiveBackend?
    /// Why the recognizer is on the CPU engine although the Neural Engine was possible, when it is.
    public private(set) var fallbackReason: FallbackReason?
    public private(set) var fallbackDetail: String?
    /// The settings the current (or last) take is scored with: `settings` on the CPU engine, `acceleratorSettings`
    /// on the Neural Engine.
    public private(set) var settingsInForce: EffectiveTajweed

    private let requested: Backend
    private let scorer: any TajweedScoring
    private let options: TajweedOptions
    private let remote: JSONValue?
    private let debugBuild: Bool
    private var exact: TajweedExactEngine?
    private var accel: (any AcceleratorBackend)?
    private nonisolated let controllerBox = Locked<AcceleratorController?>(nil)
    private var fixedState: AcceleratorState = .cpu
    private var preparationScheduled = false
    private let registryID = UUID()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var blankRun = 0
    private var converter: SampleRateConverter?
    private var take16k: [Float] = []
    private var delivered = 0
    private var take = TajweedHeads()
    private var chunkSeconds: [Double] = []
    private var takeAudioSeconds = 0.0
    private var takeOpen = false
    private var share: ShareCapture?
    private var activity: SessionActivity?
    private var stream: AsyncStream<TajweedChunk>.Continuation?
    private let created = Date()
    private static let firstSessionOfLaunch = Locked(true)
    private nonisolated let feed = Locked<AsyncStream<UncheckedBox<AVAudioPCMBuffer>>.Continuation?>(nil)
    private var feeder: Task<Void, Never>?
    private var feedError: RecognizerError?

    /// - Parameters:
    ///   - remote: the portal's tajweed block; nil reads it from the signed remote config.
    ///   - heads: the heads handed out per chunk (`.default`, `.all`, or a set).
    ///   - backend: `.automatic` (CPU first, then the Neural Engine once verified), `.exact`, or in a debug build
    ///     `.neuralEngine`.
    public init(model: TajweedModel, options: TajweedOptions = .init(), remote: JSONValue? = nil, debugBuild: Bool = false,
                backend: Backend = .automatic, heads: HeadSelection = .default, scorer: (any TajweedScoring)? = nil) throws(RecognizerError) {
        if backend == .neuralEngine && !debugBuild {
            throw .invalidArgument("forcing the Neural Engine is for debug builds (debugBuild: true)")
        }
        self.model = model
        self.requested = backend
        let block = remote ?? QuranLab.cloud?.currentConfig?.tajweed
        settings = try TajweedSettings.resolve(calibration: model.calibration, remote: block, app: options,
                                               debugBuild: debugBuild, backend: .int8)
        acceleratorSettings = try TajweedSettings.resolve(calibration: model.calibration, remote: block, app: options,
                                                          debugBuild: debugBuild, backend: .fp32)
        settingsInForce = settings
        guard model.isUsable(context: settings.context) else {
            throw .modelMissing("the CPU files of \(settings.context) are not in the model folder (TajweedModel.load(context:) fetches them)")
        }
        self.options = options
        self.remote = block
        self.debugBuild = debugBuild
        self.selection = heads
        if let scorer {
            self.scorer = scorer
        } else {
            do { self.scorer = try EngineTajweedScorer(model: model, context: settings.context) } catch {
                self.scorer = UnavailableTajweedScorer("\(error)")
            }
        }
    }

    deinit { AcceleratorRegistry.remove(registryID) }

    // MARK: backends

    var cohort: TelemetryCohort {
        var bucket = ""
        if settings.word.level == "custom", let t = settings.word.threshold {
            bucket = t <= 3 ? "le_3" : t <= 4 ? "le_4" : t <= 5 ? "le_5" : t <= 6 ? "le_6" : t <= 7 ? "le_7" : "gt_7"
        }
        return TelemetryCohort(revision: model.identity, context: settings.context,
                               backend: (activeBackend ?? .exact).telemetryName, preset: settings.presetName,
                               wordLevel: settings.word.enabled ? settings.word.level : "off", wordBucket: bucket,
                               siteOverrides: settings.siteOverrides)
    }

    /// Where the Neural Engine stands.
    public var acceleratorState: AcceleratorState { controllerBox.withLock { $0 }?.state ?? fixedState }

    /// Every change of the Neural Engine's state, starting with the current one (`.cpu` alone when no accelerator
    /// applies).
    public nonisolated func acceleratorStates() -> AsyncStream<AcceleratorState> {
        if let c = controllerBox.withLock({ $0 }) { return c.states() }
        let (s, c) = AsyncStream<AcceleratorState>.makeStream()
        c.yield(.cpu)
        c.finish()
        return s
    }

    /// Waits until the Neural Engine is ready or will not be (up to `timeout`); true when the next take will run on it.
    /// Starts the preparation now if it has not started.
    public func awaitReady(timeout: TimeInterval) async -> Bool {
        guard let c = controllerBox.withLock({ $0 }) else { return false }
        if c.state == .cpu { schedulePreparation(now: true) }
        return await c.awaitReady(timeout: timeout)
    }

    /// What the accelerator's self-test found, once it ran in this launch.
    public var acceleratorSelfTest: AcceleratorSelfTest? { controllerBox.withLock { $0 }?.lastSelfTest }

    /// Builds the CPU engine now (otherwise the first `startTake` does), and sets up the Neural Engine's background
    /// preparation where it applies.
    public func prepare() throws(RecognizerError) {
        guard exact == nil else { return }
        let t0 = Date()
        let ctx = settings.context
        exact = try TajweedExactEngine(directory: model.directory, context: ctx)
        // only the heads this recognizer hands out or keeps (the scorer's, conf for the decoded layer)
        exact?.setHeads(HeadSelection(selection.heads.union([.conf])).engineMask)
        activeBackend = .exact
        QuranLab.record(.modelLoaded(revision: model.revision, milliseconds: Date().timeIntervalSince(t0) * 1000, cohort: cohort))
        guard Self.mayUseAccelerator(requested: requested, context: ctx) else { return }
        guard DownloadProfile.osRunsCoreML else {
            if requested == .neuralEngine { throw .neuralEngineUnavailable("the V4 CoreML package needs iOS 18 or macOS 15") }
            if model.manifest.files.contains(where: { DownloadProfile.packageRoles.contains($0.role) }) {
                fixedState = .disabled("the OS is older than iOS 18 / macOS 15")
                noteFallback(.aneUnavailable, "the OS is older than iOS 18 / macOS 15")
            }
            return
        }
        guard let build = model.coreML(context: ctx) else {
            if requested == .neuralEngine { throw .neuralEngineUnavailable(model.coreMLProblem ?? "the folder has no CoreML package for \(ctx)") }
            if let p = model.coreMLProblem {
                fixedState = .disabled(p)
                noteFallback(.modelLoad, p)
            }
            return
        }
        guard #available(iOS 18.0, macOS 15.0, *) else { return }
        if requested == .neuralEngine {
            // debug builds: the package at once, without the self-test
            accel = try TajweedNeuralEngine(build)
            fixedState = .ready
            activeBackend = .neuralEngine
            return
        }
        let identity = model.identity
        let cohortNow = cohort
        let env = AcceleratorController.Environment(
            revision: identity, context: ctx, compact: build.compact,
            storage: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"),
            denied: {
                guard let f = QuranLab.cloud?.forcedBackend(revision: identity), f.backend == .exact else { return nil }
                return f.reason
            },
            record: { QuranLab.record($0) },
            cohort: { cohortNow })
        let controller = AcceleratorController(env)
        controllerBox.withLock { $0 = controller }
        if case .disabled(let why) = controller.state { fallbackReason = .modelLoad; fallbackDetail = why }
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak controller] _ in
            controller?.memoryWarning()
        }
        #endif
        AcceleratorRegistry.add(registryID) { [weak self] in await self?.prepareAccelerator() }
        #if os(macOS)
        schedulePreparation(now: true)
        #endif
    }

    /// Whether the Neural Engine is considered at all. Never for a CPU-only context, even when it is asked for.
    static func mayUseAccelerator(requested: Backend, context: String) -> Bool {
        requested != .exact && !ModelContexts.isCPUOnly(context)
    }

    /// Starts the background preparation once: now (macOS, `awaitReady`), or after the first finished take (iOS).
    private func schedulePreparation(now: Bool) {
        guard !preparationScheduled, controllerBox.withLock({ $0 }) != nil else { return }
        preparationScheduled = true
        #if os(macOS)
        let priority = TaskPriority.utility
        #else
        let priority = now ? TaskPriority.utility : TaskPriority.background
        #endif
        Task.detached(priority: priority) { [weak self] in await self?.prepareAccelerator() }
    }

    /// The load (off the actor) and the self-test (on the actor, between takes).
    func prepareAccelerator() async {
        guard let controller = controllerBox.withLock({ $0 }), let build = model.coreML(context: settings.context) else { return }
        AcceleratorRegistry.remove(registryID)
        await controller.prepare(load: {
            guard #available(iOS 18.0, macOS 15.0, *) else { throw RecognizerError.neuralEngineUnavailable("the OS is too old") }
            let ne = try TajweedNeuralEngine(build)
            // the first prediction, so the on-device compile happens here and not in a take
            let warm = [Float](repeating: 0, count: 16_000)
            _ = try warm.withUnsafeBufferPointer { (p) throws(RecognizerError) in try ne.push(p) }
            ne.reset()
            return UncheckedBox(ne as any AcceleratorBackend)
        }, selfTest: { [weak self] box in
            guard let self else { return AcceleratorSelfTest(passed: false, reason: "the recognizer is gone") }
            return await self.runSelfTestSet(box)
        })
    }

    private func noteFallback(_ r: FallbackReason, _ detail: String) {
        fallbackReason = r
        fallbackDetail = detail
        QuranLab.record(.fallback(r, cohort: cohort))
    }

    /// Waits until no take is open (the self-test uses the CPU engine, which a take also uses).
    private func idle() async {
        while takeOpen { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    /// The self-test: the model folder's self-test set through the accelerator, compared with its expected outputs
    /// (the exact CPU engine's) at the default settings, and timed against the CPU engine on the same clips. Without a
    /// self-test set in the folder, the SDK's three bundled clips with the CPU engine's tokens as the reference.
    func runSelfTestSet(_ box: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorSelfTest {
        let candidate = box.value
        await idle()
        guard let exact else { return AcceleratorSelfTest(passed: false, reason: "no CPU engine") }
        let ctx = settings.context
        let chunkMs = exact.chunkMs
        var accTimes: [Double] = [], cpuTimes: [Double] = []
        var mismatch: String?
        defer { exact.reset(); candidate.reset() }
        func run(_ b: any AcceleratorBackend, _ s: [Float]) throws(RecognizerError) -> TajweedHeads {
            b.reset()
            var h = TajweedHeads()
            for c in try s.withUnsafeBufferPointer({ (p) throws(RecognizerError) in try b.push(p) }) { h.append(c) }
            for c in try b.finish() { h.append(c) }
            return h
        }
        func cpu(_ s: [Float]) throws(RecognizerError) -> [Int] {
            exact.reset()
            let t0 = CFAbsoluteTimeGetCurrent()
            let n = try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try exact.push(p) }.count + (try exact.finish()).count
            if n > 0 { cpuTimes += Array(repeating: (CFAbsoluteTimeGetCurrent() - t0) / Double(n), count: n) }
            return exact.take.greedy
        }
        do throws(RecognizerError) {
            if model.verifiedFiles.contains("selftest/selftest.json"), model.verifiedFiles.contains("selftest/expected_" + ctx + ".json"),
               let set = SelfTestSet.load(model.directory, context: ctx) {
                let defaults = try TajweedSettings.resolve(calibration: model.calibration, remote: nil, app: TajweedOptions(context: ctx),
                                                           debugBuild: false, backend: .fp32)
                for c in set.clips {
                    _ = try cpu(c.samples)
                    let h = try run(candidate, c.samples)
                    accTimes += candidate.chunkSeconds
                    let want = set.expected[c.id]!
                    if !h.isFinite { mismatch = mismatch ?? "\(c.id): a NaN or inf head"; continue }
                    if !c.planted && h.greedy != want.tokens {
                        mismatch = mismatch ?? SelfTestSet.compare(clip: c.id, expected: want, tokens: h.greedy, flaggedSites: [], flaggedWords: [])
                        continue
                    }
                    let r = try scorer.score(heads: h, TajweedScoreRequest(surah: c.surah, ayah: c.ayah, settings: defaults,
                                                                           options: TajweedOptions(context: ctx)))
                    let sites = Set(r.sites.filter(\.flagged).map { "\($0.position)|\($0.cls.rawValue)" })
                    let words = Set(r.words.filter { $0.flagged == true }.map(\.index))
                    mismatch = mismatch ?? SelfTestSet.compare(clip: c.id, planted: c.planted, expected: want, tokens: h.greedy, flaggedSites: sites,
                                                               flaggedWords: words)
                }
            } else {
                for c in try SelfTestClips.load().clips {
                    let ref = try cpu(c.samples)
                    let h = try run(candidate, c.samples)
                    accTimes += candidate.chunkSeconds
                    if !h.isFinite { mismatch = mismatch ?? "\(c.name): a NaN or inf head"; continue }
                    if h.greedy != ref { mismatch = mismatch ?? "\(c.name): tokens differ from the CPU engine" }
                }
            }
        } catch {
            mismatch = mismatch ?? "\(error)"
        }
        return SelfTestSet.judge(mismatch: mismatch, accelerator: accTimes, cpu: cpuTimes, chunkMs: chunkMs)
    }

    // MARK: takes

    /// A new take (one recitation session): builds the backends on first use, resets every cache and the kept heads,
    /// and starts sharing the session's audio when the learner agreed to share.
    public func startTake() throws(RecognizerError) {
        if takeOpen { endTake(completed: false) }
        try prepare()
        converter = nil
        take16k.removeAll(keepingCapacity: true)
        take = TajweedHeads()
        delivered = 0
        takeChunks = 0
        chunkSeconds.removeAll()
        takeAudioSeconds = 0
        feedError = nil
        exact?.reset()
        // promotion happens here only, at a take boundary, never during one
        if requested == .automatic, let c = controllerBox.withLock({ $0 }) { accel = c.backendForTake() }
        accel?.reset()
        activeBackend = accel == nil ? .exact : .neuralEngine
        settingsInForce = accel == nil ? settings : acceleratorSettings
        blankRun = 0
        takeOpen = true
        activity = SessionActivity()
        share = Contributions.capture(revision: model.identity, backend: activeBackend ?? .exact,
                                      weightsSHA256: model.manifest.files(role: "weights").first?.localSHA256)
        QuranLab.cloud?.analytics.markSessionOpen(cohort)
        QuranLab.cloud?.noteActivity()
    }

    /// The chunks of the current take as they complete (from `append` or the microphone), each with the selected
    /// heads; the stream ends when the take finishes. Call after `startTake`.
    public func chunks() -> AsyncStream<TajweedChunk> {
        let (s, c) = AsyncStream<TajweedChunk>.makeStream()
        stream?.finish()
        stream = c
        return s
    }

    /// Mono Float samples in -1...1 at 8 to 48 kHz. Returns each completed chunk's selected heads.
    @discardableResult
    public func append(_ samples: [Float], sampleRate: Double = 16_000) throws(RecognizerError) -> [TajweedChunk] {
        guard takeOpen else { throw .sessionClosed }
        if converter == nil || converter?.inputRate != sampleRate {
            if converter != nil {
                // one input rate per take: a change ends the shared session there
                share?.finish(completed: false)
                share = nil
            }
            converter = try SampleRateConverter(inputRate: sampleRate)
        }
        try share?.append(samples, rate: sampleRate)
        takeAudioSeconds += Double(samples.count) / sampleRate
        return try push(converter!.process(samples))
    }

    /// A PCM buffer (Float32 or Int16, any channel count, averaged to mono).
    @discardableResult
    public func append(_ buffer: AVAudioPCMBuffer) throws(RecognizerError) -> [TajweedChunk] {
        let (s, rate) = try AudioFormat.samples(from: buffer)
        return try append(s, sampleRate: rate)
    }

    /// For an audio tap: queues the buffer without waiting; order is kept. Chunks arrive on `chunks()`; an error
    /// surfaces at `finish`.
    public nonisolated func enqueue(_ buffer: AVAudioPCMBuffer) throws(RecognizerError) {
        var started: AsyncStream<UncheckedBox<AVAudioPCMBuffer>>?
        feed.withLock { c in
            if c == nil {
                let (s, cc) = AsyncStream<UncheckedBox<AVAudioPCMBuffer>>.makeStream()
                c = cc
                started = s
            }
            c?.yield(UncheckedBox(buffer))
        }
        enqueued.withLock { $0 += 1 }
        if let s = started { Task { await self.consume(s) } }
    }

    private nonisolated let enqueued = Locked(0)
    private var consumed = 0

    private func consume(_ s: AsyncStream<UncheckedBox<AVAudioPCMBuffer>>) async {
        let t = Task {
            for await b in s {
                self.appendQueued(b.value)
            }
        }
        feeder = t
        await t.value
        feeder = nil
    }

    private func appendQueued(_ b: AVAudioPCMBuffer) {
        consumed += 1
        guard takeOpen, feedError == nil else { return }
        do throws(RecognizerError) { _ = try append(b) } catch { feedError = error }
    }

    /// Waits until every queued buffer went in.
    private func drainFeed() async {
        let c = feed.withLock { c -> AsyncStream<UncheckedBox<AVAudioPCMBuffer>>.Continuation? in
            defer { c = nil }
            return c
        }
        c?.finish()
        while consumed < enqueued.withLock({ $0 }) {
            if let f = feeder { await f.value } else { await Task.yield() }
        }
    }

    /// The CPU engine's chunks for `s` (timed).
    private func raw(_ s: [Float]) throws(RecognizerError) -> [TajweedHeads] {
        guard let exact else { throw .sessionClosed }
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try exact.push(p) }
        if !out.isEmpty {
            let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(out.count)
            chunkSeconds += Array(repeating: dt, count: out.count)
        }
        return out
    }

    /// A Neural Engine fault mid-take: the take restarts on the CPU engine from its first sample (the CPU engine is the
    /// standby, already built), only the chunks not handed out yet are returned, and the CPU engine serves for the rest
    /// of the launch.
    private func handOver(_ reason: FallbackReason, _ detail: String, pending: [Float]) throws(RecognizerError) -> [TajweedHeads] {
        accel = nil
        activeBackend = .exact
        settingsInForce = settings
        if let c = controllerBox.withLock({ $0 }) { c.runtimeFault(reason, detail) } else { fixedState = .disabled(detail) }
        noteFallback(reason, detail)
        QuranLab.report(.neuralEngineUnavailable(detail), backend: .neuralEngine, revision: model.identity, kind: "fallback",
                        code: "fallback:" + reason.rawValue)
        guard let exact else { throw .sessionClosed }
        exact.reset()
        take = TajweedHeads()
        takeChunks = 0
        let all = take16k + pending
        return try all.withUnsafeBufferPointer { (p) throws(RecognizerError) in try exact.push(p) }
    }

    private func push(_ s: [Float]) throws(RecognizerError) -> [TajweedChunk] {
        let chunks = accel != nil ? try rawChecked(s) : try raw(s)
        take16k += s
        return deliver(chunks)
    }

    /// Chunks that are blank on every frame while the audio pushed with them has energy, in a row, before the take
    /// goes back to the CPU engine (about a second of speech the accelerator did not hear at all).
    static let blankChunksLimit = 3
    /// The RMS above which pushed audio counts as having energy (about -40 dBFS).
    static let energyRMS: Float = 0.01

    /// The accelerator's chunks, watched: an exception, a NaN or inf, a chunk over three times its audio, or
    /// `blankChunksLimit` all-blank chunks in a row with audio energy hand the take over to the CPU engine.
    private func rawChecked(_ s: [Float]) throws(RecognizerError) -> [TajweedHeads] {
        guard let ne = accel else { return try raw(s) }
        let before = ne.chunkSeconds.count
        let out: [TajweedHeads]
        do {
            out = try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try ne.push(p) }
        } catch {
            return try handOver(.other, "prediction failed: \(error)", pending: s)
        }
        let times = Array(ne.chunkSeconds.dropFirst(before))
        let budget = Double(exact?.chunkMs ?? 320) / 1000
        if out.contains(where: { !$0.isFinite }) { return try handOver(.nonFinite, "a head was NaN or infinite", pending: s) }
        if times.contains(where: { $0 > 3 * budget }) { return try handOver(.deadline, "a chunk took over three times its audio", pending: s) }
        if !out.isEmpty {
            let energy = s.isEmpty ? 0 : (s.reduce(Float(0)) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
            for c in out {
                let blank = c.greedy.isEmpty
                blankRun = blank && energy > Self.energyRMS ? blankRun + 1 : 0
            }
            if blankRun >= Self.blankChunksLimit {
                return try handOver(.other, "\(blankRun) chunks in a row heard nothing in audio with energy", pending: s)
            }
        }
        chunkSeconds += times
        return out
    }

    /// Chunks past the ones already handed out: kept in the take, the selected heads handed out. After a handover the
    /// CPU engine re-runs the take from its start, so its first chunks are kept but not handed out again.
    private func deliver(_ chunks: [TajweedHeads]) -> [TajweedChunk] {
        var out: [TajweedChunk] = []
        let keep = selection.heads.union(TajweedHead.scorer).union([.conf])
        let ms = exact?.chunkMs ?? 320
        for c in chunks {
            take.append(c.keeping(keep))
            let index = takeChunks
            takeChunks += 1
            if index >= delivered {
                let chunk = TajweedChunk(index: index, startMs: index * ms, heads: c.keeping(selection.heads))
                out.append(chunk)
                stream?.yield(chunk)
                delivered = index + 1
            }
        }
        if coldStart == nil, !out.isEmpty { coldStart = Date().timeIntervalSince(created) * 1000 }
        return out
    }

    private var takeChunks = 0
    private var coldStart: Double?

    /// The end of the take (the resampler's tail, the 1.05 s flush): every head of the take. The chunks the flush
    /// completes are in `lastChunks`.
    @discardableResult
    public func finish() async throws(RecognizerError) -> TajweedHeads {
        await drainFeed()
        guard takeOpen else { throw .sessionClosed }
        if let e = feedError { endTake(completed: false); throw e }
        var out: [TajweedChunk] = []
        do throws(RecognizerError) {
            if let tail = converter?.flush(), !tail.isEmpty { out += try push(tail) }
            var flushed: [TajweedHeads]
            if let ne = accel {
                do throws(RecognizerError) { flushed = try ne.finish() } catch { flushed = try handOver(.other, "\(error)", pending: []) + (try exact!.finish()) }
                if flushed.contains(where: { !$0.isFinite }) {
                    flushed = try handOver(.nonFinite, "a head was NaN or infinite", pending: []) + (try exact!.finish())
                }
            } else {
                guard let exact else { throw RecognizerError.sessionClosed }
                flushed = try exact.finish()
            }
            out += deliver(flushed)
        } catch {
            endTake(completed: false)
            throw error
        }
        lastChunks = out.map(\.heads)
        endTake(completed: true)
        return take
    }

    /// The chunks `finish` ran (the flush's).
    public private(set) var lastChunks: [TajweedHeads] = []

    private func endTake(completed: Bool) {
        guard takeOpen else { return }
        takeOpen = false
        stream?.finish()
        stream = nil
        share?.finish(completed: completed)
        share = nil
        activity?.end()
        activity = nil
        QuranLab.cloud?.analytics.markSessionClosed()
        let waiting = idleWaiters
        idleWaiters = []
        for w in waiting { w.resume() }
        // iOS: the Neural Engine is prepared after the first finished take, in the background
        if completed { schedulePreparation(now: false) }
        let first = Self.firstSessionOfLaunch.withLock { v -> Bool in defer { v = false }; return v }
        let checks = TajweedCheck.allCases.filter { c in
            switch c {
            case .madd: return settings.madd.enabled
            case .lazim: return settings.lazim.enabled
            case .gemination: return settings.gemination.enabled
            case .qalqalah: return settings.qalqalah.enabled
            default: return settings.sites.contains { TajweedClass(rawValue: $0.key)?.check == c && $0.value.enabled }
            }
        }.map(\.rawValue)
        QuranLab.record(.sessionFinished(SessionTelemetry(cohort: cohort, audioSeconds: takeAudioSeconds, chunkSeconds: chunkSeconds,
                                                          chunkAudioSeconds: Double(exact?.chunkMs ?? 320) / 1000, checksOn: checks,
                                                          throttled: false, thermalTransitions: 0,
                                                          coldStartMs: first ? coldStart : nil)))
    }

    /// Ends the take without results (the learner left); a shared session is kept only as far as it got.
    public func cancelTake() async {
        await drainFeed()
        endTake(completed: false)
    }

    // MARK: layers

    /// The heads of the take so far (the scorer's heads, `conf`, and the selected ones).
    public func heads() -> TajweedHeads { take }

    /// The decoded layer of the take so far: per frame top-1 and runner-up, the greedy tokens with confidence and
    /// margin, words and times.
    public func decoded() -> DecodedTake {
        // the CPU engine keeps the top-2 of the take as it runs; heads from the Neural Engine go through zf_tajweed_top2
        let frames = activeBackend == .exact ? exact?.top2() : nil
        var d = DecodedTake(heads: take, vocabulary: model.vocabulary, frames: frames)
        d.ranked = try? ranking(.logProbs, k: 2)
        return d
    }

    /// The decoded layer with log_probs ranked `topK` deep per frame (1 to 38; 38 is the whole ranked list).
    public func decoded(topK: Int) throws(RecognizerError) -> DecodedTake {
        var d = decoded()
        d.ranked = try ranking(.logProbs, k: topK)
        return d
    }

    /// Any head with a distribution ranked `k` deep per frame, over the take so far: the token heads (k 1 to 38) and
    /// the class heads (gem, attr_tafkheem, attr_ghunna, attr_qalqalah, attr_face; k up to their class count), with
    /// the token or class names. From the engine: the CPU stream's own ranking (`zf_tajweed_stream_topk`) on the CPU
    /// engine, `zf_tajweed_topk` on heads from the Neural Engine. The head must be in the take (the scorer's heads
    /// always are; select others with `HeadSelection`).
    public func ranking(_ head: TajweedHead, k: Int) throws(RecognizerError) -> TajweedRanking {
        let names = head.classNames(vocabulary: model.vocabulary)
        let frames = head.frameMs == 40 ? take.n40 : take.n20
        if activeBackend == .exact, let exact, let r = try exact.ranking(head, k: k, frames: frames, names: names) { return r }
        return try TajweedRanking.rank(take[head], head: head, k: k, names: names)
    }

    /// Scores the take (after `finish`) as a recitation of surah:ayah with the settings in force: per-site verdicts,
    /// madd counts, qalqalah and gemination evidence and the per-word scores and flags.
    public func score(surah: Int, ayah: Int) throws(RecognizerError) -> TajweedResult {
        let r = try scorer.score(heads: take, TajweedScoreRequest(surah: surah, ayah: ayah, settings: settingsInForce, options: options,
                                                                  remote: remote, debugBuild: debugBuild))
        var t = ScoreTelemetry(cohort: cohort, surah: surah)
        for s in r.sites where s.status != .off {
            var x = t.classes[s.cls.rawValue] ?? .init()
            x.sites += 1
            if s.flagged { x.flagged += 1 }
            t.classes[s.cls.rawValue] = x
        }
        for m in r.madd where m.status != .off {
            t.maddCounts[m.count, default: 0] += 1
            if m.flagged { t.maddFlagged += 1 }
        }
        t.wordsScored = r.words.filter { $0.flagged != nil }.count
        t.wordsFlagged = r.words.filter { $0.flagged == true }.count
        let d = decoded()
        t.margins = d.tokens.map(\.margin)
        t.confidences = d.tokens.compactMap(\.confidence)
        QuranLab.record(.scored(t))
        return r
    }

    /// Tells the SDK the learner finished a session; `feedback` is true when they were shown the model's feedback
    /// for it. This is the moment the SDK may ask about sharing recitations (never on first launch, at most twice
    /// more after "Not now", 7 sessions apart). Returns what the app should show, if anything (the SDK's own sheet
    /// does this on a view with `.quranLabSharing()`).
    @discardableResult
    public func endSession(feedback: Bool) -> SharingMoment? {
        Contributions.sessionCompleted(feedback: feedback)
    }
}
