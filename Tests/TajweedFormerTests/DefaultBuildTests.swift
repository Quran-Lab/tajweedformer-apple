import Foundation
import XCTest
@testable import TajweedFormer

/// Which CoreML build a device fetches and tries (SDK 3.0.0): the fp16 build (`coreml`) when a Session's backend is
/// `auto`, as in 2.x; the compact build (`coreml-compact`) only for a Session whose backend names it. Neither is tried
/// in the other's place. Through the public Client, Model and Session over a stub API and CDN that serve the bundled
/// test folder. The pipeline's download stage is the SDK's own (so the requests show what is fetched); the compile,
/// the warm-up and the golden stage are stand-ins, since the test folder's packages are not real ones.
final class DefaultBuildTests: XCTestCase {
    /// What the pipeline ran, in order: `<build> <stage>`.
    let ran = Locked<[String]>([])
    /// The builds whose golden stage finds tokens that differ from the CPU engine's.
    let differing = Locked<Set<String>>([])

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        let ran = self.ran, differing = self.differing
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
                        if differing.withLock({ $0.contains(build) }) {
                            return .failed(PromotionFailure(.goldenMismatch, "the tokens differ from the CPU engine's",
                                                            divergence: Divergence(expected: [3, 4, 5], tokens: [3, 4])))
                        }
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

    static let pipeline = ["download", "compile", "warmup", "golden"]

    /// The paths asked of the stub so far.
    static var asked: [String] { StubProtocol.seen.map(\.path) }
    static let fp16Package = "/coreml/tajweedformer_v4.mlmodelc/"
    static let compactPackage = "/coreml-compact/tajweedformer_v4.mlmodelc/"

    /// One short take on `backend`; the Backend it ended on.
    func take(_ model: TajweedModel, _ backend: TajweedSessionOptions.Backend) async throws -> TajweedBackend {
        let session = try await model.listen(from: fakeRecitation(seconds: 2), sampleRate: 16_000, options: .init(backend: backend, pace: .fast))
        for await _ in session.chunks {}
        _ = try await session.finish()
        return session.backend
    }

    /// The Model's Backend once its stage is `stage`, or what it is after `seconds`.
    func wait(_ model: TajweedModel, for stage: TajweedBackend.Stage, seconds: Double = 30) async -> TajweedBackend {
        let end = Date().addingTimeInterval(seconds)
        var b = await model.backend
        while b.stage != stage, Date() < end {
            try? await Task.sleep(nanoseconds: 50_000_000)
            b = await model.backend
        }
        return b
    }

    func record(_ model: TajweedModel, build: String) -> PromotionRecord? {
        let store = PromotionStore(dir: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"))
        return store.record(AcceleratorController.key(revision: model.folder.identity, context: "c16_l64", build: build))
    }

    /// The default, as in 2.x: `prefetch` brings the CPU set and nothing of a CoreML build; after the first take the
    /// fp16 build is fetched and goes through the pipeline, stage by stage; the compact build is neither fetched nor
    /// tried; the next take runs on `coreml`.
    func testByDefaultTheFp16BuildIsFetchedAndTriedAndTheCompactBuildIsNot() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        XCTAssertEqual(TajweedSessionOptions().backend, .auto)
        XCTAssertNil(TajweedModel.namedCompact(.auto), "a Session that names no build")
        XCTAssertNil(TajweedModel.namedCompact(.cpu))
        XCTAssertEqual(TajweedModel.namedCompact(.coremlCompact), true, "the compact build, by name")
        XCTAssertEqual(TajweedSessionOptions.Backend.coremlCompact.rawValue, "coreml-compact")
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        defer { client.close() }
        // the first download: the CPU set, whose bytes are the progress's total, whichever build follows
        let progress = Locked<(done: Int64, total: Int64)>((0, 0))
        try await client.prefetch(onProgress: { done, total in progress.withLock { $0 = (done, total) } })
        let manifest = try ModelManifest.read(Fixtures.v4mini().appendingPathComponent("server"))
        let cpu = DownloadProfile.bytes(DownloadProfile(context: "c16_l64", coreML: false).cpuFiles(manifest))
        let last = progress.withLock { $0 }
        XCTAssertEqual(last.total, cpu, "prefetch's total is the CPU set")
        XCTAssertEqual(last.done, cpu)
        XCTAssertFalse(Self.asked.contains { $0.contains("/coreml") || $0.contains("/selftest/") }, "no accelerator file in the first download")

        let model = try await client.model()
        let first = try await take(model, .auto)
        XCTAssertEqual(first.kind, .cpu, "the CPU engine first")
        let promoted = await wait(model, for: .promoted)
        XCTAssertEqual(promoted.stage, .promoted)
        XCTAssertEqual(promoted.name, "coreml")
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml " + $0 }, "the fp16 build, stage by stage, and no other build")
        let asked = Self.asked
        XCTAssertTrue(asked.contains { $0.contains(Self.fp16Package) }, "the fp16 package was fetched")
        XCTAssertTrue(asked.contains { $0.hasSuffix("/coreml/c16_l64/keeps.bin") }, "with the context's keep table")
        XCTAssertTrue(asked.contains { $0.contains("/selftest/") }, "and the self-test set")
        XCTAssertFalse(asked.contains { $0.contains(Self.compactPackage) }, "nothing of the compact build: \(asked.filter { $0.contains("coreml") })")
        XCTAssertFalse(asked.contains { $0.contains("engine.zfs") }, "no correction")
        XCTAssertEqual(record(model, build: "coreml")?.status, .ready)
        XCTAssertNil(record(model, build: "coreml-compact"), "the compact build was not tried")
        let next = try await take(model, .auto)
        XCTAssertEqual(next.kind, .accelerator)
        XCTAssertEqual(next.name, "coreml")
        await model.close()
    }

