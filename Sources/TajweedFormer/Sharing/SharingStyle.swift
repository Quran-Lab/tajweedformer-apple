#if canImport(SwiftUI)
import CoreText
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// How the SDK's sharing views look (SDK 3.1.1; the design is the contract's sharing_copy/design/README.md, the same on
// Apple, Android and the web): the colour tokens for light and dark, the colours derived from the theme's accent, the
// type scale with its line heights, the icons of the reference drawing, and the environment the views set for
// themselves, so that nothing the host app put in its environment (a font, a weight, a text size, a line limit, a case,
// an alignment) changes them. The words are the deck's; nothing here changes a word or the consent.

/// The name at the top of the consent sheet: a constant of the SDK, not a deck string, written in Latin letters in
/// every language, as the decks write it. A theme cannot change or hide it.
enum SharingBrand {
    static let name = "Quran Lab"
}

/// A colour as sRGB components (0 to 1, gamma encoded), for the sums the design asks for: a colour at some percent
/// over a background (CSS `color-mix` in srgb), relative luminance and contrast (WCAG 2).
struct SheetRGB: Equatable, Sendable {
    let r: Double
    let g: Double
    let b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = Self.unit(r)
        self.g = Self.unit(g)
        self.b = Self.unit(b)
    }

    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func contrast(with other: SheetRGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour at `amount` (0 to 1) over `base`.
    func at(_ amount: Double, over base: SheetRGB) -> SheetRGB {
        SheetRGB(base.r + (r - base.r) * amount, base.g + (g - base.g) * amount, base.b + (b - base.b) * amount)
    }

    static let white = SheetRGB(hex: 0xFFFFFF)
    static let nearBlack = SheetRGB(hex: 0x0B0B0C)
}

/// The design's colour tokens, light and dark.
struct SheetTokens: Sendable {
    let background: SheetRGB
    let text: SheetRGB
    let body: SheetRGB
    let secondary: SheetRGB
    let card: SheetRGB
    let divider: SheetRGB
    let barDivider: SheetRGB
    let grabber: SheetRGB
    /// Used only when the app's accent cannot be read (on Apple platforms the app always has one).
    let accent: SheetRGB

    static let light = SheetTokens(background: .init(hex: 0xFFFFFF), text: .init(hex: 0x17171A), body: .init(hex: 0x3D3D44),
                                   secondary: .init(hex: 0x62626B), card: .init(hex: 0xF4F4F6), divider: .init(hex: 0xE4E4E9),
                                   barDivider: .init(hex: 0xECECF0), grabber: .init(hex: 0xD4D4DA), accent: .init(hex: 0x0E6B58))
    static let dark = SheetTokens(background: .init(hex: 0x1C1C1E), text: .init(hex: 0xF4F4F6), body: .init(hex: 0xD2D2D8),
                                  secondary: .init(hex: 0xA7A7B0), card: .init(hex: 0x2A2A2D), divider: .init(hex: 0x3B3B40),
                                  barDivider: .init(hex: 0x2E2E32), grabber: .init(hex: 0x48484D), accent: .init(hex: 0x62D2B6))

    static func of(dark: Bool) -> SheetTokens { dark ? .dark : .light }
}

