import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The sharing state machine every TajweedFormer SDK follows: never before a finished session with feedback, the
/// first ask plus at most two re-asks 7 sessions apart, then never; the guardian variant; settings off is final; the
/// thank-you once; the bundled copy deck and its disclosure lines.
final class SharingConsentTests: XCTestCase {
    func configure(contributions: Bool = true, audience: Audience = .general) {
        let storage = Fixtures.storage()
        var o = CloudFixtures.options(contributions: contributions, storage: storage)
        o.audience = audience
        let cloud = CloudFixtures.cloud(storage: storage, options: o)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: cloud)
    }

    override func tearDown() { QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil) }

    func testAskOnceThenTwoReasksSevenSessionsApartThenNever() {
        configure()
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
        XCTAssertFalse(Contributions.isActive)
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
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "turned off in settings: never asked again")
    }

    func testChildrenNeedTheGuardian() {
        configure(audience: .children)
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: true))
        Contributions.answer(share: true, guardianConfirmed: false)
        XCTAssertNotEqual(Contributions.consent, .granted, "no grant without the guardian's confirmation")
        Contributions.answer(share: true, guardianConfirmed: true)
        XCTAssertEqual(Contributions.consent, .granted)
    }

    func testTheDeveloperSwitchAndTheConfigFlag() async {
        configure(contributions: false)
        XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the option is off: never ask")
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
        XCTAssertEqual(c.consentVersion, "share-2026-11-07b")
        for k in ["sheet.title", "sheet.what", "sheet.who", "sheet.control", "sheet.share", "sheet.not_now", "thanks",
                  "settings.toggle", "settings.what", "settings.delete", "what.detail", "delete.confirm", "reask",
                  "sheet.guardian.confirm"] {
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
