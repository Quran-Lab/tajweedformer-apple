import CryptoKit
import Foundation

/// qlab-cdn: the signed file index (`/manifest.json?repo=`), the model's signed `manifest.json` (format 3), and the
/// stored files by HTTP Range.
struct CDNClient: Sendable {
    let http: HTTPClient
    let cdnURL: URL
    let key: String
    let verifier: ManifestVerifier

    struct IndexEntry: Decodable, Sendable {
        let repo: String
        let revision: String
        let path: String
        let size: Int64?
        let sha256: String?
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(key, forHTTPHeaderField: "x-qlab-key")
        return r
    }

    func fileURL(_ id: ModelID, revision: String, path: String) -> URL {
        var u = cdnURL.appendingPathComponent("hf")
        for part in id.repository.split(separator: "/") { u.appendPathComponent(String(part)) }
        u.appendPathComponent(revision)
        for part in (id.folder + "/" + path).split(separator: "/") { u.appendPathComponent(String(part)) }
        return u
    }

    /// The index entries of one revision, keyed by path inside the model folder. Signed like the config (Ed25519
    /// over the exact body, key id header) and it expires.
    func index(_ id: ModelID, revision: String) async throws(RecognizerError) -> [String: IndexEntry] {
        var c = URLComponents(url: cdnURL.appendingPathComponent("manifest.json"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "repo", value: id.repository)]
        let resp: HTTPClient.Response
        do throws(CloudError) { resp = try await http.checked(request(c.url!)) } catch { throw error.recognizerError }
        guard let sig = resp.header("x-qlab-signature"), sig.hasPrefix("ed25519="),
              let raw = Data(base64URL: String(sig.dropFirst(8))) else { throw .signatureInvalid }
        let kid = resp.header("x-qlab-key-id")
        let ok = verifier.trustedKeys.contains { key in
            (kid == nil || ConfigVerifier.keyID(key) == kid)
                && (try? Curve25519.Signing.PublicKey(rawRepresentation: key))?.isValidSignature(raw, for: resp.body) == true
        }
        guard ok else { throw .signatureInvalid }
        struct Index: Decodable { let files: [String: IndexEntry]; let expires_at: Int? }
        guard let idx = try? JSONDecoder().decode(Index.self, from: resp.body) else { throw .manifestInvalid("the CDN index does not parse") }
        if let e = idx.expires_at, Date(timeIntervalSince1970: TimeInterval(e)) <= Date() {
            throw .manifestInvalid("the CDN index has expired")
        }
        let prefix = id.folder + "/"
        var out: [String: IndexEntry] = [:]
        for e in idx.files.values where e.repo == id.repository && e.revision == revision && e.path.hasPrefix(prefix) {
            out[String(e.path.dropFirst(prefix.count))] = e
        }
        guard out[ModelManifest.fileName] != nil else {
            throw .modelMissing("revision \(revision) of \(id.repository) has no \(id.folder)/\(ModelManifest.fileName) on the CDN")
        }
        return out
    }

    /// The model's manifest at a revision, signature checked (always required from the network) and compatible.
    func manifest(_ id: ModelID, revision: String) async throws(RecognizerError) -> (ModelManifest, [String: IndexEntry]) {
        let entries = try await index(id, revision: revision)
        let resp: HTTPClient.Response
        do throws(CloudError) { resp = try await http.checked(request(fileURL(id, revision: revision, path: ModelManifest.fileName))) } catch {
            throw error.recognizerError
        }
        let m = try ModelManifest.parse(resp.body)
        guard m.modelID == id.name else { throw .manifestInvalid("the CDN manifest is for \(m.modelID), not \(id.name)") }
        try verifier.verifySignature(m, required: true)
        try m.checkCompatible()
        for f in m.files {
            guard let e = entries[f.path] else { continue }
            if let s = e.size, s != f.size { throw .checksumMismatch(file: f.path) }
            if let h = e.sha256, h.count == 64, h.lowercased() != f.sha256 { throw .checksumMismatch(file: f.path) }
        }
        return (m, entries)
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
