import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 2.0.3, takes in a row share one recording: the join rules of `ShareRecorder` on their own, with a clock and a
/// timer the test moves (nothing sleeps) and recordings that only count what they are given (no codec, no network).
/// The shared vector `takes_join.json` is replayed case by case; the rest are the rules the vector leaves to the SDKs
/// (a take without audio, the hold near the 20 minute cap, 256 takes, the app's life, sharing going off, what a
/// recording is bound to, a clock set back).
final class ShareRecorderTests: XCTestCase {
    /// A recording that counts: its input rate, samples, the last take list it was told, and how it ended.
    final class Counted: ShareRecording {
        var rate = 0.0
        var samples: Int64 = 0
        var list: [ShareTake]?
        var completed: Bool?
        var discarded = false
        var dead = false
        var ms: Int64 { rate == 0 ? 0 : samples * 1000 / Int64(rate) }

        func append(_ mono: [Float], rate: Double) throws(RecognizerError) {
            if completed != nil { XCTFail("audio after the end") }
            if self.rate == 0 { self.rate = rate }
            if rate != self.rate { XCTFail("a recording has one input rate") }
            samples += Int64(mono.count)
        }

        func takes(_ list: [ShareTake]) {
            if completed != nil { XCTFail("a take list after the end") }
            if list.count < 2 || list.first != ShareTake(start_ms: 0, gap_ms: 0) { XCTFail("a list is written when a take joins: \(list)") }
            for i in list.indices.dropFirst() where list[i].start_ms <= list[i - 1].start_ms { XCTFail("start_ms must increase: \(list)") }
            self.list = list
        }

        func finish(completed: Bool) {
            if self.completed != nil { XCTFail("ended twice") }
            self.completed = completed
        }

        func discard() {
            if completed != nil { XCTFail("ended twice") }
            completed = false
            discarded = true
        }

        var isAlive: Bool { completed == nil && !dead }
    }

    struct Pending: Sendable {
        let due: Int64
        let id: Int
        let task: @Sendable () -> Void
    }

    /// The recorder under test with its world: the clock, the timers, sharing's switches and every recording it opened.
    final class World: @unchecked Sendable {
        let nowMs: Locked<Int64>
        let window: Locked<Int>
        let on: Locked<Bool>
        let identity: Locked<String>
        let opened: Locked<[Counted]>
        let due: Locked<[Pending]>
        let recorder: ShareRecorder
        private var token = 0
        private let silence = [Float](repeating: 0, count: 4_096)

        init(window: Int = TakeJoin.defaultWindowMs, timers: Bool = true) {
            let nowMs = Locked<Int64>(0)
            let win = Locked(window)
            let on = Locked(true)
            let identity = Locked("learner")
            let opened = Locked<[Counted]>([])
            let due = Locked<[Pending]>([])
            let ids = Locked(0)
            self.nowMs = nowMs
            self.window = win
            self.on = on
            self.identity = identity
            self.opened = opened
            self.due = due
            let r = ShareRecorder(
                clock: { Date(timeIntervalSince1970: Double(nowMs.withLock { $0 }) / 1000) },
                window: { win.withLock { $0 } },
                active: { on.withLock { $0 } },
                identity: { (_: ShareRecorder.TakeInfo) -> [String] in [identity.withLock { $0 }] },
                open: { (_: ShareRecorder.TakeInfo) -> (any ShareRecording)? in
                    let c = Counted()
                    opened.withLock { $0.append(c) }
                    return c
                })
            // the window's timer: kept here until the test moves the clock past it (never run by itself)
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

        var now: Int64 {
            get { nowMs.withLock { $0 } }
            set { nowMs.withLock { $0 = newValue } }
        }

        /// Timers waiting.
        var armed: Int { due.withLock { $0.count } }

        /// Every recording the recorder opened, in order.
        var all: [Counted] { opened.withLock { $0 } }

        /// The recordings that got audio, in order (one without audio keeps nothing, as the real capture).
        var recordings: [Counted] { all.filter { $0.samples > 0 } }

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
            now = t
        }

