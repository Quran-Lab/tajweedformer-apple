import Foundation

/// SDK 4.0: when the SDK asks a learner to share, a direct port of the
/// reference `tools/share_ask.py`: the signed config's `share_ask` (20.3, `Config.resolve`), the stored state as the
/// decision reads it (20.4, `normalize`) and the decision (20.5, `decide`). Pure: the stored state, this app
/// session's part, the event, the config as it came and the clock in; the action, why and the new state out. The
/// SDK stores the new state and acts on the action (`Contributions.shareAsk`); `vectors/share_ask.json` pins it.
///
/// Quran Lab's permanent rules, which no config changes: at most three asks per install, ever; a yes is never asked
/// again; a learner who turned sharing off is not asked again; the count survives launches and SDK upgrades; a
/// developer can never switch the ask off (the config can only make asking rarer).
///
/// Tried and rejected (20.9): counting a dismissed card as nothing (the "gentle" card would be unlimited); time alone
/// or sessions alone between asks (both must pass); a monotonic clock (it restarts at every reboot: the wall clock
/// with the re-anchor rule of `normalize` instead).
enum ShareAsk {
    static let minuteMs: Int64 = 60_000
    static let hourMs: Int64 = 3_600_000
    static let dayMs: Int64 = 86_400_000
    /// Quran Lab's permanent rule: three asks per install, ever. No config raises it.
    static let hardMaxAsks = 3
    /// 20.6 `SHARE_ASK_SETTLE_MS`: an ask decided at the end of a take goes on screen after this long with no new take.
    static let settleMs = 3000
    /// 20.2: the app back in the foreground after this long in the background is a new app session.
    static let appSessionGap: TimeInterval = 30 * 60

    // MARK: 20.3 the signed config

    /// `share_ask` of the signed config as the SDK applies it. The defaults are Quran Lab's direction (11-15); the
    /// bounds only ever make asking rarer.
    struct Config: Sendable, Equatable {
        var firstMinSessions = 3
        var firstMinHours = 24
        var reaskDays = [14, 30]
        var reaskSessions = [7, 10]
        var goodSessionMinS = 60
        var maxAsks = 3

        static let firstMinSessionsBounds = (3, 30)
        static let firstMinHoursBounds = (24, 720)
        static let reaskDaysBounds = [(14, 180), (30, 365)]
        static let reaskSessionsBounds = [(7, 100), (10, 100)]
        static let goodSessionMinSBounds = (60, 600)
        static let maxAsksBounds = (1, ShareAsk.hardMaxAsks)

        /// `resolve_config`: field by field, a JSON number with an integral value (21 and 21.0 alike) is clamped into
        /// its bounds; anything else (absent, null, a boolean, a string, a fraction) is that field's default.
        /// `reask_days` and `reask_sessions` must be lists of exactly two entries, each read like a single field
        /// against its own bounds; another length or type gives the default pair. Unknown keys are ignored. Not an
        /// object (or absent): every default.
        static func resolve(_ raw: JSONValue?) -> Config {
            var c = Config()
            guard case .object(let o)? = raw else { return c }
            if let n = integral(o["first_min_sessions"]) { c.firstMinSessions = clamp(n, firstMinSessionsBounds) }
            if let n = integral(o["first_min_hours"]) { c.firstMinHours = clamp(n, firstMinHoursBounds) }
            if let n = integral(o["good_session_min_s"]) { c.goodSessionMinS = clamp(n, goodSessionMinSBounds) }
            if let n = integral(o["max_asks"]) { c.maxAsks = clamp(n, maxAsksBounds) }
            if case .array(let pair)? = o["reask_days"], pair.count == 2 {
                for i in 0..<2 {
                    if let n = integral(pair[i]) { c.reaskDays[i] = clamp(n, reaskDaysBounds[i]) }
                }
            }
            if case .array(let pair)? = o["reask_sessions"], pair.count == 2 {
                for i in 0..<2 {
                    if let n = integral(pair[i]) { c.reaskSessions[i] = clamp(n, reaskSessionsBounds[i]) }
                }
            }
            return c
        }

