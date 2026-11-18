import Foundation
import XCTest
@testable import TajweedFormer

/// What a stopped download or a stopped process leaves for the Neural Engine's build (3.1.5).
///
/// Seen with SDK 3.1.4 (2026-11-17): the promotion's download stage refused correct downloads with `verify`, "<path>
/// is in the CoreML package but not in the manifest" and "<path> does not match the manifest", after downloads the
/// network or the system had stopped; and a command-line tool that returned from `main` during the warm-up, after
/// which the build was off for good with reason `crash`.
final class DownloadAndStopTests: XCTestCase {
    func server() throws -> URL { try Fixtures.v4mini().appendingPathComponent("server") }
    func manifest() throws -> ModelManifest { try ModelManifest.parse(Data(contentsOf: server().appendingPathComponent("manifest.json"))) }
    func verifier() throws -> ManifestVerifier { ManifestVerifier(trustedKeys: [try Fixtures.v4miniKey()], requireSignature: true) }
    func scratch() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tf-stop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static let package = "coreml/tajweedformer_v4.mlmodelc"
    static let weights = "coreml/tajweedformer_v4.mlmodelc/weights/weight.bin"

    /// A folder with the CPU set of c16_l64, as the first install leaves it.
    func cpuFolder(_ m: ModelManifest) async throws -> URL {
        let dir = scratch()
        _ = try await ModelInstaller(source: DirectoryFileSource(root: try server())).install(m, profile: DownloadProfile(context: "c16_l64", coreML: false), into: dir)
        return dir
    }

    /// The accelerator's download, stopped by the network when it reaches the package's weights.
    func stoppedAtTheWeights(_ m: ModelManifest, into dir: URL) async throws {
        let profile = DownloadProfile(context: "c16_l64", coreML: true)
        let order = profile.appleFiles(m)
        let at = try XCTUnwrap(order.firstIndex { $0.localPath == Self.weights })
        let before = order[..<at].reduce(Int64(0)) { $0 + $1.size }
        let cut = TajweedModelTests.FlakySource(inner: DirectoryFileSource(root: try server()), budget: Locked(before))
        do throws(RecognizerError) {
            _ = try await ModelInstaller(source: cut, rangeSize: 64 << 10).installAccelerator(m, profile: profile, into: dir)
            XCTFail("the cut download finished")
        } catch {
            guard case .offline = error else { return XCTFail("\(error)") }
        }
    }

    /// The promotion's download stage on a folder opened at launch, as the recognizer runs it
    /// (`TajweedRecognizer.downloadAccelerator`): the build's files, then the build judged.
    func downloadStage(_ opened: ModelFolder, source: (any ModelFileSource)? = nil) async throws -> ModelFolder {
        let src: any ModelFileSource = try source ?? DirectoryFileSource(root: server())
        let installer = ModelInstaller(source: src)
        return try await TajweedRecognizer.downloadAccelerator(opened, context: "c16_l64", compact: false) {
            (folder: ModelFolder) async throws(RecognizerError) -> Void in
            _ = try await installer.installAccelerator(folder.manifest, profile: DownloadProfile(context: "c16_l64", coreML: true), into: folder.directory)
        }
    }

