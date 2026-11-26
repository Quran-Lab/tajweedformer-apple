import Foundation
import XCTest
@testable import TajweedFormer

/// Live promotion in the take runner, with the fake engines: the runner feeds the
/// take's decide (`LiveTake`) and carries out its actions. The fake accelerator runs its own copy of the fake CPU engine,
/// so started from the same sample its chunks are the CPU's (a stand-in build that agrees), and it can be made to
/// differ, to fail, or to be slow. Its chunks carry a `conf` marker the CPU's lack, so a take tells which engine ran each
/// chunk. Silence in the audio makes the pauses (a fake chunk over silence is blank; the fake has no word bar).
final class LiveTakeTests: XCTestCase {
    override func tearDown() { LiveDiagnosis.reset() }

    func runner(ringSeconds: Double = PromotionPolicy.ringSeconds) -> TakeRunner {
        let r = TakeRunner(chunkMs: 320, ringSeconds: ringSeconds, openCPU: { () throws(RecognizerError) -> any CPUStreamEngine in FakeCPUEngine() })
        // the whole take is replayed by a failover after the swap (exact), as on a fast device
        r.policy.cpuChunkMs = 1
        r.policy.cpuOpenMs = 1
        r.policy.warmUpAtStart = false
        return r
    }

    /// Fake recitation (energy everywhere) with silence over `silences` (seconds).
    func audio(seconds: Double, silences: [ClosedRange<Double>] = [], seed: Int = 1) -> [Float] {
        var a = fakeRecitation(seconds: seconds, seed: seed)
        for s in silences {
            for i in Int(s.lowerBound * 16_000)..<min(a.count, Int(s.upperBound * 16_000)) { a[i] = 0 }
        }
        return a
    }

    /// A take as handed out: its heads, each chunk's frames and whether the accelerator ran it, the live swaps, the
    /// attempt's end and the take's tally.
    struct Take {
        var heads = HeadsBuffer()
        var frames: [Int] = []
        var onAccelerator: [Bool] = []
        var swaps: [Int] = []
        var ends: [TakeRunner.LiveEnd] = []
        var tally: LiveTally?
        var truncations: [Int] = []
        /// The call that swapped: whether the accelerator ran each of its chunks.
        var swapCall: [Bool] = []
        /// The decide's states seen after each piece, in order, without repeats.
        var states: [String] = []
        /// The greedy ids of chunk k's last two frames.
        func tail(_ k: Int) -> [Int] {
            let first = frames.prefix(k).reduce(0, +)
            return Array(heads.top1(.logProbs)[first..<(first + frames[k])].suffix(2))
        }
    }

    /// A fake clock for the decide (ms), moved by the take's pieces.
    final class Clock: @unchecked Sendable { var now = 1_000_000 }

    /// The take through `r` in pieces, with its decide (`initial`); before the piece at sample `startAt` the build of
    /// `acc` is ready (the decide starts its attempt when its rule holds). With `waitFeeds`, the attempt's replay (or
    /// catch-up round) is waited for after each piece, so its catch-up comes at the next piece. `late` marks a piece
    /// late (handed out more than a chunk after its audio); `each` runs after each piece; `stopAt` ends the take early.
    func liveTake(_ r: TakeRunner, _ audio: [Float], acc: AcceleratorExecutor? = nil, startAt: Int = .max, piece: Int = 5120,
                  stopAt: Int? = nil, initial: LiveTake.Init = LiveTake.Init(context: "c16_l64"), late: (Int) -> Bool = { _ in false },
                  waitFeeds: (Int) -> Bool = { _ in true }, each: (TakeRunner) -> Void = { _ in }) throws -> Take {
        try r.start(accelerator: nil)
        r.liveBegin(initial)
        let clock = Clock()
        r.liveClock = { clock.now }
        if let acc { r.liveLease = { acc } }
        var t = Take()
        func apply(_ o: TakeRunner.Output) {
            if let n = o.truncateTo, n < t.frames.count {
                t.heads.truncate(n40: t.frames.prefix(n).reduce(0, +))
                t.frames.removeLast(t.frames.count - n)
                t.onAccelerator.removeLast(t.onAccelerator.count - n)
                t.truncations.append(n)
            }
            for c in o.chunks {
                t.heads.append(c)
                t.frames.append(c.n40)
                t.onAccelerator.append(!c.conf.isEmpty)
            }
            if let f = o.liveSwapFrom {
                t.swaps.append(f)
                t.swapCall = o.chunks.map { !$0.conf.isEmpty }
            }
            if let e = r.takeLiveEnd() {
                t.ends.append(e)
                // the recognizer closes the take's recited journal on it, then lets it go
                if e.outcome == .swapped { r.releaseRetiredCPU() }
            }
            if let s = r.liveTake?.state.rawValue, t.states.last != s { t.states.append(s) }
        }
        let end = min(audio.count, stopAt ?? audio.count)
        var at = 0, n = 0, ready = false
        while at < end {
            if !ready, at >= startAt, acc != nil {
                r.liveReady()
                ready = true
            }
            let s = Array(audio[at..<min(end, at + piece)])
            // real time: each piece arrives as its audio ends; a late one is handed out a second after
            clock.now += s.count / 16
            apply(try r.push(s, takenAtMs: late(n) ? clock.now - 1000 : clock.now))
            if waitFeeds(n) { XCTAssertTrue(r.waitLiveFeed(20)) }
            at += piece
            n += 1
            each(r)
        }
        apply(try r.finish())
        t.tally = r.takeLiveTally()
        return t
    }

