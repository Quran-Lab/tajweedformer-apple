import Foundation

/// One take boundary of a recording (SDK 2.0.3): where the take's first sample is in the stream, and the wall gap
/// before it. The property names are the wire's (`POST /v1/uploads/{id}/takes`).
struct ShareTake: Codable, Sendable, Hashable {
    /// floor(1000 x input samples of the recording before the take / input rate).
    var start_ms: Int
    /// The wall time from the previous take's end to this take's start, rounded to the nearest 100 ms (0 for the first).
    var gap_ms: Int
}

/// Back-to-back takes share one sharing recording (SDK 2.0.3), the same in every SDK and replayed against the shared
/// vector `takes_join.json`:
///
/// - When a take ends while sharing is on, its recording stays open for the JOIN WINDOW (the signed config's
///   `flags.share_join_ms`, a whole number 0 to 10000; absent or anything else 3000; 0 never joins).
/// - The next take joins it when it starts within the window (its start minus the end of the previous take that had
///   audio, wall ms, at most the window) with the same input sample rate, while the app is in the foreground, sharing
///   is still on, and the contributor, the consent version and the model revision are the recording's: its audio
///   continues the same Ogg stream (no new headers; the encoder and the resampler keep their state, so a partial Opus
///   frame left by one take is completed by the next take's first samples; the segment plan and the bitrate ladder
///   run on). The gap gets no audio.
/// - Otherwise the recording closes as a 2.0.2 session ends, and the take starts a new one. The window expiring, the
///   app going to the background, sharing going off, `capMs` of audio or `maxTakes` takes also close it at once.
/// - A recording keeps its takes `[{start_ms, gap_ms}]` (the first `{0, 0}`, strictly increasing `start_ms`); one take
///   sends none. A take without audio adds no entry and does not move the previous take's end.
///
/// Tried and rejected: inserting silence for the gap (made-up audio in training data); holding the upload back until
/// the recording closes so the session JSON could list the takes (a long recording would wait to upload, and its
/// backlog would push the bitrate ladder down).
enum TakeJoin {
    static let defaultWindowMs = 3000
    static let maxWindowMs = 10_000
    /// A recording holds at most 20 minutes of audio: a take that would take it further starts a new one.
    static let capMs: Int64 = 20 * 60 * 1000
    /// The take list call takes at most 256 entries: the 257th take starts a new recording.
    static let maxTakes = 256
    /// Whether a take fits under `capMs` is known only once it ended. Within the last `holdMs` of room, a joining
    /// take's audio is held in memory (at most `holdMs` of it) until it ends (it joins) or outgrows the room (the
    /// recording closes without it and the take starts a new one with the held audio), so the cap is exact there. A
    /// take that joins with more room and runs past `capMs` stays whole and the recording closes when it ends.
    /// Tried and rejected: holding every joining take (a crash would lose it, and its segments would wait); cutting
    /// the recording at the cap inside a take (it would split speech, what 2.0.3 removes).
    static let holdMs: Int64 = 30_000

    /// `flags.share_join_ms`: a whole number 0 to 10000, else `defaultWindowMs` (a boolean, a string, a fraction, a
    /// negative or larger number).
    static func window(_ v: JSONValue?) -> Int {
        guard case .number(let d)? = v, d == d.rounded(), d >= 0, d <= Double(maxWindowMs) else { return defaultWindowMs }
        return Int(d)
    }

    /// The wall gap rounded to the nearest 100 ms (half up), within 0 to `maxWindowMs` (a clock set back gives 0).
    static func gapMs(_ gap: Int64) -> Int {
        Int((min(max(gap, 0), Int64(maxWindowMs)) + 50) / 100 * 100)
    }

    /// Milliseconds of `samples` at `rate`, floored.
    static func ms(_ samples: Int64, rate: Double) -> Int64 {
        let r = Int64(rate.rounded())
        return r > 0 ? samples * 1000 / r : 0
    }

    /// A take of `take` samples fits a recording of `recording` samples (both at `rate`).
    static func fits(recording: Int64, take: Int64, rate: Double) -> Bool {
        ms(recording, rate: rate) + ms(take, rate: rate) <= capMs
    }
}

