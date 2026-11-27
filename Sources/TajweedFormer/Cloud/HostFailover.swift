import Foundation

/// How one host's answer is read (28.3 item 3, 18.4.7.1's table, the same for every route).
enum AnswerClass: String, Sendable {
    /// A 2xx that is the answer the route asks for, or a 304 to a config request with `If-None-Match`.
    case taken
    /// A status from 400 to 499 other than 429 with a JSON body whose `error` is a string: the request's answer,
    /// from whichever host; no other host is asked for it.
    case refused
    /// A 429, whatever its body: no other host is asked, its `Retry-After` is honoured on the same host.
    case slowDown = "slow_down"
    /// Everything else: no answer, a stall, a 5xx, a redirect, a 4xx that is not the API's, a 2xx that is not what was
    /// asked. The next host of the order is asked at once.
    case unreachable
}

extension Endpoints {
    /// The class of an answer with `status` and `body`; `taken` says whether a 2xx (or 304) is what the route asked.
    static func answerClass(status: Int, body: Data, taken: Bool) -> AnswerClass {
        if status == 429 { return .slowDown }
        if (200..<300).contains(status) || status == 304 { return taken ? .taken : .unreachable }
        guard (400..<500).contains(status) else { return .unreachable }
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return o?["error"] is String ? .refused : .unreachable
    }

    /// What most routes ask for: a 2xx (never a 304) whose body is empty or JSON. A captive portal's or an edge's page
    /// with status 200 is not it.
    @Sendable static func jsonAnswer(_ r: HTTPClient.Response) -> Bool {
        guard (200..<300).contains(r.status) else { return false }
        if r.body.isEmpty || (try? JSONSerialization.jsonObject(with: r.body, options: [.fragmentsAllowed])) != nil { return true }
        // SDK 4.0.5 (ATTEST_40.md 40.5): the check it failed, for the request's hop
        AnswerCheck.failed(AnswerCheck.notJSON)
        return false
    }

    /// SDK 4.0.5 (ATTEST_40.md 40.6): the hop of one host's answer that was not taken, nil for a route that reports none.
    /// `check`: the check a 2xx failed (40.5).
    static func hop(_ role: EndpointRole, path: String, host: URL, _ result: Result<HTTPClient.Response, CloudError>,
                    check: String?) -> CauseHop? {
        guard let stage = stage(role, path: path) else { return nil }
        let c: ErrorCause
        switch result {
        case .success(let r):
            if (200..<300).contains(r.status) || r.status == 304 {
                c = ErrorCause(stage: stage, reason: "invalid_answer", httpStatus: r.status, errorCode: check)
            } else {
                var f = ErrorCause.of(HTTPClient.failure(status: r.status, body: r.body), stage: stage)
                // a 5xx's own `error` (`lease_unavailable`, `service_unavailable`), which its cause does not carry
                if f.errorCode == nil, let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] { f.errorCode = o["error"] as? String }
                c = f
            }
        case .failure(let e):
            c = ErrorCause.of(e, stage: stage)
        }
        return CauseHop.made(stage: c.stage, reason: c.reason, hostRole: role.rawValue, hostName: Endpoints.askedName(host), httpStatus: c.httpStatus,
                             errorName: c.errorName, errorCode: c.errorCode)
    }

    /// The 24.3 reason and status of an answer that was unreachable (28.7 `lastFailover`, the `failover` report's
    /// `error_code`): `network` for none, `timeout` for one that stalled, `redirect`, `invalid_answer` for a 2xx that
    /// is not what was asked, `http` for the rest.
    static func unreachableReason(_ result: Result<HTTPClient.Response, CloudError>) -> (reason: String, status: Int?) {
        switch result {
        case .success(let r):
            if (200..<300).contains(r.status) || r.status == 304 { return ("invalid_answer", r.status) }
            if HTTPClient.redirects.contains(r.status) { return ("redirect", r.status) }
            return ("http", r.status)
        case .failure(let e):
            let c = ErrorCause.of(e, stage: "config")
            switch c.reason {
            case "network", "timeout", "redirect", "http", "invalid_answer": return (c.reason, c.httpStatus)
            default: return ("invalid_answer", c.httpStatus)
            }
        }
    }

    /// The 24.3 stage of a request of `role` at `path`, for its `failover` report: nil for a route that reports none
    /// (the error reports themselves, `sdk/latest`). A challenge asked inside a lease attempt is the lease's.
    static func stage(_ role: EndpointRole, path: String) -> String? {
        if role == .models { return path.hasSuffix("/" + ModelManifest.fileName) ? "manifest" : "download" }
        if path.hasSuffix("/v1/config") { return "config" }
        if path.hasSuffix("/v1/register") { return "register" }
        if path.hasSuffix("/v1/model-key") { return "lease" }
        if path.contains("/v1/attest") { return LeaseAttemptTrace.current != nil ? "lease" : "attest" }
        if path.hasSuffix("/v1/events") { return "events" }
        if path.contains("/v1/uploads") || path.contains("/v1/contributions") { return "sharing" }
        return nil
    }
}