        /// `_int`: a JSON number with an integral value, else nil. Decoded as a number and tested for an integral
        /// value, never as an integer type (some decoders refuse 21.0 as an integer, others round 14.5).
        static func integral(_ v: JSONValue?) -> Double? {
            guard case .number(let d)? = v, d.isFinite, d == d.rounded(.down) else { return nil }
            return d
        }

        /// Clamped while still a Double, so that a huge number never traps on the way to an Int.
        static func clamp(_ v: Double, _ bounds: (Int, Int)) -> Int {
            if v < Double(bounds.0) { return bounds.0 }
            if v > Double(bounds.1) { return bounds.1 }
            return Int(v)
        }
    }

    // MARK: 20.4 and 20.5 the words of the decision

    /// The wall clock with the device's UTC offset at that moment (20.10 item 2).
    struct Now: Sendable, Equatable {
        /// Unix milliseconds.
        var ms: Int64
        /// Minutes east of UTC.
        var tzMin: Int

        init(ms: Int64, tzMin: Int = 0) {
            self.ms = ms
            self.tzMin = tzMin
        }

        init(date: Date, timeZone: TimeZone) {
            ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
            tzMin = timeZone.secondsFromGMT(for: date) / 60
        }

        /// Now, on the configured Client's clock (the system's when there is none), in the device's time zone.
        static func current() -> Now {
            Now(date: QuranLab.cloud?.clock() ?? Date(), timeZone: .current)
        }
    }

    enum Kind: String, Sendable {
        case sheet, card

        var action: Action { self == .sheet ? .sheet : .card }
    }

    /// The ask in hand: pending until it is on screen.
    struct Ask: Sendable, Equatable {
        var kind: Kind
        /// 1 to 3: the ask it would be when it goes on screen.
        var number: Int
        var shown: Bool
    }

    /// This app session's part (20.4), never stored: its completed takes, their speech, whether an ask went on screen
    /// in it, whether a take is open, and the ask in hand.
    struct App: Sendable, Equatable {
        var takes = 0
        var recitedMs = 0
        var asked = false
        var takeOpen = false
        var ask: Ask?
    }

    /// How a take ended (20.2 `end`).
    enum End: String, Sendable {
        /// The app finished it, or it ended by itself on silence, its limit or the end of its source.
        case normal
        /// The app left the foreground, or an interruption that cannot resume.
        case interrupted
        case error
        case cancelled
    }

    enum Answer: String, Sendable {
        case yes
        case notNow = "not_now"
        /// "See how it helps" on a card: the full sheet for the same ask.
        case open
    }

    enum Event: Sendable, Equatable {
        /// A new app session: its part is reset. Never an ask.
        case launch
        case takeStart
        /// `end` nil: an end this port does not know (not a completed session).
        case takeEnd(end: End?, speechMs: Int, offered: Bool)
        /// The app's `ask()`.
        case askNow(offered: Bool)
        /// The ask in hand goes on screen now.
        case shown
        /// nil: an answer this port does not know.
        case answer(Answer?)
        case withdrawn
        /// The learner's settings switch.
        case setting(on: Bool)
        /// An event this port does not know (the vectors' `tick`): only the reading rules apply.
        case unknown
    }

    enum Action: String, Sendable {
        case none, sheet, card
    }

    struct Outcome: Sendable, Equatable {
        var action: Action
        /// The first rule that held an ask back, or why the event was ignored; nil otherwise.
        var why: String?
        var state: SharingState
        var app: App
    }

    // MARK: 20.4 the state as the decision reads it

    /// `local_day`: the device's calendar day, whole days since 1970-01-01 in its time zone at `now` (floored).
    static func localDay(_ now: Now) -> Int {
        let x = now.ms + Int64(now.tzMin) * minuteMs
        let q = x / dayMs
        return Int(x % dayMs < 0 ? q - 1 : q)
    }

