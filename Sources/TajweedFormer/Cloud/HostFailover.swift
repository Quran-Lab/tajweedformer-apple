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
        return r.body.isEmpty || (try? JSONSerialization.jsonObject(with: r.body, options: [.fragmentsAllowed])) != nil
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
    func routed(_ request: URLRequest, role named: EndpointRole?, accept: @escaping @Sendable (Response) -> Bool)
        async throws(CloudError) -> Response {
        guard let endpoints, let url = request.url, let origin = Endpoints.origin(of: url),
              let role = named ?? endpoints.role(of: url) else { return try await once(request, limited: false) }
        let start = endpoints.clock()
        let first = named != nil && !endpoints.isRoleHost(role, origin) ? origin : nil
        let (order, probe) = endpoints.order(role, at: start, first: first)
        var firstResult: Result<Response, CloudError>?
        var asked: [URL] = []
        for host in order {
            var r = request
            r.url = Endpoints.rehost(url, to: host)
            asked.append(host)
            let result: Result<Response, CloudError>
            do throws(CloudError) { result = .success(try await once(r, limited: true)) } catch { result = .failure(error) }
            if firstResult == nil { firstResult = result }
            let cls: AnswerClass
            switch result {
            case .success(let resp):
                cls = Endpoints.answerClass(status: resp.status, body: resp.body, taken: accept(resp))
                // 28.5: a lease attempt waits the largest Retry-After any host gave when every host was unreachable
                LeaseAttemptTrace.current?.hostAnswered(retryAfter: resp.header("Retry-After"))
            case .failure: cls = .unreachable
            }
            if cls != .unreachable {
                endpoints.settle(role, host, at: start, probe: probe)
                RequestTrace.note(role, fallback: asked.count > 1)
                if asked.count > 1, let firstResult { failedOver(endpoints, role, url, asked[0], to: host, firstResult) }
                return try result.get()
            }
            // a caller that gave up asks no other host
            if Task.isCancelled { return try result.get() }
        }
        RequestTrace.note(role, fallback: asked.count > 1)
        guard let firstResult else { return try await once(request, limited: true) }
        failedOver(endpoints, role, url, asked[0], to: nil, firstResult)
        return try firstResult.get()
    }

    /// The first host was unreachable: told to the endpoint set (`lastFailover`, the `failover` report).
    private func failedOver(_ endpoints: EndpointSet, _ role: EndpointRole, _ url: URL, _ from: URL, to: URL?,
                            _ first: Result<Response, CloudError>) {
        let (reason, status) = Endpoints.unreachableReason(first)
        let f = EndpointSet.Failover(role: role, from: from.host ?? "", to: to?.host, reason: reason, status: status,
                                     at: Int64(endpoints.clock().timeIntervalSince1970))
        endpoints.failedOver(f, stage: Endpoints.stage(role, path: url.path))
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
        return await $box.withValue(Locked(nil)) { await body() }
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
        guard hostRole == nil, Self.hostStages.contains(stage), !Self.localReasons.contains(reason), let t = RequestTrace.last else { return self }
        var c = self
        c.hostRole = t.role.rawValue
        c.fallback = t.fallback
        return c
    }
}
