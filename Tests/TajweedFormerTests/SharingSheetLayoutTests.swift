#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TajweedFormer

/// The sharing sheet of SDK 3.1.1 drawn by SwiftUI on the test's Mac, as an iPhone shows it (the phone layout, 390 by
/// 844 points) and as a Mac shows it (the card): every deck line drawn whole in every language, the name at the top
/// whatever the theme, the two buttons of one size, the share button waiting for the guardian's switch, the direction
/// from the deck, and nothing of the host app's environment reaching the sheet. With `QURANLAB_SHEET_PICTURES` set
/// to a folder, `testThePicturesOfTheReleaseReview` writes the pictures of the release review there (PNG, 3x).
final class SharingSheetLayoutTests: XCTestCase {
    override func tearDown() {
        try? Contributions.setWording(nil)
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The deck of `lang` in force, as for an app whose learner reads it.
    static func use(_ lang: String) {
        QuranLab.configure(key: nil, options: QuranLab.Options(storageDirectory: CloudFixtures.storage(), cloud: nil,
                                                               sharingLocale: Locale(identifier: lang)), cloud: nil)
    }

    static let teal = SheetRGB(hex: 0x0E6B58)
    static let tealDark = SheetRGB(hex: 0x62D2B6)
    /// The design's default accent, as an app would set it (light and dark).
    static func designTheme(dark: Bool) -> SharingTheme { SharingTheme(accent: (dark ? tealDark : teal).color) }

    static let phone = CGSize(width: 390, height: 844)

    /// What a drawing recorded.
    struct Drawn {
        var lines: [String: String]
        var shown: [String: String]
        var frames: [String: CGRect]
        var enabled: [String: Bool]
    }

    /// Draws `view` in a window of `size` points and returns what the sheet recorded.
    @MainActor
    static func draw<V: View>(_ view: V, size: CGSize = phone, dark: Bool = false) -> Drawn {
        SheetProbe.lines = [:]
        SheetProbe.shown = [:]
        SheetProbe.frames = [:]
        SheetProbe.enabled = [:]
        let window = SheetHost.open(view, size: size, dark: dark)
        SheetHost.close(window)
        let out = Drawn(lines: SheetProbe.lines ?? [:], shown: SheetProbe.shown ?? [:], frames: SheetProbe.frames ?? [:],
                        enabled: SheetProbe.enabled ?? [:])
        SheetProbe.lines = nil
        SheetProbe.shown = nil
        SheetProbe.frames = nil
        SheetProbe.enabled = nil
        return out
    }

    // MARK: words

    /// Every line of the sheet, in each of the eight languages, in the first ask, the re-ask and the guardian's
    /// variant: the text the sheet draws for each key is the deck file's own, whole (read from the file, not through
    /// the SDK's reader), drawn as it is in a left to right deck and after a right to left mark in an Arabic or Urdu
    /// one (so a line that starts with the Latin name is still a right to left paragraph), and the name `Quran Lab`
    /// is at the top.
    @MainActor
    func testEveryLineOfTheSheetIsDrawnWholeInEveryLanguage() throws {
        for lang in SharingCopy.bundledLanguages {
            let strings = try SharingDeckTests.strings(lang)
            Self.use(lang)
            for (reask, guardian) in [(false, false), (true, false), (false, true)] {
                let variant = "\(lang)\(reask ? " re-ask" : "")\(guardian ? " guardian" : "")"
                let drawn = Self.draw(SharingConsentView(reask: reask, guardian: guardian, theme: .standard,
                                                         render: SheetRender(layout: .phone)))
                var keys = [guardian ? "sheet.guardian.title" : "sheet.title", guardian ? "sheet.guardian.body" : "sheet.body",
                            "sheet.what", "sheet.who", "sheet.control", "sheet.mistakes",
                            guardian ? "sheet.guardian.share" : "sheet.share", "sheet.not_now"]
                if reask { keys.append("reask") }
                if guardian { keys.append("sheet.guardian.confirm") }
                XCTAssertTrue(Contributions.copy.hadithVerified, variant)
                keys += ["sheet.hadith", "sheet.hadith_ref"]
                for k in keys {
                    let deck = try XCTUnwrap(strings[k] as? String, "\(variant): \(k) in the deck")
                    XCTAssertFalse(deck.isEmpty, "\(variant): \(k)")
                    XCTAssertEqual(drawn.lines[k], deck, "\(variant): the sheet draws \(k) whole")
                    let rtl = ["ar", "ur"].contains(lang)
                    XCTAssertEqual(drawn.shown[k], SheetDirection.shown(deck, rightToLeft: rtl), "\(variant): \(k) as drawn")
                    XCTAssertEqual(drawn.shown[k].map(SheetDirection.resolvedRightToLeft), rtl, "\(variant): \(k) in the deck's direction")
                }
                XCTAssertEqual(drawn.lines["name"], "Quran Lab", "\(variant): the name at the top")
                XCTAssertNil(drawn.lines["reask"].flatMap { reask ? nil : $0 }, "\(variant): the re-ask line only on a re-ask")
            }
        }
    }

    /// The name is a constant of the SDK: a theme that sets every field, and the app's own wording, leave it in place,
    /// drawn, in Latin letters.
    @MainActor
    func testNoThemeOrWordingRemovesTheName() throws {
        Self.use("ar")
        try Contributions.setWording(["sheet.title": "A title of the app's own"])
        let theme = SharingTheme(accent: .orange, background: .black, text: .white, secondaryText: .gray, cornerRadius: 0,
                                 titleFont: .largeTitle, bodyFont: .headline)
        let drawn = Self.draw(SharingConsentView(theme: theme, render: SheetRender(layout: .phone)))
        XCTAssertEqual(drawn.lines["name"], "Quran Lab")
        XCTAssertEqual(drawn.lines["sheet.title"], "A title of the app's own")
        let name = try XCTUnwrap(drawn.frames["name"], "the name is laid out")
        XCTAssertGreaterThan(name.width, 40)
        XCTAssertGreaterThan(name.height, 10)
    }

    // MARK: layout

    /// The two buttons have the same width and height in every language, at the default and at the largest text size,
    /// on a 390 and a 320 point wide phone, in both variants: 52 high at the default size, and taller only as far as
    /// two lines of the label need.
    @MainActor
    func testBothButtonsHaveTheSameSize() throws {
        for lang in SharingCopy.bundledLanguages {
            Self.use(lang)
            for size in [DynamicTypeSize.large, .accessibility5] {
                for width in [CGFloat(390), 320] {
                    for guardian in [false, true] {
                        let at = "\(lang) \(size) \(Int(width)) \(guardian ? "guardian" : "learner")"
                        let drawn = Self.draw(SharingConsentView(guardian: guardian, theme: .standard,
                                                                 render: SheetRender(layout: .phone, textSize: size)),
                                              size: CGSize(width: width, height: 844))
                        let share = try XCTUnwrap(drawn.frames["share"], "\(at): the share button is laid out")
                        let notNow = try XCTUnwrap(drawn.frames["not_now"], "\(at): Not now is laid out")
                        XCTAssertEqual(share.width, notNow.width, accuracy: 0.5, "\(at): the same width")
                        XCTAssertEqual(share.height, notNow.height, accuracy: 0.5, "\(at): the same height")
                        XCTAssertEqual(share.width, width - 48, accuracy: 0.5, "\(at): full width inside the bar's 24 point sides")
                        XCTAssertEqual(notNow.minY - share.maxY, 10, accuracy: 0.5, "\(at): 10 between them")
                        XCTAssertGreaterThanOrEqual(share.height, 52 - 0.5, "\(at): at least 52 (a 44 point touch target and more)")
                        let copy = Contributions.copy
                        let type = SheetType(theme: .standard, size: size, rightToLeft: copy.rightToLeft)
                        let labels = [copy.string(guardian ? "sheet.guardian.share" : "sheet.share"), copy.string("sheet.not_now")]
                        let line = labels.map { type.style(.button, $0).firstLine }.max() ?? 20
                        XCTAssertLessThanOrEqual(share.height, max(52, 2 * line + 16) + 0.5, "\(at): two lines of a label at most")
                        if size == .large {
                            XCTAssertEqual(share.height, 52, accuracy: 0.5, "\(at): 52 high at the default size (each label on one line)")
                        }
                    }
                }
            }
        }
    }

    /// Under the buttons: 30 points to the sheet's bottom edge, or the bottom safe area where it is larger (a phone
    /// with a home indicator: 34), with none (a phone with a home button, an iPad's card, a Mac) and with one.
    @MainActor
    func testTheButtonsKeepThirtyPointsOrTheSafeAreaBelowThem() throws {
        Self.use("en")
        for inset in [nil, 0, 20, 34, 40] as [CGFloat?] {
            let drawn = Self.draw(SharingConsentView(theme: .standard, render: SheetRender(layout: .phone, bottomInset: inset)))
            let notNow = try XCTUnwrap(drawn.frames["not_now"])
            XCTAssertEqual(Self.phone.height - notNow.maxY, max(30, inset ?? 0), accuracy: 0.5,
                           "a safe area of \(inset.map { "\($0)" } ?? "none (this Mac's window)")")
        }
    }

    /// The grabber's band on a phone sheet (the sheet's top 20 points: the grabber with 8 above and 7 below) holds
    /// nothing but the sheet's background and the grabber: the column's viewport begins under it, so a column
    /// scrolled to its end draws nothing there, and its top fade sits inside the viewport. Light and dark.
    @MainActor
    func testNothingOfTheColumnIsDrawnInTheGrabbersBand() throws {
        Self.use("en")
        for dark in [false, true] {
            let view = SharingConsentView(theme: Self.designTheme(dark: dark),
                                          render: SheetRender(layout: .phone, scrolledToEnd: true, bottomInset: 34))
            let window = SheetHost.open(view, size: Self.phone, dark: dark)
            let host = try XCTUnwrap(window.contentView)
            let rep = try XCTUnwrap(SheetHost.bitmap(host, scale: 1))
            SheetHost.close(window)
            // the sheet's background as this snapshot draws it: the bar's empty corner at the bottom left, under the
            // buttons (the snapshot's colour management moves a dark colour off its token, so the band is compared
            // with the background as drawn; the tokens themselves are SharingSheetTests')
            let bottom = Int(Self.phone.height) - 2
            let bg = try XCTUnwrap(rep.colorAt(x: 2, y: bottom)?.usingColorSpace(.sRGB))
            XCTAssertEqual(bg.redComponent > 0.5, !dark, "the reference is the sheet's \(dark ? "dark" : "light") background")
            var stray = 0, grabber = 0
            for y in 0..<20 {
                for x in 0..<Int(Self.phone.width) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let isBackground = abs(c.redComponent - bg.redComponent) <= 2.0 / 255
                        && abs(c.greenComponent - bg.greenComponent) <= 2.0 / 255
                        && abs(c.blueComponent - bg.blueComponent) <= 2.0 / 255
                    if isBackground { continue }
                    // the grabber: 36 by 5, centred, 8 from the top (a point of antialiasing around it)
                    if x >= 195 - 19 && x <= 195 + 19 && y >= 7 && y <= 13 { grabber += 1 } else { stray += 1 }
                }
            }
            XCTAssertGreaterThan(grabber, 100, "\(dark ? "dark" : "light"): the grabber is drawn")
            XCTAssertEqual(stray, 0, "\(dark ? "dark" : "light"): nothing of the column is drawn in the grabber's band")
        }
    }

    /// In the guardian's variant the share button cannot be tapped until the switch is on; "Not now" always can. In the
    /// learner's variant both can.
    @MainActor
    func testTheShareButtonWaitsForTheGuardiansSwitch() {
        Self.use("en")
        let off = Self.draw(SharingConsentView(guardian: true, theme: .standard, render: SheetRender(layout: .phone)))
        XCTAssertEqual(off.enabled["share"], false, "the switch is off: the share button waits")
        XCTAssertEqual(off.enabled["not_now"], true)
        let on = Self.draw(SharingConsentView(guardian: true, theme: .standard, render: SheetRender(layout: .phone, confirmed: true)))
        XCTAssertEqual(on.enabled["share"], true, "the switch is on")
        XCTAssertEqual(on.enabled["not_now"], true)
        let learner = Self.draw(SharingConsentView(guardian: false, theme: .standard, render: SheetRender(layout: .phone)))
        XCTAssertEqual(learner.enabled["share"], true)
        XCTAssertEqual(learner.enabled["not_now"], true)
    }

    /// The deck's direction decides, not the app's: an Arabic or Urdu sheet is right to left (the emblem at the right
    /// edge, the name to its left) in an app laid out left to right, and the other six are left to right in an app laid
    /// out right to left.
    @MainActor
    func testTheDirectionFollowsTheDeck() throws {
        for lang in SharingCopy.bundledLanguages {
            Self.use(lang)
            let rtl = Contributions.copy.rightToLeft
            XCTAssertEqual(rtl, ["ar", "ur"].contains(lang), lang)
            for host in [LayoutDirection.leftToRight, .rightToLeft] {
                let at = "\(lang) in an app laid out \(host == .rightToLeft ? "right to left" : "left to right")"
                let drawn = Self.draw(SharingConsentView(theme: .standard, render: SheetRender(layout: .phone))
                    .environment(\.layoutDirection, host))
                let emblem = try XCTUnwrap(drawn.frames["emblem"], at)
                let name = try XCTUnwrap(drawn.frames["name"], at)
                if rtl {
                    XCTAssertEqual(emblem.maxX, 390 - 24, accuracy: 0.5, "\(at): the emblem at the right edge")
                    XCTAssertEqual(emblem.minX - name.maxX, 10, accuracy: 0.5, "\(at): the name to its left")
                } else {
                    XCTAssertEqual(emblem.minX, 24, accuracy: 0.5, "\(at): the emblem at the left edge")
                    XCTAssertEqual(name.minX - emblem.maxX, 10, accuracy: 0.5, "\(at): the name to its right")
                }
                XCTAssertEqual(emblem.width, 40, accuracy: 0.5, at)
                XCTAssertEqual(emblem.midY, name.midY, accuracy: 0.5, "\(at): one row, centred")
            }
        }
    }

    /// The host app's environment does not reach the sheet: the sheet drawn inside each of these modifiers (a font, a
    /// weight, bold, italic, a design, a text size, Bold Text, a line limit, upper case, centred text, shrinking, a
    /// placeholder redaction, the other direction, a button or toggle style, a control size, a colour, tracking,
    /// kerning, a baseline, line spacing) is the same, pixel for pixel, as the sheet drawn without it. Not in the
    /// list: `.monospacedDigit()`, which SwiftUI gives no way to undo; its only effect on the sheet is that the digits
    /// of the hadith's reference take equal widths, and the test reports whether it changed the drawing.
    @MainActor
    func testNothingOfTheHostsEnvironmentReachesTheSheet() throws {
        Self.use("en")
        let sheet = { AnyView(SharingConsentView(guardian: true, theme: Self.designTheme(dark: false),
                                                 render: SheetRender(layout: .phone, scrolledToEnd: true, bottomInset: 34))) }
        let baseline = SheetHost.pixels(sheet(), size: Self.phone)
        XCTAssertGreaterThan(SheetHost.colours(baseline), 40, "the window's snapshot holds a drawn sheet (not a blank page)")
        var hostile: [(String, @MainActor (AnyView) -> AnyView)] = [
            ("font largeTitle", { AnyView($0.font(.largeTitle)) }),
            ("dynamicTypeSize accessibility3", { AnyView($0.dynamicTypeSize(.accessibility3)) }),
            ("legibilityWeight bold", { AnyView($0.environment(\.legibilityWeight, .bold)) }),
            ("lineLimit 1", { AnyView($0.lineLimit(1)) }),
            ("textCase uppercase", { AnyView($0.textCase(.uppercase)) }),
            ("multilineTextAlignment center", { AnyView($0.multilineTextAlignment(.center)) }),
            ("minimumScaleFactor 0.5", { AnyView($0.minimumScaleFactor(0.5)) }),
            ("redacted placeholder", { AnyView($0.redacted(reason: .placeholder)) }),
            ("layoutDirection rightToLeft", { AnyView($0.environment(\.layoutDirection, .rightToLeft)) }),
            ("buttonStyle bordered", { AnyView($0.buttonStyle(.bordered)) }),
            ("toggleStyle checkbox", { AnyView($0.toggleStyle(.checkbox)) }),
            ("controlSize mini", { AnyView($0.controlSize(.mini)) }),
            ("foregroundColor red", { AnyView($0.foregroundColor(.red)) }),
            ("lineSpacing 20", { AnyView($0.lineSpacing(20)) }),
        ]
        if #available(macOS 13.0, *) {
            let text: [(String, @MainActor (AnyView) -> AnyView)] = [
                ("fontWeight semibold", { AnyView($0.fontWeight(.semibold)) }),
                ("bold", { AnyView($0.bold()) }),
                ("italic", { AnyView($0.italic()) }),
                ("fontDesign serif", { AnyView($0.fontDesign(.serif)) }),
                ("underline", { AnyView($0.underline()) }),
                ("tracking 4", { AnyView($0.tracking(4)) }),
                ("kerning 4", { AnyView($0.kerning(4)) }),
                ("baselineOffset 6", { AnyView($0.baselineOffset(6)) }),
            ]
            hostile += text
        }
        var reached: [String] = []
        for (name, wrap) in hostile {
            let got = SheetHost.pixels(wrap(sheet()), size: Self.phone)
            if got != baseline {
                reached.append(name)
                SheetPictures.write(wrap(sheet()), size: Self.phone, scale: 2, dark: false,
                                    name: "hostile-" + name.replacingOccurrences(of: " ", with: "-") + ".png",
                                    what: "the guardian sheet inside the host modifier \(name): it differs from the plain one")
            }
        }
        print("sheet: host modifiers that changed the 3.1.1 sheet: \(reached.isEmpty ? "none" : reached.joined(separator: ", "))")
        let digits = SheetHost.pixels(AnyView(sheet().monospacedDigit()), size: Self.phone) != baseline
        print("sheet: .monospacedDigit() on the host's views \(digits ? "changes" : "does not change") the 3.1.1 sheet (the reference's digits)")
        XCTAssertEqual(reached, [], "the host's environment reached the sheet")
    }

    /// The guardian's switch, clicked as a person clicks it: the share button can be tapped once it is on, and waits
    /// again once it is off. The switch is the system's switch control.
    @MainActor
    func testClickingTheGuardiansSwitchEnablesTheShareButton() throws {
        Self.use("en")
        SheetProbe.enabled = [:]
        defer { SheetProbe.enabled = nil }
        let window = SheetHost.open(SharingConsentView(guardian: true, theme: .standard, render: SheetRender(layout: .phone)),
                                    size: CGSize(width: 390, height: 2400), dark: false)
        defer { SheetHost.close(window) }
        let host = try XCTUnwrap(window.contentView)
        XCTAssertEqual(SheetProbe.enabled?["share"], false, "the switch is off: the share button waits")
        let switches = SheetHost.subviews(of: host).compactMap { $0 as? NSSwitch }
        print("sheet: \(switches.count) switch control(s) in the guardian's sheet")
        let control = try XCTUnwrap(switches.first, "the guardian's switch is the system's switch control")
        XCTAssertEqual(switches.count, 1)
        XCTAssertEqual(control.state, .off)
        control.performClick(nil)
        SheetHost.settle(host)
        XCTAssertEqual(control.state, .on)
        XCTAssertEqual(SheetProbe.enabled?["share"], true, "the switch is on: the share button can be tapped")
        XCTAssertEqual(SheetProbe.enabled?["not_now"], true)
        control.performClick(nil)
        SheetHost.settle(host)
        XCTAssertEqual(SheetProbe.enabled?["share"], false, "off again: the share button waits again")
    }

    // MARK: pictures

    /// The pictures of the release review, drawn by SwiftUI (only with `QURANLAB_SHEET_PICTURES`): light and dark,
    /// English and Arabic, as it opens and scrolled to the end, the default and the largest text size, the guardian's
    /// variant, a re-ask, a 320 point wide phone, the Mac's card, the app's own accent, the thank-you and the settings,
    /// and for the record the 3.1.0 sheet with the host modifiers that change it.
    @MainActor
    func testThePicturesOfTheReleaseReview() throws {
        guard SheetPictures.folder != nil else { throw XCTSkip("QURANLAB_SHEET_PICTURES is not set") }
        let small = CGSize(width: 320, height: 568)
        func shot(_ lang: String, dark: Bool = false, size: DynamicTypeSize = .large, end: Bool = false, guardian: Bool = false,
                  reask: Bool = false, confirmed: Bool = false, canvas: CGSize = Self.phone, theme: SharingTheme? = nil,
                  contrast: Bool = false, name: String, what: String) {
            Self.use(lang)
            let inset: CGFloat = canvas.width < 380 ? 0 : 34
            let sheet = SharingConsentView(reask: reask, guardian: guardian, theme: theme ?? Self.designTheme(dark: dark),
                                           render: SheetRender(layout: .phone, textSize: size, scrolledToEnd: end, confirmed: confirmed,
                                                               bottomInset: inset, showsIndicators: false, increasedContrast: contrast))
            SheetPictures.write(PhoneCanvas(size: canvas, top: canvas.width < 380 ? 30 : 54, dark: dark, sheet: sheet),
                                size: canvas, scale: 3, dark: dark, name: name, what: what)
        }
        shot("en", name: "en-light-open.png", what: "English, light, as it opens (Main.dc.html)")
        shot("en", end: true, name: "en-light-end.png", what: "English, light, scrolled to the end (End.dc.html)")
        shot("en", canvas: CGSize(width: 375, height: 667), name: "en-light-open-home-button.png",
             what: "a phone with a home button (375 by 667, no bottom safe area): 30 under the buttons")
        shot("en", dark: true, name: "en-dark-open.png", what: "English, dark, as it opens (Dark.dc.html)")
        shot("en", dark: true, end: true, name: "en-dark-end.png", what: "English, dark, scrolled to the end")
        shot("ar", name: "ar-light-open.png", what: "Arabic, light, right to left, as it opens (Arabic.dc.html)")
        shot("ar", end: true, name: "ar-light-end.png", what: "Arabic, light, scrolled to the end")
        shot("ar", dark: true, name: "ar-dark-open.png", what: "Arabic, dark, as it opens")
        shot("en", size: .accessibility5, name: "en-light-largest-open.png", what: "English, the largest text size (AX5), as it opens")
        shot("en", size: .accessibility5, end: true, name: "en-light-largest-end.png", what: "English, the largest text size, scrolled to the end")
        shot("ar", size: .accessibility5, name: "ar-light-largest-open.png", what: "Arabic, the largest text size, as it opens")
        shot("ar", size: .accessibility5, end: true, name: "ar-light-largest-end.png", what: "Arabic, the largest text size, scrolled to the end")
        shot("en", guardian: true, name: "en-light-guardian-open.png", what: "the guardian's variant (children's app), as it opens")
        shot("en", end: true, guardian: true, name: "en-light-guardian-end.png", what: "the guardian's variant at the end: the switch off, the share button waiting (0.45)")
        shot("en", end: true, guardian: true, confirmed: true, name: "en-light-guardian-end-on.png", what: "the guardian's variant at the end with the switch on")
        shot("ar", dark: true, end: true, guardian: true, name: "ar-dark-guardian-end.png", what: "Arabic, dark, the guardian's variant at the end")
        shot("en", reask: true, name: "en-light-reask-open.png", what: "a re-ask: the re-ask line between the title and the body")
        shot("en", canvas: small, name: "en-light-320-open.png", what: "a 320 point wide phone (320 by 568), as it opens")
        shot("en", end: true, canvas: small, name: "en-light-320-end.png", what: "a 320 point wide phone, scrolled to the end")
        shot("id", size: .accessibility5, end: true, guardian: true, canvas: small, name: "id-light-320-largest-guardian-end.png",
              what: "Indonesian (the longest button label), 320 wide, the largest size, the guardian's variant at the end")
        shot("en", size: .accessibility5, end: true, guardian: true, name: "en-light-largest-guardian-end.png",
             what: "the guardian's variant at the largest size: the switch under its text")
        shot("fr", name: "fr-light-open.png", what: "French, light, as it opens")
        shot("bn", name: "bn-light-open.png", what: "Bengali, light, as it opens (at least a quarter of the size between its lines)")
        shot("bn", end: true, name: "bn-light-end.png", what: "Bengali, light, scrolled to the end")
        shot("ur", name: "ur-light-open.png", what: "Urdu, light, right to left, as it opens")
        shot("ur", end: true, name: "ur-light-end.png", what: "Urdu, light, scrolled to the end")
        shot("tr", end: true, name: "tr-light-end.png", what: "Turkish at the end (the reference in upper case with the dotted capital I)")
        shot("en", theme: .standard, name: "en-light-app-accent-open.png",
              what: "the default theme (the app's accent colour; on this Mac the system's blue): a white share label, Not now and the icons in blue (3 to 1)")
        shot("en", dark: true, theme: .standard, name: "en-dark-app-accent-open.png", what: "the default theme in dark mode")
        shot("en", theme: .standard, contrast: true, name: "en-light-app-accent-open-more-contrast.png",
              what: "the default theme with Increase Contrast (4.5 to 1): a near black share label, Not now and the icons in the text colour")
        shot("en", dark: true, theme: .standard, contrast: true, name: "en-dark-app-accent-open-more-contrast.png",
              what: "the default theme in dark mode with Increase Contrast")
        shot("en", theme: SharingTheme(accent: SheetRGB(hex: 0xFFCC00).color), name: "en-light-yellow-accent-open.png",
              what: "a yellow accent: a near black share label, Not now and the icons in the text colour")

        // the lines of the settings in Arabic and Urdu, drawn as the settings view draws them (a column of them: the
        // view shows "What is shared", the deletion lines and the recovery hint only after taps and with a recovery
        // code), with the real settings view above
        for lang in ["ar", "ur"] {
            Self.use(lang)
            // placed as a right to left screen of the app places it: at the leading (right) edge
            SheetPictures.write(VStack(spacing: 0) {
                SharingSettingsView(theme: Self.designTheme(dark: false), opaque: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsLines()
            }.environment(\.layoutDirection, .rightToLeft).frame(width: 390, alignment: .top),
            size: CGSize(width: 390, height: 900), scale: 3, dark: false,
            name: "\(lang)-settings.png", what: "\(lang == "ar" ? "Arabic" : "Urdu"): the settings view, then its other lines (what is shared, the deletion lines, the recovery lines with the URL, the thank-you)")
            SheetPictures.write(PhoneCanvas(size: Self.phone, top: 54, dark: false, sheet: Sheet310().background(Color.white)),
                                size: Self.phone, scale: 3, dark: false, name: "sheet310-\(lang).png",
                                what: "the 3.1.0 sheet in \(lang == "ar" ? "Arabic" : "Urdu"), for the record: who receives the recordings laid out left to right")
        }

        // the Mac's card
        for dark in [false, true] {
            Self.use("en")
            let card = CGSize(width: 480, height: 680)
            let sheet = SharingConsentView(theme: Self.designTheme(dark: dark), render: SheetRender(layout: .card, showsIndicators: false))
            SheetPictures.write(CardCanvas(card: card, dark: dark, sheet: sheet), size: CGSize(width: 560, height: 760), scale: 2, dark: dark,
                                name: "mac-card-\(dark ? "dark" : "light").png", what: "the Mac's (and a wide screen's) centred card, 480 wide, \(dark ? "dark" : "light")")
        }
        // the thank-you and the settings take the same tokens
        for dark in [false, true] {
            Self.use("en")
            let tag = dark ? "dark" : "light"
            SheetPictures.write(SharingThanksView(theme: Self.designTheme(dark: dark)).frame(width: 390, alignment: .topLeading)
                                    .background(SheetTokens.of(dark: dark).background.color),
                                size: CGSize(width: 390, height: 200), scale: 3, dark: dark, name: "thanks-\(tag).png", what: "the thank-you, \(tag)")
            SheetPictures.write(SharingSettingsView(theme: Self.designTheme(dark: dark), opaque: true).frame(width: 390, alignment: .topLeading),
                                size: CGSize(width: 390, height: 360), scale: 3, dark: dark, name: "settings-\(tag).png", what: "the settings, \(tag)")
        }
        // the same picture through ImageRenderer, for comparison with the window's drawing
        if #available(macOS 13.0, *) {
            Self.use("en")
            let sheet = SharingConsentView(theme: Self.designTheme(dark: false),
                                           render: SheetRender(layout: .phone, bottomInset: 34, showsIndicators: false))
            SheetPictures.writeRendered(PhoneCanvas(size: Self.phone, top: 54, dark: false, sheet: sheet), size: Self.phone,
                                        name: "en-light-open-imagerenderer.png", what: "en-light-open.png drawn by ImageRenderer instead of a window")
        }
        // for the record: the 3.1.0 sheet, plain and inside host modifiers (which of them made its text heavy)
        Self.use("en")
        let plain310 = SheetHost.pixels(AnyView(Sheet310()), size: Self.phone)
        SheetPictures.write(Sheet310(), size: Self.phone, scale: 3, dark: false, name: "sheet310-plain.png", what: "the 3.1.0 sheet as it was")
        var changed: [String] = []
        var heavy: [(String, @MainActor (AnyView) -> AnyView)] = [
            ("legibilityWeight-bold", { AnyView($0.environment(\.legibilityWeight, .bold)) }),
            ("font-headline", { AnyView($0.font(.headline)) }),
            ("dynamicTypeSize-xxxLarge", { AnyView($0.dynamicTypeSize(.xxxLarge)) }),
        ]
        if #available(macOS 13.0, *) {
            let weights: [(String, @MainActor (AnyView) -> AnyView)] = [("fontWeight-semibold", { AnyView($0.fontWeight(.semibold)) }),
                                                                         ("bold", { AnyView($0.bold()) })]
            heavy += weights
        }
        for (name, wrap) in heavy where SheetHost.pixels(wrap(AnyView(Sheet310())), size: Self.phone) != plain310 {
            changed.append(name)
            SheetPictures.write(wrap(AnyView(Sheet310())), size: Self.phone, scale: 3, dark: false, name: "sheet310-host-\(name).png",
                                what: "the 3.1.0 sheet inside the host modifier \(name)")
        }
        print("sheet: host modifiers that changed the 3.1.0 sheet: \(changed.isEmpty ? "none" : changed.joined(separator: ", "))")
        SheetPictures.finish()
    }
}

