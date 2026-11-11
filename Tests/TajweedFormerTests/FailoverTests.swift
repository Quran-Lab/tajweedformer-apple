import Foundation
import XCTest
@testable import TajweedFormer
#if canImport(Darwin)
import Darwin
#endif

/// In-session failover without the model: a fake CPU engine with a carried state, and a fake accelerator that runs its
/// own copy and fails on demand (an exception, a NaN, a head out of range, a hung call, blank chunks) at the first, a
/// middle and the last chunk. No crash, no error to the caller, the take complete, the stall measured; a whole-take
/// replay is exact, a bounded one continues from the failed chunk; a hung call is abandoned at its deadline.
final class FailoverTests: XCTestCase {
    func runner(budgetChunks: Int? = nil, deadlineMs: Double = 300) -> TakeRunner {
        let r = TakeRunner(chunkMs: 320, openCPU: { () throws(RecognizerError) -> any CPUStreamEngine in FakeCPUEngine() })
        r.policy.deadlineMs = deadlineMs
        r.policy.cpuChunkMs = 1
        r.policy.cpuOpenMs = 1
        r.policy.maxReplayChunks = budgetChunks
        // a call past its deadline is abandoned at once (2.0.1's executor), so the hang cases finish fast
        r.policy.hangGraceMs = 0
        return r
    }

    func reference(_ audio: [Float]) throws -> RunResult { try runTake(runner(), audio, accelerator: nil) }

    func testAFailureAtTheFirstAMiddleAndTheLastChunkGivesTheCPUOnlyTake() throws {
        let audio = fakeRecitation(seconds: 6)
        let ref = try reference(audio)
        let total = ref.frames.count
        XCTAssertGreaterThan(total, 15)
        let modes: [(String, FakeAccelerator.Failure)] = [("exception", .exception), ("nan", .nan), ("out_of_range", .outOfRange), ("hang", .hang(2))]
        var stalls: [Double] = []
        for (name, mode) in modes {
            for at in [0, total / 2, total - 1] {
                let r = runner(deadlineMs: 100)
                let acc = AcceleratorExecutor(FakeAccelerator(failAt: at, failure: mode))
                let t0 = CFAbsoluteTimeGetCurrent()
                let got = try runTake(r, audio, accelerator: acc)
                let wall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                let f = try XCTUnwrap(r.failover, "\(name) at \(at)")
                switch mode {
                case .nan, .outOfRange:
                    XCTAssertEqual(f.chunk, at, "\(name) at \(at): the bad chunk itself")
                default:
                    // a call that throws or hangs fails as a whole: the switch is at its first chunk (the flush runs
                    // several chunks in one call)
                    XCTAssertLessThanOrEqual(f.chunk, at, "\(name) at \(at)")
                    XCTAssertGreaterThanOrEqual(f.chunk, at - 4, "\(name) at \(at)")
                }
                XCTAssertTrue(f.exact, "\(name) at \(at): a short take is replayed whole")
                XCTAssertEqual(got.frames.count, total, "\(name) at \(at): the take is complete")
                XCTAssertEqual(got.heads.greedy, ref.heads.greedy, "\(name) at \(at): exactly the CPU-only take")
                XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
                XCTAssertFalse(r.onAccelerator)
                XCTAssertLessThan(f.stallMs, 300)
                if case .hang = mode {
                    XCTAssertEqual(f.cause, .deadline)
                    XCTAssertLessThan(wall, 1500, "the hung call is abandoned at its deadline, not awaited")
                    XCTAssertTrue(acc.abandoned)
                }
                stalls.append(f.stallMs)
            }
        }
        print(String(format: "v4-failover fake: %d failovers, stall max %.2f ms (fake engine; not a device number)", stalls.count, stalls.max() ?? 0))
    }

    func testCausesAreDetected() throws {
        let audio = fakeRecitation(seconds: 3)
        for (mode, cause) in [(FakeAccelerator.Failure.exception, FailoverCause.exception), (.nan, .nonFinite), (.outOfRange, .outOfRange),
                              (.hang(0.5), .deadline)] {
            let r = runner(deadlineMs: 80)
            _ = try runTake(r, audio, accelerator: AcceleratorExecutor(FakeAccelerator(failAt: 2, failure: mode)))
            XCTAssertEqual(r.failover?.cause, cause, "\(mode)")
        }
    }