/// The colours of one drawing of a sharing view. Where the app's theme left a colour at its default the design's token
/// for light or dark is taken; where it set one, the theme's colour, and the card, the dividers, the grabber and the
/// body text are then mixed from the theme's text over its background (the same steps the tokens take), so a dark or
/// coloured theme keeps its contrast. The tint, the soft tint and the colour on the accent always come from the
/// accent. Contrast: running text never takes the accent and keeps 4.5 to 1; the accent carries
/// only the two button labels, the icons and the emblem's glyph, which need 3 to 1 against what is behind them, or
/// 4.5 to 1 when the device asks for more contrast.
struct SheetPalette {
    let background: Color
    let text: Color
    let body: Color
    let secondary: Color
    let card: Color
    let divider: Color
    let barDivider: Color
    let grabber: Color
    /// The share button's fill and the switch.
    let accent: Color
    let backgroundRGB: SheetRGB
    let textRGB: SheetRGB
    let accentRGB: SheetRGB
    /// The accent at 11 % over the background (16 % in dark mode): the emblem and the "Not now" button.
    let tintRGB: SheetRGB
    /// The accent at 6 % over the background (8 % in dark mode): the hadith's card.
    let softTintRGB: SheetRGB
    /// White when white has at least the bar against the accent, else near black: the share button's label.
    let onAccentRGB: SheetRGB
    /// The card (the disclosure icons stand on it).
    let cardRGB: SheetRGB
    /// What the button labels, the icons and the emblem's glyph need against what is behind them: 3 to 1, or 4.5 to
    /// 1 when the device asks for more contrast (Increase Contrast).
    let bar: Double
    /// The accent has less than the bar against the tint: the "Not now" label and the emblem's glyph take the text
    /// colour (the fills stay the tint).
    let labelFallback: Bool
    /// The accent has less than the bar against the card: the disclosure icons take the text colour.
    let iconFallback: Bool
    /// The theme's corner radius over the design's 14: every radius of the design is scaled by it.
    let radiusScale: CGFloat

    var tint: Color { tintRGB.color }
    var softTint: Color { softTintRGB.color }
    var onAccent: Color { onAccentRGB.color }
    /// The "Not now" label and the emblem's glyph: the accent, or the text colour where it misses the bar on the tint.
    var accentLabel: Color { labelFallback ? text : accent }
    /// The disclosure icons: the accent, or the text colour where it misses the bar on the card.
    var iconColor: Color { iconFallback ? text : accent }
    /// Accent-coloured text on the background (the settings view's buttons): the accent, or the text colour where it
    /// has less than 4.5 to 1 against the background.
    var accentText: Color { accentRGB.contrast(with: backgroundRGB) < 4.5 ? text : accent }

    /// - Parameters:
    ///   - increasedContrast: the device asks for more contrast: the bar is 4.5 to 1 instead of 3.
    ///   - resolve: the colour's sRGB components as the system draws it here (light or dark, the app's accent).
    init(theme: SharingTheme, dark: Bool, increasedContrast: Bool = false, resolve: (Color) -> SheetRGB?) {
        let t = SheetTokens.of(dark: dark)
        let ownBackground = theme.background != Color.clear
        let ownText = theme.text != Color.primary
        let ownSecondary = theme.secondaryText != Color.secondary
        let bg = ownBackground ? (resolve(theme.background) ?? t.background) : t.background
        let fg = ownText ? (resolve(theme.text) ?? t.text) : t.text
        let mixed = ownBackground || ownText
        func neutral(_ token: SheetRGB, _ light: Double, _ darkAmount: Double) -> Color {
            mixed ? fg.at(dark ? darkAmount : light, over: bg).color : token.color
        }
        backgroundRGB = bg
        textRGB = fg
        background = ownBackground ? theme.background : t.background.color
        text = ownText ? theme.text : t.text.color
        body = neutral(t.body, 0.836, 0.843)
        secondary = ownSecondary ? theme.secondaryText : neutral(t.secondary, 0.677, 0.644)
        card = neutral(t.card, 0.047, 0.065)
        cardRGB = mixed ? fg.at(dark ? 0.065 : 0.047, over: bg) : t.card
        divider = neutral(t.divider, 0.116, 0.144)
        barDivider = neutral(t.barDivider, 0.082, 0.083)
        grabber = neutral(t.grabber, 0.185, 0.204)
        accent = theme.accent
        let a = resolve(theme.accent) ?? t.accent
        accentRGB = a
        tintRGB = a.at(dark ? 0.16 : 0.11, over: bg)
        softTintRGB = a.at(dark ? 0.08 : 0.06, over: bg)
        bar = increasedContrast ? 4.5 : 3
        onAccentRGB = SheetRGB.white.contrast(with: a) >= bar ? .white : .nearBlack
        labelFallback = a.contrast(with: tintRGB) < bar
        iconFallback = a.contrast(with: cardRGB) < bar
        radiusScale = max(0, theme.cornerRadius) / 14
    }

