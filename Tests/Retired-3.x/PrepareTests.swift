import Foundation
import XCTest
@testable import TajweedFormer

/// `model.prepare(options:)` (3.1.5): the engine for a Session's own options is warmed ahead of its first take, so
/// that take starts on the Neural Engine where the device has one. Through the public Client, Model and Session
/// over a stub API and CDN that serve the bundled test folder. Stand-ins: the CPU engine, and the pipeline's
/// compile, warm-up and golden stages (the test folder's packages are not real ones); the download stage is the
/// SDK's own. No real CoreML package is loaded here, so what these tests show is the order of things, not a speed.
final class PrepareTests: XCTestCase {
    /// What the pipeline ran, in order: `<build> <stage>`.
    let ran = Locked<[String]>([])

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        let ran = self.ran
        TajweedRecognizer.stagesOverride.withLock {
            $0 = { recognizer in
                let real = recognizer.makeStages()
                let build = recognizer.buildKey
                return AcceleratorController.Stages(
                    download: { () async throws(PromotionFailure) -> Void in
                        ran.withLock { $0.append("\(build) download") }
                        try await real.download()
                    },
                    compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                        ran.withLock { $0.append("\(build) compile") }
                        return UncheckedBox(FakeAccelerator() as any AcceleratorBackend)
                    },
                    warmup: { (_: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in
                        ran.withLock { $0.append("\(build) warmup") }
                    },
                    golden: { (_: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                        ran.withLock { $0.append("\(build) golden") }
                        return .passed(accelerator: [0.002], cpu: [0.008], measures: Divergence(expected: [3, 4, 5], tokens: [3, 4, 5]))
                    },
                    sessionActive: { () async -> Bool in false },
                    waitIdle: { () async -> Void in })
            }
        }
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        TajweedRecognizer.stagesOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// An app's own options: the default context with its own heads (another engine than the default Session's).
    static let own = TajweedSessionOptions(heads: ["log_probs", "gem"], pace: .fast)

    /// One short take with `options`; the Backend it started on.
    func take(_ model: TajweedModel, _ options: TajweedSessionOptions) async throws -> TajweedBackend {
        var o = options
        o.pace = .fast
        let session = try await model.listen(from: fakeRecitation(seconds: 2), sampleRate: 16_000, options: o)
        let started = session.backend
        for await _ in session.chunks {}
        _ = try await session.finish()
        return started
    }

    /// Without `prepare`: the first take with the app's own options starts on the CPU engine (the engine for them
    /// is made when the take opens). With `prepare` first: it starts on the accelerator. A second `prepare` with
    /// the same options is no second warm-up. A Session with other options still runs; what it starts on is not
    /// claimed.
    func testAfterPrepareTheFirstTakeWithTheSameOptionsStartsOnTheAccelerator() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        // the control: no prepare
        try StubbedModelServer.serve()
        let plain = try StubbedModelServer.client()
        let unprepared = try await plain.model()
        let cold = try await take(unprepared, Self.own)
        XCTAssertEqual(cold.kind, .cpu, "without prepare the first take with its own options starts on the CPU engine")
        // this device has an accelerator for them: the promotion that follows the take makes the next take use it
        let end = Date().addingTimeInterval(30)
        var later = await unprepared.backend
        while later.stage != .promoted, Date() < end {
            try await Task.sleep(nanoseconds: 50_000_000)
            later = await unprepared.backend
        }
        XCTAssertEqual(later.kind, .accelerator, "the control's own promotion finished: \(later)")
        await unprepared.close()
        plain.close()
        ran.withLock { $0 = [] }

        // with prepare
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let model = try await client.model()
        let prepared = try await model.prepare(options: Self.own)
        XCTAssertEqual(prepared.kind, .accelerator, "\(prepared)")
        XCTAssertEqual(prepared.name, "coreml")
        XCTAssertEqual(prepared.stage, .promoted)
        XCTAssertEqual(ran.withLock { $0 }, ["coreml download", "coreml compile", "coreml warmup", "coreml golden"], "one promotion, stage by stage")
        let enginesAfterPrepare = FakeCPUEngine.opened.withLock { $0 }
        // twice is one warm-up: the same engine, no second promotion
        let again = try await model.prepare(options: Self.own)
        XCTAssertEqual(again, prepared)
        XCTAssertEqual(ran.withLock { $0 }.count, 4, "no stage ran a second time")
        XCTAssertEqual(FakeCPUEngine.opened.withLock { $0 }, enginesAfterPrepare, "no second engine was opened")
        // the first take with the same options
        let first = try await take(model, Self.own)
        XCTAssertEqual(first.kind, .accelerator, "the first take with the prepared options starts on the accelerator")
        XCTAssertEqual(first.name, "coreml")
        // a Session with other options runs as before; what it starts on is not claimed
        let other = try await take(model, TajweedSessionOptions(heads: ["log_probs"]))
        print("a Session with other options after prepare started on: \(other)")
        await model.close()
    }

