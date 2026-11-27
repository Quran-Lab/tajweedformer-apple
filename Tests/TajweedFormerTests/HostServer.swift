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
        /// SDK 4.0.5: the answer's body goes out at the pace every pacer allows (a host's rate, the phone's link shared by
        /// all hosts), 16 KiB at a time, each piece sent before the next is taken (so a slow reader slows the server).
        case paced(status: Int, headers: [String: String], body: Data, pacers: [Pacer])
        /// SDK 4.0.5: the head names the whole body's length, then only `sent` bytes of it go and the connection closes.
        case truncated(status: Int, headers: [String: String], body: Data, sent: Int)

        static func json(_ o: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var h = headers
            h["content-type"] = "application/json"
            return .answer(status: status, headers: h, body: (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
        }
    }

    let name: String
    /// SDK 4.0.5: each paced answer's Range and the body bytes the server sent of it (its sends that completed).
    final class Sent: @unchecked Sendable {
        let range: String?
        let ifRange: String?
        let at: Date
        let bytes = Locked(0)
        let ended = Locked(false)
        init(range: String?, ifRange: String?) {
            self.range = range
            self.ifRange = ifRange
            at = Date()
        }
    }
    let sent = Locked<[Sent]>([])
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
        case .paced(let status, let headers, let body, let pacers):
            let record = Sent(range: r.headers["range"], ifRange: r.headers["if-range"])
            sent.withLock { $0.append(record) }
            // a thread of its own, never the shared global queue: with that queue's 64 threads parked by whatever else
            // runs in the process, a paced answer never sent its head (SplitHookTests, the full runs of 2026-11-23 from
            // 17:06 to 19:02: every request silent for 10 s)
            let thread = Thread { Self.pace(c, status: status, headers: headers, body: body, pacers: pacers, record: record) }
            thread.name = "loopback-\(name)-paced"
            thread.start()
        case .truncated(let status, let headers, let body, let sent):
            var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
            var h = headers
            h["content-length"] = String(body.count)
            h["connection"] = "close"
            for (k, v) in h { head += "\(k): \(v)\r\n" }
            head += "\r\n"
            c.send(content: Data(head.utf8) + body.prefix(sent), completion: .contentProcessed { _ in c.cancel() })
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

extension HostServer {
    /// Sends a paced answer on its own thread: the head, then the body as the pacers allow; it stops when the client has
    /// closed the connection.
    static func pace(_ c: NWConnection, status: Int, headers: [String: String], body: Data, pacers: [Pacer], record: Sent) {
        let closed = Locked(false)
        @Sendable func watch() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, done, error in
                if done || error != nil { closed.withLock { $0 = true } } else { watch() }
            }
        }
        watch()
        func send(_ d: Data) -> Bool {
            let sem = DispatchSemaphore(value: 0)
            let failed = Locked(false)
            c.send(content: d, completion: .contentProcessed { e in
                if e != nil { failed.withLock { $0 = true } }
                sem.signal()
            })
            while sem.wait(timeout: .now() + 0.05) == .timedOut {
                if closed.withLock({ $0 }) { return false }
            }
            return !failed.withLock { $0 }
        }
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        var h = headers
        h["content-length"] = String(body.count)
        h["connection"] = "close"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        defer {
            record.ended.withLock { $0 = true }
            c.cancel()
        }
        guard send(Data(head.utf8)) else { return }
        var off = 0
        while off < body.count {
            if closed.withLock({ $0 }) { return }
            var n = min(16_384, body.count - off)
            for p in pacers { n = p.take(n, closed: closed) }
            if n == 0 { return }
            guard send(body.subdata(in: off..<(off + n))) else { return }
            record.bytes.withLock { $0 += n }
            off += n
        }
    }

    /// A model file as a host serves it: a 206 for a `Range: bytes=N-` or `bytes=N-M` (the 200 of the whole file when
    /// `ignoreRange`), with an ETag, at the pacers' pace.
    static func file(_ r: Request, data: Data, etag: String? = "\"split-1\"", pacers: [Pacer], ignoreRange: Bool = false) -> Reply {
        var headers = ["content-type": "application/octet-stream", "accept-ranges": "bytes"]
        if let etag { headers["etag"] = etag }
        if !ignoreRange, let range = r.headers["range"], range.hasPrefix("bytes=") {
            let ends = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if ends.count == 2, let lo = Int(ends[0]), lo < data.count {
                let hi = min(data.count - 1, Int(ends[1]) ?? (data.count - 1))
                headers["content-range"] = "bytes \(lo)-\(hi)/\(data.count)"
                return .paced(status: 206, headers: headers, body: data.subdata(in: lo..<(hi + 1)), pacers: pacers)
            }
        }
        return .paced(status: 200, headers: headers, body: data, pacers: pacers)
    }
}

