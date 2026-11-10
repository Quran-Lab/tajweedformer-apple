@preconcurrency import AVFoundation
import CoreML
import Foundation
import os
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
///     let model = try await TajweedModel.load()                      // this device's CPU set, verified
///     let r = try TajweedRecognizer(model: model, options: TajweedOptions(preset: .balanced, word: .general))
///     try await r.startTake()
///     let chunks = try await r.append(samples, sampleRate: 48_000)    // each chunk's selected heads (raw layer)
///     try await r.finish()
///     let heard = await r.decoded()                                   // decoded layer: tokens, margins, confidence
///     let result = try await r.score(surah: 1, ayah: 2)               // tajweed layer: sites, madd, words
///     await r.endSession(feedback: true)                              // lets the SDK ask about sharing, at the right moment
///
/// Backends, CPU first: the exact CPU engine serves from the first take, always. With `.automatic` (the default, no
/// code needed) the Neural Engine is promoted in the background (`AcceleratorController`: its files downloaded after
/// the first session, compiled, warmed, golden-tested against the model folder's self-test set); once it is ready
/// (`acceleratorState == .ready`), takes from the next one on run on it. A chunk that fails on the Neural Engine
/// (an exception, a NaN or inf, a head out of range, a missed deadline) switches the take to the CPU engine at that
/// chunk: the take's recent audio is replayed through it, the chunks already handed out stay, the take continues, and
/// the app gets no error (`activeBackend` and `fallbackReason` say what happened). Chunks that hear nothing in audio
/// with energy (normal in a long madd or a held vowel) are checked against the CPU engine off the audio path; only a
/// confirmed disagreement switches, and the chunk stream then hands out the CPU's chunks again from the first one in
/// question (the same `index`). What happens to the build depends on the cause (`AcceleratorController.failedOver`).
///
/// Settings precedence: the app's `options` > the portal's tajweed block (signed remote config) > calibration.json.
/// `debugBuild` is the APP's build: only a debug build may turn on a check calibration marks `off`, or force the
/// Neural Engine.
public actor TajweedRecognizer: AudioBufferSink {
    public enum Backend: String, Sendable {
        /// The exact CPU engine first; the Neural Engine once it is promoted (downloaded, compiled, golden-tested).
        case automatic
        /// Debug builds only: the Neural Engine at once, without the pipeline; throws where it cannot load (the build
        /// must be in the folder). A CPU-only context (`ModelContexts`) stays on the exact CPU engine, without an error.
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
    /// The switch to the CPU engine in the current (or last) take, when there was one.
    var lastFailover: TakeRunner.Failover?

    private let requested: Backend
    private let scorer: any TajweedScoring
    private let options: TajweedOptions
    private let remote: JSONValue?
    private let debugBuild: Bool
    private var runner: TakeRunner?
    private nonisolated let controllerBox = Locked<AcceleratorController?>(nil)
    /// The model as the pipeline sees it (the accelerator's files counted once its download verified them).
    private nonisolated let acceleratorModel: Locked<TajweedModel>
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
    private var take = TajweedHeads()
    private var takeChunkFrames: [Int] = []
    private var takeAudioSeconds = 0.0
    private var takeOpen = false
    /// Counts takes: the golden test stops when a take ran between two of its steps.
    private var takeGeneration = 0
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
    ///   - backend: `.automatic` (CPU first, then the Neural Engine once promoted), `.exact`, or in a debug build
    ///     `.neuralEngine`.
    public init(model: TajweedModel, options: TajweedOptions = .init(), remote: JSONValue? = nil, debugBuild: Bool = false,
                backend: Backend = .automatic, heads: HeadSelection = .default, scorer: (any TajweedScoring)? = nil) throws(RecognizerError) {
        if backend == .neuralEngine && !debugBuild {
            throw .invalidArgument("forcing the Neural Engine is for debug builds (debugBuild: true)")
        }
        self.model = model
        self.requested = backend
        acceleratorModel = Locked(model)
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
        // a build promoted in an earlier launch is loaded and warmed now, in the background, so the first session
        // normally starts on it (it never waits for it); nothing else starts before a session
        if Self.promotedEarlier(model: model, context: settings.context, requested: backend) {
            Task.detached(priority: .utility) { [weak self] in await self?.warmPromoted() }
        }
    }

    /// Whether this model, context and device have a build promoted in an earlier launch (the persisted verdict).
    static func promotedEarlier(model: TajweedModel, context: String, requested: Backend) -> Bool {
        guard requested == .automatic, mayUseAccelerator(requested: requested, context: context), DownloadProfile.osRunsCoreML,
              let b = model.coreML(context: context) else { return false }
        let key = AcceleratorController.key(revision: model.identity, context: context, build: b.compact ? "coreml-compact" : "coreml")
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

    /// The exact CPU engine when it is open (it is closed while the Neural Engine serves a take).
    var exact: TajweedExactEngine? { runner?.cpu as? TajweedExactEngine }

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

    /// Starts the promotion now if it has not started, and waits until the Neural Engine is ready or will not be (up to
    /// `timeout`); true when the next take will run on it.
    public func awaitReady(timeout: TimeInterval) async -> Bool {
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
    public var acceleratorSelfTest: AcceleratorSelfTest? { controllerBox.withLock { $0 }?.lastSelfTest }

    /// The controller of the Neural Engine's promotion (nil where it does not apply).
    var acceleratorController: AcceleratorController? { controllerBox.withLock { $0 } }

    /// Builds the CPU engine now (otherwise the first `startTake` does), and sets up the Neural Engine's promotion where
    /// it applies.
    public func prepare() throws(RecognizerError) {
        let t0 = Date()
        let opened = runner?.cpu == nil
        try makeRunner().ensureCPU()
        if opened {
            QuranLab.record(.modelLoaded(revision: model.revision, milliseconds: Date().timeIntervalSince(t0) * 1000, cohort: cohort))
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
        let ctx = settings.context
        let dir = model.directory
        // only the heads this recognizer hands out or keeps (the scorer's, conf for the decoded layer)
        let mask = HeadSelection(selection.heads.union([.conf])).engineMask
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
        let ctx = settings.context
        guard Self.mayUseAccelerator(requested: requested, context: ctx) else { return }
        guard DownloadProfile.osRunsCoreML else {
            if requested == .neuralEngine { throw .neuralEngineUnavailable("the V4 CoreML package needs iOS 18 or macOS 15") }
            if model.manifest.files.contains(where: { DownloadProfile.packageRoles.contains($0.role) }) {
                fixedState = .disabled("the OS is older than iOS 18 / macOS 15")
                noteFallback(.aneUnavailable, "the OS is older than iOS 18 / macOS 15")
            }
            return
        }
        let wantCompact = QuranLab.configuration.options.compactCoreML
        let downloadable = QuranLab.cloud.map { $0.updater.coreML } ?? false
        // the build on disk, unless the app asks for the other one and it can be downloaded (it then replaces it)
        let onDisk = model.coreML(context: ctx)
        let present = onDisk.flatMap { $0.compact == wantCompact || !downloadable ? $0 : nil }
        if requested == .neuralEngine {
            // debug builds: the build in the folder at once, without the pipeline
            guard let build = onDisk else { throw .neuralEngineUnavailable(model.coreMLProblem ?? "the folder has no CoreML package for \(ctx)") }
            guard #available(iOS 18.0, macOS 15.0, *) else { return }
            forced = AcceleratorExecutor(try TajweedNeuralEngine(build))
            fixedState = .ready
            return
        }
        // the promotion applies when the folder has the build, or lists one this install may download
        let compact = present?.compact ?? wantCompact
        let listed = !DownloadProfile(context: ctx, coreML: true, compact: compact).appleFiles(model.manifest).isEmpty
        guard present != nil || (downloadable && listed) else {
            if let p = model.coreMLProblem {
                fixedState = .disabled(p)
                noteFallback(.modelLoad, p)
            }
            return
        }
        let identity = model.identity
        let cohortNow = cohort
        let env = AcceleratorController.Environment(
            revision: identity, context: ctx, build: compact ? "coreml-compact" : "coreml",
            storage: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"),
            denied: { QuranLab.cloud?.acceleratorDenied(revision: identity) },
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

    /// Whether the Neural Engine is considered at all. Never for a CPU-only context, even when it is asked for.
    static func mayUseAccelerator(requested: Backend, context: String) -> Bool {
        requested != .exact && !ModelContexts.isCPUOnly(context)
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
        let ctx = settings.context
        let box = acceleratorModel
        let compact = QuranLab.configuration.options.compactCoreML
        return AcceleratorController.Stages(
            download: { () async throws(PromotionFailure) -> Void in
                let m = box.withLock { $0 }
                if let b = m.coreML(context: ctx), b.compact == compact || QuranLab.cloud == nil { return }
                guard let cloud = QuranLab.cloud else { throw PromotionFailure(.network, "no Quran Lab cloud to download the CoreML build from") }
                do throws(RecognizerError) {
                    _ = try await cloud.updater.installAccelerator(m, context: ctx)
                } catch {
                    throw Self.downloadFailure(error)
                }
                let profile = DownloadProfile(context: ctx, coreML: true, compact: compact)
                let updated = m.adding(verified: profile.appleFiles(m.manifest).map(\.localPath),
                                       removing: profile.otherBuildFiles(m.manifest).map(\.localPath))
                guard updated.coreML(context: ctx) != nil else {
                    throw PromotionFailure(.verify, updated.coreMLProblem ?? "the downloaded CoreML build is not usable")
                }
                box.withLock { $0 = updated }
            },
            compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                let m = box.withLock { $0 }
                guard let build = m.coreML(context: ctx) else { throw PromotionFailure(.compileError, "no CoreML build for \(ctx)") }
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
            fingerprint: { () -> String? in Self.programFingerprint(box.withLock { $0 }, context: ctx) })
    }

    /// The SHA-256 of the build's program on disk (the manifest's, checked when the folder was opened or the install
    /// verified it), or "gone".
    static func programFingerprint(_ m: TajweedModel, context: String) -> String {
        guard let b = m.coreML(context: context) else { return "gone" }
        let role = b.compact ? "coreml-compact" : "coreml"
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
    static func warmUp(_ b: any AcceleratorBackend, model: TajweedModel, context: String) throws(PromotionFailure) {
        var clip: [Float] = []
        if model.verifiedFiles.contains("selftest/selftest.json"), let set = SelfTestSet.load(model.directory, context: context) {
            clip = set.clips.first?.samples ?? []
        } else if let c = try? SelfTestClips.load().clips.first {
            clip = c.samples
        }
        b.reset()
        defer { b.reset() }
        var out: [TajweedHeads] = []
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

    /// The golden test: every self-test clip through the build and through the CPU engine, the same streaming code a
    /// session uses (pieces of one chunk, then the flush), scored at the default settings. The CPU's decisions must
    /// equal the shipped expected file (else `cpu_mismatch`); the build's must equal it by the pass rule (tokens on
    /// clean clips, flagged sites and words on every clip; else `golden_mismatch`); any NaN, inf or head out of range
    /// is `non_finite`. Between pieces the actor is free: a take that starts stops the test (`aborted`, no failure).
    func golden(_ b: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome {
        guard !takeOpen, let runner else { return .aborted }
        let generation = takeGeneration
        let m = acceleratorModel.withLock { $0 }
        let ctx = settings.context
        let piece = runner.chunkSamples
        let exec = AcceleratorExecutor(b.value, label: "ai.quranlab.accelerator.golden")
        let acc = TakeRunner(chunkMs: runner.chunkMs, openCPU: { () throws(RecognizerError) -> any CPUStreamEngine in
            throw RecognizerError.neuralEngineUnavailable("no CPU engine in the golden test's accelerator run")
        })
        acc.failoverEnabled = false
        var accTimes: [Double] = [], cpuTimes: [Double] = []
        let set: SelfTestSet? = m.verifiedFiles.contains("selftest/selftest.json") && m.verifiedFiles.contains("selftest/expected_\(ctx).json")
            ? SelfTestSet.load(m.directory, context: ctx) : nil
        struct Clip { let id: String; let surah: Int; let ayah: Int; let samples: [Float]; let planted: Bool; let plantedSite: String? }
        var clips: [Clip] = []
        if let set {
            clips = set.clips.map { Clip(id: $0.id, surah: $0.surah, ayah: $0.ayah, samples: $0.samples, planted: $0.planted, plantedSite: $0.plantedSite) }
        } else if let bundled = try? SelfTestClips.load() {
            clips = bundled.clips.map { Clip(id: $0.name, surah: 0, ayah: 0, samples: $0.samples, planted: false, plantedSite: nil) }
        }
        var results: [GoldenJudge.Clip] = []
        let build = (m.coreML(context: ctx)?.compact ?? false) ? "coreml-compact" : "coreml"
        let tolerance = m.manifest.tolerance(build: build)
        guard !clips.isEmpty else { return .failed(PromotionFailure(.other, "no self-test clips")) }
        let defaultsCPU = try? TajweedSettings.resolve(calibration: model.calibration, remote: nil, app: TajweedOptions(context: ctx),
                                                       debugBuild: false, backend: .int8)
        let defaultsAcc = try? TajweedSettings.resolve(calibration: model.calibration, remote: nil, app: TajweedOptions(context: ctx),
                                                       debugBuild: false, backend: .fp32)
        func decisions(_ h: TajweedHeads, _ c: Clip, _ s: EffectiveTajweed?) -> (Set<String>, Set<Int>)? {
            guard set != nil, let s,
                  let r = try? scorer.score(heads: h, TajweedScoreRequest(surah: c.surah, ayah: c.ayah, settings: s, options: TajweedOptions(context: ctx)))
            else { return nil }
            return (Set(r.sites.filter(\.flagged).map { "\($0.position)|\($0.cls.rawValue)" }), Set(r.words.filter { $0.flagged == true }.map(\.index)))
        }
        for c in clips {
            // the CPU engine
            let cpu: any CPUStreamEngine
            do throws(RecognizerError) { cpu = try runner.ensureCPU() } catch { return .failed(PromotionFailure(.other, "the CPU engine: \(error)")) }
            cpu.reset()
            var cpuHeads = TajweedHeads()
            var at = 0
            repeat {
                await Task.yield()
                if takeOpen || takeGeneration != generation { cpu.reset(); return .aborted }
                let s = Array(c.samples[at..<min(c.samples.count, at + piece)])
                let t0 = CFAbsoluteTimeGetCurrent()
                let out: [TajweedHeads]
                do throws(RecognizerError) {
                    out = try s.withUnsafeBufferPointer { (p) throws(RecognizerError) in try cpu.push(p) }
                } catch { return .failed(PromotionFailure(.cpuMismatch, "\(c.id): the CPU engine failed: \(error)", clip: c.id)) }
                if !out.isEmpty { cpuTimes += Array(repeating: (CFAbsoluteTimeGetCurrent() - t0) / Double(out.count), count: out.count) }
                for h in out { cpuHeads.append(h) }
                at += piece
            } while at < c.samples.count
            do throws(RecognizerError) { for h in try cpu.finish() { cpuHeads.append(h) } } catch {
                return .failed(PromotionFailure(.cpuMismatch, "\(c.id): the CPU engine failed: \(error)", clip: c.id))
            }
            cpu.reset()
            // the accelerator
            do throws(RecognizerError) { try acc.start(accelerator: exec) } catch { return .failed(PromotionFailure(.hang, "\(error)")) }
            guard acc.onAccelerator else { return .failed(PromotionFailure(.hang, "the accelerator was abandoned after a missed deadline")) }
            var accHeads = TajweedHeads()
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
                // (no blank rule here: the clip's decisions are compared with the CPU engine's below)
                let cause = acc.detected?.cause
                let reason: PromotionReason = cause == .deadline ? .hang : (cause == .nonFinite || cause == .outOfRange) ? .nonFinite : .other
                let ns = b.value.lastError
                return .failed(PromotionFailure(reason, "\(c.id): \(acc.detected?.detail ?? "\(error)")", errorDomain: ns?.domain,
                                                errorCode: ns.map { String($0.code) }, clip: c.id))
            }
            // warm chunks only: each clip's first chunk is a take's first (cold) chunk
            accTimes += acc.takeWarmMs.map { $0 / 1000 }
            // the decisions of both engines (the judge compares them below, in both directions)
            var r = GoldenJudge.Clip(id: c.id, planted: c.planted, plantedSite: c.plantedSite, expected: set?.expected[c.id],
                                     cpuTokens: cpuHeads.greedy, accTokens: accHeads.greedy)
            if r.expected != nil {
                guard let cpuD = decisions(cpuHeads, c, defaultsCPU), let accD = decisions(accHeads, c, defaultsAcc) else {
                    return .failed(PromotionFailure(.other, "\(c.id): the scorer did not score the clip", clip: c.id))
                }
                (r.cpuSites, r.cpuWords) = cpuD
                (r.accSites, r.accWords) = accD
            }
            results.append(r)
        }
        exec.reset(wait: true)
        let verdict = GoldenJudge.evaluate(results, tolerance: tolerance)
        if let f = verdict.failure { return .failed(f) }
        if !verdict.totals.isZero {
            let t = verdict.totals
            Self.debugLog("golden test passed within its tolerance: \(t.tokensDiffer) token edits, \(t.sitesDiffer) site flags, "
                          + "\(t.wordsDiffer) word flags differ from the CPU engine")
        }
        return .passed(accelerator: accTimes, cpu: cpuTimes)
    }

    // MARK: takes

    /// A new take (one recitation session): builds the CPU engine on first use, picks the backend (the Neural Engine
    /// when it is promoted and warm, else the CPU engine; never decided during a take), resets every cache and the
    /// kept heads, and starts sharing the session's audio when the learner agreed to share.
    public func startTake() throws(RecognizerError) {
        if takeOpen { endTake(completed: false) }
        let runner = makeRunner()
        try setUpAccelerator()
        takeGeneration += 1
        converter = nil
        take = TajweedHeads()
        takeChunkFrames = []
        delivered = 0
        handedOut = 0
        takeAudioSeconds = 0
        feedError = nil
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
        settingsInForce = runner.onAccelerator ? acceleratorSettings : settings
        takeOpen = true
        activity = SessionActivity()
        share = Contributions.capture(revision: model.identity, backend: activeBackend ?? .exact,
                                      weightsSHA256: model.manifest.files(role: "weights").first?.localSHA256)
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
        let build = (m.coreML(context: settings.context)?.compact ?? false) ? "coreml-compact" : "coreml"
        p.blankTokenTolerance = m.manifest.tolerance(build: build).tokenDiffs
        if let m = c?.record?.cpuMedianMs, m > 0 { p.cpuChunkMs = m }
        if let o = runner?.lastOpenMs, o > 0 { p.cpuOpenMs = o }
        p.minReplayChunks = Self.cacheSpanChunks(context: settings.context) + 1
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

    /// The chunks of the current take as they complete (from `append` or the microphone), each with the selected
    /// heads; the stream ends when the take finishes. Call after `startTake`. Since 2.0.2 a chunk can come again with
    /// the same `index` and `replaces == true` (the CPU engine's, after it confirmed that the Neural Engine missed
    /// speech there): replace that index and drop what you kept from it on; the later indexes follow in order.
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

    /// 16 kHz samples through the take's backend; a failover inside is handled here and invisible to the caller.
    private func push(_ s: [Float]) throws(RecognizerError) -> [TajweedChunk] {
        guard let runner else { throw .sessionClosed }
        let out = try runner.push(s)
        let chunks = apply(out)
        noteFailover()
        return chunks
    }

    /// Applies what the runner added to the take: a truncation (a failover replaced chunks from there on), then the new
    /// chunks, handing out only those not handed out yet.
    private func apply(_ o: TakeRunner.Output) -> [TajweedChunk] {
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
        settingsInForce = settings
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
    private func deliver(_ chunks: [TajweedHeads]) -> [TajweedChunk] {
        var out: [TajweedChunk] = []
        let keep = selection.heads.union(TajweedHead.scorer).union([.conf])
        let ms = runner?.chunkMs ?? 320
        for c in chunks {
            take.append(c.keeping(keep))
            let index = takeChunkFrames.count
            takeChunkFrames.append(c.n40)
            if index >= delivered {
                let chunk = TajweedChunk(index: index, startMs: index * ms, heads: c.keeping(selection.heads), replaces: index < handedOut)
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
    public func finish() async throws(RecognizerError) -> TajweedHeads {
        await drainFeed()
        guard takeOpen else { throw .sessionClosed }
        if let e = feedError { endTake(completed: false); throw e }
        var out: [TajweedChunk] = []
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
        endTake(completed: true)
        return take
    }

    /// The chunks `finish` ran (the flush's).
    public private(set) var lastChunks: [TajweedHeads] = []

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
        share?.finish(completed: completed)
        share = nil
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
        let checks = TajweedCheck.allCases.filter { c in
            switch c {
            case .madd: return settings.madd.enabled
            case .lazim: return settings.lazim.enabled
            case .gemination: return settings.gemination.enabled
            case .qalqalah: return settings.qalqalah.enabled
            default: return settings.sites.contains { TajweedClass(rawValue: $0.key)?.check == c && $0.value.enabled }
            }
        }.map(\.rawValue)
        QuranLab.record(.sessionFinished(SessionTelemetry(cohort: cohort, audioSeconds: takeAudioSeconds, chunkSeconds: runner?.chunkSeconds ?? [],
                                                          chunkAudioSeconds: Double(runner?.chunkMs ?? 320) / 1000, checksOn: checks,
                                                          throttled: false, thermalTransitions: 0,
                                                          coldStartMs: first ? coldStart : nil)))
    }

    /// Ends the take without results (the learner left); a shared session is kept only as far as it got.
    public func cancelTake() async {
        await drainFeed()
        endTake(completed: false)
    }

    // MARK: layers

    /// Whether the CPU stream holds exactly this take's heads (it ran it all, or replayed all of it).
    private var cpuHoldsTake: Bool { activeBackend == .exact && (runner?.cpuHasWholeTake ?? false) }

    /// The heads of the take so far (the scorer's heads, `conf`, and the selected ones).
    public func heads() -> TajweedHeads { take }

    /// The decoded layer of the take so far: per frame top-1 and runner-up, the greedy tokens with confidence and
    /// margin, words and times.
    public func decoded() -> DecodedTake {
        // the CPU engine keeps the top-2 of the take as it runs (when it ran the whole take); other heads go through
        // zf_tajweed_top2
        let frames = cpuHoldsTake ? exact?.top2() : nil
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
        if cpuHoldsTake, let exact, let r = try exact.ranking(head, k: k, frames: frames, names: names) { return r }
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
        // a verdict counts only where its check ran
        for q in r.qalqalah where q.status != .off {
            t.qalqalahChecked += 1
            if q.flagged { t.qalqalahFlagged += 1 }
        }
        for g in r.gemination where g.status != .off {
            t.geminationChecked += 1
            if g.flagged { t.geminationFlagged += 1 }
        }
        let d = decoded()
        t.margins = d.tokens.map(\.margin)
        t.confidences = d.tokens.compactMap(\.confidence)
        QuranLab.record(.scored(t))
        return r
    }

    /// Tells the SDK the learner finished a session; `feedback` is true when they were shown the model's feedback
    /// for it. This is the moment the SDK may ask about sharing recitations (never on first launch, never after a yes
    /// or after sharing was turned off; at most twice more after "Not now", 7 sessions apart: three sheets per install
    /// in all). Returns what the app should show, if anything (the SDK's own sheet
    /// does this on a view with `.quranLabSharing()`).
    @discardableResult
    public func endSession(feedback: Bool) -> SharingMoment? {
        Contributions.sessionCompleted(feedback: feedback)
    }
}
