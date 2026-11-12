import Foundation
import XCTest
@testable import TajweedFormer

/// The copy deck from SDK 3.1.0 (SPEC 11.8): deck `2026-11-12.1`, consent version `share-2026-11-12`. Its one
/// change: the line about who receives the recordings (`sheet.who`) and "What is shared" (`what.detail`) say, in
/// every language, that no human ever listens to the learner's recordings and that only software learns from them.
/// Here: the bundled decks are the published ones byte for byte, and the sheet shows those two texts whole in each
/// of the eight languages. That a learner who already agreed is not asked again and keeps their version is in
/// `SharingConsentPersistTests`.
final class SharingDeckTests: XCTestCase {
    override func tearDown() {
        try? Contributions.setWording(nil)
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The SHA-256 of each published deck (the contract's `sharing_copy/READY`, deck 2026-11-12.1).
    static let published: [String: String] = [
        "en": "1600ab0625db9dab1483d1a2bfd0f0ec9e0e636880909a2d47df2eb7fefd52c0",
        "ar": "b8a3402a262ac0f295af5e485ae99804fcbab0dde44f403dc9f38e1bc18be5f0",
        "id": "8d32f968b66b6b9176a3e2c152c69903a96fa20601d53f47d23cf3d20edba4f5",
        "ms": "78bd9055b9c3f1ffa05efee1a15778897ee27f7d15aa1887142682d80f21848c",
        "tr": "258a04a68c4e4d44739ca73da170a052cdb2a2f41914e5067314982190e0b9d9",
        "fr": "aba381efd20462db4864e8328b9a2f231597ffbffac7f42096b89e59e0950be2",
        "ur": "6d50705ea642f30711207b7093337a15cb7afba5d12b5c4d80bf0fe7e192c1d1",
        "bn": "56225ba6ebe642793b288d13b82874f9ada8184df8e83ea679aac3ca28a01acb",
    ]

    /// The folder of the bundled decks, as the SDK reads it.
    static func decks() throws -> URL {
        try XCTUnwrap(SDKResources.bundle.url(forResource: "SharingCopy", withExtension: nil), "the decks are not in the bundle")
    }

    /// The strings of a bundled deck, read from its file without the SDK's own reader.
    static func strings(_ lang: String) throws -> [String: Any] {
        let data = try Data(contentsOf: decks().appendingPathComponent("\(lang).json"))
        let deck = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], lang)
        return try XCTUnwrap(deck["strings"] as? [String: Any], lang)
    }

    /// The eight bundled decks are the published ones, byte for byte, and nothing else is in the folder.
    func testTheBundledDecksAreThePublishedOnesByteForByte() throws {
        XCTAssertEqual(Self.published.keys.sorted(), SharingCopy.bundledLanguages.sorted())
        XCTAssertEqual(Self.published.count, 8)
        let dir = try Self.decks()
        for lang in SharingCopy.bundledLanguages {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(lang).json"))
            XCTAssertEqual(Manifest30VectorTests.sha256(data), Self.published[lang], "\(lang).json")
            let deck = try XCTUnwrap(SharingCopy.bundled(lang), lang)
            XCTAssertEqual(deck.version, "2026-11-12.1", lang)
            XCTAssertEqual(deck.consentVersion, "share-2026-11-12", lang)
            XCTAssertEqual(deck.baseConsentVersion, "share-2026-11-12", lang)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), SharingCopy.bundledLanguages.map { $0 + ".json" }.sorted())
    }

    /// The sheet in each of the eight languages shows the deck's `sheet.who` whole, word for word, and "What is
    /// shared" shows `what.detail` whole. The sheet is built from the deck in force (`Contributions.copy`): each of
    /// its lines is `copy.string(key)`, drawn as one text that is never cut, and the settings view draws
    /// `Contributions.whatIsShared`. So: for each language the strings the sheet is handed are the deck file's own,
    /// and the sheet's source draws them.
    func testTheSheetShowsWhoReceivesTheRecordingsWholeInEveryLanguage() throws {
        for lang in SharingCopy.bundledLanguages {
            let strings = try Self.strings(lang)
            let who = try XCTUnwrap(strings["sheet.who"] as? String, lang)
            let detail = try XCTUnwrap(strings["what.detail"] as? String, lang)
            XCTAssertFalse(who.isEmpty, lang)
            XCTAssertFalse(detail.isEmpty, lang)
            // an app whose learner reads this language
            let storage = Fixtures.storage()
            CloudFixtures.seedConfig(storage: storage)
            var o = CloudFixtures.options(contributions: true, storage: storage)
            o.sharingLocale = Locale(identifier: lang)
            QuranLab.configure(key: CloudFixtures.key, options: o, cloud: CloudFixtures.cloud(storage: storage, options: o))
            let copy = Contributions.copy
            XCTAssertEqual(copy.lang, lang, "the deck in force")
            XCTAssertEqual(copy.string("sheet.who"), who, "\(lang): the sheet's line is the deck's, whole")
            XCTAssertEqual(copy.string("what.detail"), detail, "\(lang): what is shared")
            XCTAssertEqual(Contributions.whatIsShared, [detail], "\(lang): the lines behind \"What is shared\"")
            XCTAssertEqual(Contributions.consentVersionInForce, "share-2026-11-12", lang)
        }
        // the sentence itself, in the English deck: in the line about who receives the recordings, and in the detail
        let sentence = "No human ever listens to your recordings: only software learns from them."
        let en = try Self.strings("en")
        XCTAssertTrue((en["sheet.who"] as? String)?.hasSuffix(sentence) ?? false, "\(String(describing: en["sheet.who"]))")
        XCTAssertTrue((en["what.detail"] as? String)?.contains(sentence) ?? false)
        // the sheet draws the line in every variant (the learner's and the guardian's are one body), as a text that
        // grows with its words and is never cut; the settings view draws the detail
        let ui = Fixtures.repo.appendingPathComponent("Sources/TajweedFormer/Sharing/ConsentUI.swift")
        guard let source = try? String(contentsOf: ui, encoding: .utf8) else { throw XCTSkip("the sources are not in this checkout") }
        XCTAssertTrue(source.contains("line(\"sheet.who\")"), "the consent sheet draws sheet.who")
        XCTAssertTrue(source.contains("let t = copy.string(key)"), "a line of the sheet is the deck's string for its key")
        XCTAssertTrue(source.contains("private let copy = Contributions.copy"), "the sheet's deck is the one in force")
        XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"), "a line takes the height its words need")
        XCTAssertFalse(source.contains("lineLimit"), "no line of the sheet is cut")
        XCTAssertFalse(source.contains("truncationMode"))
        XCTAssertTrue(source.contains("ForEach(Contributions.whatIsShared"), "the settings view draws what.detail")
    }
}