/// The test's window: it can be the key window (a control in a window that is not key is drawn inactive, a switch
/// that is on grey instead of in the accent), and it reports a backing scale of 3, so SwiftUI draws its layers at the
/// pictures' 3x, as an iPhone does (the runner's screen is 1x, and a drawing at 1x made larger is blurred).
final class SheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var backingScaleFactor: CGFloat { 3 }
}

/// A borderless window off screen that SwiftUI lays out and draws into.
@MainActor
enum SheetHost {
    static var said = false

    static func open<V: View>(_ view: V, size: CGSize, dark: Bool) -> NSWindow {
        let app = NSApplication.shared
        if app.activationPolicy() == .prohibited { _ = app.setActivationPolicy(.accessory) }
        if !said { app.finishLaunching() }
        if #available(macOS 14.0, *) { app.activate() } else { app.activate(ignoringOtherApps: true) }
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = SheetWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host)
        if !said {
            said = true
            print("sheet: test window backing scale \(window.backingScaleFactor), layer scale \(host.layer?.contentsScale ?? 0), key \(window.isKeyWindow), app active \(app.isActive)")
        }
        return window
    }

    static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviews(of: $0) }
    }

    static func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        }
    }

    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// The view drawn at `scale`, in sRGB.
    static func bitmap(_ view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                         pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
    }

    /// How many different colours a snapshot holds (a blank one holds one).
    static func colours(_ pixels: Data) -> Int {
        var seen = Set<UInt32>()
        pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 4 <= raw.count {
                seen.insert(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 28
            }
        }
        return seen.count
    }

    /// The pixels of `view` drawn at 1x: what the comparisons compare.
    static func pixels(_ view: AnyView, size: CGSize) -> Data {
        let window = open(view, size: size, dark: false)
        defer { close(window) }
        guard let host = window.contentView, let rep = bitmap(host, scale: 1), let data = rep.bitmapData else { return Data() }
        return Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)
    }
}

