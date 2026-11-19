import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The sharing state machine every TajweedFormer SDK follows: never before a completed take, at most three asks per
/// install (SDK 4.0: the sheet, then cards after "Not now", each when it is due; the timing itself is pinned by the
/// contract's vectors in ShareAskTests), the count kept across launches and the upgrade from 2.0.0; a yes or settings
/// off ends asking; one sheet for every app (SDK 4.0); the thank-you once; the bundled copy deck and its disclosure lines.
final class SharingConsentTests: XCTestCase {
    func configure(contributions: Bool = true, flags: [String: Any]? = [:], storage: URL = Fixtures.storage()) {
        if let flags { CloudFixtures.seedConfig(storage: storage, flags: flags) }
        let o = CloudFixtures.options(contributions: contributions, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: o)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: cloud)
    }

    override func tearDown() { QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil) }

    func testAskOnceThenTwoReasksThenNever() {
        let storage = Fixtures.storage()
        configure(storage: storage)
        XCTAssertNil(Contributions.sessionCompleted(feedback: false), "no speech, no ask")
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "not in the install's first 24 hours")
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false))
        Contributions.answer(share: false)
        XCTAssertEqual(Contributions.consent, .declined)
        XCTAssertEqual(Contributions.state().asks, 1)
        for _ in 0..<10 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "not again soon") }
        for i in 2...3 {
            Contributions.makeAskDue()
            XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .card, "re-ask \(i) is a card")
            Contributions.answer(share: false)
            XCTAssertEqual(Contributions.state().asks, i)
        }
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertEqual(Contributions.state().asks, 3, "three asks in all")
        XCTAssertFalse(Contributions.isActive)
        Contributions.makeAskDue()
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "no fourth ask")
        XCTAssertNil(Contributions.askNow(), "no fourth ask at the app's own timing")
        // a restart: the count is read back from disk
        configure(storage: storage)
        XCTAssertEqual(Contributions.state().asks, 3)
        Contributions.makeAskDue()
        for i in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "no fourth ask after a restart (\(i))") }
        XCTAssertNil(Contributions.askNow())
    }

    /// The third "Not now" ends asking also when the asks came at the app's own timing (`ask()`: due by the same rules,
    /// without the 60 seconds, after a completed take); a sheet closed without an answer is a "Not now".
    func testThreeAsksInAllWhateverTheTiming() {
        let storage = Fixtures.storage()
        configure(storage: storage)
        Contributions.makeAskDue()
        XCTAssertNil(Contributions.askNow(), "not before a completed take in this app session")
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 10_000), "a short take: not the SDK's own moment")
        XCTAssertEqual(Contributions.askNow(), .ask(reask: false))
        Contributions.sheetClosed()
        XCTAssertEqual(Contributions.consent, .declined, "closed without an answer: Not now")
        XCTAssertEqual(Contributions.state().asks, 1)
        XCTAssertNil(Contributions.askNow(), "one ask per app session")
        for i in 2...3 {
            Contributions.makeAskDue()
            XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 10_000))
            XCTAssertEqual(Contributions.askNow(), .card, "re-ask \(i)")
            Contributions.answer(share: false)
        }
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertEqual(Contributions.state().asks, 3)
        Contributions.makeAskDue()
        XCTAssertNil(Contributions.takeEnded(.normal, speechMs: 10_000))
        XCTAssertNil(Contributions.askNow())
        configure(storage: storage)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
        XCTAssertNil(Contributions.askNow())
    }

    /// The ask count of a 2.0.0 install carries over (2.0.0 wrote `asks` in the same file): two asks and a decline
    /// leave one more ask at most; a decline 2.0.0 recorded without a count counts as one sheet shown.
    func testAnUpgradeFrom200CarriesItsAskCount() throws {
        let storage = Fixtures.storage()
        try SharingConsentPersistTests.write200(.init(consent: "declined", asks: 2, lastAskSession: 10, sessions: 12,
                                                      decidedAt: 1_794_200_000), storage: storage)
        configure(storage: storage)
        XCTAssertEqual(Contributions.consent, .declined)
        XCTAssertEqual(Contributions.state().asks, 2)
        for _ in 13...16 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the clocks of an upgrade start at the upgrade") }
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .card, "the third and last")
        Contributions.answer(share: false)
        XCTAssertEqual(Contributions.consent, .final)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
        configure(storage: storage)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "and after a restart") }
        XCTAssertNil(Contributions.askNow())

        let bare = Fixtures.storage()
        let url = bare.appendingPathComponent("cloud/sharing-state.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":1,"consent":"declined","sessions":3}"#.utf8).write(to: url)
        configure(storage: bare)
        XCTAssertEqual(Contributions.consent, .declined, "a state with missing fields is read, not reset")
        XCTAssertEqual(Contributions.state().asks, 1)
    }

    func testAGrantSharesAndThanksOnce() async {
        configure()
        _ = Contributions.sessionCompleted(feedback: true)
        Contributions.answer(share: true)
        XCTAssertEqual(Contributions.consent, .granted)
        XCTAssertTrue(Contributions.isActive)
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "no thanks before a session was shared")
        Contributions.noteShared()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .thanks)
        XCTAssertNil(Contributions.sessionCompleted(feedback: true))
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertFalse(Contributions.isActive)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "turned off in settings: never asked again") }
        XCTAssertNil(Contributions.askNow())
    }

    /// A yes ends asking: no sheet across many sessions, whatever the app's timing.
    func testAYesEndsAsking() {
        let storage = Fixtures.storage()
        configure(storage: storage)
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false))
        Contributions.answer(share: true)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
        XCTAssertNil(Contributions.askNow())
        configure(storage: storage)
        XCTAssertTrue(Contributions.isActive)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
    }

    /// SDK 4.0: every app shows the same sheet, and the learner's own tap on "Share" is the
    /// yes, recorded at once with the deck's consent version; nothing else is asked for.
    func testOneSheetForEveryAppAndTheLearnersTapIsTheYes() throws {
        let storage = Fixtures.storage()
        configure(storage: storage)
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false))
        Contributions.answer(share: true)
        XCTAssertEqual(Contributions.consent, .granted, "the learner's tap is the yes")
        XCTAssertEqual(Contributions.state().consentVersion, "share-2026-11-09")
        XCTAssertTrue(Contributions.isActive)
        // a state that 4.0 began has no `guardian` field (26.1 item 4: only a 3.x state's is passed through)
        let saved = try UnreadableStateTests.saved(storage)
        XCTAssertEqual(saved["consent"] as? String, "granted")
        XCTAssertNil(saved["guardian"], "a state begun by 4.0 has no guardian field")
    }

    func testTheBackendDecidesWhetherTheSheetIsOffered() async {
        // 2.0.1: Quran Lab's incident switch in the signed config decides; the app's option neither vetoes nor forces it
        configure(contributions: false)
        XCTAssertTrue(Contributions.isEnabled)
        Contributions.makeAskDue()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false), "offered by the config")
        XCTAssertFalse(Contributions.isActive, "offered is not consent")
        configure(contributions: true, flags: ["contributions": false])
        Contributions.makeAskDue()
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the config says no: the option cannot force it")
        StubProtocol.reset { _ in StubProtocol.Reply(status: 503) }
        configure(contributions: true, flags: nil)
        XCTAssertFalse(Contributions.isEnabled, "no verified config in force: nothing offered")
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["contributions": false])))
        configure()
        _ = await QuranLab.cloud?.refreshConfig()
        XCTAssertFalse(Contributions.isEnabled)
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["upload_trust": ["ios": "off", "macos": "off"]])))
        configure()
        _ = await QuranLab.cloud?.refreshConfig()
        XCTAssertFalse(Contributions.isEnabled)
    }

    func testTheBundledDeck() throws {
        let c = try XCTUnwrap(SharingCopy.bundled("en"))
        XCTAssertEqual(c.consentVersion, "share-2026-11-09")
        XCTAssertEqual(c.version, "2026-11-19.1")
        XCTAssertEqual(c.deleteDays, 0, "deletion is immediate")
        for k in ["sheet.title", "sheet.what", "sheet.who", "sheet.control", "sheet.share", "sheet.not_now", "thanks",
                  "settings.toggle", "settings.what", "settings.delete", "what.detail", "delete.confirm", "reask",
                  "delete.failed.title", "delete.failed.network", "delete.retry", "recovery.reveal",
                  "recovery.copy", "recovery.copied", "recovery.keep", "recovery.used", "recovery.invalid", "recovery.hint",
                  "card.line", "card.open", "card.not_now"] {
            XCTAssertFalse(c.string(k).isEmpty, k)
            XCTAssertFalse(c.string(k).contains("\u{2014}") || c.string(k).contains("\u{2013}"), "no em or en dash: \(k)")
        }
        XCTAssertFalse(c.string("delete.confirm").contains("{days}"))
        XCTAssertTrue(c.hadithVerified, "the shipped deck's hadith entry is verified")
        XCTAssertEqual(c.string("sheet.hadith_ref"), "Sahih Muslim 1631")
        XCTAssertEqual(c.impact(minutes: 1.7), "You have shared 1 minute of recitation. May Allah reward you.")
        for lang in ["ar", "bn", "fr", "id", "ms", "tr", "ur"] {
            let d = try XCTUnwrap(SharingCopy.bundled(lang), lang)
            XCTAssertEqual(d.consentVersion, c.consentVersion, lang)
            XCTAssertEqual(d.version, c.version, lang)
            // the plural lines differ by language (CLDR categories); every other key is in every deck
            let lines: (SharingCopy) -> Set<String> = { (x: SharingCopy) -> Set<String> in
                Set(x.keys.filter { (k: String) -> Bool in !k.hasPrefix("impact.minutes.") })
            }
            XCTAssertEqual(lines(d), lines(c), "every language has the same keys: \(lang)")
            XCTAssertFalse(d.string("sheet.what").isEmpty, lang)
        }
        XCTAssertTrue(try XCTUnwrap(SharingCopy.bundled("ar")).rightToLeft)
        XCTAssertEqual(SharingCopy.pluralCategory(3, lang: "ar"), "few")
        XCTAssertEqual(SharingCopy.forLocale(Locale(identifier: "xx_YY")).lang, "en")
    }

    /// "Delete what I shared": a challenge, the message signed with this device's key, no app credential; then a new
    /// contributor.
    func testDeleteSharedSignsTheChallengeWithTheDeviceKey() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/contributions/challenge" { return .json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300]) }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return nil
        }))
        configure()
        let key = try XCTUnwrap(ContributorKey.key(storage: QuranLab.configuration.storageDirectory))
        let code = Contributions.contributionCode
        try await Contributions.deleteShared()
        let seen = try XCTUnwrap(StubProtocol.seen("/v1/contributions/delete").first)
        XCTAssertNil(seen.headers["authorization"], "no app credential on the deletion")
        XCTAssertNil(seen.headers["x-qlab-key"])
        let body = try XCTUnwrap(seen.json)
        XCTAssertEqual(body["app"] as? String, "ios:com.example.quran")
        XCTAssertEqual(body["action"] as? String, "delete-all")
        let msg = ContributorKey.deletionMessage(app: "ios:com.example.quran", contributor: code, nonce: "d1.1794000000.AAAA.BBBB",
                                                 timestamp: try XCTUnwrap(body["timestamp"] as? Int))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: try XCTUnwrap(Data(base64URL: try XCTUnwrap(body["signature"] as? String))))
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: msg))
        XCTAssertNotEqual(Contributions.contributionCode, code, "a new contributor after a deletion")
        XCTAssertEqual(Contributions.consent, .final)
    }
}
