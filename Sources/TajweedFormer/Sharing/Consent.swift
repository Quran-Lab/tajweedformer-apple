import Foundation

/// Who the app is for. With `.children`, the SDK's consent sheet addresses the parent or guardian and needs their
/// confirmation before it can share.
public enum Audience: String, Sendable, Hashable, Codable {
    case general
    case children
}

/// What the app should show now, if anything (the SDK's `SharingConsentView` shows it for you).
public enum SharingMoment: Sendable, Hashable {
    /// The consent sheet: the first ask, or a gentle re-ask after "Not now" (the sheet is shown at most three times per
    /// install). `guardian`: the children's variant.
    case ask(reask: Bool, guardian: Bool)
    /// The thank-you line with its du'a, once, after the first shared session.
    case thanks
}

/// The learner's answer as the SDK keeps it.
public enum SharingConsent: String, Sendable, Hashable, Codable {
    /// Never asked.
    case unknown
    /// Shares every session in full while the SDK listens.
    case granted
    /// "Not now": may be asked again, at least 7 sessions later, until the sheet was shown three times in all.
    case declined
    /// Declined after the third showing, or turned off in settings: never asked again (only the settings switch turns
    /// sharing on).
    case final
}

/// The SDK's sharing state machine, persisted per install (the same machine in every TajweedFormer SDK), in
/// `cloud/sharing-state.json`. 2.0.0 wrote the same JSON object without `consentTextSHA256`; it is read as it is.
struct SharingState: Codable, Equatable {
    var v = 1
    var consent: SharingConsent = .unknown
    /// The sheets shown (or asks handed to the app's own UI) on this install, ever: at most three.
    var asks = 0
    var lastAskSession = 0
    var sessions = 0
    var thanked = false
    var decidedAt: Double?
    var consentVersion: String?
    /// The hash of the app's own wording the learner agreed to (2.0.1); nil for the deck's words.
    var consentTextSHA256: String?
    var guardian = false
    /// A shared session finished since the grant (the thank-you is due).
    var sharedOnce = false

    /// The most sheets an install is ever shown.
    static let maxAsks = 3
    /// The consent version of the deck 2.0.0 bundled on Apple platforms: a 2.0.0 grant without a recorded version
    /// agreed to it.
    static let version200 = "share-2026-11-07b"

    enum CodingKeys: String, CodingKey {
        case v, consent, asks, lastAskSession, sessions, thanked, decidedAt, consentVersion, consentTextSHA256, guardian,
             sharedOnce
    }

    /// A grant keeps the version it was given; an older state that lacks a field gets its default (a declined state
    /// without an ask count was asked once).
    mutating func upgrade() {
        if consent == .granted && (consentVersion ?? "").isEmpty { consentVersion = Self.version200 }
        if consent == .declined && asks < 1 { asks = 1 }
    }
}

extension SharingState {
    /// Tolerant of missing fields (an older SDK's file): each takes its default, and nothing is reset.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        consent = (try? c.decodeIfPresent(SharingConsent.self, forKey: .consent)) ?? .unknown
        asks = (try? c.decodeIfPresent(Int.self, forKey: .asks)) ?? 0
        lastAskSession = (try? c.decodeIfPresent(Int.self, forKey: .lastAskSession)) ?? 0
        sessions = (try? c.decodeIfPresent(Int.self, forKey: .sessions)) ?? 0
        thanked = (try? c.decodeIfPresent(Bool.self, forKey: .thanked)) ?? false
        decidedAt = (try? c.decodeIfPresent(Double.self, forKey: .decidedAt)) ?? nil
        consentVersion = (try? c.decodeIfPresent(String.self, forKey: .consentVersion)) ?? nil
        consentTextSHA256 = (try? c.decodeIfPresent(String.self, forKey: .consentTextSHA256)) ?? nil
        guardian = (try? c.decodeIfPresent(Bool.self, forKey: .guardian)) ?? false
        sharedOnce = (try? c.decodeIfPresent(Bool.self, forKey: .sharedOnce)) ?? false
        upgrade()
    }
}