/// The pictures folder (`QURANLAB_SHEET_PICTURES`) and its index.
@MainActor
enum SheetPictures {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["QURANLAB_SHEET_PICTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var index: [String] = []

    static func write<V: View>(_ view: V, size: CGSize, scale: CGFloat, dark: Bool, name: String, what: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = SheetHost.open(view, size: size, dark: dark)
        defer { SheetHost.close(window) }
        guard let host = window.contentView, let rep = SheetHost.bitmap(host, scale: scale),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent(name))
        index.append("\(name)\t\(Int(size.width))x\(Int(size.height)) pt at \(Int(scale))x\t\(what)")
    }

    @available(macOS 13.0, *)
    static func writeRendered<V: View>(_ view: V, size: CGSize, name: String, what: String) {
        guard let folder else { return }
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        renderer.scale = 3
        guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent(name))
        index.append("\(name)\t\(Int(size.width))x\(Int(size.height)) pt at 3x\t\(what)")
    }

    static func finish() {
        guard let folder else { return }
        try? (index.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
        print("sheet: \(index.count) pictures in \(folder.path)")
    }
}

/// What iOS draws around a sheet on a phone, for the pictures: the dimmed screen behind, the sheet from `top` down
/// with its top corners rounded (28). The sheet itself (from the grabber down) is the SDK's view.
struct PhoneCanvas<Sheet: View>: View {
    let size: CGSize
    let top: CGFloat
    let dark: Bool
    let sheet: Sheet

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: top)
            sheet.frame(width: size.width, height: size.height - top).clipShape(TopCorners(radius: 28))
        }
        .frame(width: size.width, height: size.height)
        .background(SheetRGB(hex: dark ? 0x0B0B0C : 0x5E5E63).color)
    }
}

