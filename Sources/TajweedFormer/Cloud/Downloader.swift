import Foundation

/// What a model request carries (SDK 3.1.0, SPEC 15.4): the install's app token and the developer key, both, for
/// good: the CDN reads the key first, and a request with a token alone gets its generic 401. `headers` is the ONE
/// place both are made: renaming a header is one edit there.
/// Tried before (to 3.0.1): a model request carried the developer key alone, so the server could not tell which
/// install fetched a model.
struct ModelRequestAuthorization: Sendable {
    /// The developer key.
    let key: String
    /// The install's app token (PLATFORM_CLIENT.md section 2: attested where the system supports App Attest, valid
    /// for at least another hour). With `renew` the token in hand is dropped and a new one is asked for.
    let token: @Sendable (_ renew: Bool) async throws(CloudError) -> String

    /// The headers of a model request: the manifest, every file, every resume.
    /// `key` nil: the token alone (a background transfer, when the signed config says so; 3.1.5).
    static func headers(key: String?, token: String) -> [(name: String, value: String)] {
        (key.map { [(name: "x-qlab-key", value: $0)] } ?? []) + [(name: "authorization", value: "Bearer \(token)")]
    }

    /// A fixed key and token (the SDK's tests).
    static func fixed(key: String, token: String) -> ModelRequestAuthorization {
        ModelRequestAuthorization(key: key, token: { (_: Bool) async throws(CloudError) -> String in token })
    }
}

/// The model files on the CDN: the model's signed `manifest.json` (format 3) and the stored files by HTTP Range, all
/// under the folder URL `ModelHost` builds.
struct CDNClient: Sendable {
    let http: HTTPClient
    let base: URL
    let auth: ModelRequestAuthorization
    let verifier: ManifestVerifier
    /// Told every refusal of a model request (the model gate remembers the ones that stop the model).
    var refused: @Sendable (CloudError) -> Void = { _ in }
    /// Told when the CDN served a model request: it accepts the key (a remembered refusal of a model request ends).
    var accepted: @Sendable () -> Void = {}
    /// Told the protocol a served model request went by, when the system named one (kept for `diagnose()`).
    var protocolSeen: @Sendable (String) -> Void = { _ in }

    /// A model request: the key and the token in their headers, the range when it asks for one, and the mark that
    /// the server speaks HTTP/3, so the first request can go by HTTP/3 and does not wait for the server to say so
    /// in an earlier answer. Only model requests carry the mark.
    /// `ifRange`: the validator of the partial file a range continues (`If-Range`).
    /// SDK 4.0.2 (section 33): every model request may go over any network the device has, a metered or a constrained
    /// one (Low Data Mode) too: a first install, an update, another context's files, the accelerator's build. The SDK
    /// never marks one as waiting for an unmetered network; the system may still hold a request by its own settings.
    /// To 4.0.1 an update's requests and the accelerator build's were marked so, and another context's files counted
    /// as an update: on mobile data a Session on that context got `model_missing` at every retry.
    static func request(_ url: URL, range: String?, key: String?, token: String, ifRange: String? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        for h in ModelRequestAuthorization.headers(key: key, token: token) { r.setValue(h.value, forHTTPHeaderField: h.name) }
        if let range { r.setValue(range, forHTTPHeaderField: "range") }
        if let ifRange { r.setValue(ifRange, forHTTPHeaderField: "if-range") }
        r.assumesHTTP3Capable = true
        r.allowsExpensiveNetworkAccess = true
        r.allowsConstrainedNetworkAccess = true
        return r
    }

    /// SDK 4.0.2 (SPEC 16.7): the Range of a request of the bytes `lower...upper` of a model file of `size` bytes: none
    /// for the whole file (one GET), `bytes=N-` for the rest of it from byte N (a resume), and `bytes=N-M` only where a
    /// range a 4.0.1 background task kept begins at M+1 (it is joined, not asked again). `size` nil: `bytes=N-M`.
    /// Tried before (to 4.0.1): `bytes=N-M` for fixed ranges of 8 MiB, one after another.
    static func range(lower: Int64, upper: Int64, size: Int64?) -> String? {
        guard let size, upper >= size - 1 else { return "bytes=\(lower)-\(upper)" }
        return lower == 0 ? nil : "bytes=\(lower)-"
    }

