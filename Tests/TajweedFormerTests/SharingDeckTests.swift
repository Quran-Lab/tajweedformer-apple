import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The copy deck SDK 3.1.2 bundles (SPEC 11.8): deck `2026-11-13.1`, consent version `share-2026-11-09`. Every
/// string is that of deck `2026-11-09.1`: the sentence that deck `2026-11-12.1` (SDK 3.1.0 and 3.1.1) added to
/// `sheet.who` and to `what.detail` is not in it. SDK 4.0 bundles deck `2026-11-19.1`: those strings and the re-ask
/// card's three (SHARE_ASK_40 20.7, from 2026-11-15.1), without the four `sheet.guardian` strings (one sheet for every
/// app, contract section 26), the same consent version. Here: the bundled decks are the published ones byte for byte;
/// the sheet shows `sheet.who` and "What is shared" whole in each of the eight languages; and no text the sheet is
/// built from, or that an app is handed to show, holds the sentence that deck 2026-11-12.1 added, in any of them.
/// That sentence is not written in this repository: the test knows its length and its SHA-256 per language
/// (`Fixtures/deck_removed/2026-11-12.1.json`, made by `scripts/make_deck_removed_hashes.py` from the published
/// decks) and looks for a stretch of that length with that hash. That a learner who already agreed is not asked
/// again and keeps their version is in `SharingConsentPersistTests`.
final class SharingDeckTests: XCTestCase {
    override func tearDown() {
        try? Contributions.setWording(nil)
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The SHA-256 of each published deck (the contract's `sharing_copy/READY`, deck 2026-11-19.1: the strings of
    /// 2026-11-15.1 without the four `sheet.guardian` strings, contract sdk-4.0.0-protected dac6627, unchanged at 3c62bf3).
    static let published: [String: String] = [
        "en": "4011ed13cb1683348cc2d26c8b5a6adf96ebeb4bc5143cb77eb72104d5992d21",
        "ar": "1159dff6482b974798d46686855c0ff0b90293f4ee7bc9890b17c76596cfc474",
        "id": "ddd02973988f286e007a9fc5e0a979b16766c43cb6d276a64ea7b59c7f17483f",
        "ms": "502835016af3430f898b669cb986ac87cbec4aa89fc10849ea33fe1226d93bcb",
        "tr": "faabab1693a40f2f9c12a94808e0d7840e66094c3cf32db1bf1695fee48008f0",
        "fr": "03b2026cef95cc4707a841d53e08596fa18af343c9e33ee57feffd373b8411f7",
        "ur": "9dec0fd78c867a08aac9a641849ab628b441f2dae88102392b1855f9931aee05",
        "bn": "ef6ebcac7798a5e3f2c6c6bc930518e1d7290b2a29821dc83865e7c3249ef949",
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

    /// An app whose learner reads `lang`: the deck in force is that language's.
    func configure(_ lang: String) {
        let storage = Fixtures.storage()
        CloudFixtures.seedConfig(storage: storage)
        var o = CloudFixtures.options(contributions: true, storage: storage)
        o.sharingLocale = Locale(identifier: lang)
        QuranLab.configure(key: CloudFixtures.key, options: o, cloud: CloudFixtures.cloud(storage: storage, options: o))
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
            XCTAssertEqual(deck.version, "2026-11-19.1", lang)
            XCTAssertEqual(deck.consentVersion, "share-2026-11-09", lang)
            XCTAssertEqual(deck.baseConsentVersion, "share-2026-11-09", lang)
            XCTAssertEqual(deck.keys.filter { $0.hasPrefix("sheet.guardian") }, [], "\(lang): no sheet.guardian key (26.1 item 5)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), SharingCopy.bundledLanguages.map { $0 + ".json" }.sorted())
    }

    /// Every bundled deck has the re-ask card's three lines (SHARE_ASK_40 20.7, deck 2026-11-15.1), so the SDK shows
    /// the card itself and never the 3.x re-ask sheet in its place: `card.line` is the deck's `reask` without its
    /// question, its "Not now" is the sheet's word for word, its button is no longer than the sheet's share button,
    /// no dash, and none of the three is blank or a disclosure line an app may not reword.
    func testEveryDeckHasTheCardsLines() throws {
        let en = try XCTUnwrap(SharingCopy.bundled("en"))
        XCTAssertEqual(en.string("card.line"), "Your recitation today could help another learner tomorrow.")
        XCTAssertEqual(en.string("card.open"), "See how it helps")
        XCTAssertEqual(en.string("card.not_now"), "Not now")
        for lang in SharingCopy.bundledLanguages {
            let deck = try XCTUnwrap(SharingCopy.bundled(lang), lang)
            for k in ["card.line", "card.open", "card.not_now"] {
                let s = deck.string(k)
                XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(lang) \(k): in the deck")
                XCTAssertFalse(s.contains("\u{2014}") || s.contains("\u{2013}"), "\(lang) \(k): no em or en dash")
                XCTAssertTrue(SharingCopy.allKeys.contains(k), "\(k): a deck key an app may give its own words for")
            }
            XCTAssertEqual(deck.string("card.not_now"), deck.string("sheet.not_now"), "\(lang): the card's Not now is the sheet's")
            XCTAssertLessThanOrEqual(deck.string("card.open").unicodeScalars.count, deck.string("sheet.share").unicodeScalars.count, lang)
            // the reviewed re-ask's first sentence, byte for byte; what follows it is the question (? or the Arabic
            // question mark U+061F)
            let reask = deck.string("reask"), line = deck.string("card.line")
            XCTAssertTrue(reask.hasPrefix(line + " "), "\(lang): card.line is reask without its question")
            let question = reask.dropFirst(line.count + 1)
            XCTAssertTrue(question.hasSuffix("?") || question.hasSuffix("\u{061F}"), "\(lang): what reask adds is a question")
        }
    }

    /// The card's lines of each language are the contract's reviewed translations of deck 2026-11-15.1
    /// (`sharing_copy/translations/card_2026-11-15.json`, copied into Fixtures/sharing_copy), the English the source.
    func testTheCardsLinesAreTheReviewedTranslations() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "sharing_copy", withExtension: nil, subdirectory: "Fixtures"))
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("card_2026-11-15.json")))
            as? [String: Any])
        let source = try XCTUnwrap(file["source"] as? [String: String])
        let languages = try XCTUnwrap(file["languages"] as? [String: Any])
        XCTAssertEqual(Set(languages.keys).union(["en"]), Set(SharingCopy.bundledLanguages))
        for lang in SharingCopy.bundledLanguages {
            let deck = try XCTUnwrap(SharingCopy.bundled(lang), lang)
            let reviewed: [String: Any] = try lang == "en" ? source as [String: Any] : XCTUnwrap(languages[lang] as? [String: Any], lang)
            XCTAssertEqual(deck.string("card.line"), reviewed["card.line"] as? String, "\(lang): card.line")
            XCTAssertEqual(deck.string("card.open"), reviewed["card.open"] as? String, "\(lang): card.open")
            if lang != "en" { XCTAssertEqual(reviewed["line_is_reask_first_sentence"] as? Bool, true, lang) }
        }
        XCTAssertEqual(source["card.not_now"], "Not now")
    }

    /// The card's lines are deck strings like any other (20.7): an app may give its own words for one, which then
    /// enter its custom consent text and version as every overridden key does; it cannot blank one, so the card
    /// always has its three lines. The deck's own consent version is unchanged by the card.
    func testAnAppsOwnWordsForTheCard() throws {
        configure("en")
        XCTAssertEqual(Contributions.consentVersionInForce, "share-2026-11-09")
        try Contributions.setWording(["card.open": "Learn more"])
        XCTAssertEqual(Contributions.copy.string("card.open"), "Learn more")
        XCTAssertTrue(Contributions.consentVersionInForce.hasPrefix("custom-"))
        XCTAssertEqual(Contributions.consentText, "quranlab.consent-text/1\nbase share-2026-11-09\ncard.open\tLearn more\n")
        for blank in ["", "   "] {
            XCTAssertThrowsError(try Contributions.setWording(["card.line": blank]), "a blank card line is refused")
        }
        XCTAssertEqual(Contributions.wording, ["card.open": "Learn more"], "a refused wording changes nothing")
        try Contributions.setWording(nil)
        XCTAssertEqual(Contributions.consentVersionInForce, "share-2026-11-09")
    }

    /// The sheet in each of the eight languages shows the deck's `sheet.who` whole, word for word, and "What is
    /// shared" shows `what.detail` whole. The sheet is built from the deck in force (`Contributions.copy`): each of
    /// its lines is the deck's string for its key, and the settings view shows `Contributions.whatIsShared`. So:
    /// for each language the strings the sheet is handed are the deck file's own. (Checked on the strings the sheet
    /// is built from, not on a drawn sheet.)
    func testTheSheetShowsWhoReceivesTheRecordingsWholeInEveryLanguage() throws {
        for lang in SharingCopy.bundledLanguages {
            let strings = try Self.strings(lang)
            let who = try XCTUnwrap(strings["sheet.who"] as? String, lang)
            let detail = try XCTUnwrap(strings["what.detail"] as? String, lang)
            XCTAssertFalse(who.isEmpty, lang)
            XCTAssertFalse(detail.isEmpty, lang)
            configure(lang)
            let copy = Contributions.copy
            XCTAssertEqual(copy.lang, lang, "the deck in force")
            XCTAssertEqual(copy.string("sheet.who"), who, "\(lang): the sheet's line is the deck's, whole")
            XCTAssertEqual(copy.string("what.detail"), detail, "\(lang): what is shared")
            XCTAssertEqual(Contributions.whatIsShared, [detail], "\(lang): the lines behind \"What is shared\"")
            XCTAssertEqual(Contributions.consentVersionInForce, "share-2026-11-09", lang)
        }
    }

    // MARK: the sentence that deck 2026-11-12.1 added

    /// A stretch of text known by its length in UTF-8 bytes and its SHA-256.
    struct Stretch {
        let bytes: Int
        let sha256: Data
    }

    /// Whether `text` holds a stretch of `stretch.bytes` UTF-8 bytes whose SHA-256 is `stretch.sha256`: a window of
    /// that length is slid over the text's bytes, one byte at a time.
    static func holds(_ text: String, _ stretch: Stretch) -> Bool {
        let utf8 = Array(text.utf8)
        guard stretch.bytes > 0, utf8.count >= stretch.bytes else { return false }
        for start in 0...(utf8.count - stretch.bytes) {
            if Data(SHA256.hash(data: Data(utf8[start..<(start + stretch.bytes)]))) == stretch.sha256 { return true }
        }
        return false
    }

    static func data(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(byte)
            i = j
        }
        return out
    }

    /// The length and SHA-256 of the sentence that deck 2026-11-12.1 added, per language and key.
    static func removed() throws -> [String: [String: Stretch]] {
        let file = Fixtures.repo.appendingPathComponent("Tests/TajweedFormerTests/Fixtures/deck_removed/2026-11-12.1.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "quranlab.sdk-deck-removed/1")
        XCTAssertEqual(root["deck"] as? String, "2026-11-12.1")
        let languages = try XCTUnwrap(root["languages"] as? [String: [String: [String: Any]]])
        var out: [String: [String: Stretch]] = [:]
        for (lang, keys) in languages {
            for (key, entry) in keys {
                let bytes = try XCTUnwrap(entry["bytes"] as? Int, "\(lang) \(key)")
                let hex = try XCTUnwrap(entry["sha256"] as? String, "\(lang) \(key)")
                let hash = try XCTUnwrap(Self.data(hex: hex), "\(lang) \(key)")
                XCTAssertEqual(hash.count, 32, "\(lang) \(key)")
                out[lang, default: [:]][key] = Stretch(bytes: bytes, sha256: hash)
            }
        }
        return out
    }

    /// The search itself finds a stretch it is given, wherever it stands in a text and in any script, and finds
    /// none when one byte differs. (A sentence made up for this test.)
    func testTheSearchFindsAStretchByItsLengthAndHash() {
        for sentence in ["A sentence made up for this test.", "Une phrase inventée pour ce test, à dessein.", "\u{0986}\u{09AE}\u{09BE}\u{09B0} \u{09AC}\u{09BE}\u{0995}\u{09CD}\u{09AF}"] {
            let bytes = Data(sentence.utf8)
            let stretch = Stretch(bytes: bytes.count, sha256: Data(SHA256.hash(data: bytes)))
            XCTAssertTrue(Self.holds(sentence, stretch), "alone")
            XCTAssertTrue(Self.holds("Before it. " + sentence + " And after it.", stretch), "in the middle")
            XCTAssertTrue(Self.holds("Before it. " + sentence, stretch), "at the end")
            XCTAssertFalse(Self.holds("Before it. " + String(sentence.dropLast()) + "! And after it.", stretch), "one character differs")
            XCTAssertFalse(Self.holds(String(sentence.dropLast()), stretch), "shorter than the stretch")
            XCTAssertFalse(Self.holds("", stretch))
        }
    }

    /// Nothing that is shown, or handed to an app to show, holds the sentence that deck 2026-11-12.1 added, in any
    /// of the eight languages: every string of the deck in force (what the SDK's sheet and settings show, and what
    /// an app's own screen is handed), the plural lines, and the lines behind "What is shared". The same search
    /// over the decks of 2026-11-12.1 finds the sentence in all eight languages (shown with the script's `--check`,
    /// not by a test here: those decks are not in this repository).
    func testNothingShownHoldsTheSentenceThatTheEarlierDeckAdded() throws {
        let removed = try Self.removed()
        XCTAssertEqual(removed.keys.sorted(), SharingCopy.bundledLanguages.sorted())
        for lang in SharingCopy.bundledLanguages {
            let stretches = try XCTUnwrap(removed[lang], lang)
            XCTAssertEqual(stretches.keys.sorted(), ["sheet.who", "what.detail"], lang)
            XCTAssertTrue(stretches.values.allSatisfy { $0.bytes > 10 }, lang)
            configure(lang)
            let copy = Contributions.copy
            XCTAssertEqual(copy.lang, lang)
            var shown = Contributions.whatIsShared
            for key in copy.keys { shown.append(copy.string(key)) }
            for forms in copy.plurals.values { shown.append(contentsOf: forms.values) }
            shown.append(copy.impact(minutes: 1))
            shown.append(copy.impact(minutes: 12))
            XCTAssertTrue(shown.contains(copy.string("sheet.who")), lang)
            XCTAssertTrue(shown.contains(copy.string("what.detail")), lang)
            XCTAssertGreaterThan(shown.filter { !$0.isEmpty }.count, 20, lang)
            for (key, stretch) in stretches {
                for text in shown {
                    XCTAssertFalse(Self.holds(text, stretch), "\(lang): a shown text holds the sentence that the earlier deck added to \(key)")
                }
            }
        }
    }
}