/// A Mac's or a wide screen's card: the sheet centred, 480 wide, corner radius 28.
struct CardCanvas<Sheet: View>: View {
    let card: CGSize
    let dark: Bool
    let sheet: Sheet

    var body: some View {
        sheet.frame(width: card.width, height: card.height)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SheetRGB(hex: dark ? 0x0B0B0C : 0x5E5E63).color)
    }
}

struct TopCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                 startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The lines of the settings view other than its switch and buttons, as it draws them (the sheet's type, the deck's
/// direction), one under the other.
struct SettingsLines: View {
    let keys = ["what.detail", "delete.confirm", "delete.done", "delete.failed.title", "delete.failed.network",
                "recovery.keep", "recovery.hint", "thanks"]

    var body: some View {
        let copy = Contributions.copy
        let type = SheetType(theme: .standard, size: .large, rightToLeft: copy.rightToLeft)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(keys, id: \.self) { key in
                let words = copy.string(key)
                Text(SheetDirection.shown(words, rightToLeft: copy.rightToLeft))
                    .sheetStyle(type.style(.row, words), color: SheetTokens.light.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(SheetTokens.light.card.color)
        .environment(\.layoutDirection, copy.rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// The 3.1.0 sheet, line for line as it shipped (its buttons do nothing here): for the record of what made its text
/// heavy in a host app.
struct Sheet310: View {
    let theme = SharingTheme()
    private let copy = Contributions.copy
    @State private var confirmed = false

    private func line(_ key: String, _ font: Font? = nil, secondary: Bool = false) -> some View {
        let t = copy.string(key)
        return Group {
            if !t.isEmpty {
                Text(t).font(font ?? theme.bodyFont).foregroundColor(secondary ? theme.secondaryText : theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                line("sheet.title", theme.titleFont)
                line("sheet.body")
                line("sheet.hadith")
                line("sheet.hadith_ref", .footnote, secondary: true)
                line("sheet.mistakes")
                VStack(alignment: .leading, spacing: 8) {
                    line("sheet.what")
                    line("sheet.who")
                    line("sheet.control")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.secondaryText.opacity(0.3)))
                HStack(spacing: 12) {
                    choice(copy.string("sheet.share"))
                    choice(copy.string("sheet.not_now"))
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(theme.background)
        .environment(\.layoutDirection, Contributions.copy.rightToLeft ? .rightToLeft : .leftToRight)
    }

    private func choice(_ title: String) -> some View {
        Button(action: {}) {
            Text(title).font(theme.bodyFont.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundColor(theme.accent)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.accent, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
#endif
