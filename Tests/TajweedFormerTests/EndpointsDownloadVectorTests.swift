import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.1, contract section 28.4 (`sdk_4.0.0/ENDPOINTS_40.md`, vectors at 564c144): `endpoints_40.json`'s 13
/// `downloads` replayed through the SDK's real download code, `ModelInstaller` with `CDNFileSource` over `HTTPClient`
/// and the four `models` hosts (as ModelDownloadTests runs one host), each attempt answered by the stand-in server as
/// the vector says. Per case: the hosts asked in order, the `Range` each asks from, the `If-Range` each sends (28.4 and
/// `downloads_if_range`: a value only to the host whose ETag it is; none is always allowed, so where the vector gives a
/// value the SDK sends that value or none, and where it gives null, none), how it ends, what is stored, and `P` after.
///
/// How the vector maps to this SDK: its first request has no Range, this installer asks every range explicitly, so a
/// `range` of null is a request from byte 0 (and the vector's 200 to it is the server's 206 of the whole file to this
/// SDK's request); `bytes=N-` is a request from byte N. An answer that `stall`s is cut after
/// its bytes as one that is `reset` (the same failed attempt after the same bytes; the 30 seconds of 16.2 are not waited
/// here). The pauses of 16.2 are not waited (ModelDownloadTests holds the installer to 1, 2, 4, 8 and 16 s); the count
/// of requests holds it to five resumes.
final class EndpointsDownloadVectorTests: XCTestCase {
    typealias Reply = StubProtocol.Reply
    static let weights = "layers.zfw.qle"
    static let base = URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/")!

    override func tearDown() {
        StubProtocol.reset { _ in .down }
    }