    /// `normalize`: a field missing (a state of SDK 3.x or earlier) gets its value: `installedAt` now (for an install
    /// from before 4.0, the upgrade: nobody is asked in the 24 hours after it); with an ask already shown,
    /// `lastAskAt` now and `lastAskDay` today (3.x stored no time of the last ask, and its `decidedAt` is the
    /// answer's time). A declined state without an ask count was asked once (2.0.0). The clock rule: a stored time
    /// later than now (the clock was set back, or was ahead when it was stored) becomes now, with its day, so an
    /// interval is never negative and a clock that goes back only restarts one. Every other field passes through.
    static func normalize(_ s: inout SharingState, now: Now) {
        s.asks = max(0, s.asks)
        s.sessions = max(0, s.sessions)
        s.lastAskSession = max(0, s.lastAskSession)
        if s.consent == .declined && s.asks < 1 { s.asks = 1 }
        if s.lastAskSession > s.sessions { s.lastAskSession = s.sessions }
        let t = now.ms
        if (s.installedAt ?? Int64.max) > t { s.installedAt = t }
        var la = s.lastAskAt, ld = s.lastAskDay
        if s.asks == 0 {
            la = nil
            ld = nil
        } else if la == nil || la! > t {
            la = t
            ld = localDay(now)
        } else if ld == nil, let at = la {
            ld = localDay(Now(ms: at, tzMin: now.tzMin))
        }
        s.lastAskAt = la
        s.lastAskDay = ld
    }

    // MARK: 20.5 the decision

    /// `decide`: the stored state (any SDK version) and this app session's part, an event, the signed config's
    /// `share_ask` as it came (nil when absent) and now. `action`: what the SDK puts on screen (`takeEnd` and
    /// `askNow`: an ask is due, present it at the moment of 20.6; `shown`: it may go on screen now; `answer open`:
    /// the full sheet). Every event, ignored or not, applies the reading rules first.
    static func decide(_ state: SharingState, app current: App, event: Event, config raw: JSONValue?, now: Now) -> Outcome {
        let cfg = Config.resolve(raw)
        var s = state
        normalize(&s, now: now)
        var app = current
        var action = Action.none
        var why: String?
        switch event {
        case .launch:
            app = App()
        case .takeStart:
            app.takeOpen = true
            if let a = app.ask {
                if !a.shown {
                    // withdrawn before it was on screen: nothing is counted
                    app.ask = nil
                } else if a.kind == .card {
                    // a card on screen goes when a take starts: Not now
                    notNow(&s, &app)
                }
            }
        case .takeEnd(let end, let speechMs, let offered):
            app.takeOpen = false
            let completed = end == .normal && speechMs > 0
            if completed {
                s.sessions += 1
                app.takes += 1
                app.recitedMs += speechMs
            }
            if !completed {
                why = "not_completed"
            } else if !offered {
                why = "not_offered"
            } else {
                why = blocked(s, app, cfg, now, moment: true)
                if why == nil { action = pend(s, &app) }
            }
        case .askNow(let offered):
            if !offered {
                why = "not_offered"
            } else if app.takeOpen {
                why = "take_open"
            } else if app.takes == 0 {
                why = "no_take"
            } else {
                why = blocked(s, app, cfg, now, moment: false)
                if why == nil { action = pend(s, &app) }
            }
        case .shown:
            if let a = app.ask {
                if a.shown {
                    why = "already_shown"
                } else {
                    why = show(&s, &app, cfg, now)
                    if why == nil { action = a.kind.action }
                }
            } else {
                why = "no_ask"
            }
        case .answer(let answer):
            if let a = app.ask {
                if !(s.consent == .unknown || s.consent == .declined) {
                    // another page or process recorded an answer meanwhile
                    app.ask = nil
                    why = "answered"
                } else if answer == .yes && a.kind != .sheet {
                    why = "card_has_no_yes"
                } else if answer == .open && a.kind != .card {
                    why = "not_a_card"
                } else if let answer {
                    // an answer means the ask was on screen (an SDK that missed its shown)
                    if !a.shown { why = show(&s, &app, cfg, now) }
                    if why == nil {
                        switch answer {
                        case .yes:
                            s.consent = .granted
                            app.ask = nil
                        case .notNow:
                            notNow(&s, &app)
                        case .open:
                            app.ask = Ask(kind: .sheet, number: a.number, shown: true)
                            action = .sheet
                        }
                    }
                } else {
                    why = "unknown_answer"
                }
            } else {
                why = "no_ask"
            }
        case .withdrawn:
            if let a = app.ask {
                if !a.shown {
                    app.ask = nil
                } else if a.kind == .card {
                    notNow(&s, &app)
                } else {
                    // a sheet taken back after it was shown: the ask is used, no answer is recorded
                    app.ask = nil
                }
            } else {
                why = "no_ask"
            }
        case .setting(let on):
            s.consent = on ? .granted : .final
            app.ask = nil
        case .unknown:
            why = "unknown_event"
        }
        return Outcome(action: action, why: why, state: s, app: app)
    }

