import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 38 on Apple's code: what a download continued from (38.8), counted with the download and
/// sent behind `AnalyticsStore.sendsContinuity` (on: qlab-api takes it), the models folder kept out of backups (38.3 item 3),
/// and the hand-over's limits (38.4: pieces of 64 MiB, the 2 s probe). The rules themselves replay the vectors in
/// ContinuityVectorTests; the hand-over in pieces is in BackgroundDownloadTests.
final class ContinuityTests: XCTestCase {
    override func tearDown() { AnalyticsStore.sendsContinuity.withLock { $0 = true } }

    /// 38.8: `continued` is counted once per download, under the first of `system`, `start` and `call` that applies;
    /// `resume_ms` only in the download the start resumed.
    func testWhatADownloadContinuedFrom() {
        var r = InstallReport()
        XCTAssertTrue(DownloadContinuity(r).isEmpty, "a download from nothing kept")
        r.keptBytes = 20_000_999
        var c = DownloadContinuity(r)
        XCTAssertEqual(c.resumedKB, 20_000)
        XCTAssertEqual(c.continued, "call")
        c = DownloadContinuity(r, fromStart: true, resumeBucket: 1)
        XCTAssertEqual(c.continued, "start")
        XCTAssertEqual(c.resumeBucket, 1)
        r.joinedBackground = true
        c = DownloadContinuity(r, fromStart: true, resumeBucket: 1)
        XCTAssertEqual(c.continued, "system", "the system's carrier finished it while the app was away")
        XCTAssertNil(c.resumeBucket, "resume_ms is the start's, with continued.start")
        r.fetchedBytes = 1
        XCTAssertEqual(DownloadContinuity(r, fromStart: true).continued, "start", "the app fetched the rest: not the system's alone")
        r = InstallReport()
        r.handed = true
        r.restarted = ["validator": 1, "cut": 2]
        c = DownloadContinuity(r)
        XCTAssertNil(c.continued)
        XCTAssertTrue(c.handed)
        XCTAssertEqual(c.restarted, ["validator": 1], "only the reasons of 38.6")
    }

    func store() -> AnalyticsStore {
        AnalyticsStore(storage: CloudFixtures.storage(), enabled: true, context: HostsSendVectorTests.context)
    }