/// A value handed from a child task to its parent that the compiler cannot see is safe to hand (the bytes of an
/// answer, read by the parent alone once the child has ended).
final class Handed<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension HTTPClient {
    /// 28.3 item 6: a host's time without a byte before the answer's status. Tests shorten it.
    static let silenceLimit = Locked<TimeInterval>(Endpoints.silenceLimit)
    /// What a request cut by that limit is: no answer (24.3 `network`), the limit named.
    static let silentHost = "the host sent no byte before an answer within"

    /// SDK 4.0.5 (37.3): what one API request did, for its count: the status it got (before its body was read), its
    /// delegate (the task's metrics), and when it was sent and ended on the SDK's own clock.
    final class ApiProbe: @unchecked Sendable {
        let status = Locked<Int?>(nil)
        let watch = Locked<NoRedirect?>(nil)
        let sent = Date()
        let ended = Locked<Date?>(nil)
    }

    /// SDK 4.0.5 (section 37): told every API request that ended (`.apiCall`) and every move of a request to the next
    /// host (`.apiMove`). Shared by every copy of this client.
    var apiCalls: Locked<(@Sendable (AnalyticsEvent) -> Void)?> { apiSink }

    /// The answer's status and headers, and its body as it comes. With `limit`, a request whose answer has not begun
    /// after `limit` seconds without a byte moving (its body going out counts) is ended: no answer.
    func head(_ request: URLRequest, watch: NoRedirect, limit: TimeInterval?) async throws(CloudError)
        -> (bytes: URLSession.AsyncBytes, response: URLResponse) {
        let session = self.session
        let attempt = Task { () async throws -> Handed<(URLSession.AsyncBytes, URLResponse)> in
            Handed(try await session.bytes(for: request, delegate: watch))
        }
        let silent = Locked(false)
        var watchdog: Task<Void, Never>?
        if let limit {
            watch.progressed.withLock { $0 = Date() }
            watchdog = Task {
                while !Task.isCancelled {
                    let left = limit - Date().timeIntervalSince(watch.progressed.withLock { $0 })
                    if left <= 0 {
                        silent.withLock { $0 = true }
                        attempt.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(min(left, 0.25) * 1_000_000_000))
                }
            }
        }
        defer { watchdog?.cancel() }
        do {
            let got = try await withTaskCancellationHandler { try await attempt.value } onCancel: { attempt.cancel() }
            return (got.value.0, got.value.1)
        } catch {
            if silent.withLock({ $0 }) {
                throw .offline("\(Self.silentHost) \(Int((limit ?? 0).rounded())) s [\(NSURLErrorDomain) \(NSURLErrorTimedOut)]")
            }
            // no answer: the system's words, and its error's domain and code for the error report
            throw .offline(ErrorCause.noAnswer(error))
        }
    }