    /// `_blocked`: the first rule, in this order, that keeps an ask from being due now, or nil. `moment` is true at
    /// the end of a take (the recitation of the app session counts) and false for the app's `ask()`.
    static func blocked(_ s: SharingState, _ app: App, _ cfg: Config, _ now: Now, moment: Bool) -> String? {
        if s.consent == .granted { return "granted" }
        if s.consent == .final { return "final" }
        if s.asks >= cfg.maxAsks { return "cap" }
        if app.ask != nil { return "ask_open" }
        if app.asked { return "app_session" }
        if let day = s.lastAskDay, localDay(now) <= day { return "same_day" }
        if moment && app.recitedMs < cfg.goodSessionMinS * 1000 { return "short" }
        let t = now.ms
        if s.asks == 0 {
            if t - (s.installedAt ?? t) < Int64(cfg.firstMinHours) * hourMs { return "first_hours" }
            if s.sessions < cfg.firstMinSessions { return "first_sessions" }
        } else {
            // asks is 1 or 2 here (under max_asks, at most 3)
            let k = min(s.asks - 1, cfg.reaskDays.count - 1)
            if t - (s.lastAskAt ?? t) < Int64(cfg.reaskDays[k]) * dayMs { return "reask_days" }
            if s.sessions - s.lastAskSession < cfg.reaskSessions[k] { return "reask_sessions" }
        }
        return nil
    }

    /// `_pend`: the ask goes in hand, a sheet when none was shown yet, else a card.
    private static func pend(_ s: SharingState, _ app: inout App) -> Action {
        let kind: Kind = s.asks == 0 ? .sheet : .card
        app.ask = Ask(kind: kind, number: s.asks + 1, shown: false)
        return kind.action
    }

    /// `_show`: the ask in hand goes on screen now, counted (one of the three), unless the stored state moved under
    /// it (`stale`: another page or process asked or was answered), when it is dropped.
    private static func show(_ s: inout SharingState, _ app: inout App, _ cfg: Config, _ now: Now) -> String? {
        guard var a = app.ask else { return "no_ask" }
        if !(s.consent == .unknown || s.consent == .declined) || s.asks + 1 != a.number || s.asks >= cfg.maxAsks {
            app.ask = nil
            return "stale"
        }
        s.asks += 1
        s.lastAskAt = now.ms
        s.lastAskDay = localDay(now)
        s.lastAskSession = s.sessions
        app.asked = true
        a.shown = true
        app.ask = a
        return nil
    }

    /// `_not_now`: "Not now" on the sheet or the card, the sheet closed without an answer, a card dismissed or gone.
    /// The third ask's is final.
    private static func notNow(_ s: inout SharingState, _ app: inout App) {
        if s.consent == .unknown || s.consent == .declined {
            s.consent = s.asks >= hardMaxAsks ? .final : .declined
        }
        app.ask = nil
    }
}

