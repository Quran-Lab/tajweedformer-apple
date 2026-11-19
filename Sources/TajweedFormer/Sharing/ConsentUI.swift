#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// How the SDK's sharing views look in the app: colours, corner radius and fonts. The words are the deck's, and a
/// theme never changes the sheet's structure or hides a line. `accent` fills the share button and the switch; the
/// "Not now" button's fill, the emblem's and the hadith's (the accent at a few percent over the background) and the
/// share button's label (white where white reads on the accent, else near black) are derived from it, and where the
/// accent cannot be read on what is behind it (3 to 1, or 4.5 to 1 when the device asks for more contrast) the "Not
/// now" label and the icons take the text colour. `background`, `text`
/// and `secondaryText` left at their defaults give the sheet's own colours for light and dark; set, the cards, the
/// dividers and the body text are mixed from them. `cornerRadius` is the buttons' (the cards', the emblem's and the
/// sheet's radii scale with it). `titleFont` and `bodyFont` left at their defaults give the sheet's own type, which
/// follows the system's text size.
public struct SharingTheme: Sendable {
    public var accent: Color
    public var background: Color
    public var text: Color
    public var secondaryText: Color
    public var cornerRadius: CGFloat
    public var titleFont: Font
    public var bodyFont: Font

    public init(accent: Color = .accentColor, background: Color = Color.clear, text: Color = .primary,
                secondaryText: Color = .secondary, cornerRadius: CGFloat = 14, titleFont: Font = .title2.weight(.semibold),
                bodyFont: Font = .body) {
        self.accent = accent; self.background = background; self.text = text; self.secondaryText = secondaryText
        self.cornerRadius = cornerRadius; self.titleFont = titleFont; self.bodyFont = bodyFont
    }

    public static let standard = SharingTheme()
}

extension Contributions {
    private static let themeState = Locked<SharingTheme>(.standard)

    /// The theme of the SDK's sheets where the app passes none: the sheet the SDK presents by itself (no
    /// `.quranLabSharing()`), and the default of `.quranLabSharing()` and the views. Colours, corner radius and fonts
    /// only: the words stay the deck's (or the app's own wording), and the consent version does not change.
    static var theme: SharingTheme {
        get { themeState.withLock { $0 } }
        set { themeState.withLock { $0 = newValue } }
    }
}

/// The consent sheet: why sharing helps, what is shared, who receives it, how to stop, and two buttons of equal
/// weight. Nothing is pre-ticked. Every app shows this same sheet (SDK 4.0, contract section 26), and the learner's
/// tap is the answer.
public struct SharingConsentView: View {
    let reask: Bool
    let theme: SharingTheme
    let render: SheetRender
    let onDone: @MainActor (Bool) -> Void
    @Environment(\.self) private var environment
    private let copy = Contributions.copy

    /// - Parameters:
    ///   - client: the app's Client.
    ///   - reask: the gentler wording of a second or third ask.
    ///   - onDone: called with the learner's answer once a button was tapped.
    public init(_ client: TajweedClient, reask: Bool = false, theme: SharingTheme = .standard,
                onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.init(reask: reask, theme: theme, render: SheetRender(), onDone: onDone)
    }

    init(reask: Bool = false, theme: SharingTheme = Contributions.theme, render: SheetRender = SheetRender(),
         onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.reask = reask
        self.theme = theme
        self.render = render
        self.onDone = onDone
    }

    public var body: some View {
        let ctx = SheetContext(theme: theme, environment: environment, rightToLeft: copy.rightToLeft, render: render)
        ConsentSheet(copy: copy, ctx: ctx, reask: reask, render: render, onDone: onDone)
    }
}

/// The sheet as drawn (the contract's sharing_copy/design/README.md): a grabber on a phone, one scrolling column (the
/// header with the emblem and the name, the title, the re-ask line, the body, the disclosure card, the hadith, the
/// mistakes line), and a bar at the bottom that does not scroll, with the two buttons.
private struct ConsentSheet: View {
    let copy: SharingCopy
    let ctx: SheetContext
    let reask: Bool
    let render: SheetRender
    let onDone: @MainActor (Bool) -> Void

