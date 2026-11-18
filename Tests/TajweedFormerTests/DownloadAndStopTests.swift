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

    /// The promotion's download stage on a folder opened at launch, as the recognizer runs it: the build's files, then
    /// the build judged.
    func downloadStage(_ opened: ModelFolder) async throws -> ModelFolder {
        let m = opened.manifest
        let installer = ModelInstaller(source: DirectoryFileSource(root: try server()))
        _ = try await installer.installAccelerator(m, profile: DownloadProfile(context: "c16_l64", coreML: true), into: opened.directory)
        let profile = DownloadProfile(context: "c16_l64", coreML: true)
        return opened.adding(verified: profile.appleFiles(m).map(\.localPath), removing: profile.otherBuildFiles(m).map(\.localPath))
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
}
