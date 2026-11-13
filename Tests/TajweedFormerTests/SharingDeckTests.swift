import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The copy deck SDK 3.1.2 bundles (SPEC 11.8): deck `2026-11-13.1`, consent version `share-2026-11-09`. Every
/// string is that of deck `2026-11-09.1`: the sentence that deck `2026-11-12.1` (SDK 3.1.0 and 3.1.1) added to
/// `sheet.who` and to `what.detail` is not in it. Here: the bundled decks are the published ones byte for byte;
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

    /// The SHA-256 of each published deck (the contract's `sharing_copy/READY`, deck 2026-11-13.1).
    static let published: [String: String] = [
        "en": "3bac94a18f4691e7fb51021e9aa4f241d409a6dc4f8f89ec22a82761ebd75051",
        "ar": "03fc6aa2eed9134b5b5780ba2abcc5590c043024d0c6daf829c876742519f599",
        "id": "f0621036f69d8f3754a0dfffea58b6c99e13a22c8356ba4cece0b20c3ba9abd0",
        "ms": "2c15cf8515885ef1bebe59117c61926dfd93ce406100fe2434e4b10d6c8e3e9d",
        "tr": "227783a34b2fdf6870ebd5d32eafb9e3ebcf496bed44797de87b571744200099",
        "fr": "9895b3eaf3e67afa250629b9ea3d93613d0298168d068fb6aba2e00450dda7ca",
        "ur": "755e2b9873180336b7e06bb44c0a9910441d8ee59dced42142c8f420ae77875a",
        "bn": "e6b0a844386437838adcd0c3693ae39f93d40e5c3dba3b614c7f71574028a6b6",
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
            XCTAssertEqual(deck.version, "2026-11-13.1", lang)
            XCTAssertEqual(deck.consentVersion, "share-2026-11-09", lang)
            XCTAssertEqual(deck.baseConsentVersion, "share-2026-11-09", lang)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), SharingCopy.bundledLanguages.map { $0 + ".json" }.sorted())
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