    /// Records the ranges asked for, by stored path.
    final class RecordingSource: ModelFileSource, @unchecked Sendable {
        let inner: DirectoryFileSource
        let asked = Locked<[String]>([])
        init(_ inner: DirectoryFileSource) { self.inner = inner }
        func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
            asked.withLock { $0.append("\(path) \(lower)-\(upper)") }
            return try await inner.bytes(path, lower: lower, upper: upper, size: size)
        }
    }

    /// Every file under the package that the manifest does not list.
    func strays(_ dir: URL, _ m: ModelManifest) throws -> [String] {
        let listed = Set(m.files.map(\.localPath))
        return try ModelFolder.filesUnder(dir, Self.package).filter { !listed.contains($0) }
    }

    /// A download the network stopped in the middle of the package leaves nothing in the package that the manifest
    /// does not list: the next launch opens the folder with no problem for its CoreML build.
    func testAnInterruptedDownloadLeavesNothingInTheCoreMLPackage() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        try await stoppedAtTheWeights(m, into: dir)
        let opened = try ModelFolder.open(directory: dir, verifier: verifier())
        XCTAssertNil(opened.coreMLProblem, "what the stopped download left in the package")
    }

    /// The production failure: a launch opens the folder an interrupted download left, the download stage finishes the
    /// build, and the build is taken (3.1.4 refused it with the problem found at launch, for good within the launch).
    func testTheDownloadStageTakesTheBuildAfterAnInterruptedDownload() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        try await stoppedAtTheWeights(m, into: dir)
        let opened = try ModelFolder.open(directory: dir, verifier: verifier())
        let updated = try await downloadStage(opened)
        XCTAssertNotNil(updated.coreML(context: "c16_l64"), "refused: \(updated.coreMLProblem ?? "no problem named")")
        XCTAssertNoThrow(try ModelFolder.open(directory: dir, verifier: verifier()))
        XCTAssertNotNil(try ModelFolder.open(directory: dir, verifier: verifier()).coreML(context: "c16_l64"))
    }

    /// A process ended while a gzip file of the package was being inflated: a short decoded file in place and the whole
    /// stored file still in its working file. The download stage sets it right and the build is taken.
    func testAShortDecodedFileFromAStoppedInflateDoesNotKeepTheBuildOff() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        _ = try await ModelInstaller(source: DirectoryFileSource(root: try server())).installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        // as SDKs to 3.1.4 left it: the stored file beside its place, a third of the decoded file in place
        let stored = try Data(contentsOf: server().appendingPathComponent(Self.weights + ".gz"))
        try stored.write(to: dir.appendingPathComponent(Self.weights + ".gz.part"))
        let decoded = try Data(contentsOf: dir.appendingPathComponent(Self.weights))
        try decoded.prefix(decoded.count / 3).write(to: dir.appendingPathComponent(Self.weights))
        let opened = try ModelFolder.open(directory: dir, verifier: verifier())
        XCTAssertNotNil(opened.coreMLProblem, "a short file in the package is never taken")
        let updated = try await downloadStage(opened)
        XCTAssertNotNil(updated.coreML(context: "c16_l64"), "refused: \(updated.coreMLProblem ?? "no problem named")")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(Self.weights)), decoded)
    }

    /// The developer report: a process that ended normally during the warm-up (SDK 3.1.4 left its one sentinel, with
    /// no way to tell an exit from a crash) is not a crash: at the next launch the build is prepared again and
    /// promoted.
    func testANormalExitDuringTheWarmupIsRetriedAndPromoted() async throws {
        let h = PromotionTests.Harness()
        let c = h.controller()
        var r = PromotionRecord(key: c.key)
        r.attempts = 1
        r.attemptStarted = h.now.withLock { $0 }
        r.completed = .compile
        c.store.save(r)
        try JSONEncoder().encode(PromotionStore.Sentinel(key: c.key, stage: .warmup)).write(to: c.store.sentinelURL)
        let next = h.controller(launch: "L2")
        XCTAssertNotEqual(next.record?.lastReason, .crash, "a normal exit taken for a crash")
        await next.run(h.stages())
        XCTAssertEqual(next.state, .ready, "the build is prepared again and promoted")
        XCTAssertEqual(next.record?.status, .ready)
    }

    // MARK: 3.1.5: the download

    /// Where a stopped download's working file is now: in the folder's working folder, never in the package.
    func testTheWorkingFileOfAStoppedDownloadIsOutsideThePackage() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        try await stoppedAtTheWeights(m, into: dir)
        XCTAssertEqual(try strays(dir, m), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelInstaller.workURL(dir, Self.weights + ".gz.part").path))
    }

    /// The leftover of SDK 3.1.4 itself: its `.part` inside the package (the exact path of the production message) is
    /// carried out of the package, the download goes on from where it stopped, the build is taken and nothing of the
    /// download is left.
    func testTheLeftoverOf314IsCarriedOutOfThePackageAndTheDownloadResumes() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        _ = try await ModelInstaller(source: DirectoryFileSource(root: try server())).installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        let stored = try Data(contentsOf: server().appendingPathComponent(Self.weights + ".gz"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(Self.weights))
        try stored.prefix(100).write(to: dir.appendingPathComponent(Self.weights + ".gz.part"))
        let opened = try ModelFolder.open(directory: dir, verifier: verifier())
        XCTAssertEqual(opened.coreMLProblem, "coreml/tajweedformer_v4.mlmodelc/weights/weight.bin.gz.part is in the CoreML package but not in the manifest",
                       "the folder's check is as strict as before")
        let source = RecordingSource(DirectoryFileSource(root: try server()))
        let updated = try await downloadStage(opened, source: source)
        XCTAssertNotNil(updated.coreML(context: "c16_l64"), updated.coreMLProblem ?? "")
        XCTAssertEqual(source.asked.withLock { $0 }, ["coreml/tajweedformer_v4.mlmodelc/weights/weight.bin.gz 100-\(stored.count - 1)"],
                       "only the rest of the weights")
        XCTAssertEqual(try strays(dir, m), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ModelInstaller.workFolder).path), "nothing of the download is left")
        XCTAssertNotNil(try ModelFolder.open(directory: dir, verifier: verifier()).coreML(context: "c16_l64"))
    }

    /// A file in the package that is not the downloader's is never taken and never left: the whole package is deleted
    /// and downloaded again from nothing.
    func testAFileInThePackageThatIsNotTheDownloadersDeletesThePackage() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        _ = try await ModelInstaller(source: DirectoryFileSource(root: try server())).installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        try Data("extra".utf8).write(to: dir.appendingPathComponent(Self.package + "/extra.bin"))
        let opened = try ModelFolder.open(directory: dir, verifier: verifier())
        XCTAssertEqual(opened.coreMLProblem, Self.package + "/extra.bin is in the CoreML package but not in the manifest")
        XCTAssertNil(opened.coreML(context: "c16_l64"))
        let source = RecordingSource(DirectoryFileSource(root: try server()))
        let updated = try await downloadStage(opened, source: source)
        XCTAssertNotNil(updated.coreML(context: "c16_l64"), updated.coreMLProblem ?? "")
        XCTAssertEqual(try strays(dir, m), [])
        let package = Set(m.files.filter { $0.role == "coreml" && $0.context == "*" }.map(\.path))
        XCTAssertEqual(Set(source.asked.withLock { $0 }.map { String($0.split(separator: " ")[0]) }), package, "the package again, every file")
    }

    /// A build that still does not verify after the download stage is a `verify` failure, and what did not verify is
    /// deleted at once: the next attempt downloads it again from nothing and the build is taken.
    func testABuildThatStillDoesNotVerifyIsDeletedForTheNextAttempt() async throws {
        let m = try manifest()
        let dir = try await cpuFolder(m)
        _ = try await ModelInstaller(source: DirectoryFileSource(root: try server())).installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: dir)
        let decoded = try Data(contentsOf: dir.appendingPathComponent(Self.weights))
        var bad = decoded
        bad[bad.startIndex] ^= 0xff
        try bad.write(to: dir.appendingPathComponent(Self.weights))
        let opened = try ModelFolder.open(directory: dir, verifier: verifier())
        XCTAssertEqual(opened.coreMLProblem, Self.weights + " does not match the manifest", "hashes stay strict")
        do throws(PromotionFailure) {
            // an install that does nothing: the build is judged by what is on disk
            _ = try await TajweedRecognizer.downloadAccelerator(opened, context: "c16_l64", compact: false) { (_: ModelFolder) async throws(RecognizerError) -> Void in }
            XCTFail("a file that does not match was taken")
        } catch {
            XCTAssertEqual(error.reason, .verify)
            XCTAssertEqual(error.detail, Self.weights + " does not match the manifest")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.weights).path), "deleted for the next attempt")
        let again = try await downloadStage(try ModelFolder.open(directory: dir, verifier: verifier()))
        XCTAssertNotNil(again.coreML(context: "c16_l64"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(Self.weights)), decoded)
    }

    /// A failed download says why in the telemetry (`failure_reasons`); a download that worked carries none.
    func testAFailedDownloadSaysWhy() throws {
        let s = AnalyticsStore(storage: CloudFixtures.storage(), enabled: true,
                               context: .init(platform: "ios", sdkVersion: SDKInfo.version, appVersion: "7.0", deviceClass: "A15", soc: "a15",
                                              osMajor: 27, ramTier: "4_8"),
                               clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let build = String(repeating: "b", count: 40)
        s.record(.download(revision: "4.0.0", build: build, profile: "apple-cpu", bytes: 10, success: false, resumed: false, failure: .network))
        s.record(.download(revision: "4.0.0", build: build, profile: "apple-cpu", bytes: 10, success: false, resumed: true, failure: .network))
        s.record(.download(revision: "4.0.0", build: build, profile: "apple-coreml", bytes: 0, success: false, resumed: false, failure: .storage))
        s.record(.download(revision: "4.0.0", build: build, profile: "apple-coreml", bytes: 5, success: true, resumed: false))
        let p = s.payload(try XCTUnwrap(s.pending.first), reportID: "6f1c0e9a4b2d47e8a1c3f5d7b9e0a2c4")
        let downloads = try XCTUnwrap(p["downloads"] as? [[String: Any]])
        let cpu = try XCTUnwrap(downloads.first { $0["profile"] as? String == "apple-cpu" })
        XCTAssertEqual(cpu["failed"] as? Int, 2)
        XCTAssertEqual(cpu["failure_reasons"] as? [String: Int], ["network": 2])
        let coreml = try XCTUnwrap(downloads.first { $0["profile"] as? String == "apple-coreml" })
        XCTAssertEqual(coreml["failure_reasons"] as? [String: Int], ["storage": 1])
        XCTAssertEqual(coreml["success"] as? Int, 1)
        XCTAssertEqual(Set(DownloadFailure.allCases.map(\.rawValue)), ["network", "http", "hash_mismatch", "signature", "storage", "other"],
                       "the server's DOWNLOAD_FAILURES")
    }

    // MARK: 3.1.5: a process that ends during a stage

    /// Another process's sentinel, as it leaves it: its file, and a mark of how it ended.
    func strand(_ c: AcceleratorController, _ stage: PromotionStage, pid: Int32 = 2_000_000_001, mark: String? = nil) throws {
        c.store.writeSentinel(PromotionStore.Sentinel(key: c.key, stage: stage, pid: pid, at: Date()))
        if let mark { try Data().write(to: c.store.sentinelFile(pid: pid, mark)) }
    }

    func inProgress(_ h: PromotionTests.Harness, _ c: AcceleratorController, completed: PromotionStage?) {
        var r = PromotionRecord(key: c.key)
        r.attempts = 1
        r.attemptStarted = h.now.withLock { $0 }
        r.completed = completed
        r.launch = "L1"
        c.store.save(r)
    }

    /// The developer report, with 3.1.5's marks: a normal exit during the warm-up (or a compile, or the golden test)
    /// is not a crash. Nothing is counted, the report says `interrupted`, and the next launch goes on from that stage and
    /// promotes.
    func testAQuitDuringAStageIsRetriedAndPromoted() async throws {
        for (stage, completed) in [(PromotionStage.compile, PromotionStage.download), (.warmup, .compile), (.golden, .warmup)] {
            let h = PromotionTests.Harness()
            let c = h.controller()
            inProgress(h, c, completed: completed)
            try strand(c, stage, mark: "quit")
            let next = h.controller(launch: "L2")
            XCTAssertEqual(next.record?.failures, 0, "\(stage)")
            XCTAssertNil(next.record?.lastReason, "\(stage)")
            XCTAssertEqual(next.record?.stops, 1)
            XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "\(stage.rawValue):interrupted")
            XCTAssertTrue(next.store.takeStranded().isEmpty, "read once")
            await next.run(h.stages())
            XCTAssertEqual(next.state, .ready, "\(stage)")
            XCTAssertEqual(next.record?.attempts, 1, "the same attempt went on")
            XCTAssertFalse(h.calls.withLock { $0 }.contains("download"), "it went on from the stage it was at")
        }
    }

    /// The system ended the app in the background during a stage: twice is nothing; a third time in a row is one
    /// failure (`hang`, retried later), never a crash.
    func testABackgroundStopGoesOnAndOnlyAThirdInARowCounts() async throws {
        let h = PromotionTests.Harness()
        var c = h.controller()
        inProgress(h, c, completed: .download)
        for n in 1...3 {
            try strand(c, .compile, pid: Int32(2_000_000_000 + n), mark: "background")
            c = h.controller(launch: "L\(n + 1)")
            if n < 3 {
                XCTAssertEqual(c.record?.backgroundStops, n)
                XCTAssertEqual(c.record?.failures, 0)
                XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "compile:crash_on_last_run")
                XCTAssertEqual(h.incidents.withLock { $0 }.last?.foreground, false)
            }
        }
        XCTAssertEqual(c.record?.lastReason, .hang)
        XCTAssertEqual(c.record?.status, .retry, "tried again later, not off for good")
        XCTAssertEqual(c.record?.failures, 1)
        h.advance(3601)
        let later = h.controller(launch: "L9")
        await later.run(h.stages())
        XCTAssertEqual(later.state, .ready)
    }

    /// A process that died in the foreground during a stage with no mark is still a crash, never retried for the key.
    func testADeathInTheForegroundIsStillACrash() async throws {
        let h = PromotionTests.Harness()
        let c = h.controller()
        inProgress(h, c, completed: .download)
        try strand(c, .compile)
        let next = h.controller(launch: "L2")
        XCTAssertEqual(next.record?.lastReason, .crash)
        XCTAssertEqual(next.record?.status, .failed)
        XCTAssertEqual(h.incidents.withLock { $0 }.last?.code, "compile:crash_on_last_run")
    }

    /// A stage under way in another process of the app (its lock held) is left alone: no verdict, the sentinel stays.
    /// Once that process is gone (the lock free), the next launch judges it.
    func testAStageUnderWayInAnotherProcessIsLeftAlone() async throws {
        let h = PromotionTests.Harness()
        let c = h.controller()
        inProgress(h, c, completed: .download)
        let pid: Int32 = 2_000_000_007
        try strand(c, .compile, pid: pid)
        // the other process holds its lock
        let lockURL = c.store.sentinelFile(pid: pid, "lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let second = h.controller(launch: "L2")
        XCTAssertNil(second.record?.lastReason, "no verdict on a stage under way")
        XCTAssertEqual(second.record?.status, .pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.store.sentinelURL(pid: pid).path))
        // the other process ends without a mark
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
        let third = h.controller(launch: "L3")
        XCTAssertEqual(third.record?.lastReason, .crash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.sentinelURL(pid: pid).path))
    }

    /// This process's own stage is never judged by a second controller of the process (two Models, two contexts).
    func testAProcessNeverJudgesItsOwnStage() async throws {
        let h = PromotionTests.Harness()
        let c = h.controller()
        inProgress(h, c, completed: .download)
        c.store.writeSentinel(c.key, .compile)
        XCTAssertTrue(StageSentinel.isHeld(c.store.sentinelFile(pid: ProcessInfo.processInfo.processIdentifier, "lock")))
        let other = h.controller(launch: "L2")
        XCTAssertNil(other.record?.lastReason)
        XCTAssertNotNil(c.store.sentinel())
        c.store.clearSentinel()
        XCTAssertNil(c.store.sentinel())
        XCTAssertFalse(StageSentinel.isHeld(c.store.sentinelFile(pid: ProcessInfo.processInfo.processIdentifier, "lock")))
    }

    /// The app's willTerminate during a stage writes the quit mark beside the sentinel.
    func testTerminateDuringAStageWritesTheQuitMark() async throws {
        let h = PromotionTests.Harness()
        let c = h.controller()
        let pid = ProcessInfo.processInfo.processIdentifier
        c.store.writeSentinel(c.key, .warmup)
        NotificationCenter.default.post(name: Notification.Name(StageSentinel.terminateName), object: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.store.sentinelFile(pid: pid, "quit").path))
        c.store.clearSentinel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.sentinelFile(pid: pid, "quit").path))
        // after the stage, a terminate writes nothing
        NotificationCenter.default.post(name: Notification.Name(StageSentinel.terminateName), object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.store.sentinelFile(pid: pid, "quit").path))
    }

    /// `prepareAccelerator(again: true)`: a build off for good on this device is prepared from the start.
    func testForgetPreparesAFailedBuildAgain() async throws {
        let h = PromotionTests.Harness()
        h.failures.withLock { $0[.golden] = PromotionFailure(.goldenMismatch, "tokens differ") }
        let c = h.controller()
        await c.run(h.stages())
        XCTAssertEqual(c.record?.status, .failed)
        h.failures.withLock { $0 = [:] }
        c.forget()
        XCTAssertNil(c.record)
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
    }

    /// The first launch of 3.1.5: a crash at a stage and a download stage's verdict of an earlier SDK get one more
    /// attempt; a golden-test mismatch stays.
    func testTheUpgradeGivesCrashAndDownloadVerdictsOneMoreAttempt() async throws {
        let h = PromotionTests.Harness()
        let store = PromotionStore(dir: h.storage)
        let key = AcceleratorController.key(revision: "r1", context: "c16_l64", build: "coreml", osBuild: "23A100", deviceModel: "iPhone17,1")
        var crash = PromotionRecord(key: key)
        crash.status = .failed
        crash.lastStage = .compile
        crash.lastReason = .crash
        crash.failures = 1
        crash.attempts = 1
        store.save(crash)
        var verify = PromotionRecord(key: "r2|c16_l64|coreml|23A100|iPhone17,1")
        verify.status = .failed
        verify.lastStage = .download
        verify.lastReason = .verify
        verify.failures = 4
        store.save(verify)
        var golden = PromotionRecord(key: "r3|c16_l64|coreml|23A100|iPhone17,1")
        golden.status = .failed
        golden.lastStage = .golden
        golden.lastReason = .goldenMismatch
        store.save(golden)
        let c = h.controller()
        XCTAssertEqual(store.record(key)?.status, .retry)
        XCTAssertEqual(store.record(verify.key)?.status, .retry)
        XCTAssertEqual(store.record(verify.key)?.failures, PromotionPolicy.backoff.count, "one more attempt, not a new budget")
        XCTAssertEqual(store.record(golden.key)?.status, .failed)
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
        XCTAssertEqual(store.migrate315(), [], "once per store")
    }

    /// A download the network stops says nothing about the build: retried after 1 h, 6 h, then every 24 h, never
    /// off for good.
    func testADownloadTheNetworkStopsNeverUsesUpTheTries() async throws {
        let h = PromotionTests.Harness()
        h.failures.withLock { $0[.download] = PromotionFailure(.network, "offline: the network connection was lost") }
        let waits: [TimeInterval] = [3600, 6 * 3600, 24 * 3600, 24 * 3600, 24 * 3600, 24 * 3600]
        for (n, wait) in waits.enumerated() {
            let c = h.controller(launch: "L\(n + 1)")
            await c.run(h.stages())
            XCTAssertEqual(c.record?.status, .retry, "launch \(n + 1)")
            XCTAssertEqual(c.record?.failures, 0)
            XCTAssertEqual(c.record?.notBefore, h.now.withLock { $0 }.addingTimeInterval(wait), "launch \(n + 1)")
            h.advance(wait)
        }
        h.failures.withLock { $0 = [:] }
        let c = h.controller(launch: "L9")
        await c.run(h.stages())
        XCTAssertEqual(c.state, .ready)
    }
}