extension SharingMoment {
    /// The moment of the ask `decide` put in hand: the full sheet for the first ask, a card for a re-ask (20.1).
    init?(_ action: ShareAsk.Action) {
        switch action {
        case .sheet: self = .ask(reask: false)
        case .card: self = .card
        case .none: return nil
        }
    }

    /// The consent ask, as the sheet or the card (not the thank-you).
    var isAsk: Bool {
        if case .thanks = self { return false }
        return true
    }
}

/// SDK 4.0 (20.4 to 20.6, 20.10): the ask's events at the SDK's hooks, through `ShareAsk.decide`, replacing the 3.x
/// ask (`sessionCompleted`, the count at the decision). The launch and the return after 30 minutes (`Cloud.launch`,
/// `cameToForeground`), the take's start and end (`TajweedSession`), the background (`wentToBackground`), the
/// moment on screen (`SharingPresenter.present`) and the learner's answers.
extension Contributions {
    /// This app session's part of the ask (20.4), in memory only. Taken inside `update`'s body (the state's lock
    /// first) or alone, never the other way round.
    static let askApp = Locked(ShareAsk.App())
    /// For tests: how long the moment settles before an ask decided at the end of a take goes on screen (20.6).
    static let settleMs = Locked(ShareAsk.settleMs)
    /// The ask that waits for its moment: a later one, a take start, a launch, the background or a new configuration
    /// replaces the number, and the wait ends without showing anything.
    private static let settling = Locked(0)

    /// The number of the ask that waits for its moment: a presentation goes ahead only while it is the same.
    static var askToken: Int { settling.withLock { $0 } }

    /// One event through the decision, with what it changed.
    struct AskStep: Sendable {
        let outcome: ShareAsk.Outcome
        /// The app session's part before the event.
        let previous: ShareAsk.App
    }

    /// One event through the decision (20.5) under the state's lock, with `then` applied in the same write; the
    /// stored state is written only when it changed (20.4). Every ask it counts is a `share_asked` (20.8). Nil while
    /// the stored answer cannot be read (3.1.4): nothing is decided or written then.
    @discardableResult
    static func shareAsk(_ event: ShareAsk.Event,
                         then: (inout SharingState, ShareAsk.Outcome) -> Void = { _, _ in }) -> AskStep? {
        let config = QuranLab.cloud?.currentConfig?.share_ask
        let now = ShareAsk.Now.current()
        var step: AskStep?
        var counted = false
        _ = update(onlyIfChanged: true) { (s: inout SharingState) in
            let r = askApp.withLock { (app: inout ShareAsk.App) -> AskStep in
                let d = ShareAsk.decide(s, app: app, event: event, config: config, now: now)
                defer { app = d.app }
                return AskStep(outcome: d, previous: app)
            }
            counted = r.outcome.state.asks > s.asks
            s = r.outcome.state
            then(&s, r.outcome)
            step = r
        }
        if counted { QuranLab.count(.shareAsked) }
        return step
    }

    /// A new configuration (`reload`): a new app session's part, and no ask waits for its moment.
    static func resetAsk() {
        askApp.withLock { $0 = ShareAsk.App() }
        settling.withLock { $0 += 1 }
    }

    /// A new app session (20.2 `launch`): the Client's start in this process, and the app back in the foreground
    /// after 30 minutes or more in the background. Its part is reset; never an ask.
    static func appSessionStarted() {
        settling.withLock { $0 += 1 }
        guard let step = shareAsk(.launch) else {
            askApp.withLock { $0 = ShareAsk.App() }
            return
        }
        if step.previous.ask?.kind == .card { SharingPresenter.shared.cardGone() }
    }

    /// A take starts (20.5 `take_start`, where a `TajweedSession` opens): an ask in hand that is not on screen yet
    /// goes (it is decided again at this take's end); a card on screen goes as a "Not now"; a sheet on screen stays.
    static func takeStarted() {
        settling.withLock { $0 += 1 }
        guard let step = shareAsk(.takeStart) else { return }
        cardWent(step)
    }