        func start(revision: String = "v4.0+abc") {
            token = recorder.takeStarted(.init(revision: revision, backend: .exact, weightsSHA256: nil))
        }

        func audio(_ samples: Int64, rate: Double = 16_000) throws {
            var left = samples
            while left > 0 {
                let k = Int(min(left, Int64(silence.count)))
                try recorder.audio(token, k == silence.count ? silence : Array(silence[0..<k]), rate: rate)
                left -= Int64(k)
            }
        }

        func end(_ completed: Bool = true) { recorder.takeEnded(token, completed: completed) }

        /// One take: starts at `start`, `samples` of audio at `rate`, ends at `end`.
        func take(_ start: Int64, _ samples: Int64, _ end: Int64, rate: Double = 16_000, completed: Bool = true) throws {
            at(start)
            self.start()
            try audio(samples, rate: rate)
            at(end)
            self.end(completed)
        }

        /// Time passes until nothing waits; every recording must have ended.
        func settle(file: StaticString = #filePath, line: UInt = #line) {
            at(now + 60_000)
            recorder.checkWindow()
            XCTAssertNil(recorder.current, "no recording left open", file: file, line: line)
            XCTAssertTrue(all.allSatisfy { $0.completed != nil }, "every recording ended", file: file, line: line)
        }
    }

    func takes(_ t: (Int, Int)...) -> [ShareTake] { t.map { ShareTake(start_ms: $0.0, gap_ms: $0.1) } }

