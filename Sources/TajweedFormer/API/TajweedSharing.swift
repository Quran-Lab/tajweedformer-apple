import Foundation

/// Sharing recitations with Quran Lab, reached through `client.sharing`. Every learner is asked, in every app, under
/// the same rules, and the choice is theirs: "Not now", or a yes they can take back, and they can delete what they
/// shared at any time. The developer switches nothing on or off; Quran Lab's signed config keeps an incident switch
/// (`flags.contributions`) that stops all asking and sharing. The SDK asks with its own sheet at the end of a
/// good take, and after "Not now" with a small card, at most three times per install; a yes is never asked again.
/// Once the learner said yes, every take the SDK listens to is shared in full, and takes that follow one another
/// within a few seconds are one recording.
///
/// The SDK's sheet and settings view are `SharingConsentView`, `SharingSettingsView` and the view modifier
/// `.quranLabSharing(_:)`; an app with its own settings screen uses the members here.
public final class TajweedSharing: Sendable {
    /// One recording in the outbox.
    public struct Item: Sendable, Hashable, Identifiable {
        /// The recording's upload id.
        public let id: String
        /// Its UTC day.
        public let day: String
        /// Known once the recording has ended (0 before).
        public let durationMs: Int
        public let bytes: Int64
        /// `queued` (recording, waiting or uploading), `uploaded` or `failed`.
        public let status: String
    }

    /// The learner's own shared minutes, this app's and Quran Lab's totals, and the line to show.
    public struct Summary: Sendable, Hashable {
        public let mySessions: Int
        public let myMinutes: Double
        /// Nil while the app has fewer than 10 contributors.
        public let appContributors: Int?
        public let appMinutes: Double?
        public let allContributors: Int
        public let allMinutes: Double
        /// The gratitude line of the copy deck with the learner's minutes, in the app's language.
        public let line: String
    }

    init() {}

    /// Quran Lab's signed config has sharing on: its incident switch (`flags.contributions`) is on and this platform
    /// may upload. False until a verified config says so.
    public var isAvailable: Bool { Contributions.isEnabled }

    /// The look of the sheets the SDK presents by itself: the ask at the end of a good take, `ask()`'s, and the card
    /// with the sheet it opens. Colours, corner radius and fonts only: the words, the structure and the consent version
    /// never change. The views and `.quranLabSharing()` take their own `theme` argument. Before 4.0 the SDK's own sheet
    /// always used `SharingTheme.standard` (the Flutter port, 11-18: an app's theme never reached it).
    public var theme: SharingTheme {
        get { Contributions.theme }
        set { Contributions.theme = newValue }
    }

    /// The learner said yes.
    public var isOn: Bool { Contributions.consent == .granted }

    /// The settings switch. On records the learner's yes; off stops uploads at once and deletes the unsent queue.
    /// Throws `sharing_unavailable` when turned on while Quran Lab's incident switch has sharing off (`isAvailable`
    /// is false); off always works, with one exception: when the device gives
    /// neither the learner's stored answer nor a place to write the off down, it throws `storage_failed`, and the
    /// SDK then records and uploads nothing more in this process. On throws `storage_failed`, and changes nothing,
    /// while the learner's stored answer cannot be read.
    public func setOn(_ on: Bool) async throws(TajweedError) {
        if on && !isAvailable { throw TajweedError(.sharingUnavailable) }
        // one operation for the cause it makes (4.0.1, RequestTrace: `sharing` names its request's role and fallback)
        try await RequestTrace.scope { () async -> Result<Void, TajweedError> in
            do throws(RecognizerError) {
                try await Contributions.switchSharing(on)
                return .success(())
            } catch {
                return .failure(TajweedError(from: error, stage: "sharing"))
            }
        }.get()
    }

    /// Asks now, at a point of the app's own flow, when an ask is due by the SDK's rules: the sheet the first time, a
    /// card after "Not now" (at most three asks per install, never after a yes or after sharing was turned off, never
    /// two in one app session or one day, the first not in the first 24 hours or before the 3rd completed take, a
    /// re-ask only 14 days and 7 completed takes after the last). Never at launch or during a take: only after a
    /// completed take in this app session and with no take open. True when the ask is due and goes on screen now;
    /// false, with nothing shown, when it is not due. The SDK also asks by itself at the end of a good take.
    @discardableResult
    public func ask() -> Bool { Contributions.askNow() != nil }

    /// Audio the app already captures outside takes (before the first, between them, after the last), mono at
    /// `sampleRate`. With sharing on and a yes, the SDK keeps the last second of it in memory and puts it in front of
    /// the next take's recording, and adds half a second after a take; otherwise it is dropped at once. The model
    /// never sees it. An app that uses `listen()` has no audio outside takes and need not call this.
    public func feed(_ samples: [Float], sampleRate: Double) {
        Contributions.recorder.feed(samples, rate: sampleRate)
    }

    /// The outbox: each recording and where its upload stands.
    public var items: [Item] {
        get async {
            guard let outbox = QuranLab.cloud?.outbox else { return [] }
            return await outbox.items.map { c in
                let status: String
                switch c.status {
                case .queued: status = "queued"
                case .uploaded: status = "uploaded"
                case .failed: status = "failed"
                }
                return Item(id: c.id, day: c.day, durationMs: c.durationMs, bytes: c.bytes, status: status)
            }
        }
    }

    /// The learner's summary from Quran Lab's server; nil when the call fails (show nothing then).
    public func summary() async -> Summary? {
        guard let s = await Contributions.summary() else { return nil }
        return Summary(mySessions: s.mySessions, myMinutes: s.myMinutes, appContributors: s.appContributors, appMinutes: s.appMinutes,
                       allContributors: s.allContributors, allMinutes: s.allMinutes, line: Contributions.copy.impact(minutes: s.myMinutes))
    }

    /// "Delete what I shared": every recording this learner shared from this app is deleted from Quran Lab's servers
    /// (signed with this device's key; no app credential can do it), the unsent queue is dropped, and sharing goes off.
    public func delete() async throws(TajweedError) {
        // one operation for the cause it makes (4.0.1, RequestTrace)
        try await RequestTrace.scope { () async -> Result<Void, TajweedError> in
            do throws(RecognizerError) {
                try await Contributions.deleteShared()
                return .success(())
            } catch {
                return .failure(TajweedError(from: error, stage: "sharing"))
            }
        }.get()
    }

    /// The code that deletes the learner's recordings when the device is lost; nil until the learner has shared.
    /// Show it only to the learner.
    public var recoveryCode: String? { Contributions.recoveryCodeForDisplay }

    /// Replaces strings of the SDK's sharing copy with the app's own words, by the deck's keys; nil or empty goes back
    /// to the deck. A learner who agrees from then on agrees to these words. An unknown key or an empty text throws
    /// `invalid_argument` and nothing changes.
    public func setWording(_ overrides: [String: String]?) throws(TajweedError) {
        do throws(RecognizerError) {
            try Contributions.setWording(overrides)
        } catch {
            throw TajweedError(from: error, stage: "sharing")
        }
    }
}