    /// 38.8, 38.9: the fields are counted with the download and sent (qlab-api takes them since 2026-11-23 15:27Z), as
    /// the server checks them, each left out when 0; with the switch off they are counted and left out of what is sent.
    func testTheFieldsAreCountedAndHeldUntilTheServerTakesThem() throws {
        XCTAssertTrue(AnalyticsStore.sendsContinuity.withLock { $0 }, "on: qlab-api takes them")
        AnalyticsStore.sendsContinuity.withLock { $0 = false }
        let s = store()
        var r = InstallReport()
        r.keptBytes = 20_000_000
        r.handed = true
        s.record(.download(revision: "4.0.0", build: String(repeating: "b", count: 40), profile: "apple-cpu", bytes: 34_765_312, success: true,
                           resumed: true, continuity: DownloadContinuity(r, fromStart: true, resumeBucket: 1)))
        var r2 = InstallReport()
        r2.restarted = ["validator": 1]
        s.record(.download(revision: "4.0.0", build: String(repeating: "b", count: 40), profile: "apple-cpu", bytes: 54_765_312, success: true,
                           resumed: false, continuity: DownloadContinuity(r2)))
        let day = try XCTUnwrap(s.pending.first)
        let entry = try XCTUnwrap((s.payload(day, reportID: String(repeating: "a", count: 32))["downloads"] as? [[String: Any]])?.first)
        for k in ["resumed_kb", "resume_ms", "continued", "handed", "restarted"] { XCTAssertNil(entry[k], k) }
        AnalyticsStore.sendsContinuity.withLock { $0 = true }
        let on = try XCTUnwrap((s.payload(day, reportID: String(repeating: "b", count: 32))["downloads"] as? [[String: Any]])?.first)
        XCTAssertEqual(on["resumed_kb"] as? Int, 20_000)
        XCTAssertEqual(on["resume_ms"] as? [Int], [0, 1, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(on["continued"] as? [String: Int], ["start": 1])
        XCTAssertEqual(on["handed"] as? Int, 1)
        XCTAssertEqual(on["restarted"] as? [String: Int], ["validator": 1])
        XCTAssertNil(ContinuityRules.downloadsProblem(on), "the server takes it")
        // a day saved by 4.0.4 (no continuity fields) still decodes
        let old = try JSONSerialization.data(withJSONObject: ["bytes": 10, "success": 1, "failed": 0, "resumed": 0])
        let d = try JSONDecoder().decode(AnalyticsStore.Download.self, from: old)
        XCTAssertNil(d.resumedKB)
        XCTAssertNil(d.continued)
    }

    /// 38.3 item 3: the models folder is excluded from backups, once it is there (nothing is made before).
    func testTheModelsFolderIsNotBackedUp() throws {
        let root = CloudFixtures.storage().appendingPathComponent("models")
        ModelStore.excludeFromBackup(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "nothing made before a download")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelStore.excludeFromBackup(root)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    /// 38.3: the owed records: written atomically, one per model, build, kind and context, read back, removed one by
    /// one; the order of 38.5 item 3 (the app's first); and what 4.0.4 left read as an owed first install of the app.
    func testTheOwedRecords() throws {
        let storage = CloudFixtures.storage()
        let root = storage.appendingPathComponent("models")
        func owe(_ build: String, _ kind: String, _ by: String, _ context: String? = nil) -> OwedDownload {
            OwedDownload(id: .v4_0, build: build, version: "4.0.0", keyID: nil, context: context, kind: kind, by: by, activate: kind == "first_install")
        }
        let acc = owe("b1", "accelerator", "sdk"), ctx = owe("b1", "context", "app", "c24_l256"), upd = owe("b2", "update", "sdk")
        for o in [acc, upd, ctx] { OwedDownloads.write(o, root: root) }
        XCTAssertEqual(Set(OwedDownloads.all(root: root).map { $0.fileName }), Set([acc, upd, ctx].map { $0.fileName }))
        XCTAssertEqual(OwedDownloads.ordered([acc, upd, ctx]).map { $0.kind }, ["context", "update", "accelerator"], "the app's first")
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        var again = upd
        again.base = "https://cdn.quranlab.ai/models/x/"
        OwedDownloads.write(again, root: root)
        XCTAssertEqual(OwedDownloads.all(root: root).count, 3, "one record per download, rewritten")
        OwedDownloads.removeOther(.v4_0, keeping: "b9", root: root)
        XCTAssertEqual(OwedDownloads.all(root: root).map { $0.kind }.sorted(), ["accelerator", "context"], "a superseded update goes")
        OwedDownloads.remove(ctx, root: root)
        XCTAssertEqual(OwedDownloads.all(root: root).map { $0.kind }, ["accelerator"])
        XCTAssertFalse(ctx.fileName.contains("/"), "a file name, whatever the context")
        // 38.3 item 4: a `.download-<build>` folder 4.0.4 left, with this device's record saying downloading
        let store = ModelStore(root: root, verifier: ManifestVerifier(trustedKeys: [], requireSignature: false), installKeys: CloudFixtures.installKeys)
        let left = store.base(.v4_0).appendingPathComponent(".download-" + String(repeating: "c", count: 40))
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try InstallRecord.write(.downloading, build: String(repeating: "c", count: 40), in: left, keys: CloudFixtures.installKeys)
        let found = OwedDownloads.leftBy404(.v4_0, store: store, known: OwedDownloads.all(root: root))
        XCTAssertEqual(found.map { [$0.build, $0.kind, $0.by] }, [[String(repeating: "c", count: 40), "first_install", "app"]])
        XCTAssertNil(found.first?.manifest, "no manifest kept: the resume fetches it")
        XCTAssertEqual(OwedDownloads.leftBy404(.v4_0, store: store, known: found), [], "not twice")
    }

    /// 38.4, 38.5, 16.2: a task the app waits for must bring a byte within 2 s, then none for 30 s ends it; a
    /// background task takes at most 64 MiB.
    func testTheLimits() {
        XCTAssertEqual(ModelInstaller.probeLimit.withLock { $0 }, 2)
        XCTAssertEqual(ModelInstaller.stallLimit.withLock { $0 }, 30)
        XCTAssertEqual(ModelInstaller.pieceBytes.withLock { $0 }, 67_108_864)
        XCTAssertEqual(ContinuityRules.pieces(1_000_000, 131_072_000).map { [$0.lo, $0.hi] },
                       [[1_000_000, 68_108_864], [68_108_864, 131_072_000]])
    }

    /// 38.5 item 2: a download from the folder an earlier answer named that needed nothing after the answer (every file
    /// was in already, so no install waited for it) still waits for the lease asked beside it: a refusal ends it, and
    /// only an answer with a folder lets the build be put in place.
    func testADownloadThatEndsBeforeTheLeasesAnswerStillWaitsForIt() async {
        let base = URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/b/sdk/v4.0/")!
        let refused = Task { () async -> Result<LeaseRecord, RecognizerError> in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .failure(.serverRejected(status: 403, code: "lease_attestation_required", message: "not attested"))
        }
        let done: @Sendable () async throws(RecognizerError) -> InstallReport = { () async throws(RecognizerError) -> InstallReport in InstallReport() }
        let first = await ModelUpdater.leaseBeside(refused, base: base, done)
        guard case .failed = first else { return XCTFail("a refusal after the files were in: \(first)") }
        let granted = Task { () async -> Result<LeaseRecord, RecognizerError> in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .success(LeaseRecord(build: "b", base: base.absoluteString, expiresAt: 0, refreshAfter: 0))
        }
        let second = await ModelUpdater.leaseBeside(granted, base: base, done)
        guard case .installed = second else { return XCTFail("an answer naming the folder: \(second)") }
    }
}
