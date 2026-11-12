import Foundation

/// The model files on the CDN: the model's signed `manifest.json` (format 3) and the stored files by HTTP Range, all
/// under the folder URL `ModelHost` builds.
struct CDNClient: Sendable {
    let http: HTTPClient
    let base: URL
    let key: String
    let verifier: ManifestVerifier

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "x-qlab-key")
        return r
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
        do throws(CloudError) { resp = try await http.checked(request(fileURL(id, revision: revision, path: ModelManifest.fileName))) } catch {
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
        var r = URLRequest(url: client.fileURL(id, revision: revision, path: path))
        r.setValue(client.key, forHTTPHeaderField: "x-qlab-key")
        r.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "range")
        let resp: HTTPClient.Response
        do throws(CloudError) { resp = try await client.http.checked(r) } catch { throw error.recognizerError }
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
