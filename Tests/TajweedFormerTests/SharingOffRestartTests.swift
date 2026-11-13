import Foundation
import XCTest
@testable import TajweedFormer

/// A recording made under an earlier consent is never uploaded (rule R5 of SPEC 11.7, contract 1.5.0).
///
/// The situations are the `restart_cases` of the shared file `sharing_off.json`: nine recordings wait in the queue,
/// none in flight; the learner turns sharing off or deletes what they shared; from the moment of the call every
/// deletion of a recording fails (here: their folders cannot be written), which is what a stop that cannot delete
/// leaves and what a process that ends before the deletion leaves; where the case says so the process ends and a new
/// one opens the same storage; then the learner turns sharing on again, or leaves it off. Each case runs 20 times and
/// is checked by the file's keys; one line per case is printed, runs passed of 20 with the keys that failed.
///
/// How the keys are measured here:
/// - `off_is_on_disk_first`: the new process, which has nothing but the storage, finds sharing off.
/// - `earlier_consent_never_uploaded`: no start, URL, PUT or take-list request for any of the nine after the call, in
///   the first process or the new one, whatever passes are asked for. The queue is quiet when the call is made (the
///   outbox idle, no request at the stub for 200 ms); the stub's request sequence number is read at that point, and
///   every later request that names one of the nine counts, answered or not, with the network up or down. The
///   line of a case says how many there were, of which kind, and when they arrived relative to the call.
/// - `earlier_consent_deleted`: the nine folders are gone from the disk: right after the launch where deleting works
///   by then, else after the first pass once deleting works again.
/// - `on_again_works`: a recording made after sharing came on again is uploaded, and it is the only one uploaded.
/// - the optional case (`delete_unanswered`): the process ends while the server is being asked to delete. This SDK
///   writes on the device that a deletion is being asked before it asks, and a process that finds that at its
///   launch takes it for an off and asks the server again (3.1.4). Only the first process's request goes
///   unanswered, as the case says; the next start's request is answered. By the rule of 3.1.4, nothing is
///   recorded for sharing while that deletion is not confirmed, also after the learner turned sharing on again
///   (their yes is stored at once and takes effect when the server has confirmed): so for this case the test
///   waits until the deletion is confirmed before sharing comes on again, and `on_again_works` is measured on a
///   recording made after that.
final class SharingOffRestartTests: XCTestCase {
    struct Case {
        let name: String
        let left: Int
        let action: String
        let ends: Bool
        let then: String?
        let keys: [String]
    }

    static let keys = ["returns_within_bound", "off_is_on_disk_first", "earlier_consent_never_uploaded", "earlier_consent_deleted",
                       "on_again_works"]

    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// A launch: a new server client and outbox on `storage`, with what the disk says about the learner's answer.
    func launch(storage: URL) async -> QuranLabCloud {
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        return cloud
    }

