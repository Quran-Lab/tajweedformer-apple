import Foundation
import XCTest
@testable import TajweedFormer

/// An upload task that an earlier process handed to the system's background session, and whose recording is gone
/// from the queue or may no longer be sent (3.1.4): when the next process opens the queue, the task is cancelled.
/// Until 3.1.3 only the process that turned sharing off cancelled such tasks; one that the system still held at
/// the next launch went on.
///
/// With a REAL background session of the SDK's uploader on the test's Mac, and a server on the loopback interface
/// that takes the upload's request and does not answer it (so the system holds the task). The queue is the SDK's
/// own, opened on a storage folder the test filled; the earlier process is the test starting the task. Not shown:
/// an app that was suspended or ended by the system, a relaunch by the system, a phone.
final class OrphanUploadTaskTests: UnreadableStorageTestCase {
    let fm = FileManager.default

    /// A storage, an app of its own (so that the background session is this test's alone), and a server that
    /// holds every answer until the gate opens.
    struct Stage {
        let storage: URL
        let root: URL
        let app: AppIdentity
        let uploader: BackgroundUploader
        let server: LoopbackServer
        let gate: StubProtocol.Gate
    }

    func stage() async throws -> Stage {
        let server = try LoopbackServer()
        guard await server.start() else { throw XCTSkip("the loopback server did not start") }
        let gate = StubProtocol.Gate()
        server.answer.withLock { $0 = { _ in
            gate.wait()
            return LoopbackServer.Answer(status: 200)
        } }
        let storage = CloudFixtures.storage()
        let app = AppIdentity(platform: "ios", bundleID: "com.example.orphan." + UUID().uuidString.lowercased(), name: "Example", version: "1")
        let uploader = BackgroundUploader.shared(identifier: BackgroundUploader.identifier(for: app))
        return Stage(storage: storage, root: storage.appendingPathComponent("outbox"), app: app, uploader: uploader, server: server, gate: gate)
    }

    func close(_ s: Stage) {
        s.uploader.cancel(prefix: "")
        s.gate.open()
        s.server.stop()
    }

    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    /// The folder of a recording of one segment that has ended and is not sent, stamped with `stamp`.
    func queue(_ s: Stage, id: String, stamp: Int) throws -> URL {
        let folder = s.root.appendingPathComponent(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try ShareFiles.write(ShareFiles.Stamp(count: stamp), folder.appendingPathComponent(ShareFiles.stampFile))
        try Data("{}".utf8).write(to: folder.appendingPathComponent(ShareFiles.session))
        let audio = folder.appendingPathComponent(ShareFiles.name(1) + ".opus")
        try Data((0..<3000).map { UInt8($0 % 251) }).write(to: audio)
        try ShareFiles.mark(folder, n: 1, granule: 48_000, bitrate: nil)
        try ShareFiles.write(ShareFiles.End(durationMs: 1000, completed: true), folder.appendingPathComponent(ShareFiles.end))
        return audio
    }

    /// The learner's stored answer in the stage's storage.
    func answer(_ s: Stage, _ json: String) throws {
        let state = s.storage.appendingPathComponent("cloud/sharing-state.json")
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: state)
    }

    /// The earlier process: the upload of a recording's first segment is with the system, and the server has its
    /// request and has not answered. The task's key.
    func handOver(_ s: Stage, id: String, file: URL) async throws -> String {
        let name = ShareFiles.name(1) + ".opus"
        let key = "\(id)/\(name)"
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(s.server.port)/recordings/\(id)/\(name)"))
        let request = ContributionClient.putRequest(.init(n: 1, url: url, expiresAt: Date().addingTimeInterval(3600)),
                                                    contentType: "audio/ogg", bytes: 3000)
        s.uploader.start(request, file: file, key: key)
        let uploader = s.uploader, server = s.server
        let held = await until(30) { () async -> Bool in
            let running = await uploader.running()
            let asked = server.got.withLock({ $0.count })
            return running.contains(key) && asked == 1
        }
        guard held else { throw XCTSkip("the background session did not bring the upload to the server on this machine") }
        return key
    }

    /// The next process: the SDK's upload queue on the stage's storage, with the background session of that app.
    func open(_ s: Stage) -> ContributionOutbox {
        let options = CloudOptions(apiURL: CloudFixtures.api, app: s.app, urlSession: nil, backgroundUploads: true)
        let config = ConfigStore(storage: s.storage, trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation])
        return ContributionOutbox(storage: s.storage, http: HTTPClient(session: StubProtocol.session()), apiURL: CloudFixtures.api, tokens: nil,
                                  config: config, options: options, app: s.app, clock: { Date() })
    }

    /// A task whose recording is not in the queue any more (its folder is gone): cancelled when the queue opens.
    func testAnUploadTaskWhoseRecordingIsGoneIsCancelledWhenTheQueueOpens() async throws {
        let s = try await stage()
        defer { close(s) }
        try answer(s, SharingConsentPersistTests.granted301)
        let file = fm.temporaryDirectory.appendingPathComponent("orphan-\(UUID().uuidString).opus")
        try Data((0..<3000).map { UInt8($0 % 251) }).write(to: file)
        defer { try? fm.removeItem(at: file) }
        let key = try await handOver(s, id: Self.newID(), file: file)

        let outbox = open(s)
        let uploader = s.uploader
        let cancelled = await until(15) { await !uploader.running().contains(key) }
        XCTAssertTrue(cancelled, "the task of a recording that is gone is cancelled when the queue opens")
        _ = outbox
    }

    /// A task whose recording may no longer be sent (the learner turned sharing off, in a process that ended
    /// before it could cancel the task): cancelled when the queue opens, and the recording's folder goes as before.
    func testAnUploadTaskWhoseRecordingMayNotBeSentIsCancelledWhenTheQueueOpens() async throws {
        let s = try await stage()
        defer { close(s) }
        try answer(s, UnreadableStateTests.storedFinal)
        let id = Self.newID()
        let audio = try queue(s, id: id, stamp: 1)
        let key = try await handOver(s, id: id, file: audio)

        let outbox = open(s)
        let uploader = s.uploader
        let cancelled = await until(15) { await !uploader.running().contains(key) }
        XCTAssertTrue(cancelled, "the task of a recording that may not be sent is cancelled when the queue opens")
        XCTAssertFalse(fm.fileExists(atPath: s.root.appendingPathComponent(id).path), "and its folder is gone, as before")
        _ = outbox
    }

    /// The control: a task whose recording is in the queue under the consent in force is left to the system.
    func testAnUploadTaskOfARecordingInTheQueueIsNotCancelled() async throws {
        let s = try await stage()
        defer { close(s) }
        try answer(s, SharingConsentPersistTests.granted301)
        let id = Self.newID()
        let audio = try queue(s, id: id, stamp: 1)
        let key = try await handOver(s, id: id, file: audio)

        let outbox = open(s)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let running = await s.uploader.running()
        XCTAssertTrue(running.contains(key), "the upload of a recording that is in the queue goes on")
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
        _ = outbox
    }
}