    /// One request through its role's hosts (28.3), or to the host it names when it is no role's: `role` names the role
    /// (a model request, whose host may be an allowed one that is not the role's: asked first, 28.4), else the role is
    /// the one whose host the request names. `P` first, then the others in list order; each host gets the same
    /// method, path, query, headers and body. The first answer that is taken, a refusal or a slow down is the answer,
    /// and its host becomes `P`; an unreachable one sends the request to the next host at once. When every host was
    /// unreachable, the FIRST host's answer (or failure) is the request's, as before 4.0.1, and `P` stays.
    /// SDK 4.0.2 (28.11 item 2, 18.4.7.3 item 4): the answer a request of `url` gets now without asking, when its
    /// route is held by a `Retry-After` (a 429's on the route, or a 503's on every host of its role); nil when it may go.
    /// A call that needs other requests first (a challenge, an App Attest attestation) asks this before them.
    func held(_ url: URL) -> Response? {
        guard let endpoints, let role = endpoints.role(of: url) else { return nil }
        let route = RetryAfterHolds.route(of: url, role: role)
        let now = endpoints.clock()
        var first: (until: Date, wholeRoute: Bool)?
        for host in endpoints.order(role, at: now).hosts {
            guard let h = endpoints.holds.hold(route, host: host, now: now) else { return nil }
            if h.wholeRoute {
                return RetryAfterHolds.heldAnswer(until: h.until, now: now, wholeRoute: true, code: endpoints.holds.lastCode(route))
            }
            first = first ?? h
        }
        guard let first else { return nil }
        return RetryAfterHolds.heldAnswer(until: first.until, now: now, wholeRoute: false, code: endpoints.holds.lastCode(route, status: 503))
    }

    /// Throws what a request of `url` would fail with now when its route is held (`held`).
    func failIfHeld(_ url: URL) throws(CloudError) {
        guard let r = held(url) else { return }
        LeaseAttemptTrace.current?.metHold()
        throw Self.failure(status: r.status, body: r.body)
    }

