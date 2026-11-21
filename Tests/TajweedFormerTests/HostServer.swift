import Foundation
import Network
import XCTest
@testable import TajweedFormer

/// An HTTP/1.1 server on 127.0.0.1 standing for one Quran Lab host, for the tests that need real sockets: URLSession connects to it, sends its request and reads
/// the answer as from any server. Each request is answered by the handler: an answer, a connection closed with no answer
/// (`close`), or nothing at all until the test ends (`hold`). A stopped server's port refuses connections.
/// One request per connection (`Connection: close`).
final class HostServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    enum Reply: Sendable {
        case answer(status: Int, headers: [String: String], body: Data)
        /// The connection is closed with no answer (as a host that resets it).
        case close
        /// No byte comes back (a host that is silent).
        case hold

        static func json(_ o: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var h = headers
            h["content-type"] = "application/json"
            return .answer(status: status, headers: h, body: (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
        }
    }

    let name: String
    private let listener: NWListener
    private let queue: DispatchQueue
    private(set) var port: UInt16 = 0
    private let held = Locked<[NWConnection]>([])
    let log = Locked<[Request]>([])
    let handler: Locked<@Sendable (Request) -> Reply>

    /// The server's origin, `http://127.0.0.1:<port>`.
    var origin: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(_ name: String, handler: @escaping @Sendable (Request) -> Reply = { _ in .answer(status: 404, headers: [:], body: Data()) }) throws {
        self.name = name
        self.handler = Locked(handler)
        queue = DispatchQueue(label: "loopback-\(name)")
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { stop() }

    /// Stops listening and drops every held connection: the port refuses connections from now on.
    func stop() {
        listener.cancel()
        held.withLock { $0.forEach { $0.cancel() }; $0 = [] }
    }

    func reset(_ h: @escaping @Sendable (Request) -> Reply) {
        handler.withLock { $0 = h }
        log.withLock { $0 = [] }
    }

    var paths: [String] { log.withLock { $0.map(\.path) } }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    /// Reads until the headers and the body named by Content-Length are in, then answers.
    private func read(_ c: NWConnection, _ have: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = have
            if let data { buf.append(data) }
            if let request = Self.parse(buf) {
                self.respond(c, request)
            } else if done || error != nil {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private static func parse(_ buf: Data) -> Request? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[end.upperBound...]
        guard body.count >= length else { return nil }
        let path = String(first[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return Request(method: String(first[0]), path: path, headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ c: NWConnection, _ r: Request) {
        log.withLock { $0.append(r) }
        switch handler.withLock({ $0 })(r) {
        case .close:
            c.cancel()
        case .hold:
            held.withLock { $0.append(c) }
        case .answer(let status, let headers, let body):
            var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
            var h = headers
            h["content-length"] = String(body.count)
            h["connection"] = "close"
            for (k, v) in h { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}

/// A URLSession of its own for a test that talks to loopback servers (no cache, no cookies).
enum HostSession {
    static func make() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }
}

final class HostServerTests: XCTestCase {
    /// The harness itself: URLSession reaches the server over http on 127.0.0.1, and a stopped server refuses.
    func testTheHostServerAnswersAndAStoppedOneRefuses() async throws {
        let a = try HostServer("a") { _ in .json(["ok": true]) }
        let (data, response) = try await HostSession.make().data(from: a.origin.appendingPathComponent("v1/ping"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertEqual(a.paths, ["/v1/ping"])
        let dead = try HostServer("dead")
        let url = dead.origin
        dead.stop()
        do {
            _ = try await HostSession.make().data(from: url.appendingPathComponent("x"))
            XCTFail("a stopped server refuses")
        } catch {}
    }
}