/// Recording sharing, one switch for the developer (`QuranLab.Options.contributions`) and one tap for the learner.
///
/// With the option on (and the signed config allowing it on this platform), the SDK asks the learner at the right
/// moment with its own consent sheet: never on first launch; after a finished session with feedback
/// (`TajweedRecognizer.endSession(feedback:)`); "Not now" re-asks at least 7 sessions later, until the sheet was shown
/// three times on the install in all; then never again. A yes ends asking for good: the grant keeps the consent
/// version the learner agreed to across copy decks, the app's wording and SDK upgrades (2.0.0's grants included), and
/// turning sharing off after it never brings the sheet back. Only the settings switch (`setSharing(_:)`) turns sharing
/// on or off after asking has ended. Children's apps (`audience: .children`) get the guardian variant. Apps may change
/// WHEN the sheet appears (`askNow()`), never what it discloses.
///
/// 2.0.1: the app may show its own UI instead of the SDK's sheet (`setPresenter(_:)`: the SDK hands it each moment, the
/// app shows the deck's strings from `copy` and reports the learner's tap with `answer(share:guardianConfirmed:)`), and
/// may replace any string of the deck with its own words (`setWording(_:)`): a learner who agrees from then on agrees
/// to those words, under a consent version derived from them (`custom-...`), and every session they share carries
/// their hash.
///
/// Once the learner agrees, every session the SDK listens to is shared in full, continuously, as Ogg Opus segments
/// uploaded in the background (`ContributionOutbox`). The learner can stop at any time (`setSharing(false)` stops
/// uploads at once and deletes the unsent queue) and delete what they shared (`deleteShared()`).
public enum Contributions {
    static let lock = Locked<SharingState?>(nil)

    private static func file() -> JSONFile<SharingState> {
        JSONFile(url: QuranLab.configuration.storageDirectory.appendingPathComponent("cloud/sharing-state.json"))
    }

    static func state() -> SharingState {
        lock.withLock { s in
            if let s { return s }
            var v = file().read() ?? SharingState()
            v.upgrade()
            s = v
            return v
        }
    }

    static func update(_ body: (inout SharingState) -> Void) -> SharingState {
        let f = file()
        return lock.withLock { s -> SharingState in
            var v = s ?? f.read() ?? SharingState()
            v.upgrade()
            body(&v)
            s = v
            f.write(v)
            return v
        }
    }

    /// Forgets the cached state (tests, and a new storage directory at configure).
    static func reload() { lock.withLock { $0 = nil } }

    /// The copy deck in force (the app's locale, else English), with the app's own wording applied.
    public static var copy: SharingCopy {
        SharingCopy.forLocale(QuranLab.configuration.options.sharingLocale).applying(wording)
    }

    private static let wordingState = Locked<[String: String]>([:])

    /// The app's own wording in force, by deck key (empty: the deck's words).
    public static var wording: [String: String] { wordingState.withLock { $0 } }