/// SDK 4.0.5: a rate shared by paced answers (a token bucket of bytes a second; 0: no limit), with windows of seconds
/// since it was made in which nothing goes (a stall).
final class Pacer: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Int
    private var tokens: Double = 0
    private var last = Date()
    private let born = Date()
    private var stalls: [(from: Double, to: Double)]

    init(_ rate: Int, stalls: [(from: Double, to: Double)] = []) {
        self.rate = rate
        self.stalls = stalls
    }

    func set(rate r: Int) { lock.withLock { rate = r } }

    /// Waits until some of `want` bytes may go; how many (0 when the connection closed meanwhile).
    func take(_ want: Int, closed: Locked<Bool>) -> Int {
        while true {
            if closed.withLock({ $0 }) { return 0 }
            lock.lock()
            let now = Date()
            let t = now.timeIntervalSince(born)
            let stalled = stalls.contains { $0.from <= t && t < $0.to }
            if stalled {
                last = now
                tokens = 0
            } else if rate <= 0 {
                lock.unlock()
                return want
            } else {
                tokens = min(Double(max(rate / 20, 16_384)), tokens + now.timeIntervalSince(last) * Double(rate))
                last = now
                if tokens >= 1 {
                    let n = Int(min(Double(want), tokens))
                    tokens -= Double(n)
                    lock.unlock()
                    return n
                }
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: stalled ? 0.02 : 0.004)
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

    /// Parks every thread the shared global queue may have (64 on macOS), as blocking waits that never end park them;
    /// `body` runs meanwhile, and the threads are let go after it.
    static func withTheSharedPoolParked<T>(_ body: () async throws -> T) async rethrows -> T {
        let release = DispatchSemaphore(value: 0)
        let parked = Locked(0)
        let n = 80
        for _ in 0..<n {
            DispatchQueue.global().async {
                parked.withLock { $0 += 1 }
                release.wait()
            }
        }
        for _ in 0..<50 where parked.withLock({ $0 }) < 64 { try? await Task.sleep(nanoseconds: 20_000_000) }
        defer { for _ in 0..<n { release.signal() } }
        return try await body()
    }

    /// SDK 4.0.5: a paced answer goes out with the shared global queue's threads all parked. In the full runs of
    /// 2026-11-23 from 17:06 to 19:02 every paced answer of SplitHookTests waited for a thread of that queue and never
    /// sent its head (each request silent for 10 s, each test 70 s); with the pool parked by hand the same happens
    /// (the requests reach the server, none is answered). A paced answer now has a thread of its own.
    func testAPacedAnswerGoesOutWhileTheSharedPoolIsParked() async throws {
        let body = Data(repeating: 7, count: 1 << 20)
        let s = try HostServer("paced") { _ in .paced(status: 200, headers: [:], body: body, pacers: []) }
        var request = URLRequest(url: s.origin.appendingPathComponent("file"))
        request.timeoutInterval = 5
        let (data, response) = try await Self.withTheSharedPoolParked {
            try await HostSession.make().data(for: request)
        }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, body)
    }

    /// SDK 4.0.5: held answers of the stub park no thread. Seventy requests wait behind a gate (each on a host of its
    /// own, so no limit of connections per host holds any back); meanwhile work sent to the shared global queue still
    /// runs, and when the gate opens every request is answered.
    func testHeldStubAnswersParkNoThread() async throws {
        let gate = StubProtocol.Gate()
        StubProtocol.reset { _ in var r = StubProtocol.Reply.json(["ok": true]); r.hold = gate; return r }
        defer { StubProtocol.reset { _ in .down } }
        let session = StubProtocol.session()
        let n = 70
        let calls = (0..<n).map { i in
            Task { () -> Int? in
                let r = try? await session.data(from: URL(string: "https://h\(i).example/held")!)
                return (r?.1 as? HTTPURLResponse)?.statusCode
            }
        }
        for _ in 0..<250 where StubProtocol.seen.count < n { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(StubProtocol.seen.count, n, "every request reached the stub and waits")
        let ran = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { ran.signal() }
        XCTAssertEqual(ran.wait(timeout: .now() + 2), .success, "the shared global queue still runs work while the answers are held")
        gate.open()
        var answered = 0
        for c in calls {
            if await c.value == 200 { answered += 1 }
        }
        XCTAssertEqual(answered, n)
    }
}
