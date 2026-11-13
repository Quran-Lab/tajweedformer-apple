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

    /// The headers of a model request: the manifest, every file, every Range request.
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
    /// `ifRange`: the validator of the partial file a range continues (`If-Range`). `unmeteredOnly`: the request of
    /// an update or of the accelerator's build, which waits for an unmetered network: the system then refuses to
    /// send it over a cellular network, a personal hotspot or a network in Low Data Mode, for as long as it runs.
    static func request(_ url: URL, range: String?, key: String?, token: String, ifRange: String? = nil,
                        unmeteredOnly: Bool = false) -> URLRequest {
        var r = URLRequest(url: url)
        for h in ModelRequestAuthorization.headers(key: key, token: token) { r.setValue(h.value, forHTTPHeaderField: h.name) }
        if let range { r.setValue(range, forHTTPHeaderField: "range") }
        if let ifRange { r.setValue(ifRange, forHTTPHeaderField: "if-range") }
        r.assumesHTTP3Capable = true
        if unmeteredOnly {
            r.allowsExpensiveNetworkAccess = false
            r.allowsConstrainedNetworkAccess = false
        }
        return r
    }

    /// The requests of this client wait for an unmetered network (an update, the accelerator's build). A first
    /// install goes on any network. Stricter than to 3.1.1 on purpose: the network was read once when an update
    /// started, and an update that began on Wi-Fi and lost it went on over a metered network; now it stops there
    /// and goes on when the device is on an unmetered network again.
    var unmeteredOnly = false
    /// The same, asked while the install runs: `client.prefetch(unmeteredOnly:)` wants its download on unmetered
    /// networks only, so its requests carry the system's marks and the system holds to it for the whole download
    /// (3.1.5; before, the connection was read once when the call started).
    var alsoUnmetered: @Sendable () -> Bool = { false }
    private var waitsForUnmetered: Bool { unmeteredOnly || alsoUnmetered() }

    /// The request of one range for a background task: the install's token as it is now (asked for as for any
    /// model request; nil when none can be had), the range, the validator and the mark of a request that waits
    /// for an unmetered network. A background task keeps the request it was made with, and the system keeps that
    /// request in its own store until the task ends. `sendsKey`: whether it carries the developer key beside the
    /// token; that is the signed config's `flags.model_requests_key_in_background` (true when absent), so that
    /// Quran Lab can make a background transfer carry the short-lived token alone. Requests the app makes itself
    /// always carry both.
    func backgroundRequest(_ url: URL, lower: Int64, upper: Int64, validator: String?, sendsKey: Bool = true) async -> URLRequest? {
        guard let token = try? await auth.token(false) else { return nil }
        return Self.request(url, range: "bytes=\(lower)-\(upper)", key: sendsKey ? auth.key : nil, token: token, ifRange: validator,
                            unmeteredOnly: waitsForUnmetered)
    }

    /// The bytes `lower...upper` of a model file, written to `part` as they arrive (`HTTPClient.stream`), under the
    /// rules of `send`: the key and the token, one renewal on 401 `invalid_token`, no redirect, the gate told of a
    /// refusal and of a served request. `validator` is the ETag of the answer that started the partial file, sent
    /// as `If-Range`: a file that changed on the server then comes whole (a 200) and replaces the partial file.
    func stream(_ url: URL, lower: Int64, upper: Int64, size: Int64, validator: String?, into part: URL,
                started: @Sendable (_ headers: [String: String], _ whole: Bool) -> Void,
                received: @Sendable (Int64) -> Void) async throws(CloudError) -> HTTPClient.Streamed {
        func request(_ token: String) -> URLRequest {
            Self.request(url, range: "bytes=\(lower)-\(upper)", key: auth.key, token: token, ifRange: validator, unmeteredOnly: waitsForUnmetered)
        }
        let token = try await auth.token(false)
        do throws(CloudError) {
            let answer = try await http.stream(request(token), offset: lower, size: size, into: part, started: started, received: received)
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
            let answer = try await http.stream(request(renewed), offset: lower, size: size, into: part, started: started, received: received)
            accepted()
            if let p = answer.networkProtocol { protocolSeen(p) }
            return answer
        } catch {
            refused(error)
            throw error
        }
    }

    /// One model request, with the token and the key (`ModelRequestAuthorization.headers`). The SDK has a token
    /// before it asks: without one the request is not made. On 401 `invalid_token` the token is renewed once and the
    /// request repeated once; whatever the repeat answers is the answer. A 401 that names why the key is refused
    /// (a `reason` that stops the model) is not renewed. A redirect is never followed: a model request does not
    /// leave the host it was made to.
    func send(_ url: URL, range: String? = nil) async throws(CloudError) -> HTTPClient.Response {
        func request(_ token: String) -> URLRequest {
            Self.request(url, range: range, key: auth.key, token: token, unmeteredOnly: waitsForUnmetered)
        }
        let token = try await auth.token(false)
        do throws(CloudError) {
            let answer = try await http.checked(request(token))
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
            let answer = try await http.checked(request(renewed))
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
        do throws(CloudError) { resp = try await send(fileURL(id, revision: revision, path: ModelManifest.fileName)) } catch {
            if case .rejected(status: 404, _, _, _) = error {
                throw .modelMissing("revision \(revision) of \(id.repository) has no \(id.folder)/\(ModelManifest.fileName) on the CDN")
            }
            throw error.recognizerError
        }
        let build = revision.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil ? revision : nil
        let m = try ModelManifest.accept(resp.body, verifier: verifier, build: build, version: version)
        guard m.modelID == id.name else { throw .manifestInvalid("the CDN manifest is for \(m.modelID), not \(id.name)") }
        return m
    }

    /// Stored files of one revision, by HTTP Range.
    func source(_ id: ModelID, revision: String) -> CDNFileSource { CDNFileSource(client: self, id: id, revision: revision) }
}

struct CDNFileSource: StreamingModelFileSource {
    let client: CDNClient
    let id: ModelID
    let revision: String

    func stream(_ path: String, lower: Int64, upper: Int64, size: Int64, validator: String?, into part: URL,
                started: @Sendable (_ validator: String?, _ whole: Bool) -> Void,
                received: @Sendable (Int64) -> Void) async throws(RecognizerError) -> StreamedRange {
        do throws(CloudError) {
            let answer = try await client.stream(client.fileURL(id, revision: revision, path: path), lower: lower, upper: upper,
                                                 size: size, validator: validator, into: part,
                                                 started: { headers, whole in started(Self.strong(HTTPClient.header(headers, "etag")), whole) },
                                                 received: received)
            return StreamedRange(whole: answer.whole, written: answer.written)
        } catch {
            throw error.recognizerError
        }
    }

    /// An ETag that can stand for the file's bytes: a strong one. A weak one (`W/"..."`) is no validator for a range.
    static func strong(_ etag: String?) -> String? {
        guard let etag, !etag.isEmpty, !etag.hasPrefix("W/") else { return nil }
        return etag
    }

    func bytes(_ path: String, lower: Int64, upper: Int64, size: Int64) async throws(RecognizerError) -> Data {
        let resp: HTTPClient.Response
        do throws(CloudError) {
            resp = try await client.send(client.fileURL(id, revision: revision, path: path), range: "bytes=\(lower)-\(upper)")
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
