import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The model download on a network that fails (Apple 3.1.5, SPEC 16), on 4.0's encrypted builds: the installer and the
/// CDN client over a stub download server that answers ranges as a real one does (206 with the bytes asked for, an
/// ETag, the whole file when `If-Range` names another ETag). 3.1.5 ran these through the public Client on a plaintext
/// folder; in 4.0 a build is installed only under a lease the Core holds, which a unit test cannot get from a stub
/// server, so they run one layer down, on the same code: `ModelInstaller` with `CDNFileSource` and `HTTPClient`. The
/// file is a CDN form (`qle1`, random bytes standing for ciphertext); the Core's install is a stand-in that checks the
/// CDN form it is handed and writes a device form of the right size. The whole path through a real lease, a real Core
/// and a real network is Stage B's staging run.
/// - a range is written to disk as it arrives, so a connection that ends keeps what it delivered;
/// - a range that fails for the network's sake is taken up again, at most five times per file in one call, after
///   pauses; a refusal is never retried; a cancelled call ends a pause at once;
/// - the partial file keeps the validator of the answer that started it and sends it with every later range; a 200
///   to a range request replaces the partial file; the hash of the whole CDN form stays the last word;
/// - an answer that says success and is not the file is a failed attempt that costs no stored byte; a 416 and a
///   partial file larger than the file remove it;
/// - nothing writes a decrypted file: the CDN form is handed to the Core only once it is whole and verified against
///   the signed manifest's size and SHA-256 of the CDN form, and it goes once the Core has installed it.
final class ModelDownloadTests: XCTestCase {
    typealias Reply = StubProtocol.Reply
    let fm = FileManager.default

