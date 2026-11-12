@preconcurrency import AVFoundation
import CoreML
import Foundation
import os
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Something a rate adapter feeds converted buffers to, in order, without waiting (it must not queue them without a
/// bound).
protocol AudioBufferSink: Sendable {
    func enqueue(_ buffer: AVAudioPCMBuffer) throws(RecognizerError)
}

/// The engine behind a Model's Sessions (SDK 3.0.0: internal; the public types are `TajweedModel` and
/// `TajweedSession`): streams a take, keeps the selected heads, and decodes them. Inference only: nothing here
/// compares a take with a text.
///
///     let r = try TajweedRecognizer(model: folder)                    // a verified model folder
///     try await r.startTake()
///     let chunks = try await r.append(samples, sampleRate: 48_000)    // each chunk's selected heads (raw layer)
///     try await r.finish()
///     let heard = await r.decoded()                                   // decoded layer: tokens, margins, confidence
///
/// Backends, CPU first: the exact CPU engine serves from the first take, always. With `.automatic` (the default)
/// the Neural Engine is promoted in the background (`AcceleratorController`: its files downloaded after the first
/// session, compiled, warmed, golden-tested on raw outputs against the CPU engine with the model folder's self-test
/// set); once it is ready (`acceleratorState == .ready`), takes from the next one on run on it. A chunk that fails on
/// the Neural Engine (an exception, a NaN or inf, a head out of range, a missed deadline) switches the take to the CPU
/// engine at that chunk: the take's recent audio is replayed through it, the chunks already handed out stay, the take
/// continues, and the app gets no error (`activeBackend` and `fallbackReason` say what happened). Chunks that hear
/// nothing in audio with energy (normal in a long madd or a held vowel) are checked against the CPU engine off the
/// audio path; only a confirmed disagreement switches, and the chunk stream then hands out the CPU's chunks again
/// from the first one in question (the same `index`). What happens to the build depends on the cause
/// (`AcceleratorController.failedOver`).
///
/// The context: the caller's choice, else the signed config's `inference.context` when the model has it, else the
/// manifest's default.
actor TajweedRecognizer {
    enum Backend: String, Sendable {
        /// The exact CPU engine first; the Neural Engine once it is promoted (downloaded, compiled, golden-tested).
        case automatic
        /// Tests and measurements only: the Neural Engine at once, without the pipeline; throws where it cannot load
        /// (the build must be in the folder). A context no build of the model serves (`ModelManifest.serving`) stays on
        /// the exact CPU engine.
        case neuralEngine
        /// The exact CPU engine only.
        case exact
    }

    let model: ModelFolder
    /// The context running.
    nonisolated let context: String
    /// The heads handed out per chunk.
    nonisolated let selection: HeadSelection
    /// The CoreML build this recognizer fetches, promotes and runs: the fp16 one (`coreml`), or the compact one
    /// (`coreml-compact`) when the app named it. The other build is never tried in its place, also not after this one
    /// was demoted.
    nonisolated let compact: Bool
    /// That build's key, as the manifest, the promotion's record and the Backend name it.
    nonisolated var buildKey: String { compact ? "coreml-compact" : "coreml" }
    private(set) var activeBackend: ActiveBackend?
    /// Why the recognizer is on the CPU engine although the Neural Engine was possible, when it is.
    private(set) var fallbackReason: FallbackReason?
    private(set) var fallbackDetail: String?
    /// The switch to the CPU engine in the current (or last) take, when there was one.
    var lastFailover: TakeRunner.Failover?

    private let requested: Backend
    private var runner: TakeRunner?
    private nonisolated let controllerBox = Locked<AcceleratorController?>(nil)
    /// The model as the pipeline sees it (the accelerator's files counted once its download verified them).
    private nonisolated let acceleratorModel: Locked<ModelFolder>
    private var forced: AcceleratorExecutor?
    private var leased = false
    private var fixedState: AcceleratorState = .cpu
    private var pipelineStarted = false
    private let registryID = UUID()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var converter: SampleRateConverter?
    private var delivered = 0
    /// Chunks handed out at least once in this take (above `delivered` after a re-delivery).
    private var handedOut = 0
    /// The current take's id (deadline misses are counted per session).
    private var takeID = ""
    var take = HeadsBuffer()
    var takeChunkFrames: [Int] = []
    private var takeAudioSeconds = 0.0
    /// The take's input audio in whole milliseconds: floor(1000 * samples / rate), per input rate of the take.
    private var takeAudioMs = 0
    private var takeSamples: [Int: Int] = [:]
    private var takeOpen = false
    /// Counts takes: the golden test stops when a take ran between two of its steps.
    private var takeGeneration = 0
    /// This take in the process's sharing recorder (2.0.3: the recording outlives the take, so that the next take in a
    /// row continues it; `Contributions.recorder`).
    private var shareTake: Int?
    private var activity: SessionActivity?
    private var stream: AsyncStream<RawChunk>.Continuation?
    private let created = Date()
    private static let firstSessionOfLaunch = Locked(true)

    /// - Parameters:
    ///   - context: the context to run; nil takes the config's, else the manifest's default.
    ///   - heads: the heads handed out per chunk (`.default`, `.all`, or a set).
    ///   - backend: `.automatic` (CPU first, then the Neural Engine once promoted) or `.exact`.
    ///   - compact: the CoreML build `.automatic` promotes: true the compact one (a Session that names it), false the
    ///     fp16 one; nil, when no build is named, the fp16 one (see `unnamedBuildIsCompact`).
    init(model: ModelFolder, context: String? = nil, backend: Backend = .automatic,
         heads: HeadSelection = .default, compact: Bool? = nil) throws(RecognizerError) {
        self.model = model
        self.requested = backend
        acceleratorModel = Locked(model)
        let ctx = try RemoteConfig.context(app: context, config: QuranLab.cloud?.currentConfig, contexts: model.manifest.contexts,
                                           defaultContext: model.manifest.defaultContext)
        self.context = ctx
        let build = compact ?? Self.unnamedBuildIsCompact(model: model, context: ctx)
        self.compact = build
        guard model.isUsable(context: ctx) else {
            throw .modelMissing("the CPU files of \(ctx) are not in the model folder (ModelFolder.load(context:) fetches them)")
        }
        self.selection = heads
        // a build promoted in an earlier launch is loaded and warmed now, in the background, so the first session
        // normally starts on it (it never waits for it); nothing else starts before a session
        if Self.promotedEarlier(model: model, context: ctx, requested: backend, compact: build) {
            Task.detached(priority: .utility) { [weak self] in await self?.warmPromoted() }
        }
    }

    /// Whether a recognizer runs the compact build when the app names no build. It does not: the build is the fp16
    /// one, as in 2.x. One case apart, also as in 2.x: a folder that holds only the compact build, where no build can
    /// be downloaded (a folder the app opened itself, or an install that may not fetch CoreML files), runs that one.
    static func unnamedBuildIsCompact(model: ModelFolder, context: String) -> Bool {
        let downloadable = QuranLab.cloud.map { $0.updater.coreML } ?? false
        guard !downloadable else { return false }
        return model.coreML(context: context, compact: false) == nil && model.coreML(context: context, compact: true) != nil
    }
    /// Whether this model, context and device have a build promoted in an earlier launch (the persisted verdict).
    static func promotedEarlier(model: ModelFolder, context: String, requested: Backend, compact: Bool = false) -> Bool {
        guard requested == .automatic, mayUseAccelerator(requested: requested, model: model, context: context), DownloadProfile.osRunsCoreML,
              model.coreML(context: context, compact: compact) != nil else { return false }
        let key = AcceleratorController.key(revision: model.identity, context: context, build: compact ? "coreml-compact" : "coreml")
        let store = PromotionStore(dir: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"))
        return store.record(key)?.status == .ready
    }

    /// The take runner and the promotion, without opening the CPU engine (a take that runs on the CPU opens it).
    private func warmPromoted() {
        makeRunner()
        try? setUpAccelerator()
    }

    deinit { AcceleratorRegistry.remove(registryID) }

    /// Tests only: a CPU engine in place of the exact engine (given the context), and the promotion's stages in place
    /// of the CoreML ones, so the recognizer's order and failover run without the model.
    // (untyped throws: a typed-throws function type as a generic argument needs iOS 18 / macOS 15 at run time)
    static let cpuEngineOverride = Locked<(@Sendable (String) throws -> any CPUStreamEngine)?>(nil)
    static let stagesOverride = Locked<(@Sendable (TajweedRecognizer) -> AcceleratorController.Stages)?>(nil)

    // MARK: backends

    /// The telemetry cohort of this recognizer now: the model version and build, the context, the backend that runs.
    var cohort: TelemetryCohort {
        TelemetryCohort(revision: model.version, build: model.build, context: context, backend: (activeBackend ?? .exact).telemetryName)
    }

    /// The exact CPU engine when it is open (it is closed while the Neural Engine serves a take).
    var exact: TajweedExactEngine? { runner?.cpu as? TajweedExactEngine }

    /// Where the Neural Engine stands.
    var acceleratorState: AcceleratorState { controllerBox.withLock { $0 }?.state ?? fixedState }

    /// Every change of the Neural Engine's state, starting with the current one (`.cpu` alone when no accelerator
    /// applies).
    nonisolated func acceleratorStates() -> AsyncStream<AcceleratorState> {
        if let c = controllerBox.withLock({ $0 }) { return c.states() }
        let (s, c) = AsyncStream<AcceleratorState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        c.yield(.cpu)
        c.finish()
        return s
    }

    /// Starts the promotion now if it has not started, and waits until the Neural Engine is ready or will not be (up to
    /// `timeout`); true when the next take will run on it.
    func awaitReady(timeout: TimeInterval) async -> Bool {
        guard let c = controllerBox.withLock({ $0 }) else { return forced != nil }
        if c.state != .ready { startPipeline(priority: .utility) }
        // give the run a moment to leave .cpu
        for _ in 0..<50 where c.state == .cpu && c.record?.status != .failed {
            if c.isRunning { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await c.awaitReady(timeout: timeout)
    }

    /// What the golden test found for this model revision, OS build and device, once it ran.
    var acceleratorSelfTest: AcceleratorSelfTest? { controllerBox.withLock { $0 }?.lastSelfTest }

    /// The controller of the Neural Engine's promotion (nil where it does not apply).
    var acceleratorController: AcceleratorController? { controllerBox.withLock { $0 } }

    /// Builds the CPU engine now (otherwise the first `startTake` does), and sets up the Neural Engine's promotion where
    /// it applies.
    func prepare() throws(RecognizerError) {
        let t0 = Date()
        let opened = runner?.cpu == nil
        try makeRunner().ensureCPU()
        if opened {
            QuranLab.record(.modelLoaded(revision: model.version, milliseconds: Date().timeIntervalSince(t0) * 1000, cohort: cohort))
        }
        try setUpAccelerator()
    }

    /// The chunk of a context, ms (`c<frames>_l<left>`, frames of 20 ms): 320 at c16_l64.
    static func chunkMs(context: String) -> Int {
        let parts = String(context.dropFirst()).components(separatedBy: "_l")
        return (parts.first.flatMap { Int($0) } ?? 16) * 20
    }

    /// The take runner; the CPU engine is opened by the first take that needs it.
    @discardableResult
    private func makeRunner() -> TakeRunner {
        if let runner { return runner }
        let ctx = context
        let dir = model.directory
        // only the heads this recognizer hands out or keeps (log_probs and conf for the decoded layer, the timing
        // head for speech and silence)
        let mask = HeadSelection(selection.heads.union(HeadID.kept)).engineMask
        let override = Self.cpuEngineOverride.withLock { $0 }
        let open = { () throws(RecognizerError) -> any CPUStreamEngine in
            if let override {
                do { return try override(ctx) } catch { throw (error as? RecognizerError) ?? .engineFailed(code: -1, message: "\(error)") }
            }
            let e = try TajweedExactEngine(directory: dir, context: ctx)
            e.setHeads(mask)
            return e
        }
        let r = TakeRunner(chunkMs: Self.chunkMs(context: ctx), openCPU: open)
        runner = r
        activeBackend = .exact
        return r
    }

    private var acceleratorSetUp = false

    /// Sets up the Neural Engine's promotion where it applies (once).
    private func setUpAccelerator() throws(RecognizerError) {
        guard !acceleratorSetUp else { return }
        acceleratorSetUp = true
        let ctx = context
        guard Self.mayUseAccelerator(requested: requested, model: model, context: ctx) else { return }
        guard DownloadProfile.osRunsCoreML else {
            if requested == .neuralEngine { throw .neuralEngineUnavailable("the V4 CoreML package needs iOS 18 or macOS 15") }
            if model.manifest.files.contains(where: { DownloadProfile.packageRoles.contains($0.role) }) {
                fixedState = .disabled("the OS is older than iOS 18 / macOS 15")
                noteFallback(.aneUnavailable, "the OS is older than iOS 18 / macOS 15")
            }
            return
        }
        let downloadable = QuranLab.cloud.map { $0.updater.coreML } ?? false
        // this recognizer's build, when it is on disk. The other build is not tried in its place: a device gets the
        // fp16 build, and the compact one only when an app names it
        let present = model.coreML(context: ctx, compact: compact)
        if requested == .neuralEngine {
            // debug builds: a build in the folder at once, without the pipeline
            guard let build = model.coreML(context: ctx) else {
                throw .neuralEngineUnavailable(model.coreMLProblem ?? "the folder has no CoreML package for \(ctx)")
            }
            guard #available(iOS 18.0, macOS 15.0, *) else { return }
            forced = AcceleratorExecutor(try TajweedNeuralEngine(build))
            fixedState = .ready
            return
        }
        // the promotion applies when the folder has the build, or lists it and this install may download it
        let listed = !DownloadProfile(context: ctx, coreML: true, compact: compact).appleFiles(model.manifest).isEmpty
        guard present != nil || (downloadable && listed) else {
            if let p = model.coreMLProblem {
                fixedState = .disabled(p)
                noteFallback(.modelLoad, p)
            }
            return
        }
        let identity = model.identity
        let version = model.version
        let cohortNow = cohort
        let env = AcceleratorController.Environment(
            revision: identity, version: version, context: ctx, build: buildKey,
            storage: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"),
            denied: { QuranLab.cloud?.acceleratorDenied(revision: version.isEmpty ? identity : version) },
            record: { QuranLab.record($0) },
            // kept on the device even without a Quran Lab client (sent once one is configured with a key)
            incident: { QuranLab.reportIncident($0) },
            cohort: { cohortNow })
        let controller = AcceleratorController.shared(env)
        controllerBox.withLock { $0 = controller }
        if case .disabled(let why) = controller.state { fallbackReason = .modelLoad; fallbackDetail = why }
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak controller] _ in
            controller?.memoryWarning()
        }
        #endif
        AcceleratorRegistry.add(registryID) { [weak self] in await self?.runPipeline() }
        if controller.record?.status == .ready {
            // promoted in an earlier launch: load and warm it now, so the first session normally starts on it
            startPipeline(priority: .utility)
        } else if controller.record != nil {
            // a key seen in an earlier launch: at launch, at low priority (the CPU engine serves until it is warm)
            startPipeline(priority: .background)
        } else {
            // a first run: after the first session ends, or after a short idle delay, whichever comes first
            let delay = PromotionPolicy.idleStartDelay
            Task.detached(priority: .background) { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                await self?.idleDelayPassed()
            }
        }
    }

    /// Whether the Neural Engine is considered at all for `context`: never for the exact backend, and only where the
    /// model's manifest has an accelerator build serve the context (SPEC 5.4: a signed tolerance under
    /// `<build>:<context>`, or a keep table listed for it). A context no build serves runs on the CPU engine, even
    /// when the Neural Engine is asked for.
    /// Tried before (to 3.0.1): the SDK's own list of CPU-only contexts (`c8_l64`) answered this, whatever the
    /// manifest listed.
    static func mayUseAccelerator(requested: Backend, model: ModelFolder, context: String) -> Bool {
        requested != .exact && DownloadProfile.packageRoles.contains { model.manifest.serving(build: $0, context: context) != nil }
    }

    private func idleDelayPassed() {
        // a session running now starts the pipeline when it ends
        guard !pipelineStarted, !takeOpen else { return }
        startPipeline(priority: .background)
    }

    /// Runs the pipeline in the background (it returns at once when it is running, ready, failed or waiting).
    private func startPipeline(priority: TaskPriority) {
        guard controllerBox.withLock({ $0 }) != nil else { return }
        pipelineStarted = true
        Task.detached(priority: priority) { [weak self] in await self?.runPipeline() }
    }

    func runPipeline() async {
        guard let c = controllerBox.withLock({ $0 }) else { return }
        await c.run(Self.stagesOverride.withLock { $0 }.map { $0(self) } ?? makeStages())
    }

    private func noteFallback(_ r: FallbackReason, _ detail: String) {
        fallbackReason = r
        fallbackDetail = detail
        QuranLab.record(.fallback(r, cohort: cohort))
    }

    /// Waits until no take is open.
    private func idle() async {
        while takeOpen { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    private func isTakeOpen() -> Bool { takeOpen }

    // MARK: the pipeline's stages

    /// The work of each stage for this recognizer's model and context.
    nonisolated func makeStages() -> AcceleratorController.Stages {
        let ctx = context
        let box = acceleratorModel
        let compact = self.compact
        return AcceleratorController.Stages(
            download: { () async throws(PromotionFailure) -> Void in
                let m = box.withLock { $0 }
                // this recognizer's build and no other
                if m.coreML(context: ctx, compact: compact) != nil { return }
                guard let cloud = QuranLab.cloud else { throw PromotionFailure(.network, "no Quran Lab cloud to download the CoreML build from") }
                do throws(RecognizerError) {
                    _ = try await cloud.updater.installAccelerator(m, context: ctx, compact: compact)
                } catch {
                    throw Self.downloadFailure(error)
                }
                let profile = DownloadProfile(context: ctx, coreML: true, compact: compact)
                let updated = m.adding(verified: profile.appleFiles(m.manifest).map(\.localPath),
                                       removing: profile.otherBuildFiles(m.manifest).map(\.localPath))
                guard updated.coreML(context: ctx, compact: compact) != nil else {
                    throw PromotionFailure(.verify, updated.coreMLProblem ?? "the downloaded CoreML build is not usable")
                }
                box.withLock { $0 = updated }
            },
            compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                let m = box.withLock { $0 }
                guard let build = m.coreML(context: ctx, compact: compact) else { throw PromotionFailure(.compileError, "no CoreML build for \(ctx)") }
                guard #available(iOS 18.0, macOS 15.0, *) else { throw PromotionFailure(.compileError, "the OS is too old") }
                do throws(RecognizerError) {
                    return UncheckedBox(try TajweedNeuralEngine(build) as any AcceleratorBackend)
                } catch {
                    throw PromotionFailure(.compileError, "\(error)")
                }
            },
            warmup: { (b: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in
                let m = box.withLock { $0 }
                try Self.warmUp(b.value, model: m, context: ctx)
            },
            golden: { [weak self] (b: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                guard let self else { return .aborted }
                return await self.golden(b)
            },
            sessionActive: { [weak self] () async -> Bool in await self?.isTakeOpen() ?? false },
            waitIdle: { [weak self] () async -> Void in
                await self?.idle()
                // let a session that is about to start get the CPU engine first
                try? await Task.sleep(nanoseconds: 200_000_000)
            },
            fingerprint: { () -> String? in Self.programFingerprint(box.withLock { $0 }, context: ctx, compact: compact) })
    }

    /// The SHA-256 of the build's program on disk (the manifest's, checked when the folder was opened or the install
    /// verified it), or "gone".
    static func programFingerprint(_ m: ModelFolder, context: String, compact: Bool = false) -> String {
        guard m.coreML(context: context, compact: compact) != nil else { return "gone" }
        let role = compact ? "coreml-compact" : "coreml"
        return m.manifest.files(role: role).first { $0.localPath.hasSuffix("/weights/weight.bin") }?.localSHA256 ?? "gone"
    }

    /// Debug builds only: a line for the developer (os.Logger, notice).
    static func debugLog(_ line: String) {
        #if DEBUG
        Logger(subsystem: "ai.quranlab.sdk", category: "accelerator").notice("\(line, privacy: .public)")
        #endif
    }

    static func downloadFailure(_ e: RecognizerError) -> PromotionFailure {
        switch e {
        case .offline: return PromotionFailure(.network, "\(e)")
        case .insufficientStorage, .storageFailed: return PromotionFailure(.storage, "\(e)")
        case .checksumMismatch, .signatureInvalid, .manifestInvalid: return PromotionFailure(.verify, "\(e)")
        default: return PromotionFailure(.other, "\(e)")
        }
    }

    /// The warm-up: one second of silence and the first self-test clip through the build, every chunk checked.
    static func warmUp(_ b: any AcceleratorBackend, model: ModelFolder, context: String) throws(PromotionFailure) {
        var clip: [Float] = []
        if model.verifiedFiles.contains("selftest/selftest.json"), let set = SelfTestSet.load(model.directory, context: context) {
            clip = set.clips.first?.samples ?? []
        } else if let c = try? SelfTestClips.load().clips.first {
            clip = c.samples
        }
        b.reset()
        defer { b.reset() }
        var out: [HeadsBuffer] = []
        do throws(RecognizerError) {
            out += try [Float](repeating: 0, count: 16_000).withUnsafeBufferPointer { (p) throws(RecognizerError) in try b.push(p) }
            b.reset()
            out += try clip.withUnsafeBufferPointer { (p) throws(RecognizerError) in try b.push(p) }
            out += try b.finish()
        } catch {
            let ns = b.lastError
            throw PromotionFailure(.loadError, "\(error)", errorDomain: ns?.domain, errorCode: ns.map { String($0.code) })
        }
        for c in out {
            if let bad = HeadsCheck.check(c) { throw PromotionFailure(.nonFinite, "warm-up: \(bad.1)") }
        }
    }

    /// The golden test, on raw outputs (SDK 3.0.0): every self-test clip through the build and through the CPU engine,
    /// the same streaming code a session uses (pieces of one chunk, then the flush), and the two runs' heads compared
    /// by `GoldenRaw`: token edits and log-prob distances per CTC head, the mean probability difference of the
    /// attribute heads, within the build's tolerance from the signed manifest (tokens only where it gives none). The
    /// CPU's tokens must equal the shipped expected tokens (else `cpu_mismatch`); any NaN, inf or head out of range is
    /// `non_finite`. Between pieces the actor is free: a take that starts stops the test (`aborted`, no failure).
    func golden(_ b: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome {
        guard !takeOpen, let runner else { return .aborted }
        let generation = takeGeneration
        let m = acceleratorModel.withLock { $0 }
        let ctx = context
        let piece = runner.chunkSamples
        let exec = AcceleratorExecutor(b.value, label: "ai.quranlab.accelerator.golden")
        let acc = TakeRunner(chunkMs: runner.chunkMs, openCPU: { () throws(RecognizerError) -> any CPUStreamEngine in
            throw RecognizerError.neuralEngineUnavailable("no CPU engine in the golden test's accelerator run")
        })
        acc.failoverEnabled = false
        var accTimes: [Double] = [], cpuTimes: [Double] = []
        let set: SelfTestSet? = m.verifiedFiles.contains("selftest/selftest.json") && m.verifiedFiles.contains("selftest/expected_\(ctx).json")
            ? SelfTestSet.load(m.directory, context: ctx) : nil
        struct Clip { let id: String; let samples: [Float]; let planted: Bool; let expected: [Int]? }
        var clips: [Clip] = []
        if let set {
            clips = set.clips.map { Clip(id: $0.id, samples: $0.samples, planted: $0.planted, expected: set.expected[$0.id]) }
        } else if let bundled = try? SelfTestClips.load() {
            clips = bundled.clips.map { Clip(id: $0.name, samples: $0.samples, planted: false, expected: nil) }
        }
        guard !clips.isEmpty else { return .failed(PromotionFailure(.other, "no self-test clips")) }
        // the entry in force for this build in this context: `<build>:<context>`, or the plain `<build>` of a context
        // served by its keep table (SPEC 5.4); none: identical tokens decide
        let tolerance = m.manifest.rawTolerance(build: buildKey, context: context)
        // the CPU run computes every head the test compares, whatever the Session selected; the selection is put
        // back when the test ends, before the next take
        let session = HeadSelection(selection.heads.union(HeadID.kept)).engineMask
        func restore() { (runner.cpu as? TajweedExactEngine)?.setHeads(session) }
        var results: [GoldenRaw.Clip] = []
        for c in clips {
            // the CPU engine
            let cpu: any CPUStreamEngine
            do throws(RecognizerError) { cpu = try runner.ensureCPU() } catch { return .failed(PromotionFailure(.other, "the CPU engine: \(error)")) }
            cpu.reset()
            (cpu as? TajweedExactEngine)?.setHeads(HeadSelection.all.engineMask)
            var cpuHeads = HeadsBuffer()
            var at = 0
            repeat {
                await Task.yield()
                if takeOpen || takeGeneration != generation { cpu.reset(); restore(); return .aborted }
                let s = Array(c.samples[at..<min(c.samples.count, at + piece)])
                let t0 = CFAbsoluteTimeGetCurrent()
                let out: [HeadsBuffer]
                do throws(RecognizerError) {
                    out = try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try cpu.push(p) }
                } catch {
                    restore()
                    return .failed(PromotionFailure(.cpuMismatch, "\(c.id): the CPU engine failed: \(error)", clip: c.id))
                }
                if !out.isEmpty { cpuTimes += Array(repeating: (CFAbsoluteTimeGetCurrent() - t0) / Double(out.count), count: out.count) }
                for h in out { cpuHeads.append(h) }
                at += piece
            } while at < c.samples.count
            do throws(RecognizerError) { for h in try cpu.finish() { cpuHeads.append(h) } } catch {
                restore()
                return .failed(PromotionFailure(.cpuMismatch, "\(c.id): the CPU engine failed: \(error)", clip: c.id))
            }
            cpu.reset()
            restore()
            // the accelerator
            do throws(RecognizerError) { try acc.start(accelerator: exec) } catch { return .failed(PromotionFailure(.hang, "\(error)")) }
            guard acc.onAccelerator else { return .failed(PromotionFailure(.hang, "the accelerator was abandoned after a missed deadline")) }
            var accHeads = HeadsBuffer()
            at = 0
            do throws(RecognizerError) {
                repeat {
                    await Task.yield()
                    if takeOpen || takeGeneration != generation { return .aborted }
                    let s = Array(c.samples[at..<min(c.samples.count, at + piece)])
                    for h in try acc.push(s).chunks { accHeads.append(h) }
                    at += piece
                } while at < c.samples.count
                for h in try acc.finish().chunks { accHeads.append(h) }
            } catch {
                let cause = acc.detected?.cause
                let reason: PromotionReason = cause == .deadline ? .hang : (cause == .nonFinite || cause == .outOfRange) ? .nonFinite : .other
                let ns = b.value.lastError
                return .failed(PromotionFailure(reason, "\(c.id): \(acc.detected?.detail ?? "\(error)")", errorDomain: ns?.domain,
                                                errorCode: ns.map { String($0.code) }, clip: c.id))
            }
            // warm chunks only: each clip's first chunk is a take's first (cold) chunk
            accTimes += acc.takeWarmMs.map { $0 / 1000 }
            results.append(GoldenRaw.Clip(id: c.id, clean: !c.planted, expectedTokens: c.expected, cpu: GoldenRaw.heads(cpuHeads),
                                          accelerator: GoldenRaw.heads(accHeads)))
        }
        exec.reset(wait: true)
        return Self.goldenOutcome(results, tolerance: tolerance, accelerator: accTimes, cpu: cpuTimes, label: "\(buildKey) \(ctx)")
    }

    /// The golden stage's outcome for what the two engines gave on the self-test clips: judged by the build's
    /// tolerance from the signed manifest (`golden_raw_tolerance`: token edits, `lp_mean` and `lp_p99` per CTC head,
    /// `p_mean` for the attribute heads), and on identical tokens when the manifest gives the build none. Inside:
    /// passed, with the measures and the tolerance they were judged by. Outside: `golden_mismatch`, with the same
    /// and the measures that decided it.
    static func goldenOutcome(_ results: [GoldenRaw.Clip], tolerance: GoldenRawTolerance?, accelerator accTimes: [Double],
                              cpu cpuTimes: [Double], label: String) -> AcceleratorController.GoldenOutcome {
        let verdict = GoldenRaw.evaluate(results, tolerance: tolerance)
        if let reason = verdict.reason {
            let why = reason == .cpuMismatch
                ? "the CPU engine's tokens differ from the expected ones on \(verdict.cpuMismatchClip ?? "a clip")"
                : (tolerance == nil ? "the tokens differ from the CPU engine's (this build has no tolerance): "
                                    : "out of tolerance against the CPU engine: ") + verdict.failed.joined(separator: ", ")
            return .failed(PromotionFailure(reason, why, clip: verdict.cpuMismatchClip, divergence: verdict.divergence(tolerance: tolerance)))
        }
        if let edits = verdict.ctc["log_probs"].flatMap({ $0 })?.tokenEdits, edits > 0 {
            Self.debugLog("golden test passed within its tolerance: \(edits) token edits against the CPU engine")
        }
        // the measures are kept whatever decided the verdict: a build without a tolerance is judged on its tokens, and
        // its distances are what the next build's tolerance is set from
        let measures = verdict.divergence(tolerance: tolerance).bounded
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let line = try? encoder.encode(measures) {
            Self.debugLog("golden test measures, \(label): " + String(decoding: line, as: UTF8.self))
        }
        return .passed(accelerator: accTimes, cpu: cpuTimes, measures: measures)
    }
    // MARK: takes

    /// A new take (one recitation session): builds the CPU engine on first use, picks the backend (the Neural Engine
    /// when it is promoted and warm, else the CPU engine; never decided during a take), resets every cache and the
    /// kept heads, and starts sharing the session's audio when the learner agreed to share (2.0.3: a take that starts
    /// within a few seconds of the previous one continues its shared recording).
    func startTake() throws(RecognizerError) {
        if takeOpen { endTake(completed: false) }
        let runner = makeRunner()
        try setUpAccelerator()
        takeGeneration += 1
        converter = nil
        take = HeadsBuffer()
        takeChunkFrames = []
        delivered = 0
        handedOut = 0
        takeAudioSeconds = 0
        takeAudioMs = 0
        takeSamples = [:]
        lastFailover = nil
        takeID = UUID().uuidString
        var exec: AcceleratorExecutor?
        if let f = forced, !f.abandoned {
            exec = f
        } else if requested == .automatic, let c = controllerBox.withLock({ $0 }), let e = c.leaseForSession() {
            exec = e
            leased = true
        }
        runner.policy = failoverPolicy()
        do throws(RecognizerError) { try runner.start(accelerator: exec) } catch {
            endLease()
            throw error
        }
        if exec != nil && !runner.onAccelerator { endLease() }
        activeBackend = runner.onAccelerator ? .neuralEngine : .exact
        takeOpen = true
        activity = SessionActivity()
        shareTake = Contributions.recorder.takeStarted(
            .init(revision: model.identity, version: model.version, backend: activeBackend ?? .exact,
                  weightsSHA256: model.manifest.files(role: "weights").first?.localSHA256))
        QuranLab.cloud?.analytics.markSessionOpen(cohort)
        QuranLab.cloud?.noteActivity()
    }

    /// The failover's numbers for this device: the limits from this key's warm chunk times, the CPU engine's chunk
    /// time and cold open (for the replay window), the caches' span of the context, and the build's golden tolerance
    /// (for a blank verification).
    private func failoverPolicy() -> TakeRunner.Policy {
        var p = TakeRunner.Policy()
        let c = controllerBox.withLock { $0 }
        if let l = c?.limits {
            p.deadlineMs = l.laterMs
            p.firstChunkMs = l.firstMs
            p.warmMs = l.warmMs
        }
        let m = acceleratorModel.withLock { $0 }
        // the build that runs: this recognizer's, or (a build forced in a debug build) the one in the folder
        let running = forced == nil ? buildKey : m.coreMLBuildKey(context: context)
        p.blankTokenTolerance = m.manifest.rawTolerance(build: running, context: context)?.heads["log_probs"]?.tokenEdits ?? 0
        if let m = c?.record?.cpuMedianMs, m > 0 { p.cpuChunkMs = m }
        if let o = runner?.lastOpenMs, o > 0 { p.cpuOpenMs = o }
        p.minReplayChunks = Self.cacheSpanChunks(context: context) + 1
        return p
    }

    /// Chunks that cover the streaming encoder's left context (`c<chunk>_l<left>`, frames of 20 ms): 4 at c16_l64
    /// (1.28 s of 320 ms chunks), 11 at c24_l256.
    static func cacheSpanChunks(context: String) -> Int {
        let parts = String(context.dropFirst()).components(separatedBy: "_l")
        guard parts.count == 2, let chunk = Int(parts[0]), let left = Int(parts[1]), chunk > 0 else { return 4 }
        return (left + chunk - 1) / chunk
    }

    private func endLease() {
        if leased { controllerBox.withLock { $0 }?.endLease() }
        leased = false
    }

    /// The most chunks that wait unread in a chunk stream.
    static let chunkBuffer = 32

    /// The chunks of the current take as they complete (from `append` or the microphone), each with the selected
    /// heads; the stream ends when the take finishes. Call after `startTake`. Since 2.0.2 a chunk can come again with
    /// the same `index` and `replaces == true` (the CPU engine's, after it confirmed that the Neural Engine missed
    /// speech there): replace that index and drop what you kept from it on; the later indexes follow in order.
    func chunks() -> AsyncStream<RawChunk> {
        // bounded: a reader that falls behind loses the oldest unread chunks, never the take (`finish` returns it whole)
        let (s, c) = AsyncStream<RawChunk>.makeStream(bufferingPolicy: .bufferingNewest(Self.chunkBuffer))
        stream?.finish()
        stream = c
        return s
    }

    /// Mono Float samples in -1...1 at 8 to 48 kHz. Returns each completed chunk's selected heads.
    @discardableResult
    func append(_ samples: [Float], sampleRate: Double = 16_000) throws(RecognizerError) -> [RawChunk] {
        guard takeOpen else { throw .sessionClosed }
        if converter == nil || converter?.inputRate != sampleRate {
            converter = try SampleRateConverter(inputRate: sampleRate)
        }
        // one input rate per take: the recorder ends the shared recording where the rate changes
        if let shareTake { try Contributions.recorder.audio(shareTake, samples, rate: sampleRate) }
        takeAudioSeconds += Double(samples.count) / sampleRate
        takeSamples[Int(sampleRate), default: 0] += samples.count
        takeAudioMs = takeSamples.reduce(0) { $0 + 1000 * $1.value / max(1, $1.key) }
        return try push(converter!.process(samples))
    }

    /// A PCM buffer (Float32 or Int16, any channel count, averaged to mono).
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) throws(RecognizerError) -> [RawChunk] {
        let (s, rate) = try AudioFormat.samples(from: buffer)
        return try append(s, sampleRate: rate)
    }

    /// 16 kHz samples through the take's backend; a failover inside is handled here and invisible to the caller.
    private func push(_ s: [Float]) throws(RecognizerError) -> [RawChunk] {
        guard let runner else { throw .sessionClosed }
        let out = try runner.push(s)
        let chunks = apply(out)
        noteFailover()
        return chunks
    }

    /// Applies what the runner added to the take: a truncation (a failover replaced chunks from there on), then the new
    /// chunks, handing out only those not handed out yet.
    private func apply(_ o: TakeRunner.Output) -> [RawChunk] {
        if let t = o.truncateTo, t < takeChunkFrames.count {
            take.truncate(n40: takeChunkFrames.prefix(t).reduce(0, +))
            takeChunkFrames.removeLast(takeChunkFrames.count - t)
        }
        // a confirmed blank disagreement: the CPU's chunks are handed out again from the first one in question
        if let r = o.redeliverFrom { delivered = min(delivered, max(0, r)) }
        return deliver(o.chunks)
    }

    /// After a failover in this take: the CPU engine from here on, the build's fate by the cause (a single deadline miss
    /// keeps it promoted), the counters, the incident report. The app gets no error.
    private func noteFailover() {
        guard let runner, let f = runner.failover, lastFailover == nil else { return }
        lastFailover = f
        activeBackend = .exact
        fallbackReason = f.cause == .nonFinite ? .nonFinite : f.cause == .deadline ? .deadline : .other
        fallbackDetail = f.detail
        if let c = controllerBox.withLock({ $0 }), leased {
            c.failedOver(f, session: takeID)
        } else if forced != nil {
            forced = nil
            fixedState = .disabled("failover: \(f.detail)")
            QuranLab.record(.fallback(fallbackReason!, cohort: cohort))
        }
    }

    /// Chunks past the ones already handed out: kept in the take, the selected heads handed out.
    private func deliver(_ chunks: [HeadsBuffer]) -> [RawChunk] {
        var out: [RawChunk] = []
        let keep = selection.heads.union(HeadID.kept)
        let ms = runner?.chunkMs ?? 320
        let blank = model.vocabulary.blank
        for c in chunks {
            take.append(c.keeping(keep))
            let index = takeChunkFrames.count
            takeChunkFrames.append(c.n40)
            if index >= delivered {
                // speech and silence are read from the engine's own chunk: the timing head is there whatever the
                // app selected
                let active = SpeechTracker.active(logProbs: c.top1(.logProbs), timing: c.top1(.timingLogProbs), blank: blank)
                let chunk = RawChunk(index: index, startMs: index * ms, heads: c.keeping(selection.heads), replaces: index < handedOut,
                                     active: active)
                out.append(chunk)
                stream?.yield(chunk)
                delivered = index + 1
                handedOut = max(handedOut, delivered)
            }
        }
        if coldStart == nil, !out.isEmpty { coldStart = Date().timeIntervalSince(created) * 1000 }
        return out
    }

    private var coldStart: Double?

    /// The end of the take (the resampler's tail, the 1.05 s flush): every head of the take. The chunks the flush
    /// completes are in `lastChunks`.
    @discardableResult
    func finish() async throws(RecognizerError) -> HeadsBuffer {
        guard takeOpen else { throw .sessionClosed }
        var out: [RawChunk] = []
        do throws(RecognizerError) {
            if let tail = converter?.flush(), !tail.isEmpty { out += try push(tail) }
            guard let runner else { throw RecognizerError.sessionClosed }
            out += apply(try runner.finish())
            noteFailover()
        } catch {
            endTake(completed: false)
            throw error
        }
        lastChunks = out.map(\.heads)
        lastFlush = out
        endTake(completed: true)
        return take
    }

    /// The end of a take at one of its chunks, without the flush (a take that ended on silence, SDK 3.0.0): the take's
    /// heads up to and including that chunk. What the engine ran after it is not part of the take.
    func finish(atChunk index: Int) -> HeadsBuffer {
        guard takeOpen else { return take }
        if index + 1 < takeChunkFrames.count {
            take.truncate(n40: takeChunkFrames.prefix(index + 1).reduce(0, +))
            takeChunkFrames.removeLast(takeChunkFrames.count - index - 1)
        }
        lastChunks = []
        lastFlush = []
        endTake(completed: true)
        return take
    }

    /// The chunks `finish` ran (the flush's).
    private(set) var lastChunks: [HeadsBuffer] = []
    /// The same chunks with their indexes (what a Session hands out as the take's last chunks).
    private(set) var lastFlush: [RawChunk] = []

    private func endTake(completed: Bool) {
        guard takeOpen else { return }
        takeOpen = false
        if let runner {
            // a cancelled take's verification stops; a session on the build adds its warm chunk times and counts the
            // blank suspicions the CPU engine confirmed as correct
            runner.dropVerification()
            if leased, let c = controllerBox.withLock({ $0 }) {
                c.sessionEnded(warmMs: runner.takeWarmMs, blankConfirmedOK: runner.blankConfirmedOK)
            }
        }
        endLease()
        stream?.finish()
        stream = nil
        // the shared recording stays open for the next take in a row (the join window), or closes
        if let shareTake { Contributions.recorder.takeEnded(shareTake, completed: completed) }
        shareTake = nil
        activity?.end()
        activity = nil
        QuranLab.cloud?.analytics.markSessionClosed()
        let waiting = idleWaiters
        idleWaiters = []
        for w in waiting { w.resume() }
        // the promotion: a first run starts after the first finished session; later, a waiting run resumes
        if completed, let c = controllerBox.withLock({ $0 }), c.state != .ready, !c.isRunning {
            startPipeline(priority: .background)
        }
        let first = Self.firstSessionOfLaunch.withLock { v -> Bool in defer { v = false }; return v }
        var t = SessionTelemetry(cohort: cohort, audioSeconds: takeAudioSeconds, chunkSeconds: runner?.chunkSeconds ?? [],
                                 chunkAudioSeconds: Double(runner?.chunkMs ?? 320) / 1000, coldStartMs: first ? coldStart : nil)
        t.counts = completed
        if completed {
            // what the model itself gave for this take: its audio, speech and silence frames (from log_probs and
            // the timing head, which the take keeps whatever was selected), the tokens of each selected CTC head, the
            // compute time, and the decoded tokens' margins and confidences
            let heads = take
            t.count(audioMs: takeAudioMs, selected: HeadID.ctc.filter { selection.contains($0) }.map(\.rawValue),
                    computeMicroseconds: (runner?.chunkSeconds ?? []).reduce(0) { $0 + Int(($1 * 1_000_000).rounded()) },
                    ids: { HeadID(rawValue: $0).map { heads.top1($0) } ?? [] })
            let d = decoded()
            t.margins = d.tokens.map(\.margin)
            t.confidences = d.tokens.compactMap(\.confidence)
        }
        QuranLab.record(.sessionFinished(t))
    }
    /// Ends the take without results (the learner left); a shared session is kept only as far as it got.
    func cancelTake() async {
        endTake(completed: false)
    }

    // MARK: layers

    /// Whether the CPU stream holds exactly this take's heads (it ran it all, or replayed all of it).
    private var cpuHoldsTake: Bool { activeBackend == .exact && (runner?.cpuHasWholeTake ?? false) }

    /// The heads of the take so far (the selected ones, with `log_probs` and `conf` for the decoded layer).
    func heads() -> HeadsBuffer { take }

    /// The decoded layer of the take so far: per frame top-1 and runner-up, the greedy tokens with confidence and
    /// margin, words and times.
    func decoded() -> DecodedTake {
        // the CPU engine keeps the top-2 of the take as it runs (when it ran the whole take); other heads go through
        // zf_tajweed_top2
        let frames = cpuHoldsTake ? exact?.top2() : nil
        var d = DecodedTake(heads: take, vocabulary: model.vocabulary, frames: frames)
        d.ranked = try? ranking(.logProbs, k: 2)
        return d
    }

    /// The decoded layer with log_probs ranked `topK` deep per frame (1 to 38; 38 is the whole ranked list).
    func decoded(topK: Int) throws(RecognizerError) -> DecodedTake {
        var d = decoded()
        d.ranked = try ranking(.logProbs, k: topK)
        return d
    }

    /// Any head with a distribution ranked `k` deep per frame, over the take so far: the token heads (k 1 to 38) and
    /// the class heads (gem, attr_tafkheem, attr_ghunna, attr_qalqalah, attr_face; k up to their class count), with
    /// the token or class names. From the engine: the CPU stream's own ranking (`zf_tajweed_stream_topk`) on the CPU
    /// engine, `zf_tajweed_topk` on heads from the Neural Engine. The head must be in the take (`log_probs`
    /// always is; select others with `HeadSelection`).
    func ranking(_ head: HeadID, k: Int) throws(RecognizerError) -> TajweedRanking {
        let names = head.classNames(vocabulary: model.vocabulary)
        let frames = head.frameMs == 40 ? take.n40 : take.n20
        if cpuHoldsTake, let exact, let r = try exact.ranking(head, k: k, frames: frames, names: names) { return r }
        return try TajweedRanking.rank(take[head], head: head, k: k, names: names)
    }
}
