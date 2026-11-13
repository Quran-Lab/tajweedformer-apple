import Foundation

/// Who the app is for. With `.children`, the SDK's consent sheet addresses the parent or guardian and needs their
/// confirmation before it can share.
enum Audience: String, Sendable, Hashable, Codable {
    case general
    case children
}

/// What the app should show now, if anything (the SDK's `SharingConsentView` shows it for you).
enum SharingMoment: Sendable, Hashable {
    /// The consent sheet: the first ask, or a gentle re-ask after "Not now" (the sheet is shown at most three times per
    /// install). `guardian`: the children's variant.
    case ask(reask: Bool, guardian: Bool)
    /// The thank-you line with its du'a, once, after the first shared session.
    case thanks
}

/// The learner's answer as the SDK keeps it.
enum SharingConsent: String, Sendable, Hashable, Codable {
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
    /// The count of the learner's changes of mind (3.0.1, rule R5): it goes up when sharing is turned off, when a
    /// deletion is accepted and when sharing comes on, in the same write as the consent. Every recording carries
    /// the count it was begun under; one that carries another is never uploaded. 0 in a state of an earlier SDK.
    var consentCount = 0
    /// The note of SDK 3.0.1 to 3.1.3 that "delete what I shared" is asking the server. Since 3.1.4 that is a file
    /// of its own (`DeletionMark`), and this field is never set: it is read from a state an earlier SDK stored,
    /// where it becomes the mark at the first read, and it is written as false.
    var deleting = false

    /// The most sheets an install is ever shown.
    static let maxAsks = 3
    /// The consent version of the deck 2.0.0 bundled on Apple platforms: a 2.0.0 grant without a recorded version
    /// agreed to it.
    static let version200 = "share-2026-11-07b"

    enum CodingKeys: String, CodingKey {
        case v, consent, asks, lastAskSession, sessions, thanked, decidedAt, consentVersion, consentTextSHA256, guardian,
             sharedOnce, consentCount, deleting
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
        consentCount = (try? c.decodeIfPresent(Int.self, forKey: .consentCount)) ?? 0
        deleting = (try? c.decodeIfPresent(Bool.self, forKey: .deleting)) ?? false
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
///
/// 2.0.3: takes that follow one another within a few seconds are one recording (`TakeJoin`), so an app that stops and
/// starts takes while the learner keeps reciting no longer splits the recitation.
enum Contributions {
    static let lock = Locked<SharingState?>(nil)

    /// The recording of the takes (2.0.3), one per process: it stays open after a take for the join window (the signed
    /// config's `flags.share_join_ms`, 3000 ms when absent), so the next take in a row continues the same stream. Its
    /// clock is the configured client's.
    static let recorder = ShareRecorder(
        clock: { QuranLab.cloud?.clock() ?? Date() },
        window: { QuranLab.cloud?.currentConfig?.flags.share_join_ms ?? TakeJoin.defaultWindowMs },
        active: { Contributions.isActive },
        // what a recording is bound to: a take joins an open one only in the same storage, under the same contributor,
        // consent version (and wording hash) and model revision; the backend and the input route may differ
        identity: { (info: ShareRecorder.TakeInfo) -> [String] in
            [QuranLab.configuration.storageDirectory.path, QuranLab.contributorID, Contributions.consentVersion ?? "",
             Contributions.grantedTextSHA256 ?? "", info.revision]
        },
        open: { (info: ShareRecorder.TakeInfo) -> (any ShareRecording)? in
            Contributions.capture(revision: info.version.isEmpty ? info.revision : info.version, build: info.version.isEmpty ? nil : info.revision,
                                  backend: info.backend, weightsSHA256: info.weightsSHA256)
        },
        // this install's count of shared recordings (take_seq, gap_ms_prev), in the configured storage
        sequence: .stored { ShareSequencer.file(storage: QuranLab.configuration.storageDirectory) })

    /// Where the learner's answer is kept in a storage folder.
    static func stateFile(storage: URL) -> JSONFile<SharingState> {
        JSONFile(url: storage.appendingPathComponent("cloud/sharing-state.json"))
    }

    private static func file() -> JSONFile<SharingState> { stateFile(storage: QuranLab.configuration.storageDirectory) }

    /// For tests: whether the device refuses to store the state now (a full disk, a storage that refuses the write).
    /// It refuses the write of the saved answer, and the write and the removal of the deletion mark.
    static let refusesWrites = Locked<(@Sendable () -> Bool)?>(nil)
    /// When the last write of the state failed, if it did. The state in memory is the one in force meanwhile.
    private static let unsaved = Locked<Date?>(nil)
    /// Whether this start found a deletion mark when it read the saved answer: the server is asked again for it.
    private static let foundMark = Locked(false)
    /// Whether the device has the state that is in force: the saved answer is written, and no deletion mark is left
    /// that should be gone.
    static var isStored: Bool {
        unsaved.withLock { $0 == nil } && !DeletionMark.removalOwed(QuranLab.configuration.storageDirectory)
    }

