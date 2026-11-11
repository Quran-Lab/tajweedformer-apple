import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 3.0.0 additions to shared recordings, on the recorder alone (a clock and timers the test moves, recordings
/// that only count): the shared vector `sharing_30.json` case by case (the feed's ring, pre-roll and tail, the take
/// list with a feed, `take_seq` and `gap_ms_prev`, the 20-minute cap inside a take), and the bounds of what the
/// recorder keeps in memory (the ring's second, the tail's half second, a held take's 30 s).
final class ShareFeedTests: XCTestCase {
    /// A recording that counts what it is given and checks the order it is driven in.
    final class Tape: ShareRecording {
        var rate = 0.0
        var samples: Int64 = 0
        var list: [ShareTake]?
        var completed: Bool?
        var discarded = false
        var takeSeq: Int?
        var gapMsPrev: Int?
        /// Samples per take of the recording: its pre-roll, its own audio, its tail (kept by the test's world).
        var parts: [[String: Int]] = []

        func begin(takeSeq: Int, gapMsPrev: Int?) {
            XCTAssertEqual(samples, 0, "begin comes before the first audio")
            XCTAssertNil(self.takeSeq, "begin comes once")
            self.takeSeq = takeSeq
            self.gapMsPrev = gapMsPrev
        }

        func append(_ mono: [Float], rate: Double) throws(RecognizerError) {
            XCTAssertNil(completed, "audio after the end")
            XCTAssertNotNil(takeSeq, "audio before begin")
            if self.rate == 0 { self.rate = rate }
            XCTAssertEqual(rate, self.rate, "a recording has one input rate")
            samples += Int64(mono.count)
            XCTAssertLessThanOrEqual(samples, TakeJoin.capSamples(rate: rate), "a recording never holds more than 20 minutes")
        }

        func takes(_ list: [ShareTake]) {
            XCTAssertNil(completed, "a take list after the end")
            XCTAssertGreaterThanOrEqual(list.count, 2, "a list is written when a take joins")
            self.list = list
        }

        func finish(completed: Bool) {
            XCTAssertNil(self.completed, "ended twice")
            self.completed = completed
        }

        func discard() {
            XCTAssertNil(completed, "ended twice")
            completed = false
            discarded = true
        }

        var isAlive: Bool { completed == nil }
    }

    struct Pending: Sendable {
        let due: Int64
        let id: Int
        let task: @Sendable () -> Void
    }

    /// The recorder with its world: the clock, the timers, sharing's switch, the install's count of recordings in a
    /// file, and every recording it opened.
    final class World: @unchecked Sendable {
        let nowMs: Locked<Int64>
        let on: Locked<Bool>
        let opened: Locked<[Tape]>
        let due: Locked<[Pending]>
        let recorder: ShareRecorder
        let sequenceFile: URL
        /// A block of audio reused for every push (a recording only counts).
        private let block = [Float](repeating: 0.01, count: 160_000)

        init(window: Int = TakeJoin.defaultWindowMs, on sharing: Bool = true, timers: Bool = true) {
            let nowMs = Locked<Int64>(0)
            let on = Locked(sharing)
            let opened = Locked<[Tape]>([])
            let due = Locked<[Pending]>([])
            let ids = Locked(0)
            let file = Fixtures.storage().appendingPathComponent("cloud/sharing-seq.json")
            self.nowMs = nowMs
            self.on = on
            self.opened = opened
            self.due = due
            sequenceFile = file
            let r = ShareRecorder(
                clock: { Date(timeIntervalSince1970: Double(nowMs.withLock { $0 }) / 1000) },
                window: { window },
                active: { on.withLock { $0 } },
                identity: { (_: ShareRecorder.TakeInfo) -> [String] in ["learner"] },
                open: { (_: ShareRecorder.TakeInfo) -> (any ShareRecording)? in
                    let t = Tape()
                    opened.withLock { $0.append(t) }
                    return t
                },
                sequence: .stored { file })
            r.setTimer(JoinTimer { ms, task in
                let id = ids.withLock { (n: inout Int) -> Int in
                    n += 1
                    return n
                }
                let at = nowMs.withLock { $0 } + ms
                if timers { due.withLock { $0.append(Pending(due: at, id: id, task: task)) } }
                return { due.withLock { (list: inout [Pending]) -> Void in list.removeAll { $0.id == id } } }
            })
            recorder = r
        }

        var now: Int64 { nowMs.withLock { $0 } }

        /// The recordings that got audio, in order.
        var tapes: [Tape] { opened.withLock { $0 }.filter { $0.samples > 0 } }

        /// Moves the clock to `t`, running the timers that come due on the way, each at its time.
        func at(_ t: Int64) {
            while true {
                let next: Pending? = due.withLock { (list: inout [Pending]) -> Pending? in
                    var best: Int?
                    for i in list.indices where list[i].due <= t {
                        if best == nil || list[i].due < list[best!].due { best = i }
                    }
                    guard let best else { return nil }
                    return list.remove(at: best)
                }
                guard let next else { break }
                nowMs.withLock { $0 = max($0, next.due) }
                next.task()
            }
            nowMs.withLock { $0 = t }
        }

        /// `n` samples, as the block or a part of it.
        func audio(_ n: Int) -> [Float] { n == block.count ? block : Array(block[0..<n]) }

        /// One fed buffer at the clock's time; a tail goes to the open recording's last take.
        @discardableResult
        func feed(_ n: Int, rate: Double = 16_000) -> ShareFeed.Fed {
            let tape = recorder.current as? Tape
            let fed = recorder.feed(audio(n), rate: rate)
            if fed.toTail > 0, let tape, !tape.parts.isEmpty { tape.parts[tape.parts.count - 1]["tail", default: 0] += fed.toTail }
            return fed
        }

        /// One take from `start` to `end` with `samples` of audio (in blocks), `fedDuring` samples fed in its middle.
        /// Returns the samples fed during it that were dropped, and where its own samples were cut by the cap.
        @discardableResult
        func take(_ start: Int64, _ samples: Int, _ end: Int64, rate: Double = 16_000, fedDuring: Int = 0,
                  completed: Bool = true) throws -> (dropped: Int, cuts: [Int]) {
            at(start)
            let before = opened.withLock { $0 }.map(\.samples)
            let token = recorder.takeStarted(.init(revision: "8b9e3beb169a41b234eacc93252d7bcc141f0b27", version: "4.0.0", backend: .exact,
                                                   weightsSHA256: nil))
            var left = samples, dropped = 0, fed = false
            while left > 0 {
                let k = min(left, block.count)
                try recorder.audio(token, audio(k), rate: rate)
                left -= k
                if fedDuring > 0, !fed {
                    // the app keeps feeding while the take runs
                    fed = true
                    var more = fedDuring
                    while more > 0 {
                        let n = min(more, block.count)
                        dropped += recorder.feed(audio(n), rate: rate).dropped
                        more -= n
                    }
                }
            }
            at(end)
            recorder.takeEnded(token, completed: completed)
            // what each recording got of this take: its pre-roll goes with its first samples
            let all = opened.withLock { $0 }
            var pre = recorder.preRoll, taken = 0, first = true
            var cuts: [Int] = []
            for (i, tape) in all.enumerated() {
                let got = Int(tape.samples - (i < before.count ? before[i] : 0))
                guard got > 0 else { continue }
                // a second recording with audio of this take: the cap cut the take at the samples taken so far
                if !first { cuts.append(taken) }
                first = false
                let own = got - pre
                tape.parts.append(["pre_roll": pre, "take": own, "tail": 0])
                taken += own
                pre = 0
            }
            return (dropped, cuts)
        }

        /// Time passes until nothing waits; every recording must have ended.
        func settle(file: StaticString = #filePath, line: UInt = #line) {
            at(now + 60_000)
            recorder.checkWindow()
            XCTAssertNil(recorder.current, "no recording left open", file: file, line: line)
            XCTAssertTrue(opened.withLock { $0 }.allSatisfy { $0.completed != nil }, "every recording ended", file: file, line: line)
        }
    }

    static func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }

    // MARK: the shared vector

    /// Every case, once with the window's timer running and once without it (the clock decides).
    func testTheSharedSharingVector() throws {
        let v = try Vectors30.json("sharing_30.json")
        XCTAssertEqual(Self.int(v["default_window_ms"]), TakeJoin.defaultWindowMs)
        XCTAssertEqual((v["cap_ms"] as? NSNumber)?.int64Value, TakeJoin.capMs)
        XCTAssertEqual(Self.int(v["ring_ms"]), ShareFeed.ringMs)
        XCTAssertEqual(Self.int(v["tail_ms"]), ShareFeed.tailMs)
        XCTAssertEqual((v["tail_wait_ms"] as? NSNumber)?.int64Value, ShareFeed.tailWaitMs)
        XCTAssertEqual(ShareFeed.tailWaitMs, 1500)
        XCTAssertEqual((v["stale_ms"] as? NSNumber)?.int64Value, ShareFeed.staleMs)
        XCTAssertEqual((v["gap_ms_prev_max"] as? NSNumber)?.int64Value, ShareSequencer.gapMaxMs)
        XCTAssertEqual((v["hold_ms"] as? NSNumber)?.int64Value, TakeJoin.holdMs)
        let caps = try XCTUnwrap(v["cap_samples"] as? [String: NSNumber])
        for (rate, n) in caps { XCTAssertEqual(TakeJoin.capSamples(rate: Double(rate) ?? 0), n.int64Value, rate) }
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 41)
        XCTAssertEqual(cases.filter { (($0["name"] as? String) ?? "").hasPrefix("the tail wait") }.count, 3)
        var recordings = 0
        for c in cases {
            for timers in [true, false] {
                let name = "\((c["name"] as? String) ?? "?") (\(timers ? "timer" : "no timer"))"
                let flags = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["flags"] as? [String: Any], name))
                let window = try JSONDecoder().decode(RemoteConfig.Flags.self, from: flags).share_join_ms
                let w = World(window: window, on: (c["sharing_on_at_start"] as? Bool) ?? true, timers: timers)
                for (n, e) in try XCTUnwrap(c["events"] as? [[String: Any]], name).enumerated() {
                    let label = "\(name), event \(n + 1)"
                    let expect = (e["expect"] as? [String: Any]) ?? [:]
                    switch e["event"] as? String {
                    case "feed":
                        w.at(Int64(try XCTUnwrap(Self.int(e["wall_ms"]), label)))
                        let fed = w.feed(try XCTUnwrap(Self.int(e["samples"]), label), rate: Double(try XCTUnwrap(Self.int(e["rate"]), label)))
                        XCTAssertEqual(fed.toTail, Self.int(expect["to_tail"]), "\(label): to the tail")
                        XCTAssertEqual(fed.toRing, Self.int(expect["to_ring"]), "\(label): to the ring")
                        XCTAssertEqual(fed.dropped, Self.int(expect["dropped"]), "\(label): dropped")
                    case "take":
                        let before = w.tapes.count
                        let joinable = w.recorder.current != nil
                        let samples = try XCTUnwrap(Self.int(e["samples"]), label)
                        let got = try w.take(Int64(try XCTUnwrap(Self.int(e["start_wall_ms"]), label)), samples,
                                             Int64(try XCTUnwrap(Self.int(e["end_wall_ms"]), label)),
                                             rate: Double(try XCTUnwrap(Self.int(e["rate"]), label)), fedDuring: Self.int(e["fed_during"]) ?? 0)
                        XCTAssertEqual(w.recorder.preRoll, Self.int(expect["pre_roll"]), "\(label): the pre-roll")
                        XCTAssertEqual(got.dropped, Self.int(expect["fed_during_dropped"]), "\(label): fed during the take")
                        let cuts = (expect["cut_at_take_samples"] as? [NSNumber])?.map(\.intValue) ?? []
                        XCTAssertEqual(got.cuts, cuts, "\(label): where the cap cut the take")
                        let recorded = (expect["recorded"] as? Bool) ?? false
                        let opened = w.tapes.count - before
                        if recorded {
                            let joined = (expect["joined"] as? Bool) ?? false
                            XCTAssertEqual(opened, (joined ? 0 : 1) + cuts.count, "\(label): joined \(joined)")
                            if joined { XCTAssertTrue(joinable, label) }
                        } else {
                            XCTAssertEqual(opened, 0, "\(label): not recorded")
                        }
                        XCTAssertEqual(w.recorder.wasHeld, (expect["held"] as? Bool) ?? false, "\(label): held")
                    case "background":
                        w.at(Int64(try XCTUnwrap(Self.int(e["wall_ms"]), label)))
                        w.recorder.background()
                        // the vector's next events are in the foreground again
                        w.recorder.foreground()
                    case "sharing":
                        let on = try XCTUnwrap(e["on"] as? Bool, label)
                        w.on.withLock { $0 = on }
                        if !on { w.recorder.stop() }
                    case "delete":
                        // "Delete what I shared": the open recording goes, and the count starts again
                        w.recorder.stop()
                        ShareSequencer.reset(w.sequenceFile)
                    default:
                        XCTFail("\(label): an event the test does not know")
                    }
                    XCTAssertEqual(w.recorder.ringSamples, Self.int(expect["ring_samples"]), "\(label): the ring")
                }
                w.settle()
                let want = try XCTUnwrap(c["recordings"] as? [[String: Any]], name)
                let got = w.tapes
                XCTAssertEqual(got.count, want.count, name)
                for (i, (tape, x)) in zip(got, want).enumerated() {
                    let label = "\(name), recording \(i + 1)"
                    XCTAssertEqual(Int(tape.rate), Self.int(x["rate"]), label)
                    XCTAssertEqual(tape.samples, (x["samples"] as? NSNumber)?.int64Value, label)
                    XCTAssertEqual(TakeJoin.ms(tape.samples, rate: tape.rate), (x["audio_ms"] as? NSNumber)?.int64Value, label)
                    XCTAssertEqual(tape.takeSeq, Self.int(x["take_seq"]), "\(label): take_seq")
                    XCTAssertEqual(tape.gapMsPrev, Self.int(x["gap_ms_prev"]), "\(label): gap_ms_prev (nil: absent)")
                    let list: [ShareTake]? = (x["takes"] as? [[String: Int]])?.map { (t: [String: Int]) -> ShareTake in
                        ShareTake(start_ms: t["start_ms"] ?? -1, gap_ms: t["gap_ms"] ?? -1)
                    }
                    XCTAssertEqual(tape.list, list, "\(label): the take list")
                    XCTAssertEqual(tape.parts, x["parts"] as? [[String: Int]], "\(label): the pre-roll, the take and the tail of each take")
                    let deleted = (x["deleted"] as? Bool) ?? false
                    XCTAssertEqual(tape.discarded, deleted, "\(label): deleted")
                    if !deleted { XCTAssertEqual(tape.completed, true, label) }
                    if (x["closed_at_cap"] as? Bool) == true {
                        XCTAssertEqual(tape.samples, TakeJoin.capSamples(rate: tape.rate), "\(label): closed at the cap")
                    }
                }
                if timers { recordings += got.count }
            }
        }
        print("sharing_30 vector: \(cases.count) cases, \(recordings) recordings, with and without the window's timer")
    }

    // MARK: take_seq and gap_ms_prev

    func testTheGapToThePreviousRecording() {
        XCTAssertNil(ShareSequencer.gap(previousEnd: nil, start: 5_000))
        XCTAssertEqual(ShareSequencer.gap(previousEnd: 1_000, start: 5_000), 4_000)
        XCTAssertEqual(ShareSequencer.gap(previousEnd: 1_000, start: 1_000), 0)
        XCTAssertEqual(ShareSequencer.gap(previousEnd: 0, start: 1_800_049), 1_800_000)
        XCTAssertEqual(ShareSequencer.gap(previousEnd: 0, start: 1_800_050), 1_800_100, "half up")
        XCTAssertEqual(ShareSequencer.gap(previousEnd: 0, start: 3_600_000), 3_600_000)
        XCTAssertNil(ShareSequencer.gap(previousEnd: 0, start: 3_600_001), "above an hour: absent")
        XCTAssertNil(ShareSequencer.gap(previousEnd: 2_000, start: 1_999), "a clock set back: absent")
    }

    /// The count lives in the storage: it goes on after a relaunch, and only a deletion resets it.
    func testTheCountOfRecordingsIsKeptInTheStorage() throws {
        let file = Fixtures.storage().appendingPathComponent("cloud/sharing-seq.json")
        let a = ShareSequencer.stored { file }
        XCTAssertEqual(a.next(1_000, false).seq, 1)
        XCTAssertNil(a.next(2_000, false).gapMsPrev, "no take has ended yet")
        a.takeEnded(10_000)
        // a new process
        let b = ShareSequencer.stored { file }
        let third = b.next(14_020, false)
        XCTAssertEqual(third.seq, 3)
        XCTAssertEqual(third.gapMsPrev, 4_000)
        let continued = b.next(14_020, true)
        XCTAssertEqual(continued.seq, 4)
        XCTAssertEqual(continued.gapMsPrev, 0, "a continuation at the cap: present, 0")
        ShareSequencer.reset(file)
        let again = b.next(20_000, false)
        XCTAssertEqual(again.seq, 1)
        XCTAssertNil(again.gapMsPrev)
    }

    /// The session JSON carries them only when there is a count, and `gap_ms_prev` only within its range.
    func testTheSessionJSONFields() throws {
        func session(_ seq: Int?, _ gap: Int?) throws -> [String: Any] {
            let d = ContributionClient.session(modelRevision: "4.0.0", backend: "exact", weightsSHA256: nil, consentVersion: "share-2026-11-09",
                                               contributor: String(repeating: "a", count: 32), day: "2026-11-11", inputSampleRate: 16_000,
                                               inputRoute: "builtin", modelBuild: AnalyticsAndIssueTests.build, takeSeq: seq, gapMsPrev: gap)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        }
        let first = try session(1, nil)
        XCTAssertEqual(first["take_seq"] as? Int, 1)
        XCTAssertNil(first["gap_ms_prev"])
        let second = try session(2, 4_000)
        XCTAssertEqual(second["take_seq"] as? Int, 2)
        XCTAssertEqual(second["gap_ms_prev"] as? Int, 4_000)
        XCTAssertEqual(try session(3, 0)["gap_ms_prev"] as? Int, 0, "0 is present")
        let none = try session(nil, 4_000)
        XCTAssertNil(none["take_seq"])
        XCTAssertNil(none["gap_ms_prev"])
        XCTAssertNil(try session(0, nil)["take_seq"], "no count is kept: no field")
        let decode = try XCTUnwrap(second["decode"] as? [String: Any])
        XCTAssertEqual(decode["model_revision"] as? String, "4.0.0", "the model version")
        XCTAssertEqual(decode["model_build"] as? String, AnalyticsAndIssueTests.build)
    }

    // MARK: the bounds

    /// The ring is a fixed second at the feed's rate, however much is fed and however large a buffer is.
    func testTheRingNeverHoldsMoreThanASecond() {
        for rate in [16_000.0, 48_000.0] {
            let w = World()
            let second = Int(rate)
            XCTAssertEqual(ShareFeed.ringSamples(rate: rate), second)
            // 30 s in 100 ms buffers: a fixed number of calls
            for i in 0..<300 {
                w.at(Int64(i + 1) * 100)
                w.feed(second / 10, rate: rate)
                XCTAssertLessThanOrEqual(w.recorder.ringSamples, second)
            }
            XCTAssertEqual(w.recorder.ringSamples, second)
            // one buffer of 3 s: its last second
            w.at(33_000)
            XCTAssertEqual(w.feed(min(3 * second, 160_000), rate: rate).toRing, min(3 * second, 160_000))
            XCTAssertEqual(w.recorder.ringSamples, second)
            // the other rate: the ring starts anew
            let other = rate == 16_000 ? 48_000.0 : 16_000.0
            w.at(33_100)
            w.feed(1_000, rate: other)
            XCTAssertEqual(w.recorder.ringSamples, 1_000)
        }
    }

    /// Nothing fed is kept without sharing on and the learner's yes, during a take, or after sharing goes off.
    func testNothingFedIsKeptWithoutAYes() throws {
        let w = World(on: false)
        w.at(100)
        XCTAssertEqual(w.feed(1_600), ShareFeed.Fed(toTail: 0, toRing: 0, dropped: 1_600))
        XCTAssertEqual(w.recorder.ringSamples, 0, "nothing in memory after the call")
        w.on.withLock { $0 = true }
        w.at(200)
        XCTAssertEqual(w.feed(1_600).toRing, 1_600)
        XCTAssertEqual(w.recorder.ringSamples, 1_600)
        // off: the ring is emptied at once, by the switch and by the next buffer alike
        w.on.withLock { $0 = false }
        w.at(300)
        XCTAssertEqual(w.feed(1_600).dropped, 1_600)
        XCTAssertEqual(w.recorder.ringSamples, 0)
        w.on.withLock { $0 = true }
        w.at(400)
        w.feed(1_600)
        w.recorder.stop()
        XCTAssertEqual(w.recorder.ringSamples, 0, "sharing went off")
        w.at(500)
        w.feed(1_600)
        w.recorder.background()
        XCTAssertEqual(w.recorder.ringSamples, 0, "the app went to the background")
        w.recorder.foreground()
        // during a take every fed buffer is dropped
        w.at(1_000)
        let t = w.recorder.takeStarted(.init(revision: "r", backend: .exact, weightsSHA256: nil))
        try w.recorder.audio(t, w.audio(16_000), rate: 16_000)
        XCTAssertEqual(w.feed(1_600).dropped, 1_600)
        XCTAssertEqual(w.recorder.ringSamples, 0)
        w.at(2_000)
        w.recorder.takeEnded(t, completed: true)
        w.settle()
    }

    /// The tail is at most half a second per take, whatever is fed after it.
    func testTheTailIsAtMostHalfASecond() throws {
        let w = World()
        try w.take(0, 32_000, 2_000)
        var tail = 0
        // 5 s fed after the take, in 100 ms buffers
        for i in 0..<50 {
            w.at(2_000 + Int64(i + 1) * 100)
            tail += w.feed(1_600).toTail
        }
        XCTAssertEqual(tail, ShareFeed.tailSamples(rate: 16_000))
        XCTAssertEqual(tail, 8_000)
        XCTAssertEqual(w.tapes.first?.samples, 40_000)
        XCTAssertNil(w.recorder.current, "the window passed while the app fed on")
        // one large buffer right after a take: half a second of it
        let x = World()
        try x.take(0, 32_000, 2_000)
        x.at(3_000)
        let fed = x.feed(16_000)
        XCTAssertEqual(fed.toTail, 8_000)
        XCTAssertEqual(fed.toRing, 8_000)
        x.settle()
    }

    /// The tail wait runs from the take's END, after every take, whether or not the app fed before: a buffer that
    /// arrives within 1500 ms goes to the tail, a later one goes to the ring however it continues, and feeding does not
    /// extend the wait.
    func testTheTailWaitRunsFromTheTakesEnd() throws {
        // no feed before the take, the join window 0: the first fed buffer after the take is its tail
        let a = World(window: 0)
        try a.take(0, 32_000, 2_000)
        a.at(3_400)
        XCTAssertNotNil(a.recorder.current, "open for its tail 1400 ms after the take")
        let inTime = a.feed(22_400)
        XCTAssertEqual(inTime.toTail, 8_000, "1.4 s after the take's end: the tail")
        XCTAssertEqual(inTime.toRing, 14_400)
        XCTAssertNil(a.recorder.current, "the tail is complete and no take can join: closed")
        XCTAssertEqual(a.tapes.first?.samples, 40_000)
        // 1.6 s after the take's end: too late, although the buffer continues from the take
        for timers in [true, false] {
            let b = World(window: 0, timers: timers)
            try b.take(0, 32_000, 2_000)
            b.at(3_600)
            let late = b.feed(25_600)
            XCTAssertEqual(late.toTail, 0, "timers \(timers): the tail wait is over")
            XCTAssertEqual(late.toRing, 25_600)
            XCTAssertEqual(b.recorder.ringSamples, 16_000, "the ring keeps its last second")
            XCTAssertNil(b.recorder.current, "timers \(timers): the recording closed without a tail")
            XCTAssertEqual(b.tapes.first?.samples, 32_000, "exactly the take's samples")
            XCTAssertEqual(b.tapes.first?.completed, true)
        }
        // feeding does not extend the wait: it runs from the take's end, not from the last fed buffer
        let c = World(window: 0, timers: false)
        try c.take(0, 32_000, 2_000)
        c.at(2_100)
        XCTAssertEqual(c.feed(1_600).toTail, 1_600, "in time")
        c.at(3_501)
        // 1.4 s of audio that continues from that buffer, 1501 ms after the take's end
        XCTAssertEqual(c.feed(22_400).toTail, 0, "too late for the tail")
        XCTAssertNil(c.recorder.current)
        XCTAssertEqual(c.tapes.first?.samples, 33_600, "the take and the 100 ms that came in time")
    }

    /// With window 0 a recording waits for its tail no longer than `tailWaitMs` after the take's end.
    func testARecordingWaitsForItsTailOnlySoLong() throws {
        let w = World(window: 0)
        try w.take(0, 32_000, 2_000)
        XCTAssertNotNil(w.recorder.current)
        w.at(2_000 + ShareFeed.tailWaitMs)
        XCTAssertNotNil(w.recorder.current)
        w.at(2_000 + ShareFeed.tailWaitMs + 1)
        XCTAssertNil(w.recorder.current, "no feed came")
        // the tail completes: closed with its last sample
        let x = World(window: 0)
        try x.take(0, 32_000, 2_000)
        for i in 0..<5 {
            x.at(2_000 + Int64(i + 1) * 100)
            XCTAssertNotNil(x.recorder.current)
            XCTAssertEqual(x.feed(1_600).toTail, 1_600)
        }
        XCTAssertNil(x.recorder.current, "the tail is complete and no take can join")
        XCTAssertEqual(x.tapes.first?.samples, 40_000)
        XCTAssertEqual(x.tapes.first?.completed, true)
    }

    /// A take held near the cap keeps at most 30 s (and its pre-roll) in memory: past that it is written out.
    func testAHeldTakeKeepsAtMostThirtySecondsInMemory() throws {
        let w = World()
        try w.take(0, 1_171 * 16_000, 1_171_000)   // 29 s of room
        w.at(1_171_500)
        let t = w.recorder.takeStarted(.init(revision: "8b9e3beb169a41b234eacc93252d7bcc141f0b27", version: "4.0.0", backend: .exact,
                                             weightsSHA256: nil))
        let limit = Int(TakeJoin.holdMs) * 16 + ShareFeed.ringSamples(rate: 16_000)
        // 60 s in 1 s pushes
        for _ in 0..<60 {
            try w.recorder.audio(t, w.audio(16_000), rate: 16_000)
            XCTAssertLessThanOrEqual(w.recorder.heldSamples, limit)
        }
        XCTAssertTrue(w.recorder.wasHeld)
        XCTAssertEqual(w.recorder.heldSamples, 0, "it outgrew the room: written to its own recording")
        w.at(1_231_500)
        w.recorder.takeEnded(t, completed: true)
        w.settle()
        XCTAssertEqual(w.tapes.map(\.samples), [1_171 * 16_000, 60 * 16_000])
    }

    /// A take that runs past 20 minutes: the recording closes whole at the cap and the take goes on in the next one,
    /// which is the install's next recording with no gap.
    func testARecordingClosesAtTheCapInsideATake() throws {
        let w = World()
        w.at(0)
        let t = w.recorder.takeStarted(.init(revision: "8b9e3beb169a41b234eacc93252d7bcc141f0b27", version: "4.0.0", backend: .exact,
                                             weightsSHA256: nil))
        // 1250 s in pushes of 10 s
        for _ in 0..<125 { try w.recorder.audio(t, w.audio(160_000), rate: 16_000) }
        XCTAssertEqual(w.tapes.map(\.samples), [1_200 * 16_000, 50 * 16_000])
        XCTAssertEqual(w.tapes.first?.completed, true, "closed at the cap, as a whole recording")
        w.at(1_250_000)
        w.recorder.takeEnded(t, completed: true)
        w.settle()
        XCTAssertEqual(w.tapes.map(\.takeSeq), [1, 2])
        XCTAssertEqual(w.tapes.map(\.gapMsPrev), [nil, 0])
        XCTAssertEqual(w.tapes.map(\.completed), [true, true])
        XCTAssertTrue(w.tapes.allSatisfy { $0.list == nil })
    }
}
