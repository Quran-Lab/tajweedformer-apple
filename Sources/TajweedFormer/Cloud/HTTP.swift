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
    /// Bytes per range request.
    var rangeSize: Int64
    /// The pauses, in seconds, before a model file's download is taken up again after a failure of the network:
    /// one per retry, so their count is the most retries a file gets in one call. Tests pass short ones.
    /// (To 3.1.1 there was an option `parallelDownloads` here that nothing read: the download is one request at a
    /// time in the foreground. It is gone; `parallelBackgroundRanges` is what the background session runs at a time.)
    var retryPauses: [TimeInterval]
    /// Whether, and when, a model download uses the background session (`BackgroundDownloads.swift`). Ignored
    /// when `urlSession` is set, unless `backgroundTransport` is.
    var backgroundDownloads: BackgroundDownloadPolicy
    /// The range tasks the background session runs at a time.
    var parallelBackgroundRanges: Int
    /// Nil: the background session. Tests pass a stand-in.
    var backgroundTransport: (any BackgroundRangeTransport)?
    /// Whether the app has left the foreground. Tests pass their own.
    var handOver: DownloadHandOver
    /// Upload shared sessions on a background URLSession, so an upload goes on while the app is
    /// suspended (on by default on iOS; the host forwards `handleEventsForBackgroundURLSession`
    /// to `TajweedClient.handleBackgroundEvents`). Ignored when `urlSession` is set. Off by default on
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
                rangeSize: Int64 = 8 << 20,
                retryPauses: [TimeInterval] = ModelInstaller.standardRetryPauses,
                backgroundDownloads: BackgroundDownloadPolicy = CloudOptions.backgroundDownloadsByDefault,
                parallelBackgroundRanges: Int = 4,
                backgroundTransport: (any BackgroundRangeTransport)? = nil,
                handOver: DownloadHandOver = .shared,
                backgroundUploads: Bool = CloudOptions.backgroundUploadsByDefault) {
        self.apiURL = apiURL
        self.cdnURL = cdnURL
        self.signingKeys = signingKeys
        self.issueReports = issueReports
        self.updatesOnWiFiOnly = updatesOnWiFiOnly
        self.appleTeamID = appleTeamID
        self.app = app
        self.urlSession = urlSession
        self.rangeSize = rangeSize
        self.retryPauses = retryPauses
        self.backgroundDownloads = backgroundDownloads
        self.parallelBackgroundRanges = parallelBackgroundRanges
        self.backgroundTransport = backgroundTransport
        self.handOver = handOver
        self.backgroundUploads = backgroundUploads
    }

    #if os(iOS)
    static let backgroundUploadsByDefault = true
    #else
    static let backgroundUploadsByDefault = false
    #endif

    /// The environment variable that chooses the policy of model downloads for a measurement on a device (`off`,
    /// `whenLeaving`, `whenResigning` or `fromFirstByte`). It is read in a DEBUG build of the SDK only (an app run from Xcode); in
    /// a release build the policy is the system's default whatever the environment says. An app has no option
    /// for it.
    static let backgroundDownloadsVariable = "QURANLAB_BACKGROUND_DOWNLOADS"

    /// On iOS what is left of a model download goes to the background session when the learner leaves the app. A
    /// Mac app is not suspended: its download runs in the app's process, and `fromFirstByte` never applies there.
    static var backgroundDownloadsByDefault: BackgroundDownloadPolicy {
        #if os(iOS)
        let usual = BackgroundDownloadPolicy.whenLeaving
        #else
        let usual = BackgroundDownloadPolicy.off
        #endif
        #if DEBUG
        // read from the process's environment as it is now: an app that measures sets it before it makes its Client
        if let named = getenv(backgroundDownloadsVariable), let chosen = BackgroundDownloadPolicy(rawValue: String(cString: named)) {
            #if os(iOS)
            return chosen
            #else
            return chosen == .fromFirstByte ? usual : chosen
            #endif
        }
        #endif
        return usual
    }
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
    /// The device could not keep what a model request delivered (the partial file could not be opened or written).
    case storage(String)
    /// A model file's request was answered with success and with something that is not the file asked for (SPEC
    /// 16.1: a 204, another length, another start or total, no byte). A failed attempt: the file is tried again by
    /// the installer's rule, and nothing stored is lost.
    case badAnswer(String)

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
        case .storage(let why): return .storageFailed(why)
        case .badAnswer(let why): return .updateDeferred("the download server's answer was not the file: \(why)")
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
    /// The protocol the request went by, as the system's metrics name it (`h3`, `h2`, `http/1.1`); nil until the
    /// task's metrics arrive, and when they name none.
    let networkProtocol = Locked<String?>(nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        refused.withLock { $0 = true }
        return nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let name = metrics.transactionMetrics.last(where: { $0.networkProtocolName != nil })?.networkProtocolName
        networkProtocol.withLock { $0 = name }
    }
}