    /// A recording of 1 s that has ended; its id, nil when sharing is not on.
    func record() throws -> String? {
        guard let capture = Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil) else { return nil }
        for i in 0..<10 { try capture.append(SharingTests.audio(4800, seed: i + 1), rate: 48_000) }
        capture.finish(completed: true)
        return capture.id
    }

    func until(_ seconds: TimeInterval, _ done: @Sendable () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await done()
    }

    /// The upload requests the stub has seen for these recordings (answered or not).
    static func requests(_ ids: [String]) -> Int {
        SharingOffTests.uploads.filter { r in ids.contains { r.url.absoluteString.contains($0) || r.headers["x-qlab-id"] == $0 } }.count
    }

    /// The upload requests for these recordings that reached the stub after its request number `mark`.
    static func later(than mark: Int, for ids: [String]) -> [StubProtocol.Seen] {
        StubProtocol.seen.dropFirst(mark).filter { r in
            SharingOffTests.kind(r) != nil && ids.contains { r.url.absoluteString.contains($0) || r.headers["x-qlab-id"] == $0 }
        }
    }

    /// How many of these recordings have a folder on disk.
    static func onDisk(_ root: URL, _ ids: [String]) -> Int {
        ids.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }.count
    }

    /// One run of a case; the keys that did not hold (empty: the run passed), and the requests made for the leftover
    /// recordings after the call: their kind ("start", "put", ...) and the milliseconds from the call to their
    /// arrival at the stub.
    func run(_ c: Case, boundMs: Int) async throws -> (failed: [String], sent: [(kind: String, ms: Int)]) {
        let server = SharingTests.Server()
        let gate = StubProtocol.Gate()
        let unanswered = c.action == "delete_unanswered"
        let answers = server.handler
        StubProtocol.reset { (s: StubProtocol.Seen) -> StubProtocol.Reply in
            if s.path == "/v1/contributions/challenge" {
                var r = StubProtocol.Reply.json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300])
                // the server that is being asked by the first process and has not answered; a later request (the
                // next start's, which asks again) is answered
                if unanswered, StubProtocol.seen("/v1/contributions/challenge").count == 1 { r.hold = gate }
                return r
            }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return answers(s)
        }
        // the first process: sharing on, no network, the recordings wait unsent and none is in flight
        server.down.withLock { $0 = true }
        let storage = CloudFixtures.storage()
        let first = await launch(storage: storage)
        Contributions.answer(share: true)
        var ids: [String] = []
        for _ in 0..<c.left {
            guard let id = try record() else { return (["setup: sharing is not on"], []) }
            ids.append(id)
        }
        let queue = first.outbox
        let left = c.left
        let waiting = await until(15) { await queue.items.count == left }
        guard waiting, Set(SharingOffTests.unsent(first)) == Set(ids) else { return (["setup: the recordings do not wait unsent"], []) }
        let root = first.outbox.root
        // the queue is quiet when the call is made: the outbox is idle, and no request has reached the stub for 200 ms.
        // None of the nine is in flight (a request in flight at the call is a situation of the first table).
        await first.outbox.drain()
        var seen = StubProtocol.seen.count, quietSince = Date()
        let waitedFrom = Date()
        while Date().timeIntervalSince(quietSince) < 0.2, Date().timeIntervalSince(waitedFrom) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let n = StubProtocol.seen.count
            if n != seen {
                seen = n
                quietSince = Date()
            }
        }
        if Date().timeIntervalSince(quietSince) < 0.2 { return (["setup: the queue did not come to rest"], []) }

        var failed: [String] = []
        func fail(_ key: String) { if !failed.contains(key) { failed.append(key) } }
        // from the moment of the call every deletion of a recording fails
        let fm = FileManager.default
        let folders = ids.map { root.appendingPathComponent($0).path }
        func deleting(works: Bool) {
            for f in folders where fm.fileExists(atPath: f) { try? fm.setAttributes([.posixPermissions: works ? 0o755 : 0o555], ofItemAtPath: f) }
        }
        deleting(works: false)
        defer { deleting(works: true) }
        // the stub's request number at the quiet point (read under the stub's lock), and the moment of the call
        let mark = StubProtocol.seen.count
        let called = Date()
        /// The requests made for the leftover recordings after the call, answered or not.
        func sent() -> [(kind: String, ms: Int)] {
            Self.later(than: mark, for: ids).map { (kind: SharingOffTests.kind($0) ?? "?", ms: Int(($0.at.timeIntervalSince(called) * 1000).rounded())) }
        }

        // the call
        var asking: Task<Void, Never>?
        let began = Date()
        switch c.action {
        case "off":
            await Contributions.setSharing(false)
        case "delete":
            do { try await Contributions.deleteShared() } catch { fail("setup: the delete was not accepted") }
        default:
            // the server is asked and does not answer; the process ends meanwhile
            asking = Task { _ = try? await Contributions.deleteShared() }
            let asked = await until(10) { StubProtocol.seen("/v1/contributions/challenge").count == 1 }
            if !asked { fail("setup: the server was not asked") }
        }
        if !unanswered, Date().timeIntervalSince(began) * 1000 > Double(boundMs) { fail("returns_within_bound") }

        // the network is back from here on: whatever may be sent, can be
        server.down.withLock { $0 = false }
        var cloud = first
        if c.ends {
            // the process ends: its outbox does nothing more. A new one opens the same storage.
            first.outbox.shutdown()
            if c.then == nil { deleting(works: true) }
            cloud = await launch(storage: storage)
            if Contributions.consent == .granted || Contributions.isActive { fail("off_is_on_disk_first") }
            // where deleting works by now: gone right after the launch, before any pass was asked for
            if c.then == nil, Self.onDisk(root, ids) != 0 { fail("earlier_consent_deleted") }
        }
        if c.then == "on" {
            if unanswered {
                // the rule of 3.1.4: while the deletion that the first process asked is not confirmed, nothing is
                // recorded for sharing, whatever the learner answers meanwhile. The next start has asked the server
                // again; the test waits until it has confirmed (the mark is gone) before sharing comes on again.
                let mark = DeletionMark.url(storage).path
                let confirmed = await until(10) { !FileManager.default.fileExists(atPath: mark) }
                if !confirmed { fail("setup: the next start's deletion was not confirmed") }
            }
            // sharing on again while the recordings still cannot be deleted
            await Contributions.setSharing(true)
            // (for that case also until sharing is in force: the end of the confirmed deletion's work)
            if unanswered { _ = await until(2) { Contributions.isActive } }
            await cloud.outbox.drain(ignoringBackoff: true)
            let next = try record()
            let outbox = cloud.outbox
            let up = await until(5) { () async -> Bool in
                guard let next else { return false }
                return await outbox.item(next)?.status == .uploaded
            }
            await cloud.outbox.drain(ignoringBackoff: true)
            try await Task.sleep(nanoseconds: 100_000_000)
            let uploaded = await cloud.outbox.items.filter { $0.status == .uploaded }.map(\.id)
            if !up || uploaded != [next ?? ""] { fail("on_again_works") }
            if !sent().isEmpty { fail("earlier_consent_never_uploaded") }
            // then deleting works again: gone before the next pass sends anything
            deleting(works: true)
            await cloud.outbox.drain(ignoringBackoff: true)
            if Self.onDisk(root, ids) != 0 { fail("earlier_consent_deleted") }
        } else {
            // sharing stays off; passes are asked for all the same
            await cloud.outbox.drain(ignoringBackoff: true)
        }
        await cloud.outbox.drain(ignoringBackoff: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        if !sent().isEmpty { fail("earlier_consent_never_uploaded") }
        if Self.onDisk(root, ids) != 0 { fail("earlier_consent_deleted") }
        // the first process is over: what it was still waiting for ends with the test
        if let asking {
            asking.cancel()
            await asking.value
            gate.open()
        }
        return (failed, sent())
    }

    /// Every restart case of the shared file, 20 runs each: all pass. One line per case is printed.
    func testEveryRestartCaseOfSharingOff() async throws {
        let v = try Vectors30.json("sharing_off.json")
        let runs = try XCTUnwrap(v["runs"] as? Int)
        let bound = try XCTUnwrap(v["off_bound_ms"] as? Int)
        let cases = try XCTUnwrap(v["restart_cases"] as? [[String: Any]]).map { (o: [String: Any]) -> Case in
            let keys = ((o["assert"] as? [String]) ?? []).map { String($0.prefix { $0 != ":" }) }
            return Case(name: o["name"] as? String ?? "?", left: o["left"] as? Int ?? 0, action: o["action"] as? String ?? "?",
                        ends: o["ends"] as? Bool ?? false, then: o["then"] as? String, keys: keys)
        }
        XCTAssertEqual(cases.count, 5)
        var lines: [String] = []
        var short = 0
        for c in cases {
            XCTAssertEqual(c.left, 9, c.name)
            XCTAssertTrue(["off", "delete", "delete_unanswered"].contains(c.action), c.name)
            XCTAssertTrue(Set(c.keys).isSubset(of: Set(Self.keys)), "\(c.name): a key this test does not check: \(c.keys)")
            var passed = 0, most = 0
            var failures: [String: Int] = [:]
            var kinds: [String: Int] = [:]
            var arrived: [Int] = []
            for _ in 0..<runs {
                let r = try await run(c, boundMs: bound)
                if r.failed.isEmpty { passed += 1 }
                for k in r.failed { failures[k, default: 0] += 1 }
                most = max(most, r.sent.count)
                for s in r.sent {
                    kinds[s.kind, default: 0] += 1
                    arrived.append(s.ms)
                }
            }
            var line = "sharing_off restart | \(c.name) | \(passed) of \(runs) | most requests made for the nine after the call in a run: \(most)"
            if !kinds.isEmpty {
                line += " (in all runs: " + kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
                line += "; arrived \(arrived.min() ?? 0) to \(arrived.max() ?? 0) ms after the call)"
            }
            let why = failures.sorted { $0.key < $1.key }.map { "\($0.key) failed in \($0.value)" }.joined(separator: ", ")
            if !why.isEmpty { line += " | " + why }
            print(line)
            lines.append(line)
            if passed != runs { short += 1 }
        }
        XCTAssertEqual(short, 0, "\(short) of \(cases.count) restart cases did not pass every run:\n" + lines.joined(separator: "\n"))
    }

    /// A queue of an SDK before 3.0.1 (no stamp on a recording, no count in the saved answer) is uploaded as before
    /// while sharing stays on: it reads 0 and 0.
    func testAQueueOfAnEarlierSDKGoesOnWhileSharingStaysOn() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        server.down.withLock { $0 = true }
        let storage = CloudFixtures.storage()
        let first = await launch(storage: storage)
        Contributions.answer(share: true)
        let id = try XCTUnwrap(try record())
        let queue = first.outbox
        let waiting = await until(15) { await queue.items.count == 1 }
        XCTAssertTrue(waiting)
        // the first launch's queue is at rest before its files are changed by hand: a pass that was started before
        // the shutdown would read the recording without its stamp against the state this process still holds, and
        // remove it as one made under an earlier consent (seen once in six runs of the suite, and once in 300 runs
        // of these steps; `hold()` returns when the pass has left)
        await first.outbox.hold()
        first.outbox.shutdown()
        // as an earlier SDK left it: the recording has no stamp, and the saved answer has no count
        let fm = FileManager.default
        try? fm.removeItem(at: first.outbox.root.appendingPathComponent(id).appendingPathComponent("stamp.json"))
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        var saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        saved["consentCount"] = nil
        saved["deleting"] = nil
        try JSONSerialization.data(withJSONObject: saved).write(to: state)
        // the next launch, with the network back
        server.down.withLock { $0 = false }
        let cloud = await launch(storage: storage)
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertTrue(fm.fileExists(atPath: cloud.outbox.root.appendingPathComponent(id).path), "the launch keeps it")
        await cloud.outbox.drain(ignoringBackoff: true)
        let outbox = cloud.outbox
        let up = await until(5) { await outbox.item(id)?.status == .uploaded }
        XCTAssertTrue(up, "and it is uploaded")
    }
}
