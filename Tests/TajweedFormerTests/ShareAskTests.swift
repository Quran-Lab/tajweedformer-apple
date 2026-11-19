import Foundation
import XCTest
@testable import TajweedFormer

extension Contributions {
    /// For the tests written before 4.0 (a finished take, with the model's feedback or without): a take that ended
    /// normally, with 90 seconds of speech or with none.
    @discardableResult
    static func sessionCompleted(feedback: Bool) -> SharingMoment? { takeEnded(.normal, speechMs: feedback ? 90_000 : 0) }

    /// For tests: the stored state made so that the next ask is due at the next good take (installed two days ago,
    /// three completed sessions; after an ask, the last one 31 days ago and 10 completed sessions since), in a new
    /// app session.
    static func makeAskDue() {
        let now = ShareAsk.Now.current()
        _ = update { (s: inout SharingState) in
            s.installedAt = now.ms - 2 * ShareAsk.dayMs
            s.sessions = max(s.sessions, 3)
            if s.asks > 0 {
                let at = now.ms - 31 * ShareAsk.dayMs
                s.lastAskAt = at
                s.lastAskDay = ShareAsk.localDay(ShareAsk.Now(ms: at, tzMin: now.tzMin))
                s.sessions = max(s.sessions, s.lastAskSession + 10)
            }
        }
        appSessionStarted()
    }
}