/// What the recorder drives: one Ogg stream in one outbox folder (`ShareCapture`; tests pass their own).
protocol ShareRecording: AnyObject {
    /// Audio of the take that is running, at its input rate.
    func append(_ mono: [Float], rate: Double) throws(RecognizerError)
    /// The recording's takes so far (2 or more), written where recovery and the outbox read them.
    func takes(_ list: [ShareTake])
    /// Ends the stream: `completed` is the last take's.
    func finish(completed: Bool)
    /// Sharing went off: ends the recording and keeps nothing of it that is not uploaded yet.
    func discard()
    /// False once the recording failed or ended by itself (a storage error, sharing off): no take joins it.
    var isAlive: Bool { get }
}

/// Runs a task after a delay (wall ms); the function it returns cancels it. The window's timer; tests pass their own.
struct JoinTimer: Sendable {
    typealias Cancel = @Sendable () -> Void

    let schedule: @Sendable (Int64, @escaping @Sendable () -> Void) -> Cancel

    /// A detached task of the process.
    static let live = JoinTimer { delayMs, task in
        let t = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(max(0, delayMs)) * 1_000_000)
            guard !Task.isCancelled else { return }
            task()
        }
        return { t.cancel() }
    }
}

/// Keeps the sharing recording across takes (SDK 2.0.3): the model session (the take) stays as the app drives it, and the
/// recording, its Ogg stream, outbox item and session id, lives across back-to-back takes by the rules of `TakeJoin`.
/// The recognizer calls `takeStarted`, `audio` and `takeEnded`; the app's life calls `background` and `foreground`;
/// sharing going off calls `stop`. Every decision reads the clock (the window is wall time); the timer only makes the
/// window's end prompt, and the clock decides whether it passed.
///
/// One per process (`Contributions.recorder`), behind a lock: the recognizer's actor, the timer's task, the app's
/// life and the settings switch arrive on different threads, and the capture (which is not thread safe) is only ever
/// touched under that lock. A take is known by the token `takeStarted` returns, so a recognizer whose take was ended
/// by another's start cannot write into the newer take.
///
/// A take's input rate is known with its first audio, so that is where a take that may join (decided when it started)
/// joins the open recording or, at another rate, closes it and starts its own.
final class ShareRecorder: Sendable {
    /// What a take brings to a recording that starts with it (the session JSON's decode fields).
    struct TakeInfo: Sendable {
        var revision: String
        var backend: ActiveBackend
        var weightsSHA256: String?
    }

    private struct Open {
        let recording: any ShareRecording
        /// What the recording is bound to (the storage, the contributor, the consent version and hash, the revision).
        let identity: [String]
        /// The input rate (the first audio's); 0 before it.
        var rate: Double = 0
        var samples: Int64 = 0
        var takes = [ShareTake(start_ms: 0, gap_ms: 0)]
        /// The last take with audio completed.
        var completed = false
        var ms: Int64 { rate == 0 ? 0 : TakeJoin.ms(samples, rate: rate) }
    }

    /// A joining take's audio held near the cap (`TakeJoin.holdMs`).
    private struct Hold {
        let gapMs: Int
        var chunks: [[Float]] = []
        var samples: Int64 = 0
    }

    private struct State {
        var open: Open?
        /// The running take's token.
        var take: Int?
        var info: TakeInfo?
        var takeSamples: Int64 = 0
        /// The running take's input rate (its first audio's).
        var takeRate: Double?
        /// The take's input rate changed: nothing more of it is recorded.
        var detached = false
        /// The gap of a take that may join the open recording, until its first audio (a take without audio joins nothing).
        var joinGap: Int?
        var hold: Hold?
        /// The wall time (ms) the last take with audio ended.
        var lastEnd: Int64 = 0
        var backgrounded = false
        var cancelTimer: JoinTimer.Cancel?
        var armed = 0
        var tokens = 0
        var timer = JoinTimer.live
    }

    private let state = Locked(State())
    private let clock: @Sendable () -> Date
    /// The join window in force, ms (0: never join).
    private let window: @Sendable () -> Int
    /// Sharing is on now (the learner's consent, the signed config).
    private let active: @Sendable () -> Bool
    private let identity: @Sendable (TakeInfo) -> [String]
    /// A new recording for a take, or nil when none can be made (sharing off).
    private let open: @Sendable (TakeInfo) -> (any ShareRecording)?

    init(clock: @escaping @Sendable () -> Date, window: @escaping @Sendable () -> Int, active: @escaping @Sendable () -> Bool,
         identity: @escaping @Sendable (TakeInfo) -> [String], open: @escaping @Sendable (TakeInfo) -> (any ShareRecording)?) {
        self.clock = clock
        self.window = window
        self.active = active
        self.identity = identity
        self.open = open
    }