    /// The first CPU pause at or after chunk `from` of a CPU-only take.
    func pause(_ ref: Take, from: Int) -> Int? {
        (from..<ref.frames.count).first { LiveRules.isPause(tail: ref.tail($0), bar: nil) }
    }

    // MARK: a swap

    /// 30.11: a take that becomes ready mid-take swaps at the first pause after one window; the chunks before the swap
    /// are the CPU's, the ones after the stand-in's; nothing is handed out twice; the swap names `fromChunk`; the take's
    /// heads hold every chunk once (an exact replay: the take is the CPU-only one). The first window is the newest
    /// chunks both engines computed when the accelerator caught up (30.0 item 3), and the commit's chunk is its last.
    func testATakeThatBecomesReadyMidTakeSwapsAtTheFirstPauseAfterAWindow() throws {
        let a = audio(seconds: 12, silences: [6.0...7.2])
        let ref = try liveTake(runner(), a)
        let fake = FakeAccelerator()
        fake.marker = 1
        let r = runner()
        var commit: Int?
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
            if commit == nil { commit = r.liveState?.commitChunk }
        })
        XCTAssertEqual(got.states, ["cpu", "rebuild", "committed", "accel", "ended"])
        XCTAssertEqual(got.ends.count, 1)
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .swapped)
        XCTAssertTrue(e.exact, "a take of 3 s is replayed whole")
        XCTAssertEqual(r.liveTake?.verdicts, [.within], "one window")
        let c = try XCTUnwrap(commit)
        let k = try XCTUnwrap(pause(ref, from: c))
        XCTAssertGreaterThan(k, c, "the audio holds no pause before the silence at 6 s")
        XCTAssertLessThan(k - c + 1, 25, "within the cap")
        XCTAssertEqual(e.fromChunk, k + 1)
        XCTAssertEqual(got.swaps, [k + 1])
        XCTAssertEqual(r.liveSwapFrom, k + 1)
        XCTAssertEqual(got.onAccelerator, (0..<ref.frames.count).map { $0 > k }, "the CPU's chunks to the pause, the accelerator's after it")
        XCTAssertEqual(got.frames, ref.frames, "every chunk once")
        XCTAssertTrue(got.truncations.isEmpty, "nothing replaced")
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs, "an exact replay with a build that agrees: the CPU-only take")
        XCTAssertTrue(r.onAccelerator)
        XCTAssertNil(r.cpu, "the CPU engine is closed at the swap")
        XCTAssertNil(r.retiredCPU)
        XCTAssertNil(r.failover)
        XCTAssertEqual(fake.resets.withLock { $0 }, 1, "the replay reset the accelerator, nothing else did")
        XCTAssertEqual(r.chunkSeconds.count, got.frames.count)
        // 30.9: the take's tally, the audio the accelerator served from the first accelerator chunk on
        let t = try XCTUnwrap(got.tally)
        XCTAssertEqual(t.attempts, 1)
        XCTAssertEqual(t.outcome, "swapped")
        XCTAssertNotNil(t.latency)
        XCTAssertEqual(t.secondsAfterSwap, LiveRules.tenths(samples: a.count - (k + 1) * 5120))
        print("v4-live fake: commit at chunk \(c), swap after the pause at \(k)")
    }

    /// The same with pieces of a second (three chunks a call): the catch-up takes a second round off the audio path,
    /// and the swap falls inside a call, which hands out the CPU's chunks to the pause and the accelerator's after it.
    func testASwapInsideACallOfSeveralChunks() throws {
        // chunk 28 (from 143,360) is the first over the silence; the call of 144,000 to 160,000 completes chunks 27 to 29
        let a = audio(seconds: 14, silences: [8.96...10.2])
        let ref = try liveTake(runner(), a, piece: 16_000)
        let fake = FakeAccelerator()
        fake.marker = 1
        let r = runner()
        var rounds = 0
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, piece: 16_000, each: { r in
            rounds = max(rounds, r.liveState?.rounds ?? 0)
        })
        XCTAssertEqual(rounds, 1, "two seconds arrived meanwhile: a second round off the audio path")
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .swapped)
        let k = try XCTUnwrap(e.fromChunk) - 1
        XCTAssertEqual(k, 28)
        XCTAssertEqual(got.swapCall, [false, false, true], "the CPU's chunks to the pause and the accelerator's after it, in one call")
        XCTAssertEqual(got.onAccelerator, (0..<ref.frames.count).map { $0 > k })
        XCTAssertTrue(LiveRules.isPause(tail: ref.tail(k), bar: nil))
        XCTAssertEqual(got.frames, ref.frames)
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
        XCTAssertEqual(r.chunkSeconds.count, got.frames.count, "a time for each chunk handed out")
    }

    /// 30.5 (30.0 item 4): no chunk pair is compared while waiting for the pause; a chunk of the accelerator that differs
    /// after the commit does not end the attempt, and the take swaps at the pause.
    func testNothingIsComparedWhileWaitingForThePause() throws {
        let a = audio(seconds: 12, silences: [8.0...9.2])
        let fake = FakeAccelerator()
        fake.marker = 1
        let r = runner()
        var set = false
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
            guard !set, r.liveState?.state == "committed" else { return }
            set = true
            // exact: the accelerator's chunk i is take chunk i; the next chunk differs
            let next = r.chunks
            fake.differ = { $0 == next }
        })
        XCTAssertTrue(set, "the attempt committed and waited for a pause")
        XCTAssertEqual(got.ends.map(\.outcome), [.swapped])
        XCTAssertTrue(r.onAccelerator)
    }

    /// 30.5: no pause after the commit (a held madd): at 8 s of audio from the commit's chunk on, its own included (25
    /// chunks at c16), the swap is made anyway.
    func testWithoutAPauseTheSwapComesAtTheCap() throws {
        let a = audio(seconds: 30)
        let ref = try liveTake(runner(), a)
        let audioChunks = (a.count - FakeCPUEngine.window) / FakeCPUEngine.advance + 1
        XCTAssertGreaterThanOrEqual(pause(ref, from: 0) ?? .max, audioChunks, "the fake recitation has no pause")
        let fake = FakeAccelerator()
        fake.marker = 1
        let r = runner()
        var commit: Int?
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
            if commit == nil { commit = r.liveState?.commitChunk }
        })
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .swapped)
        let c = try XCTUnwrap(commit)
        XCTAssertEqual(e.fromChunk, c + 25, "the 25th chunk from the commit's is the last on the CPU")
        XCTAssertEqual(got.onAccelerator, (0..<ref.frames.count).map { $0 >= c + 25 })
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
    }

    // MARK: no swap

    /// 30.11: a stand-in whose chunks differ, the whole take in the ring: `mismatch` at the first window; the take stays
    /// on the CPU as if nothing had happened, and one attempt is all the take gets.
    func testAnExactReplayOutsideTheToleranceIsAMismatch() throws {
        let a = audio(seconds: 12, silences: [6.0...7.2])
        let ref = try liveTake(runner(), a)
        let fake = FakeAccelerator()
        fake.marker = 1
        fake.differ = { _ in true }
        let r = runner()
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000)
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .mismatch)
        XCTAssertEqual(r.liveTake?.verdicts, [.outside], "the first window decided")
        XCTAssertTrue(e.exact)
        XCTAssertEqual(LivePromotion.recordRule(e.outcome), .disagreement)
        XCTAssertFalse(got.onAccelerator.contains(true), "no chunk was taken from the accelerator")
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
        XCTAssertFalse(r.onAccelerator)
        XCTAssertNotNil(r.cpu)
        XCTAssertTrue(got.swaps.isEmpty)
        XCTAssertEqual(got.ends.count, 1, "one attempt per take")
        XCTAssertEqual(fake.resets.withLock { $0 }, 2, "the replay's reset, and the accelerator reset for the next take")
        XCTAssertEqual(got.tally, LiveTally(attempts: 1, outcome: "mismatch"))
    }

    /// 30.11: a take longer than the ring: the replay starts 30 s back (not exact), its comparable chunks 33 chunks after
    /// its first; the first window (the replay's newest chunks) outside the tolerance, a later one inside commits, and the
    /// swap comes at the next pause.
    func testALongerTakeReplaysInexactlyAndCommitsAtALaterWindow() throws {
        let a = audio(seconds: 50, silences: [46.0...47.2], seed: 2)
        let ref = try liveTake(runner(), a)
        let fake = FakeAccelerator()
        fake.marker = 1
        // the replay's chunks differ; those after the first window was judged agree
        fake.differ = { _ in true }
        let r = runner()
        var plan: LiveRules.ReplayPlan?
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 40 * 16_000, each: { r in
            guard let s = r.liveState else { return }
            if plan == nil { plan = s.plan }
            if s.windows >= 1 { fake.differ = { _ in false } }
        })
        let p = try XCTUnwrap(plan)
        XCTAssertFalse(p.exact)
        XCTAssertEqual(p.fromSample, LiveRules.replayPlan(chunkMs: 320, taken: 640_000).fromSample)
        XCTAssertEqual(p.firstChunk, 32)
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .swapped)
        XCTAssertFalse(e.exact)
        let v = try XCTUnwrap(r.liveTake?.verdicts)
        XCTAssertEqual(v.first, .outside, "the first window, the replay's own last chunks")
        XCTAssertEqual(v.last, .within)
        XCTAssertTrue((2...3).contains(v.count), "\(v)")
        let k = try XCTUnwrap(e.fromChunk) - 1
        XCTAssertEqual(k, pause(ref, from: k), "the swap is at a pause")
        XCTAssertEqual(got.onAccelerator, (0..<ref.frames.count).map { $0 > k })
        XCTAssertEqual(got.frames, ref.frames, "every chunk once")
        let cpuFrames = ref.frames.prefix(k + 1).reduce(0, +) * 38
        XCTAssertEqual(Array(got.heads.logProbs.prefix(cpuFrames)), Array(ref.heads.logProbs.prefix(cpuFrames)), "the CPU's chunks as handed out")
        print("v4-live fake inexact: replay from chunk \(p.firstChunk), windows \(v), swap after chunk \(k)")
    }

    /// 30.11: the same longer take with a stand-in that differs everywhere: three windows outside, `mismatch_inexact`.
    func testThreeWindowsOutsideAfterAnInexactReplayAreMismatchInexact() throws {
        let a = audio(seconds: 50, seed: 2)
        let ref = try liveTake(runner(), a)
        let fake = FakeAccelerator()
        fake.differ = { _ in true }
        let r = runner()
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 40 * 16_000)
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .mismatchInexact)
        XCTAssertFalse(e.exact)
        XCTAssertEqual(r.liveTake?.verdicts, [.outside, .outside, .outside])
        XCTAssertEqual(LivePromotion.recordRule(e.outcome), .deadlineMiss)
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
        XCTAssertFalse(r.onAccelerator)
    }

    /// 30.5: late from the commit on for 20 s of audio (63 chunks at c16): the swap stays off (also at the cap), and the
    /// attempt ends `stalled`; the take stays on the CPU and the record is untouched.
    func testALateTakeStallsTheSwapAndEndsStalled() throws {
        let a = audio(seconds: 40)
        let ref = try liveTake(runner(), a)
        let fake = FakeAccelerator()
        fake.marker = 1
        let r = runner()
        // late from the piece after the commit on (a box: both closures read it, one sets it)
        let lateFrom = Locked(Int.max)
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, late: { n in lateFrom.withLock { $0 } <= n }, each: { r in
            if r.liveState?.state == "committed" { lateFrom.withLock { if $0 == .max { $0 = 0 } } }
        })
        XCTAssertEqual(got.ends.map(\.outcome), [.stalled])
        XCTAssertNil(LivePromotion.recordRule(.stalled))
        XCTAssertFalse(got.onAccelerator.contains(true))
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
        XCTAssertEqual(got.tally, LiveTally(attempts: 1, outcome: "stalled"))
    }

    /// 30.2 item 9: the build is ready while the take is in a stall (an interruption): no attempt until it ends; a take
    /// that stays in it is held under `stall`.
    func testAStallHoldsTheStartAndCountsHeld() throws {
        let a = audio(seconds: 12)
        let r = runner()
        let fake = FakeAccelerator()
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
            // interrupted from the first piece on, before the build is ready
            if !(r.liveTake?.stalled ?? true) { r.liveInterrupted() }
        })
        XCTAssertTrue(got.ends.isEmpty)
        XCTAssertEqual(got.tally, LiveTally(held: "stall"))
        XCTAssertEqual(fake.resets.withLock { $0 }, 0, "no replay")
    }

    /// 30.2 item 2: the app asked for the CPU engine: no attempt, and nothing counted (not even held).
    func testTheAppAskedForTheCPUEngine() throws {
        var i = LiveTake.Init(context: "c16_l64")
        i.appCPU = true
        let fake = FakeAccelerator()
        let r = runner()
        let got = try liveTake(r, audio(seconds: 6), acc: AcceleratorExecutor(fake), startAt: 16_000, initial: i)
        XCTAssertTrue(got.ends.isEmpty)
        XCTAssertEqual(got.tally, LiveTally())
        XCTAssertEqual(fake.resets.withLock { $0 }, 0)
    }

    /// 30.11: a take that ends during the replay, or while waiting for the pause: `aborted`; the last chunk and the
    /// flush are the CPU's, and the accelerator is reset for the next take.
    func testATakeThatEndsDuringTheReplayOrTheWaitIsAborted() throws {
        let a = audio(seconds: 12)
        let stop = 8 * 16_000 + 3 * 5120
        let ref = try liveTake(runner(), a, stopAt: stop)
        // the replay: a slow build (20 ms a chunk, 25 chunks), the take ends two pieces after the start
        let slow = FakeAccelerator()
        slow.chunkCost = 0.02
        slow.marker = 1
        let exec = AcceleratorExecutor(slow)
        let r = runner()
        let got = try liveTake(r, a, acc: exec, startAt: 8 * 16_000, stopAt: stop, waitFeeds: { _ in false })
        XCTAssertEqual(got.ends.map(\.outcome), [.aborted])
        XCTAssertFalse(got.onAccelerator.contains(true))
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs, "the take as the CPU engine alone gives it, its flush included")
        XCTAssertNil(r.liveState)
        XCTAssertEqual(got.tally, LiveTally(attempts: 1, outcome: "aborted"))
        // the build serves the next take (once what was queued on it has run)
        exec.reset(wait: true)
        slow.chunkCost = 0
        let next = try runTake(r, audio(seconds: 2), accelerator: exec)
        XCTAssertTrue(r.onAccelerator)
        XCTAssertGreaterThan(next.frames.count, 0)
        // the wait: the take ends after the commit, before a pause
        let r2 = runner()
        let got2 = try liveTake(r2, a, acc: AcceleratorExecutor(FakeAccelerator()), startAt: 8 * 16_000, stopAt: stop)
        XCTAssertEqual(got2.states.suffix(2), ["committed", "ended"])
        XCTAssertEqual(got2.ends.map(\.outcome), [.aborted])
        XCTAssertEqual(got2.heads.logProbs, ref.heads.logProbs)
    }

    /// 30.3, 30.4: an accelerator failure before the swap (a NaN, an exception, a head out of range) is `accel_failed`
    /// with its cause; the take stays on the CPU.
    func testAnAcceleratorFailureBeforeTheSwapIsAccelFailed() throws {
        let a = audio(seconds: 12, silences: [6.0...7.2])
        let ref = try liveTake(runner(), a)
        for (failure, cause) in [(FakeAccelerator.Failure.nan, FailoverCause.nonFinite), (.exception, .exception), (.outOfRange, .outOfRange)] {
            let fake = FakeAccelerator()
            let r = runner()
            var at: Int?
            let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
                guard at == nil, r.liveState?.state == "committed" else { return }
                // exact: the accelerator's chunk i is take chunk i; the next call's chunk fails
                at = r.chunks
                fake.failAt = r.chunks
                fake.failure = failure
            })
            let e = try XCTUnwrap(got.ends.first, "\(failure)")
            XCTAssertEqual(e.outcome, .accelFailed, "\(failure)")
            XCTAssertEqual(e.cause, cause, "\(failure)")
            XCTAssertEqual(e.chunk, at, "\(failure)")
            XCTAssertEqual(LivePromotion.recordRule(e.outcome), .byCause)
            XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs, "\(failure)")
            XCTAssertFalse(r.onAccelerator)
            XCTAssertNil(r.failover, "no take left the accelerator")
        }
    }

    /// A chunk past the take's deadline rule beside the CPU engine is `accel_failed` (a deadline miss).
    func testAChunkPastItsDeadlineBeforeTheSwapIsAccelFailed() throws {
        let a = audio(seconds: 12, silences: [6.0...7.2])
        let fake = FakeAccelerator()
        let r = runner()
        r.policy.deadlineMs = 50
        var set = false
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
            guard !set, r.liveState?.state == "committed" else { return }
            set = true
            fake.costs = [r.chunks: 0.12]
        })
        let e = try XCTUnwrap(got.ends.first)
        XCTAssertEqual(e.outcome, .accelFailed)
        XCTAssertEqual(e.cause, .deadline)
        XCTAssertNotNil(e.deadlineMs)
    }

    /// The build could not be leased for the replay (an abandoned one): the attempt ends `aborted`, counted.
    func testABuildThatCannotBeLeasedAbortsTheAttempt() throws {
        let hung = AcceleratorExecutor(FakeAccelerator(failAt: 0, failure: .hang(1)))
        _ = hung.run(timeout: 0.01) { (b: any AcceleratorBackend) throws(RecognizerError) -> [HeadsBuffer] in
            try [Float](repeating: 0.1, count: 8000).withBuffer { (p) throws(RecognizerError) in try b.push(p) }
        }
        XCTAssertTrue(hung.abandoned)
        let r = runner()
        let got = try liveTake(r, audio(seconds: 4), acc: hung, startAt: 16_000)
        XCTAssertEqual(got.ends.map(\.outcome), [.aborted])
        XCTAssertTrue(got.ends.first?.detail.contains("leased") == true, got.ends.first?.detail ?? "")
        XCTAssertEqual(got.tally, LiveTally(attempts: 1, outcome: "aborted"))
        // a take on the accelerator has no decide
        try r.start(accelerator: AcceleratorExecutor(FakeAccelerator()))
        r.liveBegin(LiveTake.Init(context: "c16_l64"))
        XCTAssertNil(r.liveTake)
    }

    // MARK: after the swap

    /// 30.6: after the swap the take is an accelerator take in every respect: a NaN later fails over to the CPU engine
    /// as today (the whole take replayed, exact); the tally counts the accelerator's audio to the failed chunk.
    func testAfterTheSwapAFailureFailsOverToTheCPU() throws {
        let a = audio(seconds: 12, silences: [6.0...7.2])
        let ref = try liveTake(runner(), a)
        let fake = FakeAccelerator()
        fake.marker = 1
        let r = runner()
        var failAt: Int?
        let got = try liveTake(r, a, acc: AcceleratorExecutor(fake), startAt: 3 * 16_000, each: { r in
            guard failAt == nil, let from = r.liveSwapFrom else { return }
            failAt = from + 3
            fake.failAt = from + 3
            fake.failure = .nan
        })
        XCTAssertEqual(got.ends.first?.outcome, .swapped)
        let f = try XCTUnwrap(r.failover)
        XCTAssertEqual(f.cause, .nonFinite)
        XCTAssertEqual(f.chunk, failAt)
        XCTAssertTrue(f.exact, "the whole take replayed on the CPU engine")
        XCTAssertFalse(r.onAccelerator)
        XCTAssertEqual(got.truncations, [0], "the failover's whole-take replay replaces the take, as for a take that started on the accelerator")
        XCTAssertEqual(got.frames, ref.frames)
        XCTAssertEqual(got.heads.logProbs, ref.heads.logProbs)
        XCTAssertEqual(got.tally?.secondsAfterSwap, LiveRules.tenths(samples: 3 * 5120), "the accelerator served until the failed chunk")
        XCTAssertEqual(r.liveTake?.state, .ended)
    }
}
