import Foundation

/// The shared sessions on their way to R2. Each session is a folder `<storage>/outbox/<id>/`
/// (excluded from backups) the capture fills while the session runs (see `ShareFiles`); the
/// outbox starts the upload once the first segment is closed, and PUTs every closed segment
/// straight to R2, each to its own presigned URL (the Worker hands them out in batches of 20; the
/// outbox asks for the next batch when 5 unused URLs remain, and for fresh ones when R2 answers 403
/// to an expired URL). Nothing else is sent: the server
/// reads the session's state from the audio (the last page of a finished session ends the
/// stream). Uploads go whenever
/// there is a connection, on a background URLSession on iOS (they continue while the app is
/// suspended), in order, and retry with backoff; a re-sent segment is the same key and bytes.
///
/// Since 2.0.3 a recording may hold several takes. Its segments upload as before while it waits for the next take;
/// once it has closed and every segment is up, the item is uploaded, and a recording of two or more takes then sends
/// its take list (`POST /v1/uploads/{id}/takes`, the body of `takes.json`). That call never changes the item's
/// status: it is retried with the same backoff until it is accepted or dropped, across relaunches.
///
/// Sharing off during an upload (3.0.1, the four rules of the shared `sharing_off.json`): when the learner turns
/// sharing off or deletes what they shared, no byte of audio leaves the device after the call returns, whatever
/// was in flight; the call returns within 3 s even when a request hangs; nothing unsent stays on the device; and
/// turning sharing on again works at once. For that every request of a pass is its own task and is cancelled by
/// a stop (`transmit`, `abort`), the pass asks `may` before every request and after every answer, a recording
/// that was taken out stays out (`gone`: no record, no write, no request, and its folder is deleted again at the
/// second look), and no pass starts while a stop is at work (`stops`).
/// A recording made under an earlier consent is never uploaded (rule R5): the learner's answer carries a count of
/// their changes of mind, every recording's folder is stamped with the count it was begun under, and `earlier`
/// finds every unsent recording with another count, and every unsent recording when the learner's yes is not in
/// force. They are deleted when the outbox is made (a launch) and before every pass, and are never loaded into
/// the queue; one that cannot be deleted yet stays out and is tried again. The signed config's pause is not the
/// learner's no: it keeps the queue. What refuses them is on the device and survives the end of the process.
/// Tried before (3.0.0, and the first 3.0.1 candidate): only the list in memory (`gone`). A process that ended
/// between the saved off and the delete, or a stop that could not delete, left recordings that the next launch
/// took into the queue and uploaded once sharing came on again.
/// Tried before (3.0.0): the off call removed the record and the folder and let the request in flight run to its
/// end. No new request started and nothing was put back, but the rest of the segment that was being sent went
/// out after the call had returned, and a request that hung kept the next recording waiting behind it.
actor ContributionOutbox {
    static let itemName = "item.json"
    /// The most item changes that wait unread on `updates()`.
    static let waitingUpdates = 64

    struct Record: Codable {
        enum State: String, Codable { case active, uploaded, failed }
        /// Where the take list of a recording of two or more takes stands (2.0.3).
        enum Takes: String, Codable { case pending, sent, dropped }
        var id: String
        var seq = 0
        var state: State = .active
        /// The server has the session (POST /v1/uploads answered).
        var started = false
        /// Presigned PUT URLs for segments not uploaded yet (optional: items of older builds lack it).
        var urls: [ContributionClient.SegmentURL]?
        /// "seg-00001.opus", ... in R2.
        var uploaded: Set<String> = []
        var failCode: String?
        var failMessage: String?
        var attempts = 0
        var lastError: String?
        /// Local only: when the next retry is due.
        var nextAttempt: Date?
        /// The take list of a recording of two or more takes (2.0.3; optional: items of older builds lack it): nil when
        /// there is none to send, pending from the moment the item is uploaded until the list is sent or dropped.
        var takes: Takes?
        var takesAttempts: Int?
        /// The bad-request issue of this list was reported (once per list; optional: items of older builds lack it).
        var takesIssueReported: Bool?
        /// Local only: when the next try of the take list is due.
        var takesNextAttempt: Date?

        /// Something is still to send: segments, or the take list of an uploaded recording.
        var waiting: Bool { state == .active || takes == .pending }
        /// When the next try is due.
        var due: Date? { state == .active ? nextAttempt : takesNextAttempt }
    }

    enum Transport {
        case inProcess
        case background(BackgroundUploader)
    }

    nonisolated let root: URL
    nonisolated let storage: URL
    /// 2.0.1: the bitrate shared sessions are encoded at, from how the uploads go (one per outbox, in memory: a new
    /// process starts at the top).
    nonisolated let ladder: BitrateLadder
    private let client: ContributionClient
    private let http: HTTPClient
    private let tokens: TokenProvider?
    private let config: ConfigStore
    private let clock: @Sendable () -> Date
    private let transport: Transport
    private var records: [String: Record] = [:]
    /// The recordings the last look at the queue left alone because one of their files is there and cannot be read
    /// (3.1.4): nothing is sent, written or deleted for them until a later look reads it.
    private var held: Set<String> = []
    /// PUTs running now ("<id>/<file>").
    private var inFlight: Set<String> = []
    /// The requests of the pass that this process runs now, by "<id>/<what>" (a segment's file name, `call` for the
    /// start and the URLs, `takes`): each is its own task, so that a stop can cancel it.
    private var sending: [String: Task<Result<HTTPClient.Response, CloudError>, Never>] = [:]
    /// The requests a stop cancelled: what comes back from them is not an upload that failed.
    private var aborted: Set<String> = []
    /// The recordings sharing-off took out of the queue: nothing is written or sent for them again, and a folder of
    /// one that shows up again is deleted. (An id is a recording's own and is never used twice.)
    private var gone: Set<String> = []
    /// Stops at work (sharing is going off, or "delete what I shared" is asking the server): no pass starts and no
    /// request goes out while this is above 0.
    private var stops = 0
    /// How long a stop waits for the pass to leave. The off call's own bound is 3 s (rule R2).
    static let stopWait: TimeInterval = 2.5
    /// The pass's wait for a token, while it waits: a stop ends the wait through it.
    private var tokenWait: AsyncStream<Result<APIToken, CloudError>?>.Continuation?
    private var offline: Set<String> = []
    private var running: Task<Void, Never>?
    private var again = false
    private var againIgnoringBackoff = false
    private var wake: Task<Void, Never>?
    private var watchers: [UUID: AsyncStream<Contribution>.Continuation] = [:]
    /// Times a server answered 404 to a take list (the line for the developer is written once).
    private(set) var takesRouteNotes = 0
    /// Bad-request issues reported for take lists by this outbox (one per refused list).
    private(set) var takesIssues = 0

    /// Told the host a background upload was redirected to (3.1.3): reported as an issue, the host only.
    private let onRedirect: @Sendable (String) -> Void

    init(storage: URL, http: HTTPClient, apiURL: URL, tokens: TokenProvider?, config: ConfigStore, options: CloudOptions,
         app: AppIdentity, clock: @escaping @Sendable () -> Date, ladder: BitrateLadder = BitrateLadder(),
         redirected: @escaping @Sendable (String) -> Void = { _ in }) {
        onRedirect = redirected
        self.storage = storage
        self.ladder = ladder
        root = storage.appendingPathComponent("outbox")
        self.http = http
        client = ContributionClient(http: http, apiURL: apiURL)
        self.tokens = tokens
        self.config = config
        self.clock = clock
        try? StorageProtection.makeFolder(root)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var r = root
        try? r.setResourceValues(values)
        if options.backgroundUploads && options.urlSession == nil {
            let bg = BackgroundUploader.shared(identifier: BackgroundUploader.identifier(for: app))
            transport = .background(bg)
            // results of uploads started before a relaunch arrive here
            bg.attach(self)
        } else {
            transport = .inProcess
        }
        // a launch: what was left unsent under an earlier consent goes before any pass is asked for. While the
        // learner's stored answer cannot be read, nothing goes.
        if let look = Self.earlier(root: root, storage: storage, launch: true) {
            for name in look.gone {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
        // and the upload tasks an earlier process left with the system, whose recording is gone or may not be sent
        if case .background = transport {
            Task.detached(priority: .utility) { await self.cancelOrphans() }
        }
    }

    /// What the device says of the learner's answer in `storage`: whether their yes is in force (the signed config's
    /// pause is not looked at: it keeps the queue), and the count of their changes of mind. At a launch, a deletion
    /// that was being asked is an off (the deletion mark, or the note of a state that SDK 3.1.3 or an earlier one
    /// stored): the process that asked ended before the answer was written. While this process itself is asking,
    /// it is not: a deletion the server does not take changes nothing.
    ///
    /// Nil (3.1.4): the stored answer is there and cannot be read. That is neither a yes nor a no: nothing may be
    /// uploaded and nothing may be deleted on its account. Only a file that is not there is "never answered". Until
    /// 3.1.3 an answer that could not be read was a no with count 0, and a launch deleted the unsent recordings.
    ///
    /// In the process that holds this storage's state, the state in force there is asked, not the file: a write of
    /// the state that failed (a full disk) leaves the file behind the state in force, and recordings begun under the
    /// count in force must not read as earlier ones. At a launch the file is all there is.
    static func consentOnDevice(_ storage: URL, launch: Bool = false) -> (on: Bool, count: Int)? {
        if !launch, QuranLab.configuration.storageDirectory.path == storage.path {
            guard let s = Contributions.inForce else { return nil }
            return (s.consent == .granted, s.consentCount)
        }
        switch Contributions.stateFile(storage: storage).read() {
        case .unreadable: return nil
        case .missing: return (false, 0)
        case .value(let s):
            // so is an off the learner asked while the answer could not be read (`OffMark`)
            let asked = launch && (s.deleting || DeletionMark.exists(storage) || OffMark.exists(storage))
            return (s.consent == .granted && !asked, s.consentCount)
        }
    }

    /// The item file of a recording's folder, in three results. A file the system does not give (refused) is
    /// `unreadable`: its recording is left alone.
    static func item(_ folder: URL) -> StoredRead<Record> {
        switch StorageSeam.read(folder.appendingPathComponent(itemName)) {
        case .missing: return .missing
        case .unreadable(let why): return .unreadable(why)
        case .value(let d):
            // damaged is taken as no item here (bytes that were read and are not an item), as before 3.1.4: the
            // recording is then one that is still to send, as with an item file that was deleted; it is sent
            // while the learner's yes covers it and goes with their off, and is not kept for ever
            guard let rec = try? JSONDecoder().decode(Record.self, from: d) else { return .missing }
            return .value(rec)
        }
    }

    /// One look at the queue's folders.
    struct Look {
        /// The unsent recordings made under an earlier consent: they are deleted.
        var gone: [String] = []
        /// The recordings left alone at this look: their item file or their stamp is there and cannot be read.
        var held: Set<String> = []
    }

    /// The unsent recordings in `root` that were made under an earlier consent (rule R5): every recording still to
    /// send whose stamp is not the count in force, and every one when the learner's yes is not in force. A recording
    /// that is being captured now is not looked at (its capture ends it), nor one that is sent or has failed (they
    /// hold no audio).
    ///
    /// Nil while the learner's stored answer cannot be read: nothing is deleted then and nothing is taken up. A
    /// recording whose item file cannot be read may be one that was sent: it is left alone. One whose stamp cannot
    /// be read, while the learner's yes is in force, is neither of an earlier consent nor one that may be sent: it
    /// is left alone too. (When the learner's yes is not in force the stamp is not asked: every unsent recording
    /// goes.)
    static func earlier(root: URL, storage: URL, launch: Bool = false) -> Look? {
        guard let now = consentOnDevice(storage, launch: launch) else { return nil }
        return look(root: root, now: now)
    }

    /// The recordings in `root` that are still to send, whatever their stamp: what goes when a new answer is begun
    /// over a damaged one (`Contributions.startAfresh`). Not those being captured now, not those that are sent or
    /// have failed, and not those whose item file the system does not give.
    static func unsent(root: URL) -> [String] { look(root: root, now: (on: false, count: 0)).gone }

    /// `earlier`, for a given answer.
    static func look(root: URL, now: (on: Bool, count: Int)) -> Look {
        let fm = FileManager.default
        var out = Look()
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.count == 32 && name.allSatisfy(\.isHexDigit) {
            if ShareCapture.active.withLock({ $0.contains(name) }) { continue }
            let f = root.appendingPathComponent(name, isDirectory: true)
            switch item(f) {
            case .value(let rec):
                if rec.state != .active { continue }
            case .unreadable:
                out.held.insert(name)
                continue
            case .missing:
                break
            }
            if !now.on {
                out.gone.append(name)
                continue
            }
            switch ShareFiles.stamped(ShareFiles.stamp(f), with: now.count) {
            case .some(true): break
            case .some(false): out.gone.append(name)
            case .none: out.held.insert(name)
            }
        }
        return out
    }

    // MARK: public

    /// Every session, oldest first.
    var items: [Contribution] {
        scan()
        return records.values.sorted { $0.seq < $1.seq }.map(snapshot)
    }

    func item(_ id: String) -> Contribution? {
        scan()
        return records[id].map(snapshot)
    }

    /// Every change to an item, as it happens. At most 64 changes wait for a reader; the oldest waiting one is dropped
    /// (`items` has every item's state now).
    func updates() -> AsyncStream<Contribution> {
        let (stream, c) = AsyncStream<Contribution>.makeStream(bufferingPolicy: .bufferingNewest(Self.waitingUpdates))
        let key = UUID()
        watchers[key] = c
        c.onTermination = { [weak self] _ in Task { await self?.unwatch(key) } }
        return stream
    }

    /// Takes a session out before the server has it: its files go and nothing is sent. Once its
    /// upload has started it cannot be cancelled.
    func cancel(_ id: String) throws(RecognizerError) {
        scan()
        guard let r = records[id] else { throw .contributionUnavailable("no outbox item \(id)") }
        guard r.state == .active, !r.started, !ShareCapture.active.withLock({ $0.contains(id) }) else {
            throw .contributionUnavailable("item \(id) is already uploading")
        }
        remove(id)
    }

    /// Starts an upload pass now (it also runs at launch, when a segment closes and when a retry is
    /// due). Returns at once.
    nonisolated func resume() {
        Task.detached(priority: .utility) { await self.drain() }
    }

    // MARK: internal

    /// A capture closed a segment or ended.
    func poke() async { await drain() }

    /// Sharing was turned off (the settings switch, an accepted "delete what I shared"): every session not yet fully
    /// uploaded goes (the server marks a started one abandoned after 48 hours without activity).
    ///
    /// In this order (3.0.1): the queue is marked stopped; every request in flight is cancelled; the unsent
    /// recordings leave the queue in memory, so nothing is written or sent for them from here on; the call waits
    /// until the pass has left (at most `wait`); then their folders are deleted; then a second look deletes whatever
    /// is unsent on disk after that. A take list still to send is dropped with its file (its recording stays
    /// uploaded).
    func cancelQueued(wait: TimeInterval = ContributionOutbox.stopWait) async {
        stops += 1
        abort()
        var out = takeOut()
        await left(within: wait)
        for id in out { try? FileManager.default.removeItem(at: folder(id)) }
        // the second look: a recording that ended meanwhile, and anything a pass put back on its way out
        out += takeOut()
        for id in out { try? FileManager.default.removeItem(at: folder(id)) }
        stops -= 1
    }

    /// Every recording still to send goes, whatever its stamp (3.1.4): the learner begins a new answer over a stored
    /// one that is damaged, and under which answer these recordings were made is not known. In the order of
    /// `cancelQueued`: the queue stops, what is in flight is cancelled, the pass leaves, the folders are deleted.
    func removeUnsent(wait: TimeInterval = ContributionOutbox.stopWait) async {
        stops += 1
        abort()
        await left(within: wait)
        for name in Self.unsent(root: root) {
            gone.insert(name)
            records[name] = nil
            try? FileManager.default.removeItem(at: folder(name))
        }
        for r in records.values where r.takes == .pending {
            endTakes(r.id, .dropped)
            try? FileManager.default.removeItem(at: folder(r.id).appendingPathComponent(ShareFiles.takesFile))
        }
        stops -= 1
    }

    /// "Delete what I shared" is about to ask the server, and sharing is still on: the queue stops (no pass starts,
    /// no request goes out, what is in flight is cancelled), and the call returns when the pass has left, at most
    /// `stopWait` later. Nothing is deleted. `release()` ends it.
    func hold() async {
        stops += 1
        abort()
        await left(within: Self.stopWait)
    }

    /// The end of a `hold()`: the queue goes on with what it has (a delete the server did not take changes nothing;
    /// after an accepted one there is nothing left to send).
    func release() {
        stops = max(0, stops - 1)
        if stops == 0 { resume() }
    }

    /// Takes every unsent recording out of the queue in memory, and drops the take lists still to send; the ids of
    /// the recordings taken out.
    private func takeOut() -> [String] {
        scan()
        var out: [String] = []
        for r in records.values where r.state == .active && !ShareCapture.active.withLock({ $0.contains(r.id) }) {
            gone.insert(r.id)
            records[r.id] = nil
            out.append(r.id)
        }
        for r in records.values where r.takes == .pending {
            endTakes(r.id, .dropped)
            // the list was not sent and will not be: its file goes (the recording's status then counts one take)
            try? FileManager.default.removeItem(at: folder(r.id).appendingPathComponent(ShareFiles.takesFile))
        }
        return out
    }

    /// Cancels every request in flight: those this process runs, and the background session's uploads; and ends the
    /// pass's wait for a token.
    private func abort() {
        tokenWait?.yield(nil)
        tokenWait?.finish()
        tokenWait = nil
        aborted.formUnion(sending.keys)
        aborted.formUnion(inFlight)
        for task in sending.values { task.cancel() }
        if case .background(let bg) = transport { bg.cancel(prefix: "") }
    }

    /// Waits until the pass has left, at most `seconds`.
    private func left(within seconds: TimeInterval) async {
        let start = Date()
        while running != nil, Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Whether the pass may send or write for `id` now: no stop is at work, sharing is still on, and the recording
    /// is still in the queue. Asked before every request and after every answer.
    private func may(_ id: String) -> Bool {
        stops == 0 && !isClosed && !gone.contains(id) && !held.contains(id) && records[id] != nil && Contributions.isActive
    }

    /// A token for the pass. The wait for one is a wait for the network (an attestation, a token request), so a stop
    /// ends it: nil then, and the pass leaves. The token request itself goes on and serves the next pass.
    private func tokenOrStop(_ tokens: TokenProvider) async -> Result<APIToken, CloudError>? {
        guard stops == 0 else { return nil }
        let (answers, c) = AsyncStream<Result<APIToken, CloudError>?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        Task.detached(priority: .utility) {
            let r: Result<APIToken, CloudError>
            do throws(CloudError) { r = .success(try await tokens.token()) } catch { r = .failure(error) }
            c.yield(r)
            c.finish()
        }
        tokenWait = c
        var got: Result<APIToken, CloudError>?
        for await answer in answers {
            got = answer
            break
        }
        tokenWait = nil
        return stops > 0 ? nil : got
    }

    /// One request of a pass, as its own task so that a stop can cancel it. Nil when the pass may not send for `id`
    /// (before the request, or by the time it came back) or when a stop cancelled the request: the pass then leaves,
    /// and what came back counts for nothing (no retry, no step down the bitrate ladder).
    private func transmit(_ id: String, _ what: String, _ request: URLRequest) async -> Result<HTTPClient.Response, CloudError>? {
        guard may(id) else { return nil }
        let http = self.http
        let task = Task.detached(priority: .utility) { () async -> Result<HTTPClient.Response, CloudError> in
            do throws(CloudError) { return .success(try await http.send(request)) } catch { return .failure(error) }
        }
        let key = "\(id)/\(what)"
        sending[key] = task
        let result = await task.value
        sending[key] = nil
        if aborted.remove(key) != nil { return nil }
        guard may(id) else { return nil }
        return result
    }

    /// Whether the pending take list of an item waits for a later pass (its last try was answered or failed).
    func takesWaits(_ id: String) -> Bool { records[id]?.takes == .pending && records[id]?.takesNextAttempt != nil }

    /// Where the take list of an item stands (nil: none to send).
    func takesState(_ id: String) -> Record.Takes? {
        scan()
        return records[id]?.takes
    }

    /// One upload pass, after any pass already running (a request during a pass runs one more).
    /// `ignoringBackoff` is for tests.
    /// The Client that owns this outbox was closed: no pass runs from here on (what is queued stays on disk for the
    /// next Client's outbox).
    /// The end of the Client that made this queue. No pass starts from here on, and a pass that was started before
    /// stops before it deletes or uploads anything (3.1.5): it looks at the shut-down mark before its first look at
    /// the queue, and before every request.
    /// Tried before (to 3.1.3): only new passes were stopped. A pass that was already on its way went on to read
    /// the queue's folders, and removed a recording whose files the next Client's owner had changed meanwhile.
    nonisolated func shutdown() { closedFlag.withLock { $0 = true } }

    #if DEBUG
    /// For tests: a wait between a pass being started and its first look at the queue, in nanoseconds.
    static let passDelayForTests = Locked<UInt64>(0)
    #endif

    nonisolated var isClosed: Bool { closedFlag.withLock { $0 } }

    private nonisolated let closedFlag = Locked(false)

    func drain(ignoringBackoff: Bool = false) async {
        // no pass starts while a stop is at work (the one who stopped it starts the queue again when it goes on)
        if isClosed || stops > 0 { return }
        if running != nil {
            again = true
            // the pass that runs for this request honours it, whichever caller starts that pass
            againIgnoringBackoff = againIgnoringBackoff || ignoringBackoff
            while let t = running { await t.value }
            if !again || stops > 0 { return }
        }
        let ignore = ignoringBackoff || againIgnoringBackoff
        again = false
        againIgnoringBackoff = false
        let t = Task {
            await self.reconcile()
            #if DEBUG
            let wait = Self.passDelayForTests.withLock { $0 }
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            #endif
            await self.pass(ignoringBackoff: ignore)
            self.scheduleWake()
            self.running = nil
        }
        running = t
        await t.value
        if again, stops == 0 { await drain() }
    }

    private func pass(ignoringBackoff: Bool) async {
        // a queue that was shut down after this pass was started: nothing is read, deleted or sent
        guard !isClosed else { return }
        scan()
        expireTakes()
        guard let tokens, stops == 0, Contributions.isActive else { return }
        // the contributor's id, device key or recovery code is there and cannot be read (3.1.4): nothing is sent
        // until it reads
        guard Contributor.isReadable(storage: storage) else { return }
        let now = clock()
        let due = records.values.filter { $0.waiting && !held.contains($0.id) && (ignoringBackoff || ($0.due ?? .distantPast) <= now) }
            .sorted { $0.seq < $1.seq }.map(\.id)
        guard !due.isEmpty else { return }
        if config.current?.flags.contributions != true {
            for id in due { note(id, "sharing is turned off for this app; waiting") }
            return
        }
        for id in due {
            if Task.isCancelled || stops > 0 { return }
            // an uploaded recording whose take list waits: a token that cannot be had never changes its status
            let listOnly = records[id]?.state == .uploaded
            // the wait for a token is a wait for the network: a stop ends it, and the pass leaves
            guard let answer = await tokenOrStop(tokens) else { return }
            let token: APIToken
            switch answer {
            case .success(let t):
                token = t
            case .failure(let error):
                if listOnly {
                    retryTakes(id)
                    if error.retryable { return }
                    continue
                }
                if error.retryable { retry(id, "token: \(error)"); return }
                fail(id, code: "token", message: "\(error)")
                continue
            }
            let tier = config.current.map { UploadTrust.tier($0, platform: AppIdentity.currentPlatform) } ?? "attested"
            guard token.attested || tier == "capped" else {
                if listOnly {
                    retryTakes(id)
                } else {
                    fail(id, code: "attestation_required", message: "this install has no App Attest backed token")
                }
                continue
            }
            if !(await step(id, token: token.token)) { return }
        }
    }

    /// Moves one session on as far as it goes now. False when the pass should stop (offline).
    private func step(_ id: String, token: String) async -> Bool {
        let folder = self.folder(id)
        // the recording's markers, its end and its take list are read strictly (3.1.4): while one of them is there
        // and cannot be read the recording is left as it is at this pass (no segment is left out, and it is not
        // finished without its last one)
        guard case .value(let markers) = ShareFiles.closed(folder) else { return true }
        let end: ShareFiles.End?
        switch ShareFiles.stored(ShareFiles.End.self, folder.appendingPathComponent(ShareFiles.end)) {
        case .value(let e): end = e
        case .missing: end = nil
        case .unreadable: return true
        }
        guard case .value(let takeList) = ShareFiles.storedTakes(folder) else { return true }
        guard var rec = records[id] else { return true }
        // before the first write and the first request for this recording: is sharing still on, and no stop at work?
        guard may(id) else { return false }
        // uploaded, its take list still to send
        if rec.state != .active { return await sendTakes(id, token: token) }
        // the server hears of a session only once it has a segment (a short failed session never
        // reaches it)
        if !rec.started {
            // a session JSON that cannot be read: the recording waits (it is not started without it)
            guard !markers.isEmpty, let session = try? StorageSeam.data(folder.appendingPathComponent(ShareFiles.session)) else { return true }
            rec.attempts += 1
            save(rec)
            guard let urls = await call(id, client.startRequest(id: id, session: session, token: token)) else { return !isOffline(id) }
            // the item can go while the call is out (sharing turned off, cancel(_:)): nothing is left to send for it
            guard let now = records[id] else { return true }
            rec = now
            rec.started = true
            rec.urls = merge(rec.urls, urls)
            save(rec)
        }
        // every closed segment, in order, each to its own URL
        for m in markers {
            let name = ShareFiles.name(m.n) + ".opus"
            guard !rec.uploaded.contains(name), !inFlight.contains("\(id)/\(name)") else { continue }
            // sharing can go off while this pass runs: from then on nothing more is sent
            guard may(id) else { return false }
            if rec.urls?.first(where: { $0.n == m.n })?.fresh(at: clock()) != true {
                // none for this segment yet (the next batch did not come in time), or it expired
                guard await fetchURLs(id, from: m.n, token: token) else { return !isOffline(id) }
                rec = records[id]!
            }
            guard let u = rec.urls?.first(where: { $0.n == m.n }) else { return true }
            let request = ContributionClient.putRequest(u, contentType: "audio/ogg", bytes: m.bytes)
            let file = folder.appendingPathComponent(name)
            inFlight.insert("\(id)/\(name)")
            switch transport {
            case .background(let bg):
                bg.start(request, file: file, key: "\(id)/\(name)")
            case .inProcess:
                var r = request
                r.httpBodyStream = InputStream(url: file)
                guard let result = await transmit(id, name, r) else {
                    // stopped: the segment is not up, and the pass leaves
                    inFlight.remove("\(id)/\(name)")
                    return false
                }
                if !put(id, name, result) { return false }
                guard let now = records[id], now.state == .active else { return true }
                rec = now
                // refused (put() has scheduled the retry, at once for a 403): this pass stops here
                if !rec.uploaded.contains(name) { return true }
            }
        }
        // while the session runs: the next batch once 5 unused URLs remain, so a segment that closes
        // never waits for a Worker call
        if end == nil, let last = rec.urls?.map(\.n).max(), last - (markers.last?.n ?? 0) <= 5 {
            guard await fetchURLs(id, from: last + 1, token: token) else { return !isOffline(id) }
        }
        rec = records[id] ?? rec
        // done once the session has ended and every segment is up: the server reads the rest from
        // the audio (the last segment ends the stream)
        guard end != nil, rec.started, !markers.isEmpty,
              markers.allSatisfy({ rec.uploaded.contains(ShareFiles.name($0.n) + ".opus") }) else { return true }
        rec.state = .uploaded
        rec.lastError = nil
        rec.nextAttempt = nil
        rec.urls = nil
        // 2.0.3: a recording of several takes sends its take list next; the session is uploaded whatever comes of it
        if takeList != nil { rec.takes = .pending }
        save(rec)
        // the item, the markers, the end, the session JSON and the take list stay (they give the status its numbers)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name != Self.itemName && name != ShareFiles.end && name != ShareFiles.session && name != ShareFiles.takesFile
            && name != ShareFiles.stampFile
            && !(name.hasPrefix("seg-") && name.hasSuffix(".json")) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        return await sendTakes(id, token: token)
    }

    /// The take list of an uploaded recording of two or more takes (2.0.3): `POST /v1/uploads/{id}/takes` with the body
    /// of `takes.json`, once the recording has closed and its segments are up. The session stays uploaded whatever the
    /// answer: 2xx, the list is sent; 404 (a server without the route, or one that does not know the upload) and 410
    /// drop it; 401 renews the token and tries again; 408, 429, 5xx and no answer keep it for a later pass with the
    /// outbox's backoff (the same body again; the server replaces the list). 400 keeps it too (SDK 3.0.0; 2.0.3
    /// dropped it): the server could refuse a correct list while its duration was stale, so the list is retried on
    /// the backoff until it is accepted, sharing goes off or seven days pass, and the bad-request issue is reported
    /// once for the list.
    /// The bitrate ladder does not hear of this call: it is not audio. False when the pass should stop (offline).
    private func sendTakes(_ id: String, token: String) async -> Bool {
        guard var rec = records[id], rec.state == .uploaded, rec.takes == .pending else { return true }
        // a take list that is there and cannot be read is neither sent nor dropped: it waits for a later pass
        guard case .value(let stored) = ShareFiles.storedTakes(folder(id)) else { return true }
        guard let list = stored else {
            endTakes(id, nil)
            return true
        }
        // the contributor the recording was shared under (the session JSON's)
        guard let contributor = sessionField(id, "contributor") ?? Contributor.id(storage: storage) else { return false }
        rec.takesAttempts = (rec.takesAttempts ?? 0) + 1
        save(rec)
        // stopped (sharing went off, a delete is asking the server): the pass leaves, and nothing is written
        guard let sent = await transmit(id, "takes", client.takesRequest(id: id, takes: list, contributor: contributor, token: token)) else {
            return false
        }
        let resp: HTTPClient.Response
        switch sent {
        case .success(let r): resp = r
        case .failure:
            retryTakes(id)
            return false
        }
        guard records[id]?.takes == .pending else { return true }
        switch resp.status {
        case 200..<300:
            endTakes(id, .sent)
        case 401:
            await tokens?.invalidate()
            retryTakes(id, immediately: (records[id]?.takesAttempts ?? 0) < 3)
        case 408, 425, 429, 500...:
            retryTakes(id)
        case 400:
            if records[id]?.takesIssueReported != true {
                QuranLab.report(.serverRejected(status: 400, code: "bad_request", message: ""), backend: nil, revision: nil,
                                kind: "other", code: "bad_request:uploads_takes")
                takesIssues += 1
                if var r = records[id] {
                    r.takesIssueReported = true
                    save(r)
                }
            }
            retryTakes(id)
        case 404:
            if takesRouteNotes == 0 {
                SDKLatest.debugOnly("the server answered 404 to POST /v1/uploads/{id}/takes: the take boundaries of a recording "
                                    + "are not sent (the recording is uploaded)")
            }
            takesRouteNotes += 1
            endTakes(id, .dropped)
        default:
            let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            // sharing switched off for the app: the list waits, as segments do; 410 (the upload was deleted) and any
            // other refusal drop it
            if o?["error"] as? String == "contributions_disabled" { retryTakes(id) } else { endTakes(id, .dropped) }
        }
        return true
    }

    /// The take list call is over: sent, dropped, or (nil) there was none to send.
    private func endTakes(_ id: String, _ state: Record.Takes?) {
        guard var rec = records[id] else { return }
        rec.takes = state
        rec.takesNextAttempt = nil
        save(rec)
    }

    /// The take list waits for a later pass, with the outbox's backoff (30 s doubling to 6 h, with jitter).
    private func retryTakes(_ id: String, immediately: Bool = false) {
        guard var rec = records[id] else { return }
        let n = max(1, rec.takesAttempts ?? 0)
        let delay = immediately ? 0 : min(30 * pow(2, Double(min(n - 1, 16))), 6 * 3600) * Double.random(in: 0.8...1.2)
        rec.takesNextAttempt = clock().addingTimeInterval(delay)
        save(rec)
    }

    /// A take list that could not be sent for 7 days is dropped (its recording stays uploaded).
    private func expireTakes() {
        let oldest = Day.string(clock().addingTimeInterval(-7 * 86_400))
        for r in records.values where r.state == .uploaded && r.takes == .pending {
            if let day = sessionField(r.id, "day"), day < oldest { endTakes(r.id, .dropped) }
        }
    }

    /// A string field of an item's session JSON.
    private func sessionField(_ id: String, _ key: String) -> String? {
        // unreadable is taken as not there here: the callers have what to do without the field
        (try? StorageSeam.data(folder(id).appendingPathComponent(ShareFiles.session)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[key] as? String
    }

    /// A Worker call that answers with URLs; nil when it did not (the item is retried or failed).
    private func call(_ id: String, _ request: URLRequest) async -> [ContributionClient.SegmentURL]? {
        guard let r = await send(id, request) else { return nil }
        if let u = ContributionClient.urls(r, id: id) { return u }
        retry(id, "no upload URLs in the answer")
        return nil
    }

    /// URLs for segments `from` to `from + 19`, merged into the item. False when the call failed.
    private func fetchURLs(_ id: String, from: Int, token: String) async -> Bool {
        // the id cannot be read now: the pass leaves, as when it is offline, and nothing counts against the item
        guard let contributor = Contributor.id(storage: storage) else {
            offline.insert(id)
            return false
        }
        guard let urls = await call(id, client.urlsRequest(id: id, from: from, contributor: contributor, token: token)) else {
            // a failed call counts toward the backoff; the batches of a long session do not. A call a stop ended is
            // not a failed one.
            if may(id), var r = records[id] { r.attempts += 1; save(r) }
            return false
        }
        guard var rec = records[id] else { return false }
        rec.urls = merge(rec.urls, urls)
        save(rec)
        return true
    }

    /// New URLs replace those for the same segments; URLs of uploaded segments go.
    private func merge(_ old: [ContributionClient.SegmentURL]?, _ new: [ContributionClient.SegmentURL]) -> [ContributionClient.SegmentURL] {
        var by = Dictionary((old ?? []).map { ($0.n, $0) }, uniquingKeysWith: { $1 })
        for u in new { by[u.n] = u }
        return by.values.sorted { $0.n < $1.n }
    }

    /// A Worker call: the response on 2xx; otherwise the item is retried or failed and nil comes back.
    private func send(_ id: String, _ request: URLRequest) async -> HTTPClient.Response? {
        guard let sent = await transmit(id, "call", request) else {
            // stopped: the pass leaves (as when offline), and nothing is written for the item
            offline.insert(id)
            return nil
        }
        let resp: HTTPClient.Response
        switch sent {
        case .success(let r): resp = r
        case .failure(let error):
            ladder.uploadFailed()
            retry(id, "\(error)")
            offline.insert(id)
            return nil
        }
        if (200..<300).contains(resp.status) { return resp }
        if resp.status >= 500 || resp.status == 408 { ladder.uploadFailed() }
        let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
        let code = o?["error"] as? String ?? "http_\(resp.status)"
        let message = o?["message"] as? String ?? ""
        if resp.status == 401 {
            await tokens?.invalidate()
            retry(id, "HTTP 401 \(code)", immediately: (records[id]?.attempts ?? 0) < 3)
        } else if resp.status >= 500 || [408, 425, 429].contains(resp.status) || code == "contributions_disabled" {
            retry(id, "HTTP \(resp.status) \(code)")
        } else {
            fail(id, code: code, message: message)
        }
        return nil
    }

    private func isOffline(_ id: String) -> Bool { offline.remove(id) != nil }

    /// A PUT's outcome. Returns false when the pass should stop (offline).
    @discardableResult
    func put(_ id: String, _ name: String, _ result: Result<HTTPClient.Response, CloudError>) -> Bool {
        inFlight.remove("\(id)/\(name)")
        // an upload a stop cancelled is not one that failed: it goes again when the queue goes on
        if aborted.remove("\(id)/\(name)") != nil, case .failure = result { return false }
        guard !gone.contains(id), var rec = records[id], rec.state == .active else { return true }
        switch result {
        case .failure(let e):
            ladder.uploadFailed()
            retry(id, "PUT \(name): \(e)")
            return false
        case .success(let resp) where (200..<300).contains(resp.status):
            rec.uploaded.insert(name)
            rec.urls?.removeAll { ShareFiles.name($0.n) + ".opus" == name }
            rec.lastError = nil
            // an upload went through: later segments need not wait for an earlier failure's backoff
            rec.nextAttempt = nil
            save(rec)
            try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(name))
            ladder.uploadOk(backlogSeconds: ShareFiles.backlogSeconds(root: root))
            return true
        case .success(let resp):
            if resp.status >= 500 || resp.status == 408 { ladder.uploadFailed() }
            // 403: the URL expired (R2: "Request has expired") or its signature is no longer valid
            // (the Worker's R2 key was rotated): fresh URLs from the same segment, and again
            rec.attempts += 1
            if resp.status == 403 { rec.urls?.removeAll { ShareFiles.name($0.n) + ".opus" == name } }
            save(rec)
            retry(id, "PUT \(name): HTTP \(resp.status)", immediately: resp.status == 403 && rec.attempts < 5)
            return true
        }
    }

    /// A segment's upload on the background session ended on another host than its signed URL's (SPEC 15.4, the
    /// second exception): there the system follows a redirect without asking the SDK, so the PUT, with the
    /// segment's bytes and neither key nor token, has by then gone to that host. The segment counts as NOT
    /// uploaded, whatever that host answered: it is not marked sent, its file stays, its URL is dropped so that
    /// the next attempt asks the API for a fresh one, and the attempt comes by the queue's ordinary rule for an
    /// upload that failed. The host, and nothing else of the address, is reported.
    func redirected(_ id: String, _ name: String, to host: String) {
        inFlight.remove("\(id)/\(name)")
        onRedirect(host)
        // an upload a stop cancelled goes again when the queue goes on, as in `put`
        if aborted.remove("\(id)/\(name)") != nil { return }
        guard !gone.contains(id), var rec = records[id], rec.state == .active else { return }
        rec.attempts += 1
        rec.urls?.removeAll { ShareFiles.name($0.n) + ".opus" == name }
        save(rec)
        retry(id, "PUT \(name): redirected to \(host)")
    }

    /// After a relaunch: PUTs no longer running are sent again.
    private func reconcile() async {
        guard case .background(let bg) = transport else { return }
        let running = await bg.running()
        inFlight = inFlight.intersection(running)
    }

    private func retry(_ id: String, _ why: String, immediately: Bool = false) {
        guard var rec = records[id] else { return }
        rec.lastError = why
        let n = max(1, rec.attempts)
        let delay = immediately ? 0 : min(30 * pow(2, Double(min(n - 1, 16))), 6 * 3600) * Double.random(in: 0.8...1.2)
        rec.nextAttempt = clock().addingTimeInterval(delay)
        save(rec)
    }

    private func fail(_ id: String, code: String, message: String) {
        guard var rec = records[id] else { return }
        rec.state = .failed
        rec.failCode = code
        rec.failMessage = message
        rec.nextAttempt = nil
        rec.urls = nil
        save(rec)
        // the server revoked this contributor (a deletion) or holds another key for it: the next share starts a new
        // contributor, device key and recovery code
        if code == "contributor_revoked" || code == "contributor_key_mismatch" { Contributor.reset(storage: storage) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder(id).path)) ?? [] where name != Self.itemName {
            try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(name))
        }
    }

    private func note(_ id: String, _ why: String) {
        // an uploaded item whose take list waits keeps its status as it is
        guard var rec = records[id], rec.state == .active, rec.lastError != why else { return }
        rec.lastError = why
        save(rec)
    }

    /// Wakes the outbox when the earliest retry is due (while the app runs; otherwise at launch).
    private func scheduleWake() {
        wake?.cancel()
        wake = nil
        guard let next = records.values.filter({ $0.waiting }).compactMap({ $0.due }).min() else { return }
        let delay = max(1, next.timeIntervalSince(clock()))
        wake = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func unwatch(_ key: UUID) { watchers[key] = nil }

    // MARK: disk

    private func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// Picks up folders the captures made, and recovers the ones a killed app left. A recording made under an
    /// earlier consent is not picked up: it leaves the queue and the disk first (rule R5), and the take list of a
    /// sent recording of an earlier consent is dropped.
    ///
    /// 3.1.4: while the learner's stored answer cannot be read, nothing is picked up, deleted or dropped at this
    /// look. A recording whose item file or stamp cannot be read is left alone (`held`), and so is one a killed
    /// app left whose files cannot be read: nothing of it is deleted or written over.
    private func scan() {
        // a queue that was shut down deletes nothing and drops nothing: the live Client's queue does that
        guard !isClosed else { return }
        guard let look = Self.earlier(root: root, storage: storage) else { return }
        held = look.held
        for name in look.gone {
            gone.insert(name)
            records[name] = nil
            try? FileManager.default.removeItem(at: folder(name))
        }
        defer {
            if let now = Self.consentOnDevice(storage) {
                for r in records.values where r.state == .uploaded && r.takes == .pending {
                    // the list of a recording whose stamp cannot be read stays as it is at this look
                    guard let current = ShareFiles.stamped(ShareFiles.stamp(folder(r.id)), with: now.count) else { continue }
                    guard !now.on || !current else { continue }
                    endTakes(r.id, .dropped)
                    try? FileManager.default.removeItem(at: folder(r.id).appendingPathComponent(ShareFiles.takesFile))
                }
            }
        }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 32 && $0.allSatisfy(\.isHexDigit) }
        for name in names where records[name] == nil && !gone.contains(name) && !held.contains(name) {
            let f = folder(name)
            switch Self.item(f) {
            case .value(let rec) where rec.id == name:
                records[name] = rec
                continue
            case .unreadable:
                // it became unreadable since the look above: left alone
                held.insert(name)
                continue
            case .value, .missing:
                break
            }
            let capturing = ShareCapture.active.withLock { $0.contains(name) }
            // an item appears with its first closed segment
            if capturing, ShareFiles.markers(f).isEmpty { continue }
            if !capturing, !fm.fileExists(atPath: f.appendingPathComponent(ShareFiles.end).path) {
                switch ShareFiles.recovery(f) {
                case .recovered: break
                case .nothing: continue
                case .unreadable:
                    held.insert(name)
                    continue
                }
            }
            var rec = Record(id: name)
            rec.seq = (records.values.map(\.seq).max() ?? 0) + 1
            save(rec)
        }
        // a session whose capture is gone without an end (the app was killed, in an earlier run)
        for rec in records.values where rec.state == .active && !held.contains(rec.id) {
            let f = folder(rec.id)
            if !ShareCapture.active.withLock({ $0.contains(rec.id) }), !fm.fileExists(atPath: f.appendingPathComponent(ShareFiles.end).path) {
                switch ShareFiles.recovery(f) {
                case .recovered: break
                case .nothing: records[rec.id] = nil
                case .unreadable: held.insert(rec.id)
                }
            }
        }
    }

    /// When the queue opens (a launch; the queue takes the background session's results): every upload task the
    /// system still holds for a recording that is not in the queue as one to send is cancelled (3.1.4). Such a
    /// recording is gone (sharing was turned off, it was deleted, it failed), or it may not be sent now: it was
    /// made under an earlier consent, or the learner's answer or one of its own files cannot be read. A task that
    /// is cancelled for a recording that is still to send is sent again by a later pass.
    /// Until 3.1.3 only the process that turned sharing off cancelled its tasks; one that the system still held
    /// when the next process started went on.
    func cancelOrphans() async {
        guard case .background(let bg) = transport else { return }
        scan()
        let live = Set(records.values.filter { $0.state == .active && !held.contains($0.id) }.map(\.id))
        for key in await bg.running() {
            let id = String(key.prefix { $0 != "/" })
            if !live.contains(id) { bg.cancel(prefix: id + "/") }
        }
    }

    private func remove(_ id: String) {
        gone.insert(id)
        records[id] = nil
        try? FileManager.default.removeItem(at: folder(id))
    }

    private func snapshot(_ r: Record) -> Contribution {
        let f = folder(r.id)
        let markers = ShareFiles.markers(f)
        let end = ShareFiles.read(ShareFiles.End.self, f.appendingPathComponent(ShareFiles.end))
        let status: Contribution.Status
        switch r.state {
        case .active: status = .queued
        case .uploaded: status = .uploaded
        case .failed: status = .failed(code: r.failCode ?? "other", message: r.failMessage ?? "")
        }
        // unreadable is taken as not there here: this is the day a recording's status shows
        let day = (try? StorageSeam.data(f.appendingPathComponent(ShareFiles.session)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["day"] as? String ?? ""
        return Contribution(id: r.id, segments: markers.count, bytes: markers.reduce(0) { $0 + $1.bytes },
                            durationMs: end?.durationMs ?? 0, day: day, completed: end?.completed, status: status,
                            attempts: r.attempts, lastError: r.lastError,
                            segmentBitrates: markers.map { (m: ShareFiles.Marker) -> Int in m.bitrate ?? OpusSettings.shared.bitrate },
                            takes: ShareFiles.takes(f)?.count ?? 1)
    }

    private func save(_ rec: Record) {
        // a recording sharing-off took out stays out: nothing is written for it again
        if gone.contains(rec.id) { return }
        records[rec.id] = rec
        if let d = try? JSONEncoder().encode(rec) {
            try? d.write(to: folder(rec.id).appendingPathComponent(Self.itemName), options: StorageProtection.atomic)
        }
        let c = snapshot(rec)
        for w in watchers.values { w.yield(c) }
    }
}

/// Uploads from file on a background URLSession, so a PUT continues while the app is suspended
/// and its result reaches the outbox when the app runs again. One per identifier per process (a
/// background session identifier may be used only once). Its mutable state is behind a lock;
/// results go to the outbox actor.
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let all = Locked<[String: BackgroundUploader]>([:])

    static func shared(identifier: String) -> BackgroundUploader {
        all.withLock { m in
            if let u = m[identifier] { return u }
            let u = BackgroundUploader(identifier: identifier)
            m[identifier] = u
            // the system's completion handler came before the Client was made: it was waiting for this session
            if let waited = BackgroundEvents.take(identifier) { u.setFinishedHandler(waited) }
            return u
        }
    }

    static func existing(_ identifier: String) -> BackgroundUploader? { all.withLock { $0[identifier] } }

    static func identifier(for app: AppIdentity) -> String { "ai.quranlab.contributions." + app.bundleID }

    let identifier: String
    /// Where a finished upload goes: the outbox (`attach(_ outbox:)`), or a test's own.
    struct Sink: Sendable {
        /// The upload "<id>/<name>" ended with this answer, or without one.
        let put: @Sendable (_ id: String, _ name: String, _ result: Result<HTTPClient.Response, CloudError>) async -> Void
        /// The upload ended on another host than the one it was made to.
        let redirected: @Sendable (_ id: String, _ name: String, _ host: String) async -> Void
    }

    private struct State {
        var bodies: [Int: Data] = [:]
        /// The redirects the system followed for a task, as its metrics say (by task identifier).
        var redirects: [Int: Int] = [:]
        var sink: Sink?
        var finished: (@Sendable () -> Void)?
    }
    private let state = Locked(State())
    private var session: URLSession!

    private init(identifier: String) {
        self.identifier = identifier
        super.init()
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    /// `key` is "<id>/<file name>".
    func start(_ request: URLRequest, file: URL, key: String) {
        let t = session.uploadTask(with: request, fromFile: file)
        t.taskDescription = key
        t.resume()
    }

    /// Cancels the uploads whose key starts with `prefix` ("" for all of them): a stop of the queue.
    func cancel(prefix: String) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription?.hasPrefix(prefix) == true { t.cancel() }
        }
    }

    func running() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    /// The app delegate's completion handler for `handleEventsForBackgroundURLSession`.
    func setFinishedHandler(_ h: @escaping @Sendable () -> Void) { state.withLock { $0.finished = h } }

    func attach(_ outbox: ContributionOutbox) {
        attach(Sink(put: { id, name, result in
            await outbox.put(id, name, result)
            await outbox.drain()
        }, redirected: { id, name, host in
            await outbox.redirected(id, name, to: host)
            await outbox.drain()
        }))
    }

    func attach(_ sink: Sink) { state.withLock { $0.sink = sink } }

    /// The host a finished task ended on, when the system redirected it; nil when it did not. A background
    /// session follows a redirect without asking its delegate, so this is read after the fact: the task was
    /// redirected when the system's metrics count a redirect, or when the answer's URL has another scheme, host
    /// (compared without case) or port than the URL the task was made to. What is returned is the host only, in
    /// lower case (`unknown` when the answer has no URL).
    static func redirectedHost(asked: URL?, final: URL?, redirects: Int = 0) -> String? {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "http" ? 80 : 443) }
        var moved = redirects > 0
        if let asked, let final {
            moved = moved || asked.scheme?.lowercased() != final.scheme?.lowercased() || asked.host?.lowercased() != final.host?.lowercased()
                || port(asked) != port(final)
        }
        guard moved else { return nil }
        return final?.host?.lowercased() ?? "unknown"
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard metrics.redirectCount > 0 else { return }
        state.withLock { $0.redirects[task.taskIdentifier] = metrics.redirectCount }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (body, redirects, sink) = state.withLock { s in
            (s.bodies.removeValue(forKey: task.taskIdentifier) ?? Data(), s.redirects.removeValue(forKey: task.taskIdentifier) ?? 0, s.sink)
        }
        guard let key = task.taskDescription, let slash = key.firstIndex(of: "/"), let sink else { return }
        let id = String(key[..<slash]), name = String(key[key.index(after: slash)...])
        // the system followed a redirect: the segment is not uploaded, whatever the other host answered (SPEC 15.4)
        if let host = Self.redirectedHost(asked: task.originalRequest?.url, final: task.response?.url, redirects: redirects) {
            Task.detached(priority: .utility) { await sink.redirected(id, name, host) }
            return
        }
        let result: Result<HTTPClient.Response, CloudError>
        if let http = task.response as? HTTPURLResponse, error == nil {
            result = .success(.init(status: http.statusCode, headers: [:], body: body))
        } else {
            result = .failure(.offline(error?.localizedDescription ?? "no response"))
        }
        Task.detached(priority: .utility) { await sink.put(id, name, result) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let h = state.withLock { s -> (@Sendable () -> Void)? in
            defer { s.finished = nil }
            return s.finished
        }
        if let h { DispatchQueue.main.async { h() } }
    }
}