    private func nowMs() -> Int64 { Int64((clock().timeIntervalSince1970 * 1000).rounded()) }

    /// The window's timer (tests pass one they run themselves).
    func setTimer(_ timer: JoinTimer) { state.withLock { $0.timer = timer } }

    /// The open recording (between takes too), or nil.
    var current: (any ShareRecording)? { state.withLock { $0.open?.recording } }

    /// The open recording's takes so far.
    var takes: [ShareTake] { state.withLock { $0.open?.takes ?? [] } }

    /// A take starts: it may join the open recording (decided here, done at its first audio) or starts a new one.
    /// Returns the take's token, for `audio` and `takeEnded`.
    @discardableResult
    func takeStarted(_ info: TakeInfo) -> Int {
        state.withLock { (s: inout State) -> Int in
            // a take that never ended: as in 2.0.2 its recording ends there, not completed. When that take really ended
            // is not known, so this one does not join it.
            if s.take != nil {
                self.end(&s, completed: false)
                self.close(&s, keep: true)
            }
            s.tokens += 1
            let token = s.tokens
            s.take = token
            s.info = info
            s.takeSamples = 0
            s.takeRate = nil
            s.detached = false
            s.joinGap = nil
            s.hold = nil
            if let o = s.open {
                self.disarm(&s)
                let w = self.window()
                let gap = self.nowMs() - s.lastEnd
                if w > 0, gap <= Int64(w), !s.backgrounded, self.active(), o.recording.isAlive, o.ms < TakeJoin.capMs,
                   o.takes.count < TakeJoin.maxTakes, o.identity == self.identity(info) {
                    s.joinGap = TakeJoin.gapMs(gap)
                    return token
                }
                self.close(&s, keep: true)
            }
            self.start(&s, info)
            return token
        }
    }

    /// A new recording for the running take, or none.
    @discardableResult
    private func start(_ s: inout State, _ info: TakeInfo) -> Bool {
        s.open = nil
        guard active(), let r = open(info) else { return false }
        s.open = Open(recording: r, identity: identity(info))
        return true
    }

    /// Audio of the take `token`; nothing outside it.
    func audio(_ token: Int, _ samples: [Float], rate: Double) throws(RecognizerError) {
        guard !samples.isEmpty else { return }
        try state.withLock { (s: inout State) throws(RecognizerError) -> Void in
            guard s.take == token, !s.detached, let info = s.info, s.open != nil else { return }
            if let r = s.takeRate, r != rate {
                // one input rate per take: a change ends the shared recording there (as before 2.0.3), not completed
                // when this take has audio in it
                s.detached = true
                s.joinGap = nil
                if s.takeSamples > 0, s.hold == nil { s.open?.completed = false }
                s.hold = nil
                self.close(&s, keep: true)
                return
            }
            s.takeRate = rate
            if let gap = s.joinGap {
                // the first audio of a take that may join: its rate is known now
                s.joinGap = nil
                let recorded = s.open?.rate ?? 0
                let ms = s.open?.ms ?? 0
                if recorded != rate {
                    // another input rate: the open recording closes, and the take starts its own
                    self.close(&s, keep: true)
                    guard self.start(&s, info) else { return }
                } else if TakeJoin.capMs - ms <= TakeJoin.holdMs {
                    s.hold = Hold(gapMs: gap)
                } else {
                    self.boundary(&s, gap)
                }
            }
            if s.open?.rate == 0 { s.open?.rate = rate }
            let n = Int64(samples.count)
            if s.hold != nil {
                s.hold?.chunks.append(samples)
                s.hold?.samples += n
                s.takeSamples += n
                let fits = TakeJoin.fits(recording: s.open?.samples ?? 0, take: s.hold?.samples ?? 0, rate: rate)
                if !fits { try self.overflow(&s, info) }
                return
            }
            guard let recording = s.open?.recording else { return }
            try recording.append(samples, rate: rate)
            s.open?.samples += n
            s.takeSamples += n
        }
    }

    /// A take joins at the recording's current position: its boundary, when it lies after the last one.
    private func boundary(_ s: inout State, _ gapMs: Int) {
        guard let o = s.open else { return }
        let at = Int(o.ms)
        guard at > (o.takes.last?.start_ms ?? 0) else { return }
        let list = o.takes + [ShareTake(start_ms: at, gap_ms: gapMs)]
        s.open?.takes = list
        o.recording.takes(list)
    }