    /// Blank chunks with audio in them that the CPU engine hears: the suspicion at the third is verified on the CPU,
    /// the disagreement confirmed, and the CPU redoes the take from the first (handed out again from there).
    func testBlankChunksTheCPUHearsSwitchAndRedoFromTheFirstBlank() throws {
        let audio = fakeRecitation(seconds: 6)
        let ref = try reference(audio)
        let r = runner()
        let got = try runTake(r, audio, accelerator: AcceleratorExecutor(FakeAccelerator(failAt: 4, failure: .blank)))
        let f = try XCTUnwrap(r.failover)
        XCTAssertEqual(f.cause, .blank)
        XCTAssertEqual(f.chunk, 4)
        XCTAssertEqual(got.heads.greedy, ref.heads.greedy)
        XCTAssertEqual(got.redeliveredFrom, [4])
        XCTAssertGreaterThan(f.divergence?.tokenEdits ?? 0, 0)
    }

    /// A take longer than the replay budget: the last chunks are replayed, the CPU continues from the failed chunk, the
    /// chunks before it stay as the accelerator gave them; the take has every chunk. The fake engine's carried state is
    /// not rebuilt exactly, so the tokens after the failure may differ: counted, not hidden.
    func testABoundedReplayContinuesFromTheFailedChunk() throws {
        let audio = fakeRecitation(seconds: 20, seed: 3)
        let ref = try reference(audio)
        let r = runner(budgetChunks: 5)
        let at = 40
        let got = try runTake(r, audio, accelerator: AcceleratorExecutor(FakeAccelerator(failAt: at, failure: .exception)))
        let f = try XCTUnwrap(r.failover)
        XCTAssertEqual(f.chunk, at)
        XCTAssertEqual(f.replayFrom, at - 5)
        XCTAssertFalse(f.exact)
        XCTAssertFalse(r.cpuHasWholeTake)
        XCTAssertEqual(got.frames.count, ref.frames.count)
        let n = got.frames.prefix(at).reduce(0, +) * 38
        XCTAssertEqual(Array(got.heads.logProbs.prefix(n)), Array(ref.heads.logProbs.prefix(n)), "the chunks before the failure stay")
        print("v4-failover fake bounded: replay from \(f.replayFrom), token edits \(Divergence.edits(ref.heads.greedy, got.heads.greedy)) of \(ref.heads.greedy.count)")
    }

    func testAHungCallIsAbandonedAndTheExecutorRefusesLaterTakes() throws {
        let acc = AcceleratorExecutor(FakeAccelerator(failAt: 0, failure: .hang(2)))
        let r = runner(deadlineMs: 50)
        let t0 = Date()
        _ = try runTake(r, fakeRecitation(seconds: 2), accelerator: acc)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertTrue(acc.abandoned)
        try r.start(accelerator: acc)
        XCTAssertFalse(r.onAccelerator, "an abandoned accelerator is never used again")
    }

    /// While the accelerator serves, the CPU engine is closed (no standby memory); the failover opens it.
    func testTheCPUEngineIsClosedDuringAnAcceleratorTakeAndOpenedAtTheSwitch() throws {
        let r = runner()
        try r.start(accelerator: nil)
        XCTAssertNotNil(r.cpu)
        try r.start(accelerator: AcceleratorExecutor(FakeAccelerator()))
        XCTAssertNil(r.cpu, "closed while the accelerator serves")
        let acc = AcceleratorExecutor(FakeAccelerator(failAt: 3, failure: .nan))
        let opened = FakeCPUEngine.opened.withLock { $0 }
        _ = try runTake(r, fakeRecitation(seconds: 3), accelerator: acc)
        XCTAssertEqual(FakeCPUEngine.opened.withLock { $0 }, opened + 1)
        XCTAssertEqual(r.failover?.cold, true)
    }

    // MARK: the pieces

    func testHeadsCheck() {
        func chunk(_ name: String, _ v: [Float]) -> HeadsBuffer {
            var c = HeadsBuffer(chunk: ["log_probs": [Float](repeating: -3, count: 38)])
            c.set(name, v)
            return c
        }
        XCTAssertNil(HeadsCheck.check(chunk("log_probs", [Float](repeating: -3, count: 38))))
        XCTAssertNil(HeadsCheck.check(chunk("gem", [0.4, 0.6])))
        XCTAssertNil(HeadsCheck.check(chunk("boundary", [-12.5])))
        XCTAssertEqual(HeadsCheck.check(chunk("log_probs", [.nan] + [Float](repeating: -3, count: 37)))?.0, .nonFinite)
        XCTAssertEqual(HeadsCheck.check(chunk("inter1_log_probs", [Float.infinity]))?.0, .nonFinite)
        XCTAssertEqual(HeadsCheck.check(chunk("log_probs", [3] + [Float](repeating: -3, count: 37)))?.0, .outOfRange)
        XCTAssertEqual(HeadsCheck.check(chunk("timing_log_probs", [-50_000]))?.0, .outOfRange)
        XCTAssertEqual(HeadsCheck.check(chunk("attr_ghunna", [1.5]))?.0, .outOfRange)
        XCTAssertEqual(HeadsCheck.check(chunk("conf", [60_000]))?.0, .outOfRange)
    }

