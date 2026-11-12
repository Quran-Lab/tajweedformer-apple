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
    /// PUTs running now ("<id>/<file>").
    private var inFlight: Set<String> = []
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

    init(storage: URL, http: HTTPClient, apiURL: URL, tokens: TokenProvider?, config: ConfigStore, options: CloudOptions,
         app: AppIdentity, clock: @escaping @Sendable () -> Date, ladder: BitrateLadder = BitrateLadder()) {
        self.storage = storage
        self.ladder = ladder
        root = storage.appendingPathComponent("outbox")
        self.http = http
        client = ContributionClient(http: http, apiURL: apiURL)
        self.tokens = tokens
        self.config = config
        self.clock = clock
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// Sharing was turned off: every session not yet fully uploaded goes (the server marks a
    /// started one abandoned after 48 hours without activity).
    func cancelQueued() {
        scan()
        for r in records.values where r.state == .active && !ShareCapture.active.withLock({ $0.contains(r.id) }) { remove(r.id) }
        // a take list still to send goes too (its recording stays uploaded)
        for r in records.values where r.takes == .pending { endTakes(r.id, .dropped) }
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
    nonisolated func shutdown() { closedFlag.withLock { $0 = true } }

    nonisolated var isClosed: Bool { closedFlag.withLock { $0 } }

    private nonisolated let closedFlag = Locked(false)

    func drain(ignoringBackoff: Bool = false) async {
        if isClosed { return }
        if running != nil {
            again = true
            // the pass that runs for this request honours it, whichever caller starts that pass
            againIgnoringBackoff = againIgnoringBackoff || ignoringBackoff
            while let t = running { await t.value }
            if !again { return }
        }
        let ignore = ignoringBackoff || againIgnoringBackoff
        again = false
        againIgnoringBackoff = false
        let t = Task {
            await self.reconcile()
            await self.pass(ignoringBackoff: ignore)
            self.scheduleWake()
            self.running = nil
        }
        running = t
        await t.value
        if again { await drain() }
    }

    private func pass(ignoringBackoff: Bool) async {
        scan()
        expireTakes()
        guard let tokens, Contributions.isActive else { return }
        let now = clock()
        let due = records.values.filter { $0.waiting && (ignoringBackoff || ($0.due ?? .distantPast) <= now) }
            .sorted { $0.seq < $1.seq }.map(\.id)
        guard !due.isEmpty else { return }
        if config.current?.flags.contributions != true {
            for id in due { note(id, "sharing is turned off for this app; waiting") }
            return
        }
        for id in due {
            if Task.isCancelled { return }
            // an uploaded recording whose take list waits: a token that cannot be had never changes its status
            let listOnly = records[id]?.state == .uploaded
            let token: APIToken
            do throws(CloudError) {
                token = try await tokens.token()
            } catch {
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
        let markers = ShareFiles.markers(folder)
        let end = ShareFiles.read(ShareFiles.End.self, folder.appendingPathComponent(ShareFiles.end))
        guard var rec = records[id] else { return true }
        // uploaded, its take list still to send
        if rec.state != .active { return await sendTakes(id, token: token) }
        // the server hears of a session only once it has a segment (a short failed session never
        // reaches it)
        if !rec.started {
            guard !markers.isEmpty, let session = try? Data(contentsOf: folder.appendingPathComponent(ShareFiles.session)) else { return true }
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
                let result: Result<HTTPClient.Response, CloudError>
                do throws(CloudError) { result = .success(try await http.send(r)) } catch { result = .failure(error) }
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
        if ShareFiles.takes(folder) != nil { rec.takes = .pending }
        save(rec)
        // the item, the markers, the end, the session JSON and the take list stay (they give the status its numbers)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name != Self.itemName && name != ShareFiles.end && name != ShareFiles.session && name != ShareFiles.takesFile
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
        guard let list = ShareFiles.takes(folder(id)) else {
            endTakes(id, nil)
            return true
        }
        // the contributor the recording was shared under (the session JSON's)
        let contributor = sessionField(id, "contributor") ?? Contributor.id(storage: storage)
        rec.takesAttempts = (rec.takesAttempts ?? 0) + 1
        save(rec)
        let resp: HTTPClient.Response
        do throws(CloudError) {
            resp = try await http.send(client.takesRequest(id: id, takes: list, contributor: contributor, token: token))
        } catch {
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
        (try? Data(contentsOf: folder(id).appendingPathComponent(ShareFiles.session)))
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
        let contributor = Contributor.id(storage: storage)
        guard let urls = await call(id, client.urlsRequest(id: id, from: from, contributor: contributor, token: token)) else {
            // a failed call counts toward the backoff; the batches of a long session do not
            if var r = records[id] { r.attempts += 1; save(r) }
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
        let resp: HTTPClient.Response
        do throws(CloudError) {
            resp = try await http.send(request)
        } catch {
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
        guard var rec = records[id], rec.state == .active else { return true }
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

    /// Picks up folders the captures made, and recovers the ones a killed app left.
    private func scan() {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 32 && $0.allSatisfy(\.isHexDigit) }
        for name in names where records[name] == nil {
            let f = folder(name)
            if let d = try? Data(contentsOf: f.appendingPathComponent(Self.itemName)),
               let rec = try? JSONDecoder().decode(Record.self, from: d), rec.id == name {
                records[name] = rec
                continue
            }
            let capturing = ShareCapture.active.withLock { $0.contains(name) }
            // an item appears with its first closed segment
            if capturing, ShareFiles.markers(f).isEmpty { continue }
            if !capturing, !fm.fileExists(atPath: f.appendingPathComponent(ShareFiles.end).path), !ShareFiles.recover(f) { continue }
            var rec = Record(id: name)
            rec.seq = (records.values.map(\.seq).max() ?? 0) + 1
            save(rec)
        }
        // a session whose capture is gone without an end (the app was killed, in an earlier run)
        for rec in records.values where rec.state == .active {
            let f = folder(rec.id)
            if !ShareCapture.active.withLock({ $0.contains(rec.id) }), !fm.fileExists(atPath: f.appendingPathComponent(ShareFiles.end).path) {
                if !ShareFiles.recover(f) { records[rec.id] = nil }
            }
        }
    }

    private func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        records[id] = nil
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
        let day = (try? Data(contentsOf: f.appendingPathComponent(ShareFiles.session)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["day"] as? String ?? ""
        return Contribution(id: r.id, segments: markers.count, bytes: markers.reduce(0) { $0 + $1.bytes },
                            durationMs: end?.durationMs ?? 0, day: day, completed: end?.completed, status: status,
                            attempts: r.attempts, lastError: r.lastError,
                            segmentBitrates: markers.map { (m: ShareFiles.Marker) -> Int in m.bitrate ?? OpusSettings.shared.bitrate },
                            takes: ShareFiles.takes(f)?.count ?? 1)
    }

    private func save(_ rec: Record) {
        records[rec.id] = rec
        if let d = try? JSONEncoder().encode(rec) {
            try? d.write(to: folder(rec.id).appendingPathComponent(Self.itemName), options: .atomic)
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
            return u
        }
    }

    static func existing(_ identifier: String) -> BackgroundUploader? { all.withLock { $0[identifier] } }

    static func identifier(for app: AppIdentity) -> String { "ai.quranlab.contributions." + app.bundleID }

    let identifier: String
    private struct State {
        var bodies: [Int: Data] = [:]
        var outbox: ContributionOutbox?
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

    func running() async -> Set<String> {
        Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    /// The app delegate's completion handler for `handleEventsForBackgroundURLSession`.
    func setFinishedHandler(_ h: @escaping @Sendable () -> Void) { state.withLock { $0.finished = h } }

    func attach(_ outbox: ContributionOutbox) { state.withLock { $0.outbox = outbox } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (body, outbox) = state.withLock { s in (s.bodies.removeValue(forKey: task.taskIdentifier) ?? Data(), s.outbox) }
        guard let key = task.taskDescription, let slash = key.firstIndex(of: "/"), let outbox else { return }
        let id = String(key[..<slash]), name = String(key[key.index(after: slash)...])
        let result: Result<HTTPClient.Response, CloudError>
        if let http = task.response as? HTTPURLResponse, error == nil {
            result = .success(.init(status: http.statusCode, headers: [:], body: body))
        } else {
            result = .failure(.offline(error?.localizedDescription ?? "no response"))
        }
        Task.detached(priority: .utility) {
            await outbox.put(id, name, result)
            await outbox.drain()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let h = state.withLock { s -> (@Sendable () -> Void)? in
            defer { s.finished = nil }
            return s.finished
        }
        if let h { DispatchQueue.main.async { h() } }
    }
}
