import Foundation

/// SDK 4.0.5: one hop of a cause chain. Every answer of a Quran Lab host that
/// was not taken in an operation (unreachable, a refusal, a slow down: one per host asked), and every failure of the
/// platform's attestation (App Attest), in the order they happened. The report's `error.chain` and `diagnose()`'s
/// `protected.lastFailure.chain` carry the last 8. Tokens only: never a host name (`host` is `first` or `standby`), a
/// path, a message or an identifier.
struct CauseHop: Codable, Sendable, Equatable {
    var stage: String
    /// `api`, `models` or `web_frame`; nil for a platform's attestation.
    var hostRole: String?
    /// `first` for a host under quranlab.ai (28.1's first hosts), `standby` for any other allowed host.
    var host: String?
    var httpStatus: Int?
    var reason: String
    var errorName: String?
    /// The check the answer failed (40.5), the server's `error`, the platform's code.
    var errorCode: String?

    /// A hop with each value through 24.2's pattern for its field (a value that fails is left out, never cut); nil when
    /// its stage or reason is not a token. `hostName` is the host the request asked, read for `first` or `standby` only.
    static func made(stage: String, reason: String, hostRole: String? = nil, hostName: String? = nil, httpStatus: Int? = nil,
                     errorName: String? = nil, errorCode: String? = nil) -> CauseHop? {
        guard ErrorRules.token(stage, ErrorRules.reasonPattern) != nil, ErrorRules.token(reason, ErrorRules.reasonPattern) != nil
        else { return nil }
        let role = hostRole.flatMap { CauseChain.roles.contains($0) ? $0 : nil }
        return CauseHop(stage: stage, hostRole: role, host: role == nil ? nil : hostName.map(CauseChain.host(of:)),
                        httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }, reason: reason,
                        errorName: errorName.flatMap { ErrorRules.token($0, ErrorRules.errorNamePattern) },
                        errorCode: errorCode.flatMap { ErrorRules.token($0, ErrorRules.errorCodePattern) })
    }

    /// The hop as the report sends it (24.2's names, fields in 40.6's order, an absent one left out).
    struct Wire: Encodable, Sendable, Equatable {
        var stage: String
        var host_role: String?
        var host: String?
        var http_status: Int?
        var reason: String
        var error_name: String?
        var error_code: String?
    }

    var wire: Wire {
        Wire(stage: stage, host_role: hostRole, host: host, http_status: httpStatus, reason: reason, error_name: errorName,
             error_code: errorCode)
    }

    /// The hop in `diagnose()`'s JSON (camelCase, 40.6 item 2), its fields in order, an absent one left out.
    var diagnosisJSON: String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var parts = ["\"stage\": \(q(stage))"]
        if let hostRole { parts.append("\"hostRole\": \(q(hostRole))") }
        if let host { parts.append("\"host\": \(q(host))") }
        if let httpStatus { parts.append("\"httpStatus\": \(httpStatus)") }
        parts.append("\"reason\": \(q(reason))")
        if let errorName { parts.append("\"errorName\": \(q(errorName))") }
        if let errorCode { parts.append("\"errorCode\": \(q(errorCode))") }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}

/// The hops of one operation (40.6): bound with the operation's scope (`RequestTrace.scope` binds it beside its own),
/// so a cause made in it carries them (`ErrorCause.traced`). Outside an operation nothing is kept.
enum CauseChain {
    /// 40.6: the hops a report carries, the last ones.
    static let max = 8
    /// The hops a box keeps while the operation runs (a long run of retries keeps its latest).
    static let kept = 32
    static let roles: Set<String> = ["api", "models", "web_frame"]

    @TaskLocal static var box: Locked<[CauseHop]>?

    /// `body` with a box of its own, unless one is bound already (an operation inside another is the outer one's).
    static func scope<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if box != nil { return await body() }
        return await $box.withValue(Locked([])) { await body() }
    }

    /// Records a hop in the operation's box; nothing outside an operation.
    static func add(_ hop: CauseHop?) {
        guard let hop, let box else { return }
        box.withLock { h in
            h.append(hop)
            if h.count > kept { h.removeFirst(h.count - kept) }
        }
    }

    /// The operation's hops so far, the last `max`; nil when there is none or no operation.
    static var current: [CauseHop]? { box.flatMap { b in last(b.withLock { $0 }) } }

    /// The last `max` of `hops`, nil when empty.
    static func last(_ hops: [CauseHop]) -> [CauseHop]? {
        hops.isEmpty ? nil : Array(hops.suffix(max))
    }

    /// `first` for a host under quranlab.ai, `standby` for any other: never the name (40.6).
    static func host(of name: String) -> String {
        let h = Endpoints.asciiLower(name)
        return h == "quranlab.ai" || h.hasSuffix(".quranlab.ai") ? "first" : "standby"
    }
}
