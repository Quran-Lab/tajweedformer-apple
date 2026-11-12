import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// A build whose CoreML package carries its keep table inside (SPEC 5.4, SDK 3.0.2): its manifest lists the package
/// for context `*` and no keep table, and its signed tolerance names the contexts each build serves
/// (`coreml:c16_l64`). Through the public Client, Model and Session over a stub API and CDN: the build is fetched
/// and goes through the pipeline for a context it serves, with no keep table asked for, and its record names the
/// build `coreml` or `coreml-compact`, never the tolerance key. Until 3.0.1 such a build stayed on the CPU engine
/// (probed on the 3.0.1 code: nothing of the package was fetched). Then a folder of each kind in one storage.
///
/// The manifest is the bundled test folder's, without its keep table lines, with the tolerance keyed by context,
/// signed again with the suite's test key. The pipeline's download stage is the SDK's own (so the requests show
/// what is fetched); the compile, the warm-up and the golden stage are stand-ins, as in DefaultBuildTests, since
/// the test folder's packages are not real ones. The engine's side of a one-file package is TajweedOneFilePackageTests.
final class OneFileBuildTests: XCTestCase {
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

    static let pipeline = ["download", "compile", "warmup", "golden"]
    static let fp16Package = "coreml/tajweedformer_v4.mlmodelc/"
    static let compactPackage = "coreml-compact/tajweedformer_v4.mlmodelc/"
    static let revision = "v4.0-test.onefile"