    private var palette: SheetPalette { ctx.palette }
    /// The deck's language for the texts (a Turkish reference in upper case keeps its dotted capital I); Urdu is set
    /// in the system's Arabic face, as the design says, so it is drawn as Arabic.
    private var locale: Locale { Locale(identifier: copy.lang == "ur" ? "ar" : copy.lang) }
    private var r: CGFloat { ctx.radius }
    private static let content = "quranlab.sharing.sheet.content"
    /// Under the grabber, inside its band; the column's 20 above the header counts from the grabber's bottom edge, as
    /// the drawing measures it, so the header stays where the drawing has it.
    static let underGrabber: CGFloat = 7

    var body: some View {
        // the layout runs to the sheet's bottom edge, and the bar pads its buttons by 30 or the bottom safe area,
        // whichever is larger: the same sum on a phone with a home indicator (34), one with a home button, an iPad's
        // card and a Mac (none), and in the tests' drawings (which name the safe area they stand for)
        GeometryReader { proxy in
            let inset = render.bottomInset ?? proxy.safeAreaInsets.bottom
            VStack(spacing: 0) {
                if ctx.layout == .phone {
                    // the grabber's band (8 above the grabber, 7 below): the column's viewport begins under it, so
                    // nothing of the column is ever drawn there and the top fade sits inside the viewport
                    Capsule().fill(palette.grabber).frame(width: 36, height: 5)
                        .padding(.top, 8).padding(.bottom, Self.underGrabber)
                        .frame(maxWidth: .infinity)
                        .background(palette.background)
                        .accessibilityHidden(true)
                }
                column
                bar(inset: inset)
            }
            .frame(maxWidth: ctx.layout == .card ? 480 : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .background(palette.background.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: ctx.layout == .card ? 360 : 0, idealWidth: 480, maxWidth: .infinity,
               minHeight: ctx.layout == .card ? 440 : 0, idealHeight: 680, maxHeight: .infinity)
        #endif
        .modifier(SheetEnvironment(rightToLeft: ctx.rightToLeft, textSize: ctx.textSize, boldText: ctx.boldText))
        .sharingSheetPresentation(radius: 28 * r, background: palette.background)
    }

    // MARK: the column

    private var column: some View {
        ScrollViewReader { scroller in
            let scroll = ScrollView(.vertical, showsIndicators: render.showsIndicators) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        line("sheet.title")
                    }
                    if reask { line("reask") }
                    line("sheet.body")
                    disclosure
                    if copy.hadithVerified { hadith }
                    line("sheet.mistakes")
                }
                .padding(.top, ctx.layout == .phone ? 20 - Self.underGrabber : 20)
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: SheetContentFrame.self, value: g.frame(in: .named(Self.content)))
                })
                .id(Self.content)
                .onAppear { if render.scrolledToEnd { scroller.scrollTo(Self.content, anchor: .bottom) } }
            }
            .coordinateSpace(name: Self.content)
            .overlayPreferenceValue(SheetContentFrame.self) { frame in
                SheetFades(content: frame, background: palette.backgroundRGB)
            }
            if #available(iOS 17.0, macOS 14.0, *) {
                scroll.defaultScrollAnchor(render.scrolledToEnd ? UnitPoint.bottom : nil)
            } else {
                scroll
            }
        }
    }

    /// The emblem and the name, one row: the emblem first in reading order (at the right in a right to left sheet).
    private var header: some View {
        let icon = 22 * ctx.type.iconScale
        let box = 40 * ctx.type.iconScale
        SheetProbe.drew("name", SharingBrand.name)
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12 * r, style: .continuous).fill(palette.tint)
                SheetIcon(kind: .waveform, size: icon, stroke: 1.9, color: palette.accentLabel)
            }
            .frame(width: box, height: box)
            .accessibilityHidden(true)
            .sheetProbe("emblem")
            Text(verbatim: SharingBrand.name)
                .sheetStyle(ctx.type.style(.name, SharingBrand.name), color: palette.text)
                .fixedSize()
                .sheetProbe("name")
        }
    }

    /// One deck line, whole, in the style of its place on the sheet (`SheetRole.of`).
    private func line(_ key: String) -> some View {
        let t = copy.string(key)
        let role = SheetRole.of(key)
        let style = ctx.type.style(role, t)
        SheetProbe.drew(key, t)
        SheetProbe.showed(key, ctx.shown(t))
        return Group {
            if !t.isEmpty {
                Text(ctx.shown(t)).sheetStyle(style, color: palette.color(role))
                    .accessibilityLabel(Text(verbatim: t))
                    .environment(\.locale, locale)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(role == .title ? .isHeader : [])
            }
        }
    }

    /// What is shared, who receives it, how to stop: one card, three rows, each one element for a screen reader.
    private var disclosure: some View {
        VStack(spacing: 0) {
            row(.microphone) { line("sheet.what") }
            divider
            row(.shield) { line("sheet.who") }
            divider
            row(.toggle) { line("sheet.control") }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 18 * r, style: .continuous).fill(palette.card))
    }

    private var divider: some View {
        Rectangle().fill(palette.divider).frame(height: 1).accessibilityHidden(true)
    }

    /// An icon at the leading edge, centred on the first line of the text beside it.
    private func row<Line: View>(_ kind: SheetGlyph.Kind, @ViewBuilder _ text: () -> Line) -> some View {
        let icon = 22 * ctx.type.iconScale
        let first = ctx.type.style(.row, copy.string("sheet.what")).firstLine
        return HStack(alignment: .top, spacing: 12) {
            SheetIcon(kind: kind, mirrored: kind == .toggle && ctx.rightToLeft, size: icon, stroke: 1.8, color: palette.iconColor)
                .padding(.top, max(0, (first - icon) / 2))
            text()
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var hadith: some View {
        VStack(alignment: .leading, spacing: 10) {
            line("sheet.hadith")
            line("sheet.hadith_ref")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18 * r, style: .continuous).fill(palette.softTint))
    }

    // MARK: the bar

    /// The fixed bar: the share button (the accent) and "Not now" (the tint), the same size, shape and type. Both can
    /// be tapped at once: the learner's tap is the answer.
    private func bar(inset: CGFloat) -> some View {
        let share = copy.string("sheet.share")
        let notNow = copy.string("sheet.not_now")
        SheetProbe.drew("sheet.share", share)
        SheetProbe.drew("sheet.not_now", notNow)
        SheetProbe.showed("sheet.share", ctx.shown(share))
        SheetProbe.showed("sheet.not_now", ctx.shown(notNow))
        SheetProbe.state("share", true)
        SheetProbe.state("not_now", true)
        return VStack(spacing: 10) {
            Button {
                Contributions.answer(share: true)
                onDone(true)
            } label: {
                label(share, both: [share, notNow], color: palette.onAccent)
            }
            .buttonStyle(SheetButtonStyle(fill: palette.accent, radius: 14 * r))
            .sheetProbe("share")
            Button {
                Contributions.answer(share: false)
                onDone(false)
            } label: {
                label(notNow, both: [share, notNow], color: palette.accentLabel)
            }
            .buttonStyle(SheetButtonStyle(fill: palette.tint, radius: 14 * r))
            .sheetProbe("not_now")
        }
        .padding(.top, 12)
        .padding(.horizontal, 24)
        .padding(.bottom, max(30, inset))
        .frame(maxWidth: .infinity)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.barDivider).frame(height: 1).accessibilityHidden(true)
        }
    }

    /// A button's label. Both labels are laid out, unseen, in each button, so the two buttons always have the height
    /// of the taller label: the same size whatever the language and the text size.
    private func label(_ title: String, both: [String], color: Color) -> some View {
        ZStack {
            ForEach(0..<both.count, id: \.self) { i in
                buttonText(both[i], color: .clear).hidden().accessibilityHidden(true)
            }
            buttonText(title, color: color)
        }
        .frame(maxWidth: .infinity)
    }

    private func buttonText(_ title: String, color: Color) -> some View {
        Text(ctx.shown(title)).sheetStyle(ctx.type.style(.button, title), color: color)
            .accessibilityLabel(Text(verbatim: title))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The two buttons of the sheet: full width, 52 high (taller only when a larger text size or a second line needs
/// it), filled, no stroke.
struct SheetButtonStyle: ButtonStyle {
    let fill: Color
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// Where the column's content is, in the scroll view's own space.
struct SheetContentFrame: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The sheet's background faded over the column's edges: 40 points above the bar while more is below, 28 under the
/// top while the column is scrolled. Never an animation.
struct SheetFades: View {
    let content: CGRect
    let background: SheetRGB

    var body: some View {
        GeometryReader { viewport in
            let above = content.height > 0 && content.minY < -0.5
            let below = content.height > 0 && content.maxY > viewport.size.height + 0.5
            VStack(spacing: 0) {
                LinearGradient(colors: [background.color, background.color.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .opacity(above ? 1 : 0)
                Spacer(minLength: 0)
                LinearGradient(colors: [background.color.opacity(0), background.color], startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
                    .opacity(below ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The thank-you line with its du'a, and (when the server answers) the learner's real shared minutes.
public struct SharingThanksView: View {
    let theme: SharingTheme
    let render: SheetRender
    @State private var impact: String?
    @Environment(\.self) private var environment
    public init(_ client: TajweedClient, theme: SharingTheme = .standard) { self.init(theme: theme) }
    init(theme: SharingTheme = Contributions.theme, render: SheetRender = SheetRender()) { self.theme = theme; self.render = render }
    public var body: some View {
        let copy = Contributions.copy
        let ctx = SheetContext(theme: theme, environment: environment, rightToLeft: copy.rightToLeft, render: render)
        let thanks = copy.string("thanks")
        VStack(alignment: .leading, spacing: 8) {
            Text(ctx.shown(thanks)).sheetStyle(ctx.type.style(.body, thanks), color: ctx.palette.text)
                .accessibilityLabel(Text(verbatim: thanks))
                .fixedSize(horizontal: false, vertical: true)
            if let impact {
                Text(ctx.shown(impact)).sheetStyle(ctx.type.style(.row, impact), color: ctx.palette.secondary)
                    .accessibilityLabel(Text(verbatim: impact))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(ctx.palette.background)
        .modifier(SheetEnvironment(rightToLeft: copy.rightToLeft, textSize: ctx.textSize, boldText: ctx.boldText))
        .sharingSheetPresentation(radius: 28 * ctx.radius, background: ctx.palette.background)
        .task {
            if let s = await Contributions.summary(), s.myMinutes >= 1 { impact = Contributions.copy.impact(minutes: s.myMinutes) }
        }
    }
}

/// The sharing settings: the switch, "What is shared", "Delete what I shared" (with its confirmation), and the
/// learner's recovery code for a lost device (revealed on tap, shown only here). Works whatever Quran Lab's switch says, so a learner can always stop and delete.
public struct SharingSettingsView: View {
    let theme: SharingTheme
    let render: SheetRender
    /// Drawn as a screen of its own (the view controllers): the sheet's background where the theme sets none.
    let opaque: Bool
    @State private var on = Contributions.consent == .granted
    @State private var showWhat = false
    @State private var confirmDelete = false
    @State private var deleted = false
    @State private var deleteFailed = false
    @State private var showCode = false
    @Environment(\.self) private var environment
    private let copy = Contributions.copy

    public init(_ client: TajweedClient, theme: SharingTheme = .standard) { self.init(theme: theme) }
    init(theme: SharingTheme = Contributions.theme, render: SheetRender = SheetRender(), opaque: Bool = false) {
        self.theme = theme
        self.render = render
        self.opaque = opaque
    }

    private func delete() {
        confirmDelete = false
        deleteFailed = false
        Task {
            if (try? await Contributions.deleteShared()) != nil { deleted = true } else { deleteFailed = true }
        }
    }

    public var body: some View {
        let ctx = SheetContext(theme: theme, environment: environment, rightToLeft: copy.rightToLeft, render: render)
        let p = ctx.palette
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: Binding(get: { on }, set: { v in
                on = v
                Task { await Contributions.setSharing(v) }
            })) { text(ctx, copy.string("settings.toggle"), .body, p.text) }
                .toggleStyle(SwitchToggleStyle())
                .tint(p.accent)
            Button { showWhat.toggle() } label: { text(ctx, copy.string("settings.what"), .button, p.accentText) }
                .buttonStyle(.plain)
            if showWhat {
                ForEach(Contributions.whatIsShared, id: \.self) { text(ctx, $0, .row, p.secondary) }
            }
            Button { confirmDelete = true } label: { text(ctx, copy.string("settings.delete"), .button, p.accentText) }
                .buttonStyle(.plain)
            if confirmDelete {
                VStack(alignment: .leading, spacing: 8) {
                    text(ctx, copy.string("delete.confirm"), .row, p.text)
                    HStack {
                        Button { delete() } label: { text(ctx, copy.string("delete.action"), .button, p.accentText) }
                            .buttonStyle(.plain)
                        Button { confirmDelete = false } label: { text(ctx, copy.string("delete.cancel"), .button, p.accentText) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if deleted { text(ctx, copy.string("delete.done"), .row, p.secondary) }
            if deleteFailed {
                VStack(alignment: .leading, spacing: 8) {
                    text(ctx, copy.string("delete.failed.title"), .button, p.text)
                    text(ctx, copy.string("delete.failed.network"), .row, p.secondary)
                    Button { delete() } label: { text(ctx, copy.string("delete.retry"), .button, p.accentText) }
                        .buttonStyle(.plain)
                }
            }
            if let code = Contributions.recoveryCodeForDisplay {
                Button { showCode.toggle() } label: {
                    if showCode {
                        Text(code).font(.system(size: (15.5 * SheetCurve.body.factor(ctx.textSize) * 2).rounded() / 2, weight: .regular, design: .monospaced))
                            .foregroundColor(p.accentText)
                    } else {
                        text(ctx, copy.string("recovery.reveal"), .button, p.accentText)
                    }
                }
                .buttonStyle(.plain)
                if showCode {
                    text(ctx, copy.string("recovery.keep"), .row, p.secondary)
                }
                text(ctx, copy.string("recovery.hint"), .row, p.secondary)
            }
        }
        .padding(16)
        .background(opaque || theme.background != Color.clear ? p.background : Color.clear)
        .modifier(SheetEnvironment(rightToLeft: copy.rightToLeft, textSize: ctx.textSize, boldText: ctx.boldText))
    }

    /// A text of the settings in the sheet's type scale.
    private func text(_ ctx: SheetContext, _ words: String, _ role: SheetRole, _ color: Color) -> some View {
        Text(ctx.shown(words)).sheetStyle(ctx.type.style(role, words), color: color)
            .accessibilityLabel(Text(verbatim: words))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shows the SDK's sheet, card and thank-you at the moments the SDK picks (the end of a good take, once the moment has
/// settled). Put it once near the root of the app: `.quranLabSharing(client)`.
@MainActor
final class SharingPromptModel: ObservableObject {
    static let shared = SharingPromptModel()
    @Published var moment: SharingMoment?
    var installed = false

    /// The consent sheet or the thank-you is up (a card is an overlay of the app's view, not a sheet).
    var sheetUp: Bool {
        switch moment {
        case .ask(_)?, .thanks?: return true
        case .card?, nil: return false
        }
    }

    /// The card is up.
    var cardUp: Bool {
        if case .card? = moment { return true }
        return false
    }

    /// The sheet went without one of its buttons (swiped down): for an ask, "Not now" (20.6).
    func sheetClosed() {
        if case .ask(_)? = moment { Contributions.sheetClosed() }
        moment = nil
    }

    /// The learner's choice on the card (20.6): "See how it helps" opens the full sheet for the same ask, without the
    /// re-ask line (the card has just said it); "Not now", or the card swiped away, closes it.
    func cardChosen(_ choice: SharingCardView.Choice) {
        guard case .card? = moment else { return }
        switch choice {
        case .open:
            moment = Contributions.cardOpened() ? .ask(reask: false) : nil
        case .notNow:
            moment = nil
            Contributions.cardDismissed()
        }
    }

    /// A card that went by itself (a take started, the app left the foreground, the settings switch).
    func cardGone() {
        if cardUp { moment = nil }
    }
}

/// The modifier behind `.quranLabSharing(theme:)`.
struct SharingPromptModifier: ViewModifier {
    let theme: SharingTheme
    @ObservedObject private var model = SharingPromptModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(theme: SharingTheme) { self.theme = theme }

    func body(content: Content) -> some View {
        content
            .onAppear { model.installed = true }
            // SDK 4.0 (20.6): a re-ask is a card at the bottom of the app's view, over it and not modal
            .overlay(alignment: .bottom) {
                ZStack {
                    if model.cardUp {
                        SharingCardView(theme: theme) { (choice: SharingCardView.Choice) in model.cardChosen(choice) }
                            .transition(reduceMotion ? AnyTransition.identity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.cardUp)
            }
            .sheet(isPresented: Binding(get: { model.sheetUp }, set: { if !$0 { model.sheetClosed() } })) {
                switch model.moment {
                case .ask(let reask)?:
                    SharingConsentView(reask: reask, theme: theme) { _ in model.moment = nil }
                case .thanks?:
                    SharingThanksView(theme: theme)
                case .card?, nil:
                    EmptyView()
                }
            }
    }
}

/// SDK 4.0 (20.6): the re-ask card. Not modal: no dim, no focus taken, the app stays usable around it; anchored at
/// the bottom of the window above the safe area, at most 480 wide, in the sheet's tokens (background, accent, tint,
/// corner radius 18, the type scale). The emblem, `card.line` (body style), and one row of two equal buttons,
/// `card.open` (filled with the accent) and `card.not_now` (filled with the tint), the same size, shape and type as on
/// the sheet. No timeout (timed content fails people who read slowly): it stays until the learner answers or swipes it
/// away, a take starts, or the app leaves the foreground. A screen reader hears its line once, politely, and keeps its
/// focus. No consent is given on it: "See how it helps" opens the full sheet.
struct SharingCardView: View {
    enum Choice: Sendable { case open, notNow }

    let theme: SharingTheme
    let render: SheetRender
    let onChoice: @MainActor (Choice) -> Void
    @Environment(\.self) private var environment
    @State private var drag: CGFloat = 0
    private let copy = Contributions.copy

    init(theme: SharingTheme = Contributions.theme, render: SheetRender = SheetRender(),
         onChoice: @escaping @MainActor (Choice) -> Void) {
        self.theme = theme
        self.render = render
        self.onChoice = onChoice
    }

    var body: some View {
        let ctx = SheetContext(theme: theme, environment: environment, rightToLeft: copy.rightToLeft, render: render)
        let p = ctx.palette
        let r = ctx.radius
        // the deck's own lines (2026-11-15.1 and later: every bundled deck has them, SharingDeckTests)
        let line = copy.string("card.line")
        let open = copy.string("card.open")
        let notNow = copy.string("card.not_now")
        let icon = 22 * ctx.type.iconScale
        let box = 40 * ctx.type.iconScale
        for (key, text) in [("card.line", line), ("card.open", open), ("card.not_now", notNow)] {
            SheetProbe.drew(key, text)
            SheetProbe.showed(key, ctx.shown(text))
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12 * r, style: .continuous).fill(p.tint)
                    SheetIcon(kind: .waveform, size: icon, stroke: 1.9, color: p.accentLabel)
                }
                .frame(width: box, height: box)
                .accessibilityHidden(true)
                .sheetProbe("card.emblem")
                // as on the sheet: the deck's language (Urdu set in the system's Arabic face)
                Text(ctx.shown(line)).sheetStyle(ctx.type.style(.body, line), color: p.text)
                    .accessibilityLabel(Text(verbatim: line))
                    .environment(\.locale, Locale(identifier: copy.lang == "ur" ? "ar" : copy.lang))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button { onChoice(.open) } label: {
                    label(ctx, open, both: [open, notNow], color: p.onAccent)
                }
                .buttonStyle(SheetButtonStyle(fill: p.accent, radius: 14 * r))
                .sheetProbe("card.open")
                Button { onChoice(.notNow) } label: {
                    label(ctx, notNow, both: [open, notNow], color: p.accentLabel)
                }
                .buttonStyle(SheetButtonStyle(fill: p.tint, radius: 14 * r))
                .sheetProbe("card.not_now")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18 * r, style: .continuous).fill(p.background)
            .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 4))
        .frame(maxWidth: 480)
        .sheetProbe("card")
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .offset(y: max(0, drag))
        // swiped away: "Not now"
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { v in drag = v.translation.height }
            .onEnded { v in
                if v.translation.height > 60 { onChoice(.notNow) } else { drag = 0 }
            })
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { onChoice(.notNow) }
        .modifier(SheetEnvironment(rightToLeft: copy.rightToLeft, textSize: ctx.textSize, boldText: ctx.boldText))
        .onAppear { SharingAnnounce.politely(line) }
    }

    /// A button's label: both labels laid out, unseen, in each button, so the two buttons have the same size.
    private func label(_ ctx: SheetContext, _ title: String, both: [String], color: Color) -> some View {
        ZStack {
            ForEach(0..<both.count, id: \.self) { i in
                buttonText(ctx, both[i], color: .clear).hidden().accessibilityHidden(true)
            }
            buttonText(ctx, title, color: color)
        }
        .frame(maxWidth: .infinity)
    }

    private func buttonText(_ ctx: SheetContext, _ title: String, color: Color) -> some View {
        Text(ctx.shown(title)).sheetStyle(ctx.type.style(.button, title), color: color)
            .accessibilityLabel(Text(verbatim: title))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A line read to a screen reader without moving its focus, queued behind what it is reading (a polite live region).
@MainActor
enum SharingAnnounce {
    static func politely(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(iOS)
        let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: queued)
        #elseif os(macOS)
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        #endif
    }
}

extension View {
    /// Lets the SDK present its recitation-sharing sheet and thank-you on this view, at the right moments, in `theme`
    /// for the app's Client. Without it the SDK presents its sheet over the front view controller on iOS.
    public func quranLabSharing(_ client: TajweedClient, theme: SharingTheme = .standard) -> some View {
        modifier(SharingPromptModifier(theme: theme))
    }
}

#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
/// The sheet when the app installed no presenter (no `.quranLabSharing()`, no handler): presented by the SDK over the
/// front view controller of the foreground scene, and the card (SDK 4.0, 20.6) at the bottom of its window. Only the
/// consent ask; the thank-you waits for the app's presenter.
@MainActor
enum SharingFallbackPresenter {
    /// The card on screen, with its controller.
    private static var card: UIHostingController<SharingCardView>?
    /// Hears the sheet go without one of its buttons (swiped down).
    private static let closing = SheetClosing()

    /// `show` is `Contributions.goingOnScreen` (or the sheet a card opened into): called only once the SDK has
    /// somewhere to show the ask. With nowhere to show it, the ask is withdrawn: it never reached the screen.
    static func present(_ m: SharingMoment, show: () -> SharingMoment?) {
        guard m.isAsk else { return }
        guard let window = frontWindow(), var top = window.rootViewController else {
            Contributions.askWithdrawn()
            return
        }
        while let next = top.presentedViewController { top = next }
        guard let shown = show() else { return }
        switch shown {
        case .ask(let reask): sheet(reask: reask, over: top)
        case .card: showCard(in: window)
        case .thanks: break
        }
    }

    private static func frontWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }

    private static func sheet(reask: Bool, over presenter: UIViewController) {
        let theme = Contributions.theme
        let host = UIHostingController(rootView: SharingConsentView(reask: reask, theme: theme) { _ in
            presenter.dismiss(animated: true)
        })
        #if os(iOS)
        SheetPresentation.configure(host, radius: 28 * max(0, theme.cornerRadius) / 14)
        #endif
        host.presentationController?.delegate = closing
        presenter.present(host, animated: true)
    }

    /// The card over the window's content, at its bottom above the safe area, as tall as the card: the app stays
    /// usable around it.
    private static func showCard(in window: UIWindow) {
        removeCard()
        let host = UIHostingController(rootView: SharingCardView(theme: Contributions.theme) { (choice: SharingCardView.Choice) in
            SharingFallbackPresenter.removeCard()
            switch choice {
            case .open:
                // the full sheet for the same ask, without the re-ask line
                if Contributions.cardOpened() { SharingPresenter.shared.present(.ask(reask: false), opened: true) }
            case .notNow:
                Contributions.cardDismissed()
            }
        })
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(host.view)
        let full = host.view.widthAnchor.constraint(equalTo: window.widthAnchor)
        full.priority = .defaultHigh
        var constraints = [
            host.view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor),
            host.view.widthAnchor.constraint(lessThanOrEqualToConstant: 504),
            full,
            host.view.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor),
        ]
        if #available(iOS 16.0, *) {
            host.sizingOptions = .intrinsicContentSize
        } else {
            let fits = host.sizeThatFits(in: CGSize(width: min(504, window.bounds.width), height: window.bounds.height))
            constraints.append(host.view.heightAnchor.constraint(equalToConstant: fits.height))
        }
        NSLayoutConstraint.activate(constraints)
        card = host
    }

    /// The card leaves the screen.
    static func removeCard() {
        card?.view.removeFromSuperview()
        card = nil
    }
}

/// The SDK's own sheet swiped down without one of its buttons: a "Not now" for the ask (20.6).
@MainActor
private final class SheetClosing: NSObject, UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        Contributions.sheetClosed()
    }
}
#endif

#if canImport(UIKit) && !os(watchOS)
/// UIKit: the consent sheet in a view controller, for an app that presents it itself.
public final class SharingConsentViewController: UIHostingController<SharingConsentView> {
    public init(_ client: TajweedClient, reask: Bool = false, theme: SharingTheme = .standard,
                onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        super.init(rootView: SharingConsentView(reask: reask, theme: theme, onDone: onDone))
        rootView = SharingConsentView(reask: reask, theme: theme) { [weak self] v in
            onDone(v)
            self?.dismiss(animated: true)
        }
        #if os(iOS)
        SheetPresentation.configure(self, radius: 28 * max(0, theme.cornerRadius) / 14)
        #endif
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// UIKit: the sharing settings in a view controller.
public final class SharingSettingsViewController: UIHostingController<SharingSettingsView> {
    public init(_ client: TajweedClient, theme: SharingTheme = .standard) { super.init(rootView: SharingSettingsView(theme: theme, opaque: true)) }
    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// AppKit: the consent sheet in a view controller (present it as a sheet of the app's window).
public final class SharingConsentViewControllerMac: NSHostingController<SharingConsentView> {
    public init(_ client: TajweedClient, reask: Bool = false, theme: SharingTheme = .standard,
                onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        super.init(rootView: SharingConsentView(reask: reask, theme: theme, onDone: onDone))
        rootView = SharingConsentView(reask: reask, theme: theme) { [weak self] v in
            onDone(v)
            if let self { self.presentingViewController?.dismiss(self) }
        }
        preferredContentSize = NSSize(width: 480, height: 680)
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// AppKit: the sharing settings in a view controller.
public final class SharingSettingsViewControllerMac: NSHostingController<SharingSettingsView> {
    public init(_ client: TajweedClient, theme: SharingTheme = .standard) { super.init(rootView: SharingSettingsView(theme: theme, opaque: true)) }
    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
#endif