    /// The request of one stretch of a file for a background task: the install's token as it is now (asked for as for
    /// any model request; nil when none can be had), the range (`range(lower:upper:size:)`) and the validator. A background task keeps the request
    /// it was made with, and the system keeps that request in its own store until the task ends. `sendsKey`: whether it carries the developer key beside the
    /// token; that is the signed config's `flags.model_requests_key_in_background` (true when absent), so that
    /// Quran Lab can make a background transfer carry the short-lived token alone. Requests the app makes itself
    /// always carry both.
    func backgroundRequest(_ url: URL, lower: Int64, upper: Int64, size: Int64? = nil, validator: String?,
                           sendsKey: Bool = true) async -> URLRequest? {
        guard let token = try? await auth.token(false) else { return nil }
        let range = Self.range(lower: lower, upper: upper, size: size)
        return Self.request(url, range: range, key: sendsKey ? auth.key : nil, token: token, ifRange: range == nil ? nil : validator)
    }

    /// The bytes `lower...upper` of a model file, written to `part` as they arrive (`HTTPClient.stream`), with the Range
    /// of `range(lower:upper:size:)` (SDK 4.0.2: none for the whole file, `bytes=N-` to resume), under the rules of
    /// `send`: the key and the token, one renewal on 401 `invalid_token`, no redirect, the gate told of a
    /// refusal and of a served request. `validator` is the ETag of the answer that started the partial file, sent
    /// as `If-Range`: a file that changed on the server then comes whole (a 200) and replaces the partial file.
    /// `hash`: the partial file's SHA-256 as its bytes are written (`HTTPClient.stream`).
    func stream(_ url: URL, lower: Int64, upper: Int64, size: Int64, validator: String?, into part: URL, hash: PartHasher? = nil,
                started: @Sendable (_ headers: [String: String], _ whole: Bool) -> Void,
                received: @Sendable (Int64) -> Void) async throws(CloudError) -> HTTPClient.Streamed {
        let range = Self.range(lower: lower, upper: upper, size: size)
        func request(_ token: String) -> URLRequest {
            Self.request(url, range: range, key: auth.key, token: token, ifRange: range == nil ? nil : validator)
        }
        let token = try await auth.token(false)
        do throws(CloudError) {
            let answer = try await http.stream(request(token), offset: lower, size: size, into: part, hash: hash, started: started, received: received)
            accepted()
            if let p = answer.networkProtocol { protocolSeen(p) }
            return answer
        } catch {
            guard case .rejected(401, "invalid_token", _, let reason) = error, !ModelGate.stops(reason: reason) else {
                refused(error)
                throw error
            }
        }
        let renewed = try await auth.token(true)
        do throws(CloudError) {
            let answer = try await http.stream(request(renewed), offset: lower, size: size, into: part, hash: hash, started: started, received: received)
            accepted()
            if let p = answer.networkProtocol { protocolSeen(p) }
            return answer
        } catch {
            refused(error)
            throw error
        }
    }

    /// SDK 4.0.1 (28.4): the model folder of the lease this install holds for a build, when it holds one: the build's
    /// manifest is read from there, through the `models` hosts. Nil: the folder of the build under `base`.
    var leaseFolder: @Sendable (_ build: String) -> URL? = { _ in nil }

