#if canImport(SwiftUI)
import SwiftUI
import XCTest
@testable import TajweedFormer

/// The sharing sheet of SDK 3.1.1 (the contract's sharing_copy/design/README.md) as sums: the colour tokens for light
/// and dark, what is derived from the theme's accent, the 4.5 to 1 fallback, the type scale and the theme's fields.
/// How the sheet lays out when drawn is in `SharingSheetLayoutTests`; its words are the deck's (`SharingDeckTests`).
final class SharingSheetTests: XCTestCase {
    static let teal = SheetRGB(hex: 0x0E6B58)
    static let tealDark = SheetRGB(hex: 0x62D2B6)
    /// The system's blue: the accent of an app that names none.
    static let blue = SheetRGB(hex: 0x007AFF)
    static let blueDark = SheetRGB(hex: 0x0A84FF)
    /// A pale accent that cannot be read on its own tint.
    static let sky = SheetRGB(hex: 0x7FD4FF)
    /// The system's yellow: white cannot be read on it.
    static let yellow = SheetRGB(hex: 0xFFCC00)

    /// The palette of a theme whose accent the system reads as `accent` (the test stands in for the system's reading
    /// of a colour; the theme's other colours are at their defaults, so the tokens apply).
    func palette(_ accent: SheetRGB, dark: Bool = false, increased: Bool = false) -> SheetPalette {
        let theme = SharingTheme(accent: accent.color)
        return SheetPalette(theme: theme, dark: dark, increasedContrast: increased) { c in c == theme.accent ? accent : nil }
    }