    func testTheAudioRing() {
        var ring = AudioRing(capacity: 10)
        ring.append((0..<7).map(Float.init))
        XCTAssertEqual(ring.samples(from: 0), (0..<7).map(Float.init))
        ring.append((7..<16).map(Float.init))
        XCTAssertEqual(ring.oldest, 6)
        XCTAssertEqual(ring.total, 16)
        XCTAssertEqual(ring.samples(from: 0), (6..<16).map(Float.init), "clamped to what is kept")
        XCTAssertEqual(ring.samples(from: 12), (12..<16).map(Float.init))
        ring.append((16..<40).map(Float.init))
        XCTAssertEqual(ring.samples(from: 35), (35..<40).map(Float.init))
        ring.reset()
        XCTAssertEqual(ring.samples(from: 0), [])
    }

    func testTheDeadlineAndTheReplayWindow() {
        XCTAssertEqual(PromotionPolicy.deadlineMs(p90Ms: nil, medianMs: nil), 300, "before a measurement")
        XCTAssertEqual(PromotionPolicy.deadlineMs(p90Ms: 5, medianMs: 4), 50, "the floor")
        XCTAssertEqual(PromotionPolicy.deadlineMs(p90Ms: 60, medianMs: 30), 240)
        XCTAssertEqual(PromotionPolicy.deadlineMs(p90Ms: 100, medianMs: 90), 300, "never above 300 ms")
        var p = TakeRunner.Policy()
        p.cpuChunkMs = 15
        p.cpuOpenMs = 100
        XCTAssertEqual(p.replayChunks, 10, "(250 - 100) / 15")
        p.cpuChunkMs = 60
        XCTAssertEqual(p.replayChunks, 5, "never fewer than the caches' span plus one")
        XCTAssertEqual(TajweedRecognizer.cacheSpanChunks(context: "c16_l64"), 4)
        XCTAssertEqual(TajweedRecognizer.cacheSpanChunks(context: "c24_l72"), 3)
        XCTAssertEqual(TajweedRecognizer.cacheSpanChunks(context: "c24_l256"), 11)
        XCTAssertEqual(TajweedRecognizer.cacheSpanChunks(context: "c8_l64"), 8)
    }
}

/// The order, through the recognizer (the bundled test folder, the fake CPU engine and fake stages): the first session
/// runs on the CPU and the pipeline starts only after it; a session that started before the promotion stays on the
/// CPU and the next one uses the accelerator; a failover in a session is invisible to the app, demotes the build and
/// the next session starts on the CPU; a key promoted earlier is warmed at launch while sessions run on the CPU.
final class PromotionOrderTests: XCTestCase {
    final class Sink: AnalyticsSink, @unchecked Sendable {
        let events = Locked<[AnalyticsEvent]>([])
        func record(_ event: AnalyticsEvent) { events.withLock { $0.append(event) } }
    }

