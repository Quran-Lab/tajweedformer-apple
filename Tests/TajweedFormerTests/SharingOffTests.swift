import Foundation
import XCTest
@testable import TajweedFormer

/// Sharing goes off, or the learner deletes what they shared, while an upload is in flight (SPEC 11.7, SDK 3.0.1).
///
/// The situations are those of the shared file `sharing_off.json` (the four SDKs build the same ones): a recording is
/// being uploaded, a stub server HOLDS one request (a segment PUT, the start of the upload, a batch of upload URLs,
/// the take list) so that it never answers by itself, and the learner turns sharing off, deletes what they shared
/// (the server accepts it), or tries to and the server does not take it; in two cases sharing is turned on again at
/// once. Each case runs `runs` (20) times, because a race passes most
/// single runs, and each run is checked by the file's assertion keys. The test prints one line per case, runs passed
/// of 20, with the keys that failed and how often.
///
/// How the keys are measured here:
/// - `no_audio_after` (rule R1: no byte of audio leaves the device after the call returns, whatever was in flight):
///   the body bytes of every PUT that started after the call, AND the bytes the server took of the held PUT's body
///   after the call. The held PUT is a slow upload: the stub takes the first 4096 bytes of its body when the request
///   starts and the rest when it is let go, as a server on a slow connection does.
/// - `nothing_unsent_on_device`: read from the disk. A folder of the queue counts as unsent when it holds a segment's
///   audio, has no item or an item that is not uploaded, or holds a take list that was not sent.
/// - An accepted delete turns sharing off (`sharing_is_off_after_an_accepted_delete`: off when the call returns, and
///   no ask is allowed any more); the learner turns it on again with the switch and a recording made after that is
///   uploaded in the same run (`on_again_works`, after the held request was let go).
/// - A refused delete (`delete_refused`: the server answers 503) changes nothing: sharing is still on, the recording
///   is still on the device, and it is uploaded in the same run once the held request is let go. In this SDK the
///   call reports a delete the server did not take by throwing, so for these cases `returns_within_bound` is the
///   bound alone, and the throw is checked with it.
/// - `held_request_cancelled` is this SDK's own key, next to the file's: the request in flight was cancelled (the
///   stub saw its sender end it) by the time the call returned.
final class SharingOffTests: XCTestCase {
    struct Case {
        let name: String
        let held: String
        let action: String
        let then: String?
        let keys: [String]
    }

    /// The assertion keys of the shared file.
    static let sharedKeys = ["returns_within_bound", "no_request_after", "no_audio_after", "nothing_unsent_on_device",
                             "still_nothing_after_release", "queue_stopped_before_the_server_is_asked",
                             "sharing_is_off_after_an_accepted_delete", "a_refused_delete_changes_nothing", "queue_resumes",
                             "on_again_works", "the_old_recording_is_gone"]
    /// This SDK's own key.
    static let ownKey = "held_request_cancelled"

    override func tearDown() {
        StubProtocol.slowBody = nil
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    // MARK: the pieces of a run

    /// A configured cloud over the stub network, in its own storage, with a learner who said "Share".
    func configure(_ server: SharingTests.Server) async -> QuranLabCloud {
        let storage = CloudFixtures.storage()
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        Contributions.answer(share: true)
        return cloud
    }

    /// A recording of 12 s (two segments) that has ended, of two takes when `takes`. Its id; nil when sharing is off.
    func record(takes: Bool = false) throws -> String? {
        guard let capture = Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil) else { return nil }
        for i in 0..<120 {
            if takes, i == 60 { capture.takes([ShareTake(start_ms: 0, gap_ms: 0), ShareTake(start_ms: 6000, gap_ms: 100)]) }
            try capture.append(SharingTests.audio(4800, seed: i + 1), rate: 48_000)
        }
        capture.finish(completed: true)
        return capture.id
    }

    /// Which request of an upload pass this is: `put`, `start`, `urls` or `takes`; nil for any other request.
    static func kind(_ s: StubProtocol.Seen) -> String? {
        if s.url.host == "r2.test" { return s.method == "PUT" ? "put" : nil }
        if s.method == "POST", s.path == "/v1/uploads" { return "start" }
        if s.path.hasPrefix("/v1/uploads/"), s.path.hasSuffix("/urls") { return "urls" }
        if s.path.hasPrefix("/v1/uploads/"), s.path.hasSuffix("/takes") { return "takes" }
        return nil
    }

    /// The requests of upload passes the stub has seen start.
    static var uploads: [StubProtocol.Seen] { StubProtocol.seen.filter { kind($0) != nil } }

