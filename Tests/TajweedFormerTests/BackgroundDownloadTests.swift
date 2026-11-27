import Foundation
import XCTest
@testable import TajweedFormer

/// The model download's background transport (3.1.5), with a STAND-IN for the background session: no background
/// URLSession is made here, no app is suspended and nothing runs out of process. 4.0: on the installer a run makes,
/// over the stub build's CDN forms (`StubBuild`, `StubInstall`): 3.1.5 ran these through the public Client on a
/// plaintext folder, and a 4.0 build installs only under a lease the Core holds. What 3.1.5 read off the Client
/// (the gate, the redirect issue, the abandoned and dropped counts) is read off the install. The stand-in takes the range
/// tasks the installer starts, ends as many of them as the test says (handing each answer to the same
/// `RangeDelivery.deliver` the real session's delegate calls) and keeps the rest "in flight" until they are
/// cancelled. "The app leaves the foreground" is the test setting the hand-over's state. What these tests show is
/// the SDK's own bookkeeping: what is handed over, what is joined, that no byte is fetched or written twice, what
/// is counted as abandoned, and what becomes of a redirect or a refusal. That a real background session carries
/// the tasks on while an app is suspended is shown only by a phone.
final class BackgroundDownloadTests: XCTestCase {
    typealias Reply = StubProtocol.Reply
    let fm = FileManager.default

    /// The stand-in for the background session.
    final class StandIn: BackgroundRangeTransport, @unchecked Sendable {
        struct Answer {
            var status = 206
            var body = Data()
            /// The host of the answer's final URL; nil: the host the request was made to.
            var finalHost: String?
            /// The redirects the system counts for the task.
            var redirects = 0
            /// The answer's Content-Range; nil: the range asked for, of the file's size.
            var contentRange: String?
        }