/// SDK 4.0, contract section 20 (`SHARE_ASK_40.md`): when the SDK asks a learner to share. Every case of
/// `vectors/share_ask.json` (copied into Fixtures/vectors40) replayed through the port (`ShareAsk.decide`, each step's
/// action, why and whole new state, the stored names mapped as 20.4), every config case through the config's
/// reading, the stored state of an earlier SDK, the 30 minutes that make a new app session, and the moment on a fake
/// clock (20.10 item 5).
final class ShareAskTests: XCTestCase {
    override func tearDown() {
        Contributions.setPresenter(nil)
        Contributions.settleMs.withLock { $0 = ShareAsk.settleMs }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    // MARK: the vectors' words

    /// The vectors' stored names (20.4) and the names the SDK stores them under.
    static let storedNames = ["consent": "consent", "asks": "asks", "sessions": "sessions", "last_ask_session": "lastAskSession",
                              "installed_at": "installedAt", "last_ask_at": "lastAskAt", "last_ask_day": "lastAskDay"]

    /// A JSON number as an integer; nil for null or anything else.
    static func number(_ x: Any?) -> Int64? { (x as? NSNumber)?.int64Value }

    /// A vector's stored state, read by the SDK's own decoder under the stored names (a 3.x state has none of the
    /// three new fields).
    static func state(_ v: [String: Any]) throws -> SharingState {
        var o: [String: Any] = [:]
        for (k, x) in v {
            let name = try XCTUnwrap(storedNames[k], "a field of the vectors' stored state: \(k)")
            o[name] = x
        }
        return try JSONDecoder().decode(SharingState.self, from: try JSONSerialization.data(withJSONObject: o))
    }

    /// Stored fields another page or process wrote (a step's `set`), merged into the stored part.
    static func apply(_ set: [String: Any], to s: inout SharingState) throws {
        for (k, x) in set {
            switch k {
            case "consent": s.consent = try XCTUnwrap(SharingConsent(rawValue: try XCTUnwrap(x as? String)))
            case "asks": s.asks = try XCTUnwrap(x as? Int)
            case "sessions": s.sessions = try XCTUnwrap(x as? Int)
            case "last_ask_session": s.lastAskSession = try XCTUnwrap(x as? Int)
            case "installed_at": s.installedAt = number(x)
            case "last_ask_at": s.lastAskAt = number(x)
            case "last_ask_day": s.lastAskDay = number(x).map { Int($0) }
            default: XCTFail("a field of a step's set: \(k)")
            }
        }
    }

    static func event(_ e: [String: Any]) -> ShareAsk.Event {
        switch e["type"] as? String {
        case "launch": return .launch
        case "take_start": return .takeStart
        case "take_end":
            return .takeEnd(end: (e["end"] as? String).flatMap { ShareAsk.End(rawValue: $0) },
                            speechMs: (e["speech_ms"] as? NSNumber)?.intValue ?? 0, offered: (e["offered"] as? Bool) == true)
        case "ask_now": return .askNow(offered: (e["offered"] as? Bool) == true)
        case "shown": return .shown
        case "answer": return .answer((e["answer"] as? String).flatMap { ShareAsk.Answer(rawValue: $0) })
        case "withdrawn": return .withdrawn
        case "setting": return .setting(on: (e["on"] as? Bool) == true)
        default: return .unknown
        }
    }

    /// The app session's part as the vectors write it.
    static func app(_ v: Any?) throws -> ShareAsk.App {
        let a = try XCTUnwrap(v as? [String: Any])
        var out = ShareAsk.App(takes: try XCTUnwrap(a["takes"] as? Int), recitedMs: try XCTUnwrap(a["recited_ms"] as? Int),
                               asked: try XCTUnwrap(a["asked"] as? Bool), takeOpen: try XCTUnwrap(a["take_open"] as? Bool), ask: nil)
        if let k = a["ask"] as? [String: Any] {
            out.ask = ShareAsk.Ask(kind: try XCTUnwrap(ShareAsk.Kind(rawValue: try XCTUnwrap(k["kind"] as? String))),
                                   number: try XCTUnwrap(k["number"] as? Int), shown: try XCTUnwrap(k["shown"] as? Bool))
        }
        return out
    }

    static func config(_ d: [String: Any]) throws -> ShareAsk.Config {
        ShareAsk.Config(firstMinSessions: try XCTUnwrap(d["first_min_sessions"] as? Int),
                        firstMinHours: try XCTUnwrap(d["first_min_hours"] as? Int),
                        reaskDays: try XCTUnwrap(d["reask_days"] as? [Int]),
                        reaskSessions: try XCTUnwrap(d["reask_sessions"] as? [Int]),
                        goodSessionMinS: try XCTUnwrap(d["good_session_min_s"] as? Int),
                        maxAsks: try XCTUnwrap(d["max_asks"] as? Int))
    }

    /// The whole new state of a step: the stored part, field by field, and the app session's part.
    static func check(_ r: ShareAsk.Outcome, _ want: [String: Any], _ label: String) throws {
        XCTAssertEqual(Set(want.keys), Set(storedNames.keys).union(["app"]), "\(label): the fields of the state")
        let s = r.state
        XCTAssertEqual(s.consent.rawValue, want["consent"] as? String, "\(label): consent")
        XCTAssertEqual(s.asks, want["asks"] as? Int, "\(label): asks")
        XCTAssertEqual(s.sessions, want["sessions"] as? Int, "\(label): sessions")
        XCTAssertEqual(s.lastAskSession, want["last_ask_session"] as? Int, "\(label): last_ask_session")
        XCTAssertEqual(s.installedAt, number(want["installed_at"]), "\(label): installed_at")
        XCTAssertEqual(s.lastAskAt, number(want["last_ask_at"]), "\(label): last_ask_at")
        XCTAssertEqual(s.lastAskDay.map { Int64($0) }, number(want["last_ask_day"]), "\(label): last_ask_day")
        XCTAssertEqual(r.app, try app(want["app"]), "\(label): the app session's part")
    }

    // MARK: the vectors

    /// Every case, step by step: from the case's stored state (some in 3.x form) and its config, each event at its
    /// time gives the step's action, why and whole new state; the next step starts from that state.
    func testEveryCaseOfTheVectors() throws {
        let v = try V40.json("share_ask.json")
        XCTAssertEqual(v["format"] as? String, "quranlab.share-ask-vectors/1")
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 40)
        var steps = 0
        var whys = Set<String>()
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let raw = c["config"]
            let config: JSONValue? = raw == nil || raw is NSNull ? nil : JSONValue(any: raw)
            var state = try Self.state(try XCTUnwrap(c["state"] as? [String: Any]))
            var app = ShareAsk.App()
            for (i, step) in try XCTUnwrap(c["steps"] as? [[String: Any]]).enumerated() {
                let label = "\(name), step \(i + 1)"
                if let set = step["set"] as? [String: Any] { try Self.apply(set, to: &state) }
                let now = try XCTUnwrap(step["now"] as? [String: Any])
                let at = ShareAsk.Now(ms: try XCTUnwrap(Self.number(now["ms"])), tzMin: (now["tz_min"] as? Int) ?? 0)
                let event = Self.event(try XCTUnwrap(step["event"] as? [String: Any]))
                let r = ShareAsk.decide(state, app: app, event: event, config: config, now: at)
                XCTAssertEqual(r.action.rawValue, step["action"] as? String, "\(label): action")
                XCTAssertEqual(r.why, step["why"] as? String, "\(label): why")
                try Self.check(r, try XCTUnwrap(step["state"] as? [String: Any]), label)
                if let why = r.why { whys.insert(why) }
                state = r.state
                app = r.app
                steps += 1
            }
        }
        XCTAssertEqual(steps, 338)
        XCTAssertEqual(whys, Set(try XCTUnwrap(v["why"] as? [String])), "every why of 20.5 is pinned, and no other")
    }

    /// Every config case: the port's reading of `share_ask` as it came, and the same through the signed config's
    /// reading, at the top level; `share_ask` inside `flags` is not read.
    func testEveryConfigCase() throws {
        let v = try V40.json("share_ask.json")
        let cases = try XCTUnwrap(v["config_cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 21)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let want = try Self.config(try XCTUnwrap(c["resolved"] as? [String: Any]))
            let raw: Any = try XCTUnwrap(c["raw"])
            let absent = raw is NSNull
            XCTAssertEqual(ShareAsk.Config.resolve(absent ? nil : JSONValue(any: raw)), want, name)
            let body = CloudFixtures.config(extra: absent ? [:] : ["share_ask": raw]).body
            let cfg = try JSONDecoder().decode(RemoteConfig.self, from: body)
            XCTAssertEqual(ShareAsk.Config.resolve(cfg.share_ask), want, "\(name): read from the signed config")
        }
        let inFlags = CloudFixtures.config(flags: ["share_ask": ["max_asks": 1, "first_min_hours": 48]]).body
        let cfg = try JSONDecoder().decode(RemoteConfig.self, from: inFlags)
        XCTAssertNil(cfg.share_ask)
        XCTAssertEqual(ShareAsk.Config.resolve(cfg.share_ask), ShareAsk.Config(), "never read from flags")
    }

    /// The port's constants are the vectors': the defaults, the bounds, the hard cap, an hour and a day.
    func testTheConstantsAreTheContracts() throws {
        let k = try XCTUnwrap(try V40.json("share_ask.json")["constants"] as? [String: Any])
        XCTAssertEqual(k["HARD_MAX_ASKS"] as? Int, ShareAsk.hardMaxAsks)
        XCTAssertEqual(Self.number(k["HOUR_MS"]), ShareAsk.hourMs)
        XCTAssertEqual(Self.number(k["DAY_MS"]), ShareAsk.dayMs)
        XCTAssertEqual(try Self.config(try XCTUnwrap(k["defaults"] as? [String: Any])), ShareAsk.Config())
        let b = try XCTUnwrap(k["bounds"] as? [String: Any])
        func pair(_ t: (Int, Int)) -> [Int] { [t.0, t.1] }
        XCTAssertEqual(b["first_min_sessions"] as? [Int], pair(ShareAsk.Config.firstMinSessionsBounds))
        XCTAssertEqual(b["first_min_hours"] as? [Int], pair(ShareAsk.Config.firstMinHoursBounds))
        XCTAssertEqual(b["good_session_min_s"] as? [Int], pair(ShareAsk.Config.goodSessionMinSBounds))
        XCTAssertEqual(b["max_asks"] as? [Int], pair(ShareAsk.Config.maxAsksBounds))
        XCTAssertEqual(b["reask_days"] as? [[Int]], ShareAsk.Config.reaskDaysBounds.map(pair))
        XCTAssertEqual(b["reask_sessions"] as? [[Int]], ShareAsk.Config.reaskSessionsBounds.map(pair))
        XCTAssertEqual(ShareAsk.settleMs, 3000, "20.6 SHARE_ASK_SETTLE_MS")
        XCTAssertEqual(ShareAsk.appSessionGap, 1800, "20.2: 30 minutes in the background")
        // the calendar day is floored, also before 1970 and west of UTC
        XCTAssertEqual(ShareAsk.localDay(ShareAsk.Now(ms: 1_800_000_000_000, tzMin: 0)), 20833)
        XCTAssertEqual(ShareAsk.localDay(ShareAsk.Now(ms: -1, tzMin: 0)), -1)
        XCTAssertEqual(ShareAsk.localDay(ShareAsk.Now(ms: 0, tzMin: -1)), -1)
    }

    // MARK: the stored state

    func configure(storage: URL = Fixtures.storage(), clock: @escaping @Sendable () -> Date = { Date() }) -> QuranLabCloud {
        CloudFixtures.seedConfig(storage: storage)
        let o = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: o, clock: clock)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: cloud)
        return cloud
    }

    /// A stored state of an earlier SDK has none of the three new fields: it reads, every field of it kept, and the
    /// new ones are absent (also when they hold something that is not a whole number). 4.0 stores them under the
    /// names of 20.4. On the device, the first decision under 4.0 (the launch) starts the clocks at the upgrade: the
    /// install time now, and for an install asked before, the last ask now and its day today; nothing else changes.
    func testAStateOfAnEarlierSDKReadsWithoutTheNewFieldsAndItsClocksStartAtTheUpgrade() throws {
        for text in [SharingConsentPersistTests.granted311, UnreadableStateTests.storedDeclined, #"{"v":1,"consent":"declined","sessions":3}"#] {
            let s = try JSONDecoder().decode(SharingState.self, from: Data(text.utf8))
            XCTAssertNil(s.installedAt, text)
            XCTAssertNil(s.lastAskAt, text)
            XCTAssertNil(s.lastAskDay, text)
        }
        let declined = try JSONDecoder().decode(SharingState.self, from: Data(UnreadableStateTests.storedDeclined.utf8))
        XCTAssertEqual([declined.asks, declined.sessions, declined.lastAskSession], [1, 5, 3])
        XCTAssertEqual(declined.consent, .declined)
        XCTAssertEqual(declined.decidedAt, 1_794_300_000)
        let odd = #"{"v":1,"consent":"declined","asks":1,"installedAt":"soon","lastAskAt":1.5,"lastAskDay":"today"}"#
        let o = try JSONDecoder().decode(SharingState.self, from: Data(odd.utf8))
        XCTAssertNil(o.installedAt)
        XCTAssertNil(o.lastAskAt)
        XCTAssertNil(o.lastAskDay)
        XCTAssertEqual(o.asks, 1, "the rest is read")

        var s = SharingState()
        s.asks = 1
        s.installedAt = 1_799_000_000_000
        s.lastAskAt = 1_800_000_000_000
        s.lastAskDay = 20833
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        XCTAssertEqual(Self.number(written["installedAt"]), 1_799_000_000_000)
        XCTAssertEqual(Self.number(written["lastAskAt"]), 1_800_000_000_000)
        XCTAssertEqual(Self.number(written["lastAskDay"]), 20833)
        XCTAssertEqual(try JSONDecoder().decode(SharingState.self, from: JSONEncoder().encode(s)), s)

        // on the device
        let storage = Fixtures.storage()
        let file = storage.appendingPathComponent("cloud/sharing-state.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(UnreadableStateTests.storedDeclined.utf8).write(to: file)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = configure(storage: storage, clock: { t })
        Contributions.appSessionStarted()
        let saved = try UnreadableStateTests.saved(storage)
        let now = ShareAsk.Now(date: t, timeZone: .current)
        XCTAssertEqual(Self.number(saved["installedAt"]), now.ms, "the install time is the upgrade")
        XCTAssertEqual(Self.number(saved["lastAskAt"]), now.ms, "asked under 3.x: the last ask is the upgrade")
        XCTAssertEqual(Self.number(saved["lastAskDay"]), Int64(ShareAsk.localDay(now)))
        XCTAssertEqual(saved["consent"] as? String, "declined")
        XCTAssertEqual(saved["asks"] as? Int, 1)
        XCTAssertEqual(saved["sessions"] as? Int, 5)
        XCTAssertEqual(saved["lastAskSession"] as? Int, 3)
        XCTAssertEqual((saved["decidedAt"] as? NSNumber)?.doubleValue, 1_794_300_000)
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 90_000), "not asked: the last ask is the upgrade, today")
        XCTAssertEqual(Contributions.state().sessions, 6, "the completed session counted")
    }

    // MARK: the app session

    /// 20.2: the app back in the foreground after 30 minutes or more in the background is a new app session (its part
    /// starts again); after less, the same one.
    func testAReturnAfterThirtyMinutesOrMoreIsANewAppSession() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let now = Locked(t0)
        let cloud = configure(clock: { now.withLock { $0 } })
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 30_000))
        XCTAssertEqual(Contributions.askApp.withLock { $0 }, ShareAsk.App(takes: 1, recitedMs: 30_000))

        cloud.wentToBackground()
        now.withLock { $0 = t0.addingTimeInterval(29 * 60 + 59) }
        cloud.cameToForeground()
        XCTAssertEqual(Contributions.askApp.withLock { $0 }, ShareAsk.App(takes: 1, recitedMs: 30_000),
                       "29 minutes 59 seconds away: the same app session")

        let t1 = t0.addingTimeInterval(40 * 60)
        now.withLock { $0 = t1 }
        cloud.wentToBackground()
        now.withLock { $0 = t1.addingTimeInterval(30 * 60) }
        cloud.cameToForeground()
        XCTAssertEqual(Contributions.askApp.withLock { $0 }, ShareAsk.App(), "30 minutes away: a new app session")
        XCTAssertEqual(Contributions.state().sessions, 1, "the stored count goes on")
    }

    // MARK: the moment, on a fake clock

    /// A "Not now" 15 days ago, 8 completed sessions since: the next good take is the moment of a card.
    func seedReask(_ t: Date) {
        let now = ShareAsk.Now(date: t, timeZone: .current)
        let last = now.ms - 15 * ShareAsk.dayMs
        _ = Contributions.update { (s: inout SharingState) in
            s.consent = .declined
            s.asks = 1
            s.sessions = 10
            s.lastAskSession = 2
            s.installedAt = now.ms - 30 * ShareAsk.dayMs
            s.lastAskAt = last
            s.lastAskDay = ShareAsk.localDay(ShareAsk.Now(ms: last, tzMin: now.tzMin))
        }
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 10, _ done: () async -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Waits on the main actor until `done` (what the SDK's surface shows is the main actor's).
    @MainActor
    func waitOnMain(_ what: String, timeout: TimeInterval = 10, _ done: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if done() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// The card is decided at the end of a good take and goes on screen after the settle, as the card (deck
    /// 2026-11-15.1 has its lines; no 3.x re-ask sheet in its place); a take that starts before then takes it back
    /// (nothing counted) and the next end decides again. On screen it is one ask; "See how it helps" opens the full
    /// sheet for the same ask, where the yes is given.
    func testTheCardAfterTheSettle() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = configure(clock: { t })
        Contributions.settleMs.withLock { $0 = 300 }
        let seen = Locked<[SharingMoment]>([])
        Contributions.setPresenter { (m: SharingMoment) in seen.withLock { $0.append(m) } }
        seedReask(t)
        let copy = Contributions.copy
        for k in ["card.line", "card.open", "card.not_now"] { XCTAssertFalse(copy.string(k).isEmpty, "the deck in force has \(k)") }

        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .card)
        Contributions.takeStarted()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(seen.withLock { $0 }, [], "a take started before the moment settled: nothing on screen")
        XCTAssertEqual(Contributions.state().asks, 1, "and nothing counted")
        XCTAssertNil(Contributions.askApp.withLock { $0.ask })

        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .card, "decided again at the next end")
        try await waitUntil("the card on screen") { seen.withLock { $0.count } == 1 }
        XCTAssertEqual(seen.withLock { $0 }, [.card], "the card, never the re-ask sheet")
        let s = Contributions.state()
        XCTAssertEqual(s.asks, 2, "one ask, counted on screen")
        XCTAssertEqual(s.lastAskAt, ShareAsk.Now(date: t, timeZone: .current).ms)
        XCTAssertEqual(s.lastAskSession, 12)
        XCTAssertEqual(Contributions.askApp.withLock { $0.ask }, ShareAsk.Ask(kind: .card, number: 2, shown: true), "the card on screen")
        XCTAssertTrue(Contributions.cardOpened(), "See how it helps: the full sheet for the same ask")
        XCTAssertEqual(Contributions.askApp.withLock { $0.ask }, ShareAsk.Ask(kind: .sheet, number: 2, shown: true))
        Contributions.answer(share: true)
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertEqual(Contributions.state().asks, 2, "a card opened into the sheet is one ask")
        XCTAssertEqual(Contributions.state().consentVersion, "share-2026-11-09", "the deck's consent version, unchanged by the card")
    }

    /// The SDK's own surface (`.quranLabSharing()`): the re-ask goes on screen as the card, an overlay and not a
    /// sheet (nothing modal); "See how it helps" turns it into the full sheet without the re-ask line, the same ask;
    /// that sheet swiped down is a "Not now". Then, at the third ask, the card's own "Not now" is the final one.
    @MainActor
    func testTheSDKsSurfaceShowsTheCard() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = configure(clock: { t })
        Contributions.settleMs.withLock { $0 = 0 }
        let model = SharingPromptModel.shared
        model.installed = true
        model.moment = nil
        defer {
            model.installed = false
            model.moment = nil
        }
        seedReask(t)

        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .card)
        try await waitOnMain("the card on screen") { model.moment == .card }
        XCTAssertTrue(model.cardUp)
        XCTAssertFalse(model.sheetUp, "a card is not a sheet: nothing modal")
        XCTAssertEqual(Contributions.state().asks, 2, "counted as it went on screen")
        model.cardChosen(.open)
        XCTAssertEqual(model.moment, .ask(reask: false), "the full sheet, without the re-ask line")
        XCTAssertTrue(model.sheetUp)
        XCTAssertEqual(Contributions.state().asks, 2, "the same ask")
        model.sheetClosed()
        XCTAssertNil(model.moment)
        XCTAssertEqual(Contributions.consent, .declined, "the sheet swiped down: Not now")

        // the third ask: the card's own Not now is final
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .card)
        try await waitOnMain("the third card on screen") { model.moment == .card }
        XCTAssertEqual(Contributions.state().asks, 3)
        model.cardChosen(.notNow)
        XCTAssertNil(model.moment)
        XCTAssertEqual(Contributions.consent, .final, "Not now on the third ask: never asked again")
    }

    /// A card on screen in the SDK's surface leaves it when a take starts, as a "Not now".
    @MainActor
    func testACardOnTheSDKsSurfaceGoesWhenATakeStarts() async throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = configure(clock: { t })
        Contributions.settleMs.withLock { $0 = 0 }
        let model = SharingPromptModel.shared
        model.installed = true
        model.moment = nil
        defer {
            model.installed = false
            model.moment = nil
        }
        seedReask(t)
        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .card)
        try await waitOnMain("the card on screen") { model.moment == .card }
        Contributions.takeStarted()
        try await waitOnMain("the card off the screen") { model.moment == nil }
        XCTAssertEqual(Contributions.consent, .declined, "a card gone with a take start: Not now")
        XCTAssertEqual(Contributions.state().asks, 2, "it was one ask")
    }

    /// A card on screen goes when a take starts, as a "Not now" (it was one of the three); nothing more is asked in
    /// this app session.
    func testACardOnScreenGoesWithATakeStartAsNotNow() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = configure(clock: { t })
        seedReask(t)
        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .card)
        // on screen
        XCTAssertEqual(try XCTUnwrap(Contributions.shareAsk(.shown)).outcome.action, .card)
        XCTAssertEqual(Contributions.state().asks, 2)
        Contributions.takeStarted()
        XCTAssertEqual(Contributions.consent, .declined, "Not now")
        XCTAssertNil(Contributions.askApp.withLock { $0.ask })
        XCTAssertEqual(Contributions.state().asks, 2, "still one ask")
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 90_000), "one ask per app session")
        XCTAssertNil(Contributions.askNow())
    }

    /// The app leaving the foreground takes back an ask that waits for its moment: it never reaches the screen and
    /// is not counted.
    func testTheBackgroundTakesBackAnAskThatWaitsForItsMoment() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let cloud = configure(clock: { t })
        Contributions.settleMs.withLock { $0 = 300 }
        let seen = Locked<[SharingMoment]>([])
        Contributions.setPresenter { (m: SharingMoment) in seen.withLock { $0.append(m) } }
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.takeEnded(.normal, speechMs: 90_000), .ask(reask: false))
        cloud.wentToBackground()
        XCTAssertNil(Contributions.askApp.withLock { $0.ask })
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(seen.withLock { $0 }, [], "nothing appears")
        XCTAssertEqual(Contributions.state().asks, 0, "nothing counted")
    }

    /// The app's `ask()` keeps its moment and loses the cadence (20.9): nothing at launch, during a take, or before
    /// the first ask is due; without the 60 seconds once it is.
    func testTheAppsAskIsFalseWhenNotDue() {
        _ = configure()
        Contributions.appSessionStarted()
        XCTAssertNil(Contributions.askNow(), "no completed take in this app session")
        Contributions.takeStarted()
        XCTAssertNil(Contributions.askNow(), "a take is open")
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 10_000))
        XCTAssertNil(Contributions.askNow(), "the install's first 24 hours")
        Contributions.makeAskDue()
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 10_000), "10 seconds: not the SDK's moment")
        XCTAssertEqual(Contributions.askNow(), .ask(reask: false), "the app's moment, without the 60 seconds")
        XCTAssertNil(Contributions.askNow(), "one ask at a time")
    }
}
