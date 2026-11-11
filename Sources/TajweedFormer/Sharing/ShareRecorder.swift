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
///   run on). The gap gets no audio of the take's.
/// - Otherwise the recording closes as a 2.0.2 session ends, and the take starts a new one. The window expiring, the
///   app going to the background, sharing going off, `capMs` of audio or `maxTakes` takes also close it.
/// - A recording keeps its takes `[{start_ms, gap_ms}]` (strictly increasing `start_ms`); one take sends none. A take
///   without audio adds no entry and does not move the previous take's end.
///
/// Tried and rejected: inserting silence for the gap (made-up audio in training data); holding the upload back until
/// the recording closes so the session JSON could list the takes (a long recording would wait to upload, and its
/// backlog would push the bitrate ladder down).
enum TakeJoin {
    static let defaultWindowMs = 3000
    static let maxWindowMs = 10_000
    /// A recording never holds more than 20 minutes of audio (SDK 3.0.0): when its audio reaches the cap inside a take
    /// it closes there as a whole recording, and the take goes on in a new one at the next sample.
    static let capMs: Int64 = 20 * 60 * 1000
    /// The take list call takes at most 256 entries: the 257th take starts a new recording.
    static let maxTakes = 256
    /// Within the last `holdMs` of room, a joining take's audio is held in memory (at most `holdMs` of it) until it
    /// ends (it joins) or outgrows the room, counted in samples (the recording closes without it and the take starts
    /// a new one with the held audio), so a short take near the cap is never split.
    /// Tried and rejected: holding every joining take (a crash would lose it, and its segments would wait).
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

    /// The samples of `capMs` at `rate`: the most a recording holds.
    static func capSamples(rate: Double) -> Int64 { capMs * Int64(rate.rounded()) / 1000 }

    /// A take of `take` samples (its pre-roll included) fits a recording of `recording` samples, both at `rate`:
    /// together they are at most the cap, in samples (SDK 3.0.0; 2.0.3 compared floored milliseconds, which let a
    /// held take exceed the cap by a few samples).
    static func fits(recording: Int64, take: Int64, rate: Double) -> Bool {
        recording + take <= capSamples(rate: rate)
    }
}

/// The audio an app feeds outside takes (`client.sharing.feed`, SDK 3.0.0; the rules F1 to F7 of the shared vector
/// `sharing_30.json`): the last second of it waits in a ring in memory and goes in front of the next take's audio (the
/// pre-roll), and up to half a second after a take goes to the recording (the tail). One constant per number.
enum ShareFeed {
    /// The ring holds the last second of fed audio, at the feed's rate. Fixed: it never grows.
    static let ringMs = 1000
    /// At most half a second of fed audio after a take's end goes to the recording.
    static let tailMs = 500
    /// A fed buffer continues the audio before it (the previous buffer, or the end of the take before it) when it
    /// arrives no later than its own duration plus this; the ring is a take's pre-roll when its last buffer is at most
    /// this old at the take's start.
    static let staleMs: Int64 = 500
    /// The tail wait: after every take, whether or not the app has fed before, the take's tail can take fed audio
    /// until this much wall time after the take's END. A buffer that arrives later never goes to the tail, however it
    /// continues the audio before it: it goes to the ring. A recording whose tail is not complete stays open that
    /// long, also when the join window is 0 or shorter; an app that never feeds sees a difference only where its
    /// window is shorter than this. Only audio the app feeds is recorded in that time: the SDK keeps no microphone
    /// open for a tail.
    static let tailWaitMs: Int64 = 1500

    static func ringSamples(rate: Double) -> Int { Int(rate.rounded()) * ringMs / 1000 }
    static func tailSamples(rate: Double) -> Int { Int(rate.rounded()) * tailMs / 1000 }

    /// Where the samples of one fed buffer went.
    struct Fed: Sendable, Hashable {
        var toTail = 0
        var toRing = 0
        var dropped = 0
    }
}