    func routed(_ request: URLRequest, role named: EndpointRole?, accept: @escaping @Sendable (Response) -> Bool)
        async throws(CloudError) -> Response {
        guard let endpoints, let url = request.url, let origin = Endpoints.origin(of: url),
              let role = named ?? endpoints.role(of: url) else { return try await once(request, limited: false) }
        let start = endpoints.clock()
        let first = named != nil && !endpoints.isRoleHost(role, origin) ? origin : nil
        let (order, probe) = endpoints.order(role, at: start, first: first)
        var firstResult: Result<Response, CloudError>?
        // SDK 4.0.5 (40.5): the check the first host's 2xx failed, for `lastFailover.check`
        var firstCheck: String?
        var asked: [URL] = []
        // 28.11 item 2 (SDK 4.0.2): a route a 429 asked to wait asks no host before its Retry-After; a host a 503 asked
        // to wait is not asked, the next host is
        let route = RetryAfterHolds.route(of: url, role: role)
        var held: (until: Date, wholeRoute: Bool)?
        // 28.7 (SDK 4.0.2, contract 7cdb1ee): a request that skipped its first host for a hold asked no first host, and
        // its next host's answer is no failover report (`lastFailover` is told as before)
        var skippedFirst = false
        // SDK 4.0.5 (34.4): hosts whose request lost its hedge (no answer of theirs was read)
        var hedgedAway: Set<URL> = []
        // SDK 4.0.5 (37.3): the route an API request is counted under, and the host it left with why (a move is counted
        // when the next host is asked)
        let apiRoute = role == .api ? ApiRoute.of(method: request.httpMethod ?? "GET", path: url.path) : nil
        var leaving: (host: String, why: String)?
        // SDK 4.0.5 (34.9.7): the same for a model request of this kind (the manifest)
        var modelLeaving: (host: String, why: String)?
        for (i, host) in order.enumerated() {
            // SDK 4.0.5 (34.4): a host the hedge already asked is not asked again
            if asked.contains(host) { continue }
            if let h = endpoints.holds.hold(route, host: host, now: endpoints.clock()) {
                if h.wholeRoute {
                    LeaseAttemptTrace.current?.metHold()
                    // the request ends on the held 429 (28.3): no failover; `fallback` counts the hosts it asked (24.2)
                    if !asked.isEmpty { RequestTrace.note(role, fallback: asked.count > 1) }
                    return RetryAfterHolds.heldAnswer(until: h.until, now: endpoints.clock(), wholeRoute: true, code: endpoints.holds.lastCode(route))
                }
                if host == order.first { skippedFirst = true }
                held = held ?? h
                continue
            }
            var r = request
            r.url = Endpoints.rehost(url, to: host)
            asked.append(host)
            if let apiRoute, let from = leaving, let to = host.host {
                tellApi(.apiMove(host: from.host, route: apiRoute, to: Endpoints.asciiLower(to), why: from.why))
                leaving = nil
            }
            if role == .models, let from = modelLeaving, let to = host.host {
                modelSink.withLock { $0 }?(.modelMove(host: from.host, to: Endpoints.asciiLower(to), why: from.why))
                modelLeaving = nil
            }
            // SDK 4.0.5 (34.4): a request of the models role (the build's manifest) with no answer 1.5 s after it was sent
            // also goes to the next host of the order that no Retry-After holds; the first answer that is taken, a
            // refusal or a slow down is the request's, and the other is cancelled
            let askedNow = asked
            let next: URL? = role != .models ? nil : order[(i + 1)...].first(where: { (h: URL) -> Bool in
                !askedNow.contains(h) && endpoints.holds.hold(route, host: h, now: endpoints.clock()) == nil
            })
            let tries = await hedged(r, host: host, next: next, url: url, accept: accept, counted: apiRoute)
            for t in tries {
                // the request that lost its hedge: counted as a request of its host, without a status, never unreachable;
                // its host was not found unreachable, so its loss is no failover
                if t.lost {
                    hedgedAway.insert(t.host)
                    // 34.9.7: the first host's request lost to the second's answer: a move for `hedge`
                    if role == .models, t.hedged, let from = t.host.host, let to = tries.first(where: { !$0.lost })?.host.host {
                        modelSink.withLock { $0 }?(.modelMove(host: Endpoints.asciiLower(from), to: Endpoints.asciiLower(to), why: "hedge"))
                    }
                    if role == .models, let to = modelHosts.withLock({ $0 }), let name = t.host.host {
                        to(ModelHostSample(host: name, ttfbMs: nil, bytes: 0, bodySeconds: 0, unreachable: false, lastByte: false,
                                           hedged: t.hedged))
                    }
                    continue
                }
                if t.host != host { asked.append(t.host) }
                // 34.9.7: the hedge asked this host after the first ended unreachable: that is the move
                if role == .models, t.host != host, let from = modelLeaving, let to = t.host.host {
                    modelSink.withLock { $0 }?(.modelMove(host: from.host, to: Endpoints.asciiLower(to), why: from.why))
                    modelLeaving = nil
                }
                let result = t.result
                let isFirst = firstResult == nil
                if firstResult == nil { firstResult = result }
                let cls: AnswerClass
                // SDK 4.0.5 (ATTEST_40.md 40.5): the accept runs once per answer, and names the check it failed
                var verdict: (taken: Bool, check: String?) = (false, nil)
                switch result {
                case .success(let resp):
                    verdict = AnswerCheck.judging { accept(resp) }
                    let taken = verdict.taken
                    if isFirst { firstCheck = verdict.check }
                    cls = Endpoints.answerClass(status: resp.status, body: resp.body, taken: taken)
                    // SDK 4.0.2 (STEERING_40 34.6, contract 0d9f5d7): a model request of this kind (the build's manifest)
                    // counts on its host as a file does: its request, its bytes, one of `files` when it is the answer taken
                    if role == .models, let to = modelHosts.withLock({ $0 }), let name = t.host.host {
                        var s = ModelHostSample(host: name, ttfbMs: Int((t.ended.timeIntervalSince(t.sent) * 1000).rounded()),
                                                bytes: Int64(resp.body.count), bodySeconds: 0, unreachable: cls == .unreachable,
                                                lastByte: taken && (200..<300).contains(resp.status), hedged: t.hedged)
                        // SDK 4.0.5 (34.9.1): a 2xx that is not what was asked (a manifest that does not verify) is
                        // `bad_body`; another status its class; and the version it went by
                        if (200..<300).contains(resp.status) {
                            s.fail = taken ? nil : "bad_body"
                        } else {
                            s.fail = FailClass.of(HTTPClient.failure(status: resp.status, body: resp.body), status: resp.status, cancelled: false)
                        }
                        s.proto = FailClass.proto(resp.networkProtocol)
                        to(s)
                        if cls == .unreachable, let why = s.fail { modelLeaving = (Endpoints.asciiLower(name), why) }
                    }
                    // 28.5: a lease attempt waits the largest Retry-After any host gave when every host was unreachable
                    LeaseAttemptTrace.current?.hostAnswered(retryAfter: resp.header("Retry-After"))
                    endpoints.holds.note(route, host: t.host, status: resp.status, retryAfter: resp.header("Retry-After"), body: resp.body,
                                         now: endpoints.clock())
                case .failure(let e):
                    cls = .unreachable
                    if role == .models, let to = modelHosts.withLock({ $0 }), let name = t.host.host {
                        var s = ModelHostSample(host: name, ttfbMs: nil, bytes: 0, bodySeconds: 0,
                                                unreachable: !Task.isCancelled && Self.unreachable(e), lastByte: false, hedged: t.hedged)
                        s.fail = FailClass.of(e, status: nil, cancelled: Task.isCancelled)
                        to(s)
                        if let why = s.fail { modelLeaving = (Endpoints.asciiLower(name), why) }
                    }
                }
                // SDK 4.0.5 (40.6): every answer that was not taken is a hop of the operation's chain (a caller that gave up
                // made none)
                if cls != .taken, !Task.isCancelled {
                    CauseChain.add(Endpoints.hop(role, path: url.path, host: t.host, result, check: verdict.check))
                }
                if let apiRoute, let name = t.host.host {
                    let s = Self.apiSample(Endpoints.asciiLower(name), apiRoute, t, taken: verdict.taken)
                    tellApi(.apiCall(s))
                    if cls == .unreachable, let why = s.fail { leaving = (Endpoints.asciiLower(name), why) }
                }
                if cls != .unreachable {
                    endpoints.settle(role, t.host, at: start, probe: probe)
                    RequestTrace.note(role, fallback: asked.count > 1)
                    if asked.count > 1, asked[0] != t.host, !hedgedAway.contains(asked[0]), let firstResult {
                        failedOver(endpoints, role, url, asked[0], to: t.host, firstResult, check: firstCheck, report: !skippedFirst)
                    }
                    return try result.get()
                }
                // a caller that gave up asks no other host
                if Task.isCancelled { return try result.get() }
            }
        }
        // every host held: the hold's answer, and no host is asked
        if asked.isEmpty, let held {
            LeaseAttemptTrace.current?.metHold()
            return RetryAfterHolds.heldAnswer(until: held.until, now: endpoints.clock(), wholeRoute: false,
                                              code: endpoints.holds.lastCode(route, status: 503))
        }
        RequestTrace.note(role, fallback: asked.count > 1)
        guard let firstResult else { return try await once(request, limited: true) }
        failedOver(endpoints, role, url, asked[0], to: nil, firstResult, check: firstCheck)
        return try firstResult.get()
    }

