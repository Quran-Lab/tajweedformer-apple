import Foundation
import XCTest
@testable import TajweedFormer

/// Live promotion through a Session: the recognizer with the fake CPU engine and a pipeline of
/// fake stages whose build is the fake accelerator, on the synthetic test folder (opened unsigned). A take starts on the
/// CPU engine, the build becomes ready during it, and the take moves to the accelerator at a pause: the app sees
/// `backendChanged` with `fromChunk` the first accelerator chunk, each chunk names the backend that ran it, and no index
/// comes twice. With `flags.live_promotion` false the take stays on the CPU.
final class LiveSessionTests: XCTestCase {
    let gate = Locked(false)

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        let gate = self.gate
        TajweedRecognizer.stagesOverride.withLock {
            $0 = { _ in
                AcceleratorController.Stages(
                    download: { () async throws(PromotionFailure) -> Void in },
                    compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                        while !gate.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 10_000_000) }
                        let fake = FakeAccelerator()
                        fake.marker = 1
                        return UncheckedBox(fake as any AcceleratorBackend)
                    },
                    warmup: { (_: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in },
                    golden: { (_: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                        .passed(accelerator: [0.002], cpu: [0.008])
                    },
                    sessionActive: { () async -> Bool in false },
                    waitIdle: { () async -> Void in })
            }
        }
        Fixtures.configure()
        LiveDiagnosis.reset()
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        TajweedRecognizer.stagesOverride.withLock { $0 = nil }
        TajweedRecognizer.liveFlagOverride.withLock { $0 = nil }
        LiveDiagnosis.reset()
    }

    /// The synthetic test folder with its CoreML builds, opened unsigned; a skip where the promotion cannot run here.
    func model() async throws -> ModelFolder {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("no accelerator in this process (AcceleratorGate)") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tf-live-\(UUID().uuidString)")
        try fm.copyItem(at: Fixtures.v4mini().appendingPathComponent("decoded"), to: dir)
        let m: ModelFolder
        do {
            try Fixtures.manifest(for: dir).write(to: dir)
            m = try ModelFolder.open(directory: dir, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        } catch {
            throw XCTSkip("the synthetic folder does not open here: \(error)")
        }
        guard m.isUsable(context: "c16_l64"), m.coreML(context: "c16_l64") != nil else {
            throw XCTSkip("the synthetic folder has no usable c16_l64 with its CoreML build here")
        }
        // the pipeline's own conditions must hold on this machine, or no build becomes ready
        let c = await PromotionConditions.current()
        if let why = c.blocker(for: .download) { throw XCTSkip("the promotion waits here: \(why)") }
        return m
    }

    struct Seen {
        var chunks: [TajweedChunk] = []
        var events: [TajweedEvent] = []
        var backendAtEnd: ActiveBackend?
    }

    /// One take: 2 s on the CPU engine, then the build becomes ready, then the rest in pieces of 100 ms.
    func take(_ model: ModelFolder, _ audio: [Float]) async throws -> Seen {
        let r = try TajweedRecognizer(model: model, context: "c16_l64", backend: .automatic)
        try await r.startTake()
        let started = await r.activeBackend
        XCTAssertEqual(started, .exact, "the take starts on the CPU engine")
        let session = TajweedSession(recognizer: r, vocabulary: model.vocabulary, selection: HeadSelection.default.heads,
                                     options: TajweedSessionOptions(), backend: await r.backendNow, pushed: true, onEnd: {})
        let chunks = Task { () -> [TajweedChunk] in
            var out: [TajweedChunk] = []
            for await c in session.chunks { out.append(c) }
            return out
        }
        let events = Task { () -> [TajweedEvent] in
            var out: [TajweedEvent] = []
            for await e in session.events { out.append(e) }
            return out
        }
        var at = 0
        while at < 2 * 16_000 {
            try session.push(Array(audio[at..<(at + 1600)]))
            at += 1600
        }
        gate.withLock { $0 = true }
        let ready = await r.awaitReady(timeout: 20)
        XCTAssertTrue(ready, "the build is ready during the take")
        while at < audio.count {
            try session.push(Array(audio[at..<min(audio.count, at + 1600)]))
            at += 1600
            try await Task.sleep(nanoseconds: 3_000_000)
        }
        _ = try await session.finish()
        var seen = Seen()
        seen.chunks = await chunks.value
        seen.events = await events.value
        seen.backendAtEnd = await r.activeBackend
        return seen
    }

    /// 12 s of fake recitation with a pause at 8 s.
    func audio() -> [Float] {
        var a = fakeRecitation(seconds: 12)
        for i in (8 * 16_000)..<(9 * 16_000 + 3200) { a[i] = 0 }
        return a
    }

    func testATakeMovesToTheAcceleratorAtAPauseAndTheAppSeesFromChunk() async throws {
        let model = try await model()
        let seen = try await take(model, audio())
        let swaps = seen.events.compactMap { e -> (TajweedBackend, Int)? in
            if case .backendChanged(let b, let from) = e { return (b, from) }
            return nil
        }
        XCTAssertEqual(swaps.count, 1, "\(seen.events)")
        let (backend, from) = try XCTUnwrap(swaps.first)
        XCTAssertEqual(backend.kind, .accelerator)
        XCTAssertEqual(seen.chunks.map(\.index), Array(0..<seen.chunks.count), "every chunk once, in order")
        XCTAssertGreaterThan(from, 0)
        XCTAssertLessThan(from, seen.chunks.count)
        for c in seen.chunks {
            XCTAssertEqual(c.backend.kind, c.index < from ? .cpu : .accelerator, "chunk \(c.index): the backend that ran it")
        }
        // the chunk before it was a pause on the CPU engine (its last two frames blank)
        let pause = seen.chunks[from - 1].heads.buffer.top1(.logProbs).suffix(2)
        XCTAssertEqual(Array(pause), [0, 0])
        XCTAssertEqual(seen.backendAtEnd, .neuralEngine, "the take ended on the accelerator")
        let stats = LiveDiagnosis.stats.withLock { $0 }
        XCTAssertEqual(stats, .init(attempts: 1, swaps: 1, last: "swapped", lastFromChunk: from))
        print("v4-live session: swapped at chunk \(from) of \(seen.chunks.count)")
    }

    func testWithTheFlagFalseTheTakeStaysOnTheCPU() async throws {
        let model = try await model()
        TajweedRecognizer.liveFlagOverride.withLock { $0 = { .bool(false) } }
        let seen = try await take(model, audio())
        XCTAssertFalse(seen.events.contains { if case .backendChanged = $0 { return true }; return false })
        XCTAssertTrue(seen.chunks.allSatisfy { $0.backend.kind == .cpu })
        XCTAssertEqual(seen.backendAtEnd, .exact)
        XCTAssertNil(LiveDiagnosis.stats.withLock { $0 }, "no attempt started")
    }
}