    /// Where no accelerator applies, `prepare` returns at once with the CPU engine and starts no promotion: a
    /// Session that names the CPU engine, and an install whose accelerator is switched off (the stand-in here for
    /// a device without one).
    func testWithoutAnAcceleratorPrepareReturnsAtOnceWithTheCPUEngine() async throws {
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        let model = try await client.model()
        var started = Date()
        let named = try await model.prepare(options: TajweedSessionOptions(heads: ["log_probs", "gem"], backend: .cpu))
        XCTAssertEqual(named.kind, .cpu)
        XCTAssertEqual(named.name, "cpu")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "at once")
        let onCPU = try await take(model, TajweedSessionOptions(heads: ["log_probs", "gem"], backend: .cpu))
        XCTAssertEqual(onCPU.kind, .cpu)
        await model.close()
        client.close()
        ran.withLock { $0 = [] }

        // an install with the accelerator off
        try StubbedModelServer.serve()
        let storage = CloudFixtures.storage()
        var made = CloudFixtures.options(signingKeys: [CloudFixtures.signer.publicKey.rawRepresentation, try Fixtures.v4miniKey()], storage: storage)
        made.neuralEngine = false
        let options = made
        let off = try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
            CloudFixtures.cloud(storage: root, options: options)
        })
        defer { off.close() }
        let cpuOnly = try await off.model()
        started = Date()
        let backend = try await cpuOnly.prepare(options: Self.own)
        XCTAssertEqual(backend.kind, .cpu)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "at once")
        XCTAssertEqual(ran.withLock { $0 }, [], "no promotion on an install without an accelerator")
        let take = try await take(cpuOnly, Self.own)
        XCTAssertEqual(take.kind, .cpu)
        await cpuOnly.close()
    }

    /// The options are checked as a Session's are, and `prepare` is for the time before a take.
    func testPrepareChecksItsOptionsAndRefusesWhileASessionIsOpen() async throws {
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let model = try await client.model()
        func code(_ options: TajweedSessionOptions) async -> String? {
            do throws(TajweedError) { _ = try await model.prepare(options: options); return nil } catch { return error.code }
        }
        let badHead = await code(TajweedSessionOptions(heads: ["not_a_head"]))
        XCTAssertEqual(badHead, "invalid_argument")
        let noHead = await code(TajweedSessionOptions(heads: []))
        XCTAssertEqual(noHead, "invalid_argument")
        let badContext = await code(TajweedSessionOptions(context: "c99_l1"))
        XCTAssertEqual(badContext, "invalid_argument")
        // while a Session is open
        let session = try await model.session(options: TajweedSessionOptions(backend: .cpu))
        let busy = await code(TajweedSessionOptions(backend: .cpu))
        XCTAssertEqual(busy, "session_open")
        await session.cancel()
        let free = await code(TajweedSessionOptions(backend: .cpu))
        XCTAssertNil(free, "after the take")
        await model.close()
        let closed = await code(TajweedSessionOptions(backend: .cpu))
        XCTAssertEqual(closed, "model_missing")
    }
}
