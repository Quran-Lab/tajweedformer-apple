import Foundation

/// Who the app is for. With `.children`, the SDK's consent sheet addresses the parent or guardian and needs their
/// confirmation before it can share.
public enum Audience: String, Sendable, Hashable, Codable {
    case general
    case children
}

/// What the app should show now, if anything (the SDK's `SharingConsentView` shows it for you).
public enum SharingMoment: Sendable, Hashable {
    /// The consent sheet: the first ask, or a gentle re-ask after "Not now". `guardian`: the children's variant.
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
    /// "Not now": may be asked again (at most twice, 7 sessions apart).
    case declined
    /// Declined after the last re-ask, or turned off in settings: never asked again unless the learner turns it on.
    case final
}

/// The SDK's sharing state machine, persisted per install (the same machine in every TajweedFormer SDK).
struct SharingState: Codable, Equatable {
    var v = 1
    var consent: SharingConsent = .unknown
    var asks = 0
    var lastAskSession = 0
    var sessions = 0
    var thanked = false
    var decidedAt: Double?
    var consentVersion: String?
    var guardian = false
    /// A shared session finished since the grant (the thank-you is due).
    var sharedOnce = false
}

/// Recording sharing, one switch for the developer (`QuranLab.Options.contributions`) and one tap for the learner.
///
/// With the option on (and the signed config allowing it on this platform), the SDK asks the learner at the right
/// moment with its own consent sheet: never on first launch; after a finished session with feedback
/// (`TajweedRecognizer.endSession(feedback:)`); "Not now" re-asks at most twice, each at least 7 sessions later;
/// then never again unless the learner opens the setting. Children's apps (`audience: .children`) get the guardian
/// variant. Apps may change WHEN the sheet appears (`askNow()`), never what it discloses.
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
            let v = file().read() ?? SharingState()
            s = v
            return v
        }
    }

    static func update(_ body: (inout SharingState) -> Void) -> SharingState {
        let f = file()
        return lock.withLock { s -> SharingState in
            var v = s ?? f.read() ?? SharingState()
            body(&v)
            s = v
            f.write(v)
            return v
        }
    }

    /// Forgets the cached state (tests, and a new storage directory at configure).
    static func reload() { lock.withLock { $0 = nil } }

    /// The copy deck in force (the app's locale, else English).
    public static var copy: SharingCopy { SharingCopy.forLocale(QuranLab.configuration.options.sharingLocale) }

    /// The developer turned sharing on, and the signed config allows it on this platform (flag `contributions` and the
    /// upload trust tier). When false, the SDK never asks and never uploads; the learner's answer is kept.
    public static var isEnabled: Bool {
        let o = QuranLab.configuration.options
        guard o.contributions, o.cloud != nil else { return false }
        if let cfg = QuranLab.cloud?.currentConfig {
            if cfg.flags.contributions == false { return false }
            if UploadTrust.tier(cfg, platform: AppIdentity.currentPlatform) == "off" { return false }
        }
        return true
    }

    /// Enabled and the learner agreed (to the current consent version): sessions are being shared.
    public static var isActive: Bool {
        let s = state()
        return isEnabled && s.consent == .granted && s.consentVersion == copy.consentVersion
    }

    /// The learner's answer.
    public static var consent: SharingConsent { state().consent }

    /// The consent version the learner agreed to, sent with every shared session.
    static var consentVersion: String? { state().consent == .granted ? state().consentVersion : nil }

    /// A finished session: counts it, and says whether this is the moment to ask (or thank). `feedback`: the learner
    /// was shown the model's feedback for the session.
    @discardableResult
    public static func sessionCompleted(feedback: Bool) -> SharingMoment? {
        let enabled = isEnabled
        let version = copy.consentVersion
        var moment: SharingMoment?
        _ = update { s in
            s.sessions += 1
            guard enabled else { return }
            if s.consent == .granted && s.sharedOnce && !s.thanked {
                s.thanked = true
                moment = .thanks
                return
            }
            // a new disclosure version asks again, once
            if s.consent == .granted && s.consentVersion != version && feedback {
                s.consent = .unknown
                s.asks = 0
            }
            guard feedback else { return }
            if s.consent == .unknown || (s.consent == .declined && s.asks < 3 && s.sessions - s.lastAskSession >= 7) {
                moment = .ask(reask: s.consent == .declined, guardian: QuranLab.configuration.options.audience == .children)
                s.asks += 1
                s.lastAskSession = s.sessions
            }
        }
        if let moment { SharingPresenter.shared.present(moment) }
        return moment
    }

    /// The app's own timing: the sheet now (when the learner has not decided for good), whatever the session count.
    @discardableResult
    public static func askNow() -> SharingMoment? {
        guard isEnabled else { return nil }
        var moment: SharingMoment?
        _ = update { s in
            guard s.consent == .unknown || s.consent == .declined else { return }
            moment = .ask(reask: s.consent == .declined, guardian: QuranLab.configuration.options.audience == .children)
            s.asks += 1
            s.lastAskSession = s.sessions
        }
        if let moment { SharingPresenter.shared.present(moment) }
        return moment
    }

    /// The learner's answer on the sheet. `guardianConfirmed` must be true for a grant in a children's app.
    public static func answer(share: Bool, guardianConfirmed: Bool = false) {
        let children = QuranLab.configuration.options.audience == .children
        let version = copy.consentVersion
        _ = update { s in
            if share && (!children || guardianConfirmed) {
                s.consent = .granted
                s.decidedAt = Date().timeIntervalSince1970.rounded()
                s.consentVersion = version
                s.guardian = children
            } else {
                s.consent = s.asks >= 3 ? .final : .declined
                s.decidedAt = Date().timeIntervalSince1970.rounded()
            }
        }
    }

    /// The settings switch. On: granted (a children's app needs the guardian's confirmation). Off: final, and every
    /// queued upload stops at once (the unsent queue is deleted).
    public static func setSharing(_ on: Bool, guardianConfirmed: Bool = false) async {
        if on {
            answer(share: true, guardianConfirmed: guardianConfirmed)
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
        return ShareCapture(outbox: outbox, consentVersion: consentVersion, modelRevision: revision,
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

/// Hands moments to a presenter the app installed (`SharingConsentView` does it), on the main actor.
final class SharingPresenter: @unchecked Sendable {
    static let shared = SharingPresenter()
    private let lock = NSLock()
    private var handler: (@Sendable (SharingMoment) -> Void)?

    func set(_ h: (@Sendable (SharingMoment) -> Void)?) {
        lock.lock(); handler = h; lock.unlock()
    }

    func present(_ m: SharingMoment) {
        lock.lock(); let h = handler; lock.unlock()
        Task { @MainActor in
            #if canImport(SwiftUI)
            if SharingPromptModel.shared.installed { SharingPromptModel.shared.moment = m }
            #endif
            h?(m)
        }
    }
}