    let calls = Locked<[String]>([])
    let gate = Locked(true)
    let failure = Locked<(Int, FakeAccelerator.Failure)>((-1, .none))
    /// Chunks both engines hear nothing in (a held vowel), when set.
    let held = Locked<Range<Int>?>(nil)
    let sink = Sink()

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        let calls = self.calls, gate = self.gate, failure = self.failure, held = self.held
        TajweedRecognizer.stagesOverride.withLock {
            $0 = { _ in
                AcceleratorController.Stages(
                    download: { () async throws(PromotionFailure) -> Void in calls.withLock { $0.append("download") } },
                    compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                        calls.withLock { $0.append("compile") }
                        while !gate.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 10_000_000) }
                        let (at, f) = failure.withLock { $0 }
                        return UncheckedBox(FakeAccelerator(failAt: at, failure: f, held: held.withLock { $0 }) as any AcceleratorBackend)
                    },
                    warmup: { (_: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in calls.withLock { $0.append("warmup") } },
                    golden: { (_: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                        calls.withLock { $0.append("golden") }
                        return .passed(accelerator: [0.002], cpu: [0.008])
                    },
                    sessionActive: { () async -> Bool in false },
                    waitIdle: { () async -> Void in })
            }
        }
        QuranLab.configure(options: .init(modelSource: [], analytics: .on, analyticsSink: sink, storageDirectory: Fixtures.storage(), cloud: nil))
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        TajweedRecognizer.stagesOverride.withLock { $0 = nil }
    }

    /// The bundled folder with the CoreML files a device has by default: the fp16 build (as a bundled or
    /// earlier-installed folder has them).
    func model() async throws -> ModelFolder {
        let m = try ModelManifest.read(Fixtures.v4mini().appendingPathComponent("server"))
        let dir = Fixtures.storage().appendingPathComponent("model")
        _ = try await ModelInstaller(source: DirectoryFileSource(root: Fixtures.v4mini().appendingPathComponent("server")))
            .install(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        let model = try ModelFolder.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true))
        guard model.coreML(context: "c16_l64") != nil else { throw XCTSkip("the bundled folder has no CoreML build for c16_l64") }
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        return model
    }

    func take(_ r: TajweedRecognizer, seconds: Double = 3) async throws -> (ActiveBackend?, HeadsBuffer) {
        try await r.startTake()
        let started = await r.activeBackend
        let a = fakeRecitation(seconds: seconds)
        var at = 0
        while at < a.count {
            try await r.append(Array(a[at..<min(a.count, at + 4000)]))
            at += 4000
        }
        let h = try await r.finish()
        return (started, h)
    }

    func waitFor(_ r: TajweedRecognizer, _ want: AcceleratorState, timeout: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await r.acceleratorState == want { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testTheOrderFromTheFirstSessionToAFailover() async throws {
        let model = try await model()
        gate.withLock { $0 = false }
        let r = try TajweedRecognizer(model: model, backend: .automatic)
        // first session: on the CPU, and nothing of the pipeline before it
        try await r.startTake()
        let v1 = await r.activeBackend
        XCTAssertEqual(v1, .exact)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(calls.withLock { $0 }, [], "nothing queued in front of the first session")
        try await r.append(fakeRecitation(seconds: 2))
        try await r.finish()
        // the pipeline starts after it (held at the compile by the gate)
        var started = false
        for _ in 0..<200 where !started {
            started = calls.withLock { $0 }.contains("compile")
            if !started { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(started, "the pipeline starts once the first session ended")
        // a session that starts before the promotion stays on the CPU even when the promotion lands during it
        try await r.startTake()
        let v2 = await r.activeBackend
        XCTAssertEqual(v2, .exact)
        gate.withLock { $0 = true }
        let ready = await waitFor(r, .ready)
        XCTAssertTrue(ready)
        try await r.append(fakeRecitation(seconds: 2))
        let v3 = await r.activeBackend
        XCTAssertEqual(v3, .exact, "never switched during a session")
        let cpuTake = try await r.finish()
        // the next one uses the accelerator; the CPU engine is closed meanwhile
        let (backend, onAcc) = try await take(r)
        XCTAssertEqual(backend, .neuralEngine)
        XCTAssertFalse(onAcc.greedy.isEmpty)
        _ = cpuTake
        XCTAssertEqual(calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
    }

    func testAFailoverIsInvisibleToTheAppAndTheNextSessionStartsOnTheCPU() async throws {
        let model = try await model()
        failure.withLock { $0 = (4, .exception) }
        let r = try TajweedRecognizer(model: model, backend: .automatic)
        let (first, cpuHeads) = try await take(r)
        XCTAssertEqual(first, .exact)
        let v4 = await waitFor(r, .ready)
        XCTAssertTrue(v4)
        let (second, heads) = try await take(r)
        XCTAssertEqual(second, .neuralEngine)
        let v5 = await r.activeBackend
        XCTAssertEqual(v5, .exact, "the backend name changed")
        XCTAssertEqual(heads.greedy, cpuHeads.greedy, "a whole-take replay: the same take as on the CPU")
        let lf = await r.lastFailover
        let f = try XCTUnwrap(lf)
        XCTAssertEqual(f.chunk, 4)
        let v6 = await r.fallbackReason
        XCTAssertEqual(v6, .other)
        let st = await r.acceleratorState
        guard case .disabled = st else { return XCTFail("demoted") }
        let (third, _) = try await take(r)
        XCTAssertEqual(third, .exact, "later sessions start on the CPU")
        let fo = sink.events.withLock { $0 }.contains { if case .promotion(let p) = $0, case .failover(.exception, _) = p.kind { return true }; return false }
        XCTAssertTrue(fo, "the failover is counted")
        print(String(format: "v4-failover order: chunk %d, stall %.2f ms (fake engines)", f.chunk, f.stallMs))
    }

    /// 2.0.2: a held vowel both engines hear nothing in keeps the session and the build on the Neural Engine, counted
    /// as `blank_confirmed_ok`; the next session runs on it too.
    func testAHeldVowelTheCPUConfirmsKeepsTheNeuralEngine() async throws {
        let model = try await model()
        held.withLock { $0 = 6..<14 }
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine(held: 6..<14) } }
        let r = try TajweedRecognizer(model: model, backend: .automatic)
        let (first, cpuHeads) = try await take(r, seconds: 8)
        XCTAssertEqual(first, .exact)
        let ready = await waitFor(r, .ready)
        XCTAssertTrue(ready)
        let (second, heads) = try await take(r, seconds: 8)
        XCTAssertEqual(second, .neuralEngine)
        let still = await r.activeBackend
        XCTAssertEqual(still, .neuralEngine, "no failover")
        let lf = await r.lastFailover
        XCTAssertNil(lf)
        XCTAssertEqual(heads.greedy, cpuHeads.greedy)
        let st = await r.acceleratorState
        XCTAssertEqual(st, .ready)
        let ok = sink.events.withLock { $0 }.filter { if case .promotion(let p) = $0, case .blankConfirmedOK = p.kind { return true }; return false }
        XCTAssertEqual(ok.count, 1)
        let (third, _) = try await take(r)
        XCTAssertEqual(third, .neuralEngine)
    }

    /// 2.0.2: a stretch the Neural Engine hears nothing in and the CPU does: the session switches, the chunk stream
    /// hands out the CPU's chunks again from the first one in question, the take is the CPU-only one, the build is
    /// demoted for 6 h (transient).
    func testAConfirmedBlankDisagreementRedeliversTheCPUChunks() async throws {
        let model = try await model()
        failure.withLock { $0 = (6, .blankSpan(8)) }
        let r = try TajweedRecognizer(model: model, backend: .automatic)
        let (_, cpuHeads) = try await take(r, seconds: 8)
        let ready = await waitFor(r, .ready)
        XCTAssertTrue(ready)
        try await r.startTake()
        let started = await r.activeBackend
        XCTAssertEqual(started, .neuralEngine)
        let stream = await r.chunks()
        let collector = Task { () -> [(Int, Bool)] in
            var seen: [(Int, Bool)] = []
            for await c in stream { seen.append((c.index, c.replaces)) }
            return seen
        }
        let a = fakeRecitation(seconds: 8)
        var at = 0
        while at < a.count {
            try await r.append(Array(a[at..<min(a.count, at + 4000)]))
            at += 4000
        }
        let heads = try await r.finish()
        let pairs = await collector.value
        let seen = pairs.map(\.0)
        // replaces is true exactly for an index handed out before
        var before = Set<Int>()
        for (i, r) in pairs {
            XCTAssertEqual(r, before.contains(i), "chunk \(i)")
            before.insert(i)
        }
        XCTAssertEqual(pairs.first { $0.1 }?.0, 6, "the first replacement is the first suspicious chunk")
        let lf = await r.lastFailover
        let f = try XCTUnwrap(lf)
        XCTAssertEqual(f.cause, .blank)
        XCTAssertEqual(f.chunk, 6)
        XCTAssertEqual(heads.greedy, cpuHeads.greedy, "nothing lost: the CPU-only take")
        XCTAssertGreaterThanOrEqual(seen.filter { $0 == 6 }.count, 2, "chunk 6 handed out again (\(seen))")
        XCTAssertEqual(Set(seen), Set(0..<(seen.max() ?? 0) + 1), "every index handed out")
        let st = await r.acceleratorState
        guard case .disabled(let why) = st else { return XCTFail("\(st)") }
        XCTAssertTrue(why.contains("used again after"), why)
    }

    func testAKeyPromotedEarlierIsWarmedWhileTheFirstSessionRunsOnTheCPU() async throws {
        let model = try await model()
        let a = try TajweedRecognizer(model: model, backend: .automatic)
        try await a.prepare()
        let ac = await a.acceleratorController
        let c = try XCTUnwrap(ac)
        var rec = PromotionRecord(key: c.key)
        rec.status = .ready
        rec.completed = .promote
        rec.acceleratorMedianMs = 2
        rec.acceleratorP90Ms = 3
        rec.cpuMedianMs = 8
        c.store.save(rec)
        gate.withLock { $0 = false }
        let b = try TajweedRecognizer(model: model, backend: .automatic)
        let t0 = Date()
        try await b.startTake()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "no waiting for the accelerator")
        let v7 = await b.activeBackend
        XCTAssertEqual(v7, .exact)
        try await b.finish()
        gate.withLock { $0 = true }
        let v8 = await waitFor(b, .ready)
        XCTAssertTrue(v8)
        XCTAssertFalse(calls.withLock { $0 }.contains("golden"), "a promoted key is not golden-tested again")
        let (next, _) = try await take(b)
        XCTAssertEqual(next, .neuralEngine)
    }
}

/// The first install of a model through the updater (the CDN served from the bundled folder): the CPU set only, no
/// CoreML, keep table or self-test file; the pipeline's download stage then brings exactly those.
final class FirstInstallTests: XCTestCase {
    func testAFirstInstallFetchesNoAcceleratorFile() async throws {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        StubProtocol.reset { seen in
            let p = seen.url.path
            guard let r = p.range(of: "/sdk/v4.0/") else { return StubProtocol.Reply(status: 404) }
            guard let d = try? Data(contentsOf: server.appendingPathComponent(String(p[r.upperBound...]))) else { return StubProtocol.Reply(status: 404) }
            return StubProtocol.Reply(headers: [:], body: d)
        }
        let verifier = ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true)
        let store = ModelStore(root: Fixtures.storage(), verifier: verifier)
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: ModelHost.defaultBase, key: "k", verifier: verifier)
        let updater = ModelUpdater(store: store, client: { client }, coreML: true, networkAllowed: { _ in true })
        let out = await updater.update(.v4_0, to: "rev-1", activate: true)
        guard case .installed(let m, _) = out else { return XCTFail("\(out)") }
        let first = StubProtocol.log.withLock { $0 }.map(\.url.path)
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(first.contains { $0.contains("/coreml") || $0.contains("/selftest/") }, "\(first)")
        // by role, so a delta (coreml-delta, coreml-compact-delta) or any later Apple role fails it too
        let roles = Set(first.compactMap { p in m.manifest.files.first { p.hasSuffix("/" + $0.path) }?.role })
        XCTAssertFalse(roles.isEmpty)
        XCTAssertTrue(roles.isDisjoint(with: DownloadProfile.appleRoles.union(["selftest"])), "\(roles)")
        XCTAssertTrue(DownloadProfile.appleRoles.isSuperset(of: ["coreml-delta", "coreml-compact-delta"]))
        XCTAssertTrue(m.isUsable(context: "c16_l64"))
        XCTAssertNil(m.coreML(context: "c16_l64"), "no CoreML build before the pipeline")
        StubProtocol.log.withLock { $0 = [] }
        // the build the SDK fetches when the app names none: the fp16 one
        let r = try await updater.installAccelerator(m, context: "c16_l64")
        let later = StubProtocol.log.withLock { $0 }.map(\.url.path)
        XCTAssertTrue(later.contains { $0.contains("/coreml/tajweedformer_v4.mlmodelc/") }, "the fp16 package")
        XCTAssertTrue(later.contains { $0.hasSuffix("/coreml/c16_l64/keeps.bin") }, "the context's keep table")
        XCTAssertTrue(later.contains { $0.contains("/selftest/") })
        XCTAssertFalse(later.contains { $0.contains("/coreml-compact/") }, "nothing of the compact build: \(later)")
        XCTAssertFalse(later.contains { $0.hasSuffix("layers.zfw.gz") || $0.contains("engine.zfs") })
        XCTAssertGreaterThan(r.downloadedBytes, 0)
        let fp16 = DownloadProfile(context: "c16_l64", coreML: true)
        XCTAssertEqual(r.profileBytes, DownloadProfile.bytes(fp16.appleFiles(m.manifest)), "the fp16 profile's accelerator files")
        let files = fp16.appleFiles(m.manifest).map(\.localPath)
        XCTAssertEqual(m.adding(verified: files).coreML(context: "c16_l64")?.compact, false)
        XCTAssertNil(m.adding(verified: files).coreML(context: "c16_l64", compact: true), "the compact build is not there")
        print("v4-promotion first install: \(first.count) requests (CPU set), then \(later.count) for the accelerator")
    }
}

