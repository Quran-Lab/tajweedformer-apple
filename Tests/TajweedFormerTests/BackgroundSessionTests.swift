import Foundation
import Network
import XCTest
@testable import TajweedFormer

/// The background transport with a REAL background URLSession (3.1.5): the SDK's own `BackgroundDownloader`, on the
/// test's Mac, against a small HTTP server on the loopback interface that serves the stub build's CDN forms
/// (`StubBuild`; 4.0: on the installer a run makes, `StubInstall`, as 3.1.5's Client cannot install a 4.0 build from a
/// stub server). Nothing
/// here is a stand-in for the session: the system's download tasks fetch the ranges, the SDK's delegate places
/// them, the installer joins them and the hashes decide. The API and the manifest still come from the suite's stub
/// server (a stub cannot answer a background session, and the loopback server cannot sign in an install).
/// What this does NOT show, because a test process on a Mac is never suspended: that the transfers go on while an
/// app is suspended, the relaunch that hands the app its events, a cellular network, Low Data Mode, a force-quit,
/// and anything on a phone.
final class BackgroundSessionTests: XCTestCase {
    /// An HTTP server on the loopback interface. A path with `/sdk/v4.0/` in it is that file of the test folder: a
    /// `Range` gets a 206 with the bytes asked for, no range the whole file. One request can be answered with a
    /// redirect to the same path on another host name of this machine (`localhost`), once.
    final class Server: @unchecked Sendable {
        struct Got: Sendable {
            let path: String
            let host: String
            let range: String?
            let key: String?
            let authorization: String?
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "tests.loopback-model-server")
        let got = Locked<[Got]>([])
        /// The stored path and first byte of the request that is redirected, until it was.
        let redirect = Locked<(path: String, lower: Int)?>(nil)
        /// Where that redirect leads, as the start of an address; nil: this server under another host name
        /// (`localhost`). A test names another server here, or this server's `/hop`, which leads back.
        let redirectBase = Locked<String?>(nil)
        private let port = Locked<UInt16>(0)

        init() throws { listener = try NWListener(using: .tcp) }

        /// Starts listening; the port, or nil when the listener is not ready within five seconds.
        func start() async -> UInt16? {
            let ready = Locked(false)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.withLock { $0 = true } }
            }
            listener.newConnectionHandler = { [weak self] connection in
                let box = UncheckedBox(connection)
                self?.queue.async { [weak self] in
                    box.value.start(queue: self?.queue ?? .global())
                    self?.read(box, Data())
                }
            }
            listener.start(queue: queue)
            for _ in 0..<200 {
                if ready.withLock({ $0 }) { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard ready.withLock({ $0 }), let p = listener.port?.rawValue else { return nil }
            port.withLock { $0 = p }
            return p
        }

        func stop() { listener.cancel() }

        private func read(_ box: UncheckedBox<NWConnection>, _ soFar: Data) {
            box.value.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
                var buffer = soFar
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self?.answer(box, String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                } else if done || error != nil {
                    box.value.cancel()
                } else {
                    self?.read(box, buffer)
                }
            }
        }