/// This install's count of shared recordings and the end of its last shared take (SDK 3.0.0: the session JSON's
/// `take_seq` and `gap_ms_prev`). Only "Delete what I shared" resets it.
struct ShareSequencer: Sendable {
    /// `gap_ms_prev` is left out above an hour.
    static let gapMaxMs: Int64 = 3_600_000

    /// A recording starts, with a take that started at `startMs` (wall ms); `continuation`: it continues a take whose
    /// recording closed at the cap. Returns its `take_seq` and `gap_ms_prev` (nil: absent).
    var next: @Sendable (_ startMs: Int64, _ continuation: Bool) -> (seq: Int, gapMsPrev: Int?)
    /// A shared take ended at `endMs` (wall ms).
    var takeEnded: @Sendable (_ endMs: Int64) -> Void

    /// No count is kept (a recorder without a store).
    static let none = ShareSequencer(next: { _, _ in (0, nil) }, takeEnded: { _ in })

    private struct Stored: Codable {
        var seq = 0
        var prev_end_ms: Int64?
    }

    /// `gap_ms_prev`: the wall ms from the end of the previous recording's last take to this recording's first take,
    /// rounded to the nearest 100 (half up); absent without a previous end, for a negative gap and above an hour.
    static func gap(previousEnd: Int64?, start: Int64) -> Int? {
        guard let previousEnd else { return nil }
        let d = start - previousEnd
        guard d >= 0, d <= gapMaxMs else { return nil }
        return Int(min((d + 50) / 100 * 100, gapMaxMs))
    }

    /// The count kept in `file` (the storage's `cloud/sharing-seq.json`), read where the storage is at each call.
    static func stored(_ file: @escaping @Sendable () -> URL) -> ShareSequencer {
        ShareSequencer(
            next: { (start: Int64, continuation: Bool) -> (seq: Int, gapMsPrev: Int?) in
                let f = JSONFile<Stored>(url: file())
                var s = f.read() ?? Stored()
                s.seq += 1
                f.write(s)
                // a continuation starts at the sample after the recording before it: no gap
                return (s.seq, continuation ? 0 : gap(previousEnd: s.prev_end_ms, start: start))
            },
            takeEnded: { (end: Int64) -> Void in
                let f = JSONFile<Stored>(url: file())
                var s = f.read() ?? Stored()
                s.prev_end_ms = end
                f.write(s)
            })
    }

    /// "Delete what I shared": the count starts again at 1, and the previous end is forgotten.
    static func reset(_ file: URL) { JSONFile<Stored>(url: file).delete() }

    static func file(storage: URL) -> URL { storage.appendingPathComponent("cloud/sharing-seq.json") }
}

/// What the recorder drives: one Ogg stream in one outbox folder (`ShareCapture`; tests pass their own).
protocol ShareRecording: AnyObject {
    /// Before the first audio: the recording's `take_seq` (0: none is kept) and `gap_ms_prev` (SDK 3.0.0).
    func begin(takeSeq: Int, gapMsPrev: Int?)
    /// Audio of the take that is running (its pre-roll and tail included), at its input rate.
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

extension ShareRecording {
    func begin(takeSeq: Int, gapMsPrev: Int?) {}
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
/// sharing going off calls `stop`; the app's own capture outside takes arrives at `feed` (SDK 3.0.0, `ShareFeed`).
/// Every decision reads the clock (the window is wall time); the timer only makes the window's end prompt, and the
/// clock decides whether it passed.
///
/// One per process (`Contributions.recorder`), behind a lock: the recognizer's actor, the timer's task, the app's
/// life, the app's feed and the settings switch arrive on different threads, and the capture (which is not thread
/// safe) is only ever touched under that lock. A take is known by the token `takeStarted` returns, so a recognizer
/// whose take was ended by another's start cannot write into the newer take.
///
/// A take's input rate is known with its first audio, so that is where a take that may join (decided when it started)
/// joins the open recording or, at another rate, closes it and starts its own, and where its pre-roll goes in.
///
/// What it holds in memory is bounded: the ring (`ShareFeed.ringMs` of audio), a take's pre-roll (the ring, once),
/// and a take held near the cap (`TakeJoin.holdMs` of audio and its pre-roll). Everything else is written as it
/// comes, and a recording closes at `TakeJoin.capMs` of audio whatever the take does.
final class ShareRecorder: Sendable {
    /// What a take brings to a recording that starts with it (the session JSON's decode fields).
    struct TakeInfo: Sendable {
        /// The model build the take runs (what a recording is bound to), and the model's version (SDK 3.0.0).
        var revision: String
        var version: String = ""
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
        /// Samples of fed audio the recording still takes after its last take (the tail).
        var tailLeft = 0
        var ms: Int64 { rate == 0 ? 0 : TakeJoin.ms(samples, rate: rate) }
    }