    func testDownloads() async throws {
        let cases = try XCTUnwrap(try EndpointsVectorTests.vectors()["downloads"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 13)
        for c in cases { try await replay(c) }
    }

    /// The vector's answer to one attempt, as the stand-in server sends it for the request `seen`.
    /// `noRange`: the vector's request had no Range. This SDK's has one from byte 0, which a server answers 206 for the
    /// whole file where the vector's request got 200 (the same bytes from byte 0).
    static func reply(_ a: [String: Any], _ seen: StubProtocol.Seen, data: Data, etag: String?, noRange: Bool) -> Reply {
        guard let status = a["status"] as? Int else { return .down }
        var headers = ["content-type": "application/octet-stream"]
        if let etag { headers["etag"] = etag }
        if let ra = a["retry_after"] as? Int { headers["retry-after"] = String(ra) }
        let lower = ModelDownloadTests.range(seen)?.lower ?? 0
        switch a["body"] as? String {
        case "bytes":
            let deliver = a["deliver"] as? Int ?? data.count
            var r: Reply
            if status == 206 || (status == 200 && noRange && lower == 0) {
                headers["content-range"] = "bytes \(lower)-\(data.count - 1)/\(data.count)"
                r = Reply(status: 206, headers: headers, body: data.subdata(in: lower..<data.count))
            } else {
                r = Reply(status: status, headers: headers, body: data)
            }
            if a["end"] as? String != "complete" { r.breakAfter = deliver }
            return r
        case "invalid":
            // a 206 of another total: its range, of a file one byte longer
            headers["content-range"] = "bytes \(lower)-\(data.count - 1)/\(data.count + 1)"
            return Reply(status: status, headers: headers, body: data.subdata(in: lower..<data.count))
        case "json":
            var o: [String: Any] = [:]
            if let e = a["error"] as? String { o["error"] = e }
            return Reply.json(o, status: status, headers: headers.filter { $0.key != "content-type" && $0.key != "etag" })
        case "html":
            return Reply(status: status, headers: ["content-type": "text/html"], body: Data("<html><body>a page</body></html>".utf8))
        default:
            return Reply(status: status, headers: [:], body: Data())
        }
    }

    private func replay(_ c: [String: Any]) async throws {
        let name = c["name"] as? String ?? "?"
        let size = try XCTUnwrap(c["size"] as? Int)
        let etags = try XCTUnwrap(c["etags"] as? [String: String])
        let answers = try XCTUnwrap(c["answers"] as? [[String: Any]])
        let want = try XCTUnwrap(c["requests"] as? [[String: Any]])
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let file = ModelManifest.File(path: Self.weights, size: Int64(size), sha256: Data(SHA256.hash(data: data)).hex, role: "weights",
                                      encoding: "qle1", decoded: .init(path: "layers.zfw", size: Int64(size - 100), sha256: String(repeating: "0", count: 64)))
        let n = Locked(0), held = Handed(answers), wanted = Handed(want)
        StubProtocol.reset { seen in
            guard seen.url.lastPathComponent == Self.weights else { return Reply(status: 404) }
            let i = n.withLock { (k: inout Int) -> Int in defer { k += 1 }; return k }
            guard i < held.value.count else { return .down }
            let noRange = i < wanted.value.count && wanted.value[i]["range"] is NSNull
            return Self.reply(held.value[i], seen, data: data, etag: etags[seen.url.host ?? ""], noRange: noRange)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let endpoints = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models), clock: { now })
        let pBefore = try XCTUnwrap(c["p_before"] as? String)
        endpoints.settle(.models, Endpoints.origin(pBefore), at: now, probe: false)
        let client = CDNClient(http: HTTPClient(session: StubProtocol.session(), endpoints: endpoints), base: ModelHost.defaultBase,
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                               verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        var installer = ModelInstaller(source: client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: Self.base),
                                       rangeSize: 8 << 20, retryPauses: [0, 0, 0, 0, 0])
        let core = ModelDownloadTests.CoreStandIn()
        let folder = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-b")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        installer.install = core.install(in: folder)
        var report = InstallReport()
        var failure: RecognizerError?
        do throws(RecognizerError) { try await installer.ensure(file, in: folder, report: &report) } catch { failure = error }

        let seen = StubProtocol.seen.filter { $0.url.lastPathComponent == Self.weights }
        XCTAssertEqual(seen.map { $0.url.host ?? "" }, want.map { $0["host"] as? String ?? "" }, "\(name): the hosts")
        for (k, (s, w)) in zip(seen, want).enumerated() {
            let from = (w["range"] as? String).flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
            XCTAssertEqual(ModelDownloadTests.range(s)?.lower ?? 0, from, "\(name): request \(k)'s range")
            XCTAssertEqual(s.url.path, Self.base.path + "/" + Self.weights, "\(name): request \(k)'s path, the lease's folder")
            let sent = s.headers["if-range"]
            if let allowed = w["if_range"] as? String {
                XCTAssertTrue(sent == nil || sent == allowed, "\(name): request \(k) sent If-Range \(sent ?? "none"), allowed \(allowed) or none")
            } else {
                XCTAssertNil(sent, "\(name): request \(k) sends no If-Range (the validator goes only to its own host)")
            }
        }
        let end = try XCTUnwrap(c["end"] as? String)
        switch end {
        case "installed":
            XCTAssertNil(failure, "\(name): \(String(describing: failure))")
            XCTAssertEqual(core.installed.withLock { $0 }, [Self.weights], name)
        case "refused":
            XCTAssertEqual(failure.map { ErrorCause.of($0, stage: "download").reason }, "refused", name)
        case "rate_limited":
            XCTAssertEqual(failure.map { ErrorCause.of($0, stage: "download").httpStatus }, 429, name)
        default:
            XCTAssertNotNil(failure, "\(name): \(end)")
            XCTAssertEqual(failure.map { ErrorCause.of($0, stage: "download").reason }, "network", name)
        }
        if (c["stored"] as? Int) == 0 {
            let part = folder.appendingPathComponent(Self.weights + ".part")
            let kept = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
            XCTAssertEqual(kept, 0, "\(name): nothing stored")
        }
        XCTAssertEqual(endpoints.preferred(.models), c["p_after"] as? String, "\(name): P after")
    }
}