    /// Writes the state to the device; whether it is stored. A write that fails is tried again whenever the state is
    /// read (at most once a second) and at the state's next change, so the device has it as soon as it can.
    @discardableResult
    private static func store(_ v: SharingState, _ f: JSONFile<SharingState>) -> Bool {
        let refused = refusesWrites.withLock { $0 }?() ?? false
        let ok = !refused && f.store(v)
        unsaved.withLock { $0 = ok ? nil : Date() }
        // the answer this process holds is on the device: an off's mark that was applied to it has done its work
        if ok { OffMark.answerStored(f.url.deletingLastPathComponent().deletingLastPathComponent()) }
        return ok
    }

    /// The state as the device has it, at a process's first read that succeeds, in three results (3.1.4).
    ///
    /// A stored answer that is there and cannot be read (the system refuses the read, or the bytes do not parse)
    /// is not "never answered": nothing is made of it, nothing is written, and it is read again at the next need.
    /// Only a file that is not there is a fresh state. Until 3.1.3 a file that could not be read was a fresh state,
    /// kept for the life of the process and written over the stored answer at its next change.
    ///
    /// A deletion mark in the storage means that a process ended while the server was being asked to delete: the
    /// learner's wish stands, sharing is off from here, in this write, so the recordings of the earlier consent are
    /// never uploaded whatever the server did; and the server is asked again (`finishDeletion`). A state of 3.1.3
    /// or earlier that says a deletion was being asked (`deleting`) becomes the mark here.
    private static func fromDisk(_ f: JSONFile<SharingState>) -> StoredRead<SharingState> {
        var v: SharingState
        switch f.read() {
        case .unreadable(let why): return .unreadable(why)
        case .missing: v = SharingState()
        case .value(let read): v = read
        }
        v.upgrade()
        let storage = f.url.deletingLastPathComponent().deletingLastPathComponent()
        // a mark whose removal failed earlier in this process is not a deletion that is pending
        DeletionMark.retryRemoval(storage, atOnce: true)
        var changed = false
        // sharing goes off, with its count, when it is not off already
        func turnOff() {
            guard v.consent != .final else { return }
            if v.consent == .granted { v.consentCount += 1 }
            v.consent = .final
            v.decidedAt = Date().timeIntervalSince1970.rounded()
            changed = true
        }
        // an off that the learner asked while this answer could not be read (`OffMark`): applied now
        let offWaits = OffMark.waits(storage)
        if offWaits {
            turnOff()
            OffMark.appliedInProcess(storage)
        } else {
            // a mark whose off an earlier process wrote and could not remove: it is not applied again
            OffMark.removeLeftOver(storage)
        }
        var asked = DeletionMark.exists(storage)
        if v.deleting {
            // the upgrade: the earlier SDK's note becomes the mark; where the mark cannot be written the note stays
            if DeletionMark.write(storage) {
                v.deleting = false
                changed = true
            }
            asked = true
        }
        // the off of a deletion's mark is written once: when an earlier start wrote it, the answer the state holds
        // now is one the learner gave since (they turned sharing on again), and it stands. (A mark whose content
        // cannot be read is a mark all the same: the off is written.)
        let written = asked && DeletionMark.offWritten(storage)
        if asked, !written { turnOff() }
        let stored = changed ? store(v, f) : true
        // the off's mark goes once the off is on the device: with the write above, or, when that fails, with the
        // first later write of the answer that succeeds (`store`). When no write was needed (the stored answer was
        // off already) it goes now.
        if offWaits, !changed { OffMark.answerStored(storage) }
        if asked {
            // the deletion's mark says that its off is on the device, once it is
            if !written, stored, v.consent == .final { DeletionMark.noteOffWritten(storage) }
            foundMark.withLock { $0 = true }
            // the server is asked again, once in this start
            Task.detached(priority: .utility) { await Contributions.finishDeletion() }
        }
        return .value(v)
    }

    /// The learner's stored answer as this process has it now, in three results. One that could not be read is read
    /// again here, at every need, until it reads; from then on the process holds it.
    private static func current() -> StoredRead<SharingState> {
        lock.withLock { (s: inout SharingState?) -> StoredRead<SharingState> in
            if let s {
                // a write that failed is tried again, at most once a second; so is the removal of a mark
                if let tried = unsaved.withLock({ $0 }), Date().timeIntervalSince(tried) >= 1 { store(s, file()) }
                DeletionMark.retryRemoval(QuranLab.configuration.storageDirectory, atOnce: false)
                if unsaved.withLock({ $0 == nil }) { OffMark.retryRemoval(QuranLab.configuration.storageDirectory) }
                return .value(s)
            }
            let read = fromDisk(file())
            if case .value(let v) = read { s = v }
            return read
        }
    }