    /// Replaces strings of the SDK's copy deck with the app's own words, `{key: text}` (the deck's keys; a plural line
    /// by category, `impact.minutes.one`). Nil or empty goes back to the deck's words. An unknown key or an empty or
    /// blank text throws `.invalidArgument` and nothing changes. Set it at launch, before the first session: a learner
    /// who agrees from then on agrees to these words, so their consent version is `custom-` and 24 hex digits of the
    /// words' hash (`consentTextSHA256`), and every session they share sends the hash for Quran Lab to review. A
    /// learner who already agreed keeps the version and hash they agreed to, is not asked again, and keeps sharing.
    /// Your words must still say that the audio of recitation sessions is sent to Quran Lab, what else is sent, what it
    /// is used for, and how to stop and delete.
    public static func setWording(_ overrides: [String: String]?) throws(RecognizerError) {
        let o = overrides ?? [:]
        let known = SharingCopy.allKeys
        for k in o.keys.sorted() {
            guard known.contains(k) else { throw .invalidArgument("sharing wording: \(k) is not a key of the copy deck") }
            guard let text = o[k], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw .invalidArgument("sharing wording: the text for \(k) is empty")
            }
        }
        wordingState.withLock { $0 = o }
    }

    /// The consent version in force (what a grant from now on records): the deck's, or `custom-...` for the app's own
    /// wording. A learner who agreed earlier keeps the version they agreed to.
    public static var consentVersionInForce: String { copy.consentVersion }

    /// With the app's own wording: the SHA-256 (64 hex) every shared session carries, for the developer to send to
    /// Quran Lab with the wording. Nil with the deck's words.
    public static var consentTextSHA256: String? { copy.consentTextSHA256 }

    /// With the app's own wording: the canonical text `consentTextSHA256` is the hash of. Nil with the deck's words.
    public static var consentText: String? { copy.consentText }

    /// Your own UI instead of the SDK's sheet: the SDK hands each moment (the consent ask, the thank-you) to `handler`
    /// on the main actor and shows nothing itself. Show the deck's strings from `copy` (the app's own wording applied),
    /// buttons of equal weight, and report the learner's own tap with `answer(share:guardianConfirmed:)`. The SDK
    /// picks the moments and counts the asks as for its own sheet. Nil goes back to the SDK's sheet.
    public static func setPresenter(_ handler: (@MainActor @Sendable (SharingMoment) -> Void)?) {
        SharingPresenter.shared.set(handler)
    }

    /// Quran Lab's signed config offers sharing to this app on this platform (flag `contributions`, decided per app on
    /// the server, and the upload trust tier). Since 2.0.1 the app's `Options.contributions` does not decide it, and
    /// without a verified config in force nothing is offered (2.0.0 offered it before the first config arrived). When
    /// false, the SDK never asks and never uploads; the learner's answer is kept. Offered is never consent: capture and
    /// upload also need the learner's grant (`isActive`).
    public static var isEnabled: Bool {
        guard QuranLab.configuration.options.cloud != nil, let cfg = QuranLab.cloud?.currentConfig else { return false }
        if !cfg.flags.contributions { return false }
        if UploadTrust.tier(cfg, platform: AppIdentity.currentPlatform) == "off" { return false }
        return true
    }

    /// Enabled and the learner agreed: sessions are being shared. A grant holds whatever consent version it was given
    /// (an older deck, the app's earlier wording, a 2.0.0 grant): the sessions carry that version.
    public static var isActive: Bool {
        isEnabled && state().consent == .granted
    }

    /// The learner's answer.
    public static var consent: SharingConsent { state().consent }

    /// The consent version the learner agreed to, sent with every shared session.
    static var consentVersion: String? { state().consent == .granted ? state().consentVersion : nil }

    /// The hash of the app's own wording the learner agreed to, sent next to the version; nil for the deck's words.
    static var grantedTextSHA256: String? {
        let s = state()
        guard s.consent == .granted, s.consentVersion?.hasPrefix("custom-") == true else { return nil }
        return s.consentTextSHA256
    }

    /// A finished session: counts it, and says whether this is the moment to ask (or thank). `feedback`: the learner
    /// was shown the model's feedback for the session.
    @discardableResult
    public static func sessionCompleted(feedback: Bool) -> SharingMoment? {
        let enabled = isEnabled
        var moment: SharingMoment?
        _ = update { s in
            s.sessions += 1
            guard enabled else { return }
            if s.consent == .granted && s.sharedOnce && !s.thanked {
                s.thanked = true
                moment = .thanks
                return
            }
            // never after a grant or settings off; the first ask, then "Not now" (or a sheet closed without an answer)
            // asks again at least 7 sessions later, until the sheet was shown three times in all
            guard feedback, s.asks < SharingState.maxAsks, s.consent == .unknown || s.consent == .declined else { return }
            if s.asks == 0 || s.sessions - s.lastAskSession >= 7 {
                moment = .ask(reask: s.asks > 0, guardian: QuranLab.configuration.options.audience == .children)
                s.asks += 1
                s.lastAskSession = s.sessions
            }
        }
        if case .ask(_, _)? = moment { QuranLab.count(.shareAsked) }
        if let moment { SharingPresenter.shared.present(moment) }
        return moment
    }

    /// The app's own timing: the sheet now, whatever the session count, when the learner has not agreed or turned
    /// sharing off and the sheet was shown fewer than three times (it counts as one of the three).
    @discardableResult
    public static func askNow() -> SharingMoment? {
        guard isEnabled else { return nil }
        var moment: SharingMoment?
        _ = update { s in
            guard s.asks < SharingState.maxAsks, s.consent == .unknown || s.consent == .declined else { return }
            moment = .ask(reask: s.asks > 0, guardian: QuranLab.configuration.options.audience == .children)
            s.asks += 1
            s.lastAskSession = s.sessions
        }
        if moment != nil { QuranLab.count(.shareAsked) }
        if let moment { SharingPresenter.shared.present(moment) }
        return moment
    }

    /// The learner's answer on the sheet (the SDK's, or the app's own UI from `setPresenter(_:)`), only from the
    /// learner's own tap. `guardianConfirmed` must be true for a grant in a children's app. The grant is to the
    /// consent version in force (the app's own wording included).
    public static func answer(share: Bool, guardianConfirmed: Bool = false) {
        let granted = decide(share: share, guardianConfirmed: guardianConfirmed)
        QuranLab.count(granted ? .shareYes : .shareNo)
    }

    /// Records a decision; true when it is a grant.
    @discardableResult
    static func decide(share: Bool, guardianConfirmed: Bool) -> Bool {
        let children = QuranLab.configuration.options.audience == .children
        let c = copy
        let version = c.consentVersion, hash = c.consentTextSHA256
        var granted = false
        _ = update { s in
            if share && (!children || guardianConfirmed) {
                s.consent = .granted
                s.decidedAt = Date().timeIntervalSince1970.rounded()
                s.consentVersion = version
                s.consentTextSHA256 = hash
                s.guardian = children
                granted = true
            } else {
                s.consent = s.asks >= SharingState.maxAsks ? .final : .declined
                s.decidedAt = Date().timeIntervalSince1970.rounded()
            }
        }
        return granted
    }

    /// The settings switch (not a sheet answer). On: granted, to the consent version in force at that moment (a
    /// children's app needs the guardian's confirmation); already on, nothing changes (the learner keeps the version
    /// they agreed to). Off: final, never asked again, and every queued upload stops at once (the unsent queue is
    /// deleted); it works whatever version the learner agreed to.
    public static func setSharing(_ on: Bool, guardianConfirmed: Bool = false) async {
        if on {
            if state().consent == .granted { return }
            decide(share: true, guardianConfirmed: guardianConfirmed)
        } else {
            _ = update { s in
                s.consent = .final
                s.decidedAt = Date().timeIntervalSince1970.rounded()
            }
            await QuranLab.cloud?.outbox.cancelQueued()
        }
    }

    /// The lines behind "What is shared" (disclosure lines: show them as they are).
    public static var whatIsShared: [String] { [copy.string("what.detail")].filter { !$0.isEmpty } }

    /// This install's contribution code (32 hex), shown to the learner in the sharing settings for deletion requests.
    public static var contributionCode: String { QuranLab.contributorID }

    /// "Delete what I shared": every recording this learner shared from this app is deleted from Quran Lab's
    /// servers (a challenge signed with this device's key, no app credential can do this),
    /// the unsent queue is dropped, and the contribution code, device key and recovery code are replaced, so later
    /// shares are not linked to the deleted ones. There is no call to delete another learner's recordings.
    public static func deleteShared() async throws(RecognizerError) {
        guard let cloud = QuranLab.cloud else { throw .serviceUnavailable("deleting shared recordings (no cloud configured)") }
        try await cloud.deleteContributions(contributor: contributionCode)
        await cloud.outbox.cancelQueued()
        QuranLab.resetContributor()
        _ = update { s in
            s.consent = .final
            s.decidedAt = Date().timeIntervalSince1970.rounded()
        }
    }

    /// The recovery code for a lost device, shown only by the SDK's own sharing settings view (never handed to the
    /// app). Nil until the learner has shared.
    static var recoveryCodeForDisplay: String? {
        let storage = QuranLab.configuration.storageDirectory
        guard ContributorKey.read(ContributorKey.codeAccount, storage: storage) != nil else { return nil }
        return ContributorKey.recoveryCode(storage: storage)
    }

    /// The learner's own shared minutes, this app's and Quran Lab's totals (real numbers from the server); nil when
    /// the call fails (show nothing then).
    public static func summary() async -> ContributionSummary? {
        await QuranLab.cloud?.contributionSummary(contributor: contributionCode)
    }

    /// The capture for a session that starts now, when sharing is active.
    static func capture(revision: String, backend: ActiveBackend, weightsSHA256: String?) -> ShareCapture? {
        guard isActive, let outbox = QuranLab.cloud?.outbox else { return nil }
        return ShareCapture(outbox: outbox, consentVersion: consentVersion, consentTextSHA256: grantedTextSHA256, modelRevision: revision,
                            backend: backend.rawValue, weightsSHA256: weightsSHA256)
    }

    /// A shared session finished (the thank-you becomes due at the next completed session).
    static func noteShared() { _ = update { $0.sharedOnce = true } }
}