    /// The folders of the queue that hold something unsent, on disk: a segment's audio, no item or an item that is
    /// not uploaded, or a take list that was not sent.
    static func unsent(_ cloud: QuranLabCloud) -> [String] {
        let fm = FileManager.default
        let root = cloud.outbox.root
        var out: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.count == 32 {
            let folder = root.appendingPathComponent(name)
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            var item: [String: Any]?
            if let d = try? Data(contentsOf: folder.appendingPathComponent(ContributionOutbox.itemName)) {
                item = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            let uploaded = (item?["state"] as? String) == "uploaded"
            let list = files.contains(ShareFiles.takesFile) && (item?["takes"] as? String) != "sent"
            let audio = files.contains { $0.hasSuffix(".opus") }
            if audio || !uploaded || list { out.append(name) }
        }
        return out.sorted()
    }

    /// Waits until `done` holds, at most `seconds`; whether it did.
    func until(_ seconds: TimeInterval, _ done: @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await done()
    }

    /// Whether the recording `id` is uploaded, within 5 s.
    func uploaded(_ cloud: QuranLabCloud, _ id: String?) async -> Bool {
        guard let id else { return false }
        let outbox = cloud.outbox
        return await until(5) { await outbox.item(id)?.status == .uploaded }
    }

    // MARK: one run of one case

    /// One run of a case. Returns the keys that did not hold (empty: the run passed) and the bytes of audio the
    /// server took after the call returned.
    func run(_ c: Case, boundMs: Int) async throws -> (failed: [String], bytesAfter: Int) {
        let server = SharingTests.Server(batch: c.held == "urls" ? 1 : 20)
        let gate = StubProtocol.Gate()
        defer { gate.open() }
        let taken = Locked(false)
        let atAnswer = Locked<Int?>(nil)
        let held = c.held
        let refused = c.action == "delete_refused"
        // the one request that is held: the first of its kind
        let first: @Sendable () -> Bool = {
            taken.withLock { (t: inout Bool) -> Bool in
                if t { return false }
                t = true
                return true
            }
        }
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge", refused {
                // the server does not take the delete; how many upload requests had started by its answer
                let n = SharingOffTests.uploads.count
                atAnswer.withLock { $0 = n }
                return StubProtocol.Reply(status: 503)
            }
            if s.path == "/v1/contributions/challenge" { return .json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300]) }
            if s.path == "/v1/contributions/delete" {
                // the server's answer to the delete: how many upload requests had started by then
                let n = SharingOffTests.uploads.count
                atAnswer.withLock { $0 = n }
                return .json(["ok": true], status: 202)
            }
            var reply = answers(s)
            if held != "put", SharingOffTests.kind(s) == held, first() { reply.hold = gate }
            return reply
        }
        if held == "put" {
            // a slow upload: the server has the first bytes of the segment, the rest is still to come
            StubProtocol.slowBody = { (r: URLRequest) -> StubProtocol.Gate? in
                guard r.url?.host == "r2.test", r.httpMethod == "PUT", first() else { return nil }
                return gate
            }
        }
        let cloud = await configure(server)
        guard let old = try record(takes: held == "takes") else { return (["setup: sharing is not on"], 0) }
        let inFlight = await until(10) { taken.withLock { $0 } }
        guard inFlight else { return (["setup: the \(held) request never started"], 0) }

        var failed: [String] = []
        func fail(_ key: String) { if !failed.contains(key) { failed.append(key) } }
        if Self.unsent(cloud) != [old] { fail("setup: the recording is not the one unsent thing before the call") }
        let before = Self.uploads.count
        /// The upload requests that started after the call was made.
        func after() -> [StubProtocol.Seen] { Array(Self.uploads.dropFirst(before)) }
        /// The bytes of audio in them.
        func audio(_ requests: [StubProtocol.Seen]) -> Int {
            var n = 0
            for r in requests where Self.kind(r) == "put" { n += r.body.count }
            return n
        }

        // the call
        let began = Date()
        var threw = false
        if c.action == "off" {
            await Contributions.setSharing(false)
        } else {
            do { try await Contributions.deleteShared() } catch { threw = true }
        }
        let took = Date().timeIntervalSince(began)
        let cancelled = await until(0.5) { StubProtocol.cancelled.withLock { !$0.isEmpty } }
        if !cancelled { fail(Self.ownKey) }

        if refused {
            // the server did not take the delete: the call says so, in time, and nothing has changed
            if took * 1000 > Double(boundMs) { fail("returns_within_bound") }
            if !threw { fail("setup: a delete the server refused did not throw") }
            if atAnswer.withLock({ $0 }) != before { fail("queue_stopped_before_the_server_is_asked") }
            // nothing on the device was deleted: the recording's folder is there (the queue has resumed, so it may be
            // on its way up already)
            let kept = FileManager.default.fileExists(atPath: cloud.outbox.root.appendingPathComponent(old).path)
            if Contributions.consent != .granted || !Contributions.isActive || !kept { fail("a_refused_delete_changes_nothing") }
            // the held request is let go: the queue resumes with the recording that was in flight
            gate.open()
            await cloud.outbox.drain(ignoringBackoff: true)
            if !(await uploaded(cloud, old)) || server.segments(old).count != 2 { fail("queue_resumes") }
            return (failed, 0)
        }

        if threw || took * 1000 > Double(boundMs) { fail("returns_within_bound") }
        if Contributions.consent != .final { fail("setup: sharing is not off after the call") }
        if !Self.unsent(cloud).isEmpty { fail("nothing_unsent_on_device") }
        if c.action == "delete", Contributions.isActive || Contributions.askNow() != nil { fail("sharing_is_off_after_an_accepted_delete") }

        if c.then == "on" {
            // on again at once, while the old request is still held
            await Contributions.setSharing(true)
            let next = try record()
            if !(await uploaded(cloud, next)) { fail("on_again_works") }
            // then the held request is let go
            gate.open()
            await cloud.outbox.drain(ignoringBackoff: true)
            try await Task.sleep(nanoseconds: 100_000_000)
            // what was asked or sent for the OLD recording after the call
            let forOld = after().filter { $0.url.absoluteString.contains(old) || $0.headers["x-qlab-id"] == old }
            if !forOld.isEmpty {
                fail("no_request_after")
                fail("the_old_recording_is_gone")
            }
            if FileManager.default.fileExists(atPath: cloud.outbox.root.appendingPathComponent(old).path) { fail("the_old_recording_is_gone") }
            let late = StubProtocol.lateBytes.withLock { $0 }
            if audio(forOld) + late > 0 { fail("no_audio_after") }
            return (failed, audio(forOld) + late)
        }

        if !after().isEmpty { fail("no_request_after") }
        if c.action == "delete", atAnswer.withLock({ $0 }) != before { fail("queue_stopped_before_the_server_is_asked") }
        // the held request is let go: it answers 200
        gate.open()
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        if !Self.unsent(cloud).isEmpty || !after().isEmpty { fail("still_nothing_after_release") }
        let bytes = audio(after()) + StubProtocol.lateBytes.withLock { $0 }
        if bytes > 0 { fail("no_audio_after") }
        if c.action == "delete" {
            // an accepted delete turned sharing off: the learner turns it on again, and it works in the same run
            await Contributions.setSharing(true)
            let next = try record()
            if !(await uploaded(cloud, next)) { fail("on_again_works") }
        }
        return (failed, bytes)
    }

    // MARK: the table

    /// Every case of the shared file, 20 runs each: all pass. One line per case is printed: runs passed of 20 by the
    /// file's keys, runs passed with this SDK's own key as well, which keys failed and in how many runs, and the most
    /// bytes of audio that left after the call in one run.
    func testEveryCaseOfSharingOff() async throws {
        let v = try Vectors30.json("sharing_off.json")
        let runs = try XCTUnwrap(v["runs"] as? Int)
        let bound = try XCTUnwrap(v["off_bound_ms"] as? Int)
        XCTAssertEqual(runs, 20)
        XCTAssertEqual(bound, 3000)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]]).map { (o: [String: Any]) -> Case in
            let keys = ((o["assert"] as? [String]) ?? []).map { String($0.prefix { $0 != ":" }) }
            return Case(name: o["name"] as? String ?? "?", held: o["held"] as? String ?? "?", action: o["action"] as? String ?? "?",
                        then: o["then"] as? String, keys: keys)
        }
        XCTAssertEqual(cases.count, 12)
        var lines: [String] = []
        var short = 0
        for c in cases {
            XCTAssertTrue(["put", "start", "urls", "takes"].contains(c.held), c.name)
            XCTAssertTrue(["off", "delete", "delete_refused"].contains(c.action), c.name)
            XCTAssertTrue(Set(c.keys).isSubset(of: Set(Self.sharedKeys)), "\(c.name): a key this test does not check: \(c.keys)")
            var byTheFile = 0, withOwn = 0, mostBytes = 0
            var failures: [String: Int] = [:]
            for _ in 0..<runs {
                let r = try await run(c, boundMs: bound)
                if r.failed.isEmpty { withOwn += 1 }
                if r.failed.allSatisfy({ $0 == Self.ownKey }) { byTheFile += 1 }
                for k in r.failed { failures[k, default: 0] += 1 }
                mostBytes = max(mostBytes, r.bytesAfter)
            }
            var line = "sharing_off | \(c.name) | \(byTheFile) of \(runs) | with \(Self.ownKey): \(withOwn) of \(runs) | "
            line += "most bytes of audio after the call: \(mostBytes)"
            let why = failures.sorted { $0.key < $1.key }.map { "\($0.key) failed in \($0.value)" }.joined(separator: ", ")
            if !why.isEmpty { line += " | " + why }
            print(line)
            lines.append(line)
            if withOwn != runs { short += 1 }
        }
        XCTAssertEqual(short, 0, "\(short) of \(cases.count) cases did not pass every run:\n" + lines.joined(separator: "\n"))
    }

    // MARK: delete what I shared, around the server's answer

    /// "Delete what I shared" stops the queue BEFORE it asks the server: while the server has not answered, nothing
    /// of a recording is sent, also not of one that ends meanwhile; when the delete is accepted that recording goes
    /// with the rest.
    func testDeleteStopsTheQueueBeforeItAsksTheServer() async throws {
        let server = SharingTests.Server()
        let gate = StubProtocol.Gate()
        defer { gate.open() }
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge" {
                // the server is slow to answer
                var r = StubProtocol.Reply.json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300])
                r.hold = gate
                return r
            }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return answers(s)
        }
        let cloud = await configure(server)
        let deleting = Task { try await Contributions.deleteShared() }
        let asked = await until(10) { StubProtocol.seen("/v1/contributions/challenge").count == 1 }
        XCTAssertTrue(asked, "the server is being asked")
        // a recording ends while the server has not answered: sharing is still on, so it is kept, and not sent
        let id = try XCTUnwrap(try record())
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(Self.uploads.count, 0, "nothing is sent while the server is being asked: \(Self.uploads.map(\.path))")
        XCTAssertEqual(Self.unsent(cloud), [id], "the recording waits on the device")
        // the server accepts the delete
        gate.open()
        try await deleting.value
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertEqual(Self.unsent(cloud), [], "the queue is empty on disk")
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(Self.uploads.count, 0, "and nothing was sent")
        XCTAssertEqual(Self.unsent(cloud), [])
    }

    /// A delete the server cannot be asked for, once more outside the table: the call throws, sharing was on and stays on, and the queue goes on:
    /// the recording that was in flight is uploaded whole, and so is one made afterwards.
    func testADeleteThatFailsLeavesSharingOnAndTheQueueGoesOn() async throws {
        let server = SharingTests.Server()
        let gate = StubProtocol.Gate()
        defer { gate.open() }
        let taken = Locked(false)
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path.hasPrefix("/v1/contributions/") { return StubProtocol.Reply(status: 503) }
            return answers(s)
        }
        StubProtocol.slowBody = { (r: URLRequest) -> StubProtocol.Gate? in
            guard r.url?.host == "r2.test", r.httpMethod == "PUT" else { return nil }
            let first = taken.withLock { (t: inout Bool) -> Bool in
                if t { return false }
                t = true
                return true
            }
            return first ? gate : nil
        }
        let cloud = await configure(server)
        let id = try XCTUnwrap(try record())
        let inFlight = await until(10) { taken.withLock { $0 } }
        XCTAssertTrue(inFlight, "a segment is being uploaded")
        var threw = false
        do { try await Contributions.deleteShared() } catch { threw = true }
        XCTAssertTrue(threw, "the delete failed")
        XCTAssertEqual(Contributions.consent, .granted, "sharing was on and stays on")
        XCTAssertTrue(Contributions.isActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.outbox.root.appendingPathComponent(id).path),
                      "nothing on the device was deleted: the recording is still there")
        gate.open()
        await cloud.outbox.drain(ignoringBackoff: true)
        let up = await uploaded(cloud, id)
        XCTAssertTrue(up, "the queue goes on: the recording is uploaded")
        XCTAssertEqual(server.segments(id).count, 2, "both segments, whole")
        let next = try record()
        let also = await uploaded(cloud, next)
        XCTAssertTrue(also, "and so is a recording made afterwards")
    }
}