    static func verifier() -> ManifestVerifier {
        ManifestVerifier(trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation], requireSignature: true)
    }

    /// The one-file build's manifest.json: the test folder's without its two `coreml-keeps` lines, under its own
    /// revision name, with `golden_raw_tolerance` keyed `coreml:c16_l64` and `coreml-compact:c16_l64` (the folder's
    /// entries of `coreml` and `coreml-compact`; no plain key, and no key for c24_l72), signed with the suite's
    /// test key. The package lines of both builds stay as they are: context `*`.
    static func manifest() throws -> Data {
        let url = try Fixtures.v4mini().appendingPathComponent("server").appendingPathComponent("manifest.json")
        var o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try XCTUnwrap(o["files"] as? [[String: Any]])
        files.removeAll { ($0["role"] as? String) == "coreml-keeps" }
        o["files"] = files
        o["revision"] = revision
        let tolerance = try XCTUnwrap(o["golden_raw_tolerance"] as? [String: Any])
        let fp16 = try XCTUnwrap(tolerance["coreml"]), compact = try XCTUnwrap(tolerance["coreml-compact"])
        o["golden_raw_tolerance"] = ["coreml:c16_l64": fp16, "coreml-compact:c16_l64": compact] as [String: Any]
        o["signature"] = nil
        let unsigned = try ModelManifest.parse(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
        o["signature"] = try CloudFixtures.signer.signature(for: Data(unsigned.signedText().utf8)).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// Installs the stub: a healthy API whose signed config names the build of `manifest`, and a CDN that serves
    /// `manifest` as manifest.json and every other file from the bundled test folder. Returns the build id.
    @discardableResult
    static func serve(_ manifest: Data) throws -> String {
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let build = String(Manifest30VectorTests.sha256(manifest).prefix(40))
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build]), extra: { s in
            guard s.url.host == CloudFixtures.cdn.host, let at = s.path.range(of: "/sdk/v4.0/") else { return nil }
            let path = String(s.path[at.upperBound...])
            if path == "manifest.json" {
                return StubProtocol.Reply(status: 200, headers: ["content-type": "application/octet-stream"], body: manifest)
            }
            guard let data = try? Data(contentsOf: server.appendingPathComponent(path)) else {
                return StubProtocol.Reply(status: 404)
            }
            return StubProtocol.Reply(status: 200, headers: ["content-type": "application/octet-stream"], body: data)
        }))
        return build
    }

    /// The paths asked of the stub's CDN so far, after `/sdk/v4.0/`.
    static var fetched: [String] {
        StubProtocol.seen.compactMap { s -> String? in
            guard s.url.host == CloudFixtures.cdn.host, let at = s.path.range(of: "/sdk/v4.0/") else { return nil }
            return String(s.path[at.upperBound...])
        }
    }

    /// One short take in the default context on `backend`; the Backend it ended on.
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

    static func records() -> [String: PromotionRecord] {
        PromotionStore(dir: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator")).all()
    }

    /// The manifest as the SDK reads it: accepted; each build serves c16_l64 by its tolerance key and does not serve
    /// c24_l72; the golden stage's tolerance in c16_l64 is the entry under that key.
    func testTheManifestOfAOneFileBuildServesTheContextsItsToleranceNames() throws {
        let m = try ModelManifest.accept(try Self.manifest(), verifier: Self.verifier())
        XCTAssertTrue(m.files(role: "coreml-keeps").isEmpty)
        XCTAssertTrue(m.goldenRawSigned)
        for build in ["coreml", "coreml-compact"] {
            let s = try XCTUnwrap(m.serving(build: build, context: "c16_l64"), build)
            XCTAssertEqual(s.by, .tolerance, build)
            XCTAssertEqual(s.toleranceKey, "\(build):c16_l64", build)
            XCTAssertNotNil(m.rawTolerance(build: build, context: "c16_l64"), build)
            XCTAssertEqual(m.rawTolerance(build: build, context: "c16_l64"), m.rawTolerance(build: "\(build):c16_l64"), build)
            XCTAssertNil(m.rawTolerance(build: build), "\(build): no plain key")
            XCTAssertNil(m.serving(build: build, context: "c24_l72"), "\(build): no key and no keep table for c24_l72")
            XCTAssertNil(m.rawTolerance(build: build, context: "c24_l72"), build)
            let compact = build == "coreml-compact"
            let files = DownloadProfile(context: "c16_l64", coreML: true, compact: compact).appleFiles(m).map(\.path)
            XCTAssertTrue(files.contains { $0.hasPrefix(compact ? Self.compactPackage : Self.fp16Package) }, "\(build): \(files)")
            XCTAssertFalse(files.contains { $0.hasSuffix("keeps.bin") }, "\(build): \(files)")
            XCTAssertTrue(DownloadProfile(context: "c24_l72", coreML: true, compact: compact).appleFiles(m).isEmpty, build)
        }
    }

    /// With `backend: .auto`: the first download is the CPU set; after the first take the fp16 package and the
    /// self-test set are fetched, no keep table is asked for, and the build goes through the pipeline, stage by
    /// stage; its record is the record of `coreml` in c16_l64; the next take runs on `coreml`, and `diagnose()` says
    /// so. The folder, opened again as a later launch opens it, has the build for c16_l64 without a keep table and
    /// no build for c24_l72.
    func testAOneFileBuildIsFetchedAndPromotedWithoutAKeepTable() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        let build = try Self.serve(try Self.manifest())
        let client = try StubbedModelServer.client()
        defer { client.close() }
        try await client.prefetch()
        XCTAssertFalse(Self.fetched.contains { $0.hasPrefix("coreml") || $0.hasPrefix("selftest/") }, "no accelerator file in the first download")
        let model = try await client.model()
        XCTAssertEqual(model.folder.manifest.build, build)
        XCTAssertTrue(model.folder.manifest.files(role: "coreml-keeps").isEmpty, "the build lists no keep table")

        let first = try await take(model, .auto)
        XCTAssertEqual(first.kind, .cpu, "the CPU engine first")
        let promoted = await wait(model, for: .promoted)
        XCTAssertEqual(promoted, TajweedBackend(kind: .accelerator, name: "coreml", stage: .promoted, reason: nil))
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml " + $0 }, "the fp16 build, stage by stage, and no other build")
        let fetched = Self.fetched
        XCTAssertTrue(fetched.contains { $0.hasPrefix(Self.fp16Package) }, "the fp16 package was fetched: \(fetched)")
        XCTAssertTrue(fetched.contains { $0.hasPrefix("selftest/") }, "and the self-test set")
        XCTAssertFalse(fetched.contains { $0.hasSuffix("keeps.bin") }, "no keep table was asked for: \(fetched)")
        XCTAssertFalse(fetched.contains { $0.hasPrefix(Self.compactPackage) }, "nothing of the compact build")

        // the record: the build is `coreml`, the context its own field of the key; no record under the tolerance key
        let records = Self.records()
        let key = AcceleratorController.key(revision: model.folder.identity, context: "c16_l64", build: "coreml")
        XCTAssertEqual(records[key]?.status, .ready, "\(records.keys.sorted())")
        XCTAssertEqual(records.count, 1, "\(records.keys.sorted())")
        XCTAssertFalse(records.keys.contains { $0.contains("coreml:c16_l64") }, "\(records.keys.sorted())")

        let next = try await take(model, .auto)
        XCTAssertEqual(next, TajweedBackend(kind: .accelerator, name: "coreml", stage: .promoted, reason: nil))
        let d = await client.diagnose()
        XCTAssertEqual(d.context, "c16_l64")
        XCTAssertEqual(d.backend, TajweedBackend(kind: .accelerator, name: "coreml", stage: .promoted, reason: nil))

        let directory = model.folder.directory
        await model.close()
        let reopened = try ModelFolder.open(directory: directory, verifier: Self.verifier())
        let fp16 = try XCTUnwrap(reopened.coreML(context: "c16_l64", compact: false), "the build is on disk and verified")
        XCTAssertNil(fp16.keeps, "a build without a keep table")
        XCTAssertEqual(fp16.frontFunction, "front_c16_l64")
        XCTAssertNil(reopened.coreML(context: "c16_l64", compact: true), "the compact build was not fetched")
        XCTAssertNil(reopened.coreML(context: "c24_l72"), "c24_l72 is not served: the CPU engine")
        XCTAssertFalse(TajweedRecognizer.mayUseAccelerator(requested: .automatic, model: reopened, context: "c24_l72"))
        XCTAssertTrue(TajweedRecognizer.mayUseAccelerator(requested: .automatic, model: reopened, context: "c16_l64"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("coreml/c16_l64").path), "no keep table folder on disk")
    }

    /// The compact build by name: fetched and promoted the same way, under the record of `coreml-compact`.
    func testTheCompactOneFileBuildIsFetchedWhenTheBackendNamesIt() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs iOS 18 / macOS 15") }
        try Self.serve(try Self.manifest())
        let client = try StubbedModelServer.client()
        defer { client.close() }
        let model = try await client.model()
        let first = try await take(model, .coremlCompact)
        XCTAssertEqual(first.kind, .cpu, "the CPU engine first")
        let promoted = await wait(model, for: .promoted)
        XCTAssertEqual(promoted, TajweedBackend(kind: .accelerator, name: "coreml-compact", stage: .promoted, reason: nil))
        XCTAssertEqual(ran.withLock { $0 }, Self.pipeline.map { "coreml-compact " + $0 })
        let fetched = Self.fetched
        XCTAssertTrue(fetched.contains { $0.hasPrefix(Self.compactPackage) }, "\(fetched)")
        XCTAssertFalse(fetched.contains { $0.hasPrefix(Self.fp16Package) }, "the fp16 build was not fetched for it")
        XCTAssertFalse(fetched.contains { $0.hasSuffix("keeps.bin") }, "no keep table was asked for")
        let key = AcceleratorController.key(revision: model.folder.identity, context: "c16_l64", build: "coreml-compact")
        XCTAssertEqual(Self.records()[key]?.status, .ready)
        let next = try await take(model, .coremlCompact)
        XCTAssertEqual(next.name, "coreml-compact")
        await model.close()
    }

    /// Both kinds of build side by side in one storage, as on a device that holds a build with keep tables and a
    /// one-file build: each folder opens and hands out its own build for c16_l64 (one with its keep table, one
    /// without), installing the second leaves the first untouched, and each has its own promotion record, read back
    /// as the Backend a Session would get.
    func testAFolderOfEachKindSideBySideInOneStorage() async throws {
        let storage = CloudFixtures.storage()
        Fixtures.configure(storage: storage)
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let models = storage.appendingPathComponent("models/v4.0")
        let installer = ModelInstaller(source: DirectoryFileSource(root: server), rangeSize: 64 << 10)

        // the build with keep tables: the test folder as it is
        let tableVerifier = ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true)
        let tableManifest = try ModelManifest.accept(Data(contentsOf: server.appendingPathComponent("manifest.json")), verifier: tableVerifier)
        let tableDir = models.appendingPathComponent(tableManifest.revision)
        let r1 = try await installer.install(tableManifest, profile: DownloadProfile(context: "c16_l64", coreML: true), into: tableDir)
        XCTAssertNil(r1.appleUnavailable)
        let keeps = tableDir.appendingPathComponent("coreml/c16_l64/keeps.bin")
        let keepsBefore = try Data(contentsOf: keeps)

        // the one-file build, next to it
        let oneManifest = try ModelManifest.accept(try Self.manifest(), verifier: Self.verifier())
        XCTAssertNotEqual(oneManifest.revision, tableManifest.revision)
        XCTAssertNotEqual(oneManifest.build, tableManifest.build)
        let oneDir = models.appendingPathComponent(oneManifest.revision)
        let r2 = try await installer.install(oneManifest, profile: DownloadProfile(context: "c16_l64", coreML: true), into: oneDir)
        XCTAssertNil(r2.appleUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oneDir.appendingPathComponent("coreml/c16_l64").path), "no keep table was installed")
        XCTAssertEqual(try Data(contentsOf: keeps), keepsBefore, "the other build's keep table is untouched")

        let table = try ModelFolder.open(directory: tableDir, verifier: tableVerifier)
        let one = try ModelFolder.open(directory: oneDir, verifier: Self.verifier())
        let tableBuild = try XCTUnwrap(table.coreML(context: "c16_l64", compact: false))
        let oneBuild = try XCTUnwrap(one.coreML(context: "c16_l64", compact: false))
        XCTAssertEqual(tableBuild.keeps?.path, keeps.path, "the build with keep tables hands out its keep table")
        XCTAssertNil(oneBuild.keeps, "the one-file build has none")
        XCTAssertNotEqual(tableBuild.package, oneBuild.package)
        XCTAssertEqual(table.manifest.serving(build: "coreml", context: "c16_l64")?.by, .keepTable)
        XCTAssertEqual(one.manifest.serving(build: "coreml", context: "c16_l64")?.by, .tolerance)
        XCTAssertNil(table.coreML(context: "c24_l72"), "c24_l72 of the first build is served, and its keep table is not installed")
        XCTAssertNil(one.coreML(context: "c24_l72"), "c24_l72 of the one-file build is not served")

        // one promotion store, a record per build
        let store = PromotionStore(dir: storage.appendingPathComponent("accelerator"))
        for folder in [table, one] {
            var record = PromotionRecord(key: AcceleratorController.key(revision: folder.identity, context: "c16_l64", build: "coreml"))
            record.status = .ready
            record.completed = .promote
            store.save(record)
        }
        XCTAssertEqual(store.all().count, 2, "\(store.all().keys.sorted())")
        if DownloadProfile.osRunsCoreML {
            let promoted = TajweedBackend(kind: .accelerator, name: "coreml", stage: .promoted, reason: nil)
            XCTAssertEqual(TajweedClient.storedBackend(table, context: "c16_l64"), promoted, "the build with keep tables")
            XCTAssertEqual(TajweedClient.storedBackend(one, context: "c16_l64"), promoted, "the one-file build")
            XCTAssertEqual(TajweedClient.storedBackend(one, context: "c24_l72"), .cpu, "a context the one-file build does not serve")
        }
    }
}