    /// The colour of a deck line by its place on the sheet.
    func color(_ role: SheetRole) -> Color {
        switch role {
        case .body, .mistakes: return body
        case .reference: return secondary
        case .name, .title, .row, .hadith, .button: return text
        }
    }
}

/// Reads a SwiftUI colour as sRGB components.
enum SheetColor {
    /// The colour as the system draws it in `environment` (light or dark, the app's accent), or nil when the system
    /// cannot say.
    static func resolve(_ color: Color, in environment: EnvironmentValues) -> SheetRGB? {
        if #available(iOS 17.0, macOS 14.0, *) {
            let c = color.resolve(in: environment)
            return SheetRGB(Double(c.red), Double(c.green), Double(c.blue))
        }
        #if canImport(UIKit)
        let style: UIUserInterfaceStyle = environment.colorScheme == .dark ? .dark : .light
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return SheetRGB(Double(r), Double(g), Double(b))
        #elseif canImport(AppKit)
        // macOS 12 and 13: the colour in the current drawing appearance
        guard let s = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return SheetRGB(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
        #else
        return nil
        #endif
    }
}

/// The place of a text on the sheet, which gives its size, line height, weight and colour.
enum SheetRole: Sendable {
    case name, title, body, row, hadith, reference, mistakes, button

    /// The place of a deck line on the sheet.
    static func of(_ key: String) -> SheetRole {
        switch key {
        case "sheet.title", "sheet.guardian.title": return .title
        case "sheet.what", "sheet.who", "sheet.control", "sheet.guardian.confirm": return .row
        case "sheet.hadith": return .hadith
        case "sheet.hadith_ref": return .reference
        case "sheet.mistakes": return .mistakes
        case "sheet.share", "sheet.guardian.share", "sheet.not_now": return .button
        default: return .body
        }
    }
}

/// How the design's sizes grow with the system's text size: the steps of the system's own text styles (body for the
/// running text, title for the title, subheadline for the name, caption for the hadith's reference), from extra small
/// to the fifth accessibility size, as a factor of the default (large) size. The buttons follow the body up to the
/// first accessibility size, so that a label stays on one line where it can and takes two at most; the name follows
/// the subheadline up to the same size, so that it never crowds the title and the body off the first screen.
enum SheetCurve: Sendable {
    case body, title, subheadline, caption, button, name

    private static let body17: [Double] = [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]
    private static let title28: [Double] = [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58]
    private static let subheadline15: [Double] = [12, 13, 14, 15, 17, 19, 21, 25, 30, 36, 42, 49]
    private static let caption12: [Double] = [11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43]

    static func step(_ size: DynamicTypeSize) -> Int {
        switch size {
        case .xSmall: return 0
        case .small: return 1
        case .medium: return 2
        case .large: return 3
        case .xLarge: return 4
        case .xxLarge: return 5
        case .xxxLarge: return 6
        case .accessibility1: return 7
        case .accessibility2: return 8
        case .accessibility3: return 9
        case .accessibility4: return 10
        case .accessibility5: return 11
        @unknown default: return 3
        }
    }

    func factor(_ size: DynamicTypeSize) -> CGFloat {
        let i = Self.step(size)
        switch self {
        case .body: return CGFloat(Self.body17[i] / 17)
        case .title: return CGFloat(Self.title28[i] / 28)
        case .subheadline: return CGFloat(Self.subheadline15[i] / 15)
        case .caption: return CGFloat(Self.caption12[i] / 12)
        case .button: return CGFloat(Self.body17[min(i, 7)] / 17)
        case .name: return CGFloat(Self.subheadline15[min(i, 7)] / 15)
        }
    }
}

/// How one text is drawn.
struct SheetTextStyle {
    let font: Font
    /// The design's line height less the font's own, between lines; half of it also goes above the first line and
    /// below the last, as a CSS line height does.
    let lineSpacing: CGFloat
    let tracking: CGFloat
    let uppercase: Bool
    /// The height of the first line as drawn: what an icon beside the text is centred on.
    let firstLine: CGFloat
}

/// The sheet's type: the system font at the design's sizes, weights and line heights (Latin decks and right to left
/// decks), grown by the system's text size. A theme's own title or body font replaces the system font for those texts.
struct SheetType {
    let size: DynamicTypeSize
    /// The deck is right to left (Arabic, Urdu): the design's taller line heights.
    let rightToLeft: Bool
    let titleFont: Font?
    let bodyFont: Font?

