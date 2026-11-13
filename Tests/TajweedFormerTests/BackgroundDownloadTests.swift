import Foundation
import XCTest
@testable import TajweedFormer

/// The model download's background transport (3.1.5), with a STAND-IN for the background session: no background
/// URLSession is made here, no app is suspended and nothing runs out of process. The stand-in takes the range
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
        private var _started: [String] = []
        private var _requests: [URLRequest] = []
        private var _delivered: [String] = []
        private var _cancelled: [String] = []
        private var _outcomes: [RangeDelivery.Outcome] = []
        private var _finishing = Int.max
        private var _sink: RangeDelivery.Sink?
        private var _answer: @Sendable (BackgroundRange) -> Answer = { range in
            guard let data = try? ModelDownloadTests.stored(range.path), Int(range.upper) < data.count else { return Answer(status: 404) }
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
            let (ends, sink, answer) = locked { () -> (Bool, RangeDelivery.Sink?, @Sendable (BackgroundRange) -> Answer) in
                _started.append(key)
                _requests.append(request)
                let ends = _finishing > 0
                if ends {
                    if _finishing != Int.max { _finishing -= 1 }
                    _delivered.append(key)
                } else {
                    inFlight.append(key)
                }
                return (ends, _sink, _answer)
            }
            guard ends, let sink, let range = BackgroundRange(key: key) else { return }
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
                _cancelled.append(contentsOf: gone)
                return Set(gone)
            }
        }
    }

    override func setUp() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        // ranges of 100 bytes, so that the test folder's files have several
        ModelInstaller.smallestRange.withLock { $0 = 100 }
    }

    override func tearDown() {
        ModelInstaller.smallestRange.withLock { $0 = 64 << 10 }
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    static let weights = ModelDownloadTests.weights

    /// A Client whose downloads use `standIn` under `policy`, with ranges of 100 bytes and no update check of its
    /// own; the stand-in hands its answers to the Client's own sink.
    func makeClient(_ storage: URL, _ standIn: StandIn, _ policy: BackgroundDownloadPolicy, _ handOver: DownloadHandOver) throws -> TajweedClient {
        var made = CloudFixtures.options(updates: .manual, signingKeys: [CloudFixtures.signer.publicKey.rawRepresentation, try Fixtures.v4miniKey()],
                                         storage: storage)
        made.cloud?.rangeSize = 100
        made.cloud?.backgroundDownloads = policy
        made.cloud?.backgroundTransport = standIn
        made.cloud?.handOver = handOver
        let options = made
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
            CloudFixtures.cloud(storage: root, options: options)
        })
        let cloud = try XCTUnwrap(QuranLab.cloud)
        standIn.deliver(to: QuranLabCloud.rangeSink(storage: storage, gate: cloud.gate, issues: cloud.issues, app: cloud.app, enabled: true))
        return client
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

    /// The foreground requests the stub got for a stored file, as `lower-upper`.
    static func foreground(_ seen: [StubProtocol.Seen], of path: String) -> [String] {
        seen.filter { OnlineOnlyTests.modelPath($0) == path }.compactMap { ModelDownloadTests.range($0) }.map { "\($0.lower)-\($0.upper)" }
    }

    // MARK: hand-over and hand-back

    /// One install, left twice. The app leaves while the first range of the weights file is in flight in the
    /// foreground: that request is ended, and every range that is left goes to background tasks. Two of them end,
    /// then the app is back while the others are in flight: those are cancelled, each abandoned whole, and counted;
    /// the two that ended are joined, and the foreground goes on from the byte after them. The app leaves again in
    /// the middle of a later range: what is left goes to the background once more, and this time ends there.
    /// At the end the model opens (every file's hash is right), and every range of the weights file was fetched
    /// exactly once, by the foreground or by a background task that ended.
    func testADownloadIsHandedOverAndTakenBackWithNoRangeFetchedTwice() async throws {
        let size = try ModelDownloadTests.stored(Self.weights).count
        XCTAssertEqual(size, 420, "the test folder's weights file: five ranges of 100 bytes")
        let first = StubProtocol.Gate(), later = StubProtocol.Gate()
        let held = Locked<Set<Int>>([])
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in
            var reply = ModelDownloadTests.served(path, seen)
            // the first request for byte 0, and the first for byte 300, of the weights file stay in flight
            if path == Self.weights, let asked = ModelDownloadTests.range(seen), asked.lower == 0 || asked.lower == 300 {
                let isFirst = held.withLock { $0.insert(asked.lower).inserted }
                if isFirst { reply.hold = asked.lower == 0 ? first : later }
            }
            return reply
        })
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let storage = CloudFixtures.storage()
        let client = try makeClient(storage, standIn, .whenLeaving, handOver)
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let call = Task { await OnlineOnlyTests.model(client) }

        // the app leaves while the weights file's first range is in flight; two background tasks will end
        try await Self.wait("the first range of the weights file in flight") { held.withLock { $0.contains(0) } }
        XCTAssertEqual(standIn.started, [], "nothing is handed over while the app is in the foreground")
        standIn.finish(next: 2)
        handOver.set(away: true)
        try await Self.wait("the hand-over") { standIn.started.count >= 8 }
        XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights), ["0-99", "100-199", "200-299", "300-399", "400-419"],
                       "every range of the file in hand, from the byte the foreground had reached")
        XCTAssertEqual(Self.ranges(standIn.started, of: "tokens.txt"), ["0-99", "100-199", "200-247"], "and the file that comes after it")
        XCTAssertEqual(standIn.started.count, 8)
        XCTAssertEqual(Self.ranges(standIn.delivered, of: Self.weights), ["0-99", "100-199"])

        // the app is back while six tasks are in flight: they are abandoned whole
        handOver.set(away: false)
        try await Self.wait("the later range in flight in the foreground") { held.withLock { $0.contains(300) } }
        XCTAssertEqual(standIn.cancelled.count, 6, "the tasks that had not ended were cancelled: \(standIn.cancelled)")
        XCTAssertEqual(cloud.updater.abandonedRanges.withLock { $0 }, 6, "and counted")

        // the app leaves again, in the middle of the range that starts at byte 300; this time every task ends
        standIn.finish(next: Int.max)
        handOver.set(away: true)
        let got = await call.value
        handOver.set(away: false)
        // the two requests that were ended are no longer waited for by the stub
        first.open()
        later.open()
        XCTAssertEqual(got.build, build, "the model opens: every file's hash is right (\(String(describing: got.error)))")
        XCTAssertEqual(cloud.updater.abandonedRanges.withLock { $0 }, 6, "nothing more was abandoned")

        // every range of the weights file exactly once: the foreground's that were served, and the background's that ended
        let cut = StubProtocol.cancelled.withLock { Self.foreground($0, of: Self.weights) }
        XCTAssertEqual(cut.sorted(), ["0-99", "300-399"], "the two foreground requests that were in flight at a hand-over were ended")
        var served = Self.foreground(StubProtocol.seen, of: Self.weights)
        for c in cut { if let i = served.firstIndex(of: c) { served.remove(at: i) } }
        XCTAssertEqual(served, ["200-299"], "the foreground went on from the byte after the joined ranges, once")
        let background = Self.ranges(standIn.delivered, of: Self.weights)
        XCTAssertEqual(background, ["0-99", "100-199", "300-399", "400-419"])
        XCTAssertEqual((served + background).sorted { (Int($0.split(separator: "-")[0]) ?? 0) < (Int($1.split(separator: "-")[0]) ?? 0) },
                       ["0-99", "100-199", "200-299", "300-399", "400-419"], "the file's bytes, each fetched once")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: "tokens.txt"), [], "the file after it came by the background alone")
        XCTAssertEqual(Self.ranges(standIn.delivered, of: "tokens.txt").sorted(), ["0-99", "100-199", "200-247"])
        // nothing is left beside the installed files
        let left = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.contains(".part") }
        XCTAssertEqual(left, [], "no partial file and no kept range is left")
    }

    // MARK: every range by the background

    /// With every range a background task from the first byte: the download server gets no request for a file from
    /// the foreground (only the manifest), and the model opens. And when the background ends every task without
    /// the bytes (here: the server refuses each for its token), nothing is kept, and the foreground fetches every
    /// file itself.
    func testEveryRangeByTheBackgroundAndTheForegroundWhenItBringsNothing() async throws {
        var build = try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
        var standIn = StandIn()
        var client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
        var got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(OnlineOnlyTests.fetched, ["manifest.json"], "no file was asked for from the foreground")
        XCTAssertGreaterThan(standIn.delivered.count, 10)
        XCTAssertTrue(standIn.outcomes.allSatisfy { $0 == .placed }, "\(standIn.outcomes)")
        XCTAssertEqual(standIn.cancelled, [])
        client.close()

        build = try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
        standIn = StandIn()
        let refusal = try JSONSerialization.data(withJSONObject: ["error": "invalid_token", "message": "Renew the token."])
        standIn.answer { _ in StandIn.Answer(status: 401, body: refusal) }
        client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
        defer { client.close() }
        got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "the foreground fetched what the background did not bring (\(String(describing: got.error)))")
        XCTAssertFalse(standIn.outcomes.isEmpty)
        XCTAssertTrue(standIn.outcomes.allSatisfy { $0 == .refused }, "\(standIn.outcomes)")
        XCTAssertNil(QuranLab.cloud?.gate.stop, "a refusal for the token is no refusal of the key")
        XCTAssertTrue(OnlineOnlyTests.fetched.contains(Self.weights))
    }

    // MARK: a redirect and a refusal on a background transfer

    /// The system followed a redirect on a background transfer (the stand-in's answer comes from another host). The
    /// bytes are refused: nothing of them is kept or joined, the issue `update_failed`, `model_redirected:<host>`
    /// is queued with the host only, and the foreground fetches that range from the model host. Had the bytes been
    /// joined, the file would not verify and would start again; it does not.
    func testARedirectOnABackgroundTransferIsRefusedAndReportedWithItsHostOnly() async throws {
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
        let standIn = StandIn()
        standIn.answer { range in
            if range.path == Self.weights, range.lower == 100 {
                // what another host would send in place of the range: the right length, other bytes
                return StandIn.Answer(body: Data(repeating: 0x5a, count: Int(range.upper - range.lower + 1)), finalHost: "Elsewhere.Example")
            }
            guard let data = try? ModelDownloadTests.stored(range.path) else { return StandIn.Answer(status: 404) }
            return StandIn.Answer(body: data.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }
        let client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        let refusedBytes = standIn.outcomes.filter { $0 != .placed }
        XCTAssertFalse(refusedBytes.isEmpty)
        XCTAssertTrue(refusedBytes.allSatisfy { $0 == .redirected("elsewhere.example") }, "\(refusedBytes)")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["100-199"],
                       "the foreground fetched that range, and only it: the file did not start again")
        let issues = cloud.issues.pending.filter { $0.kind == "update_failed" }
        XCTAssertEqual(Set(issues.map { $0.code }), ["model_redirected:elsewhere.example"], "the host, and nothing else of the address")
    }

    /// A refusal that stops the model, met by a background task: it is told to the model gate as any refusal of a
    /// model request, the model files are removed, and the call fails with the refusal's error.
    func testARefusalThatStopsTheModelOnABackgroundTransferStopsIt() async throws {
        try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
        let standIn = StandIn()
        let refusal = try JSONSerialization.data(withJSONObject: ["error": "missing or invalid x-qlab-key", "reason": "key_revoked"])
        standIn.answer { range in
            if range.path == Self.weights { return StandIn.Answer(status: 401, body: refusal) }
            guard let data = try? ModelDownloadTests.stored(range.path) else { return StandIn.Answer(status: 404) }
            return StandIn.Answer(body: data.subdata(in: Int(range.lower)..<Int(range.upper + 1)))
        }
        let storage = CloudFixtures.storage()
        let client = try makeClient(storage, standIn, .fromFirstByte, DownloadHandOver())
        defer { client.close() }
        let got = await OnlineOnlyTests.model(client)
        XCTAssertNil(got.build)
        XCTAssertEqual(got.error?.code, "invalid_key", "the refusal's error (\(String(describing: got.error)))")
        XCTAssertEqual(QuranLab.cloud?.gate.stop?.reason, "key_revoked")
        XCTAssertEqual(QuranLab.cloud?.gate.stop?.from, .model)
        let left = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
            .filter { !$0.hasPrefix("recommended.json") }
        XCTAssertEqual(left, [], "no model file is left")
    }

    // MARK: the hand-over when the app resigns (`whenResigning`, behind the measuring switch)

    /// A server whose first answer to the weights file's first range stays in flight behind `gate`.
    func serveHoldingTheFirstRange(_ gate: StubProtocol.Gate) throws -> String {
        let held = Locked(false)
        return try OnlineOnlyTests.serve(cdn: { path, seen in
            var reply = ModelDownloadTests.served(path, seen)
            if path == Self.weights, ModelDownloadTests.range(seen)?.lower == 0 {
                let first = held.withLock { (h: inout Bool) -> Bool in
                    defer { h = true }
                    return !h
                }
                if first { reply.hold = gate }
            }
            return reply
        })
    }

    /// The app resigns while the weights file's first range is in flight in the app, and is active again without
    /// having been in the background (Control Center, a banner). The ranges after the app's own were handed to
    /// background tasks at the resign; at the return they are cancelled and what they fetched is dropped and
    /// counted. The app's own request was never cut. Twice: once with no task ended (nothing was fetched twice),
    /// once with two tasks ended (their 200 bytes are dropped, and the app fetches those ranges itself).
    func testResigningAndBeingActiveAgainCancelsTheTasksAndDropsWhatTheyFetched() async throws {
        for ended in [0, 2] {
            let gate = StubProtocol.Gate()
            let build = try serveHoldingTheFirstRange(gate)
            let standIn = StandIn()
            let handOver = DownloadHandOver()
            let storage = CloudFixtures.storage()
            let client = try makeClient(storage, standIn, .whenResigning, handOver)
            let cloud = try XCTUnwrap(QuranLab.cloud)
            let call = Task { [client] in await OnlineOnlyTests.model(client) }
            try await Self.wait("the first range of the weights file in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
            XCTAssertEqual(standIn.started, [], "nothing is handed over while the app is active")
            standIn.finish(next: ended)
            handOver.set(resigned: true)
            try await Self.wait("the hand-over at the resign") { standIn.started.count >= 7 }
            XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights), ["100-199", "200-299", "300-399", "400-419"],
                           "the ranges after the one the app is fetching")
            XCTAssertEqual(Self.ranges(standIn.started, of: "tokens.txt"), ["0-99", "100-199", "200-247"], "and the file that comes after it")
            XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the app's own request is not cut at the resign")
            handOver.set(resigned: false)
            try await Self.wait("the tasks cancelled") { standIn.cancelled.count == 7 - ended }
            let updater = cloud.updater
            try await Self.wait("the dropped bytes counted") { updater.droppedForNothing.withLock { $0.tasks } == 7 - ended }
            XCTAssertEqual(updater.droppedForNothing.withLock { $0.bytes }, Int64(ended * 100), "ended \(ended): the bytes the tasks had fetched")
            let keptLeft = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
                .filter { $0.contains(".part.r") }
            XCTAssertEqual(keptLeft, [], "ended \(ended): what the tasks fetched is dropped")
            XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "ended \(ended): the app's own request is untouched")
            gate.open()
            let got = await call.value
            client.close()
            XCTAssertEqual(got.build, build, "ended \(ended): \(String(describing: got.error))")
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["0-99", "100-199", "200-299", "300-399", "400-419"],
                           "ended \(ended): the app fetched every range itself, each once")
            XCTAssertEqual(cloud.updater.abandonedRanges.withLock { $0 }, 0, "ended \(ended): nothing was a return from the background")
            XCTAssertEqual(standIn.started.count, 7, "ended \(ended): nothing was handed over again")
        }
    }

    /// The app resigns while the first range is in flight, and then enters the background. The app's request is
    /// not cut: it ends with its range. Every range after it is the background's, and each range of the file was
    /// fetched once: the first by the app, the others by a background task.
    func testResigningAndEnteringTheBackgroundLeavesTheRestToTheTasks() async throws {
        let gate = StubProtocol.Gate()
        let build = try serveHoldingTheFirstRange(gate)
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenResigning, handOver)
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let call = Task { [client] in await OnlineOnlyTests.model(client) }
        try await Self.wait("the first range of the weights file in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
        handOver.set(resigned: true)
        try await Self.wait("the hand-over at the resign") { standIn.started.count >= 7 }
        handOver.set(away: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the app's request is not cut when the app enters the background")
        gate.open()
        let got = await call.value
        handOver.set(away: false)
        handOver.set(resigned: false)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["0-99"], "the app fetched the range it was in, and no other")
        XCTAssertEqual(Self.ranges(standIn.delivered, of: Self.weights), ["100-199", "200-299", "300-399", "400-419"], "the rest came by the tasks, each once")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: "tokens.txt"), [], "the file after it came by the tasks alone")
        XCTAssertEqual(standIn.started.count, 7, "no range was handed over twice")
        XCTAssertEqual(standIn.cancelled, [])
        XCTAssertEqual(cloud.updater.droppedForNothing.withLock { $0.tasks }, 0)
    }

    /// Resign, active again, resign again, then the background: the first hand-over's tasks are cancelled (none had
    /// ended), the second's carry the rest, and each range of the file was fetched once.
    func testResigningTwiceHandsOverAgainAndNoRangeIsFetchedTwice() async throws {
        let gate = StubProtocol.Gate()
        let build = try serveHoldingTheFirstRange(gate)
        let standIn = StandIn()
        let handOver = DownloadHandOver()
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenResigning, handOver)
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let call = Task { [client] in await OnlineOnlyTests.model(client) }
        try await Self.wait("the first range of the weights file in flight") { !Self.foreground(StubProtocol.seen, of: Self.weights).isEmpty }
        standIn.finish(next: 0)
        handOver.set(resigned: true)
        try await Self.wait("the first hand-over") { standIn.started.count >= 7 }
        handOver.set(resigned: false)
        try await Self.wait("the first hand-over's tasks cancelled") { standIn.cancelled.count == 7 }
        standIn.finish(next: Int.max)
        handOver.set(resigned: true)
        try await Self.wait("the second hand-over") { standIn.started.count >= 14 }
        handOver.set(away: true)
        gate.open()
        let got = await call.value
        handOver.set(away: false)
        handOver.set(resigned: false)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(standIn.started.count, 14)
        XCTAssertEqual(standIn.cancelled.count, 7, "only the first hand-over's tasks were cancelled")
        XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights), ["0-99"])
        XCTAssertEqual(Self.ranges(standIn.delivered, of: Self.weights), ["100-199", "200-299", "300-399", "400-419"], "each range once, by a task that ended")
        XCTAssertEqual(StubProtocol.cancelled.withLock { $0.count }, 0, "the app's own request was never cut")
        let dropped = cloud.updater.droppedForNothing.withLock { $0 }
        XCTAssertEqual(dropped.tasks, 7)
        XCTAssertEqual(dropped.bytes, 0, "no byte was fetched twice")
    }

    /// The rules of the download hold at both hand-over moments (the app active throughout): a download that goes
    /// on from a partial file of 50 bytes is answered with a 204 at every attempt. The file is asked for once and
    /// five times again, the call fails, the partial file is the same 50 bytes, and the next call finishes from it.
    func testAFailedAttemptCostsNoStoredByteAtEitherHandOverMoment() async throws {
        for policy in [BackgroundDownloadPolicy.whenLeaving, .whenResigning] {
            let what = policy.rawValue
            let whole = try ModelDownloadTests.stored(Self.weights)
            // an install that stopped with 50 bytes of the weights file
            let broke = Locked(false)
            try OnlineOnlyTests.serve(cdn: { path, seen in
                guard path == Self.weights else { return ModelDownloadTests.served(path, seen) }
                let first = broke.withLock { (b: inout Bool) -> Bool in
                    defer { b = true }
                    return !b
                }
                guard first else { return .down }
                var reply = ModelDownloadTests.served(path, seen)
                reply.breakAfter = 50
                return reply
            })
            let storage = CloudFixtures.storage()
            var client = try makeClient(storage, StandIn(), policy, DownloadHandOver())
            var got = await OnlineOnlyTests.model(client)
            client.close()
            XCTAssertNil(got.build, what)
            let parts = (fm.enumerator(atPath: storage.appendingPathComponent("models").path)?.compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(Self.weights + ".part") }
            let part = storage.appendingPathComponent("models").appendingPathComponent(try XCTUnwrap(parts.first, what))
            XCTAssertEqual(try Data(contentsOf: part), whole.prefix(50), what)
            // every attempt is answered with a 204
            try OnlineOnlyTests.serve(cdn: { path, seen in
                path == Self.weights ? Reply(status: 204, headers: ["content-length": "0"]) : ModelDownloadTests.served(path, seen)
            })
            let standIn = StandIn()
            client = try makeClient(storage, standIn, policy, DownloadHandOver())
            got = await OnlineOnlyTests.model(client)
            client.close()
            XCTAssertNil(got.build, what)
            XCTAssertEqual(got.error?.code, "download_failed", what)
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights).count, 6, "\(what): asked once and five times again")
            XCTAssertEqual(try Data(contentsOf: part), whole.prefix(50), "\(what): the partial file is the bytes it was")
            XCTAssertEqual(standIn.started, [], "\(what): nothing is handed over while the app is active")
            // the next call finishes from the partial file
            let build = try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
            client = try makeClient(storage, StandIn(), policy, DownloadHandOver())
            got = await OnlineOnlyTests.model(client)
            client.close()
            XCTAssertEqual(got.build, build, "\(what): \(String(describing: got.error))")
            XCTAssertEqual(Self.foreground(StubProtocol.seen, of: Self.weights).first, "50-149", "\(what): the next call goes on from the partial file")
        }
    }

    /// `whenResigning`, the app resigned for the whole call, and the background brings nothing (the stand-in's
    /// server answers every task with a 500): each hand-over that ends without the next byte is a failed attempt,
    /// and the call ends after its tries; it does not hand over without end.
    func testABackgroundThatBringsNothingAfterAResignEndsTheCallAfterItsTries() async throws {
        try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
        let standIn = StandIn()
        standIn.answer { _ in StandIn.Answer(status: 500) }
        let handOver = DownloadHandOver()
        handOver.set(resigned: true)
        let client = try makeClient(CloudFixtures.storage(), standIn, .whenResigning, handOver)
        defer { client.close() }
        let done = Locked(false)
        let call = Task { [client] () -> (build: String?, error: TajweedError?) in
            let got = await OnlineOnlyTests.model(client)
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
            let build = try OnlineOnlyTests.build()
            let flags: [String: Any] = flag.map { ["model_requests_key_in_background": $0] } ?? [:]
            StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build], flags: flags), extra: { s in
                guard let path = OnlineOnlyTests.modelPath(s) else { return nil }
                return ModelDownloadTests.served(path, s)
            }))
            let standIn = StandIn()
            let client = try makeClient(CloudFixtures.storage(), standIn, .fromFirstByte, DownloadHandOver())
            let got = await OnlineOnlyTests.model(client)
            client.close()
            let what = "the flag is \(flag.map { String($0) } ?? "absent")"
            XCTAssertEqual(got.build, build, "\(what): \(String(describing: got.error))")
            let handed = standIn.requests
            XCTAssertGreaterThan(handed.count, 10, what)
            XCTAssertTrue(handed.allSatisfy { $0.value(forHTTPHeaderField: "authorization") == "Bearer qlt_v1.eyJ2IjoxfQ.sig" }, "\(what): every background task carries the token")
            XCTAssertTrue(handed.allSatisfy { ($0.value(forHTTPHeaderField: "x-qlab-key") != nil) == sendsKey }, "\(what): the key on a background task")
            let own = OnlineOnlyTests.modelRequests
            XCTAssertFalse(own.isEmpty, what)
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
        let build = try OnlineOnlyTests.serve(cdn: { path, seen in ModelDownloadTests.served(path, seen) })
        let standIn = StandIn()
        let failed = Locked<Set<String>>([])
        standIn.answer { range in
            guard let data = try? ModelDownloadTests.stored(range.path), Int(range.upper) < data.count else { return StandIn.Answer(status: 404) }
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
        let got = await OnlineOnlyTests.model(client)
        XCTAssertEqual(got.build, build, "\(String(describing: got.error))")
        XCTAssertEqual(Self.ranges(standIn.started, of: Self.weights).filter { $0 == "0-99" }.count, 2, "the missing range was handed over a second time")
        let firstHanded = try XCTUnwrap(standIn.started.first.flatMap { BackgroundRange(key: $0) })
        XCTAssertEqual(standIn.started.filter { $0 == firstHanded.key }.count, 2, "also the first range of the file that was in hand at the first hand-over")
        XCTAssertEqual(OnlineOnlyTests.fetched, ["manifest.json"], "the foreground asked for no file while the app was away")
    }
}