/// A thin JSON client for qlab-api and qlab-cdn.
struct HTTPClient: Sendable {
    let session: URLSession

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        /// A model request only: the protocol it went by (`h3`, `h2`, `http/1.1`), when the system named one.
        var networkProtocol: String?

        func header(_ name: String) -> String? {
            let n = name.lowercased()
            return headers.first { $0.key.lowercased() == n }?.value
        }
    }

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        // The stall limit of every request, a model request included: 30 seconds WITHOUT A BYTE end it. The timer
        // starts again with every piece that arrives, so it is not a limit on the whole transfer: a slow link that
        // keeps delivering is never cut. (The limit on a whole transfer, `timeoutIntervalForResource`, stays at the
        // system's seven days.)
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    /// For tests: the protocol a model request is taken to have gone by. The suite's stub server answers inside
    /// the process, so the system's metrics name no protocol for its requests.
    static let networkProtocolOverride = Locked<(@Sendable (URLRequest) -> String?)?>(nil)

    /// The answers that name another address for the request.
    static let redirects: Set<Int> = [301, 302, 303, 307, 308]

    /// What a redirect is to the SDK: a failed request, `offline` like an answer that did not come.
    static func redirectRefused(_ status: Int) -> CloudError {
        .offline("the server answered with a redirect (HTTP \(status)), which the SDK never follows")
    }

    /// Sends one request. This is the one place every request of the SDK's ordinary session passes whose answer
    /// is held in memory: the API's calls (config, registration, attestation and token, telemetry, issues, every
    /// sharing call, the deletion calls), a model's manifest, and a segment's PUT to its signed URL when it runs
    /// in the app (a model file's bytes go by `stream`, under the same rule). None of them follows a redirect
    /// (SPEC 15.4): the task's delegate tells the system no, and the 3xx is a failed request, `offline` like an
    /// answer that did not come. It is never a refusal of the key, and it is asked again only by the rule the
    /// call already has for a failed request. The task's metrics say which protocol the request went by.
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
        if watch.refused.withLock({ $0 }) || Self.redirects.contains(http.statusCode) { throw Self.redirectRefused(http.statusCode) }
        let networkProtocol = Self.networkProtocolOverride.withLock { $0 }?(request) ?? watch.networkProtocol.withLock { $0 }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        return Response(status: http.statusCode, headers: headers, body: data, networkProtocol: networkProtocol)
    }

    /// Sends and checks the status: 2xx returns, 5xx is offline, 4xx is rejected with the error
    /// code from the body.
    func checked(_ request: URLRequest) async throws(CloudError) -> Response {
        let r = try await send(request)
        if (200..<300).contains(r.status) { return r }
        throw Self.failure(status: r.status, body: r.body)
    }

    /// The failure a status outside 2xx stands for: a redirect, which the SDK never follows, a 5xx (worth another
    /// try), or a refusal with the body's code and reason.
    static func failure(status: Int, body: Data) -> CloudError {
        if redirects.contains(status) { return redirectRefused(status) }
        if status >= 500 { return .offline("HTTP \(status)") }
        let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return .rejected(status: status, code: o?["error"] as? String ?? "http_\(status)", message: message(o), reason: reason(o))
    }

    /// What a model request did whose body went to a file as it arrived.
    struct Streamed: Sendable {
        let status: Int
        let headers: [String: String]
        /// The server sent the whole file (a 200 to a range request), all of it arrived, and it took the partial
        /// file's place.
        let whole: Bool
        /// The bytes this request wrote.
        let written: Int64
        /// The protocol it went by, when the system named one.
        let networkProtocol: String?
    }

    /// The bytes a streamed request gathers before it writes them to the file.
    static let pieceBytes = 64 << 10

    /// The `error` of a model file's request that the server answered with a redirect. It is asked once: a redirect
    /// is not the network's failure, and is not tried again in the call (SPEC 16.2).
    static let redirectCode = "redirect_refused"

    /// A header of an answer, by name, whatever its case.
    static func header(_ headers: [String: String], _ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.key.lowercased() == n }?.value
    }

    /// `Content-Range: bytes <lower>-<upper>/<total>`, read whole; nil for anything else (no total, another unit).
    static func contentRange(_ value: String?) -> (lower: Int64, upper: Int64, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let ends = parts[0].split(separator: "-")
        guard ends.count == 2, let lower = Int64(ends[0].trimmingCharacters(in: .whitespaces)),
              let upper = Int64(ends[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (lower, upper, total)
    }

    /// Where a whole file that the server sends in place of a range is written until all of it has arrived:
    /// beside the partial file.
    static func wholeFile(beside part: URL) -> URL { URL(fileURLWithPath: part.path + ".whole") }

    /// A model request whose body is written to disk as it arrives, so that a connection that ends keeps what it
    /// delivered. `offset` is the first byte of the range asked for, which is where the partial file `file` ends;
    /// `size` is the whole file's size in the signed manifest.
    ///
    /// What is the file (SPEC 16.1), and nothing else is:
    /// - a 206 whose Content-Range starts at `offset` and names `size` as its total: its bytes are appended to the
    ///   partial file, at most as many as the range it names;
    /// - a 200, the whole file sent in place of the range, only at the manifest's size: a Content-Length, where
    ///   one is given without a content coding, must equal `size`; the body is written to a file BESIDE the
    ///   partial file, at most `size` bytes of it, and takes the partial file's place only when all of it has
    ///   arrived.
    /// Anything else that says success is a failed attempt, `badAnswer`: a 204, another length, another start or
    /// total, no Content-Range, a body that runs past its size, an answer that brings no byte. A failed attempt
    /// costs no stored byte: the partial file is as it was, and the caller tries again by its rule.
    ///
    /// `started` is told the answer's headers and whether it is the whole file: for a range before its first byte
    /// is written, for a whole file when it has taken the partial file's place. `received` is told the bytes that
    /// came to count: every piece of a range as it is written, and for a whole file, once it is in place, what it
    /// added to the `offset` bytes counted before. No redirect is followed. When the connection ends after bytes
    /// of a range arrived, they are written before `offline` is thrown; a whole file that did not arrive whole
    /// leaves nothing.
    /// Tried before (the first candidate of this version, never released): every 2xx that was not a 206 was taken
    /// for the whole file and written over the partial file from its first byte, with no look at its length, and an
    /// answer without a byte was a success. A 204, a short 200 or an error page with status 200 then wiped the
    /// partial file, and the caller asked again at once, without a count and without a pause.
    func stream(_ request: URLRequest, offset: Int64, size: Int64, into file: URL,
                started: @Sendable (_ headers: [String: String], _ whole: Bool) -> Void,
                received: @Sendable (Int64) -> Void) async throws(CloudError) -> Streamed {
        let fm = FileManager.default
        let watch = NoRedirect()
        let incoming: URLSession.AsyncBytes, response: URLResponse
        do {
            (incoming, response) = try await session.bytes(for: request, delegate: watch)
        } catch {
            throw .offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalid("not an HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k] = v }
        }
        let status = http.statusCode
        if watch.refused.withLock({ $0 }) || Self.redirects.contains(status) {
            throw .rejected(status: status, code: Self.redirectCode,
                            message: "the server answered with a redirect (HTTP \(status)), which the SDK never follows")
        }
        guard (200..<300).contains(status) else {
            // a refusal's body is small JSON: at most 64 KiB of it is read, for its code and reason
            var body = [UInt8]()
            do {
                for try await byte in incoming {
                    body.append(byte)
                    if body.count >= 65_536 { break }
                }
            } catch {}
            throw Self.failure(status: status, body: Data(body))
        }
        // what the answer must be to be the file, and the most bytes it may bring
        let whole: Bool
        let limit: Int64
        switch status {
        case 206:
            let said = Self.header(headers, "content-range")
            guard let named = Self.contentRange(said) else { throw .badAnswer("a 206 without a Content-Range it can be held to") }
            guard named.lower == offset, named.total == size, named.upper >= named.lower, named.upper < size else {
                throw .badAnswer("a 206 for another range or another file size than the one asked for (\(said ?? ""))")
            }
            whole = false
            limit = named.upper - named.lower + 1
        case 200:
            if Self.header(headers, "content-encoding") == nil, let given = Self.header(headers, "content-length").flatMap({ Int64($0) }),
               given != size {
                throw .badAnswer("a 200 of \(given) bytes for a file of \(size)")
            }
            whole = true
            limit = size
        default:
            throw .badAnswer("HTTP \(status) is not a file")
        }
        let target = whole ? Self.wholeFile(beside: file) : file
        let handle: FileHandle
        do {
            if whole { try? fm.removeItem(at: target) }
            if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
            handle = try FileHandle(forWritingTo: target)
            let begin = whole ? Int64(0) : offset
            try handle.truncate(atOffset: UInt64(begin))
            try handle.seek(toOffset: UInt64(begin))
        } catch {
            throw .storage("cannot open \(target.lastPathComponent): \(error.localizedDescription)")
        }
        if !whole { started(headers, false) }
        var written: Int64 = 0
        var buffer = [UInt8]()
        buffer.reserveCapacity(Self.pieceBytes)
        var storage: String?
        var broken: String?
        // the body ran past what the answer may bring
        var over = false
        do {
            for try await byte in incoming {
                if written + Int64(buffer.count) >= limit {
                    over = true
                    break
                }
                buffer.append(byte)
                if buffer.count >= Self.pieceBytes {
                    storage = Self.write(&buffer, to: handle)
                    if storage != nil { break }
                    written += Int64(Self.pieceBytes)
                    if !whole { received(Int64(Self.pieceBytes)) }
                }
            }
        } catch {
            broken = error.localizedDescription
        }
        // what arrived before the connection ended is written before the failure is reported
        if storage == nil, !buffer.isEmpty {
            let last = Int64(buffer.count)
            storage = Self.write(&buffer, to: handle)
            if storage == nil {
                written += last
                if !whole { received(last) }
            }
        }
        try? handle.synchronize()
        try? handle.close()
        let named = Self.networkProtocolOverride.withLock { $0 }?(request) ?? watch.networkProtocol.withLock { $0 }
        if whole {
            // the whole file takes the partial file's place only when all of it has arrived
            if storage == nil, !over, broken == nil, written == size {
                do {
                    try? fm.removeItem(at: file)
                    try fm.moveItem(at: target, to: file)
                } catch {
                    try? fm.removeItem(at: target)
                    throw .storage("cannot put \(file.lastPathComponent) in place: \(error.localizedDescription)")
                }
                started(headers, true)
                received(size - offset)
                return Streamed(status: status, headers: headers, whole: true, written: written, networkProtocol: named)
            }
            try? fm.removeItem(at: target)
            if let storage { throw .storage("cannot write \(target.lastPathComponent): \(storage)") }
            if over { throw .badAnswer("a 200 that runs past the file's \(size) bytes") }
            if let broken { throw .offline(broken) }
            throw .badAnswer("a 200 of \(written) bytes for a file of \(size)")
        }
        if let storage { throw .storage("cannot write \(file.lastPathComponent): \(storage)") }
        // what a range wrote within the bytes it named stays, however it ended
        if over { throw .badAnswer("a 206 that runs past the range it names") }
        if let broken { throw .offline(broken) }
        if written == 0 { throw .badAnswer("a 206 without a byte") }
        return Streamed(status: status, headers: headers, whole: false, written: written, networkProtocol: named)
    }

    /// Writes the gathered bytes to the file and empties the buffer; the failure's words when the write fails.
    private static func write(_ buffer: inout [UInt8], to handle: FileHandle) -> String? {
        defer { buffer.removeAll(keepingCapacity: true) }
        do {
            try handle.write(contentsOf: buffer)
            return nil
        } catch {
            return error.localizedDescription
        }
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

/// The protocol of the last answered model request of this Client in this process (3.1.5; SPEC 16.3), for
/// `diagnose()`: `h3`, `h2` or `http/1.1`. Held in memory, sent in no telemetry, and gone with the process: a
/// protocol from an earlier launch says nothing about this one.
/// Tried before (the first candidate, never released): a record in a file, which the next launch read.
enum ModelDownloadRecord {
    private static let last = Locked<String?>(nil)

    static var networkProtocol: String? { last.withLock { $0 } }

    static func note(_ networkProtocol: String) { last.withLock { $0 = networkProtocol } }

    /// A new Client starts without one.
    static func reset() { last.withLock { $0 = nil } }
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