    /// The fp16 build is demoted (its tokens differ): the Session stays on the CPU engine, and in 3.0.0 the compact
    /// build is not fetched or tried in its place, however many takes follow.
    func testAfterTheFp16BuildIsDemotedTheSessionStaysOnTheCPUEngine() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        differing.withLock { $0 = ["coreml"] }
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let model = try await client.model()
        _ = try await take(model, .auto)
        let demoted = await wait(model, for: .demoted)
        XCTAssertEqual(demoted.stage, .demoted)
        XCTAssertEqual(demoted.reason, "golden_mismatch")
        XCTAssertEqual(demoted.kind, .cpu)
        for n in 0..<3 {
            let b = try await take(model, .auto)
            XCTAssertEqual(b.kind, .cpu, "take \(n + 2) runs on the CPU engine")
            XCTAssertEqual(b.name, "cpu")
        }
        // time for a pipeline to start, if one were to
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml " + $0 }, "one attempt for the fp16 build, none for the compact build")
        XCTAssertFalse(Self.asked.contains { $0.contains(Self.compactPackage) }, "nothing of the compact build was fetched")
        XCTAssertEqual(record(model, build: "coreml")?.status, .failed)
        XCTAssertEqual(record(model, build: "coreml")?.lastReason, .goldenMismatch)
        XCTAssertNil(record(model, build: "coreml-compact"), "the compact build has no record: it was never tried")
        let after = await model.backend
        XCTAssertEqual(after.stage, .demoted)
        await model.close()
    }

    /// The compact build by name: a Session with `backend: .coremlCompact` fetches it and takes it through the same
    /// pipeline; promoted, the next such take runs on `coreml-compact`. A Session that names no build still asks for
    /// the fp16 one, and gets it: both builds are then on disk, and neither install deleted the other.
    func testTheCompactBuildIsFetchedAndTriedWhenTheBackendNamesIt() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let model = try await client.model()
        let first = try await take(model, .coremlCompact)
        XCTAssertEqual(first.kind, .cpu, "the CPU engine first")
        let promoted = await wait(model, for: .promoted)
        XCTAssertEqual(promoted.stage, .promoted)
        XCTAssertEqual(promoted.name, "coreml-compact")
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml-compact " + $0 })
        var asked = Self.asked
        XCTAssertTrue(asked.contains { $0.contains(Self.compactPackage) }, "the compact package was fetched")
        XCTAssertTrue(asked.contains { $0.hasSuffix("/coreml/c16_l64/keeps.bin") })
        XCTAssertFalse(asked.contains { $0.contains(Self.fp16Package) }, "the fp16 build was not fetched for it")
        let next = try await take(model, .coremlCompact)
        XCTAssertEqual(next.kind, .accelerator)
        XCTAssertEqual(next.name, "coreml-compact")

        // a Session that names no build: the fp16 one, through its own pipeline; the compact build on disk does not
        // stand in for it
        let auto = try await take(model, .auto)
        XCTAssertEqual(auto.kind, .cpu, "the fp16 build is not promoted yet, and the compact build is not used in its place")
        let fp16 = await wait(model, for: .promoted)
        XCTAssertEqual(fp16.name, "coreml")
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml-compact " + $0 } + Self.pipeline.map { "coreml " + $0 })
        asked = Self.asked
        XCTAssertTrue(asked.contains { $0.contains(Self.fp16Package) })
        let dir = model.folder.directory
        for package in ["coreml/tajweedformer_v4.mlmodelc/model.mil", "coreml-compact/tajweedformer_v4.mlmodelc/model.mil"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(package).path), "\(package) is on disk")
        }
        XCTAssertEqual(record(model, build: "coreml")?.status, .ready)
        XCTAssertEqual(record(model, build: "coreml-compact")?.status, .ready)
        await model.close()
    }

    /// The compact build by name, demoted: the Session runs on the CPU engine, and the fp16 build is not tried in its
    /// place.
    func testTheCompactBuildByNameDemotedLeavesTheSessionOnTheCPUEngine() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        differing.withLock { $0 = ["coreml-compact"] }
        try StubbedModelServer.serve()
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let model = try await client.model()
        _ = try await take(model, .coremlCompact)
        let demoted = await wait(model, for: .demoted)
        XCTAssertEqual(demoted.stage, .demoted)
        XCTAssertEqual(demoted.reason, "golden_mismatch")
        let next = try await take(model, .coremlCompact)
        XCTAssertEqual(next.kind, .cpu)
        XCTAssertEqual(next.name, "cpu")
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml-compact " + $0 })
        XCTAssertFalse(Self.asked.contains { $0.contains(Self.fp16Package) })
        await model.close()
    }
}
