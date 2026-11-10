#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// How the SDK's sharing views look in the app: colours, corner radius and fonts. The words are the deck's.
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
    public static var theme: SharingTheme {
        get { themeState.withLock { $0 } }
        set { themeState.withLock { $0 = newValue } }
    }
}

/// The consent sheet: why sharing helps, what is shared, who receives it, how to stop, and two buttons of equal
/// weight. Nothing is pre-ticked; in a children's app the share button is enabled only after the parent or guardian
/// confirms.
public struct SharingConsentView: View {
    let reask: Bool
    let guardian: Bool
    let theme: SharingTheme
    let onDone: @MainActor (Bool) -> Void
    @State private var confirmed = false
    private let copy = Contributions.copy

    public init(reask: Bool = false, guardian: Bool? = nil, theme: SharingTheme = Contributions.theme,
                onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.reask = reask
        self.guardian = guardian ?? (QuranLab.configuration.options.audience == .children)
        self.theme = theme
        self.onDone = onDone
    }

    private func line(_ key: String, _ font: Font? = nil, secondary: Bool = false) -> some View {
        let t = copy.string(key)
        return Group {
            if !t.isEmpty {
                Text(t).font(font ?? theme.bodyFont).foregroundColor(secondary ? theme.secondaryText : theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                line(guardian ? "sheet.guardian.title" : "sheet.title", theme.titleFont)
                if reask { line("reask") }
                line(guardian ? "sheet.guardian.body" : "sheet.body")
                if copy.hadithVerified {
                    line("sheet.hadith")
                    line("sheet.hadith_ref", .footnote, secondary: true)
                }
                line("sheet.mistakes")
                VStack(alignment: .leading, spacing: 8) {
                    line("sheet.what")
                    line("sheet.who")
                    line("sheet.control")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.secondaryText.opacity(0.3)))
                if guardian {
                    Toggle(isOn: $confirmed) { line("sheet.guardian.confirm") }
                        .toggleStyle(SwitchToggleStyle(tint: theme.accent))
                }
                HStack(spacing: 12) {
                    choice(copy.string(guardian ? "sheet.guardian.share" : "sheet.share"), enabled: !guardian || confirmed) {
                        Contributions.answer(share: true, guardianConfirmed: confirmed)
                        onDone(true)
                    }
                    choice(copy.string("sheet.not_now"), enabled: true) {
                        Contributions.answer(share: false)
                        onDone(false)
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(theme.background)
        .environment(\.layoutDirection, copy.rightToLeft ? .rightToLeft : .leftToRight)
    }

    /// Both buttons share one style: equal visual weight, no grey-on-grey.
    private func choice(_ title: String, enabled: Bool, _ action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(theme.bodyFont.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundColor(theme.accent)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius).stroke(theme.accent, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// The thank-you line with its du'a, and (when the server answers) the learner's real shared minutes.
public struct SharingThanksView: View {
    let theme: SharingTheme
    @State private var impact: String?
    public init(theme: SharingTheme = Contributions.theme) { self.theme = theme }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Contributions.copy.string("thanks")).font(theme.bodyFont).foregroundColor(theme.text)
            if let impact { Text(impact).font(.footnote).foregroundColor(theme.secondaryText) }
        }
        .padding(16)
        .background(theme.background)
        .environment(\.layoutDirection, Contributions.copy.rightToLeft ? .rightToLeft : .leftToRight)
        .task {
            if let s = await Contributions.summary(), s.myMinutes >= 1 { impact = Contributions.copy.impact(minutes: s.myMinutes) }
        }
    }
}

/// The sharing settings: the switch, "What is shared", "Delete what I shared" (with its confirmation), and the
/// learner's recovery code for a lost device (revealed on tap, shown only here). Works whatever the developer flag says, so a learner can always stop and delete.
public struct SharingSettingsView: View {
    let theme: SharingTheme
    @State private var on = Contributions.consent == .granted
    @State private var showWhat = false
    @State private var confirmDelete = false
    @State private var deleted = false
    @State private var deleteFailed = false
    @State private var confirmed = false
    @State private var showCode = false
    private let copy = Contributions.copy
    private let children = QuranLab.configuration.options.audience == .children

    public init(theme: SharingTheme = Contributions.theme) { self.theme = theme }

    private func delete() {
        confirmDelete = false
        deleteFailed = false
        Task {
            if (try? await Contributions.deleteShared()) != nil { deleted = true } else { deleteFailed = true }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: Binding(get: { on }, set: { v in
                on = v
                Task { await Contributions.setSharing(v, guardianConfirmed: !children || confirmed) }
            })) { Text(copy.string("settings.toggle")).foregroundColor(theme.text) }
                .toggleStyle(SwitchToggleStyle(tint: theme.accent))
            if children && !on {
                Toggle(isOn: $confirmed) { Text(copy.string("sheet.guardian.confirm")).font(.footnote) }
            }
            Button(copy.string("settings.what")) { showWhat.toggle() }.foregroundColor(theme.accent)
            if showWhat {
                ForEach(Contributions.whatIsShared, id: \.self) { Text($0).font(.footnote).foregroundColor(theme.secondaryText) }
            }
            Button(copy.string("settings.delete")) { confirmDelete = true }.foregroundColor(theme.accent)
            if confirmDelete {
                VStack(alignment: .leading, spacing: 8) {
                    Text(copy.string("delete.confirm")).font(.footnote).foregroundColor(theme.text)
                    HStack {
                        Button(copy.string("delete.action")) { delete() }
                        Button(copy.string("delete.cancel")) { confirmDelete = false }
                    }
                }
            }
            if deleted { Text(copy.string("delete.done")).font(.footnote).foregroundColor(theme.secondaryText) }
            if deleteFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text(copy.string("delete.failed.title")).font(theme.bodyFont.weight(.semibold)).foregroundColor(theme.text)
                    Text(copy.string("delete.failed.network")).font(.footnote).foregroundColor(theme.secondaryText)
                    Button(copy.string("delete.retry")) { delete() }.foregroundColor(theme.accent)
                }
            }
            if let code = Contributions.recoveryCodeForDisplay {
                Button(showCode ? code : copy.string("recovery.reveal")) { showCode.toggle() }
                    .font(showCode ? Font.body.monospaced() : Font.footnote)
                    .foregroundColor(theme.accent)
                if showCode {
                    Text(copy.string("recovery.keep")).font(.footnote).foregroundColor(theme.secondaryText)
                }
                Text(copy.string("recovery.hint")).font(.footnote).foregroundColor(theme.secondaryText)
            }
        }
        .padding(16)
        .background(theme.background)
        .environment(\.layoutDirection, copy.rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// Shows the SDK's sheet and thank-you at the moments the SDK picks (after a finished session with feedback,
/// `TajweedRecognizer.endSession(feedback:)`). Put it once near the root of the app: `.quranLabSharing()`.
@MainActor
final class SharingPromptModel: ObservableObject {
    static let shared = SharingPromptModel()
    @Published var moment: SharingMoment?
    var installed = false
}

/// The modifier behind `.quranLabSharing(theme:)`.
struct SharingPromptModifier: ViewModifier {
    let theme: SharingTheme
    @ObservedObject private var model = SharingPromptModel.shared

    init(theme: SharingTheme) { self.theme = theme }

    func body(content: Content) -> some View {
        content
            .onAppear { model.installed = true }
            .sheet(isPresented: Binding(get: { model.moment != nil }, set: { if !$0 { model.moment = nil } })) {
                switch model.moment {
                case .ask(let reask, let guardian)?:
                    SharingConsentView(reask: reask, guardian: guardian, theme: theme) { _ in model.moment = nil }
                case .thanks?:
                    SharingThanksView(theme: theme)
                case nil:
                    EmptyView()
                }
            }
    }
}

extension View {
    /// Lets the SDK present its recitation-sharing sheet and thank-you on this view, at the right moments, in `theme`
    /// (default: `Contributions.theme`). An app with its own UI (`Contributions.setPresenter(_:)`) does not need it.
    public func quranLabSharing(theme: SharingTheme = Contributions.theme) -> some View { modifier(SharingPromptModifier(theme: theme)) }
}

#if canImport(UIKit) && !os(watchOS) && !os(tvOS)
/// The sheet when the app installed no presenter (no `.quranLabSharing()`, no handler): presented by the SDK over the
/// front view controller of the foreground scene. Only the consent ask; the thank-you waits for the app's presenter.
@MainActor
enum SharingFallbackPresenter {
    static func present(_ m: SharingMoment) {
        guard case let .ask(reask, guardian) = m else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let presenter = top
        let host = UIHostingController(rootView: SharingConsentView(reask: reask, guardian: guardian, theme: Contributions.theme) { _ in
            presenter.dismiss(animated: true)
        })
        presenter.present(host, animated: true)
    }
}
#endif

#if canImport(UIKit) && !os(watchOS)
/// UIKit: the consent sheet in a view controller (present it modally when `endSession(feedback:)` returns `.ask`).
public final class SharingConsentViewController: UIHostingController<SharingConsentView> {
    public init(reask: Bool = false, theme: SharingTheme = Contributions.theme, onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        super.init(rootView: SharingConsentView(reask: reask, theme: theme, onDone: onDone))
        rootView = SharingConsentView(reask: reask, theme: theme) { [weak self] v in
            onDone(v)
            self?.dismiss(animated: true)
        }
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// UIKit: the sharing settings in a view controller.
public final class SharingSettingsViewController: UIHostingController<SharingSettingsView> {
    public init(theme: SharingTheme = Contributions.theme) { super.init(rootView: SharingSettingsView(theme: theme)) }
    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// AppKit: the consent sheet in a view controller (present it as a sheet of the app's window).
public final class SharingConsentViewControllerMac: NSHostingController<SharingConsentView> {
    public init(reask: Bool = false, theme: SharingTheme = Contributions.theme, onDone: @escaping @MainActor (Bool) -> Void = { _ in }) {
        super.init(rootView: SharingConsentView(reask: reask, theme: theme, onDone: onDone))
        rootView = SharingConsentView(reask: reask, theme: theme) { [weak self] v in
            onDone(v)
            if let self { self.presentingViewController?.dismiss(self) }
        }
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// AppKit: the sharing settings in a view controller.
public final class SharingSettingsViewControllerMac: NSHostingController<SharingSettingsView> {
    public init(theme: SharingTheme = Contributions.theme) { super.init(rootView: SharingSettingsView(theme: theme)) }
    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
#endif
#endif