        private let lock = NSLock()
        private var inFlight: [String] = []
        private var inFlightRequests: [String: URLRequest] = [:]
        private var _started: [String] = []
        private var _requests: [URLRequest] = []
        private var _delivered: [String] = []
        private var _cancelled: [String] = []
        private var _outcomes: [RangeDelivery.Outcome] = []
        private var _finishing = Int.max
        private var _sink: RangeDelivery.Sink?
        private var _answer: @Sendable (BackgroundRange) -> Answer = { range in
            guard let data = StubBuild.data(range.path), Int(range.upper) < data.count else { return Answer(status: 404) }
            return Answer(body: data.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var started: [String] { locked { _started } }
        /// The requests of the tasks, as they were handed over.
        var requests: [URLRequest] { locked { _requests } }
        var delivered: [String] { locked { _delivered } }
        var cancelled: [String] { locked { _cancelled } }
        var outcomes: [RangeDelivery.Outcome] { locked { _outcomes } }
        /// How many of the tasks started from now on end at once; the others stay in flight until cancelled.
        func finish(next n: Int) { locked { _finishing = n } }
        func deliver(to sink: RangeDelivery.Sink) { locked { _sink = sink } }
        func answer(_ f: @escaping @Sendable (BackgroundRange) -> Answer) { locked { _answer = f } }

        func start(_ request: URLRequest, key: String) {
            let ends = locked { () -> Bool in
                _started.append(key)
                _requests.append(request)
                let ends = _finishing > 0
                if ends {
                    if _finishing != Int.max { _finishing -= 1 }
                    _delivered.append(key)
                } else {
                    inFlight.append(key)
                    inFlightRequests[key] = request
                }
                return ends
            }
            if ends { land(request, key: key) }
        }

        /// SDK 4.0.2: the tasks in flight end now, each with its answer (the app waits for them after its return). As the
        /// session's delegate does it, a task's file is placed before the task counts as ended.
        func endInFlight() {
            let now = locked { inFlight.compactMap { k in inFlightRequests[k].map { (k, $0) } } }
            for (key, request) in now {
                land(request, key: key)
                locked {
                    inFlight.removeAll { $0 == key }
                    inFlightRequests[key] = nil
                    _delivered.append(key)
                }
            }
        }

        /// A task an earlier process handed to the session (a 4.0.1 range), still on its way.
        func carry(_ key: String) {
            locked {
                inFlight.append(key)
                inFlightRequests[key] = URLRequest(url: URL(string: "https://cdn.quranlab.ai/models/")!)
            }
        }

        /// A task's answer, handed to the sink as the session's delegate hands it.
        private func land(_ request: URLRequest, key: String) {
            let (sink, answer) = locked { (_sink, _answer) }
            guard let sink, let range = BackgroundRange(key: key) else { return }
            let a = answer(range)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("standin-" + UUID().uuidString)
            try? a.body.write(to: file)
            var final = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            if let host = a.finalHost { final?.host = host }
            let arrival = RangeDelivery.Arrival(body: file, key: key, status: a.status, asked: request.url, final: final?.url, redirects: a.redirects,
                                                contentRange: a.contentRange ?? "bytes \(range.lower)-\(range.upper)/\(range.size)")
            let outcome = RangeDelivery.deliver(arrival, sink: sink)
            locked { _outcomes.append(outcome) }
        }

        func pending(prefix: String) async -> Set<String> {
            locked { Set(inFlight.filter { $0.hasPrefix(prefix) }) }
        }

        func cancel(prefix: String) async -> Set<String> {
            locked { () -> Set<String> in
                let gone = inFlight.filter { $0.hasPrefix(prefix) }
                inFlight.removeAll { $0.hasPrefix(prefix) }
                for k in gone { inFlightRequests[k] = nil }
                _cancelled.append(contentsOf: gone)
                return Set(gone)
            }
        }
    }

    override func setUp() {
        // the 3.1.5 tests count the hand-over of an install that fetches one file at a time, which is how 4.0.1 goes
        // on after the app has left; several files at a time before it is `testSeveralFilesAtATimeThenTheRestToTheBackground`
        ModelInstaller.parallelFiles.withLock { $0 = 1 }
    }

    override func tearDown() {
        ModelInstaller.parallelFiles.withLock { $0 = 4 }
    }

    // MARK: 4.0.1: several files at a time, then the background

    /// 4.0.1, policy `whenLeaving`: while the app is in the foreground the files come several at a time. The weights
    /// file's request (SDK 4.0.2: the whole file, SPEC 16.7) is held in flight; meanwhile the frames and the tokens come
    /// whole in the foreground (the frames installed, the tokens' CDN form waiting for its turn, after the weights). The
    /// app leaves: the weights' request is ended, and the file goes to one background task, once; the tokens are not
    /// handed over (their verified CDN form is on disk). The Core installs each file once in the manifest's order, and
    /// nothing of the download is left beside the installed files.
    func testSeveralFilesAtATimeThenTheRestToTheBackgroundWhenTheAppLeaves() async throws {
        ModelInstaller.parallelFiles.withLock { $0 = 4 }
        let first = StubProtocol.Gate()
        let held = Locked(false)
        let build = StubBuild.serve(cdn: { path, seen in
            var reply = StubBuild.served(path, seen)
            if path == Self.weights, (ModelDownloadTests.range(seen)?.lower ?? 0) == 0, held.withLock({ (h: inout Bool) -> Bool in defer { h = true }; return !h }) {
                reply.hold = first
            }
            return reply
        })
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let storage = CloudFixtures.storage()
        let client = try makeClient(storage, standIn, .whenLeaving, handOver)
        defer { client.close() }
        let call = Task { await client.model() }
        let folder = client.folder
        try await Self.wait("the weights' first range in flight") { held.withLock { $0 } }
        try await Self.wait("the frames installed and the tokens' CDN form whole, both by the foreground") {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("c16_l64/frames.zfw.qld").path)
                && ModelInstaller.sizeOnDisk(folder.appendingPathComponent(StubBuild.tokens)) == 248
        }
        XCTAssertEqual(standIn.started, [], "nothing is handed over while the app is in the foreground")
        XCTAssertEqual(client.core.installed.withLock { $0 }, ["c16_l64/frames.zfw.qle"], "the tokens wait for the weights, before them in the manifest")
        handOver.set(away: true)
        let got = await call.value
        handOver.set(away: false)
        first.open()
        XCTAssertEqual(got.build, build, "the model opens: every file's hash is right (\(String(describing: got.error)))")
        XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights), ["0-419"], "the weights, to the background once, as one task")
        XCTAssertNil(standIn.requests.first?.value(forHTTPHeaderField: "range"), "a whole file's task asks it with no Range")
        XCTAssertEqual(Self.ranges(standIn.started, of: StubBuild.tokens), [], "a file whole on disk is not handed over")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: StubBuild.tokens), ["whole"], "the tokens by the foreground, once")
        XCTAssertEqual(StubProtocol.cancelled.withLock { Self.foreground($0, of: Self.weights) }, ["whole"], "the weights' request in flight was ended")
        XCTAssertEqual(client.core.installed.withLock { $0 }, StubBuild.files.map(\.path), "each file once, in the manifest's order")
        let left = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.contains(".part") }
        XCTAssertEqual(left, [], "no partial file and no kept range is left")
    }

    static let weights = StubBuild.weights

    /// An install whose downloads use `standIn` under `policy`; the stand-in hands its answers to the install's own
    /// sink.
    func makeClient(_ storage: URL, _ standIn: StandIn, _ policy: BackgroundDownloadPolicy, _ handOver: DownloadHandOver,
                    sendsKey: Bool = true) throws -> StubInstall {
        let install = StubInstall(storage: storage, transport: standIn, policy: policy, handOver: handOver, sendsKey: sendsKey)
        standIn.deliver(to: install.sink)
        return install
    }

    /// Waits until `done`, at most 20 seconds.
    static func wait(_ what: String, _ done: @escaping @Sendable () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !done() {
            guard Date() < end else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The ranges of a stored file among task names (`<folder>|<path>|<lower>|<upper>`), as `lower-upper`.
    static func ranges(_ keys: [String], of path: String) -> [String] {
        keys.compactMap { BackgroundRange(key: $0) }.filter { $0.path == path }.map { "\($0.lower)-\($0.upper)" }
    }

    /// The foreground requests the stub got for a stored file: `whole` (no Range, SDK 4.0.2), `N-` (a resume to the
    /// end) or `N-M`.
    static func foreground(_ seen: [StubProtocol.Seen], of path: String) -> [String] {
        seen.filter { StubBuild.path($0) == path }.map { s in
            guard let r = ModelDownloadTests.range(s) else { return "whole" }
            return r.upper == Int.max ? "\(r.lower)-" : "\(r.lower)-\(r.upper)"
        }
    }

    // MARK: hand-over and hand-back

    /// SDK 4.0.2 (SPEC 16.7; the rule of 2026-11-21: a learner who leaves and comes back pays for no byte twice). The
    /// weights file is asked whole; 90% of it (378 of 420 bytes) has arrived when the app leaves: the request ends where
    /// it stands, and the rest goes to one background task (`bytes=378-` with the validator), the tokens to another. The
    /// app is back before the tasks end: they are NOT cancelled; the app waits for the weights' task at its first byte
    /// and joins what it brings. The weights' bytes fetched are the file's 420, in two requests (one more than the
    /// file), and the file after it came by its task alone. (To 4.0.1 the tasks were cancelled at the return and the
    /// app fetched their ranges again.)
    func testLeavingAt90PercentAndComingBackFetchesNoByteTwice() async throws {
        let (client, standIn, handOver, build, storage) = try await leaveAt90Percent()
        defer { client.close() }
        // back before the tasks end: they go on, and the app waits for them
        handOver.set(away: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(standIn.cancelled, [], "no task is cancelled at the return")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"], "the app asks nothing more while its task runs")
        standIn.endInFlight()
        let got = await client.call.value
        XCTAssertEqual(got.build, build, "the model opens (\(String(describing: got.error)))")
        XCTAssertEqual(client.install.abandoned.withLock { $0 }, 0, "nothing was abandoned")
        XCTAssertEqual(StubProtocol.cancelled.withLock { Self.foreground($0, of: Self.weights) }, ["whole"],
                       "the request in flight at the leaving ended there")
        // the weights' bytes: 378 by the app, 42 by the task, 420 in all, in two requests
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"])
        XCTAssertEqual(Self.ranges(standIn.delivered, of: Self.weights), ["378-419"])
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: StubBuild.tokens), [], "the tokens came by their task alone")
        let left = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.contains(".part") }
        XCTAssertEqual(left, [], "no partial file and no kept range is left")
    }

    /// The task the app waits for after its return brings no byte within the probe (SDK 4.0.5, contract 38.4: 2 s; here
    /// 0.3 s): it is cancelled and counted as abandoned, and the app resumes the file itself from its partial file,
    /// once, with the validator.
    func testATaskThatBringsNothingAfterTheReturnIsGivenUpAndTheAppResumes() async throws {
        XCTAssertEqual(ModelInstaller.probeLimit.withLock { $0 }, 2, "38.4's PROBE_MS")
        XCTAssertEqual(ModelInstaller.stallLimit.withLock { $0 }, 30, "16.2's 30 s once a byte came")
        ModelInstaller.probeLimit.withLock { $0 = 0.3 }
        defer { ModelInstaller.probeLimit.withLock { $0 = Double(ContinuityRules.probeMs) / 1000 } }
        let (client, standIn, handOver, build, _) = try await leaveAt90Percent()
        defer { client.close() }
        handOver.set(away: false)
        let got = await client.call.value
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.ranges(standIn.cancelled, of: Self.weights), ["378-419"], "the task that brought nothing was given up")
        XCTAssertEqual(client.install.abandoned.withLock { $0 }, 2, "and counted, with the tokens' task")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole", "378-"], "the app resumed the file, once")
        XCTAssertEqual(StubBuild.modelRequests.last { StubBuild.path($0) == Self.weights }?.headers["if-range"], "\"one\"")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: StubBuild.tokens), ["whole"])
    }

    /// A running install and its call, for the tests above.
    struct Running {
        let install: StubInstall
        let call: Task<(build: String?, error: TajweedError?), Never>
        func close() { install.close() }
    }

    /// SDK 4.0.5: every missing stretch is handed to the background in pieces of at most `PIECE` (64
    /// MiB; here 16 bytes, so a 42-byte rest is three tasks); no piece covers a kept byte; a bounded piece sends its
    /// Range alone, and none here is the open-ended resume of the partial file, so none sends If-Range. Back in the
    /// foreground the app waits for the pieces, and no byte is fetched twice.
    func testTheRestIsHandedOverInPiecesOfAtMostSixtyFourMiB() async throws {
        XCTAssertEqual(ModelInstaller.pieceBytes.withLock { $0 }, 64 * 1024 * 1024)
        ModelInstaller.pieceBytes.withLock { $0 = 16 }
        defer { ModelInstaller.pieceBytes.withLock { $0 = Int64(ContinuityRules.piece) } }
        let first = Locked(true)
        let build = StubBuild.serve(cdn: { path, seen in
            var reply = StubBuild.served(path, seen)
            if path == Self.weights, first.withLock({ (f: inout Bool) -> Bool in defer { f = false }; return f }) { reply.stallAfter = 378 }
            return reply
        })
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let storage = CloudFixtures.storage()
        let install = try makeClient(storage, standIn, .whenLeaving, handOver)
        defer { install.close() }
        let call = Task { [install] in await install.model() }
        try await Self.wait("the weights' request in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        standIn.finish(next: 0)
        handOver.set(away: true)
        // the weights' 42 bytes in 3 pieces, the tokens' 248 in 16
        try await Self.wait("the hand-over") { standIn.started.count == 19 }
        XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights), ["378-393", "394-409", "410-419"])
        XCTAssertEqual(Self.ranges(standIn.started, of: StubBuild.tokens).count, 16)
        XCTAssertEqual(Self.ranges(standIn.started, of: StubBuild.tokens).first, "0-15")
        let weights = standIn.requests.filter { $0.url?.lastPathComponent == Self.weights }
        XCTAssertEqual(weights.map { $0.value(forHTTPHeaderField: "range") }, ["bytes=378-393", "bytes=394-409", "bytes=410-"])
        XCTAssertTrue(weights.allSatisfy { $0.value(forHTTPHeaderField: "if-range") == nil }, "no piece is the partial file's open-ended resume")
        // back: the app waits for the pieces, they land, the model opens and nothing was fetched twice
        handOver.set(away: false)
        standIn.endInFlight()
        let got = await call.value
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"], "the app asked the weights once")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: StubBuild.tokens), [], "the tokens came by their pieces alone")
    }

    /// An install (policy `whenLeaving`, one file at a time) left when 90% of the weights file has arrived: its request
    /// ended there, the rest of it and the tokens handed to two background tasks that stay in flight.
    func leaveAt90Percent() async throws -> (Running, StandIn, DownloadHandOver, String, URL) {
        let whole = try XCTUnwrap(StubBuild.data(Self.weights))
        XCTAssertEqual(whole.count, 420)
        let first = Locked(true)
        let build = StubBuild.serve(cdn: { path, seen in
            var reply = StubBuild.served(path, seen)
            if path == Self.weights, first.withLock({ (f: inout Bool) -> Bool in defer { f = false }; return f }) { reply.stallAfter = 378 }
            return reply
        })
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let storage = CloudFixtures.storage()
        let install = try makeClient(storage, standIn, .whenLeaving, handOver)
        let call = Task { [install] in await install.model() }
        try await Self.wait("the weights' request in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
        // its 378 bytes arrive and the connection stays open
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(standIn.started, [], "nothing is handed over while the app is in the foreground")
        standIn.finish(next: 0)
        handOver.set(away: true)
        try await Self.wait("the hand-over") { standIn.started.count == 2 }
        let part = install.folder.appendingPathComponent(Self.weights + ".part")
        XCTAssertEqual(ModelInstaller.sizeOnDisk(part), 378, "what arrived before the leaving stays")
        XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights), ["378-419"], "the rest of the weights, as one task")
        let resume = try XCTUnwrap(standIn.requests.first { $0.url?.lastPathComponent == Self.weights })
        XCTAssertEqual(resume.value(forHTTPHeaderField: "range"), "bytes=378-")
        XCTAssertEqual(resume.value(forHTTPHeaderField: "if-range"), "\"one\"", "with the validator of the answer that started the file")
        XCTAssertEqual(Self.ranges(standIn.started, of: StubBuild.tokens), ["0-247"], "and the file after it")
        return (Running(install: install, call: call), standIn, handOver, build, storage)
    }

    /// SDK 4.0.2 (SPEC 16.7 item 3): what a 4.0.1 install left is completed, not thrown away: a partial file of 100 bytes
    /// with its validator, a range a 4.0.1 background task delivered (bytes 200 to 299, kept beside it) and a 4.0.1 task
    /// of bytes 300 to 399 still on its way. The app asks bytes 100 to 199 (up to the kept range), joins the kept range,
    /// waits for the task and joins what it brings, then asks the rest from byte 400 to the end: nothing is asked twice,
    /// nothing is cancelled, and the model opens.
    func testWhatA401InstallLeftIsCompletedNotDiscarded() async throws {
        let whole = try XCTUnwrap(StubBuild.data(Self.weights))
        let build = StubBuild.serve()
        let standIn = StandIn()
        let install = try makeClient(CloudFixtures.storage(), standIn, .whenLeaving, DownloadHandOver())
        defer { install.close() }
        let part = install.folder.appendingPathComponent(Self.weights + ".part")
        try whole.prefix(100).write(to: part)
        try Data("\"one\"".utf8).write(to: ModelInstaller.validatorFile(part))
        try whole.subdata(in: 200..<300).write(to: BackgroundRange.file(part: part, lower: 200))
        let task = BackgroundRange(folder: install.relative, path: Self.weights, lower: 300, upper: 399, size: Int64(whole.count))
        standIn.carry(task.key)
        let call = Task { [install] in await install.model() }
        try await Self.wait("the app at the 4.0.1 task's first byte") { ModelInstaller.sizeOnDisk(part) == 300 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["100-199"], "up to the kept range, and no further while the task runs")
        standIn.endInFlight()
        let got = await call.value
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["100-199", "400-"], "the kept range and the task were joined, not asked again")
        let asked = StubBuild.modelRequests.filter { StubBuild.path($0) == Self.weights }
        XCTAssertTrue(asked.allSatisfy { $0.headers["if-range"] == "\"one\"" }, "each with the validator the 4.0.1 answer left")
        XCTAssertEqual(standIn.cancelled, [])
        XCTAssertEqual(install.abandoned.withLock { $0 }, 0)
        XCTAssertEqual(install.core.installed.withLock { $0 }, StubBuild.files.map(\.path))
    }

    // MARK: every range by the background

    /// With every range a background task from the first byte: the download server gets no request for a file from
    /// the foreground (only the manifest), and the model opens. And when the background ends every task without
    /// the bytes (here: the server refuses each for its token), nothing is kept, and the foreground fetches every
    /// file itself.
    func testEveryRangeByTheBackgroundAndTheForegroundWhenItBringsNothing() async throws {
        var build = StubBuild.serve()
        var standIn = StandIn()
        var client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
        var got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(StubBuild.fetched, [], "no file was asked for from the foreground")
        XCTAssertEqual(standIn.delivered.count, 3, "one task per file (SDK 4.0.2, SPEC 16.7)")
        XCTAssertTrue(standIn.requests.allSatisfy { $0.value(forHTTPHeaderField: "range") == nil }, "each asks its whole file, with no Range")
        XCTAssertTrue(standIn.outcomes.allSatisfy { $0 == .placed }, "\(standIn.outcomes)")
        XCTAssertEqual(standIn.cancelled, [])
        client.close()

        build = StubBuild.serve()
        standIn = StandIn()
        let refusal = try JSONSerialization.data(withJSONObject: ["error": "invalid_token", "message": "Renew the token."])
        standIn.answer { _ in StandIn.Answer(status: 401, body: refusal) }
        client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
        defer { client.close() }
        got = await client.model()
        XCTAssertEqual(got.build, build, "the foreground fetched what the background did not bring (\(String(describing: got.error)))")
        XCTAssertFalse(standIn.outcomes.isEmpty)
        XCTAssertTrue(standIn.outcomes.allSatisfy { $0 == .refused }, "\(standIn.outcomes)")
        XCTAssertNil(client.gate.stop, "a refusal for the token is no refusal of the key")
        XCTAssertTrue(StubBuild.fetched.contains(Self.weights))
    }

    // MARK: a redirect and a refusal on a background transfer

    /// The system followed a redirect on a background transfer (the stand-in's answer comes from another host). The
    /// bytes are refused: nothing of them is kept or joined, the issue `update_failed`, `model_redirected:<host>`
    /// is queued with the host only, and the foreground fetches that range from the model host. Had the bytes been
    /// joined, the file would not verify and would start again; it does not.
    func testARedirectOnABackgroundTransferIsRefusedAndReportedWithItsHostOnly() async throws {
        let build = StubBuild.serve()
        let standIn = StandIn()
        standIn.answer { range in
            if range.path == Self.weights, range.lower == 0 {
                // what another host would send in place of the range: the right length, other bytes
                return StandIn.Answer(body: Data(repeating: 0x5a, count: Int(range.upper - range.lower + 1)), finalHost: "Elsewhere.Example")
            }
            guard let data = StubBuild.data(range.path) else { return StandIn.Answer(status: 404) }
            return StandIn.Answer(body: data.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }
        let client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
        defer { client.close() }
        let got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let refusedBytes = standIn.outcomes.filter { $0 != .placed }
        XCTAssertFalse(refusedBytes.isEmpty)
        XCTAssertTrue(refusedBytes.allSatisfy { $0 == .redirected("elsewhere.example") }, "\(refusedBytes)")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"],
                       "the foreground fetched that file, once: the redirected bytes were never joined")
        XCTAssertEqual(Set(client.redirects.withLock { $0 }), ["model_redirected:elsewhere.example"], "the host, and nothing else of the address")
    }

    /// A refusal that stops the model, met by a background task: it is told to the model gate as any refusal of a
    /// model request, the model files are removed, and the call fails with the refusal's error.
    func testARefusalThatStopsTheModelOnABackgroundTransferStopsIt() async throws {
        StubBuild.serve()
        let standIn = StandIn()
        let refusal = try JSONSerialization.data(withJSONObject: ["error": "missing or invalid x-qlab-key", "reason": "key_revoked"])
        standIn.answer { range in
            if range.path == Self.weights { return StandIn.Answer(status: 401, body: refusal) }
            guard let data = StubBuild.data(range.path) else { return StandIn.Answer(status: 404) }
            return StandIn.Answer(body: data.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }
        let storage = CloudFixtures.storage()
        let client = try makeClient(storage, standIn, .fromFirstByte, DownloadHandOver())
        defer { client.close() }
        let got = await client.model()
        XCTAssertNil(got.build)
        XCTAssertEqual(got.error?.code, "invalid_key", "the refusal's error (\(String(describing: got.error)))")
        XCTAssertEqual(client.gate.stop?.reason, "key_revoked")
        XCTAssertEqual(client.gate.stop?.from, .model)
        // (the removal of the model's files at a stop is the Client's, after the gate: not this layer's)
    }

    // MARK: the hand-over when the app resigns (`whenResigning`, behind the measuring switch)

    /// A server whose first answer to the weights file's first range stays in flight behind `gate`.
    func serveHoldingTheFirstRange(_ gate: StubProtocol.Gate) throws -> String {
        let held = Locked(false)
        return StubBuild.serve(cdn: { path, seen in
            var reply = StubBuild.served(path, seen)
            if path == Self.weights, (ModelDownloadTests.range(seen)?.lower ?? 0) == 0 {
                let first = held.withLock { (h: inout Bool) -> Bool in
                    defer { h = true }
                    return !h
                }
                if first { reply.hold = gate }
            }
            return reply
        })
    }

    /// The app resigns while the weights file's request is in flight in the app, and is active again without having
    /// been in the background (Control Center, a banner). SDK 4.0.2: the app's request is the whole file (SPEC 16.7),
    /// so the files after it are what is handed to background tasks at the resign; at the return they are cancelled
    /// and what they fetched is dropped and counted. The app's own request was never cut. Twice: once with the task
    /// in flight (nothing fetched twice), once with it ended (its 248 bytes are dropped, and the app fetches the file).
    func testResigningAndBeingActiveAgainCancelsTheTasksAndDropsWhatTheyFetched() async throws {
        for ended in [0, 1] {
            let gate = StubProtocol.Gate()
            let build = try serveHoldingTheFirstRange(gate)
            let standIn = StandIn()
            let handOver = DownloadHandOver()
            let storage = CloudFixtures.storage()
            let client = try makeClient(storage, standIn, .whenResigning, handOver)
            let call = Task { [client] in await client.model() }
            try await Self.wait("the weights' request in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
            XCTAssertEqual(standIn.started, [], "nothing is handed over while the app is active")
            standIn.finish(next: ended)
            handOver.set(resigned: true)
            try await Self.wait("the hand-over at the resign") { standIn.started.count >= 1 }
            XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights), [], "the app's own file is the app's")
            XCTAssertEqual(Self.ranges(standIn.started, of: StubBuild.tokens), ["0-247"], "the file that comes after it")
            XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the app's own request is not cut at the resign")
            handOver.set(resigned: false)
            let dropped = client.dropped
            try await Self.wait("the task cancelled and its bytes dropped") {
                standIn.cancelled.count == 1 - ended && dropped.withLock { $0.bytes } == Int64(ended * 248)
            }
            XCTAssertEqual(dropped.withLock { $0.tasks }, 1 - ended, "ended \(ended): the tasks cancelled")
            let keptLeft = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
                .filter { $0.contains(".part.r") }
            XCTAssertEqual(keptLeft, [], "ended \(ended): what the task fetched is dropped")
            XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "ended \(ended): the app's own request is untouched")
            gate.open()
            let got = await call.value
            client.close()
            XCTAssertEqual(got.build, build, "ended \(ended): \(String(describing: got.error))")
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"], "ended \(ended): the app fetched its file, once")
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: StubBuild.tokens), ["whole"], "ended \(ended): and the file after it")
            XCTAssertEqual(client.abandoned.withLock { $0 }, 0, "ended \(ended): nothing was a return from the background")
            XCTAssertEqual(standIn.started.count, 1, "ended \(ended): nothing was handed over again")
        }
    }

    /// The app resigns while the weights file's request is in flight, and then enters the background. The app's
    /// request is not cut: it ends with the file. The file after it is the background's, fetched once by its task.
    func testResigningAndEnteringTheBackgroundLeavesTheRestToTheTasks() async throws {
        let gate = StubProtocol.Gate()
        let build = try serveHoldingTheFirstRange(gate)
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenResigning, handOver)
        defer { client.close() }
        let call = Task { [client] in await client.model() }
        try await Self.wait("the weights' request in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
        handOver.set(resigned: true)
        try await Self.wait("the hand-over at the resign") { standIn.started.count >= 1 }
        handOver.set(away: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the app's request is not cut when the app enters the background")
        gate.open()
        let got = await call.value
        handOver.set(away: false)
        handOver.set(resigned: false)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"], "the app fetched the file it was in, and no other")
        XCTAssertEqual(Self.ranges(standIn.delivered, of: StubBuild.tokens), ["0-247"], "the file after it came by its task, once")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: StubBuild.tokens), [], "and by the task alone")
        XCTAssertEqual(standIn.started.count, 1, "nothing was handed over twice")
        XCTAssertEqual(standIn.cancelled, [])
        XCTAssertEqual(client.dropped.withLock { $0.tasks }, 0)
    }

    /// Resign, active again, resign again, then the background: the first hand-over's task is cancelled (it had not
    /// ended), the second's carries the file after the app's, and each file was fetched once.
    func testResigningTwiceHandsOverAgainAndNoRangeIsFetchedTwice() async throws {
        let gate = StubProtocol.Gate()
        let build = try serveHoldingTheFirstRange(gate)
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenResigning, handOver)
        defer { client.close() }
        let call = Task { [client] in await client.model() }
        try await Self.wait("the weights' request in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
        standIn.finish(next: 0)
        handOver.set(resigned: true)
        try await Self.wait("the first hand-over") { standIn.started.count >= 1 }
        handOver.set(resigned: false)
        try await Self.wait("the first hand-over's task cancelled") { standIn.cancelled.count == 1 }
        standIn.finish(next: Int.max)
        handOver.set(resigned: true)
        try await Self.wait("the second hand-over") { standIn.started.count >= 2 }
        handOver.set(away: true)
        gate.open()
        let got = await call.value
        handOver.set(away: false)
        handOver.set(resigned: false)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(standIn.started.count, 2)
        XCTAssertEqual(standIn.cancelled.count, 1, "only the first hand-over's task was cancelled")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["whole"])
        XCTAssertEqual(Self.ranges(standIn.delivered, of: StubBuild.tokens), ["0-247"], "the file after it once, by a task that ended")
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the app's own request was never cut")
        let dropped = client.dropped.withLock { $0 }
        XCTAssertEqual(dropped.tasks, 1)
        XCTAssertEqual(dropped.bytes, 0, "no byte was fetched twice")
    }

    /// The rules of the download hold at both hand-over moments (the app active throughout): a download that goes
    /// on from a partial file of 50 bytes is answered with a 204 at every attempt. The file is asked for once and
    /// five times again, the call fails, the partial file is the same 50 bytes, and the next call finishes from it.
    func testAFailedAttemptCostsNoStoredByteAtEitherHandOverMoment() async throws {
        for policy in [BackgroundDownloadPolicy.whenLeaving, .whenResigning] {
            let what = policy.rawValue
            let whole = try XCTUnwrap(StubBuild.data(Self.weights))
            // an install that stopped with 50 bytes of the weights file
            let broke = Locked(false)
            StubBuild.serve(cdn: { path, seen in
                guard path == Self.weights else { return StubBuild.served(path, seen) }
                let first = broke.withLock { (b: inout Bool) -> Bool in
                    defer { b = true }
                    return !b
                }
                guard first else { return .down }
                var reply = StubBuild.served(path, seen)
                reply.breakAfter = 50
                return reply
            })
            let storage = CloudFixtures.storage()
            var client = try makeClient(storage, StandIn(), policy, DownloadHandOver())
            var got = await client.model()
            client.close()
            XCTAssertNil(got.build, what)
            let parts = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(Self.weights + ".part") }
            let part = storage.appendingPathComponent("models").appendingPathComponent(try XCTUnwrap(parts.first, what))
            XCTAssertEqual(try Data(contentsOf: part), whole.prefix(50), what)
            // every attempt is answered with a 204
            StubBuild.serve(cdn: { path, seen in
                path == Self.weights ? Reply(status: 204, headers: ["content-length": "0"]) : StubBuild.served(path, seen)
            })
            let standIn = StandIn()
            client = try makeClient(storage, standIn, policy, DownloadHandOver())
            got = await client.model()
            client.close()
            XCTAssertNil(got.build, what)
            XCTAssertEqual(got.error?.code, "download_failed", what)
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights).count, 6, "\(what): asked once and five times again")
            XCTAssertEqual(try Data(contentsOf: part), whole.prefix(50), "\(what): the partial file is the bytes it was")
            XCTAssertEqual(standIn.started, [], "\(what): nothing is handed over while the app is active")
            // the next call finishes from the partial file
            let build = StubBuild.serve()
            client = try makeClient(storage, StandIn(), policy, DownloadHandOver())
            got = await client.model()
            client.close()
            XCTAssertEqual(got.build, build, "\(what): \(String(describing: got.error))")
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights).first, "50-", "\(what): the next call goes on from the partial file")
        }
    }

    /// `whenResigning`, the app resigned for the whole call, and the background brings nothing (the stand-in's
    /// server answers every task with a 500): each hand-over that ends without the next byte is a failed attempt,
    /// and the call ends after its tries; it does not hand over without end.
    func testABackgroundThatBringsNothingAfterAResignEndsTheCallAfterItsTries() async throws {
        StubBuild.serve()
        let standIn = StandIn()
        standIn.answer { _ in StandIn.Answer(status: 500) }
        let handOver = DownloadHandOver()
        handOver.set(resigned: true)
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenResigning, handOver)
        defer { client.close() }
        let done = Locked(false)
        let call = Task { [client] () -> (build: String?, error: TajweedError?) in
            let got = await client.model()
            done.withLock { $0 = true }
            return got
        }
        let end = Date().addingTimeInterval(20)
        while !done.withLock({ $0 }), Date() < end, standIn.started.count < 2000 { try await Task.sleep(nanoseconds: 20_000_000) }
        let byItself = done.withLock { $0 }
        if !byItself { call.cancel() }
        let got = await call.value
        handOver.set(resigned: false)
        XCTAssertTrue(byItself, "the call ended by itself (stopped after \(standIn.started.count) tasks)")
        XCTAssertNil(got.build)
        XCTAssertNotNil(got.error)
        XCTAssertLessThan(standIn.started.count, 1000, "a bounded number of tasks: \(standIn.started.count)")
    }

    // MARK: what becomes of a finished range

    /// SDK 4.0.2 (SPEC 16.7): a task for a whole file asks it with no Range: its 200 of the file's length is kept at
    /// byte 0, and one of another length is not. A 200 to a task for the rest of a file (`bytes=N-`) is no answer to it.
    func testAWholeFileTaskIsKeptFromItsTwoHundred() throws {
        let storage = CloudFixtures.storage()
        let folder = "models/v4.0/.download-test"
        try fm.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        let sink = RangeDelivery.Sink(storage: storage, refused: { _ in }, redirected: { _ in })
        let asked = try XCTUnwrap(URL(string: "https://cdn.test/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/layers.zfw.qle"))
        func deliver(_ range: BackgroundRange, _ count: Int) throws -> RangeDelivery.Outcome {
            let file = fm.temporaryDirectory.appendingPathComponent("whole-" + UUID().uuidString)
            try Data(repeating: 7, count: count).write(to: file)
            return RangeDelivery.deliver(RangeDelivery.Arrival(body: file, key: range.key, status: 200, asked: asked, final: asked, redirects: 0,
                                                               contentRange: nil), sink: sink)
        }
        let whole = BackgroundRange(folder: folder, path: "layers.zfw.qle", lower: 0, upper: 419, size: 420)
        XCTAssertNotEqual(try deliver(whole, 419), .placed, "a 200 shorter than the file")
        XCTAssertEqual(try deliver(whole, 420), .placed)
        let part = BackgroundRange.part(storage.appendingPathComponent(folder), whole.path)
        XCTAssertEqual(BackgroundRange.kept(beside: part).map { $0.lower }, [0])
        let rest = BackgroundRange(folder: folder, path: "layers.zfw.qle", lower: 100, upper: 419, size: 420)
        XCTAssertNotEqual(try deliver(rest, 420), .placed, "a whole file in place of the rest of it")
        XCTAssertEqual(BackgroundRange.kept(beside: part).map { $0.lower }, [0])
    }

    func testARangeIsKeptOnlyAsTheBytesOfItsRangeFromTheAddressItWasAskedOf() throws {
        let storage = CloudFixtures.storage()
        let folder = "models/v4.0/.download-test"
        try fm.createDirectory(at: storage.appendingPathComponent(folder), withIntermediateDirectories: true)
        let refused = Locked<[CloudError]>([])
        let hosts = Locked<[String]>([])
        let sink = RangeDelivery.Sink(storage: storage, refused: { e in refused.withLock { $0.append(e) } }, redirected: { h in hosts.withLock { $0.append(h) } })
        func body(_ count: Int) throws -> URL {
            let url = fm.temporaryDirectory.appendingPathComponent("range-" + UUID().uuidString)
            try Data(repeating: 7, count: count).write(to: url)
            return url
        }
        let range = BackgroundRange(folder: folder, path: "c16_l64/frames.zfw.gz", lower: 100, upper: 199, size: 1000)
        XCTAssertEqual(range.key, "models/v4.0/.download-test|c16_l64/frames.zfw.gz|100|199|1000")
        XCTAssertEqual(BackgroundRange(key: range.key), range)
        XCTAssertNil(BackgroundRange(key: "models/../elsewhere|file|0|9|100"), "a name that leaves the storage is no range")
        XCTAssertNil(BackgroundRange(key: "a|b|9|0|100"))
        XCTAssertNil(BackgroundRange(key: "a|b|0|100|100"), "a range that ends past the file")
        XCTAssertNil(BackgroundRange(key: "a|b|0|9"), "a name without the file's size")
        XCTAssertNil(BackgroundRange(key: "not a range"))
        let part = BackgroundRange.part(storage.appendingPathComponent(folder), range.path)
        let kept = BackgroundRange.file(part: part, lower: 100)
        let asked = try XCTUnwrap(URL(string: "https://cdn.test/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/c16_l64/frames.zfw.gz"))
        /// What a task brought: `file` with `status`, answered from `final` after `redirects` redirects.
        func arrival(_ file: URL?, _ status: Int, final: String? = nil, redirects: Int = 0,
                     contentRange: String? = "bytes 100-199/1000") -> RangeDelivery.Arrival {
            RangeDelivery.Arrival(body: file, key: range.key, status: status, asked: asked, final: final.flatMap { URL(string: $0) } ?? asked,
                                  redirects: redirects, contentRange: contentRange)
        }

        // the range's own bytes, from the address it was asked of
        var file = try body(100)
        XCTAssertEqual(RangeDelivery.deliver(arrival(file, 206), sink: sink), .placed)
        XCTAssertEqual(ModelInstaller.sizeOnDisk(kept), 100)
        XCTAssertFalse(fm.fileExists(atPath: file.path), "the delivered file was moved")
        XCTAssertEqual(BackgroundRange.kept(beside: part).map { $0.lower }, [100])
        try fm.removeItem(at: kept)
        // another length, the whole file in place of the range, a failure of the server, a file that is not there
        for (status, count) in [(206, 99), (200, 100), (503, 100), (404, 0)] {
            file = try body(count)
            let outcome = RangeDelivery.deliver(arrival(file, status), sink: sink)
            guard case .discarded = outcome else { return XCTFail("\(status) \(count): \(outcome)") }
            XCTAssertFalse(fm.fileExists(atPath: kept.path), "\(status) \(count): nothing is kept")
            XCTAssertFalse(fm.fileExists(atPath: file.path), "\(status) \(count): the delivered file is removed")
        }
        // a 206 that is not the range asked for of the file asked for (SPEC 16.1): another total, another start,
        // another end, no Content-Range
        for said in ["bytes 100-199/999", "bytes 0-99/1000", "bytes 100-198/1000", nil] as [String?] {
            file = try body(100)
            let outcome = RangeDelivery.deliver(arrival(file, 206, contentRange: said), sink: sink)
            guard case .discarded = outcome else { return XCTFail("\(said ?? "no Content-Range"): \(outcome)") }
            XCTAssertFalse(fm.fileExists(atPath: kept.path), "\(said ?? "no Content-Range"): nothing is kept")
        }
        // a redirect the system followed: refused, the host told, lower case, nothing else. Another host; the same
        // host by http, and on another port; and a chain that led back to the very address (the system counted it)
        let redirected: [(final: String?, redirects: Int, host: String)] = [
            ("https://Other.Example/secret/path?token=1", 1, "other.example"),
            ("https://Other.Example/secret/path", 0, "other.example"),
            ("http://cdn.test/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/c16_l64/frames.zfw.gz", 0, "cdn.test"),
            ("https://cdn.test:8443/Quran-Lab/tajweedformer-v4/abc/sdk/v4.0/c16_l64/frames.zfw.gz", 0, "cdn.test"),
            (nil, 2, "cdn.test"),
        ]
        for r in redirected {
            hosts.withLock { $0 = [] }
            file = try body(100)
            XCTAssertEqual(RangeDelivery.deliver(arrival(file, 206, final: r.final, redirects: r.redirects), sink: sink), .redirected(r.host),
                           "\(r.final ?? "the same address") after \(r.redirects) redirects")
            XCTAssertEqual(hosts.withLock { $0 }, [r.host])
            XCTAssertFalse(fm.fileExists(atPath: kept.path))
            XCTAssertFalse(fm.fileExists(atPath: file.path))
        }
        // a refusal: its code and reason go to the model gate, whatever the 4xx it comes with; it is a refusal of the
        // range only under 401 or 403 (3.1.5: a stop is read only from those), any other 4xx is a failed range
        for status in [401, 400] {
            refused.withLock { $0 = [] }
            file = fm.temporaryDirectory.appendingPathComponent("range-" + UUID().uuidString)
            try JSONSerialization.data(withJSONObject: ["error": "missing or invalid x-qlab-key", "reason": "key_revoked"]).write(to: file)
            let outcome = RangeDelivery.deliver(arrival(file, status), sink: sink)
            if status == 401 {
                XCTAssertEqual(outcome, .refused, "HTTP \(status)")
            } else {
                guard case .discarded = outcome else { return XCTFail("HTTP \(status): \(outcome)") }
            }
            XCTAssertEqual(refused.withLock { $0 }, [.rejected(status: status, code: "missing or invalid x-qlab-key", message: "", reason: "key_revoked")])
        }
        // a download that is gone meanwhile
        try fm.removeItem(at: storage.appendingPathComponent(folder))
        file = try body(100)
        guard case .discarded = RangeDelivery.deliver(arrival(file, 206), sink: sink) else {
            return XCTFail("a range of a download that is gone")
        }
        XCTAssertFalse(fm.fileExists(atPath: storage.appendingPathComponent(folder).path), "nothing is made for it")
    }

    /// (The review's finding 3.) A process that the system started in the background is away from its first
    /// moment; one started in the foreground is not. The application's state is a stand-in here.
    func testAProcessStartedInTheBackgroundIsAwayFromItsFirstMoment() {
        defer { DownloadHandOver.startsAway.withLock { $0 = nil } }
        DownloadHandOver.startsAway.withLock { $0 = { true } }
        let background = DownloadHandOver()
        XCTAssertFalse(background.isAway)
        background.observeSystem()
        XCTAssertTrue(background.isAway, "started in the background: away before any notification")
        DownloadHandOver.startsAway.withLock { $0 = { false } }
        let foreground = DownloadHandOver()
        foreground.observeSystem()
        XCTAssertFalse(foreground.isAway)
    }

    /// Whether a background transfer sends the developer key is the signed config's switch
    /// `flags.model_requests_key_in_background`: false, and the background tasks carry the token and no key, while
    /// the requests the app makes itself still carry both; absent or true, both.
    func testTheSignedConfigSaysWhetherABackgroundTransferSendsTheKey() async throws {
        for (flag, sendsKey) in [(false as Bool?, false), (true as Bool?, true), (nil as Bool?, true)] {
            // the signed config's flag as the Client reads it (RemoteConfig.Flags), then the install it makes
            var flags: [String: Any] = ["analytics": true]
            if let flag { flags["model_requests_key_in_background"] = flag }
            let read = try JSONDecoder().decode(RemoteConfig.Flags.self, from: try JSONSerialization.data(withJSONObject: flags))
            XCTAssertEqual(read.model_requests_key_in_background, sendsKey)
            let build = StubBuild.serve()
            let standIn = StandIn()
            let client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver(), sendsKey: read.model_requests_key_in_background)
            let got = await client.model()
            client.close()
            let what = "the flag is \(flag.map { String($0) } ?? "absent")"
            XCTAssertEqual(got.build, build, "\(what): \(String(describing: got.error))")
            let handed = standIn.requests
            XCTAssertEqual(handed.count, StubBuild.files.count, "\(what): one task per file")
            XCTAssertTrue(handed.allSatisfy { $0.value(forHTTPHeaderField: "authorization") == "Bearer qlt_v1.eyJ2IjoxfQ.sig" }, "\(what): every background task carries the token")
            XCTAssertTrue(handed.allSatisfy { ($0.value(forHTTPHeaderField: "x-qlab-key") != nil) == sendsKey }, "\(what): the key on a background task")
            let own = StubBuild.modelRequests
            XCTAssertTrue(own.allSatisfy { $0.headers["x-qlab-key"] == CloudFixtures.key && $0.headers["authorization"] != nil },
                          "\(what): the app's own model requests carry both")
        }
    }
    /// The switch for measuring: the variable, set in the process before a Client is made, names the transport; a
    /// value that is no transport, and no value, leave the system's default.
    func testTheVariableSetBeforeAClientIsMadeNamesTheTransport() {
        let name = CloudOptions.backgroundDownloadsVariable
        XCTAssertEqual(name, "QURANLAB_BACKGROUND_DOWNLOADS")
        unsetenv(name)
        let usual = CloudOptions().backgroundDownloads
        defer { unsetenv(name) }
        setenv(name, "fromFirstByte", 1)
        // (the tests are a debug build, where the switch is read; a release build does not read it)
        #if os(iOS)
        XCTAssertEqual(CloudOptions().backgroundDownloads, .fromFirstByte)
        #else
        XCTAssertEqual(CloudOptions().backgroundDownloads, usual, "every range by the background session never applies on a Mac")
        #endif
        setenv(name, "whenLeaving", 1)
        XCTAssertEqual(CloudOptions().backgroundDownloads, .whenLeaving)
        setenv(name, "whenResigning", 1)
        XCTAssertEqual(CloudOptions().backgroundDownloads, .whenResigning, "the second hand-over moment, for the measurement")
        setenv(name, "off", 1)
        XCTAssertEqual(CloudOptions().backgroundDownloads, .off)
        setenv(name, "something else", 1)
        XCTAssertEqual(CloudOptions().backgroundDownloads, usual)
        unsetenv(name)
        XCTAssertEqual(CloudOptions().backgroundDownloads, usual)
    }

    /// What an app's Client uses: on iOS what is left goes to the background when the app leaves; on a Mac nothing
    /// does. Four range tasks run at a time.
    func testThePolicyOfAnAppsClient() {
        #if os(iOS)
        XCTAssertEqual(CloudOptions().backgroundDownloads, .whenLeaving)
        #else
        XCTAssertEqual(CloudOptions().backgroundDownloads, .off)
        #endif
        XCTAssertEqual(CloudOptions().parallelBackgroundRanges, 4)
        XCTAssertEqual(BackgroundDownloader.identifier(for: CloudFixtures.app), "ai.quranlab.models.com.example.quran")
        XCTAssertTrue(TajweedClient.isBackgroundSession(BackgroundDownloader.identifier(for: CloudFixtures.app)))
        let handOver = DownloadHandOver()
        let told = Locked(0)
        let id = handOver.onAway { told.withLock { $0 += 1 } }
        XCTAssertFalse(handOver.isAway)
        handOver.set(away: true)
        handOver.set(away: true)
        XCTAssertEqual(told.withLock { $0 }, 1, "told once per leaving")
        handOver.set(away: false)
        handOver.remove(id)
        handOver.set(away: true)
        XCTAssertEqual(told.withLock { $0 }, 1, "not after it was removed")
    }

    /// (The review's finding 3.) The app is away for the whole download. The FIRST range of every file ends without
    /// its bytes the first time (the stand-in's server answers it with a 500, once per file), so the file that is
    /// in hand when the ranges are handed over misses its next byte after the round. While the app is still away
    /// that range is handed to the background again; the app asks for no file itself, and the model opens.
    /// (Two earlier forms of this test failed a range that began at byte 100. Both passed on the code before the
    /// fix, in two runs, because the file in hand at the first hand-over is a small one without such a range, and
    /// every later file has a round of its own at its turn, which hands a missing range again.)
    func testARangeMissingAfterABackgroundRoundIsHandedOverAgainWhileTheAppIsAway() async throws {
        let build = StubBuild.serve()
        let standIn = StandIn()
        let failed = Locked<Set<String>>([])
        standIn.answer { range in
            guard let data = StubBuild.data(range.path), Int(range.upper) < data.count else { return StandIn.Answer(status: 404) }
            if range.lower == 0 {
                let first = failed.withLock { (f: inout Set<String>) -> Bool in f.insert(range.path).inserted }
                if first { return StandIn.Answer(status: 500) }
            }
            return StandIn.Answer(body: data.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }
        let handOver = DownloadHandOver()
        handOver.set(away: true)
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenLeaving, handOver)
        defer { client.close() }
        let got = await client.model()
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights).filter { $0 == "0-419" }.count, 2, "the missing file was handed over a second time")
        let firstHanded = try XCTUnwrap(standIn.started.first.flatMap { BackgroundRange(key: $0) })
        XCTAssertEqual(standIn.started.filter { $0 == firstHanded.key }.count, 2, "also the first range of the file that was in hand at the first hand-over")
        XCTAssertEqual(StubBuild.fetched, [], "the foreground asked for no file while the app was away")
    }
}
