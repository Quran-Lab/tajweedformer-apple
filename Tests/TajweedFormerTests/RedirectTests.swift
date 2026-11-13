import Foundation
import Network
import XCTest
@testable import TajweedFormer

/// A small HTTP server on the loopback interface, for the tests of the redirect rule (SPEC 15.4 and 15.5). It
/// keeps of every request the method, the path, the host it was asked as, the NAMES of its headers (never a
/// value) and the size of its body, and answers what the test says.
final class LoopbackServer: @unchecked Sendable {
    struct Got: Sendable {
        let method: String
        let path: String
        let host: String
        /// The names of the request's headers, in lower case, sorted. Names only.
        let headerNames: [String]
        let bodyBytes: Int
    }

    struct Answer: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tests.loopback-server")
    let got = Locked<[Got]>([])
    let answer = Locked<@Sendable (Got) -> Answer>({ _ in Answer(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)) })
    private let bound = Locked<UInt16>(0)

    init() throws { listener = try NWListener(using: .tcp) }

    var port: UInt16 { bound.withLock { $0 } }

    /// Starts listening; false when the listener is not ready within five seconds.
    func start() async -> Bool {
        let ready = Locked(false)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.withLock { $0 = true } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let box = UncheckedBox(connection)
            self?.queue.async { [weak self] in
                box.value.start(queue: self?.queue ?? .global())
                self?.read(box, Data())
            }
        }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if ready.withLock({ $0 }) { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard ready.withLock({ $0 }), let p = listener.port?.rawValue else { return false }
        bound.withLock { $0 = p }
        return true
    }

    func stop() { listener.cancel() }

    /// The head of a request (its first line and its headers) and how many bytes of body it announces; nil for the
    /// body's size when the body is sent in chunks.
    private static func head(_ text: String) -> (first: [Substring], headers: [String: String], length: Int?) {
        let lines = text.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
        return ((lines.first ?? "").split(separator: " "), headers, chunked ? nil : Int(headers["content-length"] ?? "0") ?? 0)
    }

    private func read(_ box: UncheckedBox<NWConnection>, _ soFar: Data) {
        box.value.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            var buffer = soFar
            if let data { buffer.append(data) }
            let ended = done || error != nil
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if ended { box.value.cancel() } else { self?.read(box, buffer) }
                return
            }
            let head = Self.head(String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            let body = buffer.count - end.upperBound
            // the whole body first, so that the sender is not cut in the middle of it
            let whole: Bool
            if let length = head.length {
                whole = body >= length
            } else {
                whole = buffer.suffix(5) == Data("0\r\n\r\n".utf8)
            }
            if !whole, !ended {
                self?.read(box, buffer)
                return
            }
            self?.reply(box, head.first, head.headers, body)
        }
    }

    private func reply(_ box: UncheckedBox<NWConnection>, _ first: [Substring], _ headers: [String: String], _ bodyBytes: Int) {
        let request = Got(method: first.isEmpty ? "" : String(first[0]), path: first.count > 1 ? String(first[1]) : "/",
                          host: headers["host"] ?? "", headerNames: headers.keys.sorted(), bodyBytes: bodyBytes)
        got.withLock { $0.append(request) }
        let a = answer.withLock { $0 }(request)
        var text = "HTTP/1.1 \(a.status) Answer\r\n"
        for (name, value) in a.headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(a.body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(text.utf8)
        response.append(a.body)
        box.value.send(content: response, completion: .contentProcessed { _ in box.value.cancel() })
    }
}

/// No request of the SDK follows a redirect (SPEC 15.4 of contract 1.17.0; the test of 15.5), on the REAL
/// URLSession, not on the suite's stub of the transport: the SDK's own session (`HTTPClient.makeSession()`), and
/// two servers on the loopback interface. The first answers every request with a redirect (302, then 307) whose
/// Location names the second, which is reached by another host name of the same machine. For each kind of request
/// the SDK makes: the second server is never asked, the first is asked once, and the call fails.
/// Each case prints one line that starts with "REDIRECT-MEASURE:": whether the second host was asked, and for a
/// request that reached it the method, the size of the body and the NAMES of the headers it carried (no values).
/// What this does not show: a phone, a cellular network, or the background sessions (the background upload has its
/// own test).
final class RedirectTests: XCTestCase {
    static let key = CloudFixtures.key
    static let token = "qlt_v1.eyJ2IjoxfQ.sig"

    struct Pair {
        let first: LoopbackServer
        let second: LoopbackServer
        /// The first server's address, as the SDK is given it.
        let base: URL

        func stop() {
            first.stop()
            second.stop()
        }
    }

