import Foundation

/// Where the SDK's servers are and what it trusts. The defaults are production; tests and the
/// local stack point them elsewhere.
struct CloudOptions: Sendable {
    /// qlab-api.
    var apiURL: URL
    /// Where model files are served. Nil, the default: the `base` of the signed remote config, else
    /// `https://cdn.quranlab.ai/models`. Set, it wins over the config.
    var cdnURL: URL?
    /// Raw 32-byte Ed25519 public keys that config responses and model manifests may be signed with.
    var signingKeys: [Data]
    /// Send error reports (independent of `analytics`). The remote config can also turn them off.
    var issueReports: Bool
    /// Download model updates only on Wi-Fi or wired networks (not cellular, not Low Data Mode).
    var updatesOnWiFiOnly: Bool
    /// The Apple team id, for App Attest. Nil means read it from the app's keychain access group.
    var appleTeamID: String?
    /// Nil means `AppIdentity.main`.
    var app: AppIdentity?
    /// Nil means a session made for the SDK. Tests pass one with a stub URLProtocol.
    var urlSession: URLSession?
    /// Parallel range requests per model download.
    var parallelDownloads: Int
    /// Bytes per range request.
    var rangeSize: Int64
    /// Upload shared sessions on a background URLSession, so an upload goes on while the app is
    /// suspended (on by default on iOS; the host forwards `handleEventsForBackgroundURLSession`
    /// to `QuranLab.handleBackgroundEvents`). Ignored when `urlSession` is set. Off by default on
    /// macOS: a Mac app is not suspended, so uploads run in the app's process while it runs, and
    /// whatever is left waits on disk for the next launch (a background session there would only
    /// add a daemon hop, and AppKit has no event to relaunch the app for its results).
    var backgroundUploads: Bool

    init(apiURL: URL = URL(string: "https://api.quranlab.ai")!,
                cdnURL: URL? = nil,
                signingKeys: [Data] = [ManifestVerifier.quranLabPublicKey],
                issueReports: Bool = true,
                updatesOnWiFiOnly: Bool = true,
                appleTeamID: String? = nil,
                app: AppIdentity? = nil,
                urlSession: URLSession? = nil,
                parallelDownloads: Int = 4,
                rangeSize: Int64 = 8 << 20,
                backgroundUploads: Bool = CloudOptions.backgroundUploadsByDefault) {
        self.apiURL = apiURL
        self.cdnURL = cdnURL
        self.signingKeys = signingKeys
        self.issueReports = issueReports
        self.updatesOnWiFiOnly = updatesOnWiFiOnly
        self.appleTeamID = appleTeamID
        self.app = app
        self.urlSession = urlSession
        self.parallelDownloads = parallelDownloads
        self.rangeSize = rangeSize
        self.backgroundUploads = backgroundUploads
    }

    #if os(iOS)
    static let backgroundUploadsByDefault = true
    #else
    static let backgroundUploadsByDefault = false
    #endif
}

/// What went wrong talking to a server. Internal: public calls turn it into a RecognizerError.
enum CloudError: Error, Equatable, Sendable {
    /// No connection, a timeout, or a 5xx: worth retrying later.
    case offline(String)
    /// The server said no (4xx) with its error code: retrying the same request will not help. `reason` is the
    /// answer's `reason`, when it has one: the check that refused (the API answers an origin, key-type or
    /// allow-list refusal as a 401 `invalid_key` and names the check there). What the SDK does with the network
    /// follows `status` and `code`; the error an app gets reads `reason` first.
    case rejected(status: Int, code: String, message: String, reason: String? = nil)
    /// A response that does not verify or parse.
    case invalid(String)
    /// No developer key configured.
    case noKey

    var retryable: Bool {
        switch self {
        case .offline: return true
        case .rejected(let s, _, _, _): return s == 429 || s == 401
        default: return false
        }
    }

    var recognizerError: RecognizerError {
        switch self {
        case .offline(let why): return .offline(why)
        case .rejected(let s, let code, let m, let reason): return .serverRejected(status: s, code: code, message: m, reason: reason)
        case .invalid(let why): return .serverRejected(status: 0, code: "invalid_response", message: why)
        case .noKey: return .serviceUnavailable("no developer key configured (QuranLab.configure(key:))")
        }
    }
}