    /// The state in force. While the stored answer cannot be read this is a blank state: sharing is neither on nor
    /// off, and nothing may be made of it or written (`isReadable`, `update`).
    static func state() -> SharingState {
        if case .value(let v) = current() { return v }
        return SharingState()
    }

    /// Whether the learner's answer is in hand: read, or not there (never answered). False while a stored answer is
    /// there and cannot be read.
    static var isReadable: Bool { !current().isUnreadable }

    /// The state in force, nil while the stored answer cannot be read.
    static var inForce: SharingState? { current().takingUnreadableAsMissing }

    /// Changes the state and writes it. The count of the learner's changes of mind goes up whenever their yes comes
    /// into force or goes out of it (sharing on, sharing off, an accepted deletion), in the same write as the
    /// consent: the device never holds the new answer with the old count.
    /// While the stored answer cannot be read, nothing is changed and nothing is written (3.1.4): a write would go
    /// over the stored answer. `body` is not called then, and a blank state comes back.
    static func update(_ body: (inout SharingState) -> Void) -> SharingState {
        let f = file()
        return lock.withLock { s -> SharingState in
            var v: SharingState
            if let s {
                v = s
            } else {
                guard case .value(let read) = fromDisk(f) else { return SharingState() }
                v = read
            }
            v.upgrade()
            let had = v.consent == .granted
            body(&v)
            if (v.consent == .granted) != had { v.consentCount += 1 }
            s = v
            store(v, f)
            return v
        }
    }

    /// The count of the learner's changes of mind in force (the stamp of a recording that begins now).
    static var consentCount: Int { state().consentCount }

    /// Forgets the cached state (tests, and a new storage directory at configure).
    static func reload() {
        lock.withLock { $0 = nil }
        unsaved.withLock { $0 = nil }
        foundMark.withLock { $0 = false }
    }

    /// The copy deck in force (the app's locale, else English), with the app's own wording applied.
    static var copy: SharingCopy {
        SharingCopy.forLocale(QuranLab.configuration.options.sharingLocale).applying(wording)
    }

    private static let wordingState = Locked<[String: String]>([:])

    /// The app's own wording in force, by deck key (empty: the deck's words).
    static var wording: [String: String] { wordingState.withLock { $0 } }