    init(theme: SharingTheme, size: DynamicTypeSize, rightToLeft: Bool) {
        self.size = size
        self.rightToLeft = rightToLeft
        // the defaults of SharingTheme's initialiser mean "the sheet's own type"
        titleFont = theme.titleFont == Font.title2.weight(.semibold) ? nil : theme.titleFont
        bodyFont = theme.bodyFont == Font.body ? nil : theme.bodyFont
    }

    struct Spec {
        let size: CGFloat
        let line: CGFloat
        let weight: Font.Weight
        let trackingEm: CGFloat
        let curve: SheetCurve
    }

    /// The design's numbers at the default text size.
    func spec(_ role: SheetRole) -> Spec {
        let r = rightToLeft
        switch role {
        case .name: return Spec(size: 15, line: 20, weight: .semibold, trackingEm: -0.01, curve: .name)
        case .title: return Spec(size: 26, line: r ? 36 : 31, weight: .bold, trackingEm: -0.02, curve: .title)
        case .body: return Spec(size: 15.5, line: r ? 27 : 24, weight: .regular, trackingEm: 0, curve: .body)
        case .row: return Spec(size: 14.5, line: r ? 25 : 22, weight: .regular, trackingEm: 0, curve: .body)
        case .hadith: return Spec(size: 15, line: r ? 28 : 24, weight: .regular, trackingEm: 0, curve: .body)
        case .reference: return Spec(size: 12, line: 16, weight: .semibold, trackingEm: 0.06, curve: .caption)
        case .mistakes: return Spec(size: 15, line: r ? 27 : 24, weight: .regular, trackingEm: 0, curve: .body)
        case .button: return Spec(size: 16, line: 20, weight: .semibold, trackingEm: 0, curve: .button)
        }
    }

    /// The icons and the emblem grow with the text, to one and a half times their size at most.
    var iconScale: CGFloat { min(SheetCurve.body.factor(size), 1.5) }

    /// How `text` is drawn in `role`. Tracking and upper case apply to Latin script only.
    func style(_ role: SheetRole, _ text: String) -> SheetTextStyle {
        let s = spec(role)
        let f = s.curve.factor(size)
        let points = (s.size * f * 2).rounded() / 2
        let line = (s.line * f).rounded()
        let natural = SheetMetrics.lineHeight(text, size: points, weight: s.weight)
        let latin = SheetMetrics.isLatin(text)
        var font = Font.system(size: points, weight: s.weight, design: .default)
        var own = false
        switch role {
        case .title:
            if let t = titleFont { font = t; own = true }
        case .body, .row, .hadith, .mistakes:
            if let b = bodyFont { font = b; own = true }
        case .button:
            if let b = bodyFont { font = b.weight(.semibold); own = true }
        case .name, .reference:
            break
        }
        // a script taller than Latin in a left to right deck (Bengali): the design gives Latin line heights, which
        // would leave its lines touching, so at least a quarter of the size goes between them
        var spacing = max(0, line - natural)
        if !rightToLeft && SheetMetrics.isOtherScript(text) { spacing = max(spacing, (points * 0.25).rounded()) }
        return SheetTextStyle(font: font, lineSpacing: spacing,
                              tracking: latin && !own ? s.trackingEm * points : 0,
                              uppercase: role == .reference && latin, firstLine: max(line, natural + spacing))
    }
}

/// Font measures for the line heights.
enum SheetMetrics {
    private static let cache = Locked<[String: CGFloat]>([:])