    /// Fed audio that waits: at most `ShareFeed.ringSamples` of it.
    private struct Ring {
        var rate: Double
        var samples: [Float] = []
        /// The wall time (ms) of the last buffer that went in.
        var wall: Int64 = 0
    }

    /// A joining take's audio held near the cap (`TakeJoin.holdMs`), its pre-roll first.
    private struct Hold {
        let gapMs: Int
        var pre: [Float] = []
        var chunks: [[Float]] = []
        var samples: Int64 = 0
    }

    private struct State {
        var open: Open?
        /// The running take's token.
        var take: Int?
        var info: TakeInfo?
        var takeSamples: Int64 = 0
        /// The wall time (ms) the running take started.
        var takeStart: Int64 = 0
        /// The running take's input rate (its first audio's).
        var takeRate: Double?
        /// The take's input rate changed: nothing more of it is recorded.
        var detached = false
        /// The running take's recording closed at the cap: its next sample opens a new recording.
        var atCap = false
        /// The running (or last) take was held near the cap.
        var wasHeld = false
        /// The gap of a take that may join the open recording, until its first audio (a take without audio joins nothing).
        var joinGap: Int?
        var hold: Hold?
        /// The wall time (ms) the last take with audio ended.
        var lastEnd: Int64 = 0
        /// The wall time (ms) of the audio before a fed buffer: the previous buffer, or the end of the last take.
        var lastAudio: Int64?
        var ring: Ring?
        /// The ring as it was when the running take started, until the take's first audio says its rate.
        var pre: Ring?
        /// The pre-roll samples of the running (or last) take.
        var preRoll = 0
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
    private let sequence: ShareSequencer

    init(clock: @escaping @Sendable () -> Date, window: @escaping @Sendable () -> Int, active: @escaping @Sendable () -> Bool,
         identity: @escaping @Sendable (TakeInfo) -> [String], open: @escaping @Sendable (TakeInfo) -> (any ShareRecording)?,
         sequence: ShareSequencer = .none) {
        self.clock = clock
        self.window = window
        self.active = active
        self.identity = identity
        self.open = open
        self.sequence = sequence
    }

    private func nowMs() -> Int64 { Int64((clock().timeIntervalSince1970 * 1000).rounded()) }

    /// The window's timer (tests pass one they run themselves).
    func setTimer(_ timer: JoinTimer) { state.withLock { $0.timer = timer } }

    /// The open recording (between takes too), or nil.
    var current: (any ShareRecording)? { state.withLock { $0.open?.recording } }

    /// The open recording's takes so far.
    var takes: [ShareTake] { state.withLock { $0.open?.takes ?? [] } }

    /// Samples in the ring now.
    var ringSamples: Int { state.withLock { $0.ring?.samples.count ?? 0 } }

    /// The pre-roll samples of the running (or last) take.
    var preRoll: Int { state.withLock { $0.preRoll } }

    /// Whether the running (or last) take was held near the cap.
    var wasHeld: Bool { state.withLock { $0.wasHeld } }