        private func answer(_ box: UncheckedBox<NWConnection>, _ head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ")
            let path = first.count > 1 ? String(first[1]) : "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            got.withLock {
                $0.append(Got(path: path, host: headers["host"] ?? "", range: headers["range"], key: headers["x-qlab-key"],
                              authorization: headers["authorization"]))
            }
            if path.hasPrefix("/hop/") {
                // one hop of a chain: back to this server under the name the SDK asked it by
                let back = "http://127.0.0.1:\(port.withLock { $0 })" + String(path.dropFirst(4))
                let hop = Data("HTTP/1.1 302 Found\r\nLocation: \(back)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                box.value.send(content: hop, completion: .contentProcessed { _ in box.value.cancel() })
                return
            }
            var bounds: (lower: Int, upper: Int)?
            if let asked = headers["range"], asked.hasPrefix("bytes=") {
                // `bytes=N-M`, or `bytes=N-` to the end (SDK 4.0.2's resume)
                let parts = asked.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                if parts.count == 2, let a = Int(parts[0]) { bounds = (a, parts[1].isEmpty ? Int.max : Int(parts[1]) ?? -1) }
            }
            var response: Data
            if let at = path.range(of: "/sdk/v4.0/"), let body = StubBuild.data(String(path[at.upperBound...])) {
                let stored = String(path[at.upperBound...])
                let redirected = redirect.withLock { (r: inout (path: String, lower: Int)?) -> Bool in
                    guard let rule = r, rule.path == stored, rule.lower == (bounds?.lower ?? 0) else { return false }
                    r = nil
                    return true
                }
                if redirected {
                    let own = port.withLock { $0 }
                    let target = (redirectBase.withLock { $0 } ?? "http://localhost:\(own)") + path
                    response = Data("HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                } else if let b = bounds, b.lower <= b.upper, b.lower < body.count {
                    let upper = min(b.upper, body.count - 1)
                    let slice = body.subdata(in: b.lower..<(upper + 1))
                    response = Data(("HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\n"
                        + "Content-Range: bytes \(b.lower)-\(upper)/\(body.count)\r\nContent-Length: \(slice.count)\r\nConnection: close\r\n\r\n").utf8)
                    response.append(slice)
                } else {
                    response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(body)
                }
            } else {
                response = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
            box.value.send(content: response, completion: .contentProcessed { _ in box.value.cancel() })
        }
    }

    /// The real background session, with every request it is handed kept for the test to read.
    final class Recording: BackgroundRangeTransport, @unchecked Sendable {
        let session: BackgroundDownloader
        let requests = Locked<[URLRequest]>([])

        init(_ session: BackgroundDownloader) { self.session = session }

        func start(_ request: URLRequest, key: String) {
            requests.withLock { $0.append(request) }
            session.start(request, key: key)
        }

        func pending(prefix: String) async -> Set<String> { await session.pending(prefix: prefix) }
        func cancel(prefix: String) async -> Set<String> { await session.cancel(prefix: prefix) }
    }

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The suite's stub for what stays in the process: the model host's answers to the foreground (any range the
    /// foreground fetches itself), from the same build.
    @discardableResult
    static func serveForeground() throws -> String { StubBuild.serve() }

    /// The foreground's requests for a stored file: `whole` (no Range, SDK 4.0.2), `N-` or `N-M`.
    static func foreground(of path: String) -> [String] {
        BackgroundDownloadTests.foreground(StubProtocol.seen, of: path)
    }

    /// An install whose model host is the loopback server and whose ranges all go by a real background session.
    func makeClient(_ storage: URL, port: UInt16) throws -> (client: StubInstall, transport: Recording) {
        let downloader = BackgroundDownloader.shared(identifier: "ai.quranlab.models.test." + UUID().uuidString, parallel: 4)
        let transport = Recording(downloader)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/models/Quran-Lab/tajweedformer-v4/\(StubBuild.build)/sdk/v4.0/"))
        let install = StubInstall(storage: storage, transport: transport, policy: .fromFirstByte, handOver: DownloadHandOver(), base: base)
        downloader.attach(install.sink)
        return (install, transport)
    }

    /// Every file is fetched by the system's background download tasks from the loopback server, one task per file
    /// asking the whole file with no Range (SDK 4.0.2, SPEC 16.7), placed by the SDK's delegate and joined by the
    /// installer; the model opens, so every file's hash is right. Each task carried the key and the install's token.
    func testARealBackgroundSessionFetchesTheRangesAndTheModelOpens() async throws {
        let server = try Server()
        guard let port = await server.start() else { return XCTFail("the loopback server did not start") }
        defer { server.stop() }
        let build = try Self.serveForeground()
        let storage = CloudFixtures.storage()
        let (client, transport) = try makeClient(storage, port: port)
        defer { client.close() }
        let got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        // the stub names no protocol for the foreground's requests: this record is the background session's
        XCTAssertEqual(ModelDownloadRecord.networkProtocol, "http/1.1",
                       "the protocol the background session's ranges went by is kept for diagnose()")
        let asked = server.got.withLock { $0 }
        XCTAssertEqual(asked.count, StubBuild.files.count, "the background session asked the loopback server once per file")
        XCTAssertTrue(asked.allSatisfy { $0.key == CloudFixtures.key }, "every background task carried the key")
        XCTAssertTrue(asked.allSatisfy { $0.authorization == "Bearer qlt_v1.eyJ2IjoxfQ.sig" }, "and the install's token")
        XCTAssertTrue(asked.allSatisfy { $0.range == nil }, "each for its whole file, with no Range")
        XCTAssertEqual(asked.filter { $0.path.hasSuffix("/sdk/v4.0/layers.zfw.qle") }.count, 1)
        let handed = transport.requests.withLock { $0 }
        XCTAssertTrue(handed.allSatisfy { $0.allowsExpensiveNetworkAccess && $0.allowsConstrainedNetworkAccess }, "a first install goes on any network")
        XCTAssertTrue(handed.allSatisfy { $0.assumesHTTP3Capable })
        print("background session: the foreground fetched these ranges of the weights file itself: \(Self.foreground(of: StubBuild.weights))")
    }

    /// The loopback server answers the weights file's task with a redirect to another host name. The system follows
    /// it without asking the SDK and delivers the bytes. The SDK refuses them: nothing of them is kept, the issue
    /// `update_failed`, `model_redirected:<host>` is queued with the host only, and the file is fetched again from the
    /// model host. The model opens.
    func testARedirectTheSystemFollowedIsRefusedAndReported() async throws {
        let server = try Server()
        guard let port = await server.start() else { return XCTFail("the loopback server did not start") }
        defer { server.stop() }
        server.redirect.withLock { $0 = (path: StubBuild.weights, lower: 0) }
        let build = try Self.serveForeground()
        let (client, _) = try makeClient(CloudFixtures.storage(), port: port)
        defer { client.close() }
        let got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertNil(server.redirect.withLock { $0 }.map { $0.path }, "the redirect was given")
        let asked = server.got.withLock { $0 }
        let followed = asked.filter { $0.host.hasPrefix("localhost") }
        XCTAssertFalse(followed.isEmpty, "the system followed the redirect to the other host: \(asked.map { $0.host + $0.path }.suffix(4))")
        print("background session: the followed request carried the key header: \(followed.map { $0.key != nil })")
        XCTAssertEqual(Set(client.redirects.withLock { $0 }), ["model_redirected:localhost"], "the host, and nothing else of the address")
        // the refused file was asked for again from the model host: by a second background task, or by the foreground
        let again = asked.filter { $0.host.hasPrefix("127.0.0.1") && $0.path.hasSuffix("/sdk/v4.0/layers.zfw.qle") && $0.range == nil }.count
        XCTAssertTrue(again >= 2 || Self.foreground(of: StubBuild.weights).contains("whole"),
                      "the refused file was fetched again from the model host (\(again) requests there)")
    }

    /// A task that ends before a sink is attached (the system started the app for the session's events, and the
    /// Client is not made yet): what it brought is kept, and placed when the sink is attached.
    func testWhatEndsBeforeTheSinkIsAttachedIsKeptAndPlacedWhenItIs() async throws {
        let server = try Server()
        guard let port = await server.start() else { return XCTFail("the loopback server did not start") }
        defer { server.stop() }
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
                               auth: .fixed(key: "k", token: "t"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        let made = await client.backgroundRequest(client.fileURL(.v4_0, revision: "abc", path: StubBuild.weights), lower: 0, upper: 99, validator: nil)
        let request = try XCTUnwrap(made)
        let storage = CloudFixtures.storage()
        let folder = "models/v4.0/.download-test"
        try FileManager.default.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        let downloader = BackgroundDownloader.shared(identifier: "ai.quranlab.models.test." + UUID().uuidString, parallel: 2)
        let range = BackgroundRange(folder: folder, path: StubBuild.weights, lower: 0, upper: 99, size: Int64(try XCTUnwrap(StubBuild.data(StubBuild.weights)).count))
        downloader.start(request, key: range.key)
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if await downloader.pending(prefix: BackgroundRange.prefix(folder: folder)).isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pending = await downloader.pending(prefix: BackgroundRange.prefix(folder: folder))
        XCTAssertEqual(pending, [], "the task ended")
        let kept = BackgroundRange.file(part: BackgroundRange.part(storage.appendingPathComponent(folder), range.path), lower: 0)
        XCTAssertEqual(ModelInstaller.sizeOnDisk(kept), 0, "nothing is placed while no sink is attached")
        downloader.attach(RangeDelivery.Sink(storage: storage, refused: { _ in }, redirected: { _ in }))
        XCTAssertEqual(ModelInstaller.sizeOnDisk(kept), 100, "what ended before is placed when the sink is attached")
        XCTAssertEqual(try Data(contentsOf: kept), try XCTUnwrap(StubBuild.data(StubBuild.weights)).prefix(100))
    }

    /// (The review's finding 2.) The redirect leads to ANOTHER PORT of the same host: another server. The host's
    /// name is the same, and still the bytes did not come from the address the request was made to: refused and
    /// reported, with the host.
    func testARedirectToAnotherPortOfTheSameHostIsRefusedAndReported() async throws {
        let server = try Server(), other = try Server()
        guard let port = await server.start(), let otherPort = await other.start() else { return XCTFail("a loopback server did not start") }
        defer {
            server.stop()
            other.stop()
        }
        server.redirect.withLock { $0 = (path: StubBuild.weights, lower: 0) }
        server.redirectBase.withLock { $0 = "http://127.0.0.1:\(otherPort)" }
        let build = try Self.serveForeground()
        let (client, _) = try makeClient(CloudFixtures.storage(), port: port)
        defer { client.close() }
        let got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(other.got.withLock { $0.count }, 1, "the system followed the redirect to the other port")
        XCTAssertEqual(Set(client.redirects.withLock { $0 }), ["model_redirected:127.0.0.1"], "refused and reported, though the host's name is the same")
    }

    /// (The review's finding 2.) A chain: the model host redirects to another host, which redirects back to the
    /// model host, which then serves. The answer's address is the model host's, and still the request and its
    /// headers went by the other host: refused and reported.
    func testARedirectChainThatLeadsBackToTheModelHostIsRefusedAndReported() async throws {
        let server = try Server()
        guard let port = await server.start() else { return XCTFail("the loopback server did not start") }
        defer { server.stop() }
        server.redirect.withLock { $0 = (path: StubBuild.weights, lower: 0) }
        server.redirectBase.withLock { $0 = "http://localhost:\(port)/hop" }
        let build = try Self.serveForeground()
        let (client, _) = try makeClient(CloudFixtures.storage(), port: port)
        defer { client.close() }
        let got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let asked = server.got.withLock { $0 }
        XCTAssertTrue(asked.contains { $0.host.hasPrefix("localhost") && $0.path.hasPrefix("/hop/") }, "the system went by the other host")
        XCTAssertEqual(Set(client.redirects.withLock { $0 }), ["model_redirected:127.0.0.1"], "refused and reported: the bytes came by a redirect")
    }

    /// SDK 4.0.2 (section 33): the request of a background task never waits for an unmetered network (both of the
    /// system's marks allow any network; to 4.0.1 an update's carried them), and carries the key, the token, the range
    /// and the validator. The real session takes such a task and the loopback server serves it.
    func testABackgroundTaskGoesOverAnyNetwork() async throws {
        let server = try Server()
        guard let port = await server.start() else { return XCTFail("the loopback server did not start") }
        defer { server.stop() }
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
                               auth: .fixed(key: "k", token: "t"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        let url = client.fileURL(.v4_0, revision: "abc", path: StubBuild.weights)
        let made = await client.backgroundRequest(url, lower: 0, upper: 99, validator: "\"one\"")
        let request = try XCTUnwrap(made)
        XCTAssertTrue(request.allowsExpensiveNetworkAccess)
        XCTAssertTrue(request.allowsConstrainedNetworkAccess)
        XCTAssertTrue(request.allowsCellularAccess)
        XCTAssertEqual(request.value(forHTTPHeaderField: "range"), "bytes=0-99")
        XCTAssertEqual(request.value(forHTTPHeaderField: "if-range"), "\"one\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-qlab-key"), "k")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer t")
        // the real session runs it
        let storage = CloudFixtures.storage()
        let folder = "models/v4.0/.download-test"
        try FileManager.default.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        let downloader = BackgroundDownloader.shared(identifier: "ai.quranlab.models.test." + UUID().uuidString, parallel: 2)
        downloader.attach(RangeDelivery.Sink(storage: storage, refused: { _ in }, redirected: { _ in }))
        let range = BackgroundRange(folder: folder, path: StubBuild.weights, lower: 0, upper: 99, size: Int64(try XCTUnwrap(StubBuild.data(StubBuild.weights)).count))
        downloader.start(request, key: range.key)
        let kept = BackgroundRange.file(part: BackgroundRange.part(storage.appendingPathComponent(folder), range.path), lower: 0)
        let end = Date().addingTimeInterval(30)
        while ModelInstaller.sizeOnDisk(kept) == 0, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ModelInstaller.sizeOnDisk(kept), 100, "the range was fetched and kept")
        XCTAssertEqual(try Data(contentsOf: kept), try XCTUnwrap(StubBuild.data(StubBuild.weights)).prefix(100))
    }

    /// SDK 4.0.2 (section 33.3), no_wait_40.json `queued_by_401_metered`: a range task that 4.0.1 left in the session
    /// with an unmetered-only request (the system keeps a task's request, its two marks included, across processes and
    /// an update of the app: measured on the Mac with a background session made again in a second process) does not
    /// keep waiting. The session made again (`liftNetworkConditions`, at its first use in the process) cancels it and
    /// makes the same request again under the same name with both marks allowing any network; that task fetches the
    /// range, and nothing else is touched (a task that waits for nothing stays as it is).
    func testARangeTaskThat401LeftWaitingForWiFiGoesOn() async throws {
        let server = try Server()
        guard let port = await server.start() else { return XCTFail("the loopback server did not start") }
        defer { server.stop() }
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")),
                               auth: .fixed(key: "k", token: "t"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        let url = client.fileURL(.v4_0, revision: "abc", path: StubBuild.weights)
        let storage = CloudFixtures.storage()
        let folder = "models/v4.0/.download-test"
        try FileManager.default.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        let downloader = BackgroundDownloader.shared(identifier: "ai.quranlab.models.test." + UUID().uuidString, parallel: 2)
        downloader.attach(RangeDelivery.Sink(storage: storage, refused: { _ in }, redirected: { _ in }))
        // the lift the session's first use starts has found an empty session
        try await Task.sleep(nanoseconds: 300_000_000)
        let size = Int64(try XCTUnwrap(StubBuild.data(StubBuild.weights)).count)
        // 4.0.1's request of an update's range, as its CDNClient made it, left in the session (not resumed: on a Mac
        // the loopback is never metered, so a resumed one would run at once)
        let made401 = await client.backgroundRequest(url, lower: 0, upper: 99, validator: nil)
        var waiting = try XCTUnwrap(made401)
        waiting.allowsExpensiveNetworkAccess = false
        waiting.allowsConstrainedNetworkAccess = false
        XCTAssertTrue(BackgroundDownloader.waitsForANetwork(waiting))
        let range = BackgroundRange(folder: folder, path: StubBuild.weights, lower: 0, upper: 99, size: size)
        let old = downloader.session.downloadTask(with: waiting)
        old.taskDescription = range.key
        // and one that waits for nothing (another range): it stays as it is
        let madeFree = await client.backgroundRequest(url, lower: 100, upper: 199, validator: nil)
        let free = try XCTUnwrap(madeFree)
        XCTAssertFalse(BackgroundDownloader.waitsForANetwork(free))
        let other = BackgroundRange(folder: folder, path: StubBuild.weights, lower: 100, upper: 199, size: size)
        let kept = downloader.session.downloadTask(with: free)
        kept.taskDescription = other.key
        let lifted = await downloader.liftNetworkConditions()
        XCTAssertEqual(lifted, [range.key], "the waiting task, and only it, is made again")
        let now = await downloader.session.allTasks.filter { $0.state == .running || $0.state == .suspended }
        let again = now.filter { $0.taskDescription == range.key }
        XCTAssertEqual(again.count, 1, "one task under the range's name")
        XCTAssertNotEqual(again.first?.taskIdentifier, old.taskIdentifier)
        let made = try XCTUnwrap(again.first?.originalRequest)
        XCTAssertFalse(BackgroundDownloader.waitsForANetwork(made), "its request waits for no network")
        XCTAssertEqual(made.value(forHTTPHeaderField: "range"), "bytes=0-99")
        XCTAssertEqual(made.value(forHTTPHeaderField: "authorization"), "Bearer t")
        XCTAssertTrue(now.contains { $0.taskIdentifier == kept.taskIdentifier }, "the task that waited for nothing is left as it is")
        let second = await downloader.liftNetworkConditions()
        XCTAssertEqual(second, [], "nothing more to make again")
        let file = BackgroundRange.file(part: BackgroundRange.part(storage.appendingPathComponent(folder), range.path), lower: 0)
        let end = Date().addingTimeInterval(30)
        while ModelInstaller.sizeOnDisk(file) == 0, Date() < end { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(ModelInstaller.sizeOnDisk(file), 100, "the range was fetched and kept")
        var left = await downloader.pending(prefix: BackgroundRange.prefix(folder: folder))
        while left != [other.key], Date() < end {
            try await Task.sleep(nanoseconds: 50_000_000)
            left = await downloader.pending(prefix: BackgroundRange.prefix(folder: folder))
        }
        XCTAssertEqual(left, [other.key], "the new task counts as under way until its own end, not the old one's")
        kept.cancel()
    }
}