    /// One attempt of a request through its role's order (`routed`).
    private struct Attempt: Sendable {
        let host: URL
        let result: Result<Response, CloudError>
        let sent: Date
        let ended: Date
        /// it lost its hedge: cancelled, no answer of its host
        let lost: Bool
        /// it had no answer within the hedge's time, so the same request went to the next host (34.6 `hedged`)
        let hedged: Bool
        /// SDK 4.0.5 (37.3): what the request's count reads (its status, its metrics), for an API request
        var probe: ApiProbe? = nil
    }

    /// Tells the API's count (37.3), when a sink is set.
    private func tellApi(_ e: AnalyticsEvent) { apiSink.withLock { $0 }?(e) }

    /// SDK 4.0.5 (37.3): the count of one API request that ended: its class, its time to the whole answer (the task's
    /// metrics, else the SDK's own clock), its connection and its version.
    /// SDK 4.0.5: `taken` is the verdict `routed` already has; the accept is never run twice on one answer (a second
    /// run handed the lease route's answer to the Core a second time, and a refusal by the second run replaced the
    /// first verdict).
    private static func apiSample(_ host: String, _ route: String, _ t: Attempt, taken: Bool) -> ApiSample {
        let m = t.probe?.watch.withLock { $0 }?.measure.withLock { $0 }
        let ownMs = (t.probe?.ended.withLock { $0 } ?? t.ended).timeIntervalSince(t.sent) * 1000
        switch t.result {
        case .success(let resp):
            var a = ApiClass.Answer(status: resp.status)
            a.taken = taken
            let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            a.apiError = o?["error"] is String
            return ApiSample.of(host: host, route: route, answer: a, cancelled: false, measure: m, ownMs: ownMs)
        case .failure(let e):
            let status = t.probe?.status.withLock { $0 }
            var cancelled = Task.isCancelled
            if case .offline(let why) = e, let mk = ErrorCause.marker(why), mk.code == String(NSURLErrorCancelled) { cancelled = true }
            var a = ApiClass.Answer(status: status)
            if status != nil {
                // the answer began and its body did not come whole: a 2xx is `cut`; another status is its own class
                a.cut = true
            } else {
                a.noStatus = FailClass.of(e, status: nil, cancelled: false) ?? "no_answer"
            }
            return ApiSample.of(host: host, route: route, answer: a, cancelled: cancelled, measure: m, ownMs: nil)
        }
    }