    /// One model request, with the token and the key (`ModelRequestAuthorization.headers`). The SDK has a token
    /// before it asks: without one the request is not made. On 401 `invalid_token` the token is renewed once and the
    /// request repeated once; whatever the repeat answers is the answer. A 401 that names why the key is refused
    /// (a `reason` that stops the model) is not renewed. A redirect is never followed: a model request does not
    /// leave the host it was made to. SDK 4.0.1: the request goes through the `models` hosts (28.3), its own host
    /// first when it is an allowed host that is not one of them (28.4); `accept` says what a 2xx must be.
    func send(_ url: URL, range: String? = nil,
              accept: @escaping @Sendable (HTTPClient.Response) -> Bool = Endpoints.jsonAnswer) async throws(CloudError) -> HTTPClient.Response {
        func request(_ token: String) -> URLRequest {
            Self.request(url, range: range, key: auth.key, token: token)
        }
        let token = try await auth.token(false)
        do throws(CloudError) {
            let answer = try await http.checked(request(token), role: .models, accept: accept)
            accepted()
            if let p = answer.networkProtocol { protocolSeen(p) }
            return answer
        } catch {
            guard case .rejected(401, "invalid_token", _, let reason) = error, !ModelGate.stops(reason: reason) else {
                refused(error)
                throw error
            }
        }
        let renewed = try await auth.token(true)
        do throws(CloudError) {
            let answer = try await http.checked(request(renewed), role: .models, accept: accept)
            accepted()
            if let p = answer.networkProtocol { protocolSeen(p) }
            return answer
        } catch {
            refused(error)
            throw error
        }
    }

    func folderURL(_ id: ModelID, revision: String) -> URL {
        ModelHost.folderURL(base: base, repository: id.repository, revision: revision, folder: id.folder)
    }

    func fileURL(_ id: ModelID, revision: String, path: String) -> URL {
        var u = folderURL(id, revision: revision)
        for part in path.split(separator: "/") { u.appendPathComponent(String(part)) }
        return u
    }

    /// The model's manifest at a build, as SDK 3.0.0 accepts it: its SHA-256 starts with the build the config named
    /// (when `revision` is a build id), it is signed, it has a version and runs on this SDK, and its version is the
    /// one the config named. Its signature covers the size and SHA-256 of every file.
    func manifest(_ id: ModelID, revision: String, version: String? = nil) async throws(RecognizerError) -> ModelManifest {
        let resp: HTTPClient.Response
        let build = revision.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil ? revision : nil
        // 28.4 (4.0.1): no fixed manifest host. The manifest is `<folder>manifest.json` through the `models` hosts: the
        // folder of the lease held for the build when there is one, else the build's folder under `base` (the path
        // every lease names for it; the Core accepts a lease against the signed manifest, so the first lease of a
        // build needs its manifest first). A manifest that does not verify is unreachable on that host (28.3).
        let folder = build.flatMap { leaseFolder($0) }
        let url = folder.map { $0.appendingPathComponent(ModelManifest.fileName) } ?? fileURL(id, revision: revision, path: ModelManifest.fileName)
        let verifier = self.verifier
        do throws(CloudError) {
            resp = try await send(url, accept: { (a: HTTPClient.Response) -> Bool in
                (200..<300).contains(a.status) && (try? ModelManifest.accept(a.body, verifier: verifier, build: build, version: version)) != nil
            })
        } catch {
            if case .rejected(status: 404, _, _, _) = error {
                throw .modelMissing("revision \(revision) of \(id.repository) has no \(id.folder)/\(ModelManifest.fileName) on the CDN")
            }
            throw error.recognizerError
        }
        let m = try ModelManifest.accept(resp.body, verifier: verifier, build: build, version: version)
        guard m.modelID == id.name else { throw .manifestInvalid("the CDN manifest is for \(m.modelID), not \(id.name)") }
        return m
    }

    /// Stored files of one build, by HTTP Range, from `base`: the model folder the build's lease answer named (SDK 4.0,
    /// `ProtectedRuntime.acceptedBase`: https and Quran Lab's own hosts only). There is no other source of files.
    func source(_ id: ModelID, revision: String, base: URL) -> CDNFileSource {
        CDNFileSource(client: self, id: id, revision: revision, base: base,
                      hosts: http.endpoints.flatMap { e in Endpoints.origin(of: base).map { FileHosts(endpoints: e, base: $0) } })
    }
}

struct CDNFileSource: StreamingModelFileSource {
    let client: CDNClient
    let id: ModelID
    let revision: String
    /// The lease answer's model folder.
    let base: URL
    /// SDK 4.0.1 (28.4): the `models` hosts each file is asked of, one per attempt, the next after an attempt that was
    /// unreachable. Nil (a client without the roles' hosts): every attempt goes to the folder's own host, as before.
    var hosts: FileHosts? = nil