    /// Replaces strings of the SDK's copy deck with the app's own words, `{key: text}` (the deck's keys; a plural line
    /// by category, `impact.minutes.one`). Nil or empty goes back to the deck's words. An unknown key or an empty or
    /// blank text throws `.invalidArgument` and nothing changes. Set it at launch, before the first session: a learner
    /// who agrees from then on agrees to these words, so their consent version is `custom-` and 24 hex digits of the
    /// words' hash (`consentTextSHA256`), and every session they share sends the hash for Quran Lab to review. A
    /// learner who already agreed keeps the version and hash they agreed to, is not asked again, and keeps sharing.
    /// Your words must still say that the audio of recitation sessions is sent to Quran Lab, what else is sent, what it
    /// is used for, and how to stop and delete.
    static func setWording(_ overrides: [String: String]?) throws(RecognizerError) {
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
    static var consentVersionInForce: String { copy.consentVersion }

    /// With the app's own wording: the SHA-256 (64 hex) every shared session carries, for the developer to send to
    /// Quran Lab with the wording. Nil with the deck's words.
    static var consentTextSHA256: String? { copy.consentTextSHA256 }

    /// With the app's own wording: the canonical text `consentTextSHA256` is the hash of. Nil with the deck's words.
    static var consentText: String? { copy.consentText }

    /// Your own UI instead of the SDK's sheet: the SDK hands each moment (the consent ask, the thank-you) to `handler`
    /// on the main actor and shows nothing itself. Show the deck's strings from `copy` (the app's own wording applied),
    /// buttons of equal weight, and report the learner's own tap with `answer(share:guardianConfirmed:)`. The SDK
    /// picks the moments and counts the asks as for its own sheet. Nil goes back to the SDK's sheet.
    static func setPresenter(_ handler: (@MainActor @Sendable (SharingMoment) -> Void)?) {
        SharingPresenter.shared.set(handler)
    }

    /// Quran Lab's signed config offers sharing to this app on this platform (flag `contributions`, decided per app on
    /// the server, and the upload trust tier). Since 2.0.1 the app's `Options.contributions` does not decide it, and
    /// without a verified config in force nothing is offered (2.0.0 offered it before the first config arrived). When
    /// false, the SDK never asks and never uploads; the learner's answer is kept. Offered is never consent: capture and
    /// upload also need the learner's grant (`isActive`).
    static var isEnabled: Bool {
        guard QuranLab.configuration.options.cloud != nil, let cfg = QuranLab.cloud?.currentConfig else { return false }
        if !cfg.flags.contributions { return false }
        if UploadTrust.tier(cfg, platform: AppIdentity.currentPlatform) == "off" { return false }
        return true
    }

    /// Enabled and the learner agreed: sessions are being shared. A grant holds whatever consent version it was given
    /// (an older deck, the app's earlier wording, a 2.0.0 grant): the sessions carry that version.
    ///
    /// While a deletion that a process ended in is not confirmed by the server (a deletion mark that this start
    /// found), nothing is recorded for sharing and nothing is uploaded, whatever the answer says (3.1.4): no
    /// recording may belong to a contributor whose deletion is being asked. A yes the learner gives in that time
    /// is stored at once and takes effect when the mark is gone and the new contributor exists.
    static var isActive: Bool {
        isEnabled && state().consent == .granted && !foundMark.withLock({ $0 })
    }

    /// The learner's answer.
    static var consent: SharingConsent { state().consent }

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
    static func sessionCompleted(feedback: Bool) -> SharingMoment? {
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
    static func askNow() -> SharingMoment? {
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
    static func answer(share: Bool, guardianConfirmed: Bool = false) {
        // the stored answer cannot be read: no answer is recorded over it, and none is counted
        guard isReadable else { return }
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
    /// deleted, and a request in flight is cancelled: no byte of audio leaves the device after this returns); it
    /// works whatever version the learner agreed to, and returns within 3 s whatever the network does.
    ///
    /// A stored answer that is damaged (3.1.4) is not written over by anything the SDK does by itself, but this
    /// switch is the learner's own act: a new answer is begun first (`startAfresh`), and the switch then works on
    /// it.
    ///
    /// While the system does not give the stored answer (3.1.4): an on throws `storageFailed` and changes nothing.
    /// An off is written down as a mark of its own (`OffMark`), the open recording ends, and the queue stops;
    /// nothing is recorded or uploaded while the mark is there, and the next read of the answer that succeeds,
    /// in this process or the next, applies the off and removes the mark. When the mark cannot be written either,
    /// the call throws `storageFailed`, and this process shares nothing more: the off is applied in it as soon as
    /// the answer reads.
    static func switchSharing(_ on: Bool, guardianConfirmed: Bool = false) async throws(RecognizerError) {
        if isDamaged {
            let begun = await startAfresh()
            if !begun { throw .storageFailed("the learner's stored answer is damaged and a new one could not be begun; nothing was changed") }
        }
        if !isReadable {
            if on {
                throw .storageFailed("the learner's stored answer cannot be read now; their yes was not recorded and nothing was changed, "
                                     + "and the next call tries again")
            }
            let storage = QuranLab.configuration.storageDirectory
            let marked = OffMark.ask(storage)
            // the open recording ends at once, and what is in flight is cancelled
            recorder.stop()
            await QuranLab.cloud?.outbox.cancelQueued()
            if !marked {
                throw .storageFailed("the learner's off could not be written down on this device; nothing more is recorded or uploaded "
                                     + "by this process, and the off is applied in it as soon as the stored answer reads")
            }
            return
        }
        if on {
            if state().consent == .granted { return }
            decide(share: true, guardianConfirmed: guardianConfirmed)
        } else {
            _ = update { s in
                s.consent = .final
                s.decidedAt = Date().timeIntervalSince1970.rounded()
            }
            // the open recording ends at once, in a take or waiting for the next one
            recorder.stop()
            await QuranLab.cloud?.outbox.cancelQueued()
        }
    }

    /// `switchSharing` for the SDK's own callers that have nowhere to show an error (its settings view shows the
    /// switch's state after the call).
    static func setSharing(_ on: Bool, guardianConfirmed: Bool = false) async {
        _ = try? await switchSharing(on, guardianConfirmed: guardianConfirmed)
    }

    /// Whether the stored answer was read and is not an answer (damaged), as against one the system does not give.
    static var isDamaged: Bool {
        if case .unreadable(.damaged) = current() { return true }
        return false
    }

    /// The learner's own act over a stored answer that is damaged (the switch either way, an accepted deletion):
    /// a new answer is begun. In this order: the damaged file is kept aside under another name
    /// (`cloud/sharing-state.damaged-<seconds>.json`; it is not deleted); the unsent queue goes, as at an off,
    /// because under which answer its recordings were made is not known, and a new count that happened to equal
    /// an old stamp must never send one; then the new state is written: sharing off, and the asks used up, so
    /// that the SDK never asks this install by itself again and the learner's switch is the only way on. The
    /// caller's act then works on that state. False, and nothing is changed, when the file cannot be kept aside
    /// or the new state cannot be written.
    private static func startAfresh() async -> Bool {
        let f = file()
        guard case .value(let bytes) = StorageSeam.read(f.url) else { return false }
        let aside = f.url.deletingLastPathComponent()
            .appendingPathComponent("sharing-state.damaged-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try bytes.write(to: aside, options: StorageProtection.atomic)
        } catch {
            return false
        }
        recorder.stop()
        if let outbox = QuranLab.cloud?.outbox {
            await outbox.removeUnsent()
        } else {
            let root = QuranLab.configuration.storageDirectory.appendingPathComponent("outbox")
            for name in ContributionOutbox.unsent(root: root) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
        return lock.withLock { (s: inout SharingState?) -> Bool in
            // read meanwhile, or no longer damaged: there is nothing to begin
            if s != nil { return true }
            guard case .unreadable(.damaged) = f.read() else { return true }
            var v = SharingState()
            v.consent = .final
            v.asks = SharingState.maxAsks
            v.decidedAt = Date().timeIntervalSince1970.rounded()
            guard store(v, f) else {
                unsaved.withLock { $0 = nil }
                return false
            }
            s = v
            return true
        }
    }

    /// The lines behind "What is shared" (disclosure lines: show them as they are).
    static var whatIsShared: [String] { [copy.string("what.detail")].filter { !$0.isEmpty } }

    /// This install's contribution code (32 hex), shown to the learner in the sharing settings for deletion requests.
    static var contributionCode: String { QuranLab.contributorID }

    /// "Delete what I shared": every recording this learner shared from this app is deleted from Quran Lab's
    /// servers (a challenge signed with this device's key, no app credential can do this),
    /// the unsent queue is dropped, and the contribution code, device key and recovery code are replaced, so later
    /// shares are not linked to the deleted ones. There is no call to delete another learner's recordings.
    ///
    /// The queue stops BEFORE the server is asked (3.0.1): nothing is sent while it answers, so nothing reaches the
    /// server after it has deleted. An accepted delete turns sharing off (the learner turns it on again with the
    /// switch; nobody is asked again). A delete the server did not take changes nothing: the call throws, sharing is
    /// still on, nothing on the device was deleted, and the queue goes on with what it had.
    /// When the device cannot store the state (a full disk, a storage that refuses the write), the server is asked
    /// all the same: the learner's wish to have their recordings deleted outranks the order of a local write. After
    /// an accepted deletion the state is written once more after the queue is deleted, when the write may succeed
    /// because the queue's files are gone. A write that failed is tried again whenever the state is read.
    ///
    /// 3.1.4, the deletion mark. Before the server is asked, the SDK writes on the device that a deletion was
    /// asked: a small file of its own in the storage folder (`DeletionMark`), holding that and when, nothing else.
    /// A deletion the server does not take while this process lives ends as before: the call throws, the mark is
    /// removed, sharing and the queue are as they were. A mark is left only by a process that ended while the
    /// server was being asked. The next start finds it, turns sharing off (as before), and asks the server again
    /// with the same contributor and the same device key (`finishDeletion`); the mark goes when the server has
    /// answered 202 and the device's part is done.
    /// The contributor and the device key are read before anything else, or made when the device has none (as
    /// before 3.1.4: "not there" is the only case in which one is made). While one of them is there and cannot be
    /// read, none is made in its place, the server is not asked and nothing changes: a request signed with another
    /// key would be answered 202 and delete nothing. The call then throws `storage_failed`.
    /// Tried before (to 3.1.3): the note that a deletion was being asked was a field of the saved answer, and a
    /// process that found it at its start turned sharing off and never asked the server again.
    /// Tried before (3.0.0): the server was asked first and the queue dropped after its answer, with sharing turned
    /// off last; segments could be sent while the server was deleting.
    static func deleteShared() async throws(RecognizerError) {
        guard let cloud = QuranLab.cloud else { throw .serviceUnavailable("deleting shared recordings (no cloud configured)") }
        let storage = cloud.storage
        guard let contributor = Contributor.id(storage: storage), let key = ContributorKey.key(storage: storage) else {
            throw .storageFailed("the contribution code or the device key on this device cannot be read now; the server was not asked "
                                 + "and nothing was changed, and the next call tries again")
        }
        await cloud.outbox.hold()
        // on the device before the server is asked: a deletion was asked. A process that ends before the answer
        // finds the mark at its next start. Where the mark cannot be written the server is asked all the same.
        // (A mark that an earlier process left is kept as it is: it says whether its off was written.)
        let pending = DeletionMark.exists(storage)
        if !pending { DeletionMark.write(storage) }
        do throws(RecognizerError) {
            try await cloud.deleteContributions(contributor: contributor, key: key)
        } catch {
            // not taken by the server while this process lives: nothing changes, and no mark is left (a mark
            // that an earlier process left stays: its deletion is still to be asked again)
            if !pending { DeletionMark.remove(storage) }
            await cloud.outbox.release()
            throw error
        }
        await deletionAccepted(cloud, turnsOff: true)
        await cloud.outbox.release()
    }

    /// The server took the deletion (202): the device's part. Sharing is off, in one write with its count, before
    /// anything on the device is deleted and before any take can open a recording; the open recording ends; the
    /// count of recordings starts again and the queue is dropped; the contribution code, the device key and the
    /// recovery code are replaced; and the mark goes, once the off is on the device (a mark that outlives its off
    /// is read as an off by the next start, which then finishes this).
    /// `turnsOff` is false for a start that asked again: there the off was written when the mark was found, and an
    /// answer the learner has given since stands.
    private static func deletionAccepted(_ cloud: QuranLabCloud, turnsOff: Bool) async {
        // another Client has taken this one's place meanwhile: its start finds the mark
        guard QuranLab.cloud === cloud else { return }
        let storage = cloud.storage
        // a stored answer that is damaged: the deletion is the learner's own act, and a new answer is begun (off)
        if isDamaged { _ = await startAfresh() }
        if turnsOff {
            _ = update { s in
                s.consent = .final
                s.decidedAt = Date().timeIntervalSince1970.rounded()
                s.deleting = false
            }
        }
        recorder.stop()
        // later recordings are not linked to the deleted ones: the count starts again
        ShareSequencer.reset(ShareSequencer.file(storage: storage))
        // (in the learner's own call the pass has left already: the hold waited for it)
        await cloud.outbox.cancelQueued(wait: 0.3)
        Contributor.reset(storage: storage)
        // the state once more, after the queue is deleted: a device that could not store the off before can now
        _ = update { (_: inout SharingState) in }
        if unsaved.withLock({ $0 == nil }), isReadable, DeletionMark.remove(storage) {
            // the deletion is confirmed and the new contributor is made at the next share: sharing may go on
            foundMark.withLock { $0 = false }
        }
    }

    /// A start that found the deletion mark (3.1.4): the server is asked again, with the contributor and the
    /// device key that are on the device, once in this start (and once more in it, with one fresh challenge, when
    /// the server answers 401 `nonce_invalid` or `timestamp_invalid`). A 202 ends it: the device's part is done and
    /// the mark goes. Any other answer, and no answer, leaves the mark for the next start; there is no limit to
    /// the starts that ask.
    ///
    /// Sharing is turned off before, where the saved answer is read (`fromDisk`), which also calls this. While the
    /// saved answer cannot be read nothing is asked: the off is written first. While the contributor or the device
    /// key is there and cannot be read nothing is asked either, and the mark stays: a request signed with another
    /// key would be answered 202 and delete nothing. A device that has no contributor or no device key at all has
    /// nothing at the server under a name it could sign for (the earlier process got its 202 and replaced them
    /// before it could remove the mark): the device's part is finished without a request.
    static func finishDeletion() async {
        guard let cloud = QuranLab.cloud, cloud.storage.path == QuranLab.configuration.storageDirectory.path else { return }
        let storage = cloud.storage
        // only a mark this start found when it read the saved answer: one that this process wrote itself belongs
        // to the learner's call that is asking now
        guard DeletionMark.exists(storage), isReadable, foundMark.withLock({ $0 }), cloud.takeDeletionTurn() else { return }
        let contributor: String
        let key: ContributorKey.Key
        switch (Contributor.stored(storage: storage), ContributorKey.storedKey(storage: storage)) {
        case (.value(let c), .value(let k)):
            contributor = c
            key = k
        case (.unreadable, _), (_, .unreadable):
            return
        default:
            await deletionAccepted(cloud, turnsOff: false)
            return
        }
        do throws(RecognizerError) {
            try await cloud.deleteContributions(contributor: contributor, key: key)
        } catch {
            return
        }
        await deletionAccepted(cloud, turnsOff: false)
    }

    /// The recovery code for a lost device, shown only by the SDK's own sharing settings view (never handed to the
    /// app). Nil until the learner has shared, and while the code on the device cannot be read.
    static var recoveryCodeForDisplay: String? {
        ContributorKey.storedCode(storage: QuranLab.configuration.storageDirectory).takingUnreadableAsMissing
    }

    /// The learner's own shared minutes, this app's and Quran Lab's totals (real numbers from the server); nil when
    /// the call fails (show nothing then).
    /// Nil also while the contributor's id cannot be read (3.1.4): nothing is asked without it.
    static func summary() async -> ContributionSummary? {
        guard let cloud = QuranLab.cloud, let contributor = Contributor.id(storage: cloud.storage) else { return nil }
        return await cloud.contributionSummary(contributor: contributor)
    }

    /// The capture for a recording that starts now, when sharing is active (the recorder asks for one when a take
    /// starts a new recording).
    static func capture(revision: String, build: String? = nil, backend: ActiveBackend, weightsSHA256: String?) -> ShareCapture? {
        // the count first, then the consent: a stop between the two is either seen here or leaves an old stamp
        let count = consentCount
        guard isActive, let outbox = QuranLab.cloud?.outbox else { return nil }
        let made = ShareCapture(outbox: outbox, consentVersion: consentVersion, consentTextSHA256: grantedTextSHA256, modelRevision: revision,
                                backend: backend.rawValue, weightsSHA256: weightsSHA256, modelBuild: build, consentCount: count)
        // the contributor's id, device key or recovery code is there and cannot be read: no recording begins
        return made.isAlive ? made : nil
    }

    /// A shared session finished (the thank-you becomes due at the next completed session).
    static func noteShared() { _ = update { $0.sharedOnce = true } }
}

/// The mark that the learner turned sharing off while the stored answer could not be read (3.1.4):
/// `cloud/off-pending.json` in the storage folder, beside the deletion's mark, holding that an off was asked, when,
/// and (only when the mark could not be removed) that its off is written. While it is there nothing is recorded
/// or uploaded (the answer cannot be read, and when it reads the off is applied before anything else:
/// `Contributions.fromDisk`). A process that could not write the mark keeps the off in memory for the storage
/// folder, so that it is applied in that process all the same.
///
/// The mark does not outlive its off. The off is applied once, to the answer the process holds; the mark goes at
/// the first moment that answer is on the device: with the write that applies it, or, when that write fails (a
/// full disk), with the first later write that succeeds, also when the learner has changed their answer in
/// between (their later answer is then what is on the device). A removal that fails is tried again whenever the
/// answer is read, and until it succeeds the mark says that its off is written: a later start does not apply
/// such a mark again, it only removes it. So a yes the learner gives after the off is never turned off by the
/// mark.
enum OffMark {
    struct Content: Codable, Sendable {
        var v = 1
        /// When the learner asked (seconds since 1970).
        var asked_at: Double
        /// Whether the off is on the device in the saved answer and only this file's removal is left; absent
        /// until then.
        var off_written: Bool?
    }

    static func url(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/off-pending.json") }

    static func exists(_ storage: URL) -> Bool { FileManager.default.fileExists(atPath: url(storage).path) }

    /// The storage folders for which an off was asked in this process and is not applied yet.
    private static let asked = Locked<Set<String>>([])

    /// The learner asked for an off: it is kept in this process, and written down; whether the device has the mark.
    static func ask(_ storage: URL) -> Bool {
        asked.withLock { _ = $0.insert(storage.path) }
        if Contributions.refusesWrites.withLock({ $0 })?() ?? false { return false }
        return JSONFile<Content>(url: url(storage)).store(Content(asked_at: Date().timeIntervalSince1970.rounded()))
    }

    /// The storage folders whose off was applied to the answer this process holds, and whose mark is still to go,
    /// with when its removal was last tried.
    private static let settling = Locked<[String: Date]>([:])

    /// Whether the mark on the device says that its off is written.
    private static func written(_ storage: URL) -> Bool {
        // unreadable is taken as not there here, because a mark is a mark by being there: without its content the
        // off is applied, which is the careful side
        JSONFile<Content>(url: url(storage)).read().takingUnreadableAsMissing?.off_written ?? false
    }

    /// Whether an off waits to be applied: it was asked in this process, or its mark is on the device and does
    /// not say that its off is written.
    static func waits(_ storage: URL) -> Bool {
        if asked.withLock({ $0.contains(storage.path) }) { return true }
        return exists(storage) && !written(storage)
    }

    /// The off was applied to the answer this process holds: from here the mark only waits for that answer to be
    /// on the device.
    static func appliedInProcess(_ storage: URL) {
        asked.withLock { _ = $0.remove(storage.path) }
        settling.withLock { $0[storage.path] = Date.distantPast }
    }

    /// The answer this process holds was written to the device: a mark whose off was applied to it goes. When it
    /// cannot be removed it says that its off is written, and the removal is tried again (`retryRemoval`).
    static func answerStored(_ storage: URL) {
        guard settling.withLock({ $0[storage.path] != nil }) else { return }
        try? FileManager.default.removeItem(at: url(storage))
        if !exists(storage) {
            settling.withLock { $0[storage.path] = nil }
            return
        }
        settling.withLock { $0[storage.path] = Date() }
        let file = JSONFile<Content>(url: url(storage))
        // unreadable is taken as not there here: a mark without content gets one with the time of this note
        var content = file.read().takingUnreadableAsMissing ?? Content(asked_at: Date().timeIntervalSince1970.rounded())
        content.off_written = true
        file.write(content)
    }

    /// A removal that failed is tried again, at most once a second (the answer is on the device).
    static func retryRemoval(_ storage: URL) {
        guard let tried = settling.withLock({ $0[storage.path] }), Date().timeIntervalSince(tried) >= 1 else { return }
        answerStored(storage)
    }

    /// A mark that says its off is written, left by a process that could not remove it: removed, not applied.
    static func removeLeftOver(_ storage: URL) {
        if exists(storage) { try? FileManager.default.removeItem(at: url(storage)) }
    }
}

/// The mark that a deletion was asked (3.1.4): `cloud/deletion-pending.json` in the storage folder, written before
/// the server is asked, holding that a deletion was asked, when, and whether its off has been written into the
/// saved answer, nothing else. A start looks whether the file is there, and for that one field. See
/// `Contributions.deleteShared` and `Contributions.finishDeletion`.
enum DeletionMark {
    struct Content: Codable, Sendable {
        var v = 1
        /// When the learner asked (seconds since 1970).
        var asked_at: Double
        /// Whether a start has written this mark's off into the saved answer; absent until then. An answer the
        /// learner gives after that (sharing on again) is theirs, and a later start does not turn it off again.
        var off_written: Bool?
    }

    static func url(_ storage: URL) -> URL { storage.appendingPathComponent("cloud/deletion-pending.json") }

    static func exists(_ storage: URL) -> Bool { FileManager.default.fileExists(atPath: url(storage).path) }

    /// Whether a start has written this mark's off into the saved answer.
    static func offWritten(_ storage: URL) -> Bool {
        // unreadable is taken as not there here, because a mark is a mark by being there: without its content
        // the start writes the off again, which is the careful side
        JSONFile<Content>(url: url(storage)).read().takingUnreadableAsMissing?.off_written ?? false
    }

    /// Notes in the mark that its off is on the device.
    static func noteOffWritten(_ storage: URL) {
        if refused { return }
        let file = JSONFile<Content>(url: url(storage))
        // unreadable is taken as not there here: a mark without content gets one with the time of this note
        var content = file.read().takingUnreadableAsMissing ?? Content(asked_at: Date().timeIntervalSince1970.rounded())
        content.off_written = true
        file.write(content)
    }

    /// The storages whose mark should be gone and could not be removed, with when it was last tried.
    private static let owed = Locked<[String: Date]>([:])

    private static var refused: Bool { Contributions.refusesWrites.withLock { $0 }?() ?? false }

    /// Writes the mark; whether the device has it now.
    @discardableResult
    static func write(_ storage: URL) -> Bool {
        if refused { return false }
        let ok = JSONFile<Content>(url: url(storage)).store(Content(asked_at: Date().timeIntervalSince1970.rounded()))
        if ok { owed.withLock { $0[storage.path] = nil } }
        return ok
    }

    /// Removes the mark; whether the device has none now. A removal that fails is tried again whenever the saved
    /// answer is read (at most once a second), so that a start does not take a mark that should be gone for a
    /// deletion that is pending.
    @discardableResult
    static func remove(_ storage: URL) -> Bool {
        var gone = !exists(storage)
        if !gone, !refused {
            try? FileManager.default.removeItem(at: url(storage))
            gone = !exists(storage)
        }
        owed.withLock { $0[storage.path] = gone ? nil : Date() }
        return gone
    }

    /// Whether a mark that should be gone is still there.
    static func removalOwed(_ storage: URL) -> Bool { owed.withLock { $0[storage.path] != nil } }

    /// Tries a removal that failed again: at once, or when the last try is a second old.
    static func retryRemoval(_ storage: URL, atOnce: Bool) {
        guard let tried = owed.withLock({ $0[storage.path] }) else { return }
        if atOnce || Date().timeIntervalSince(tried) >= 1 { remove(storage) }
    }
}

/// The learner's and the community's real totals (`GET /v1/contributions/summary`).
struct ContributionSummary: Sendable, Hashable {
    let mySessions: Int
    let myMinutes: Double
    /// Nil while the app has fewer than 10 contributors (the privacy floor).
    let appContributors: Int?
    let appMinutes: Double?
    let allContributors: Int
    let allMinutes: Double
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
