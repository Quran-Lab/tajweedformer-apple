import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The sharing state machine every TajweedFormer SDK follows: never before a finished session with feedback, the
/// sheet shown at most three times per install (the first ask plus re-asks 7 sessions apart after "Not now"), the
/// count kept across launches and the upgrade from 2.0.0; a yes or settings off ends asking; the guardian variant; the
/// thank-you once; the bundled copy deck and its disclosure lines.
final class SharingConsentTests: XCTestCase {
    func configure(contributions: Bool = true, audience: Audience = .general, flags: [String: Any]? = [:],
                   storage: URL = Fixtures.storage()) {
        if let flags { CloudFixtures.seedConfig(storage: storage, flags: flags) }
        var o = CloudFixtures.options(contributions: contributions, storage: storage)
        o.audience = audience
        let cloud = CloudFixtures.cloud(storage: storage, options: o)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: cloud)
    }

    override func tearDown() { QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil) }

    func testAskOnceThenTwoReasksSevenSessionsApartThenNever() {
        let storage = Fixtures.storage()
        configure(storage: storage)
        XCTAssertNil(Contributions.sessionCompleted(feedback: false), "no feedback, no ask")
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        Contributions.answer(share: false)
        XCTAssertEqual(Contributions.consent, .declined)
        var asks: [Int] = []
        for i in 3...40 {
            if case .ask(let reask, _)? = Contributions.sessionCompleted(feedback: true) {
                XCTAssertTrue(reask)
                asks.append(i)
                Contributions.answer(share: false)
            }
        }
        XCTAssertEqual(asks, [9, 16], "re-asks at least 7 sessions apart, at most twice")
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertEqual(Contributions.state().asks, 3, "three sheets in all")
        XCTAssertFalse(Contributions.isActive)
        XCTAssertNil(Contributions.askNow(), "no fourth sheet at the app's own timing")
        // a restart: the count is read back from disk
        configure(storage: storage)
        XCTAssertEqual(Contributions.state().asks, 3)
        for i in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "no fourth sheet after a restart (\(i))") }
        XCTAssertNil(Contributions.askNow())
    }

    /// The third "Not now" ends asking even when the asks came from the app's own timing; a sheet closed without an
    /// answer counts as shown.
    func testThreeShowingsInAllWhateverTheTiming() {
        let storage = Fixtures.storage()
        configure(storage: storage)
        XCTAssertEqual(Contributions.askNow(), .ask(reask: false, guardian: false))
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "closed without an answer: the re-ask waits 7 sessions")
        XCTAssertEqual(Contributions.askNow(), .ask(reask: true, guardian: false))
        Contributions.answer(share: false)
        XCTAssertEqual(Contributions.askNow(), .ask(reask: true, guardian: false))
        Contributions.answer(share: false)
        XCTAssertEqual(Contributions.consent, .final)
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
        for _ in 13...16 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "7 sessions after the last ask") }
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: true, guardian: false), "the third and last")
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
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        Contributions.answer(share: true)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
        XCTAssertNil(Contributions.askNow())
        configure(storage: storage)
        XCTAssertTrue(Contributions.isActive)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
    }

    func testChildrenNeedTheGuardian() {
        configure(audience: .children)
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: true))
        Contributions.answer(share: true, guardianConfirmed: false)
        XCTAssertNotEqual(Contributions.consent, .granted, "no grant without the guardian's confirmation")
        Contributions.answer(share: true, guardianConfirmed: true)
        XCTAssertEqual(Contributions.consent, .granted)
    }

    func testTheBackendDecidesWhetherTheSheetIsOffered() async {
        // 2.0.1: the signed config decides; the app's option neither vetoes nor forces it
        configure(contributions: false)
        XCTAssertTrue(Contributions.isEnabled)
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false), "offered by the config")
        XCTAssertFalse(Contributions.isActive, "offered is not consent")
        configure(contributions: true, flags: ["contributions": false])
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
        XCTAssertEqual(c.version, "2026-11-09.1")
        XCTAssertEqual(c.deleteDays, 0, "deletion is immediate")
        for k in ["sheet.title", "sheet.what", "sheet.who", "sheet.control", "sheet.share", "sheet.not_now", "thanks",
                  "settings.toggle", "settings.what", "settings.delete", "what.detail", "delete.confirm", "reask",
                  "sheet.guardian.confirm", "delete.failed.title", "delete.failed.network", "delete.retry", "recovery.reveal",
                  "recovery.copy", "recovery.copied", "recovery.keep", "recovery.used", "recovery.invalid", "recovery.hint"] {
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
