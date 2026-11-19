#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TajweedFormer

/// SDK 4.0's re-ask card (SHARE_ASK_40 20.6, 20.7) drawn by SwiftUI on the test's Mac, as at the bottom of a phone's
/// window and of a wide one: in each of the eight languages it draws the deck's own `card.line`, `card.open` and
/// `card.not_now` whole (read from the deck file, not through the SDK's reader), in the deck's direction (an Arabic or
/// Urdu card right to left, the emblem at the right); its two buttons have one size and are at least 44 points high;
/// it is at most 480 points wide.
final class SharingCardTests: XCTestCase {
    override func tearDown() { QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil) }

    @MainActor
    func testTheCardDrawsTheDecksOwnLinesInEveryLanguage() throws {
        let wide = CGSize(width: 1024, height: 768)
        for lang in SharingCopy.bundledLanguages {
            let strings = try SharingDeckTests.strings(lang)
            SharingSheetLayoutTests.use(lang)
            let rtl = ["ar", "ur"].contains(lang)
            for size in [SharingSheetLayoutTests.phone, wide] {
                let at = "\(lang) \(Int(size.width)) wide"
                let drawn = SharingSheetLayoutTests.draw(VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SharingCardView(theme: .standard) { (_: SharingCardView.Choice) in }
                }, size: size)
                for k in ["card.line", "card.open", "card.not_now"] {
                    let deck = try XCTUnwrap(strings[k] as? String, "\(at): \(k) in the deck")
                    XCTAssertFalse(deck.isEmpty, "\(at): \(k)")
                    XCTAssertEqual(drawn.lines[k], deck, "\(at): the card draws \(k) whole")
                    XCTAssertEqual(drawn.shown[k], SheetDirection.shown(deck, rightToLeft: rtl), "\(at): \(k) as drawn")
                    XCTAssertEqual(drawn.shown[k].map(SheetDirection.resolvedRightToLeft), rtl, "\(at): \(k) in the deck's direction")
                }
                let card = try XCTUnwrap(drawn.frames["card"], "\(at): the card is laid out")
                let open = try XCTUnwrap(drawn.frames["card.open"], "\(at): See how it helps is laid out")
                let notNow = try XCTUnwrap(drawn.frames["card.not_now"], "\(at): Not now is laid out")
                let emblem = try XCTUnwrap(drawn.frames["card.emblem"], "\(at): the emblem is laid out")
                XCTAssertEqual(card.width, min(480, size.width - 24), accuracy: 0.5, "\(at): at most 480 wide, 12 from each side")
                XCTAssertEqual(size.height - card.maxY, 12, accuracy: 0.5, "\(at): at the bottom")
                XCTAssertEqual(open.width, notNow.width, accuracy: 0.5, "\(at): two buttons of one width")
                XCTAssertEqual(open.height, notNow.height, accuracy: 0.5, "\(at): and one height")
                XCTAssertGreaterThanOrEqual(open.height, 44, "\(at): a touch target of 44 or more")
                XCTAssertEqual(open.midY, notNow.midY, accuracy: 0.5, "\(at): one row")
                if rtl {
                    XCTAssertGreaterThan(emblem.midX, card.midX, "\(at): right to left, the emblem at the right")
                    XCTAssertGreaterThan(open.midX, notNow.midX, "\(at): See how it helps first in reading order")
                } else {
                    XCTAssertLessThan(emblem.midX, card.midX, "\(at): the emblem at the left")
                    XCTAssertLessThan(open.midX, notNow.midX, "\(at): See how it helps first in reading order")
                }
            }
        }
    }
}
#endif