// MARK: real clips

/// Failover on the self-test clips through the real exact engine (TAJWEED_V4_FOLDER with `selftest/`): the CPU-only
/// run of each clip, then the same clip with the accelerator role played by the CPU-only run's own chunks (no second
/// engine stream: the engine allows one live stream per process), failing at the first, a middle and the last chunk
/// with an exception, a NaN and a timeout. Measured here: the stall (cold switch: the engine opened at the failure;
/// warm: the engine kept open), the resident memory the engine adds, and the divergence of a bounded replay.
final class FailoverRealClipTests: XCTestCase {
    /// The CPU-only run's chunks played back as an accelerator, chunk for chunk with the same pieces.
    final class Recorded: AcceleratorBackend {
        let perPush: [[HeadsBuffer]]
        let flush: [HeadsBuffer]
        var failAt: Int
        var failure: FakeAccelerator.Failure
        private var call = 0, produced = 0
        private(set) var chunkSeconds: [Double] = []

        init(perPush: [[HeadsBuffer]], flush: [HeadsBuffer], failAt: Int, failure: FakeAccelerator.Failure) {
            self.perPush = perPush; self.flush = flush; self.failAt = failAt; self.failure = failure
        }

        func reset() { call = 0; produced = 0; chunkSeconds = [] }
        func push(_ s: UnsafeBufferPointer<Float>) throws(RecognizerError) -> [HeadsBuffer] {
            let out = call < perPush.count ? perPush[call] : []
            call += 1
            return try emit(out)
        }
        func finish() throws(RecognizerError) -> [HeadsBuffer] { try emit(flush) }
        private func emit(_ cs: [HeadsBuffer]) throws(RecognizerError) -> [HeadsBuffer] {
            var out: [HeadsBuffer] = []
            for var c in cs {
                var spent = 0.001
                if produced == failAt {
                    switch failure {
                    case .exception: throw .neuralEngineUnavailable("injected")
                    case .nan: var lp = c.logProbs; lp[0] = .nan; c.logProbs = lp
                    case .hang(let s): Thread.sleep(forTimeInterval: s); spent = s
                    default: break
                    }
                }
                produced += 1
                chunkSeconds.append(spent)
                out.append(c)
            }
            return out
        }
    }