    /// The shared vector: every case, once with the window's timer running and once without it (the clock decides).
    func testTheSharedTakesJoinVector() throws {
        let v = try SharingBitrateTests.vector("takes_join.json")
        XCTAssertEqual(v["default_window_ms"] as? Int, TakeJoin.defaultWindowMs)
        XCTAssertEqual((v["cap_ms"] as? NSNumber)?.int64Value, TakeJoin.capMs)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 10)
        var recordings = 0
        for c in cases {
            for timers in [true, false] {
                let name = "\((c["name"] as? String) ?? "?") (\(timers ? "timer" : "no timer"))"
                // the window as the signed config's flags give it
                let flags = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["flags"] as? [String: Any], name))
                let window = try JSONDecoder().decode(RemoteConfig.Flags.self, from: flags).share_join_ms
                let w = World(window: window, timers: timers)
                for e in try XCTUnwrap(c["events"] as? [[String: Any]], name) {
                    if e["event"] as? String == "background" {
                        w.at(try XCTUnwrap((e["wall_ms"] as? NSNumber)?.int64Value, name))
                        w.recorder.background()
                        continue
                    }
                    XCTAssertEqual(e["event"] as? String, "take", name)
                    w.at(try XCTUnwrap((e["start_wall_ms"] as? NSNumber)?.int64Value, name))
                    // a take is recited in the foreground
                    w.recorder.foreground()
                    let rate = try XCTUnwrap((e["rate"] as? NSNumber)?.doubleValue, name)
                    w.start()
                    try w.audio(try XCTUnwrap((e["samples"] as? NSNumber)?.int64Value, name), rate: rate)
                    w.at(try XCTUnwrap((e["end_wall_ms"] as? NSNumber)?.int64Value, name))
                    w.end(true)
                }
                w.settle()
                let want = try XCTUnwrap(c["expect"] as? [[String: Any]], name)
                let got = w.recordings
                XCTAssertEqual(got.count, want.count, name)
                for (r, x) in zip(got, want) {
                    XCTAssertEqual(r.rate, (x["rate"] as? NSNumber)?.doubleValue, name)
                    XCTAssertEqual(r.ms, (x["audio_ms"] as? NSNumber)?.int64Value, name)
                    let list: [ShareTake]? = (x["takes"] as? [[String: Int]])?.map { (t: [String: Int]) -> ShareTake in
                        ShareTake(start_ms: t["start_ms"] ?? -1, gap_ms: t["gap_ms"] ?? -1)
                    }
                    XCTAssertEqual(r.list, list, name)
                    XCTAssertEqual(r.completed, true, name)
                }
                if timers { recordings += got.count }
            }
        }
        print("takes join vector: \(cases.count) cases, \(recordings) recordings, with and without the window's timer")
    }

    /// `flags.share_join_ms`: a whole number 0 to 10000, anything else the default.
    func testTheWindowIsAWholeNumberFrom0To10000() throws {
        func window(_ json: String) throws -> Int {
            try JSONDecoder().decode(RemoteConfig.Flags.self, from: Data(json.utf8)).share_join_ms
        }
        XCTAssertEqual(RemoteConfig.Flags().share_join_ms, 3000)
        XCTAssertEqual(try window("{}"), 3000, "absent")
        XCTAssertEqual(try window("{\"contributions\":true}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":0}"), 0)
        XCTAssertEqual(try window("{\"share_join_ms\":1}"), 1)
        XCTAssertEqual(try window("{\"share_join_ms\":8000}"), 8000)
        XCTAssertEqual(try window("{\"share_join_ms\":10000}"), 10_000)
        XCTAssertEqual(try window("{\"share_join_ms\":10001}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":-100}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":2.5}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":\"8000\"}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":true}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":false}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":null}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":[5]}"), 3000)
        XCTAssertEqual(try window("{\"share_join_ms\":{\"ms\":5}}"), 3000)
        XCTAssertEqual(TakeJoin.window(.number(3000)), 3000)
        XCTAssertEqual(TakeJoin.window(.number(1e300)), 3000)
        XCTAssertEqual(TakeJoin.window(.bool(true)), 3000)
        XCTAssertEqual(TakeJoin.window(nil), 3000)
        // a config whose flag is not a number still verifies and parses: the other flags are read
        let flags = try JSONDecoder().decode(RemoteConfig.Flags.self, from: Data("{\"share_join_ms\":\"x\",\"contributions\":true,\"issues\":false}".utf8))
        XCTAssertTrue(flags.contributions)
        XCTAssertFalse(flags.issues)
    }

    /// The gap is rounded to the nearest 100 ms, half up, within 0 to 10000; `start_ms` is floored.
    func testGapsRoundToHundredsAndStartsFloor() {
        let gaps: [(Int64, Int)] = [(0, 0), (49, 0), (50, 100), (149, 100), (150, 200), (1200, 1200), (2999, 3000), (9949, 9900),
                                    (9950, 10_000), (10_000, 10_000), (99_999, 10_000), (-1, 0), (-5_000, 0)]
        for (gap, want) in gaps { XCTAssertEqual(TakeJoin.gapMs(gap), want, "gap \(gap)") }
        XCTAssertEqual(TakeJoin.ms(12_345, rate: 16_000), 771)
        XCTAssertEqual(TakeJoin.ms(12_345 + 999, rate: 16_000), 834)
        XCTAssertEqual(TakeJoin.ms(44_099, rate: 44_100), 999)
        XCTAssertEqual(TakeJoin.ms(20 * 60 * 48_000, rate: 48_000), 1_200_000)
        XCTAssertTrue(TakeJoin.fits(recording: 1199 * 16_000, take: 16_000, rate: 16_000))
        XCTAssertFalse(TakeJoin.fits(recording: 1199 * 16_000, take: 16_016, rate: 16_000))
        XCTAssertEqual(TakeJoin.maxTakes, 256)
        XCTAssertEqual(TakeJoin.holdMs, 30_000)
    }

    /// A take that pushes no audio adds no entry and does not move the previous take's end.
    func testATakeWithoutAudioAddsNoEntryAndDoesNotMoveTheEnd() throws {
        let w = World()
        try w.take(0, 5 * 16_000, 5_000)
        try w.take(6_000, 0, 7_000)
        // 2900 ms after the take that had audio: inside the window, whatever the empty take did
        try w.take(7_900, 3 * 16_000, 10_900)
        w.settle()
        XCTAssertEqual(w.recordings.count, 1)
        XCTAssertEqual(w.recordings.first?.list, takes((0, 0), (5_000, 2_900)))
        XCTAssertEqual(w.recordings.first?.ms, 8_000)
        XCTAssertEqual(w.all.count, 1, "no recording was made for the take without audio")

        // an empty take that ends after the window (from the last audio) closes the recording there
        let x = World()
        try x.take(0, 5 * 16_000, 5_000)
        try x.take(6_000, 0, 8_500)
        XCTAssertNil(x.recorder.current, "closed when the empty take ended, 3500 ms after the audio")
        try x.take(8_600, 16_000, 9_600)
        x.settle()
        XCTAssertEqual(x.recordings.map(\.ms), [5_000, 1_000])
        XCTAssertTrue(x.recordings.allSatisfy { $0.list == nil })

        // a recording whose first take has no audio keeps nothing, and the next take starts its own
        let y = World()
        try y.take(0, 0, 1_000)
        XCTAssertNil(y.recorder.current)
        try y.take(1_500, 16_000, 2_500)
        y.settle()
        XCTAssertEqual(y.recordings.count, 1)
        XCTAssertNil(y.recordings.first?.list)
        // the empty take was cancelled: the completed flag is the last take's that had audio
        let z = World()
        try z.take(0, 16_000, 1_000)
        try z.take(1_500, 0, 2_000, completed: false)
        z.settle()
        XCTAssertEqual(z.recordings.first?.completed, true)
    }

    /// `completed` is the last take's; a cancelled last take ends the recording as not completed.
    func testCompletedIsTheLastTakes() throws {
        let w = World()
        try w.take(0, 16_000, 1_000, completed: false)
        try w.take(1_500, 16_000, 2_500)
        w.settle()
        XCTAssertEqual(w.recordings.first?.completed, true)
        let x = World()
        try x.take(0, 16_000, 1_000)
        try x.take(1_500, 16_000, 2_500, completed: false)
        x.settle()
        XCTAssertEqual(x.recordings.first?.completed, false)
        XCTAssertEqual(x.recordings.first?.list, takes((0, 0), (1_000, 500)))
    }

    /// A joining take whose start is not after the last entry's adds no entry; its audio still joins.
    func testABoundaryThatDoesNotAdvanceAddsNoEntry() throws {
        let w = World()
        try w.take(0, 5, 100)          // 5 samples: under a millisecond
        try w.take(200, 5, 300)        // starts at 0 ms too: no entry
        try w.take(400, 16_000, 1_400) // starts at 0 ms still (10 samples)
        try w.take(1_500, 16_000, 2_500)
        w.settle()
        XCTAssertEqual(w.recordings.count, 1)
        XCTAssertEqual(w.recordings.first?.samples, 32_010)
        XCTAssertEqual(w.recordings.first?.list, takes((0, 0), (1_000, 100)))
    }

    /// The window's edge, its expiry by the timer, and a timer that fires early or not at all.
    func testTheWindowExpiresByTheClock() throws {
        let w = World()
        try w.take(0, 16_000, 1_000)
        XCTAssertEqual(w.armed, 1, "one timer for the window")
        w.at(4_000)
        XCTAssertNotNil(w.recorder.current, "3000 ms later the recording still waits")
        w.at(4_001)
        XCTAssertNil(w.recorder.current, "one millisecond past the window it is closed")
        XCTAssertEqual(w.armed, 0)
        XCTAssertEqual(w.all.first?.completed, true)

        // the timer fired early (a coarse timer): the clock says the window has not passed, so it waits on
        let x = World(timers: false)
        try x.take(0, 16_000, 1_000)
        x.now = 2_500
        x.recorder.checkWindow()
        XCTAssertNotNil(x.recorder.current)
        x.now = 4_000
        x.recorder.checkWindow()
        XCTAssertNotNil(x.recorder.current, "exactly the window: still open")
        try x.take(4_000, 16_000, 5_000)
        XCTAssertEqual(x.all.first?.list, takes((0, 0), (1_000, 3_000)), "joined at the edge")
        // no timer at all: the next take's start decides
        try x.take(8_001, 16_000, 9_001)
        x.settle()
        XCTAssertEqual(x.recordings.map(\.ms), [2_000, 1_000])

        // a take that starts cancels the wait; the window starts again when it ends
        let y = World()
        try y.take(0, 16_000, 1_000)
        y.at(3_000)
        y.start()
        XCTAssertEqual(y.armed, 0)
        y.at(60_000)
        XCTAssertNotNil(y.recorder.current, "a running take keeps its recording however long it runs")
        try y.audio(16_000)
        y.end()
        XCTAssertEqual(y.armed, 1)
        y.at(63_000)
        XCTAssertNotNil(y.recorder.current)
        y.at(63_001)
        XCTAssertNil(y.recorder.current)
        XCTAssertEqual(y.all.first?.list, takes((0, 0), (1_000, 2_000)))
    }

    /// Window 0 never joins: every take ends its recording, as 2.0.2 did.
    func testWindowZeroEndsTheRecordingWithTheTake() throws {
        let w = World(window: 0)
        try w.take(0, 16_000, 1_000)
        XCTAssertNil(w.recorder.current, "closed with the take")
        XCTAssertEqual(w.armed, 0)
        try w.take(1_000, 16_000, 2_000)
        XCTAssertEqual(w.recordings.count, 2)
        XCTAssertTrue(w.recordings.allSatisfy { $0.list == nil && $0.completed == true })
        // the config's window changes between takes: the one in force at each decision counts
        let x = World(window: 8_000)
        try x.take(0, 16_000, 1_000)
        try x.take(8_500, 16_000, 9_500)
        XCTAssertEqual(x.all.first?.list, takes((0, 0), (1_000, 7_500)))
        x.window.withLock { $0 = 0 }
        try x.take(9_600, 16_000, 10_600)
        x.settle()
        XCTAssertEqual(x.recordings.count, 2, "window 0 at the take's start: a new recording")
    }

    /// The app in the background: a waiting recording closes at once, a running take's when the take ends.
    func testTheBackgroundClosesTheRecording() throws {
        let w = World()
        try w.take(0, 16_000, 1_000)
        w.at(1_200)
        w.recorder.background()
        XCTAssertNil(w.recorder.current, "closed in the window")
        XCTAssertEqual(w.armed, 0)
        // a take recited while the app is still in the background ends its recording with itself
        try w.take(1_500, 16_000, 2_500)
        XCTAssertNil(w.recorder.current)
        w.recorder.foreground()
        try w.take(2_600, 16_000, 3_600)
        XCTAssertNotNil(w.recorder.current, "in the foreground again the recording waits")
        // the background during a take: the take keeps its recording, which closes when it ends
        w.at(3_800)
        w.start()
        try w.audio(16_000)
        w.recorder.background()
        XCTAssertNotNil(w.recorder.current)
        try w.audio(16_000)
        w.at(5_800)
        w.end()
        XCTAssertNil(w.recorder.current)
        w.settle()
        XCTAssertEqual(w.recordings.map(\.ms), [1_000, 1_000, 3_000])
        XCTAssertEqual(w.recordings.last?.list, takes((0, 0), (1_000, 200)))
    }

    /// Sharing going off ends the recording at once, in a take or between takes, and nothing more is recorded.
    func testSharingOffEndsTheRecordingAtOnce() throws {
        let w = World()
        try w.take(0, 16_000, 1_000)
        w.at(1_500)
        w.on.withLock { $0 = false }
        w.recorder.stop()
        XCTAssertNil(w.recorder.current)
        XCTAssertEqual(w.all.first?.discarded, true, "nothing of it is kept")
        XCTAssertEqual(w.armed, 0)
        try w.take(1_600, 16_000, 2_600)
        XCTAssertEqual(w.all.count, 1, "nothing is opened while sharing is off")
        // off during a take: the rest of the take is not recorded
        w.on.withLock { $0 = true }
        w.at(10_000)
        w.start()
        try w.audio(16_000)
        w.on.withLock { $0 = false }
        w.recorder.stop()
        try w.audio(16_000)
        w.at(12_000)
        w.end()
        XCTAssertEqual(w.all.count, 2)
        XCTAssertEqual(w.all.last?.samples, 16_000)
        XCTAssertEqual(w.all.last?.discarded, true)
        // off without the stop call (the signed config's flag read at the next take): the take does not join
        let x = World()
        try x.take(0, 16_000, 1_000)
        x.on.withLock { $0 = false }
        try x.take(1_500, 16_000, 2_500)
        XCTAssertEqual(x.all.count, 1)
        XCTAssertNil(x.recorder.current)
        XCTAssertEqual(x.all.first?.samples, 16_000)
        XCTAssertEqual(x.all.first?.discarded, false, "closed as a recording ends; its files go where sharing's switch says")
    }

    /// A take joins only at the same input rate and under the same contributor, consent version and model revision.
    func testARecordingIsBoundToItsRateAndIdentity() throws {
        let w = World()
        try w.take(0, 16_000, 1_000)
        try w.take(1_500, 48_000, 2_500, rate: 48_000)
        w.identity.withLock { $0 = "another contributor" }
        try w.take(3_000, 48_000, 4_000, rate: 48_000)
        try w.take(4_500, 48_000, 5_500, rate: 48_000)
        w.settle()
        XCTAssertEqual(w.recordings.map(\.rate), [16_000, 48_000, 48_000])
        XCTAssertEqual(w.recordings.map(\.ms), [1_000, 1_000, 2_000])
        XCTAssertEqual(w.recordings.map(\.list), [nil, nil, takes((0, 0), (1_000, 500))])
        // a recording that failed (a storage error) is not joined
        let y = World()
        try y.take(0, 16_000, 1_000)
        y.all.first?.dead = true
        try y.take(1_500, 16_000, 2_500)
        y.settle()
        XCTAssertEqual(y.recordings.count, 2)
    }

    /// One input rate per take: a change inside a take ends the shared recording there (as before 2.0.3).
    func testARateChangeInsideATakeEndsTheRecordingThere() throws {
        let w = World()
        w.at(0)
        w.start()
        try w.audio(16_000)
        try w.audio(48_000, rate: 48_000)
        XCTAssertNil(w.recorder.current, "ended where the rate changed")
        try w.audio(16_000)
        w.at(3_000)
        w.end()
        XCTAssertEqual(w.all.count, 1)
        XCTAssertEqual(w.all.first?.samples, 16_000)
        XCTAssertEqual(w.all.first?.completed, false)
        // the next take starts a new recording
        try w.take(3_100, 16_000, 4_100)
        w.settle()
        XCTAssertEqual(w.recordings.count, 2)
        XCTAssertTrue(w.recordings.allSatisfy { $0.list == nil })
    }

    /// At most 256 takes in a recording: the 257th starts a new one.
    func testThe257thTakeStartsANewRecording() throws {
        let w = World()
        for i in 0..<300 { try w.take(Int64(i) * 200, 1_600, Int64(i) * 200 + 100) }
        w.settle()
        XCTAssertEqual(w.recordings.map { $0.list?.count ?? 1 }, [256, 44])
        XCTAssertEqual(w.recordings.map(\.ms), [25_600, 4_400])
        XCTAssertEqual(w.recordings.first?.list?.last, ShareTake(start_ms: 25_500, gap_ms: 100))
    }

    /// Near the 20 minute cap a joining take is held until it ends: it joins when it fits, else it starts a new
    /// recording whole.
    func testTheCapIsExactNearItAndNeverCutsATake() throws {
        let s: Int64 = 16_000
        // it fits: held while it runs, joined when it ends, and the recording, now at the cap, closes
        let w = World()
        try w.take(0, 1199 * s, 1_199_000)
        w.at(1_199_500)
        w.start()
        try w.audio(8_000)
        XCTAssertEqual(w.all.first?.samples, 1199 * s, "held, not yet in the recording")
        try w.audio(8_000)
        w.at(1_200_500)
        w.end()
        XCTAssertEqual(w.all.first?.samples, 1200 * s)
        XCTAssertEqual(w.all.first?.list, takes((0, 0), (1_199_000, 500)))
        XCTAssertNil(w.recorder.current, "20 minutes: closed at once")
        XCTAssertEqual(w.all.count, 1)

        // it outgrows the room: the recording closes without it and the take starts a new one with all its audio
        let x = World()
        try x.take(0, 1199 * s, 1_199_000)
        x.at(1_199_500)
        x.start()
        try x.audio(s)
        XCTAssertEqual(x.all.count, 1)
        try x.audio(16)
        XCTAssertEqual(x.all.count, 2, "one sample block past the room: a new recording")
        XCTAssertEqual(x.all.first?.completed, true)
        XCTAssertNil(x.all.first?.list)
        XCTAssertEqual(x.all.last?.samples, s + 16)
        try x.audio(s)
        x.at(1_201_600)
        x.end()
        x.settle()
        XCTAssertEqual(x.recordings.map(\.ms), [1_199_000, 2_001])
        XCTAssertTrue(x.recordings.allSatisfy { $0.list == nil })

        // exactly 30 s of room: held; 30 s and one millisecond: joined at once
        let y = World()
        try y.take(0, 1170 * s, 1_170_000)
        y.at(1_170_100)
        y.start()
        try y.audio(10 * s)
        XCTAssertEqual(y.all.first?.samples, 1170 * s)
        y.at(1_180_100)
        y.end()
        XCTAssertEqual(y.all.first?.samples, 1180 * s)
        let z = World()
        try z.take(0, 1170 * s - 16, 1_170_000)
        z.at(1_170_100)
        z.start()
        try z.audio(s)
        XCTAssertEqual(z.all.first?.samples, 1171 * s - 16, "more than 30 s of room: in the recording as it comes")

        // with room, a take that runs past 20 minutes stays whole; the recording closes when it ends
        let v = World()
        try v.take(0, 1100 * s, 1_100_000)
        try v.take(1_100_500, 200 * s, 1_300_500)
        XCTAssertNil(v.recorder.current, "past the cap: closed with the take")
        XCTAssertEqual(v.all.count, 1)
        XCTAssertEqual(v.all.first?.samples, 1300 * s)
        XCTAssertEqual(v.all.first?.list, takes((0, 0), (1_100_000, 500)))
        try v.take(1_300_600, s, 1_301_600)
        v.settle()
        XCTAssertEqual(v.recordings.count, 2)
        // a single take longer than 20 minutes is one recording too
        let u = World()
        try u.take(0, 1500 * s, 1_500_000)
        XCTAssertNil(u.recorder.current)
        XCTAssertEqual(u.all.count, 1)
        XCTAssertEqual(u.all.first?.samples, 1500 * s)
    }

    /// A held take: sharing going off and an empty take behave as for any other.
    func testAHeldTakeFollowsTheSameRules() throws {
        let s: Int64 = 16_000
        let w = World()
        try w.take(0, 1199 * s, 1_199_000)
        w.at(1_199_500)
        w.start()
        try w.audio(4_000)
        w.on.withLock { $0 = false }
        w.recorder.stop()
        w.at(1_199_900)
        w.end()
        XCTAssertEqual(w.all.count, 1)
        XCTAssertEqual(w.all.first?.samples, 1199 * s, "sharing went off: the held audio is gone")
        XCTAssertEqual(w.all.first?.discarded, true)
        // a held take that pushed nothing adds nothing
        let x = World()
        try x.take(0, 1199 * s, 1_199_000)
        try x.take(1_199_500, 0, 1_199_900)
        try x.take(1_200_000, 4_000, 1_200_300)
        x.settle()
        XCTAssertEqual(x.recordings.count, 1)
        XCTAssertEqual(x.recordings.first?.list, takes((0, 0), (1_199_000, 1_000)))
        XCTAssertEqual(x.recordings.first?.samples, 1199 * s + 4_000)
    }

    /// A clock set back: the gap is 0 and the take joins; a recording that waits is closed by its timer.
    func testAClockSetBack() throws {
        let w = World()
        try w.take(0, 16_000, 10_000)
        w.now = 4_000
        w.start()
        try w.audio(16_000)
        w.now = 5_000
        w.end()
        XCTAssertEqual(w.all.first?.list, takes((0, 0), (1_000, 0)))
        // the clock goes back while the recording waits: its timer ran its time, so it closes
        w.now = 1_000
        w.recorder.checkWindow()
        XCTAssertNil(w.recorder.current)
        XCTAssertEqual(w.all.count, 1)
    }

    /// A take that starts while another is open ends that one's recording as not completed (as 2.0.2 ended its
    /// session) and starts a new one: when the open take really ended is not known, so nothing joins. A recognizer
    /// whose take was ended that way cannot write into the newer take.
    func testATakeThatNeverEndedIsEndedByTheNext() throws {
        let w = World()
        w.at(0)
        let first = w.recorder.takeStarted(.init(revision: "v4.0+abc", backend: .exact, weightsSHA256: nil))
        try w.recorder.audio(first, [Float](repeating: 0, count: 16_000), rate: 16_000)
        w.at(1_000)
        let second = w.recorder.takeStarted(.init(revision: "v4.0+abc", backend: .exact, weightsSHA256: nil))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(w.all.first?.completed, false, "the first take's recording ended there")
        try w.recorder.audio(second, [Float](repeating: 0, count: 16_000), rate: 16_000)
        // the first take's recognizer is still running: its audio and its end no longer count
        try w.recorder.audio(first, [Float](repeating: 0, count: 16_000), rate: 16_000)
        w.recorder.takeEnded(first, completed: true)
        XCTAssertNotNil(w.recorder.current)
        w.at(2_000)
        w.recorder.takeEnded(second, completed: true)
        w.settle()
        XCTAssertEqual(w.recordings.map(\.samples), [16_000, 16_000])
        XCTAssertEqual(w.recordings.map(\.completed), [false, true])
        XCTAssertTrue(w.recordings.allSatisfy { $0.list == nil })

        // the same after takes that joined: the recording so far is kept, the take that never ended closes it
        let y = World()
        try y.take(0, 16_000, 1_000)
        y.at(1_500)
        y.start()
        try y.audio(16_000)
        y.at(2_600)
        y.start()
        try y.audio(16_000)
        y.at(3_600)
        y.end()
        y.settle()
        XCTAssertEqual(y.recordings.map(\.samples), [32_000, 16_000])
        XCTAssertEqual(y.recordings.first?.list, takes((0, 0), (1_000, 500)))
        XCTAssertEqual(y.recordings.map(\.completed), [false, true])
    }

    /// The default timer is a task of the process: with the real clock a waiting recording closes by itself.
    func testTheDefaultTimerClosesTheRecordingByItself() async throws {
        let closed = Locked(false)
        final class Flagging: ShareRecording {
            let closed: Locked<Bool>
            init(_ closed: Locked<Bool>) { self.closed = closed }
            func append(_ mono: [Float], rate: Double) throws(RecognizerError) {}
            func takes(_ list: [ShareTake]) {}
            func finish(completed: Bool) { closed.withLock { $0 = true } }
            func discard() { closed.withLock { $0 = true } }
            var isAlive: Bool { !closed.withLock { $0 } }
        }
        let recorder = ShareRecorder(clock: { Date() }, window: { 40 }, active: { true },
                                     identity: { (_: ShareRecorder.TakeInfo) -> [String] in [] },
                                     open: { (_: ShareRecorder.TakeInfo) -> (any ShareRecording)? in Flagging(closed) })
        let t = recorder.takeStarted(.init(revision: "v4.0+abc", backend: .exact, weightsSHA256: nil))
        try recorder.audio(t, [Float](repeating: 0, count: 1_600), rate: 16_000)
        recorder.takeEnded(t, completed: true)
        XCTAssertNotNil(recorder.current)
        let start = Date()
        while !closed.withLock({ $0 }), Date().timeIntervalSince(start) < 10 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(closed.withLock { $0 }, "the window's timer closed it")
        XCTAssertNil(recorder.current)
    }
}