    /// Samples a held take keeps in memory now (its pre-roll included).
    var heldSamples: Int { state.withLock { Int($0.hold?.samples ?? 0) + ($0.hold?.pre.count ?? 0) } }

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
            let now = self.nowMs()
            s.tokens += 1
            let token = s.tokens
            s.take = token
            s.info = info
            s.takeSamples = 0
            s.takeStart = now
            s.takeRate = nil
            s.detached = false
            s.atCap = false
            s.wasHeld = false
            s.joinGap = nil
            s.hold = nil
            // the pre-roll: the ring, when the feed led into the take (its last buffer at most `staleMs` old); the
            // ring is empty afterwards either way
            s.pre = nil
            s.preRoll = 0
            if let r = s.ring, !r.samples.isEmpty, now - r.wall <= ShareFeed.staleMs, self.active() { s.pre = r }
            s.ring = nil
            if let o = s.open {
                self.disarm(&s)
                // the take's own audio follows: the tail before it is over
                s.open?.tailLeft = 0
                let w = self.window()
                let gap = now - s.lastEnd
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

    /// The first audio of a new recording: its input rate, and its place in this install's count of recordings.
    private func begin(_ s: inout State, rate: Double, continuation: Bool = false) {
        s.open?.rate = rate
        let n = sequence.next(s.takeStart, continuation)
        s.open?.recording.begin(takeSeq: n.seq, gapMsPrev: n.gapMsPrev)
    }

    /// A take's audio into its recording. The moment the recording holds `TakeJoin.capMs` of audio it closes as a
    /// whole recording (it ended at the cap, not by a failure), and the take's next sample, when one comes, opens a
    /// new recording that continues it.
    private func write(_ s: inout State, _ samples: [Float], rate: Double, info: TakeInfo?) throws(RecognizerError) {
        var at = 0
        while at < samples.count {
            if s.open == nil {
                guard s.atCap, let info, start(&s, info) else { return }
                s.atCap = false
                begin(&s, rate: rate, continuation: true)
            }
            guard let o = s.open else { return }
            let cap = TakeJoin.capSamples(rate: rate)
            let k = Int(min(Int64(samples.count - at), max(0, cap - o.samples)))
            if k > 0 {
                try o.recording.append(k == samples.count ? samples : Array(samples[at..<(at + k)]), rate: rate)
                s.open?.samples += Int64(k)
                at += k
            }
            if o.samples + Int64(k) >= cap {
                s.open?.completed = true
                close(&s, keep: true)
                s.atCap = info != nil
            }
        }
    }

    /// Audio of the take `token`; nothing outside it.
    func audio(_ token: Int, _ samples: [Float], rate: Double) throws(RecognizerError) {
        guard !samples.isEmpty else { return }
        try state.withLock { (s: inout State) throws(RecognizerError) -> Void in
            guard s.take == token, !s.detached, let info = s.info, s.open != nil || s.atCap else { return }
            if let r = s.takeRate, r != rate {
                // one input rate per take: a change ends the shared recording there (as before 2.0.3), not completed
                // when this take has audio in it
                s.detached = true
                s.atCap = false
                s.joinGap = nil
                if s.takeSamples > 0, s.hold == nil { s.open?.completed = false }
                s.hold = nil
                self.close(&s, keep: true)
                return
            }
            // the take's first audio: its rate is known, and with it whether the ring is its pre-roll
            var lead: [Float] = []
            if s.takeRate == nil {
                if let p = s.pre, p.rate == rate { lead = p.samples }
                s.pre = nil
                s.preRoll = lead.count
            }
            s.takeRate = rate
            if let gap = s.joinGap {
                s.joinGap = nil
                let recorded = s.open?.rate ?? 0
                let ms = s.open?.ms ?? 0
                if recorded != rate {
                    // another input rate: the open recording closes, and the take starts its own
                    self.close(&s, keep: true)
                    guard self.start(&s, info) else { return }
                } else if TakeJoin.capMs - ms <= TakeJoin.holdMs {
                    s.hold = Hold(gapMs: gap, pre: lead)
                    s.wasHeld = true
                    lead = []
                } else {
                    // the stream goes on: [pre-roll][take], the take's boundary after its pre-roll
                    if !lead.isEmpty {
                        try self.write(&s, lead, rate: rate, info: info)
                        lead = []
                    }
                    self.boundary(&s, gap)
                }
            }
            if s.open?.rate == 0 {
                // the first audio of a new recording: the take starts after its pre-roll
                self.begin(&s, rate: rate)
                if !lead.isEmpty {
                    s.open?.takes = [ShareTake(start_ms: Int(TakeJoin.ms(Int64(lead.count), rate: rate)), gap_ms: 0)]
                    try self.write(&s, lead, rate: rate, info: info)
                }
            }
            let n = Int64(samples.count)
            if s.hold != nil {
                s.hold?.chunks.append(samples)
                s.hold?.samples += n
                s.takeSamples += n
                let held = (s.hold?.samples ?? 0) + Int64(s.hold?.pre.count ?? 0)
                let fits = TakeJoin.fits(recording: s.open?.samples ?? 0, take: held, rate: rate)
                if !fits { try self.overflow(&s, info) }
                return
            }
            s.takeSamples += n
            try self.write(&s, samples, rate: rate, info: info)
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
        guard start(&s, info) else { return }
        begin(&s, rate: rate)
        if !h.pre.isEmpty {
            s.open?.takes = [ShareTake(start_ms: Int(TakeJoin.ms(Int64(h.pre.count), rate: rate)), gap_ms: 0)]
            try write(&s, h.pre, rate: rate, info: info)
        }
        for c in h.chunks { try write(&s, c, rate: rate, info: info) }
    }

    /// The take `token` ended: its recording waits for the next take within the window, or closes now.
    func takeEnded(_ token: Int, completed: Bool) {
        state.withLock { (s: inout State) -> Void in
            guard s.take == token else { return }
            self.end(&s, completed: completed)
        }
    }

    private func end(_ s: inout State, completed: Bool) {
        let info = s.info
        s.take = nil
        s.info = nil
        s.joinGap = nil
        s.detached = false
        s.pre = nil
        let now = nowMs()
        if s.open == nil { s.hold = nil }
        if let h = s.hold, let rate = s.open?.rate {
            // the held take ended within the room: it joins, its boundary after its pre-roll. A failure leaves the
            // recording as it is on disk; the capture is then not alive and closes below
            s.hold = nil
            if h.pre.isEmpty || (try? write(&s, h.pre, rate: rate, info: info)) != nil {
                boundary(&s, h.gapMs)
                for c in h.chunks {
                    guard (try? write(&s, c, rate: rate, info: info)) != nil else { break }
                }
            }
        }
        s.atCap = false
        if s.takeSamples > 0 {
            // a shared take ended here, whatever became of its recording (it may have closed at the cap)
            s.open?.completed = completed
            s.lastEnd = now
            s.lastAudio = now
            if active() { sequence.takeEnded(now) }
            // the tail: what the app feeds right after the take, as far as the recording has room
            if let o = s.open, o.rate > 0 {
                let room = max(0, TakeJoin.capSamples(rate: o.rate) - o.samples)
                s.open?.tailLeft = Int(min(Int64(ShareFeed.tailSamples(rate: o.rate)), room))
            }
        }
        guard let o = s.open else { return }
        if o.samples == 0 || s.backgrounded || !active() || !o.recording.isAlive {
            close(&s, keep: true)
            return
        }
        settle(&s, now, byTimer: false)
    }

    /// A recording that waits (no take runs) closes once no take can join it any more and its tail can take nothing
    /// more; until then the timer is set for that moment.
    private func settle(_ s: inout State, _ now: Int64, byTimer: Bool) {
        guard s.take == nil, let o = s.open else { return }
        var until: Int64?
        let w = Int64(window())
        if w > 0, o.ms < TakeJoin.capMs, o.takes.count < TakeJoin.maxTakes { until = s.lastEnd + w }
        // the tail waits from the take's end, not from the last fed buffer
        if o.tailLeft > 0 { until = max(until ?? s.lastEnd, s.lastEnd + ShareFeed.tailWaitMs) }
        // a clock set back while the recording waited: the timer ran its time, so the recording closes rather than
        // waiting for a moment that may never come
        guard let until, now <= until, !(byTimer && now < s.lastEnd) else {
            close(&s, keep: true)
            return
        }
        arm(&s, until - now)
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
        settle(&s, nowMs(), byTimer: true)
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

    /// The app went to the background: a waiting recording closes now, a running take's when it ends; the ring is
    /// emptied.
    func background() {
        state.withLock { (s: inout State) -> Void in
            s.backgrounded = true
            s.ring = nil
            if s.take == nil, s.open != nil { self.close(&s, keep: true) }
        }
    }

    func foreground() { state.withLock { $0.backgrounded = false } }

    /// Audio the app captures outside takes (`client.sharing.feed`): where its samples went. Nothing is kept without
    /// sharing on and the learner's yes, or during a take.
    @discardableResult
    func feed(_ samples: [Float], rate: Double) -> ShareFeed.Fed {
        let n = samples.count
        guard n > 0, rate >= 1 else { return ShareFeed.Fed() }
        guard active() else {
            state.withLock { $0.ring = nil }
            return ShareFeed.Fed(dropped: n)
        }
        return state.withLock { (s: inout State) -> ShareFeed.Fed in
            // a take runs: its own audio is the stream
            if s.take != nil { return ShareFeed.Fed(dropped: n) }
            let now = self.nowMs()
            // the buffer continues the audio before it, or the feed paused: then nothing older is glued to it
            let continues = s.lastAudio.map { now - $0 <= TakeJoin.ms(Int64(n), rate: rate) + ShareFeed.staleMs } ?? false
            let tailBefore = s.open?.tailLeft ?? 0
            if !continues {
                s.ring = nil
                s.open?.tailLeft = 0
            }
            // the tail wait is over: this buffer goes to the ring, however it continues
            if let o = s.open, o.tailLeft > 0, now - s.lastEnd > ShareFeed.tailWaitMs { s.open?.tailLeft = 0 }
            var toTail = 0
            if let o = s.open, o.tailLeft > 0 {
                if o.rate == rate, o.recording.isAlive {
                    let k = min(n, o.tailLeft)
                    if (try? o.recording.append(k == n ? samples : Array(samples[0..<k]), rate: rate)) != nil {
                        toTail = k
                        s.open?.samples += Int64(k)
                        s.open?.tailLeft -= k
                    } else {
                        s.open?.tailLeft = 0
                    }
                } else {
                    // another rate than the recording's: the tail ends
                    s.open?.tailLeft = 0
                }
                // the tail is cut at the cap, and the recording closes there
                if let o = s.open, o.rate > 0, o.samples >= TakeJoin.capSamples(rate: o.rate) { self.close(&s, keep: true) }
            }
            let rest = n - toTail
            if rest > 0 {
                let cap = ShareFeed.ringSamples(rate: rate)
                var ring = s.ring.flatMap { $0.rate == rate ? $0 : nil } ?? Ring(rate: rate)
                if rest >= cap {
                    ring.samples = Array(samples[(n - cap)...])
                } else {
                    ring.samples.append(contentsOf: samples[toTail...])
                    if ring.samples.count > cap { ring.samples.removeFirst(ring.samples.count - cap) }
                }
                ring.wall = now
                s.ring = ring
            }
            s.lastAudio = now
            // the tail is complete, the feed paused or the tail wait is over: a recording that no take can join any
            // more closes; while the tail fills, the recording stays open until the tail wait is over
            if s.open != nil, tailBefore > 0 { self.settle(&s, now, byTimer: false) }
            return ShareFeed.Fed(toTail: toTail, toRing: rest)
        }
    }

    /// Sharing went off (withdrawal, deletion): the recording ends at once, whatever the take does, and nothing fed
    /// stays in memory.
    func stop() {
        state.withLock { (s: inout State) -> Void in
            s.hold = nil
            s.joinGap = nil
            s.ring = nil
            s.pre = nil
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
            s.ring = nil
            s.pre = nil
            s.lastAudio = nil
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