    /// A take ended (20.5 `take_end`), with how it ended and its speech (`SpeechTracker.speechFrames` times
    /// `SpeechTracker.frameMs`). A completed session (ended normally, with speech) counts; at a good moment an ask
    /// that is due goes in hand and on screen once the moment has settled (20.6). The thank-you after the first shared
    /// session is unchanged: due at the next completed session, shown at once. Returns the moment handed over.
    @discardableResult
    static func takeEnded(_ end: ShareAsk.End, speechMs: Int) -> SharingMoment? {
        let offered = isEnabled
        let completed = end == .normal && speechMs > 0
        var thanks = false
        let step = shareAsk(.takeEnd(end: end, speechMs: speechMs, offered: offered)) { (s: inout SharingState, _: ShareAsk.Outcome) in
            guard offered, completed, s.consent == .granted, s.sharedOnce, !s.thanked else { return }
            s.thanked = true
            thanks = true
        }
        guard let step else { return nil }
        if thanks {
            SharingPresenter.shared.present(.thanks)
            return .thanks
        }
        guard let m = SharingMoment(step.outcome.action) else { return nil }
        settle(m)
        return m
    }

    /// The app's own moment (`TajweedSharing.ask()`, 20.5 `ask_now`): the ask goes on screen now when it is due by
    /// the rules of the end of a take without the 60 seconds, only after a completed session in this app session and
    /// with no take open (20.9: the app keeps its moment and loses the cadence). Otherwise nil, and nothing is shown.
    @discardableResult
    static func askNow() -> SharingMoment? {
        let offered = isEnabled
        guard let step = shareAsk(.askNow(offered: offered)), let m = SharingMoment(step.outcome.action) else {
            return nil
        }
        settling.withLock { $0 += 1 }
        SharingPresenter.shared.present(m)
        return m
    }

    /// The ask in hand goes on screen once the moment has settled (20.6): `settleMs` with no new take. A take that
    /// starts meanwhile drops it (`take_start`) and its end decides again, so in an app of short takes the ask waits
    /// for the learner's pause and never lands between two takes.
    private static func settle(_ m: SharingMoment) {
        let token = settling.withLock { (n: inout Int) -> Int in
            n += 1
            return n
        }
        let ms = max(0, settleMs.withLock { $0 })
        Task.detached(priority: .utility) {
            if ms > 0 { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }
            guard Contributions.settling.withLock({ $0 == token }) else { return }
            SharingPresenter.shared.present(m)
        }
    }

    /// Right before a moment appears (20.6, `SharingPresenter.present`): an ask goes on screen only when `shown` gives
    /// its kind, and is counted then; otherwise nothing appears (it went, or the stored state moved under it). A
    /// re-ask is always the card, with the deck's `card.line`, `card.open` and `card.not_now` (20.7). The 3.x re-ask
    /// sheet that 20.6 puts in the card's place for a deck without those lines (one before 2026-11-15.1) has no case
    /// here: this SDK shows only its bundled decks, every one 2026-11-19.1 with the card's lines (SharingDeckTests), it
    /// takes no deck from the server (SPEC 3.0 11.9, where 20.7 refuses a deck that lacks a key of the bundled one),
    /// and an app's own wording cannot blank a line (`setWording`). The thank-you appears as it is.
    static func goingOnScreen(_ m: SharingMoment) -> SharingMoment? {
        guard m.isAsk else { return m }
        guard let step = shareAsk(.shown) else { return nil }
        switch step.outcome.action {
        case .none:
            return nil
        case .sheet:
            return .ask(reask: false)
        case .card:
            return .card
        }
    }

    /// The ask in hand never reached the screen (nowhere to show it): it is none (20.5 `withdrawn`).
    static func askWithdrawn() {
        settling.withLock { $0 += 1 }
        shareAsk(.withdrawn)
    }

