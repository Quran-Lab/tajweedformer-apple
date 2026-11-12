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
    static func headers(key: String, token: String) -> [(name: String, value: String)] {
        [(name: "x-qlab-key", value: key), (name: "authorization", value: "Bearer \(token)")]
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

    /// One model request, with the token and the key (`ModelRequestAuthorization.headers`). The SDK has a token
    /// before it asks: without one the request is not made. On 401 `invalid_token` the token is renewed once and the
    /// request repeated once; whatever the repeat answers is the answer. A 401 that names why the key is refused
    /// (a `reason` that stops the model) is not renewed. A redirect is never followed: a model request does not
    /// leave the host it was made to.
    func send(_ url: URL, range: String? = nil) async throws(CloudError) -> HTTPClient.Response {
        func request(_ token: String) -> URLRequest {
            var r = URLRequest(url: url)
            for h in ModelRequestAuthorization.headers(key: auth.key, token: token) { r.setValue(h.value, forHTTPHeaderField: h.name) }
            if let range { r.setValue(range, forHTTPHeaderField: "range") }
            return r
        }
        let token = try await auth.token(false)
        do throws(CloudError) {
            let answer = try await http.checked(request(token), followRedirects: false)
            accepted()
            return answer
        } catch {
            guard case .rejected(401, "invalid_token", _, let reason) = error, !ModelGate.stops(reason: reason) else {
                refused(error)
                throw error
            }
        }
        let renewed = try await auth.token(true)
        do throws(CloudError) {
            let answer = try await http.checked(request(renewed), followRedirects: false)
            accepted()
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

struct CDNFileSource: ModelFileSource {
    let client: CDNClient
    let id: ModelID
    let revision: String

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