/// The learner's and the community's real totals (`GET /v1/contributions/summary`).
public struct ContributionSummary: Sendable, Hashable {
    public let mySessions: Int
    public let myMinutes: Double
    /// Nil while the app has fewer than 10 contributors (the privacy floor).
    public let appContributors: Int?
    public let appMinutes: Double?
    public let allContributors: Int
    public let allMinutes: Double
}

/// The signed config's `flags.upload_trust` for a platform: `off`, `capped` or `attested` (defaults: ios and macos
/// `attested`).
enum UploadTrust {
    static func tier(_ cfg: RemoteConfig, platform: String) -> String {
        if let t = cfg.uploadTrust[platform], ["off", "capped", "attested"].contains(t) { return t }
        return "attested"
    }
}

/// Hands moments to the app's own UI (`Contributions.setPresenter(_:)`), else to the SDK's sheet (`.quranLabSharing()`,
/// else over the front view controller on iOS), on the main actor.
final class SharingPresenter: @unchecked Sendable {
    static let shared = SharingPresenter()
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (SharingMoment) -> Void)?

    func set(_ h: (@MainActor @Sendable (SharingMoment) -> Void)?) {
        lock.lock(); handler = h; lock.unlock()
    }

    func present(_ m: SharingMoment) {
        lock.lock(); let h = handler; lock.unlock()
        Task { @MainActor in
            // the app's own UI takes over: the SDK shows nothing itself
            if let h { h(m); return }
            var shown = false
            #if canImport(SwiftUI)
            if SharingPromptModel.shared.installed { SharingPromptModel.shared.moment = m; shown = true }
            #endif
            // 2.0.1: the backend decides whether the sheet is offered, so an app that never added
            // `.quranLabSharing()` still gets the SDK's own sheet (iOS: over the front view controller)
            #if canImport(SwiftUI) && canImport(UIKit) && !os(watchOS) && !os(tvOS)
            if !shown { SharingFallbackPresenter.present(m) }
            #else
            _ = shown
            #endif
        }
    }
}