    func assertClose(_ a: SheetRGB, _ r: Double, _ g: Double, _ b: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.r * 255, r, accuracy: 0.51, what, file: file, line: line)
        XCTAssertEqual(a.g * 255, g, accuracy: 0.51, what, file: file, line: line)
        XCTAssertEqual(a.b * 255, b, accuracy: 0.51, what, file: file, line: line)
    }

    /// The design's tokens, light and dark, where the theme left its colours at their defaults; the tint and soft tint
    /// are the accent over the sheet's background (11 % and 6 %, dark 16 % and 8 %), as the drawings' color-mix; the
    /// label on the accent is white on the light teal and near black on the dark one, as drawn.
    func testTheDefaultColoursAreTheDesignsTokens() {
        let light = palette(Self.teal)
        XCTAssertEqual(light.backgroundRGB, SheetRGB(hex: 0xFFFFFF))
        XCTAssertEqual(light.textRGB, SheetRGB(hex: 0x17171A))
        XCTAssertEqual(light.background, SheetRGB(hex: 0xFFFFFF).color)
        XCTAssertEqual(light.text, SheetRGB(hex: 0x17171A).color)
        XCTAssertEqual(light.body, SheetRGB(hex: 0x3D3D44).color)
        XCTAssertEqual(light.secondary, SheetRGB(hex: 0x62626B).color)
        XCTAssertEqual(light.card, SheetRGB(hex: 0xF4F4F6).color)
        XCTAssertEqual(light.divider, SheetRGB(hex: 0xE4E4E9).color)
        XCTAssertEqual(light.barDivider, SheetRGB(hex: 0xECECF0).color)
        XCTAssertEqual(light.grabber, SheetRGB(hex: 0xD4D4DA).color)
        assertClose(light.tintRGB, 228.49, 238.72, 236.63, "tint: #0E6B58 at 11 % over white")
        assertClose(light.softTintRGB, 240.54, 246.12, 244.98, "soft tint: 6 %")
        XCTAssertEqual(light.onAccentRGB, .white)
        XCTAssertEqual(light.bar, 3)
        XCTAssertFalse(light.labelFallback)
        XCTAssertFalse(light.iconFallback)
        XCTAssertEqual(light.cardRGB, SheetRGB(hex: 0xF4F4F6))
        XCTAssertEqual(light.accentLabel, light.accent, "the Not now label and the icons are the accent")

        let dark = palette(Self.tealDark, dark: true)
        XCTAssertEqual(dark.backgroundRGB, SheetRGB(hex: 0x1C1C1E))
        XCTAssertEqual(dark.text, SheetRGB(hex: 0xF4F4F6).color)
        XCTAssertEqual(dark.body, SheetRGB(hex: 0xD2D2D8).color)
        XCTAssertEqual(dark.secondary, SheetRGB(hex: 0xA7A7B0).color)
        XCTAssertEqual(dark.card, SheetRGB(hex: 0x2A2A2D).color)
        XCTAssertEqual(dark.divider, SheetRGB(hex: 0x3B3B40).color)
        XCTAssertEqual(dark.barDivider, SheetRGB(hex: 0x2E2E32).color)
        XCTAssertEqual(dark.grabber, SheetRGB(hex: 0x48484D).color)
        assertClose(dark.tintRGB, 39.20, 57.12, 54.32, "tint: #62D2B6 at 16 % over #1C1C1E")
        assertClose(dark.softTintRGB, 33.60, 42.56, 42.16, "soft tint: 8 %")
        XCTAssertEqual(dark.onAccentRGB, .nearBlack, "white has 1.84 to 1 on the dark teal")
        XCTAssertFalse(dark.labelFallback)
        XCTAssertFalse(dark.iconFallback)
    }

    /// The contrast rule of contract 1.12.2. The button labels, the icons and the emblem's glyph need 3 to 1 against
    /// what is behind them, and 4.5 to 1 when the device asks for more contrast. The share label is white where white
    /// reaches that bar on the accent, else near black; the "Not now" label and the glyph stay in the accent where it
    /// reaches the bar on the tint, the icons where it reaches it on the card, else they take the text colour; the
    /// fills stay the accent's. The system's blue (an app that names no accent): a white label and blue icons, in
    /// light and in dark mode; with Increase Contrast a near black label and text-coloured icons. A yellow accent: a
    /// near black label and text-coloured icons. The design's teal: as before.
    func testTheContrastRuleOfTheLabelsAndIcons() {
        struct Case {
            let name: String
            let accent: SheetRGB
            let dark: Bool
            let increased: Bool
            let white: Bool
            let notNow: Bool
            let icons: Bool
        }
        let cases: [Case] = [
            Case(name: "system blue, light", accent: Self.blue, dark: false, increased: false, white: true, notNow: true, icons: true),
            Case(name: "system blue, dark", accent: Self.blueDark, dark: true, increased: false, white: true, notNow: true, icons: true),
            Case(name: "system blue, light, more contrast", accent: Self.blue, dark: false, increased: true, white: false, notNow: false, icons: false),
            Case(name: "system blue, dark, more contrast", accent: Self.blueDark, dark: true, increased: true, white: false, notNow: false, icons: false),
            Case(name: "yellow, light", accent: Self.yellow, dark: false, increased: false, white: false, notNow: false, icons: false),
            Case(name: "yellow, light, more contrast", accent: Self.yellow, dark: false, increased: true, white: false, notNow: false, icons: false),
            Case(name: "teal, light", accent: Self.teal, dark: false, increased: false, white: true, notNow: true, icons: true),
            Case(name: "teal, dark", accent: Self.tealDark, dark: true, increased: false, white: false, notNow: true, icons: true),
            Case(name: "teal, light, more contrast", accent: Self.teal, dark: false, increased: true, white: true, notNow: true, icons: true),
            Case(name: "teal, dark, more contrast", accent: Self.tealDark, dark: true, increased: true, white: false, notNow: true, icons: true),
        ]
        for c in cases {
            let p = palette(c.accent, dark: c.dark, increased: c.increased)
            let numbers = String(format: "white on accent %.2f, accent on tint %.2f, accent on card %.2f",
                                 SheetRGB.white.contrast(with: c.accent), c.accent.contrast(with: p.tintRGB), c.accent.contrast(with: p.cardRGB))
            print("sheet contrast: \(c.name): \(numbers)")
            XCTAssertEqual(p.bar, c.increased ? 4.5 : 3, c.name)
            XCTAssertEqual(p.onAccentRGB, c.white ? .white : .nearBlack, "\(c.name): the share label (\(numbers))")
            XCTAssertEqual(p.labelFallback, !c.notNow, "\(c.name): Not now and the glyph (\(numbers))")
            XCTAssertEqual(p.iconFallback, !c.icons, "\(c.name): the icons (\(numbers))")
            XCTAssertEqual(p.accentLabel, c.notNow ? p.accent : p.text, c.name)
            XCTAssertEqual(p.iconColor, c.icons ? p.accent : p.text, c.name)
            XCTAssertEqual(p.tintRGB, c.accent.at(c.dark ? 0.16 : 0.11, over: p.backgroundRGB), "\(c.name): the fill stays the tint")
            XCTAssertGreaterThanOrEqual(p.onAccentRGB.contrast(with: c.accent), p.bar, c.name)
            XCTAssertGreaterThanOrEqual((c.notNow ? c.accent : p.textRGB).contrast(with: p.tintRGB), p.bar, c.name)
            XCTAssertGreaterThanOrEqual((c.icons ? c.accent : p.textRGB).contrast(with: p.cardRGB), p.bar, c.name)
        }
        XCTAssertEqual(SheetRGB.white.contrast(with: Self.blue), 4.02, accuracy: 0.01, "white on the system's blue")
    }

    /// Every text of the sheet can be read, with the design's accents, the system's blue, a yellow and a pale one, at
    /// normal and at increased contrast: the running text (never in the accent) has 4.5 to 1 on the background, the
    /// card and the soft tint; the share label, the Not now label and the icons have the bar (3, or 4.5 with Increase
    /// Contrast) against the accent, the tint and the card.
    func testEveryTextOfTheSheetCanBeRead() {
        for (accent, dark) in [(Self.teal, false), (Self.tealDark, true), (Self.blue, false), (Self.blueDark, true), (Self.sky, false),
                               (Self.yellow, false)] {
            for increased in [false, true] {
                let t = SheetTokens.of(dark: dark)
                let p = palette(accent, dark: dark, increased: increased)
                let what = "\(accent) \(dark ? "dark" : "light")\(increased ? " more contrast" : "")"
                XCTAssertGreaterThanOrEqual(t.text.contrast(with: t.background), 4.5, what)
                XCTAssertGreaterThanOrEqual(t.body.contrast(with: t.background), 4.5, what)
                XCTAssertGreaterThanOrEqual(t.text.contrast(with: t.card), 4.5, what)
                XCTAssertGreaterThanOrEqual(t.secondary.contrast(with: p.softTintRGB), 4.5, "\(what): the hadith's reference")
                XCTAssertGreaterThanOrEqual(p.onAccentRGB.contrast(with: accent), p.bar, "\(what): the share label")
                XCTAssertGreaterThanOrEqual((p.labelFallback ? p.textRGB : accent).contrast(with: p.tintRGB), p.bar, "\(what): Not now")
                XCTAssertGreaterThanOrEqual((p.iconFallback ? p.textRGB : accent).contrast(with: p.cardRGB), p.bar, "\(what): the icons")
            }
        }
    }

    /// A theme that sets its own background and text keeps them, and the card, the dividers and the body text are
    /// mixed from them, so the rows stay readable on a dark or coloured theme; the tint is the accent over the theme's
    /// background.
    func testAThemesOwnColoursAreKeptAndTheRestFollowThem() {
        let bg = SheetRGB(hex: 0x2B1D12), fg = SheetRGB(hex: 0xF5E9D8), accent = SheetRGB(hex: 0xE3B26A)
        let theme = SharingTheme(accent: accent.color, background: bg.color, text: fg.color)
        let p = SheetPalette(theme: theme, dark: false) { c in
            c == theme.accent ? accent : (c == theme.background ? bg : (c == theme.text ? fg : nil))
        }
        XCTAssertEqual(p.background, theme.background)
        XCTAssertEqual(p.text, theme.text)
        XCTAssertEqual(p.card, fg.at(0.047, over: bg).color)
        XCTAssertEqual(p.body, fg.at(0.836, over: bg).color)
        XCTAssertEqual(p.secondary, fg.at(0.677, over: bg).color, "the theme left secondaryText at its default")
        XCTAssertGreaterThanOrEqual(fg.contrast(with: fg.at(0.047, over: bg)), 4.5, "the rows on the card")
        XCTAssertEqual(p.tintRGB, accent.at(0.11, over: bg))
        let own = SharingTheme(secondaryText: .orange)
        XCTAssertEqual(SheetPalette(theme: own, dark: false) { _ in nil }.secondary, Color.orange, "a theme's secondary colour is kept")
    }

    /// `SharingTheme` keeps its seven fields and its initialiser (an app that themes the sheet today compiles), its
    /// defaults are those of 3.1.0, and the default fonts mean the sheet's own type. A font the app sets is used.
    func testTheThemeIsSourceCompatibleAndItsDefaultsMeanTheSheetsOwnLook() {
        var theme = SharingTheme(accent: .green, background: .white, text: .black, secondaryText: .gray, cornerRadius: 10,
                                 titleFont: .largeTitle, bodyFont: .callout)
        theme.accent = .purple; theme.background = .yellow; theme.text = .blue; theme.secondaryText = .red
        theme.cornerRadius = 4; theme.titleFont = .headline; theme.bodyFont = .footnote
        XCTAssertEqual(theme.cornerRadius, 4)
        let d = SharingTheme.standard
        XCTAssertEqual(d.accent, Color.accentColor)
        XCTAssertEqual(d.background, Color.clear)
        XCTAssertEqual(d.text, Color.primary)
        XCTAssertEqual(d.secondaryText, Color.secondary)
        XCTAssertEqual(d.cornerRadius, 14)
        let own = SheetType(theme: d, size: .large, rightToLeft: false)
        XCTAssertNil(own.titleFont, "the default title font is the sheet's own type")
        XCTAssertNil(own.bodyFont, "the default body font is the sheet's own type")
        let set = SheetType(theme: SharingTheme(titleFont: .largeTitle, bodyFont: .callout), size: .large, rightToLeft: false)
        XCTAssertEqual(set.titleFont, Font.largeTitle)
        XCTAssertEqual(set.style(.title, "Title").font, Font.largeTitle)
        XCTAssertEqual(set.style(.body, "Body").font, Font.callout)
        XCTAssertEqual(set.style(.button, "Share").font, Font.callout.weight(.semibold))
        XCTAssertEqual(set.style(.name, SharingBrand.name).font, Font.system(size: 15, weight: .semibold, design: .default), "the name is never the theme's")
        XCTAssertEqual(SheetPalette(theme: SharingTheme(cornerRadius: 4), dark: false) { _ in nil }.radiusScale, 4.0 / 14.0, accuracy: 1e-9)
        XCTAssertEqual(SheetPalette(theme: d, dark: false) { _ in nil }.radiusScale, 1)
    }

    /// The type scale at the default text size: sizes, weights, tracking in Latin script only, upper case for the
    /// reference in Latin script only, the taller line heights of a right to left deck; and how it grows: the body
    /// to the fifth accessibility size, the buttons only to the first.
    func testTheTypeScaleIsTheDesigns() {
        let en = SheetType(theme: .standard, size: .large, rightToLeft: false)
        let title = en.style(.title, "Let your recitation keep doing good")
        XCTAssertEqual(title.font, Font.system(size: 26, weight: .bold, design: .default))
        XCTAssertEqual(title.tracking, -0.52, accuracy: 1e-9)
        XCTAssertEqual(en.style(.body, "When you share").font, Font.system(size: 15.5, weight: .regular, design: .default))
        XCTAssertEqual(en.style(.row, "The audio").font, Font.system(size: 14.5, weight: .regular, design: .default))
        XCTAssertEqual(en.style(.hadith, "The Prophet").font, Font.system(size: 15, weight: .regular, design: .default))
        XCTAssertEqual(en.style(.mistakes, "Your mistakes").font, Font.system(size: 15, weight: .regular, design: .default))
        XCTAssertEqual(en.style(.button, "Not now").font, Font.system(size: 16, weight: .semibold, design: .default))
        XCTAssertEqual(en.style(.name, SharingBrand.name).font, Font.system(size: 15, weight: .semibold, design: .default))
        XCTAssertEqual(en.style(.name, SharingBrand.name).tracking, -0.15, accuracy: 1e-9)
        let ref = en.style(.reference, "Sahih Muslim 1631")
        XCTAssertEqual(ref.font, Font.system(size: 12, weight: .semibold, design: .default))
        XCTAssertTrue(ref.uppercase)
        XCTAssertEqual(ref.tracking, 0.72, accuracy: 1e-9)
        XCTAssertEqual(en.spec(.body).line, 24)
        XCTAssertEqual(en.spec(.row).line, 22)
        XCTAssertEqual(en.spec(.title).line, 31)
        // Bengali: not Latin, so no tracking and no upper case
        XCTAssertFalse(en.style(.reference, "\u{09B8}\u{09B9}\u{09BF}\u{09B9} 1631").uppercase)
        XCTAssertEqual(en.style(.title, "\u{0986}\u{09AA}\u{09A8}\u{09BE}\u{09B0}").tracking, 0)
        // a right to left deck: the design's Arabic line heights, no tracking, no upper case
        let ar = SheetType(theme: .standard, size: .large, rightToLeft: true)
        XCTAssertEqual(ar.spec(.title).line, 36)
        XCTAssertEqual(ar.spec(.body).line, 27)
        XCTAssertEqual(ar.spec(.row).line, 25)
        XCTAssertEqual(ar.spec(.hadith).line, 28)
        let arabicTitle = "\u{0627}\u{062C}\u{0639}\u{0644}"
        XCTAssertEqual(ar.style(.title, arabicTitle).tracking, 0)
        XCTAssertFalse(ar.style(.reference, "\u{0635}\u{062D}\u{064A}\u{062D} 1631").uppercase)
        XCTAssertEqual(ar.style(.name, SharingBrand.name).tracking, -0.15, accuracy: 1e-9, "the name is Latin in every language")
        // growing: the body follows the system's steps to 53 points for 17; the buttons stop at the first accessibility size
        let big = SheetType(theme: .standard, size: .accessibility5, rightToLeft: false)
        XCTAssertEqual(big.style(.body, "x").font, Font.system(size: (15.5 * 53 / 17 * 2).rounded() / 2, weight: .regular, design: .default))
        XCTAssertEqual(big.style(.button, "x").font, Font.system(size: (16 * 28 / 17 * 2).rounded() / 2, weight: .semibold, design: .default))
        XCTAssertEqual(big.style(.title, "x").font, Font.system(size: (26 * 58 / 28 * 2).rounded() / 2, weight: .bold, design: .default))
        XCTAssertEqual(big.iconScale, 1.5)
        XCTAssertEqual(big.style(.name, SharingBrand.name).font, Font.system(size: 25, weight: .semibold, design: .default),
                       "the name grows to the first accessibility size only")
        // Bengali in its left to right deck: at least a quarter of the size between its lines
        XCTAssertGreaterThanOrEqual(en.style(.body, "\u{0986}\u{09AA}\u{09A8}\u{09BE}\u{09B0} \u{09A4}\u{09BF}\u{09B2}\u{09BE}").lineSpacing, 4)
        XCTAssertEqual(en.style(.body, "When you share").lineSpacing, 24 - SheetMetrics.lineHeight("When you share", size: 15.5, weight: .regular),
                       "a Latin line keeps the design's line height")
        XCTAssertEqual(SheetType(theme: .standard, size: .xSmall, rightToLeft: false).style(.body, "x").font,
                       Font.system(size: (15.5 * 14 / 17 * 2).rounded() / 2, weight: .regular, design: .default))
    }

    /// Every text of every bundled deck (the sheet's lines, the thank-you, the settings, "What is shared", the
    /// deletion and recovery lines, the impact line in each plural form) is drawn as a paragraph in the deck's
    /// direction, whatever its first letter: as Core Text resolves the paragraph of the string the views draw. The
    /// deck's text is whole after the mark. Without the mark, the lines that begin with Latin letters in Arabic and
    /// Urdu (who receives the recordings; in Urdu also the failed deletion's network line) resolve left to right: the
    /// fault of 3.0 and 3.1.0.
    func testEveryTextOfEveryDeckIsDrawnInTheDecksDirection() throws {
        var latinFirst: [String] = []
        for lang in SharingCopy.bundledLanguages {
            let deck = try XCTUnwrap(SharingCopy.bundled(lang), lang)
            XCTAssertEqual(deck.rightToLeft, ["ar", "ur"].contains(lang), lang)
            var texts = deck.strings.map { ($0.key, $0.value) }
            for (key, forms) in deck.plurals {
                for (category, text) in forms { texts.append((key + "." + category, text)) }
            }
            XCTAssertGreaterThan(texts.count, 30, lang)
            for (key, text) in texts where !text.isEmpty {
                let shown = SheetDirection.shown(text, rightToLeft: deck.rightToLeft)
                XCTAssertEqual(SheetDirection.resolvedRightToLeft(shown), deck.rightToLeft, "\(lang) \(key): drawn in the deck's direction")
                XCTAssertEqual(shown.unicodeScalars.filter { $0.value != 0x200E && $0.value != 0x200F }.count,
                               text.unicodeScalars.count, "\(lang) \(key): the deck's text whole, nothing but the mark added")
                XCTAssertTrue(shown.hasSuffix(text), "\(lang) \(key)")
                if SheetDirection.resolvedRightToLeft(text) != deck.rightToLeft { latinFirst.append("\(lang) \(key)") }
            }
        }
        XCTAssertEqual(latinFirst.sorted(), ["ar sheet.who", "ur delete.failed.network", "ur sheet.who"],
                       "the lines a text engine would lay out against the deck's direction without the mark")
        // a paragraph after a line break takes the mark too
        XCTAssertTrue(SheetDirection.resolvedRightToLeft(SheetDirection.shown("Quran Lab \u{0648}", rightToLeft: true)))
        XCTAssertEqual(SheetDirection.shown("a\nb", rightToLeft: true), "\u{200F}a\n\u{200F}b")
        XCTAssertEqual(SheetDirection.shown("", rightToLeft: true), "")
    }

    /// The line heights come from the fonts the system draws with: a Latin line of the body is shorter than the
    /// design's 24 (so the spacing between lines is positive), and an Arabic line is taller than a Latin one.
    func testTheLineHeightsAreMeasuredOnTheSystemsFonts() {
        let latin = SheetMetrics.lineHeight("When you share your recitations", size: 15.5, weight: .regular)
        XCTAssertGreaterThan(latin, 15.5)
        XCTAssertLessThan(latin, 24)
        let arabic = SheetMetrics.lineHeight("\u{0639}\u{0646}\u{062F}\u{0645}\u{0627} \u{062A}\u{0634}\u{0627}\u{0631}\u{0643}", size: 15.5, weight: .regular)
        XCTAssertGreaterThan(arabic, latin, "the system's Arabic face is taller")
        let s = SheetType(theme: .standard, size: .large, rightToLeft: false).style(.body, "When you share your recitations")
        XCTAssertEqual(s.lineSpacing, 24 - latin, accuracy: 1e-9)
        XCTAssertEqual(s.firstLine, 24)
        XCTAssertTrue(SheetMetrics.isLatin("Sahih M\u{00FC}slim 1631"))
        XCTAssertFalse(SheetMetrics.isLatin("1631"))
    }
}
#endif
