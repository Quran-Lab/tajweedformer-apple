import Foundation
import XCTest
@testable import TajweedFormer

/// The model download on a network that fails (3.1.5), through the public Client over a stub API and a stub
/// download server that serves the bundled test folder and answers ranges as a real server does (206 with the
/// bytes asked for, an ETag, the whole file when `If-Range` names another ETag):
/// - a range is written to disk as it arrives, so a connection that ends keeps what it delivered;
/// - a range that fails for the network's sake is taken up again, at most five times per file in one call, after
///   pauses; a refusal is never retried; a cancelled call ends a pause at once;
/// - the partial file keeps the validator of the answer that started it and sends it with every later range; a 200
///   to a range request replaces the partial file; the hash of the whole file stays the last word;
/// - the requests of an update say that they do not go over a metered network, a first install's do not.
/// Stand-ins: the stub ends a connection by failing the request after some bytes of the body; the pauses are
/// short ones the test sets (the rule's own are 1, 2, 4, 8 and 16 seconds); the engine and the device's key store
/// are stand-ins. A stall (no byte for 30 seconds) is the system's own timer and is not run here; nothing here ran
/// on a phone or over a cellular network.
final class ModelDownloadTests: XCTestCase {
    typealias Reply = StubProtocol.Reply
    let fm = FileManager.default

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
    }

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    static let weights = "layers.zfw.gz"

    static func stored(_ path: String) throws -> Data { try Data(contentsOf: OnlineOnlyTests.server().appendingPathComponent(path)) }

    /// The first and last byte a `Range` header asks for.
    static func range(_ seen: StubProtocol.Seen) -> (lower: Int, upper: Int)? {
        guard let r = seen.headers["range"], r.hasPrefix("bytes=") else { return nil }
        let parts = r.dropFirst(6).split(separator: "-")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    /// A download server's answer to a model request, as a real one gives it: the bytes of the range with 206 and
    /// `content-range`; the whole file with 200 when no range is asked for, or when `If-Range` names another ETag
    /// than the file's. `etag` nil: a server that sends no ETag.
    static func served(_ path: String, _ seen: StubProtocol.Seen, etag: String? = "\"one\"") -> Reply {
        guard let data = try? stored(path) else { return Reply(status: 404) }
        var headers = ["content-type": "application/octet-stream"]
        if let etag { headers["etag"] = etag }
        guard let asked = range(seen), asked.lower < data.count else { return Reply(status: 200, headers: headers, body: data) }
        if let condition = seen.headers["if-range"], condition != etag { return Reply(status: 200, headers: headers, body: data) }
        let upper = min(asked.upper, data.count - 1)
        headers["content-range"] = "bytes \(asked.lower)-\(upper)/\(data.count)"
        return Reply(status: 206, headers: headers, body: data.subdata(in: asked.lower..<(upper + 1)))
    }

    /// The requests for the weights file so far.
    static var weightRequests: [StubProtocol.Seen] { StubProtocol.seen.filter { OnlineOnlyTests.modelPath($0) == weights } }

    /// A Client on `storage` whose retries pause as `pauses` say (the fixtures' own pause is none).
    func makeClient(_ storage: URL, pauses: [TimeInterval]? = nil, unmeteredUpdates: Bool = false) throws -> TajweedClient {
        // no update check of the launch's own: the requests the stub gets are those of the test's calls
        var made = CloudFixtures.options(updates: .manual, signingKeys: [CloudFixtures.signer.publicKey.rawRepresentation, try Fixtures.v4miniKey()],
                                         storage: storage)
        if let pauses { made.cloud?.retryPauses = pauses }
        made.cloud?.updatesOnWiFiOnly = unmeteredUpdates
        let options = made
        return try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
            CloudFixtures.cloud(storage: root, options: options)
        })
    }

    /// Every file under a storage's models folder whose name ends in `suffix`.
    func files(_ storage: URL, ending suffix: String) -> [String] {
        guard let e = fm.enumerator(atPath: storage.appendingPathComponent("models").path) else { return [] }
        return e.compactMap { $0 as? String }.filter { $0.hasSuffix(suffix) }.sorted()
    }

    // MARK: written as it arrives

    /// The connection ends after 150 bytes of the weights file's first range. Those bytes are kept: the download is
    /// taken up again from byte 150, with the validator of the answer that started the file, and the model opens.
    func testABrokenConnectionKeepsWhatItDelivered() async throws {
        let size = try Self.stored(Self.weights).count
        let broke = Locked(false)
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in
            guard path == Self.weights else { return Self.served(path, seen) }
            let first = broke.withLock { (b: inout Bool) -> Bool in
                defer { b = true }
                return !b
            }
            var reply = Self.served(path, seen)
            if first { reply.breakAfter = 150 }
            return reply
        })
        let client = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let asked = Self.weightRequests
        XCTAssertEqual(asked.map { $0.headers["range"] }, ["bytes=0-\(size - 1)", "bytes=150-\(size - 1)"],
                       "the second request goes on from the byte after the last one that arrived")
        XCTAssertNil(asked.first?.headers["if-range"], "a file that starts has no validator")
        XCTAssertEqual(asked.last?.headers["if-range"], "\"one\"", "the validator of the answer that started the partial file")
    }

    // MARK: retries

    /// The rule's numbers: at most five retries per file in one call, after 1, 2, 4, 8 and 16 seconds.
    func testTheRetryRuleIsFiveTimesAfterOneTwoFourEightAndSixteenSeconds() {
        XCTAssertEqual(ModelInstaller.standardRetryPauses, [1, 2, 4, 8, 16])
        XCTAssertEqual(CloudOptions().retryPauses, [1, 2, 4, 8, 16], "what an app's Client uses")
        XCTAssertEqual(HTTPClient.makeSession().configuration.timeoutIntervalForRequest, 30, "no byte for 30 seconds ends a request")
    }

    /// A file that the network keeps failing is asked for once and again five times, then the call fails. An
    /// answer that is not the network's failure is never asked for again: a refusal of the request, a rate limit, a
    /// refusal that stops the model. A server error is the network's kind and is retried.
    func testAFailureOfTheNetworkIsRetriedFiveTimesAndARefusalNever() async throws {
        let cases: [(name: String, reply: Reply, requests: Int, code: String?)] = [
            ("no answer", .down, 6, nil),
            ("a server error", Reply(status: 503, body: Data("{\"error\":\"storage_unavailable\"}".utf8)), 6, nil),
            ("403 model_not_allowed", .json(["error": "model_not_allowed", "message": "no"], status: 403), 1, "server_rejected"),
            ("429 model_limit", .json(["error": "model_limit", "message": "later"], status: 429), 1, "download_failed"),
            ("a refusal that stops the model", .json(["error": "missing or invalid x-qlab-key", "reason": "key_revoked"], status: 401), 1, "invalid_key"),
        ]
        for c in cases {
            let reply = c.reply
            try OnlineOnlyTests.serve(cdn: { path, seen in path == Self.weights ? reply : Self.served(path, seen) })
            let client = try makeClient(CloudFixtures.storage())
            let got = await OnlineOnlyTests.model(client)
            XCTAssertNil(got.build, c.name)
            if let code = c.code { XCTAssertEqual(got.error?.code, code, c.name) }
            XCTAssertEqual(Self.weightRequests.count, c.requests, "\(c.name): the requests for the file")
            client.close()
        }
    }

    /// The pauses are waited: two retries after 0.3 seconds each take at least 0.6 seconds. And the network coming
    /// back in the middle ends the retries: the third request is served and the model opens.
    func testThePausesAreWaitedAndAServedRetryGoesOn() async throws {
        let failures = Locked(0)
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in
            guard path == Self.weights else { return Self.served(path, seen) }
            let n = failures.withLock { (f: inout Int) -> Int in
                f += 1
                return f
            }
            return n <= 2 ? .down : Self.served(path, seen)
        })
        let client = try makeClient(CloudFixtures.storage(), pauses: [0.3, 0.3, 0.3, 0.3, 0.3])
        defer { client.close() }
        let started = Date()
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.weightRequests.count, 3, "two failures, then served")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.6, "the two pauses were waited")
    }

    /// A caller that is cancelled ends the wait before a retry at once: with a pause of a minute, the call returns
    /// within seconds of its cancellation, and no further request is made.
    func testACancelledCallEndsThePauseAtOnce() async throws {
        try OnlineOnlyTests.serve(cdn: { path, seen in path == Self.weights ? .down : Self.served(path, seen) })
        let client = try makeClient(CloudFixtures.storage(), pauses: [60, 60, 60, 60, 60])
        defer { client.close() }
        let call = Task { await OnlineOnlyTests.model(client) }
        // until the first request for the file has failed and the pause has begun
        let deadline = Date().addingTimeInterval(20)
        while Self.weightRequests.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        call.cancel()
        let got = await call.value
        XCTAssertNil(got.build)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 10, "the minute was not waited")
        XCTAssertEqual(Self.weightRequests.count, 1, "no request after the cancellation")
    }

    // MARK: the validator

    /// An install that stopped with 150 bytes of the weights file: the partial file and, beside it, the ETag of the
    /// answer that started it (nil for a server that sends none). Returns its storage.
    func interrupted(etag: String?) async throws -> URL {
        let broke = Locked(false)
        try OnlineOnlyTests.serve(cdn: { path, seen in
            guard path == Self.weights else { return Self.served(path, seen, etag: etag) }
            let first = broke.withLock { (b: inout Bool) -> Bool in
                defer { b = true }
                return !b
            }
            guard first else { return .down }
            var reply = Self.served(path, seen, etag: etag)
            reply.breakAfter = 150
            return reply
        })
        let storage = CloudFixtures.storage()
        let client = try makeClient(storage)
        let got = await OnlineOnlyTests.model(client)
        XCTAssertNil(got.build, "the download stopped")
        client.close()
        let parts = files(storage, ending: Self.weights + ".part")
        XCTAssertEqual(parts.count, 1, "the partial file is kept: \(parts)")
        if let part = parts.first {
            let url = storage.appendingPathComponent("models").appendingPathComponent(part)
            XCTAssertEqual(ModelInstaller.sizeOnDisk(url), 150, "what arrived before the connection ended")
        }
        XCTAssertEqual(files(storage, ending: ".etag").count, etag == nil ? 0 : 1, "the validator beside the partial file")
        return storage
    }

    /// The file changed on the server while the partial file waited (another ETag): the range request carries the
    /// kept validator, the server answers with the whole file, and that replaces the partial file. Nothing of the
    /// old 150 bytes is joined to it, and the model opens.
    func testAFileThatChangedOnTheServerReplacesThePartialFile() async throws {
        let size = try Self.stored(Self.weights).count
        let storage = try await interrupted(etag: "\"one\"")
        // make the kept bytes wrong, as the bytes of another file would be: only a replacement can open the model
        let part = storage.appendingPathComponent("models").appendingPathComponent(try XCTUnwrap(files(storage, ending: ".part").first))
        try Data(repeating: 0x5a, count: 150).write(to: part)
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen, etag: "\"two\"") })
        let client = try makeClient(storage)
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let asked = Self.weightRequests
        XCTAssertEqual(asked.map { $0.headers["range"] }, ["bytes=150-\(size - 1)"], "one request: the rest of the file")
        XCTAssertEqual(asked.first?.headers["if-range"], "\"one\"", "with the validator of the answer that started the partial file")
        XCTAssertEqual(files(storage, ending: ".etag"), [], "no validator is left beside a finished file")
        XCTAssertEqual(files(storage, ending: ".part"), [])
    }

    /// The same file on the server: the kept validator matches, the server sends the rest, and it is appended.
    func testAnUnchangedFileGoesOnFromThePartialFile() async throws {
        let size = try Self.stored(Self.weights).count
        let storage = try await interrupted(etag: "\"one\"")
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
        let client = try makeClient(storage)
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=150-\(size - 1)"])
        XCTAssertEqual(Self.weightRequests.first?.headers["if-range"], "\"one\"")
    }

    /// Without a kept validator (a server that sends no ETag) the range is asked for as before, without `If-Range`.
    /// The hash of the whole file stays the last word: when the bytes that come do not belong to the partial file,
    /// the file does not verify, is deleted and starts again from its first byte.
    func testWithoutAValidatorTheHashOfTheWholeFileDecides() async throws {
        let size = try Self.stored(Self.weights).count
        let storage = try await interrupted(etag: nil)
        // the rest that the server sends is not the rest of this file
        let wrong = Locked(true)
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in
            guard path == Self.weights, let asked = Self.range(seen), asked.lower == 150 else { return Self.served(path, seen, etag: nil) }
            let first = wrong.withLock { (w: inout Bool) -> Bool in
                defer { w = false }
                return w
            }
            guard first else { return Self.served(path, seen, etag: nil) }
            return Reply(status: 206, headers: ["content-range": "bytes 150-\(size - 1)/\(size)"], body: Data(repeating: 0x5a, count: size - 150))
        })
        let client = try makeClient(storage)
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let asked = Self.weightRequests
        XCTAssertEqual(asked.map { $0.headers["range"] }, ["bytes=150-\(size - 1)", "bytes=0-\(size - 1)"],
                       "the joined file did not verify, so the file started again")
        XCTAssertTrue(asked.allSatisfy { $0.headers["if-range"] == nil }, "no validator was kept, so none is sent")
    }

    // MARK: an update waits for an unmetered network

    /// The request says whether it may go over a metered network: a first install's may, an update's may not (with
    /// updates on unmetered networks only, the default of an app's Client). Read from the requests the stub got.
    func testAnUpdatesRequestsDoNotGoOverAMeteredNetworkAndAFirstInstallsDo() async throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.test/a/b/c/sdk/v4.0/layers.zfw.gz"))
        let plain = CDNClient.request(url, range: nil, key: "k", token: "t")
        XCTAssertTrue(plain.allowsExpensiveNetworkAccess)
        XCTAssertTrue(plain.allowsConstrainedNetworkAccess)
        let waiting = CDNClient.request(url, range: "bytes=0-9", key: "k", token: "t", ifRange: "\"one\"", unmeteredOnly: true)
        XCTAssertFalse(waiting.allowsExpensiveNetworkAccess)
        XCTAssertFalse(waiting.allowsConstrainedNetworkAccess)
        XCTAssertEqual(waiting.value(forHTTPHeaderField: "if-range"), "\"one\"")
        XCTAssertTrue(CloudOptions().updatesOnWiFiOnly, "an app's Client: updates on unmetered networks only")

        // a first install, then an update to another build, through the Client
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
        let storage = CloudFixtures.storage()
        let client = try makeClient(storage, unmeteredUpdates: true)
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let first = OnlineOnlyTests.modelRequests
        XCTAssertGreaterThan(first.count, 5)
        XCTAssertTrue(first.allSatisfy { $0.allowsExpensive && $0.allowsConstrained }, "a first install goes on any network")
        // the config now names another build: the update's requests
        try OnlineOnlyTests.serve(named: String(repeating: "b", count: 40), cdn: { path, seen in Self.served(path, seen) })
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        _ = await cloud.checkForUpdate(.recommended)
        let update = OnlineOnlyTests.modelRequests
        XCTAssertFalse(update.isEmpty, "the update asked the download server")
        XCTAssertTrue(update.allSatisfy { !$0.allowsExpensive && !$0.allowsConstrained }, "an update's requests do not go over a metered network")
    }

    // MARK: what a download leaves behind

    /// The working files of a download are removed before its folder is put in place, at any depth: a partial
    /// file, its validator, a range a background task delivered late, a whole file that was on its way. The
    /// model's own files stay.
    func testTheWorkingFilesOfADownloadDoNotGoIntoTheBuild() throws {
        let folder = CloudFixtures.storage().appendingPathComponent("build")
        try fm.createDirectory(at: folder.appendingPathComponent("c16_l64"), withIntermediateDirectories: true)
        for name in ["layers.zfw", "tokens.txt", "c16_l64/frames.zfw", "layers.zfw.gz.part", "layers.zfw.gz.part.etag", "layers.zfw.gz.part.r100",
                     "c16_l64/frames.zfw.gz.part.r0", "tokens.txt.part.whole"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        ModelUpdater.pruneWorkingFiles(folder)
        let left = (fm.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []).sorted()
        XCTAssertEqual(left, ["c16_l64", "c16_l64/frames.zfw", "layers.zfw", "tokens.txt"])
    }

    /// A download folder of another build, left by an earlier process, is removed when a download starts; and the
    /// installed build holds no working file.
    func testADownloadFolderOfAnotherBuildIsRemovedWhenADownloadStarts() async throws {
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
        let storage = CloudFixtures.storage()
        let old = storage.appendingPathComponent("models/v4.0/.download-" + String(repeating: "0", count: 40))
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50).write(to: old.appendingPathComponent("layers.zfw.gz.part"))
        let client = try makeClient(storage)
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertFalse(fm.fileExists(atPath: old.path), "the other build's download folder is gone")
        let working = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.contains(".part") || $0.contains(".download-") }
        XCTAssertEqual(working, [], "nothing of a download is left beside the installed build")
    }

    // MARK: cancelling one caller (SPEC 16.3)

    /// Two callers wait for the same install while the download server holds the weights file's answer. One is
    /// cancelled: its wait ends at once, with `cancelled`, and nothing else happens. The other gets the model when
    /// the server answers, and the file was asked for once: no byte was fetched twice.
    func testCancellingOneCallerEndsItsWaitAndTheOtherGetsTheModel() async throws {
        let gate = StubProtocol.Gate()
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in
            var reply = Self.served(path, seen)
            if path == Self.weights { reply.hold = gate }
            return reply
        })
        let client = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        let first = Task { await OnlineOnlyTests.model(client) }
        let second = Task { await OnlineOnlyTests.model(client) }
        // until the file's request is in flight, and both callers have had time to be waiting for the install
        let deadline = Date().addingTimeInterval(20)
        while Self.weightRequests.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        first.cancel()
        let gone = await first.value
        XCTAssertNil(gone.build)
        XCTAssertEqual(gone.error?.code, "cancelled", "\(String(describing: gone.error))")
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5, "the cancelled caller's wait ended at once, while the server still held the answer")
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the request in flight was not ended")
        gate.open()
        let got = await second.value
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.weightRequests.count, 1, "the file was asked for once")
    }

    /// The last waiter is cancelled and no download ahead of use asked for the install: the part that runs in the
    /// app stops (the request in flight is ended). A download ahead of use (`prefetch`) goes on when its caller is
    /// cancelled: the request stays in flight, and the model is on the device when the server has answered.
    func testTheInstallStopsWithItsLastWaiterAndAPrefetchGoesOn() async throws {
        var gate = StubProtocol.Gate()
        try OnlineOnlyTests.serve(cdn: { [gate] path, seen in
            var reply = Self.served(path, seen)
            if path == Self.weights { reply.hold = gate }
            return reply
        })
        var client = try makeClient(CloudFixtures.storage())
        let only = Task { [client] in await OnlineOnlyTests.model(client) }
        var deadline = Date().addingTimeInterval(20)
        while Self.weightRequests.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        only.cancel()
        _ = await only.value
        deadline = Date().addingTimeInterval(10)
        while StubProtocol.cancelled.withLock({ $0.isEmpty }), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 1, "the request in flight was ended when the last waiter left")
        gate.open()
        client.close()

        gate = StubProtocol.Gate()
        let build = try OnlineOnlyTests.serve(cdn: { [gate] path, seen in
            var reply = Self.served(path, seen)
            if path == Self.weights { reply.hold = gate }
            return reply
        })
        client = try makeClient(CloudFixtures.storage())
        defer { client.close() }
        let ahead = Task { [client] in try? await client.prefetch() }
        deadline = Date().addingTimeInterval(20)
        while Self.weightRequests.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        ahead.cancel()
        _ = await ahead.value
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "a download ahead of use goes on")
        gate.open()
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.weightRequests.count, 1, "the file was asked for once")
    }

    /// `prefetch(unmeteredOnly: true)`: every model request of the download carries the system's two marks of a
    /// request that waits for an unmetered network; a plain `prefetch` carries neither. (Read from the requests
    /// the stub got. The connection of the test's Mac is read first by the call, as before: on a connection that
    /// reads as metered or none it makes no request, and the test says so.)
    func testAPrefetchForUnmeteredNetworksOnlyMarksItsRequests() async throws {
        try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
        var client = try makeClient(CloudFixtures.storage())
        try await client.prefetch(unmeteredOnly: true)
        let marked = OnlineOnlyTests.modelRequests
        client.close()
        guard !marked.isEmpty else { throw XCTSkip("the connection of this Mac reads as metered or none: prefetch(unmeteredOnly:) made no request") }
        XCTAssertGreaterThan(marked.count, 5)
        XCTAssertTrue(marked.allSatisfy { !$0.allowsExpensive && !$0.allowsConstrained }, "every request waits for an unmetered network")
        try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
        client = try makeClient(CloudFixtures.storage())
        try await client.prefetch()
        let plain = OnlineOnlyTests.modelRequests
        client.close()
        XCTAssertGreaterThan(plain.count, 5)
        XCTAssertTrue(plain.allSatisfy { $0.allowsExpensive && $0.allowsConstrained }, "a plain prefetch goes on any network")
    }

    // MARK: answers that say success and are not the file (SPEC 16.1)

    /// The partial file of the weights in a storage whose install was interrupted.
    func partialFile(_ storage: URL) throws -> URL {
        let parts = files(storage, ending: Self.weights + ".part")
        return storage.appendingPathComponent("models").appendingPathComponent(try XCTUnwrap(parts.first))
    }

    /// `client.model()`, watched, so that a test never hangs on a call that asks without end: whether the call
    /// ended by itself within `seconds` and before the stub had `limit` requests for the weights file. A call that
    /// did not is cancelled.
    func bounded(_ client: TajweedClient, seconds: TimeInterval = 20, limit: Int = 40) async -> (build: String?, error: TajweedError?, endedByItself: Bool) {
        let done = Locked(false)
        let call = Task { () -> (build: String?, error: TajweedError?) in
            let got = await OnlineOnlyTests.model(client)
            done.withLock { $0 = true }
            return got
        }
        let end = Date().addingTimeInterval(seconds)
        while !done.withLock({ $0 }), Date() < end, Self.weightRequests.count < limit {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let byItself = done.withLock { $0 }
        if !byItself { call.cancel() }
        let got = await call.value
        return (got.build, got.error, byItself)
    }

    /// The seven answers of SPEC 16.5, each given at EVERY attempt to a download that goes on from a partial file
    /// of 150 bytes: a 204; a 200 shorter and one longer than the file; an empty 206; a 206 with another total and
    /// one with another start; a 200 with a JSON body. Each is a failed attempt: the call ends `download_failed`
    /// after the file was asked for once and five times again, the partial file is the same bytes as before, and
    /// the next call finishes from them. The answers carry a Content-Length, as a real server's do.
    func testAnAnswerThatSaysSuccessAndIsNotTheFileIsAFailedAttemptAndCostsNoStoredByte() async throws {
        let whole = try Self.stored(Self.weights)
        let size = whole.count
        func octets(_ body: Data, _ status: Int, range: String? = nil) -> Reply {
            var headers = ["content-type": "application/octet-stream", "content-length": String(body.count), "etag": "\"one\""]
            if let range { headers["content-range"] = range }
            return Reply(status: status, headers: headers, body: body)
        }
        let json = Data("{\"error\":\"storage_unavailable\"}".utf8)
        let cases: [(name: String, reply: Reply)] = [
            ("a 204", Reply(status: 204, headers: ["content-length": "0"])),
            ("a 200 shorter than the file", octets(whole.prefix(100), 200)),
            ("a 200 longer than the file", octets(whole + Data(repeating: 7, count: 50), 200)),
            ("an empty 206", octets(Data(), 206, range: "bytes 150-\(size - 1)/\(size)")),
            ("a 206 with another total", octets(whole.subdata(in: 150..<size), 206, range: "bytes 150-\(size - 1)/\(size + 580)")),
            ("a 206 with another start", octets(whole.prefix(size - 150), 206, range: "bytes 0-\(size - 151)/\(size)")),
            ("a 200 with a JSON body", Reply(status: 200, headers: ["content-type": "application/json", "content-length": String(json.count)], body: json)),
        ]
        for c in cases {
            let storage = try await interrupted(etag: "\"one\"")
            let part = try partialFile(storage)
            let before = try Data(contentsOf: part)
            XCTAssertEqual(before, whole.prefix(150), c.name)
            let reply = c.reply
            try OnlineOnlyTests.serve(cdn: { path, seen in path == Self.weights ? reply : Self.served(path, seen) })
            let client = try makeClient(storage)
            let got = await bounded(client)
            client.close()
            let requests = Self.weightRequests.count
            XCTAssertTrue(got.endedByItself, "\(c.name): the call ended by itself (it was stopped after \(requests) requests for the file)")
            XCTAssertNil(got.build, c.name)
            XCTAssertEqual(got.error?.code, "download_failed", c.name)
            XCTAssertEqual(requests, 6, "\(c.name): asked once and five times again, each a failed attempt")
            XCTAssertEqual(try? Data(contentsOf: part), before, "\(c.name): the partial file is the bytes it was")
            // the next call finishes from them
            let build = try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
            let next = try makeClient(storage)
            let again = await OnlineOnlyTests.model(next)
            next.close()
            XCTAssertEqual(again.build, build, "\(c.name): \(String(describing: again.error))")
            XCTAssertEqual(Self.weightRequests.first?.headers["range"], "bytes=150-\(size - 1)", "\(c.name): the next call goes on from the partial file")
        }
    }

    /// A failed attempt is followed by its pause like any other failure: with five pauses of 0.2 seconds, a file
    /// that is answered with an empty 206 every time takes at least a second, and is asked for six times.
    func testAFailedAttemptWaitsItsPause() async throws {
        let size = try Self.stored(Self.weights).count
        let storage = try await interrupted(etag: "\"one\"")
        let empty = Reply(status: 206, headers: ["content-length": "0", "content-range": "bytes 150-\(size - 1)/\(size)", "etag": "\"one\""])
        try OnlineOnlyTests.serve(cdn: { path, seen in path == Self.weights ? empty : Self.served(path, seen) })
        let client = try makeClient(storage, pauses: [0.2, 0.2, 0.2, 0.2, 0.2])
        let started = Date()
        let got = await bounded(client)
        client.close()
        XCTAssertTrue(got.endedByItself, "the call ended by itself (stopped after \(Self.weightRequests.count) requests)")
        XCTAssertEqual(Self.weightRequests.count, 6)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.0, "the five pauses were waited")
    }

    /// A 416: the stored bytes run past the server's file. The partial file is removed and the file starts again
    /// in the same call (one of its five resumes), and the model opens.
    func testA416RemovesThePartialFileAndTheFileStartsAgain() async throws {
        let size = try Self.stored(Self.weights).count
        let storage = try await interrupted(etag: "\"one\"")
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in
            guard path == Self.weights, let asked = Self.range(seen), asked.lower > 0 else { return Self.served(path, seen) }
            return Reply(status: 416, headers: ["content-range": "bytes */\(size)", "content-length": "0"])
        })
        let client = try makeClient(storage)
        let got = await bounded(client)
        client.close()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=150-\(size - 1)", "bytes=0-\(size - 1)"],
                       "the partial file went with the 416, and the file was asked for from its first byte")
    }

    /// A partial file larger than the file cannot be a part of it: it is removed when the attempt starts, and the
    /// file is asked for from its first byte, without a validator.
    func testAPartialFileLargerThanTheFileIsRemovedWhenTheAttemptStarts() async throws {
        let size = try Self.stored(Self.weights).count
        let storage = try await interrupted(etag: "\"one\"")
        try Data(repeating: 9, count: size + 80).write(to: try partialFile(storage))
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in Self.served(path, seen) })
        let client = try makeClient(storage)
        let got = await bounded(client)
        client.close()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=0-\(size - 1)"])
        XCTAssertNil(Self.weightRequests.first?.headers["if-range"], "the validator went with the partial file")
    }
}