    struct Folder {
        let dir: URL
        let set: SelfTestSet
    }

    func folder() throws -> Folder {
        guard let p = ProcessInfo.processInfo.environment["TAJWEED_V4_FOLDER"] else {
            print("v4-failover real: skipped (no TAJWEED_V4_FOLDER: the model is not on this runner)")
            throw XCTSkip("set TAJWEED_V4_FOLDER")
        }
        let dir = URL(fileURLWithPath: p)
        guard let set = SelfTestSet.load(dir, context: "c16_l64") else {
            print("v4-failover real: skipped (the folder has no selftest/ set)")
            throw XCTSkip("no self-test set in TAJWEED_V4_FOLDER")
        }
        return Folder(dir: dir, set: set)
    }

    func engine(_ f: Folder) -> () throws(RecognizerError) -> any CPUStreamEngine {
        let dir = f.dir
        return { () throws(RecognizerError) -> any CPUStreamEngine in
            let e = try TajweedExactEngine(directory: dir, context: "c16_l64")
            e.setHeads(ZfHeadsAll.mask)
            return e
        }
    }

    /// Resident memory that counts against an app (phys_footprint), MB.
    static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { (p: UnsafeMutablePointer<rusage_info_v4>) -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }

    /// Drops the file cache (the CI runner's passwordless sudo), so the next open reads the weights from disk.
    static func purge() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/sbin/purge"]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    func testFailoverOnTheSelfTestClips() throws {
        let f = try folder()
        let piece = 5120
        var stalls: [String: [Double]] = ["cold": [], "warm": [], "purged": []]
        var lines: [String] = []
        for clip in f.set.clips {
            // the CPU-only run, recorded push by push
            let ref = TakeRunner(chunkMs: 320, openCPU: engine(f))
            try ref.start(accelerator: nil)
            var perPush: [[HeadsBuffer]] = []
            var at = 0
            var refHeads = HeadsBuffer()
            while at < clip.samples.count {
                let o = try ref.push(Array(clip.samples[at..<min(clip.samples.count, at + piece)])).chunks
                perPush.append(o)
                for h in o { refHeads.append(h) }
                at += piece
            }
            let flush = try ref.finish().chunks
            for h in flush { refHeads.append(h) }
            ref.closeCPU()
            let total = perPush.reduce(0) { $0 + $1.count } + flush.count
            for at in [0, total / 2, total - 1] {
                for (name, mode) in [("exception", FakeAccelerator.Failure.exception), ("nan", .nan), ("timeout", .hang(0.5))] {
                    for variant in ["cold", "warm", "purged"] where variant != "purged" || (name == "exception" && at == total / 2) {
                        if variant == "purged" && !Self.purge() { continue }
                        let r = TakeRunner(chunkMs: 320, openCPU: engine(f))
                        r.policy.deadlineMs = 200
                        // the 0.5 s timeout at the first chunk too (its own limit is 1 s), abandoned at once as in 2.0.1
                        r.policy.firstChunkMs = 200
                        r.policy.hangGraceMs = 0
                        let acc = AcceleratorExecutor(Recorded(perPush: perPush, flush: flush, failAt: at, failure: mode))
                        if variant == "warm" {
                            // the standby that was rejected (64 MB resident): the engine stays open behind the accelerator
                            try r.ensureCPU().reset()
                        }
                        let got = try runTakeKeepingCPU(r, clip.samples, accelerator: acc, piece: piece, keepCPU: variant == "warm")
                        let fo = try XCTUnwrap(r.failover, "\(clip.id) \(name) at \(at)")
                        XCTAssertEqual(got.heads.greedy, refHeads.greedy, "\(clip.id) \(name) at \(at) \(variant): every token, as on the CPU only")
                        stalls[variant, default: []].append(fo.stallMs)
                        r.closeCPU()
                    }
                }
            }
            // a bounded replay (the fewest chunks the policy allows): how far the tokens move
            for at in [total / 2, total - 1] where at >= 6 {
                let r = TakeRunner(chunkMs: 320, openCPU: engine(f))
                r.policy.maxReplayChunks = 5
                r.policy.minReplayChunks = 5
                let acc = AcceleratorExecutor(Recorded(perPush: perPush, flush: flush, failAt: at, failure: .exception))
                let got = try runTake(r, clip.samples, accelerator: acc, piece: piece)
                let d = Divergence(expected: refHeads.greedy, tokens: got.heads.greedy)
                lines.append("v4-failover real bounded: \(clip.id) fail at \(at)/\(total), replay from \(r.failover?.replayFrom ?? -1): token edits \(d.tokenEdits ?? 0)/\(d.tokensExpected ?? 0)")
                r.closeCPU()
            }
        }
        for l in lines { print(l) }
        for (k, v) in stalls.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            let s = v.sorted()
            print(String(format: "v4-failover real stall %@: n %d, median %.1f ms, p90 %.1f ms, max %.1f ms (macOS runner, whole-take replay)",
                         k, s.count, s[s.count / 2], s[min(s.count - 1, Int(Double(s.count - 1) * 0.9))], s.last!))
        }
    }

    /// The resident memory the exact engine adds (what a hot CPU standby would cost while the accelerator serves).
    func testTheCPUEngineResidentCost() throws {
        let f = try folder()
        let before = Self.footprintMB()
        var e: TajweedExactEngine? = try TajweedExactEngine(directory: f.dir, context: "c16_l64")
        let opened = Self.footprintMB()
        _ = try f.set.clips[0].samples.withUnsafeBufferPointer { (p) throws(RecognizerError) in try e!.push(p) }
        let ran = Self.footprintMB()
        e = nil
        let closed = Self.footprintMB()
        print(String(format: "v4-failover real memory: footprint %.1f MB, engine open %.1f MB (+%.1f), after a clip %.1f MB (+%.1f), closed %.1f MB (macOS runner)",
                     before, opened, opened - before, ran, ran - before, closed))
        XCTAssertGreaterThan(before, 0)
    }
}

/// Like `runTake`, but `keepCPU` keeps the CPU engine open behind the accelerator (the measured warm switch).
func runTakeKeepingCPU(_ runner: TakeRunner, _ audio: [Float], accelerator: AcceleratorExecutor?, piece: Int, keepCPU: Bool) throws -> RunResult {
    guard keepCPU else { return try runTake(runner, audio, accelerator: accelerator, piece: piece) }
    runner.policy.keepCPUOpen = true
    defer { runner.policy.keepCPUOpen = false }
    return try runTake(runner, audio, accelerator: accelerator, piece: piece)
}

enum ZfHeadsAll {
    static let mask = HeadSelection.all.engineMask
}