    /// The two servers: the first answers every request with `status` and the same path on the second.
    static func pair(_ status: Int) async throws -> Pair {
        let first = try LoopbackServer(), second = try LoopbackServer()
        let up = await first.start(), alsoUp = await second.start()
        guard up, alsoUp else { throw XCTSkip("a loopback server did not start") }
        let target = second.port
        first.answer.withLock { $0 = { got in LoopbackServer.Answer(status: status, headers: ["Location": "http://localhost:\(target)\(got.path)"]) } }
        return Pair(first: first, second: second, base: try XCTUnwrap(URL(string: "http://127.0.0.1:\(first.port)")))
    }

    /// What the two servers saw of one request, said and checked.
    static func check(_ what: String, _ status: Int, _ pair: Pair, failed: Bool) {
        let second = pair.second.got.withLock { $0 }
        let reached = second.map { "[\($0.method) as \($0.host.components(separatedBy: ":").first ?? ""), body \($0.bodyBytes) bytes, header names: \($0.headerNames.joined(separator: ", "))]" }
        print("REDIRECT-MEASURE: \(what), HTTP \(status): the second host was asked \(second.count) time(s) \(reached.joined(separator: " "))")
        XCTAssertTrue(second.isEmpty, "\(what), HTTP \(status): the redirect was followed (\(second.count) request(s) reached the second host)")
        XCTAssertEqual(pair.first.got.withLock { $0.count }, 1, "\(what), HTTP \(status): the first host is asked once")
        XCTAssertTrue(failed, "\(what), HTTP \(status): a redirect is a failed request")
    }

    static func http() -> HTTPClient { HTTPClient(session: HTTPClient.makeSession()) }

    /// A model request: the key and the token in its headers.
    func testAModelRequestIsNotRedirected() async throws {
        for status in [302, 307] {
            let pair = try await Self.pair(status)
            defer { pair.stop() }
            let client = CDNClient(http: Self.http(), base: pair.base, auth: .fixed(key: Self.key, token: Self.token),
                                   verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
            var failed = false
            do { _ = try await client.send(client.fileURL(.v4_0, revision: String(repeating: "a", count: 40), path: "manifest.json")) } catch { failed = true }
            Self.check("a model request", status, pair, failed: failed)
        }
    }

    /// The call that carries the developer key in a header: the token request (`POST /v1/attest`).
    func testTheCallThatCarriesTheKeyIsNotRedirected() async throws {
        for status in [302, 307] {
            let pair = try await Self.pair(status)
            defer { pair.stop() }
            let tokens = TokenProvider(http: Self.http(), apiURL: pair.base, key: Self.key, app: CloudFixtures.app, teamID: nil,
                                       attester: FakeAttester(isSupported: false), attestKeys: MemoryAttestKeyStore(), storage: CloudFixtures.storage())
            var failed = false
            do { _ = try await tokens.token() } catch { failed = true }
            Self.check("the token request (the key)", status, pair, failed: failed)
        }
    }

    /// A call that carries the install's token: the config (`GET /v1/config`).
    func testACallThatCarriesTheTokenIsNotRedirected() async throws {
        for status in [302, 307] {
            let pair = try await Self.pair(status)
            defer { pair.stop() }
            let config = ConfigStore(storage: CloudFixtures.storage(), trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation])
            var failed = false
            do { _ = try await config.fetch(http: Self.http(), apiURL: pair.base, token: Self.token) } catch { failed = true }
            Self.check("the config request (the token)", status, pair, failed: failed)
        }
    }

    /// The start of a shared recording's upload (`POST /v1/uploads`: the token, the recording's id, a body), sent
    /// as the upload queue sends it.
    func testASharingStartIsNotRedirected() async throws {
        for status in [302, 307] {
            let pair = try await Self.pair(status)
            defer { pair.stop() }
            let http = Self.http()
            let request = ContributionClient(http: http, apiURL: pair.base)
                .startRequest(id: String(repeating: "c", count: 32), session: Data("{\"test\":true}".utf8), token: Self.token)
            var failed = false
            do { _ = try await http.send(request) } catch { failed = true }
            Self.check("a sharing start", status, pair, failed: failed)
        }
    }

    /// A segment's PUT to its signed URL as it runs in the app (no key, no token; the body is read from the
    /// segment's file as a stream, as the upload queue does).
    func testASegmentUploadInTheAppIsNotRedirected() async throws {
        for status in [302, 307] {
            let pair = try await Self.pair(status)
            defer { pair.stop() }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("redirect-test-\(UUID().uuidString).opus")
            let body = Data((0..<2000).map { UInt8($0 % 251) })
            try body.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let url = ContributionClient.SegmentURL(n: 1, url: pair.base.appendingPathComponent("recordings/test/seg-000001.opus"),
                                                    expiresAt: Date().addingTimeInterval(3600))
            var request = ContributionClient.putRequest(url, contentType: "audio/ogg", bytes: Int64(body.count))
            request.httpBodyStream = InputStream(url: file)
            var failed = false
            do { _ = try await Self.http().send(request) } catch { failed = true }
            Self.check("a segment upload in the app", status, pair, failed: failed)
        }
    }
}