    /// The held take outgrew the room: the recording closes without it, and the take starts a new one.
    private func overflow(_ s: inout State, _ info: TakeInfo) throws(RecognizerError) {
        guard let h = s.hold, let rate = s.open?.rate else { return }
        s.hold = nil
        close(&s, keep: true)
        guard start(&s, info), let recording = s.open?.recording else { return }
        s.open?.rate = rate
        for c in h.chunks {
            try recording.append(c, rate: rate)
            s.open?.samples += Int64(c.count)
        }
    }

    /// The take `token` ended: its recording waits for the next take within the window, or closes now.
    func takeEnded(_ token: Int, completed: Bool) {
        state.withLock { (s: inout State) -> Void in
            guard s.take == token else { return }
            self.end(&s, completed: completed)
        }
    }

    private func end(_ s: inout State, completed: Bool) {
        s.take = nil
        s.info = nil
        s.joinGap = nil
        s.detached = false
        guard s.open != nil else {
            s.hold = nil
            return
        }
        if let h = s.hold, let recording = s.open?.recording, let rate = s.open?.rate {
            // the held take ended within the room: it joins
            s.hold = nil
            boundary(&s, h.gapMs)
            for c in h.chunks {
                // a failure leaves the recording as it is on disk; the capture is then not alive and closes below
                guard (try? recording.append(c, rate: rate)) != nil else { break }
                s.open?.samples += Int64(c.count)
            }
        }
        let now = nowMs()
        if s.takeSamples > 0 {
            s.open?.completed = completed
            s.lastEnd = now
        }
        let w = window()
        guard let o = s.open else { return }
        if o.samples == 0 || w <= 0 || s.backgrounded || !active() || !o.recording.isAlive || o.ms >= TakeJoin.capMs
            || o.takes.count >= TakeJoin.maxTakes || now - s.lastEnd > Int64(w) {
            close(&s, keep: true)
            return
        }
        arm(&s, Int64(w) - (now - s.lastEnd))
    }

    /// The window's end: closes the waiting recording once the clock says the window passed (tests call it too).
    func checkWindow() {
        state.withLock { (s: inout State) -> Void in
            let gen = s.armed
            self.expired(&s, gen)
        }
    }

    private func expire(_ gen: Int) {
        state.withLock { (s: inout State) -> Void in self.expired(&s, gen) }
    }

    private func expired(_ s: inout State, _ gen: Int) {
        guard gen == s.armed, s.take == nil, s.open != nil else { return }
        let w = window()
        let waited = nowMs() - s.lastEnd
        // a clock set back while the recording waited: the timer ran its time, so the recording closes rather than
        // waiting for a moment that may never come
        if w <= 0 || waited > Int64(w) || waited < 0 { close(&s, keep: true) } else { arm(&s, Int64(w) - waited) }
    }

    private func arm(_ s: inout State, _ remainingMs: Int64) {
        disarm(&s)
        s.armed += 1
        let gen = s.armed
        s.cancelTimer = s.timer.schedule(max(0, remainingMs) + 1) { [weak self] in self?.expire(gen) }
    }

    private func disarm(_ s: inout State) {
        s.cancelTimer?()
        s.cancelTimer = nil
        s.armed += 1
    }

    /// The app went to the background: a waiting recording closes now, a running take's when it ends.
    func background() {
        state.withLock { (s: inout State) -> Void in
            s.backgrounded = true
            if s.take == nil, s.open != nil { self.close(&s, keep: true) }
        }
    }

    func foreground() { state.withLock { $0.backgrounded = false } }

    /// Sharing went off (withdrawal, deletion): the recording ends at once, whatever the take does.
    func stop() {
        state.withLock { (s: inout State) -> Void in
            s.hold = nil
            s.joinGap = nil
            if s.open != nil { self.close(&s, keep: false) }
        }
    }

    /// The SDK is configured again (another storage, another client): the open recording ends as a recording ends,
    /// and the take that runs, if any, records nothing more.
    func reset() {
        state.withLock { (s: inout State) -> Void in
            s.hold = nil
            s.joinGap = nil
            s.take = nil
            s.info = nil
            s.backgrounded = false
            if s.open != nil { self.close(&s, keep: true) }
        }
    }

    private func close(_ s: inout State, keep: Bool) {
        disarm(&s)
        guard let o = s.open else { return }
        s.open = nil
        // nothing keeps a closed recording (nor, through it, its outbox) alive here
        if keep { o.recording.finish(completed: o.completed) } else { o.recording.discard() }
    }
}