    static let base = URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/")!
    static let weights = "layers.zfw.qle"
    /// The CDN form of the weights: bytes that stand for ciphertext.
    static let stored: Data = {
        var g = SystemRandomNumberGenerator()
        return Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &g) })
    }()
    static let file = ModelManifest.File(path: weights, size: Int64(stored.count), sha256: Data(SHA256.hash(data: stored)).hex,
                                         role: "weights", encoding: "qle1",
                                         decoded: .init(path: "layers.zfw", size: 299_000, sha256: String(repeating: "0", count: 64)))

    override func tearDown() {
        StubProtocol.reset { _ in .down }
    }

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
    static func served(_ seen: StubProtocol.Seen, data: Data = stored, etag: String? = "\"one\"") -> Reply {
        var headers = ["content-type": "application/octet-stream"]
        if let etag { headers["etag"] = etag }
        guard let asked = range(seen), asked.lower < data.count else { return Reply(status: 200, headers: headers, body: data) }
        if let condition = seen.headers["if-range"], condition != etag { return Reply(status: 200, headers: headers, body: data) }
        let upper = min(asked.upper, data.count - 1)
        headers["content-range"] = "bytes \(asked.lower)-\(upper)/\(data.count)"
        return Reply(status: 206, headers: headers, body: data.subdata(in: asked.lower..<(upper + 1)))
    }

    /// The stub server: `reply` answers the weights' requests.
    func serve(_ reply: @escaping @Sendable (StubProtocol.Seen) -> Reply) {
        StubProtocol.reset { seen in seen.url.lastPathComponent == Self.weights ? reply(seen) : Reply(status: 404) }
    }

    static var weightRequests: [StubProtocol.Seen] { StubProtocol.seen.filter { $0.url.lastPathComponent == weights } }

    /// The Core's install, a stand-in: it is handed the CDN form only when it is whole and verified, and writes the
    /// device form (`.qld`, of the size the Core's would have). `refuse`: a failure to throw instead (no lease yet).
    final class CoreStandIn: @unchecked Sendable {
        let installed = Locked<[String]>([])
        let refuse = Locked<RecognizerError?>(nil)
        func install(in folder: URL) -> EncryptedInstall {
            EncryptedInstall { (f: ModelManifest.File) throws(RecognizerError) in
                if let e = self.refuse.withLock({ $0 }) { throw e }
                let cdn = folder.appendingPathComponent(f.path)
                guard let bytes = try? Data(contentsOf: cdn), bytes.count == f.size, Data(SHA256.hash(data: bytes)).hex == f.sha256 else {
                    throw RecognizerError.checksumMismatch(file: f.path)
                }
                try? Data(count: Int(f.deviceFormSize)).write(to: folder.appendingPathComponent(f.localPath + ".qld"))
                self.installed.withLock { $0.append(f.path) }
            }
        }
    }

    func installer(pauses: [TimeInterval] = [], core: CoreStandIn, folder: URL, rangeSize: Int64 = 8 << 20) -> ModelInstaller {
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        var i = ModelInstaller(source: client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: Self.base),
                               rangeSize: rangeSize, retryPauses: pauses)
        i.install = core.install(in: folder)
        return i
    }

    func folder() throws -> URL {
        let f = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-b")
        try fm.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    var part: (URL) -> URL { { $0.appendingPathComponent(Self.weights + ".part") } }

    /// One `ensure` of the weights: nil when it installed, else its error.
    static func ensure(_ i: ModelInstaller, _ folder: URL) async -> RecognizerError? {
        var report = InstallReport()
        do throws(RecognizerError) {
            try await i.ensure(Self.file, in: folder, report: &report)
            return nil
        } catch {
            return error
        }
    }

    /// What the folder holds: no decrypted file, and after an install only the device form.
    func assertInstalledOnlyAsDeviceForm(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) {
        let names = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        XCTAssertEqual(names, ["layers.zfw.qld"], "the device form only: no CDN form, no partial file, no validator, no plaintext", file: file, line: line)
    }

    // MARK: written as it arrives

    /// The connection ends after 150 bytes of the CDN form's first range. Those bytes are kept: the download is
    /// taken up again from byte 150, with the validator of the answer that started the file, and the Core installs
    /// the whole, verified CDN form.
    func testABrokenConnectionKeepsWhatItDelivered() async throws {
        let size = Self.stored.count
        let broke = Locked(false)
        serve { seen in
            let first = broke.withLock { (b: inout Bool) -> Bool in defer { b = true }; return !b }
            var reply = Self.served(seen)
            if first { reply.breakAfter = 150 }
            return reply
        }
        let dir = try folder(), core = CoreStandIn()
        let error = await Self.ensure(installer(pauses: [0], core: core, folder: dir), dir)
        XCTAssertNil(error)
        let asked = Self.weightRequests
        XCTAssertEqual(asked.map { $0.headers["range"] }, ["bytes=0-\(size - 1)", "bytes=150-\(size - 1)"],
                       "the second request goes on from the byte after the last one that arrived")
        XCTAssertNil(asked.first?.headers["if-range"], "a file that starts has no validator")
        XCTAssertEqual(asked.last?.headers["if-range"], "\"one\"", "the validator of the answer that started the partial file")
        XCTAssertEqual(core.installed.withLock { $0 }, [Self.weights], "installed once, whole")
        assertInstalledOnlyAsDeviceForm(dir)
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
        let cases: [(name: String, reply: Reply, requests: Int, code: String)] = [
            ("no answer", .down, 6, "download_failed"),
            ("a server error", Reply(status: 503, body: Data("{\"error\":\"storage_unavailable\"}".utf8)), 6, "download_failed"),
            ("403 model_not_allowed", .json(["error": "model_not_allowed", "message": "no"], status: 403), 1, "server_rejected"),
            ("429 model_limit", .json(["error": "model_limit", "message": "later"], status: 429), 1, "download_failed"),
            ("a refusal that stops the model", .json(["error": "missing or invalid x-qlab-key", "reason": "key_revoked"], status: 401), 1, "invalid_key"),
        ]
        for c in cases {
            let reply = c.reply
            serve { _ in reply }
            let dir = try folder(), core = CoreStandIn()
            let error = await Self.ensure(installer(pauses: [0, 0, 0, 0, 0], core: core, folder: dir), dir)
            XCTAssertNotNil(error, c.name)
            XCTAssertEqual(error.map { TajweedError(from: $0).code }, c.code, c.name)
            XCTAssertEqual(Self.weightRequests.count, c.requests, "\(c.name): the requests for the file")
            XCTAssertEqual(core.installed.withLock { $0 }, [], "\(c.name): nothing handed to the Core")
        }
    }

    /// The pauses are waited: two retries after 0.3 seconds each take at least 0.6 seconds. And the network coming
    /// back in the middle ends the retries: the third request is served and the file is installed.
    func testThePausesAreWaitedAndAServedRetryGoesOn() async throws {
        let failures = Locked(0)
        serve { seen in
            let n = failures.withLock { (f: inout Int) -> Int in f += 1; return f }
            return n <= 2 ? .down : Self.served(seen)
        }
        let dir = try folder(), core = CoreStandIn()
        let started = Date()
        let error = await Self.ensure(installer(pauses: [0.3, 0.3, 0.3, 0.3, 0.3], core: core, folder: dir), dir)
        XCTAssertNil(error)
        XCTAssertEqual(Self.weightRequests.count, 3, "two failures, then served")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.6, "the two pauses were waited")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    /// A call that is cancelled ends the wait before a retry at once: with a pause of a minute, the call returns
    /// within seconds of its cancellation, and no further request is made.
    func testACancelledCallEndsThePauseAtOnce() async throws {
        serve { _ in .down }
        let dir = try folder(), core = CoreStandIn()
        let i = installer(pauses: [60, 60, 60, 60, 60], core: core, folder: dir)
        // (the type by name, and the captures listed: Swift 6.3's region checker cannot check `Self` in this closure)
        let call = Task { [i, dir] in await ModelDownloadTests.ensure(i, dir) }
        let deadline = Date().addingTimeInterval(20)
        while Self.weightRequests.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        call.cancel()
        let error = await call.value
        XCTAssertNotNil(error)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 10, "the minute was not waited")
        XCTAssertEqual(Self.weightRequests.count, 1, "no request after the cancellation")
    }

    // MARK: the validator

    /// An install that stopped with 150 bytes of the CDN form: the partial file and, beside it, the ETag of the
    /// answer that started it (nil for a server that sends none). Returns the folder.
    func interrupted(etag: String?) async throws -> URL {
        let broke = Locked(false)
        serve { seen in
            let first = broke.withLock { (b: inout Bool) -> Bool in defer { b = true }; return !b }
            guard first else { return .down }
            var reply = Self.served(seen, etag: etag)
            reply.breakAfter = 150
            return reply
        }
        let dir = try folder()
        let error = await Self.ensure(installer(core: CoreStandIn(), folder: dir), dir)
        XCTAssertNotNil(error, "the download stopped")
        XCTAssertEqual(ModelInstaller.sizeOnDisk(part(dir)), 150, "what arrived before the connection ended")
        XCTAssertEqual(fm.fileExists(atPath: ModelInstaller.validatorFile(part(dir)).path), etag != nil, "the validator beside the partial file")
        return dir
    }

    /// The file changed on the server while the partial file waited (another ETag): the range request carries the
    /// kept validator, the server answers with the whole file, and that replaces the partial file. Nothing of the
    /// old 150 bytes is joined to it, and the CDN form verifies and is installed. 4.0.1: the whole file's SHA-256 is
    /// made as it is written, and becomes the partial file's when it takes its place; the file is not read again.
    func testAFileThatChangedOnTheServerReplacesThePartialFile() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: "\"one\"")
        // make the kept bytes wrong, as the bytes of another file would be: only a replacement verifies
        try Data(repeating: 0x5a, count: 150).write(to: part(dir))
        serve { seen in Self.served(seen, etag: "\"two\"") }
        let core = CoreStandIn()
        let readAgain = PartHasher.readAgain.withLock { $0 }
        let error = await Self.ensure(installer(core: core, folder: dir), dir)
        XCTAssertNil(error)
        let asked = Self.weightRequests
        XCTAssertEqual(asked.map { $0.headers["range"] }, ["bytes=150-\(size - 1)"], "one request: the rest of the file")
        XCTAssertEqual(asked.first?.headers["if-range"], "\"one\"", "with the validator of the answer that started the partial file")
        XCTAssertEqual(PartHasher.readAgain.withLock { $0 }, readAgain, "the whole file's hash was made as it arrived")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    /// The same file on the server: the kept validator matches, the server sends the rest, and it is appended.
    /// 4.0.1: the 150 bytes on disk are hashed once when the call starts, the rest as it arrives, and the file is not
    /// read again after its last byte.
    func testAnUnchangedFileGoesOnFromThePartialFile() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: "\"one\"")
        serve { seen in Self.served(seen) }
        let readAgain = PartHasher.readAgain.withLock { $0 }, resumed = PartHasher.resumedBytes.withLock { $0 }
        let error = await Self.ensure(installer(core: CoreStandIn(), folder: dir), dir)
        XCTAssertNil(error)
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=150-\(size - 1)"])
        XCTAssertEqual(Self.weightRequests.first?.headers["if-range"], "\"one\"")
        XCTAssertEqual(PartHasher.resumedBytes.withLock { $0 } - resumed, 150, "the bytes kept from the earlier call, hashed first")
        XCTAssertEqual(PartHasher.readAgain.withLock { $0 }, readAgain, "no second read of the file after its last byte")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    /// The hash made as the bytes arrive decides as the whole file's did: a partial file whose kept bytes are not the
    /// file's (no validator, so the rest is appended to them) fails its SHA-256, goes, and the file starts again;
    /// the Core never sees it. Covered with the server's own bytes in `testWithoutAValidatorTheHashOfTheWholeFileDecides`;
    /// here the kept bytes themselves are wrong, which only the resumed hash can see.
    func testAResumedHashCoversTheBytesKeptOnDisk() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: nil)
        try Data(repeating: 0x33, count: 150).write(to: part(dir))
        serve { seen in Self.served(seen, etag: nil) }
        let core = CoreStandIn()
        let error = await Self.ensure(installer(core: core, folder: dir), dir)
        XCTAssertNil(error)
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=150-\(size - 1)", "bytes=0-\(size - 1)"],
                       "the kept bytes made the file fail its SHA-256, so it started again")
        XCTAssertEqual(core.installed.withLock { $0 }, [Self.weights], "the Core was handed the verified CDN form only")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    // MARK: 4.0.1: several files at a time

    /// A build's files of different sizes, in the manifest's order, each a CDN form of random bytes.
    static func files(_ sizes: [(String, Int)]) -> (files: [ModelManifest.File], data: [String: Data]) {
        var g = SystemRandomNumberGenerator()
        var files: [ModelManifest.File] = [], data: [String: Data] = [:]
        for (name, size) in sizes {
            let bytes = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &g) })
            data[name] = bytes
            files.append(ModelManifest.File(path: name, size: Int64(size), sha256: Data(SHA256.hash(data: bytes)).hex, role: "weights", encoding: "qle1",
                                            decoded: .init(path: String(name.dropLast(4)), size: Int64(max(1, size - 100)), sha256: String(repeating: "0", count: 64))))
        }
        return (files, data)
    }

    /// Many files: at most four are on their way at once, the largest first, so the big file starts at once and the
    /// small ones fill the other places; no fifth request is made while four wait. The Core installs every file
    /// once, one at a time, in the manifest's order (the build's layout before the weights it keys, 18.7.4), and
    /// only the device forms stay.
    func testAtMostFourFilesAtOnceTheLargestFirstAndTheCoreInManifestOrder() async throws {
        let (files, data) = Self.files([("layout.json.qle", 2_000), ("layers.zfw.qle", 300_000), ("frontend.zfw.qle", 40_000),
                                        ("tokens.txt.qle", 1_000), ("c16_l64/graph.zfg.qle", 60_000), ("c16_l64/frames.zfw.qle", 50_000),
                                        ("calibration.qle", 3_000)])
        let gate = StubProtocol.Gate()
        StubProtocol.reset { seen in
            let name = seen.url.path.components(separatedBy: "/sdk/v4.0/").last ?? ""
            guard let d = data[name] else { return Reply(status: 404) }
            var reply = Self.served(seen, data: d)
            reply.hold = gate
            return reply
        }
        let dir = try folder(), core = CoreStandIn()
        let i = installer(core: core, folder: dir)
        let call = Task { () -> RecognizerError? in
            var report = InstallReport()
            do throws(RecognizerError) {
                try await i.ensureAll(files, in: dir, report: &report, counted: false)
                return nil
            } catch {
                return error
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while StubProtocol.seen.count < 4, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let first = StubProtocol.seen.map { $0.url.path.components(separatedBy: "/sdk/v4.0/").last ?? "" }
        XCTAssertEqual(first.count, 4, "four on their way, and no fifth while they wait: \(first)")
        XCTAssertEqual(Set(first), ["layers.zfw.qle", "c16_l64/graph.zfg.qle", "c16_l64/frames.zfw.qle", "frontend.zfw.qle"],
                       "the four largest (the four start together, so the order they reach the server in is the network's)")
        XCTAssertEqual(core.installed.withLock { $0 }, [], "nothing installed while the files wait")
        gate.open()
        let error = await call.value
        XCTAssertNil(error, "\(String(describing: error))")
        XCTAssertEqual(StubProtocol.seen.count, files.count, "each file asked for once")
        XCTAssertEqual(core.installed.withLock { $0 }, files.map(\.path), "the Core's installs in the manifest's order, each once")
        let left = (fm.enumerator(atPath: dir.path)?.compactMap { $0 as? String } ?? []).filter { !$0.hasSuffix("c16_l64") }.sorted()
        XCTAssertEqual(left, files.map { $0.localPath + ".qld" }.sorted(), "the device forms only")
    }

    /// The queue's order is the largest first, then the manifest's order between files of one size.
    func testTheQueueIsTheLargestFirst() {
        let (files, _) = Self.files([("layout.json.qle", 2_000), ("layers.zfw.qle", 300_000), ("tokens.txt.qle", 1_000),
                                     ("c16_l64/frames.zfw.qle", 50_000), ("calibration.qle", 2_000)])
        XCTAssertEqual(ModelInstaller.queue(files).map { files[$0].path },
                       ["layers.zfw.qle", "c16_l64/frames.zfw.qle", "layout.json.qle", "calibration.qle", "tokens.txt.qle"])
    }

    /// The first failure ends the call with its own error at once: a file refused by the server (asked once, as
    /// ever) ends a call whose big file is waiting out a pause after its connection ended; the big file's transfer
    /// stops, and the bytes it wrote stay in its partial file for the next call, which goes on from them.
    func testTheFirstFailureEndsTheCallAndTheOthersKeepWhatTheyWrote() async throws {
        let (files, data) = Self.files([("layers.zfw.qle", 300_000), ("tokens.txt.qle", 1_000), ("frontend.zfw.qle", 40_000)])
        let refuse = Locked(true)
        // the refusal waits until the big file's connection has ended after its first bytes
        let afterTheBreak = StubProtocol.Gate()
        StubProtocol.reset { seen in
            let name = seen.url.path.components(separatedBy: "/sdk/v4.0/").last ?? ""
            guard let d = data[name] else { return Reply(status: 404) }
            if name == "tokens.txt.qle", refuse.withLock({ $0 }) {
                var reply = Reply.json(["error": "model_not_allowed", "message": "no"], status: 403)
                reply.hold = afterTheBreak
                return reply
            }
            var reply = Self.served(seen, data: d)
            if name == "layers.zfw.qle", Self.range(seen)?.lower == 0 { reply.breakAfter = 150 }
            return reply
        }
        let dir = try folder(), core = CoreStandIn()
        let i = installer(pauses: [30, 30, 30, 30, 30], core: core, folder: dir)
        let started = Date()
        let call = Task { () -> RecognizerError? in
            var report = InstallReport()
            do throws(RecognizerError) {
                try await i.ensureAll(files, in: dir, report: &report, counted: false)
                return nil
            } catch {
                return error
            }
        }
        let bigPart = dir.appendingPathComponent("layers.zfw.qle.part")
        let deadline = Date().addingTimeInterval(20)
        while ModelInstaller.sizeOnDisk(bigPart) < 150, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        afterTheBreak.open()
        let failure = await call.value
        XCTAssertEqual(failure.map { TajweedError(from: $0).code }, "server_rejected", "the refusal's own error")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the big file's pause of 30 s was not waited")
        XCTAssertEqual(ModelInstaller.sizeOnDisk(dir.appendingPathComponent("layers.zfw.qle.part")), 150, "what the big file wrote stays")
        XCTAssertEqual(StubProtocol.seen.filter { $0.url.lastPathComponent == "tokens.txt.qle" }.count, 1, "a refusal is asked once")
        // the next call goes on from the partial file
        refuse.withLock { $0 = false }
        StubProtocol.reset { seen in
            let name = seen.url.path.components(separatedBy: "/sdk/v4.0/").last ?? ""
            return data[name].map { Self.served(seen, data: $0) } ?? Reply(status: 404)
        }
        var again = InstallReport()
        do throws(RecognizerError) { try await i.ensureAll(files, in: dir, report: &again, counted: false) } catch { XCTFail("\(error)") }
        XCTAssertEqual(StubProtocol.seen.first { $0.url.lastPathComponent == "layers.zfw.qle" }?.headers["range"], "bytes=150-299999",
                       "the big file goes on from its partial file")
        XCTAssertTrue(again.resumed)
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(files.map(\.path)))
    }

    /// A file's share of the progress counts its bytes once: a file the app's leaving stopped is counted again from
    /// its partial file by the install that goes on one file at a time, and the install's progress takes from that
    /// only what is above the bytes counted for it before; a file that starts again steps back no further than them.
    func testAFilesShareOfTheProgressCountsItsBytesOnce() {
        let told = Locked<[Int64]>([])
        let meter = ProgressMeter { done, _ in told.withLock { $0.append(done) } }
        meter.start(total: 1_000)
        let counted = Locked<Int64>(0)
        let first = ModelInstaller.share(of: meter, size: 600, floor: 0, counted: counted)
        first.add(300)
        XCTAssertEqual(told.withLock { $0.last }, 300)
        XCTAssertEqual(counted.withLock { $0 }, 300, "what the install's progress holds for the file")
        // the file goes on one file at a time: counted again from its partial file of 300 bytes, then 200 more arrive
        let again = ModelInstaller.share(of: meter, size: 600, floor: counted.withLock { $0 }, counted: Locked(0))
        again.add(300)
        XCTAssertEqual(told.withLock { $0.last }, 300, "the 300 bytes counted before are not counted twice")
        again.add(200)
        XCTAssertEqual(told.withLock { $0.last }, 500)
        again.add(-500)
        XCTAssertEqual(told.withLock { $0.last }, 300, "a file that starts again steps back to what was counted before it went on")
    }

    /// Progress counted by several transfers at once is told in the order it was counted: never a step back.
    func testProgressFromSeveralTransfersNeverStepsBack() async {
        let told = Locked<[Int64]>([])
        let meter = ProgressMeter { done, _ in told.withLock { $0.append(done) } }
        meter.start(total: 8_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { for _ in 0..<1_000 { meter.add(1) } } }
        }
        let values = told.withLock { $0 }
        XCTAssertEqual(values.last, 8_000)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "the counts as told never go down")
    }

    /// Without a kept validator (a server that sends no ETag) the range is asked for as before, without `If-Range`.
    /// The hash of the whole CDN form stays the last word: when the bytes that come do not belong to the partial
    /// file, the file does not verify, is deleted and starts again from its first byte; the Core never sees it.
    func testWithoutAValidatorTheHashOfTheWholeFileDecides() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: nil)
        let wrong = Locked(true)
        serve { seen in
            guard let asked = Self.range(seen), asked.lower == 150 else { return Self.served(seen, etag: nil) }
            let first = wrong.withLock { (w: inout Bool) -> Bool in defer { w = false }; return w }
            guard first else { return Self.served(seen, etag: nil) }
            return Reply(status: 206, headers: ["content-range": "bytes 150-\(size - 1)/\(size)"], body: Data(repeating: 0x5a, count: size - 150))
        }
        let core = CoreStandIn()
        let error = await Self.ensure(installer(core: core, folder: dir), dir)
        XCTAssertNil(error)
        let asked = Self.weightRequests
        XCTAssertEqual(asked.map { $0.headers["range"] }, ["bytes=150-\(size - 1)", "bytes=0-\(size - 1)"],
                       "the joined file did not verify, so the file started again")
        XCTAssertTrue(asked.allSatisfy { $0.headers["if-range"] == nil }, "no validator was kept, so none is sent")
        XCTAssertEqual(core.installed.withLock { $0 }, [Self.weights], "the Core was handed the verified CDN form only")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    // MARK: an update waits for an unmetered network

    /// The request says whether it may go over a metered network: a first install's may, an update's may not.
    func testAnUpdatesRequestsDoNotGoOverAMeteredNetworkAndAFirstInstallsDo() async throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.test/a/b/c/sdk/v4.0/layers.zfw.qle"))
        let plain = CDNClient.request(url, range: nil, key: "k", token: "t")
        XCTAssertTrue(plain.allowsExpensiveNetworkAccess)
        XCTAssertTrue(plain.allowsConstrainedNetworkAccess)
        let waiting = CDNClient.request(url, range: "bytes=0-9", key: "k", token: "t", ifRange: "\"one\"", unmeteredOnly: true)
        XCTAssertFalse(waiting.allowsExpensiveNetworkAccess)
        XCTAssertFalse(waiting.allowsConstrainedNetworkAccess)
        XCTAssertEqual(waiting.value(forHTTPHeaderField: "if-range"), "\"one\"")
        XCTAssertTrue(CloudOptions().updatesOnWiFiOnly, "an app's Client: updates on unmetered networks only")
        // the same through the client a run makes: an update's client marks every range, a first install's none
        serve { seen in Self.served(seen) }
        for unmetered in [false, true] {
            let dir = try folder()
            var client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                                   auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
            client.unmeteredOnly = unmetered
            var i = ModelInstaller(source: client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: Self.base),
                                   rangeSize: 100_000, retryPauses: [])
            i.install = CoreStandIn().install(in: dir)
            StubProtocol.reset { seen in seen.url.lastPathComponent == Self.weights ? Self.served(seen) : Reply(status: 404) }
            let error = await Self.ensure(i, dir)
            XCTAssertNil(error)
            let asked = Self.weightRequests
            XCTAssertEqual(asked.count, 3, "three ranges of 100,000 bytes")
            XCTAssertTrue(asked.allSatisfy { $0.allowsExpensive == !unmetered && $0.allowsConstrained == !unmetered }, "unmetered only: \(unmetered)")
        }
    }

    // MARK: what a download leaves behind

    /// The working files of a download are removed before its folder is put in place, at any depth: a partial
    /// file, its validator, a range a background task delivered late, a whole file that was on its way. The
    /// model's own files (4.0: the device forms) stay.
    func testTheWorkingFilesOfADownloadDoNotGoIntoTheBuild() throws {
        let folder = CloudFixtures.storage().appendingPathComponent("build")
        try fm.createDirectory(at: folder.appendingPathComponent("c16_l64"), withIntermediateDirectories: true)
        for name in ["layers.zfw.qld", "tokens.txt.qld", "c16_l64/frames.zfw.qld", "layers.zfw.qle.part", "layers.zfw.qle.part.etag",
                     "layers.zfw.qle.part.r100", "c16_l64/frames.zfw.qle.part.r0", "tokens.txt.qle.part.whole"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        ModelUpdater.pruneWorkingFiles(folder)
        let left = (fm.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []).sorted()
        XCTAssertEqual(left, ["c16_l64", "c16_l64/frames.zfw.qld", "layers.zfw.qld", "tokens.txt.qld"])
    }

    // MARK: answers that say success and are not the file (SPEC 16.1)

    /// The seven answers of SPEC 16.5, each given at EVERY attempt to a download that goes on from a partial file
    /// of 150 bytes: a 204; a 200 shorter and one longer than the file; an empty 206; a 206 with another total and
    /// one with another start; a 200 with a JSON body. Each is a failed attempt: the call ends `download_failed`
    /// after the file was asked for once and five times again, the partial file is the same bytes as before, and
    /// the next call finishes from them. The answers carry a Content-Length, as a real server's do.
    func testAnAnswerThatSaysSuccessAndIsNotTheFileIsAFailedAttemptAndCostsNoStoredByte() async throws {
        let whole = Self.stored
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
            let dir = try await interrupted(etag: "\"one\"")
            let before = try Data(contentsOf: part(dir))
            XCTAssertEqual(before, whole.prefix(150), c.name)
            let reply = c.reply
            serve { _ in reply }
            let core = CoreStandIn()
            let error = await Self.ensure(installer(pauses: [0, 0, 0, 0, 0], core: core, folder: dir), dir)
            XCTAssertEqual(error.map { TajweedError(from: $0).code }, "download_failed", c.name)
            XCTAssertEqual(Self.weightRequests.count, 6, "\(c.name): asked once and five times again, each a failed attempt")
            XCTAssertEqual(try? Data(contentsOf: part(dir)), before, "\(c.name): the partial file is the bytes it was")
            XCTAssertEqual(core.installed.withLock { $0 }, [], "\(c.name): nothing handed to the Core")
            // the next call finishes from them
            serve { seen in Self.served(seen) }
            let again = await Self.ensure(installer(core: core, folder: dir), dir)
            XCTAssertNil(again, c.name)
            XCTAssertEqual(Self.weightRequests.first?.headers["range"], "bytes=150-\(size - 1)", "\(c.name): the next call goes on from the partial file")
            assertInstalledOnlyAsDeviceForm(dir)
        }
    }

    /// A failed attempt is followed by its pause like any other failure: with five pauses of 0.2 seconds, a file
    /// that is answered with an empty 206 every time takes at least a second, and is asked for six times.
    func testAFailedAttemptWaitsItsPause() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: "\"one\"")
        let empty = Reply(status: 206, headers: ["content-length": "0", "content-range": "bytes 150-\(size - 1)/\(size)", "etag": "\"one\""])
        serve { _ in empty }
        let started = Date()
        let error = await Self.ensure(installer(pauses: [0.2, 0.2, 0.2, 0.2, 0.2], core: CoreStandIn(), folder: dir), dir)
        XCTAssertNotNil(error)
        XCTAssertEqual(Self.weightRequests.count, 6)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.0, "the five pauses were waited")
    }

    /// A 416: the stored bytes run past the server's file. The partial file is removed and the file starts again
    /// in the same call (one of its five resumes), and the CDN form is installed.
    func testA416RemovesThePartialFileAndTheFileStartsAgain() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: "\"one\"")
        serve { seen in
            guard let asked = Self.range(seen), asked.lower > 0 else { return Self.served(seen) }
            return Reply(status: 416, headers: ["content-range": "bytes */\(size)", "content-length": "0"])
        }
        let error = await Self.ensure(installer(pauses: [0, 0, 0, 0, 0], core: CoreStandIn(), folder: dir), dir)
        XCTAssertNil(error)
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=150-\(size - 1)", "bytes=0-\(size - 1)"],
                       "the partial file went with the 416, and the file was asked for from its first byte")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    /// A partial file larger than the file cannot be a part of it: it is removed when the attempt starts, and the
    /// file is asked for from its first byte, without a validator.
    func testAPartialFileLargerThanTheFileIsRemovedWhenTheAttemptStarts() async throws {
        let size = Self.stored.count
        let dir = try await interrupted(etag: "\"one\"")
        try Data(repeating: 9, count: size + 80).write(to: part(dir))
        serve { seen in Self.served(seen) }
        let error = await Self.ensure(installer(core: CoreStandIn(), folder: dir), dir)
        XCTAssertNil(error)
        XCTAssertEqual(Self.weightRequests.map { $0.headers["range"] }, ["bytes=0-\(size - 1)"])
        XCTAssertNil(Self.weightRequests.first?.headers["if-range"], "the validator went with the partial file")
        assertInstalledOnlyAsDeviceForm(dir)
    }

    // MARK: 4.0: the CDN form and the Core

    /// Ranges of the CDN form in 128 KB steps through a server that ends every second connection early: the partial
    /// file grows only by what arrived, every range goes on from the byte on disk, and the Core gets the CDN form
    /// once, whole. No file of the folder is ever the plaintext.
    func testTheCDNFormIsResumedRangeByRangeAndHandedToTheCoreOnceWhole() async throws {
        let n = Locked(0)
        serve { seen in
            let k = n.withLock { (c: inout Int) -> Int in c += 1; return c }
            var reply = Self.served(seen)
            if k % 2 == 1 { reply.breakAfter = 3000 }
            return reply
        }
        let dir = try folder(), core = CoreStandIn()
        let error = await Self.ensure(installer(pauses: [0, 0, 0, 0, 0], core: core, folder: dir, rangeSize: 128 << 10), dir)
        XCTAssertNil(error, "\(String(describing: error))")
        let asked = Self.weightRequests.compactMap { Self.range($0)?.lower }
        XCTAssertEqual(asked.first, 0)
        XCTAssertTrue(zip(asked, asked.dropFirst()).allSatisfy { $0 < $1 }, "every request starts past the last: \(asked)")
        XCTAssertEqual(core.installed.withLock { $0 }, [Self.weights])
        assertInstalledOnlyAsDeviceForm(dir)
    }

    /// A CDN form a stopped install left (the Core had no lease then): kept, and installed at the next call without
    /// a download. A CDN form the Core refuses as damaged goes, and is downloaded once more.
    func testACDNFormWithoutALeaseIsKeptAndInstalledLaterWithoutADownload() async throws {
        serve { seen in Self.served(seen) }
        let dir = try folder(), core = CoreStandIn()
        core.refuse.withLock { $0 = .offline("needs_connection: no install key or lease yet") }
        let first = await Self.ensure(installer(core: core, folder: dir), dir)
        XCTAssertEqual(first.map { TajweedError(from: $0).code }, "needs_connection")
        XCTAssertEqual(try? Data(contentsOf: dir.appendingPathComponent(Self.weights)), Self.stored, "the verified CDN form stays")
        let asked = Self.weightRequests.count
        core.refuse.withLock { $0 = nil }
        let second = await Self.ensure(installer(core: core, folder: dir), dir)
        XCTAssertNil(second)
        XCTAssertEqual(Self.weightRequests.count, asked, "no download: the CDN form on disk was installed")
        assertInstalledOnlyAsDeviceForm(dir)
    }
}
