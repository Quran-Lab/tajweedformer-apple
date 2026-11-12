import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 2.0.1's consent sheet options: the app's own wording (the shared vector, the version and hash it derives, a
/// grant that keeps its version when the wording changes, the hash in every session JSON of such a grant and nowhere
/// else), the app's own UI (moments handed over, nothing captured before the grant), the theme, and withdrawal under
/// any version.
final class SharingWordingTests: XCTestCase {
    override func tearDown() {
        try? Contributions.setWording(nil)
        Contributions.setPresenter(nil)
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    func configure(audience: Audience = .general) {
        let storage = Fixtures.storage()
        CloudFixtures.seedConfig(storage: storage)
        var o = CloudFixtures.options(contributions: true, storage: storage)
        o.audience = audience
        o.sharingLocale = Locale(identifier: "en_US")
        let cloud = CloudFixtures.cloud(storage: storage, options: o)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: cloud)
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    // MARK: the shared vector

    /// consent_text.json: every case's canonical bytes, hash and version; every refused input refused, nothing changed.
    func testTheSharedConsentTextVector() throws {
        let v = try SharingBitrateTests.vector("consent_text.json")
        let deck = try XCTUnwrap(SharingCopy.bundled("en"))
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let name = (c["name"] as? String) ?? "?"
            XCTAssertEqual(c["base"] as? String, deck.baseConsentVersion, name)
            let overrides = try XCTUnwrap(c["overrides"] as? [String: String], name)
            let applied = deck.applying(overrides)
            XCTAssertEqual(applied.consentVersion, c["consent_version"] as? String, name)
            XCTAssertEqual(applied.consentTextSHA256, c["consent_text_sha256"] as? String, name)
            if let want = c["canonical_utf8_hex"] as? String {
                XCTAssertEqual(Self.hex(Data(try XCTUnwrap(applied.consentText).utf8)), want, name)
            } else {
                XCTAssertNil(applied.consentText, name)
            }
            // and through the public API
            try Contributions.setWording(overrides)
            XCTAssertEqual(Contributions.consentVersionInForce, c["consent_version"] as? String, name)
            XCTAssertEqual(Contributions.consentTextSHA256, c["consent_text_sha256"] as? String, name)
            for (k, text) in overrides where !k.hasPrefix("impact.") { XCTAssertEqual(Contributions.copy.string(k), text, name) }
        }
        let good = ["sheet.title": "Help other learners"]
        try Contributions.setWording(good)
        let refused = try XCTUnwrap(v["refused"] as? [[String: Any]])
        XCTAssertEqual(refused.count, 3)
        for r in refused {
            let o = try XCTUnwrap(r["overrides"] as? [String: String])
            do {
                try Contributions.setWording(o)
                XCTFail("accepted: \(String(describing: r["why"]))")
            } catch {
                guard case .invalidArgument = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(Contributions.wording, good, "a refused wording changes nothing")
        }
        try Contributions.setWording([:])
        XCTAssertEqual(Contributions.consentVersionInForce, deck.baseConsentVersion, "empty goes back to the deck's words")
        XCTAssertNil(Contributions.consentTextSHA256)
    }

    // MARK: the grant and the version

    /// Own wording changes the version in force, which a NEW grant records; a learner who agreed to the deck's words
    /// keeps sharing under them and is not asked again; a grant under the wording stores its version and hash and keeps
    /// them when the app goes back to the deck's words.
    func testCustomWordingChangesTheVersionANewGrantRecordsAndKeepsEarlierGrants() throws {
        configure()
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        Contributions.answer(share: true)
        XCTAssertTrue(Contributions.isActive)
        XCTAssertEqual(Contributions.state().consentVersion, "share-2026-11-12")
        XCTAssertNil(Contributions.state().consentTextSHA256)

        let mine = "The audio of your recitation sessions goes to Quran Lab, with the model version and device type."
        try Contributions.setWording(["sheet.what": mine])
        XCTAssertTrue(Contributions.consentVersionInForce.hasPrefix("custom-"))
        XCTAssertEqual(Contributions.consentVersionInForce.count, 31)
        XCTAssertEqual(Contributions.copy.string("sheet.what"), mine, "the sheet shows the app's words")
        XCTAssertTrue(Contributions.isActive, "a wording change does not pause a grant")
        XCTAssertNotNil(Contributions.capture(revision: "r", backend: .exact, weightsSHA256: nil))
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "never asked again") }
        XCTAssertEqual(Contributions.state().consentVersion, "share-2026-11-12", "the version agreed to")
        XCTAssertNil(Contributions.grantedTextSHA256)

        // another install agrees under the app's words
        configure()
        try Contributions.setWording(["sheet.what": mine])
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        Contributions.answer(share: true)
        XCTAssertEqual(Contributions.state().consentVersion, Contributions.consentVersionInForce)
        XCTAssertEqual(Contributions.state().consentTextSHA256, Contributions.consentTextSHA256)
        XCTAssertEqual(Contributions.grantedTextSHA256?.count, 64)
        let version = Contributions.consentVersionInForce
        try Contributions.setWording(nil)
        XCTAssertTrue(Contributions.isActive, "back to the deck's words: the grant stays")
        XCTAssertEqual(Contributions.consentVersion, version)
        XCTAssertEqual(Contributions.grantedTextSHA256?.count, 64)
        for _ in 0..<30 { XCTAssertNil(Contributions.sessionCompleted(feedback: true)) }
    }

    /// A session after a grant under the app's wording carries consent_version custom-... and consent_text_sha256; a
    /// session under the deck's words carries no hash.
    func testTheSessionJSONCarriesTheHashOnlyForCustomWording() async throws {
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let options = CloudFixtures.options(contributions: true, storage: storage)
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        _ = await cloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        try Contributions.setWording(["sheet.title": "Share your recitation with Quran Lab", "sheet.share": "Share"])
        Contributions.answer(share: true)
        let hash = try XCTUnwrap(Contributions.consentTextSHA256)
        try await share(seconds: 1)
        let first = try await settled(cloud.outbox, count: 1)
        XCTAssertEqual(first.count, 1)
        let custom = try XCTUnwrap(SharingTests.starts.last?.json)
        XCTAssertEqual(custom["consent_version"] as? String, "custom-" + String(hash.prefix(24)))
        XCTAssertEqual(custom["consent_text_sha256"] as? String, hash)
        XCTAssertEqual(Set(custom.keys), ["format", "audio", "decode", "consent_version", "consent_text_sha256", "contributor", "day",
                                          "device_class", "os_major", "contributor_key", "recovery_hash"])

        // a learner who agreed to the deck's words (another install) sends no hash
        try Contributions.setWording(nil)
        let other = CloudFixtures.storage()
        let otherCloud = CloudFixtures.cloud(storage: other, options: CloudFixtures.options(contributions: true, storage: other))
        _ = await otherCloud.refreshConfig()
        QuranLab.configure(key: CloudFixtures.key, options: CloudFixtures.options(contributions: true, storage: other), cloud: otherCloud)
        Contributions.answer(share: true)
        try await share(seconds: 1)
        _ = try await settled(otherCloud.outbox, count: 1)
        let plain = try XCTUnwrap(SharingTests.starts.last?.json)
        XCTAssertEqual(SharingTests.starts.count, 2)
        XCTAssertEqual(plain["consent_version"] as? String, "share-2026-11-12")
        XCTAssertNil(plain["consent_text_sha256"], "no hash without the app's own wording (a 2.0.0 server refuses unknown fields)")
    }

    func share(seconds: Double) async throws {
        let c = try XCTUnwrap(Contributions.capture(revision: "test-rev", backend: .exact, weightsSHA256: nil))
        let n = Int(48_000 * seconds)
        var at = 0
        while at < n {
            let k = min(4_800, n - at)
            try c.append(SharingTests.audio(k, seed: at + 1), rate: 48_000)
            at += k
        }
        c.finish(completed: true)
    }

    func settled(_ outbox: ContributionOutbox, count: Int) async throws -> [Contribution] {
        let start = Date()
        while Date().timeIntervalSince(start) < 15 {
            let items = await outbox.items
            if items.count == count, items.allSatisfy({ $0.status == .uploaded }) { return items }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let items = await outbox.items
        XCTFail("outbox did not settle: \(items)")
        return items
    }

    // MARK: the app's own UI

    /// With a presenter the SDK hands the moment to the app (and shows nothing itself); the asks are counted and the
    /// re-ask rules hold; nothing is captured until the app reports the learner's tap.
    func testTheAppsOwnUIGetsTheMomentAndNothingIsCapturedBeforeTheGrant() async throws {
        configure()
        try Contributions.setWording(["sheet.title": "Help the next learner"])
        let seen = Locked<[SharingMoment]>([])
        Contributions.setPresenter { (m: SharingMoment) in seen.withLock { $0.append(m) } }
        XCTAssertNil(Contributions.sessionCompleted(feedback: false))
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: false, guardian: false))
        let start = Date()
        while seen.withLock({ $0.isEmpty }) && Date().timeIntervalSince(start) < 5 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(seen.withLock { $0 }, [.ask(reask: false, guardian: false)], "the app's handler got the ask")
        XCTAssertEqual(Contributions.state().asks, 1, "counted like the SDK's sheet")
        XCTAssertEqual(Contributions.copy.string("sheet.title"), "Help the next learner", "the strings the app shows")
        XCTAssertFalse(Contributions.isActive)
        XCTAssertNil(Contributions.capture(revision: "r", backend: .exact, weightsSHA256: nil), "offered is not consent")
        Contributions.answer(share: false)
        XCTAssertEqual(Contributions.consent, .declined)
        for _ in 0..<6 { XCTAssertNil(Contributions.sessionCompleted(feedback: true), "the re-ask waits 7 sessions") }
        XCTAssertEqual(Contributions.sessionCompleted(feedback: true), .ask(reask: true, guardian: false))
        Contributions.answer(share: true)
        XCTAssertTrue(Contributions.isActive)
        XCTAssertNotNil(Contributions.capture(revision: "r", backend: .exact, weightsSHA256: nil))
    }

    #if canImport(SwiftUI)
    /// The theme changes how the sheets look, never the version the learner agrees to.
    func testTheThemeDoesNotChangeTheConsentVersion() {
        configure()
        let before = Contributions.consentVersionInForce
        let saved = Contributions.theme
        defer { Contributions.theme = saved }
        Contributions.theme = SharingTheme(cornerRadius: 4)
        XCTAssertEqual(Contributions.theme.cornerRadius, 4)
        XCTAssertEqual(Contributions.consentVersionInForce, before)
        XCTAssertNil(Contributions.consentTextSHA256)
    }
    #endif

    // MARK: withdrawal

    /// The settings switch and "Delete what I shared" work under a custom version as under the deck's.
    func testWithdrawalAndDeleteUnderACustomVersion() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/contributions/challenge" { return .json(["nonce": "d1.1794000000.AAAA.BBBB", "expires_in": 300]) }
            if s.path == "/v1/contributions/delete" { return .json(["ok": true], status: 202) }
            return nil
        }))
        configure()
        try Contributions.setWording(["sheet.control": "Stop or delete any time in the settings."])
        Contributions.answer(share: true)
        XCTAssertTrue(Contributions.isActive)
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertFalse(Contributions.isActive)
        await Contributions.setSharing(true)
        XCTAssertTrue(Contributions.isActive, "the settings switch grants under the version in force")
        XCTAssertEqual(Contributions.state().consentVersion, Contributions.consentVersionInForce)
        _ = ContributorKey.key(storage: QuranLab.configuration.storageDirectory)
        let code = Contributions.contributionCode
        try await Contributions.deleteShared()
        XCTAssertEqual(StubProtocol.seen("/v1/contributions/delete").count, 1)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertNotEqual(Contributions.contributionCode, code)
        // a grant to an older wording keeps sharing after the wording changed, and can still be withdrawn
        try Contributions.setWording(nil)
        await Contributions.setSharing(true)
        try Contributions.setWording(["sheet.title": "New words"])
        XCTAssertTrue(Contributions.isActive)
        XCTAssertEqual(Contributions.state().consentVersion, "share-2026-11-12")
        await Contributions.setSharing(false)
        XCTAssertEqual(Contributions.consent, .final)
        XCTAssertFalse(Contributions.isActive)
    }
}