/// Refuses every redirect of the request it is given to: the 3xx is the answer. No request of the SDK follows a
/// redirect (SPEC 15.4, contract 1.17.0): a system that follows one by itself sends the request's own headers to
/// the new host (the developer key in `x-qlab-key`, a token, a recording's id), and on a 307 or 308 the body too,
/// which can be a report or a recording.
final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    /// The system asked about a redirect, and was told no.
    let refused = Locked(false)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        refused.withLock { $0 = true }
        return nil
    }
}

/// A thin JSON client for qlab-api and qlab-cdn.
struct HTTPClient: Sendable {
    let session: URLSession

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            let n = name.lowercased()
            return headers.first { $0.key.lowercased() == n }?.value
        }
    }

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    /// The answers that name another address for the request.
    static let redirects: Set<Int> = [301, 302, 303, 307, 308]

    /// Sends one request. This is the one place every request of the SDK's ordinary session passes: the API's
    /// calls (config, registration, attestation and token, telemetry, issues, every sharing call, the deletion
    /// calls), the model requests, and a segment's PUT to its signed URL when it runs in the app. None of them
    /// follows a redirect (SPEC 15.4): the task's delegate tells the system no, and the 3xx is a failed request,
    /// `offline` like an answer that did not come. It is never a refusal of the key, and it is asked again only by
    /// the rule the call already has for a failed request.
    /// Tried before (to 3.1.2): only a model request had the refusing delegate (since 3.1.0). Every other request
    /// was sent with `session.data(for:)` and no delegate, which leaves a redirect to the system, and the system
    /// follows it.
    func send(_ request: URLRequest) async throws(CloudError) -> Response {
        let data: Data, response: URLResponse
        let watch = NoRedirect()
        do {
            (data, response) = try await session.data(for: request, delegate: watch)
        } catch {
            throw .offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalid("not an HTTP response") }
        if watch.refused.withLock({ $0 }) || Self.redirects.contains(http.statusCode) {
            throw .offline("the server answered with a redirect (HTTP \(http.statusCode)), which the SDK never follows")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return Response(status: http.statusCode, headers: headers, body: data)
    }

    /// Sends and checks the status: 2xx returns, 5xx is offline, 4xx is rejected with the error
    /// code from the body.
    func checked(_ request: URLRequest) async throws(CloudError) -> Response {
        let r = try await send(request)
        if (200..<300).contains(r.status) { return r }
        if r.status >= 500 { throw .offline("HTTP \(r.status)") }
        let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
        throw .rejected(status: r.status, code: o?["error"] as? String ?? "http_\(r.status)", message: Self.message(o),
                        reason: Self.reason(o))
    }

    /// The message of a refusal. The SDK version a `sdk_too_old` answer names (`min_sdk`) goes in front of it, as
    /// `min_sdk x.y.z`, so the error's fix can name it.
    static func message(_ o: [String: Any]?) -> String {
        let text = o?["message"] as? String ?? ""
        if let v = o?["min_sdk"] as? String, ModelVersion.isVersion(v) { return "min_sdk \(v) " + text }
        return text
    }

    /// The `reason` of a refusal's body: the check that refused, when the server names one (absent or null: none).
    static func reason(_ o: [String: Any]?) -> String? {
        guard let r = o?["reason"] as? String, !r.isEmpty else { return nil }
        return r
    }

    static func jsonRequest(_ url: URL, method: String = "POST", body: [String: Any]?,
                            auth: String?) throws(CloudError) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let body {
            guard let d = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                throw .invalid("body is not JSON")
            }
            r.httpBody = d
            r.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if let auth { r.setValue("Bearer \(auth)", forHTTPHeaderField: "authorization") }
        return r
    }
}

/// A small JSON file the SDK keeps state in, written atomically, with the protection class named
/// (`StorageProtection`).
struct JSONFile<Value: Codable>: Sendable {
    let url: URL

    /// What the device has, in three results (3.1.4): not there, read, or there and not readable (the system
    /// refused the read, or the bytes are not this value). The caller says what it does with the third.
    func read() -> StoredRead<Value> { StorageSeam.read(url).decoded(Value.self) }

    func write(_ v: Value) { _ = store(v) }

    /// Writes the value; whether the device has it now (false on a full disk or a storage that refuses the write).
    func store(_ v: Value) -> Bool {
        try? StorageProtection.makeFolder(url.deletingLastPathComponent())
        guard let d = try? JSONEncoder().encode(v) else { return false }
        do {
            try d.write(to: url, options: StorageProtection.atomic)
            return true
        } catch {
            return false
        }
    }

    func delete() { try? FileManager.default.removeItem(at: url) }
}

extension Data {
    init?(base64URL s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        self.init(base64Encoded: t)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