    /// The height of one line of `text` in the system font: the tallest ascent, descent and leading of the fonts the
    /// system draws it with (Arabic or Bengali is drawn with the system's face for that script, which is taller than
    /// the Latin one).
    static func lineHeight(_ text: String, size: CGFloat, weight: Font.Weight) -> CGFloat {
        let w = weight == .bold ? 2 : (weight == .semibold ? 1 : 0)
        let key = "\(size) \(w) \(text)"
        if let h = cache.withLock({ $0[key] }) { return h }
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size, weight: w == 2 ? .bold : (w == 1 ? .semibold : .regular))
        #elseif canImport(AppKit)
        let font = NSFont.systemFont(ofSize: size, weight: w == 2 ? .bold : (w == 1 ? .semibold : .regular))
        #endif
        let sample = text.isEmpty ? "Ag" : text
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let h = (ascent + descent + leading).rounded(.up)
        cache.withLock { if $0.count > 512 { $0.removeAll() }; $0[key] = h }
        return h
    }

    /// The text has letters and some of them are not Latin.
    static func isOtherScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { u in
            u.properties.isAlphabetic && u.value > 0x024F && !(0x1E00...0x1EFF).contains(u.value)
        }
    }

    /// The text's letters are Latin.
    static func isLatin(_ text: String) -> Bool {
        var letters = 0
        for u in text.unicodeScalars where u.properties.isAlphabetic {
            letters += 1
            if u.value > 0x024F && !(0x1E00...0x1EFF).contains(u.value) { return false }
        }
        return letters > 0
    }
}

extension Text {
    /// The text in `style`: its font, tracking, colour and line spacing, with half of the spacing above the first line
    /// and below the last.
    func sheetStyle(_ style: SheetTextStyle, color: Color) -> some View {
        font(style.font).tracking(style.tracking).foregroundColor(color)
            .lineSpacing(style.lineSpacing)
            .padding(.vertical, style.lineSpacing / 2)
            .textCase(style.uppercase ? Text.Case.uppercase : nil)
    }
}

/// The icons of the reference drawing: strokes on a 24 by 24 grid, drawn to the frame they are given.
struct SheetGlyph: Shape {
    enum Kind: Sendable { case waveform, microphone, shield, toggle }
    let kind: Kind
    /// Right to left: the toggle's knob is at the other end (the drawing's Arabic screen). The others do not turn.
    var mirrored = false

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let x0 = rect.midX - 12 * s, y0 = rect.midY - 12 * s
        let flip = mirrored
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + (flip ? 24 - x : x) * s, y: y0 + y * s) }
        var path = Path()
        switch kind {
        case .waveform:
            let strokes: [(CGFloat, CGFloat, CGFloat)] = [(4, 10, 14), (8, 7, 17), (12, 4, 20), (16, 7, 17), (20, 10, 14)]
            for (x, top, bottom) in strokes {
                path.move(to: p(x, top))
                path.addLine(to: p(x, bottom))
            }
        case .microphone:
            path.addRoundedRect(in: CGRect(x: x0 + 9 * s, y: y0 + 3 * s, width: 6 * s, height: 11 * s),
                                cornerSize: CGSize(width: 3 * s, height: 3 * s))
            // the holder: the lower half of a circle of radius 6.5 around (12, 11.5)
            let n = 24
            for i in 0...n {
                let a = CGFloat.pi * (1 - CGFloat(i) / CGFloat(n))
                let q = p(12 + 6.5 * cos(a), 11.5 + 6.5 * sin(a))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.move(to: p(12, 18))
            path.addLine(to: p(12, 21))
        case .shield:
            path.move(to: p(12, 3))
            path.addLine(to: p(19, 6))
            path.addLine(to: p(19, 11.5))
            path.addCurve(to: p(12, 21), control1: p(19, 15.8), control2: p(16.1, 19.1))
            path.addCurve(to: p(5, 11.5), control1: p(7.9, 19.1), control2: p(5, 15.8))
            path.addLine(to: p(5, 6))
            path.closeSubpath()
            path.move(to: p(9, 12))
            path.addLine(to: p(11.2, 14.2))
            path.addLine(to: p(15.2, 10))
        case .toggle:
            path.addRoundedRect(in: CGRect(x: x0 + 2.5 * s, y: y0 + 7 * s, width: 19 * s, height: 10 * s),
                                cornerSize: CGSize(width: 5 * s, height: 5 * s))
            let c = p(16.5, 12)
            path.addEllipse(in: CGRect(x: c.x - 2.4 * s, y: c.y - 2.4 * s, width: 4.8 * s, height: 4.8 * s))
        }
        return path
    }
}