    /// A file of the build in the lease answer's model folder (its path; the host is the one the attempt asks, 28.4).
    func url(_ path: String) -> URL {
        var u = base
        for part in path.split(separator: "/") { u.appendPathComponent(String(part)) }
        return u
    }

    /// Where the next attempt of `path` goes, and the `If-Range` it may send: the validator only to the host that
    /// gave it (28.4; a validator stored before 4.0.1 is the folder's own host's).
    func attempt(_ path: String, validator: String?) -> (url: URL, host: String, ifRange: String?) {
        let own = base.host ?? ""
        guard let hosts else { return (url(path), own, HostValidator.etag(validator, for: own, legacyHost: own)) }
        let origin = hosts.host(for: path)
        let host = origin.host ?? own
        return (Endpoints.rehost(url(path), to: origin), host, HostValidator.etag(validator, for: host, legacyHost: own))
    }

    /// One attempt of a range of `path`, written to `part` as it arrives. SDK 4.0.1: on the host `FileHosts` says;
    /// the validator kept is the answer's strong ETag with the host that gave it (`HostValidator`).
    func stream(_ path: String, lower: Int64, upper: Int64, size: Int64, validator: String?, into part: URL, hash: PartHasher?,
                started: @Sendable (_ validator: String?, _ whole: Bool) -> Void,
                received: @Sendable (Int64) -> Void) async throws(RecognizerError) -> StreamedRange {
        let (url, host, ifRange) = attempt(path, validator: validator)
        let keepsHost = hosts != nil
        do throws(CloudError) {
            let answer = try await client.stream(url, lower: lower, upper: upper, size: size, validator: ifRange, into: part, hash: hash,
                                                 started: { headers, whole in
                                                     let etag = Self.strong(HTTPClient.header(headers, "etag"))
                                                     started(keepsHost ? HostValidator.make(host, etag) : etag, whole)
                                                 },
                                                 received: received)
            hosts?.answered(path, .taken)
            if let hosts { RequestTrace.note(.models, fallback: hosts.fellBack) }
            return StreamedRange(whole: answer.whole, written: answer.written)
        } catch {
            guard let hosts else { throw error.recognizerError }
            hosts.failed(path, error)
            // the cause of a download that fails names the files' role and whether a file was asked of more than one
            // host (24.2)
            RequestTrace.note(.models, fallback: hosts.fellBack)
            // 28.3: a redirect and a 4xx that is not the API's are unreachable, resumed on the next host like no answer
            throw FileHosts.resumable(error).recognizerError
        }
    }

    /// The request of one stretch of `path` for a background task: on the host the next attempt of the file asks, with
    /// the validator only when that host gave it.
    func backgroundRequest(_ path: String, lower: Int64, upper: Int64, size: Int64? = nil, validator: String?,
                           sendsKey: Bool) async -> URLRequest? {
        let a = attempt(path, validator: validator)
        return await client.backgroundRequest(a.url, lower: lower, upper: upper, size: size, validator: a.ifRange, sendsKey: sendsKey)
    }

    /// A background round of `path` ended without its next byte: the next attempt goes to the next host (28.4).
    func resumeElsewhere(_ path: String) { hosts?.failed(path, .offline("the background transfer ended without its next byte")) }

    /// An ETag that can stand for the file's bytes: a strong one. A weak one (`W/"..."`) is no validator for a range.
    static func strong(_ etag: String?) -> String? {
        guard let etag, !etag.isEmpty, !etag.hasPrefix("W/") else { return nil }
        return etag
    }

    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
        let resp: HTTPClient.Response
        do throws(CloudError) {
            resp = try await client.send(url(path), range: CDNClient.range(lower: lower, upper: upper, size: size),
                                         accept: { (200..<300).contains($0.status) })
        } catch {
            throw error.recognizerError
        }
        if resp.status == 206 {
            if let cr = resp.header("content-range"), !cr.hasPrefix("bytes \(lower)-\(upper)/") {
                throw .checksumMismatch(file: path + " (wrong range)")
            }
            return resp.body
        }
        // a server that ignores Range sends the whole file
        guard Int64(resp.body.count) == size else { throw .offline("unexpected body for \(path)") }
        return resp.body.subdata(in: Int(lower)..<Int(upper + 1))
    }
}
