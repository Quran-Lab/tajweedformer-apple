// Debug builds only: the Core's stand-in (StagingHooks.core, NoWaitHarness) is not in a release build.
#if DEBUG
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract 38.3 and 38.5 on the Client, with the stub server and the Core's stand-in of NoWaitTests: the
/// owed record a download writes before its first request and keeps when it is cut, and the resume at the next Client's
/// start with no call of the app (38.10 items 1 and 2 in the stub's terms; on a device with throttle_server.py they wait
/// for the Mac). The start's resume is run here by the test (`QuranLabCloud.resumeOwed`), as ClientStartTests run the
/// launch.
final class ContinuityResumeTests: XCTestCase {
    static let weights = "layers.zfw.qle"

    override func tearDown() { NoWaitHarness.tearDown() }

    /// The server of NoWaitHarness, its weights stalling after `cut` bytes (a transfer the process's end will cut), and
    /// every file under the ETag `etag`.
    static func serve(_ build: (data: Data, build: String, manifest: ModelManifest), stallAfter cut: Int? = nil, etag: String = "\"one\"",
                      stalling: String = ContinuityResumeTests.weights) {
        let config = CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build.build])
        let first = Locked(true)
        let routes = CloudFixtures.server(config: config, extra: { (s: StubProtocol.Seen) -> StubProtocol.Reply? in
            guard let p = TwoContextBuild.path(s) else { return nil }
            if p == ModelManifest.fileName { return StubProtocol.Reply(status: 200, headers: ["content-type": "application/json"], body: build.data) }
            guard let d = TwoContextBuild.data(p) else { return StubProtocol.Reply(status: 404) }
            var reply = ModelDownloadTests.served(s, data: d, etag: etag)
            if p == stalling, let cut, first.withLock({ (f: inout Bool) -> Bool in defer { f = false }; return f }) { reply.stallAfter = cut }
            return reply
        })
        StubProtocol.reset(routes)
    }

    /// The model requests the stub got: stored path, Range and If-Range.
    static func asked() -> [(path: String, range: String?, ifRange: String?)] {
        StubProtocol.seen.compactMap { s in TwoContextBuild.path(s).map { ($0, s.headers["range"], s.headers["if-range"]) } }
    }

    /// A first Client whose `model()` is cut 40 % into the weights (the process ends: its call is cancelled, which
    /// ends that download, and the Client closed while the transfer stalls). The storage, the build and the bytes kept.
    func cutFirstInstall() async throws -> (storage: URL, build: (data: Data, build: String, manifest: ModelManifest), cut: Int) {
        NoWaitHarness.setUp(connection: .unmetered)
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest()
        let cut = 968
        Self.serve(build, stallAfter: cut)
        let first = try NoWaitHarness.client(storage)
        let call = Task { _ = try? await first.model() }
        let part = storage.appendingPathComponent("models/v4.0/.download-\(build.build)/\(Self.weights).part")
        // the weights' request in flight, its first bytes in (they reach the partial file when the transfer ends)
        let end = Date().addingTimeInterval(20)
        while !Self.asked().contains(where: { $0.path == Self.weights }), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        call.cancel()
        _ = await call.value
        first.close()
        // 38.3: the owed record stays through the cancel and the close, with the manifest and the folder
        let owed = OwedDownloads.all(root: storage.appendingPathComponent("models"))
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.kind, "first_install")
        XCTAssertEqual(owed.first?.by, "app")
        XCTAssertEqual(owed.first?.build, build.build)
        XCTAssertNotNil(owed.first?.manifest, "the signed manifest, kept to resume")
        XCTAssertNotNil(owed.first?.base, "the folder the lease named")
        XCTAssertEqual(ModelInstaller.sizeOnDisk(part), Int64(cut), "the kept bytes stay")
        return (storage, build, cut)
    }

    /// 38.10 item 1: a new Client, with no call of the app, resumes the owed download at its start: no manifest is
    /// fetched again, the weights' first request is from the kept byte with If-Range, no byte is fetched twice, the build
    /// is put in place and the owed record goes.
    func testTheNextStartResumesACutDownloadWithNoCallOfTheApp() async throws {
        let (storage, build, cut) = try await cutFirstInstall()
        StubProtocol.reset { _ in .down }
        Self.serve(build)
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        await cloud.resumeOwed()
        let asked = Self.asked()
        XCTAssertFalse(asked.contains { $0.path == ModelManifest.fileName }, "the manifest is the record's, not fetched again: \(asked)")
        let w = asked.filter { $0.path == Self.weights }
        XCTAssertEqual(w.count, 1, "the weights once: \(asked)")
        XCTAssertEqual(w.first?.range, "bytes=\(cut)-", "from the kept byte")
        XCTAssertEqual(w.first?.ifRange, "\"one\"", "with the validator, to the host that gave it")
        XCTAssertEqual(cloud.store.currentRevision(.v4_0), build.manifest.revision, "the build is in place")
        XCTAssertEqual(OwedDownloads.all(root: storage.appendingPathComponent("models")), [], "the record goes once the download ended ready")
        // 38.8: counted as resumed by the start
        let day = try XCTUnwrap(cloud.analytics.pending.first)
        let entry = try XCTUnwrap(day.downloads.values.first { $0.success == 1 })
        XCTAssertEqual(entry.continued, ["start": 1])
        XCTAssertNil(entry.resumedKB, "968 bytes are under a kB: left out")
        XCTAssertEqual(entry.resumeMs?.reduce(0, +), 1, "resume_ms, once")
    }

    /// 38.10 item 2: the same with the file changed on the server (another ETag): one 200, the file whole, and
    /// `restarted.validator` 1.
    func testAChangedFileComesWholeOnceAndIsCountedAsRestarted() async throws {
        let (storage, build, cut) = try await cutFirstInstall()
        StubProtocol.reset { _ in .down }
        Self.serve(build, etag: "\"two\"")
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        await cloud.resumeOwed()
        let w = Self.asked().filter { $0.path == Self.weights }
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.first?.range, "bytes=\(cut)-")
        XCTAssertEqual(w.first?.ifRange, "\"one\"")
        XCTAssertEqual(cloud.store.currentRevision(.v4_0), build.manifest.revision)
        let day = try XCTUnwrap(cloud.analytics.pending.first)
        let entry = try XCTUnwrap(day.downloads.values.first { $0.success == 1 })
        XCTAssertEqual(entry.restarted, ["validator": 1])
    }

    /// The Core's stand-in of NoWaitHarness with no lease in force, whose lease answer waits until `release` is true and
    /// then is `answer` (a lease of the build's folder by default). Told each time the lease is asked.
    static func leaseHeld(release: Locked<Bool>, asked: Locked<Int>,
                          answer: @escaping @Sendable (ModelManifest) throws -> LeaseRecord = { m in try ContinuityResumeTests.lease(m) }) {
        var core = NoWaitHarness.core()
        core.lease = { (m: ModelManifest) async throws -> LeaseRecord in
            asked.withLock { $0 += 1 }
            while !release.withLock({ $0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
            return try answer(m)
        }
        StagingHooks.core.withLock { $0 = core }
    }

    /// A lease of the build, its model folder `folder` (the build's own by default).
    static func lease(_ m: ModelManifest, folder: String? = nil) throws -> LeaseRecord {
        let now = Int64(Date().timeIntervalSince1970)
        return LeaseRecord(build: m.build, base: "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/\(folder ?? m.build)/sdk/v4.0/",
                           expiresAt: now + 30 * 86_400, refreshAfter: now + 20 * 86_400)
    }

    /// Waits up to 10 s for `done`.
    static func until(_ done: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !done(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// 38.5 item 2 (vector `lease_asked_beside`): with no lease in force, the start's resume asks the lease beside its first
    /// request, never before it: the weights' request from the kept byte, to the folder the record's earlier answer named,
    /// goes out while the lease is unanswered, and the Core installs nothing until the answer. The answer names the same
    /// folder: the download ends ready from those bytes.
    func testWithNoLeaseInForceTheLeaseIsAskedBesideTheFirstRequest() async throws {
        let (storage, build, cut) = try await cutFirstInstall()
        StubProtocol.reset { _ in .down }
        Self.serve(build)
        let release = Locked(false), asked = Locked(0)
        Self.leaseHeld(release: release, asked: asked)
        let installedBefore = NoWaitHarness.installed.withLock { $0 }
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let resume = Task { await cloud.resumeOwed() }
        try await Self.until { Self.asked().contains { $0.path == Self.weights } }
        let w = Self.asked().filter { $0.path == Self.weights }
        XCTAssertEqual(w.first?.range, "bytes=\(cut)-", "the weights from the kept byte, before the lease's answer")
        XCTAssertEqual(w.first?.ifRange, "\"one\"")
        XCTAssertEqual(asked.withLock { $0 }, 1, "the lease is asked beside it")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(NoWaitHarness.installed.withLock { $0 }, installedBefore, "the Core installs nothing before the lease's answer")
        release.withLock { $0 = true }
        await resume.value
        XCTAssertEqual(cloud.store.currentRevision(.v4_0), build.manifest.revision, "the build is in place")
        XCTAssertEqual(Self.asked().filter { $0.path == Self.weights }.count, 1, "no byte asked twice")
        XCTAssertEqual(OwedDownloads.all(root: storage.appendingPathComponent("models")), [])
    }

    /// 38.6 (vector `lease` confirmed, other_folder): the lease asked beside names another folder. The download from the
    /// earlier folder stops and keeps its bytes (an answer named their folder before), and the rest comes from the
    /// answer's folder, from the bytes on disk.
    func testALeaseBesideThatNamesAnotherFolderSendsTheRestThere() async throws {
        let (storage, build, _) = try await cutFirstInstall()
        StubProtocol.reset { _ in .down }
        // the weights stall again on the earlier folder after 500 more bytes, so the answer finds the transfer on its way
        Self.serve(build, stallAfter: 500)
        let release = Locked(false), asked = Locked(0)
        Self.leaseHeld(release: release, asked: asked) { m in try Self.lease(m, folder: "moved") }
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let resume = Task { await cloud.resumeOwed() }
        let weightsAt = { (folder: String) -> [StubProtocol.Seen] in
            StubProtocol.seen.filter { TwoContextBuild.path($0) == Self.weights && $0.url.path.contains("/tajweedformer-v4/\(folder)/") }
        }
        try await Self.until { !weightsAt(build.build).isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        let part = storage.appendingPathComponent("models/v4.0/.download-\(build.build)/\(Self.weights).part")
        release.withLock { $0 = true }
        await resume.value
        XCTAssertEqual(weightsAt(build.build).count, 1, "the earlier folder once, before the answer")
        let moved = weightsAt("moved")
        XCTAssertEqual(moved.count, 1, "the rest from the answer's folder: \(Self.asked())")
        let from = moved.first?.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
        XCTAssertGreaterThan(from, 968, "from the bytes kept, those of the earlier folder included")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(cloud.store.currentRevision(.v4_0), build.manifest.revision, "the build is in place")
    }

    /// 38.6 (vector `lease` confirmed, refused): the lease asked beside is refused. The download stops, the bytes it
    /// fetched stay with the record, and nothing is installed.
    func testARefusedLeaseBesideKeepsTheBytes() async throws {
        let (storage, build, cut) = try await cutFirstInstall()
        StubProtocol.reset { _ in .down }
        Self.serve(build, stallAfter: 500)
        let release = Locked(false), asked = Locked(0)
        Self.leaseHeld(release: release, asked: asked) { _ in
            throw RecognizerError.serverRejected(status: 403, code: "lease_attestation_required", message: "not attested")
        }
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let resume = Task { await cloud.resumeOwed() }
        try await Self.until { Self.asked().contains { $0.path == Self.weights } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let part = storage.appendingPathComponent("models/v4.0/.download-\(build.build)/\(Self.weights).part")
        release.withLock { $0 = true }
        await resume.value
        XCTAssertNil(cloud.store.currentRevision(.v4_0), "nothing in place")
        XCTAssertGreaterThan(ModelInstaller.sizeOnDisk(part), Int64(cut), "the bytes fetched beside the lease stay")
        XCTAssertEqual(OwedDownloads.all(root: storage.appendingPathComponent("models")).count, 1, "and the record")
    }

    /// A file of the build in use cut by `call` on its way: the call runs until the file's request is in flight, then it is
    /// cancelled and the Client closed (the process ends). The folder of the build in use.
    func cutInBuild(_ build: (data: Data, build: String, manifest: ModelManifest), _ storage: URL, path: String, after cut: Int,
                    _ call: @escaping @Sendable (QuranLabCloud, ModelFolder) async throws -> Void) async throws -> ModelFolder {
        Self.serve(build, stallAfter: cut, stalling: path)
        let first = try NoWaitHarness.client(storage)
        try await first.prefetch()
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let installed = try await ModelStore.standard.resolve(.v4_0, sources: [.cache], context: nil)
        let running = Task { try await call(cloud, installed) }
        try await Self.until { Self.asked().contains { $0.path == path } }
        try await Task.sleep(nanoseconds: 300_000_000)
        running.cancel()
        _ = try? await running.value
        first.close()
        XCTAssertEqual(ModelInstaller.sizeOnDisk(installed.directory.appendingPathComponent(path + ".part")), Int64(cut), "the kept bytes stay")
        return installed
    }

    /// 38.3 and 38.5 for the Core ML build: its download writes an owed record (`accelerator`, by the SDK) before its first
    /// request and keeps it when cut; the next Client's start goes on with it into the build in use, from the kept byte,
    /// with no stage of the promotion (and none of its backoff), and the record goes once the build is in.
    func testACutCoreMLBuildIsResumedAtTheNextStart() async throws {
        // the Simulator (and an OS below the Core ML floor) fetches no Core ML build: AcceleratorGate
        try XCTSkipUnless(DownloadProfile.osRunsCoreML, "no Core ML build is fetched here (AcceleratorGate)")
        NoWaitHarness.setUp(connection: .unmetered)
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest(accelerator: true)
        let coreml = TwoContextBuild.acceleratorFiles[0].path
        let installed = try await cutInBuild(build, storage, path: coreml, after: 600) { cloud, folder in
            guard cloud.updater.coreML else { return }
            _ = try await cloud.updater.installAccelerator(folder, context: "c16_l64")
        }
        let root = storage.appendingPathComponent("models")
        let owed = OwedDownloads.all(root: root)
        XCTAssertEqual(owed.map(\.kind), ["accelerator"])
        XCTAssertEqual(owed.first?.by, "sdk")
        XCTAssertEqual(owed.first?.build, installed.identity)
        StubProtocol.reset { _ in .down }
        Self.serve(build)
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let again = try XCTUnwrap(QuranLab.cloud)
        await again.resumeOwed()
        let asked = Self.asked().filter { $0.path == coreml }
        XCTAssertEqual(asked.map(\.range), ["bytes=600-"], "from the kept byte, with no call of the app")
        XCTAssertTrue(NoWaitHarness.installed.withLock { $0 }.contains(coreml), "the Core ML build is in")
        XCTAssertEqual(OwedDownloads.all(root: root), [], "and its record gone")
    }

    /// The Core ML build's record waits for the promotion's own verdicts: a build this device has failed for good is not
    /// fetched again at the start, and its record ends.
    func testACoreMLBuildThisDeviceFailedIsNotResumed() async throws {
        // the Simulator (and an OS below the Core ML floor) fetches no Core ML build: AcceleratorGate
        try XCTSkipUnless(DownloadProfile.osRunsCoreML, "no Core ML build is fetched here (AcceleratorGate)")
        NoWaitHarness.setUp(connection: .unmetered)
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest(accelerator: true)
        let coreml = TwoContextBuild.acceleratorFiles[0].path
        let installed = try await cutInBuild(build, storage, path: coreml, after: 600) { cloud, folder in
            guard cloud.updater.coreML else { return }
            _ = try await cloud.updater.installAccelerator(folder, context: "c16_l64")
        }
        let root = storage.appendingPathComponent("models")
        XCTAssertEqual(OwedDownloads.all(root: root).map(\.kind), ["accelerator"])
        let key = AcceleratorController.key(revision: installed.identity, context: "c16_l64", build: "coreml",
                                            program: AcceleratorController.programKey(installed.manifest, context: "c16_l64", compact: false))
        var verdict = PromotionRecord(key: key)
        verdict.status = .failed
        PromotionStore(dir: storage.appendingPathComponent("accelerator")).save(verdict)
        StubProtocol.reset { _ in .down }
        Self.serve(build)
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let again = try XCTUnwrap(QuranLab.cloud)
        await again.resumeOwed()
        XCTAssertEqual(Self.asked().filter { $0.path == coreml }.count, 0, "nothing asked for a build this device failed")
        XCTAssertEqual(OwedDownloads.all(root: root), [], "and its record ends")
    }

    /// 38.3 and 38.5 for the reference table: the same, its record by the app.
    func testACutReferenceTableIsResumedAtTheNextStart() async throws {
        NoWaitHarness.setUp(connection: .unmetered)
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest(reference: true)
        let table = TwoContextBuild.referenceFile.path
        let installed = try await cutInBuild(build, storage, path: table, after: 500) { cloud, folder in
            guard let file = folder.referenceFile else { return }
            try await cloud.updater.install(file, of: folder)
        }
        let root = storage.appendingPathComponent("models")
        let owed = OwedDownloads.all(root: root)
        XCTAssertEqual(owed.map(\.kind), ["reference"])
        XCTAssertEqual(owed.first?.by, "app")
        XCTAssertEqual(owed.first?.build, installed.identity)
        StubProtocol.reset { _ in .down }
        Self.serve(build)
        let second = try NoWaitHarness.client(storage)
        defer { second.close() }
        let again = try XCTUnwrap(QuranLab.cloud)
        await again.resumeOwed()
        XCTAssertEqual(Self.asked().filter { $0.path == table }.map(\.range), ["bytes=500-"], "from the kept byte, with no call of the app")
        XCTAssertTrue(NoWaitHarness.installed.withLock { $0 }.contains(table), "the table is in")
        XCTAssertEqual(OwedDownloads.all(root: root), [], "and its record gone")
    }

    /// 38.4 for another context (to 4.0.4 it stayed in the foreground): while the app is away, its file goes to the
    /// background session (a stand-in here), into the build in use, and no foreground request is made for it.
    func testAnotherContextsFileGoesToTheBackgroundWhileTheAppIsAway() async throws {
        NoWaitHarness.setUp(connection: .unmetered)
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest()
        Self.serve(build)
        let standIn = BackgroundDownloadTests.StandIn()
        standIn.answer { range in
            guard let d = TwoContextBuild.data(range.path), Int(range.upper) < d.count else { return .init(status: 404) }
            return .init(body: d.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }
        standIn.deliver(to: RangeDelivery.Sink(storage: storage, refused: { _ in }, redirected: { _ in }))
        let handOver = DownloadHandOver()
        let client = try NoWaitHarness.client(storage) { o in
            o.cloud?.backgroundDownloads = .whenLeaving
            o.cloud?.backgroundTransport = standIn
            o.cloud?.handOver = handOver
        }
        defer { client.close() }
        try await client.prefetch()
        XCTAssertEqual(standIn.started, [], "the default context in the foreground")
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let frames = "c24_l256/frames.zfw.qle"
        let before = StubProtocol.seen.count
        handOver.set(away: true)
        let outcome = await cloud.install(.v4_0, context: TwoContextBuild.other, activate: true)
        handOver.set(away: false)
        guard case .installed = outcome else { return XCTFail("the context did not install: \(outcome)") }
        let rev = try XCTUnwrap(cloud.store.currentRevision(.v4_0))
        let tasks = standIn.started.compactMap { BackgroundRange(key: $0) }.filter { $0.path == frames }
        XCTAssertEqual(tasks.count, 1, "one background task for the context's file: \(standIn.started)")
        XCTAssertTrue(tasks.allSatisfy { $0.folder.hasSuffix("/v4.0/\(rev)") }, "into the build in use: \(tasks.map(\.folder))")
        XCTAssertFalse(Array(StubProtocol.seen.dropFirst(before)).contains { TwoContextBuild.path($0) == frames }, "no foreground request for it")
        XCTAssertTrue(NoWaitHarness.installed.withLock { $0 }.contains(frames), "and it is in")
    }

    /// 38.5: nothing owed, nothing at the start (13.4: a first download waits for the app's call); a refusal held
    /// removes the model files and the owed records, and nothing is requested.
    func testNothingOwedAndAStopHeldRequestNothing() async throws {
        NoWaitHarness.setUp(connection: .unmetered)
        let build = try TwoContextBuild.manifest()
        Self.serve(build)
        let storage = CloudFixtures.storage()
        let client = try NoWaitHarness.client(storage)
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        await cloud.resumeOwed()
        XCTAssertEqual(Self.asked().count, 0, "nothing owed: no model request")
        // a record, then a refusal held
        let root = storage.appendingPathComponent("models")
        OwedDownloads.write(OwedDownload(id: .v4_0, build: build.build, version: nil, keyID: nil, context: nil, kind: "first_install", by: "app",
                                         activate: true), root: root)
        XCTAssertEqual(OwedDownloads.all(root: root).count, 1)
        cloud.gate.note(.rejected(status: 403, code: "x", message: "", reason: "key_revoked"), from: .api)
        XCTAssertNotNil(cloud.gate.stop)
        await cloud.resumeOwed()
        XCTAssertEqual(Self.asked().count, 0, "a stop held: nothing requested")
        XCTAssertEqual(OwedDownloads.all(root: root), [], "and the owed records went with the model files")
    }
}
#endif