/// An icon of the sheet: decoration, hidden from screen readers.
struct SheetIcon: View {
    let kind: SheetGlyph.Kind
    var mirrored = false
    let size: CGFloat
    /// The stroke on the 24 point grid (the drawing: 1.9 for the emblem, 1.8 for the rows).
    let stroke: CGFloat
    let color: Color

    var body: some View {
        SheetGlyph(kind: kind, mirrored: mirrored)
            .stroke(color, style: StrokeStyle(lineWidth: stroke * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A phone sheet (the grabber, the full width) or a centred card (a wide screen, a Mac).
enum SheetLayout: Sendable { case phone, card }

/// How a test draws a sheet for the release's pictures and its layout checks. In an app every field is at its
/// default: the layout from the screen, the system's text size and Bold Text, the scroll at the top.
struct SheetRender {
    var layout: SheetLayout?
    var textSize: DynamicTypeSize?
    var boldText: Bool?
    var scrolledToEnd = false
    /// The guardian's switch starts on.
    var confirmed = false
    /// The bottom safe area of the device drawn (a phone with a home indicator: 34).
    var bottomInset: CGFloat?
    var showsIndicators = true
    /// The device asks for more contrast (nil: the system's setting).
    var increasedContrast: Bool?
}

/// The system's own settings the sheet follows: not the host app's environment.
enum SheetSystem {
    /// The learner's text size: on iOS the system's Larger Text setting; macOS has none, so the default.
    @MainActor static var textSize: DynamicTypeSize {
        #if os(iOS)
        return DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large
        #else
        return .large
        #endif
    }

    /// The system's Increase Contrast setting (iOS and macOS).
    @MainActor static var increasedContrast: Bool {
        #if os(iOS)
        return UIAccessibility.isDarkerSystemColorsEnabled
        #elseif os(macOS)
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        #else
        return false
        #endif
    }

    /// The system's Bold Text setting (iOS).
    @MainActor static var boldText: Bool {
        #if os(iOS)
        return UIAccessibility.isBoldTextEnabled
        #else
        return false
        #endif
    }
}

/// Everything one drawing of a sharing view needs: its colours, its type and its layout.
struct SheetContext {
    let palette: SheetPalette
    let type: SheetType
    let layout: SheetLayout
    let rightToLeft: Bool
    let textSize: DynamicTypeSize
    let boldText: Bool

    @MainActor
    init(theme: SharingTheme, environment: EnvironmentValues, rightToLeft: Bool, render: SheetRender) {
        let dark = environment.colorScheme == .dark
        palette = SheetPalette(theme: theme, dark: dark, increasedContrast: render.increasedContrast ?? SheetSystem.increasedContrast) {
            SheetColor.resolve($0, in: environment)
        }
        textSize = render.textSize ?? SheetSystem.textSize
        boldText = render.boldText ?? SheetSystem.boldText
        type = SheetType(theme: theme, size: textSize, rightToLeft: rightToLeft)
        self.rightToLeft = rightToLeft
        #if os(iOS)
        layout = render.layout ?? (environment.horizontalSizeClass == .regular ? .card : .phone)
        #else
        layout = render.layout ?? .card
        #endif
    }

    var radius: CGFloat { palette.radiusScale }

    /// A deck line as drawn, its paragraph direction the deck's (`SheetDirection.shown`).
    func shown(_ text: String) -> String { SheetDirection.shown(text, rightToLeft: rightToLeft) }
}

/// The paragraph direction of every text the sharing views draw is the deck's `dir`, never the first strong letter of
/// the line. SwiftUI's Text takes no paragraph style (an attributed string's base writing direction is not applied),
/// and it lays a paragraph out in the direction of its first strong letter: an Arabic or Urdu line that begins with
/// the Latin name Quran Lab came out left to right, the name at the left end and the full stop on the wrong side.
/// So each paragraph of a line is drawn after the deck's direction mark (U+200F in a right to left deck, U+200E in a
/// left to right one), which makes that mark its first strong character. The mark is not a word and is not read: the
/// tests compare the deck's own text, and a screen reader is given the deck's text without it.
enum SheetDirection {
    static func shown(_ text: String, rightToLeft: Bool) -> String {
        guard !text.isEmpty else { return text }
        let mark = rightToLeft ? "\u{200F}" : "\u{200E}"
        return mark + text.replacingOccurrences(of: "\n", with: "\n" + mark)
    }

    /// The direction a text engine gives the paragraph of `text` when nothing else decides it (its first strong
    /// letter): true for right to left. Core Text lays the text out on one line; the caret at the paragraph's start
    /// (string index 0) is at the line's left edge in a left to right paragraph and at its right edge in a right to
    /// left one.
    static func resolvedRightToLeft(_ text: String) -> Bool {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return CTLineGetOffsetForStringIndex(line, 0, nil) > width / 2
    }
}

/// What every sharing view sets for itself, so that the host app's environment cannot change how it looks: the
/// deck's layout direction, the system's text size and Bold Text setting (not a size or weight the host set on its
/// views), no font weight, design, style or tracking from above, every line whole (no line limit, no shrinking, no
/// case change), leading alignment, regular controls, no placeholder redaction.
struct SheetEnvironment: ViewModifier {
    let rightToLeft: Bool
    let textSize: DynamicTypeSize
    let boldText: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .lineLimit(nil)
            .minimumScaleFactor(1)
            .allowsTightening(false)
            .textCase(nil)
            .multilineTextAlignment(.leading)
            .environment(\.legibilityWeight, boldText ? LegibilityWeight.bold : LegibilityWeight.regular)
            .dynamicTypeSize(textSize)
            .controlSize(.regular)
            .unredacted()
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        if #available(iOS 16.1, macOS 13.0, *) {
            base.fontWeight(nil).bold(false).italic(false).fontDesign(nil)
                .underline(false).strikethrough(false).kerning(0).tracking(0).baselineOffset(0)
        } else if #available(iOS 16.0, macOS 13.0, *) {
            base.fontWeight(nil).bold(false).italic(false)
                .underline(false).strikethrough(false).kerning(0).tracking(0).baselineOffset(0)
        } else {
            base
        }
    }
}

extension View {
    /// The SDK's sheet as iOS presents it: the large detent, no system grabber (the sheet draws its own), the design's
    /// corner radius and background. Nothing elsewhere: a Mac's sheet is the system's window.
    @ViewBuilder
    func sharingSheetPresentation(radius: CGFloat, background: Color) -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            self.presentationDetents([.large]).presentationDragIndicator(.hidden)
                .presentationCornerRadius(radius).presentationBackground(background)
        } else if #available(iOS 16.0, *) {
            self.presentationDetents([.large]).presentationDragIndicator(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Where a test reads this view's frame (nothing is recorded in an app).
    func sheetProbe(_ key: String) -> some View {
        background(GeometryReader { g in
            Color.clear.onAppear { SheetProbe.place(key, g.frame(in: .global)) }
        })
    }
}

#if os(iOS)
/// The SDK's sheet in a UIKit presentation: a sheet at the large detent on a phone, a centred card 480 wide on a
/// wide screen, the design's corner radius, no system grabber.
@MainActor
enum SheetPresentation {
    static func configure(_ controller: UIViewController, radius: CGFloat) {
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 480, height: 720)
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = radius
        }
    }
}
#endif

/// What the tests read of a drawn sheet. Each is nil (nothing recorded) unless a test sets it to an empty dictionary.
@MainActor
enum SheetProbe {
    /// The deck line drawn for each key, and the name under "name".
    static var lines: [String: String]?
    /// The string each line is drawn with (the deck line, after a right to left mark in a right to left deck).
    static var shown: [String: String]?
    /// Frames in the window: the buttons ("share", "not_now"), the emblem and the name.
    static var frames: [String: CGRect]?
    /// Whether each button can be tapped.
    static var enabled: [String: Bool]?

    static func drew(_ key: String, _ text: String) { lines?[key] = text }
    static func showed(_ key: String, _ text: String) { shown?[key] = text }
    static func place(_ key: String, _ frame: CGRect) { frames?[key] = frame }
    static func state(_ key: String, _ on: Bool) { enabled?[key] = on }
}
#endif