    /// The app left the foreground (20.6): an ask in hand that is not on screen yet, or a card on screen, is
    /// withdrawn (the card as a "Not now"); a sheet on screen stays.
    static func leftForeground() {
        guard let a = askApp.withLock({ $0.ask }), !a.shown || a.kind == .card else { return }
        settling.withLock { $0 += 1 }
        guard let step = shareAsk(.withdrawn) else { return }
        cardWent(step)
    }

    /// The settings switch (20.5 `setting`): any ask in hand goes, and a card leaves the screen. The consent itself
    /// is the switch's own write (`switchSharing`).
    static func askDropped() {
        settling.withLock { $0 += 1 }
        let was = askApp.withLock { (app: inout ShareAsk.App) -> ShareAsk.Ask? in
            defer { app.ask = nil }
            return app.ask
        }
        if was?.kind == .card { SharingPresenter.shared.cardGone() }
    }

    /// A card on screen that went with the event (a take start, the background) was a "Not now" (`share_no`, 20.8):
    /// it leaves the screen.
    private static func cardWent(_ step: AskStep) {
        guard let was = step.previous.ask, was.kind == .card, was.shown, step.outcome.app.ask == nil else { return }
        if step.outcome.why == nil { QuranLab.count(.shareNo) }
        SharingPresenter.shared.cardGone()
    }

    /// "See how it helps" on the card (20.5 `answer open`): true when the full sheet is to be shown now, for the same
    /// ask (not counted again), without the re-ask line.
    static func cardOpened() -> Bool {
        shareAsk(.answer(.open))?.outcome.action == .sheet
    }

    /// The card's "Not now", or the card swiped away: "Not now" (`share_no`).
    static func cardDismissed() {
        guard isReadable, let step = shareAsk(.answer(.notNow)), step.outcome.why == nil else { return }
        QuranLab.count(.shareNo)
    }

    /// The sheet went without one of its buttons (swiped down): a "Not now" for the ask in hand (20.5 `_not_now`);
    /// nothing when no ask is in hand.
    static func sheetClosed() {
        answer(share: false)
    }

    /// The learner's answer on the sheet (the SDK's, or the app's own UI from `setPresenter(_:)`), only from the
    /// learner's own tap: 20.5 `answer` `yes` or `not_now` for the ask in hand (an answer to an ask not yet shown
    /// counts it first). A yes is to the consent version in force (the app's own wording included), with its hash.
    ///
    /// A yes given on the SDK's full sheet when no ask is in hand (an app that presents `SharingConsentView` itself;
    /// an app session that started again under the sheet; a stale ask) is the learner's own consent with everything
    /// shared in view, and is recorded as before 4.0; the ask's count is not touched then. A "Not now" without an
    /// ask in hand changes nothing. A yes on a card that was not opened is not a yes (`card_has_no_yes`): the full
    /// sheet is shown in the card's place for the same ask.
    static func answer(share: Bool) {
        // the stored answer cannot be read: no answer is recorded over it, and none is counted
        guard isReadable else { return }
        let yes = share
        let c = copy
        let version = c.consentVersion, hash = c.consentTextSHA256
        var recorded: Bool?
        let step = shareAsk(.answer(yes ? .yes : .notNow)) { (s: inout SharingState, r: ShareAsk.Outcome) in
            let at = Date().timeIntervalSince1970.rounded()
            if r.why == nil {
                s.decidedAt = at
                recorded = yes
            } else if yes, r.why == "no_ask" || r.why == "stale", s.consent != .granted {
                // (a learner who already said yes keeps the version they agreed to)
                s.consent = .granted
                s.decidedAt = at
                recorded = true
            }
            if recorded == true {
                s.consentVersion = version
                s.consentTextSHA256 = hash
            }
        }
        if let recorded { QuranLab.count(recorded ? .shareYes : .shareNo) }
        if step?.outcome.why == "card_has_no_yes", cardOpened() {
            SharingPresenter.shared.present(.ask(reask: false), opened: true)
        }
    }
}