    /// SDK 4.0.5 (34.4): `r` to `host`; with `next`, and no answer within `CDNFileSource.hedgeAfter`, the same request also
    /// goes to `next`. The first answer that is taken (`accept`), a refusal or a slow down decides and the other request is
    /// cancelled; an unreachable one decides nothing, and the other is waited for. The attempts in the order they ended.
    /// (A manifest is one small read: its answer is decided when it has arrived, not at its status.)
    private func hedged(_ r: URLRequest, host: URL, next: URL?, url: URL, accept: @escaping @Sendable (Response) -> Bool,
                        counted: String? = nil) async -> [Attempt] {
        func launch(_ r: URLRequest) -> (Task<Result<Response, CloudError>, Never>, Locked<(Result<Response, CloudError>, Date)?>) {
            let done = Locked<(Result<Response, CloudError>, Date)?>(nil)
            let t = Task { () -> Result<Response, CloudError> in
                let res: Result<Response, CloudError>
                do throws(CloudError) { res = .success(try await self.once(r, limited: true)) } catch { res = .failure(error) }
                done.withLock { $0 = (res, Date()) }
                return res
            }
            return (t, done)
        }
        func decides(_ res: Result<Response, CloudError>) -> Bool {
            guard case .success(let resp) = res else { return false }
            return Endpoints.answerClass(status: resp.status, body: resp.body, taken: accept(resp)) != .unreachable
        }
        let sent1 = Date()
        // no host to hedge to (another role, the last host): the request alone, as before 4.0.5
        guard let next else {
            let probe = counted != nil ? ApiProbe() : nil
            let res: Result<Response, CloudError>
            do throws(CloudError) { res = .success(try await once(r, limited: true, probe: probe)) } catch { res = .failure(error) }
            return [Attempt(host: host, result: res, sent: sent1, ended: Date(), lost: false, hedged: false, probe: probe)]
        }
        let (t1, d1) = launch(r)
        let wait = CDNFileSource.hedgeAfter.withLock { $0 }
        while !Task.isCancelled, d1.withLock({ $0 }) == nil, Date().timeIntervalSince(sent1) < wait {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard d1.withLock({ $0 }) == nil, !Task.isCancelled else {
            let res = await withTaskCancellationHandler { await t1.value } onCancel: { t1.cancel() }
            return [Attempt(host: host, result: res, sent: sent1, ended: d1.withLock { $0?.1 } ?? Date(), lost: false, hedged: false)]
        }
        var r2 = r
        r2.url = Endpoints.rehost(url, to: next)
        let sent2 = Date()
        let (t2, d2) = launch(r2)
        var out: [Attempt] = []
        var seen1 = false, seen2 = false
        while !(seen1 && seen2) {
            if Task.isCancelled {
                t1.cancel()
                t2.cancel()
            }
            if !seen1, let (res, at) = d1.withLock({ $0 }) {
                seen1 = true
                out.append(Attempt(host: host, result: res, sent: sent1, ended: at, lost: false, hedged: true))
                if decides(res) {
                    t2.cancel()
                    _ = await t2.value
                    // the lost request first, so it is counted before the answer ends the request
                    out.insert(Attempt(host: next, result: .failure(.offline(HTTPClient.hedgeLost)), sent: sent2, ended: Date(), lost: true,
                                       hedged: false), at: 0)
                    return out
                }
            }
            if !seen2, let (res, at) = d2.withLock({ $0 }) {
                seen2 = true
                out.append(Attempt(host: next, result: res, sent: sent2, ended: at, lost: false, hedged: false))
                if decides(res) {
                    t1.cancel()
                    _ = await t1.value
                    if !seen1 {
                        out.insert(Attempt(host: host, result: .failure(.offline(HTTPClient.hedgeLost)), sent: sent1, ended: Date(), lost: true,
                                           hedged: true), at: 0)
                    }
                    return out
                }
            }
            if !(seen1 && seen2) { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        return out
    }

    /// The first host was unreachable: told to the endpoint set (`lastFailover`, the `failover` report).
    /// `report`: whether the request asked its first host (a silent `failover` report goes out only then, 28.7).
    private func failedOver(_ endpoints: EndpointSet, _ role: EndpointRole, _ url: URL, _ from: URL, to: URL?,
                            _ first: Result<Response, CloudError>, check: String? = nil, report: Bool = true) {
        let (reason, status) = Endpoints.unreachableReason(first)
        let f = EndpointSet.Failover(role: role, from: from.host ?? "", to: to?.host, reason: reason, status: status,
                                     at: Int64(endpoints.clock().timeIntervalSince1970),
                                     check: reason == "invalid_answer" ? check.flatMap { ErrorRules.token($0, ErrorRules.errorCodePattern) } : nil)
        endpoints.failedOver(f, stage: report ? Endpoints.stage(role, path: url.path) : nil)
    }
}

/// The role of the last request an operation made through a role's hosts, and whether it was asked of more than one
/// host (24.2 `host_role`, `fallback`): the cause of a failure made in that operation names them. An operation is a
/// scope (`RequestTrace.scope`: a config refresh, a registration, a model install, a lease attempt) and its child
/// tasks; outside one nothing is kept, so a cause never takes another operation's request.
/// Tried before (df09971): a map keyed by the current task's hash, kept two minutes. A task is identified by its
/// address, which a later task reuses, so a cause made without a request of its own (a stand-in transport, a
/// background transfer) took the request of a task that had ended (ProtectedCoreTests in the full suite).
enum RequestTrace {
    struct Entry: Sendable {
        let role: EndpointRole
        let fallback: Bool
    }

    /// The operation's last request, while a scope is bound.
    @TaskLocal static var box: Locked<Entry?>?

    /// `body` as one operation: its requests' role and fallback are what its causes name. A scope inside another is
    /// the outer one (its last request is the operation's).
    static func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if box != nil { return await body() }
        // SDK 4.0.5 (ATTEST_40.md 40.6): the operation's cause chain beside its last request
        return await $box.withValue(Locked(nil)) { await CauseChain.scope(body) }
    }

    static func note(_ role: EndpointRole, fallback: Bool) {
        box?.withLock { $0 = Entry(role: role, fallback: fallback) }
    }

    /// The operation's last request through a role, when it made one.
    static var last: Entry? { box?.withLock { $0 } }
}

extension ErrorCause {
    /// The stages whose cause is a request to a host of 28.1 (28.7), and the reasons of them that are not an answer of
    /// a host (the device's own store, a clock, an attestation the platform cannot give).
    static let hostStages: Set<String> = ["config", "register", "attest", "lease", "manifest", "download", "sharing", "events"]
    static let localReasons: Set<String> = ["storage", "quota", "aborted", "unsupported", "expired", "clock", "hash", "other", "encoder"]

    /// The cause with `host_role` and `fallback` of the request it is, when this task made one through a role's hosts
    /// (24.2, 28.7); unchanged for another stage or a reason that is not a host's answer.
    func traced() -> ErrorCause {
        var c = self
        // SDK 4.0.5 (40.6): a cause made in an operation carries its chain, whatever its reason
        if c.chain == nil { c.chain = CauseChain.current }
        guard hostRole == nil, Self.hostStages.contains(stage), !Self.localReasons.contains(reason), let t = RequestTrace.last else { return c }
        c.hostRole = t.role.rawValue
        c.fallback = t.fallback
        return c
    }
}
