import Foundation
import XCTest
@testable import TajweedFormer

/// What the Client keeps about its model that is there and cannot be read is not "not there" (3.1.4): the
/// remembered refusal of the server (`cloud/model-stop.json`), and a downloaded build's install record and
/// manifest. While the refusal cannot be read no model is opened and nothing is downloaded; while the record or
/// the manifest cannot be read the build is neither opened nor deleted nor downloaded again. Each is read again
/// at the next call.
///
/// Through the public Client over the suite's stub API and CDN, with a model from a real download of the bundled
/// test folder. "Cannot be read" is the test's switch (`StorageLock`); the device's key store is a stand-in. No
/// test here locks a device.
final class UnreadableModelTests: XCTestCase {
    let fm = FileManager.default

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
    }

    override func tearDown() {
        StorageLock.reset()
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// What is under `<storage>/models`: every file with its size, sorted, without the note of which model Quran
    /// Lab recommends (not a model file).
    func modelFiles(_ storage: URL) -> [String] {
        let dir = storage.appendingPathComponent("models")
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let path = dir.appendingPathComponent(rel).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue, !rel.hasPrefix("recommended.json") else { continue }
            out.append("\(rel) \(((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? -1)")
        }
        return out.sorted()
    }

    /// A first launch that downloads the build; the storage, the device and the build id.
    func downloaded() async throws -> (storage: URL, device: MemoryInstallKeyStore, build: String) {
        let build = try OnlineOnlyTests.serve()
        let device = MemoryInstallKeyStore()
        let storage = CloudFixtures.storage()
        let client = try StubbedModelServer.client(storage: storage, installKeys: device)
        let got = await OnlineOnlyTests.model(client)
        client.close()
        XCTAssertEqual(got.build, build, "the first launch downloads the build: \(String(describing: got.error))")
        XCTAssertFalse(modelFiles(storage).isEmpty)
        return (storage, device, build)
    }

    /// A refusal an earlier launch remembered, with the model still on the device (its removal was owed), and a
    /// next process without a network that cannot read the refusal: `client.model()` opens no model and fails
    /// with `storage_failed`, nothing is removed, nothing is asked of the download server. Once the refusal
    /// reads, in the same Client: the refusal's own error, and the removal that was owed is done.
    func testARememberedRefusalThatCannotBeReadOpensNoModel() async throws {
        let made = try await downloaded()
        let refusal = made.storage.appendingPathComponent("cloud/model-stop.json")
        let stored = Data(#"{"status":403,"code":"app_blocked","message":"Refused.","reason":"app_blocked","from":"api"}"#.utf8)
        try stored.write(to: refusal)
        let files = modelFiles(made.storage)

        StubProtocol.reset { _ in .down }
        StorageLock.refuse(["cloud/model-stop.json"])
        let client = try StubbedModelServer.client(storage: made.storage, installKeys: made.device)
        let locked = await OnlineOnlyTests.model(client)
        XCTAssertNil(locked.build, "no model is opened while the refusal cannot be read")
        XCTAssertEqual(locked.error?.code, "storage_failed")
        XCTAssertEqual(modelFiles(made.storage), files, "nothing is removed")
        XCTAssertEqual(try Data(contentsOf: refusal), stored, "the remembered refusal is what it was")
        XCTAssertEqual(OnlineOnlyTests.fetched, [], "nothing is asked of the download server")

        StorageLock.open()
        let read = await OnlineOnlyTests.model(client)
        XCTAssertNil(read.build, "the refusal reads: still no model")
        XCTAssertEqual(read.error?.code, "server_rejected", "now with the refusal's own error")
        XCTAssertEqual(modelFiles(made.storage), [], "and the removal that was owed is done")
        client.close()
    }

    /// The other side of the line, so that the two cannot drift together: a remembered refusal that was READ and is
    /// not a refusal (damaged) is taken as not there, as before 3.1.4, and as a file that was deleted. Without a
    /// network the model that this Client downloaded opens. (A refusal the system does not give is held: the test
    /// above.)
    func testADamagedRememberedRefusalIsTakenAsNotThere() async throws {
        let made = try await downloaded()
        let refusal = made.storage.appendingPathComponent("cloud/model-stop.json")
        try Data("not a refusal".utf8).write(to: refusal)
        let files = modelFiles(made.storage)

        StubProtocol.reset { _ in .down }
        let client = try StubbedModelServer.client(storage: made.storage, installKeys: made.device)
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, made.build, "the model opens, as with no refusal file: \(String(describing: got.error))")
        XCTAssertEqual(modelFiles(made.storage), files, "nothing is removed")
        client.close()
    }

    /// And for the install record: one that was READ and is not a record (damaged) makes the build "not the
    /// Client's", as before 3.1.4 and as a record that was deleted: the build is deleted and downloaded again. (A
    /// record the system does not give is held: the test below.)
    func testADamagedInstallRecordIsNotTheClientsAndTheBuildIsDownloadedAgain() async throws {
        let made = try await downloaded()
        let base = made.storage.appendingPathComponent("models/v4.0")
        let revision = try String(contentsOf: base.appendingPathComponent("current"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let record = InstallRecord.url(base.appendingPathComponent(revision))
        XCTAssertTrue(fm.fileExists(atPath: record.path))
        try Data("not a record".utf8).write(to: record)

        try OnlineOnlyTests.serve()
        let client = try StubbedModelServer.client(storage: made.storage, installKeys: made.device)
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, made.build, "\(String(describing: got.error))")
        XCTAssertTrue(OnlineOnlyTests.fetched.contains("layers.zfw.gz"), "the build was downloaded again: \(OnlineOnlyTests.fetched)")
        client.close()
    }

    /// A downloaded build whose install record, or whose manifest, the next process cannot read: the build is not
    /// taken for one the Client did not download. It is not opened (`storage_failed`), not deleted, and not
    /// downloaded again, also not by the launch's own update check. Once the file reads, in the same Client, the
    /// model opens with no request for a file.
    func testAnInstallRecordOrAManifestThatCannotBeReadDeletesAndDownloadsNothing() async throws {
        for what in [InstallRecord.fileName, ModelManifest.fileName] {
            let made = try await downloaded()
            let files = modelFiles(made.storage)
            try OnlineOnlyTests.serve()
            let own = made.storage.lastPathComponent
            StorageSeam.refusesReads.withLock { $0 = { (url: URL) -> Bool in url.lastPathComponent == what && url.path.contains(own) } }
            let client = try StubbedModelServer.client(storage: made.storage, installKeys: made.device)
            let locked = await OnlineOnlyTests.model(client)
            // the launch's own update check has had its time
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertNil(locked.build, "\(what) cannot be read: no model is opened")
            XCTAssertEqual(locked.error?.code, "storage_failed", what)
            XCTAssertEqual(modelFiles(made.storage), files, "\(what) cannot be read: nothing is deleted")
            XCTAssertEqual(OnlineOnlyTests.fetched, [], "\(what) cannot be read: nothing is downloaded")

            StorageLock.open()
            let read = await OnlineOnlyTests.model(client)
            XCTAssertEqual(read.build, made.build, "\(what) reads again: \(String(describing: read.error))")
            XCTAssertEqual(OnlineOnlyTests.fetched, [], "\(what) reads again: the model was there all along, nothing is downloaded")
            client.close()
            StorageLock.reset()
        }
    }
}
