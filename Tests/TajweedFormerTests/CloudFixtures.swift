import CryptoKit
import DeviceCheck
import Foundation
import XCTest
@testable import TajweedFormer

/// A URLProtocol that answers from a handler: no request leaves the process.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["content-type": "application/json"]
        var body = Data()
        /// Fail as if offline.
        var offline = false
        /// The answer waits behind this gate: the request stays in flight until the gate opens (an upload the
        /// server has not answered yet), or until its sender cancels it.
        var hold: Gate?

        static func json(_ o: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            var r = Reply(status: status, body: try! JSONSerialization.data(withJSONObject: o))
            r.headers.merge(headers) { _, b in b }
            return r
        }
        static let down = Reply(offline: true)
    }

    /// A gate an answer waits behind. Opening it lets every answer that waits, or comes later, go.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func open() { semaphore.signal() }
        func wait() {
            semaphore.wait()
            semaphore.signal()
        }
    }

    struct Seen: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
        /// When the request reached the stub.
        var at = Date()
        var path: String { url.path }
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    nonisolated(unsafe) static var handler: (@Sendable (Seen) -> Reply)?
    static let log = Locked<[Seen]>([])
    /// The requests their sender cancelled while the answer was held.
    static let cancelled = Locked<[Seen]>([])
    /// This request, while its answer is held.
    private let waiting = Locked<Seen?>(nil)
    /// A slow upload: when this names a gate for a request with a body stream, the server takes the first bytes of
    /// the body at once (the request has started) and the rest only when the gate opens, unless the sender
    /// cancelled the request meanwhile. The handler answers when the whole body is there.
    nonisolated(unsafe) static var slowBody: (@Sendable (URLRequest) -> Gate?)?
    /// The body bytes the server took of slow uploads after their gates opened.
    static let lateBytes = Locked(0)
    /// How much of a slow upload's body the server takes at once.
    static let firstBytes = 4096

    static func reset(_ h: @escaping @Sendable (Seen) -> Reply) {
        handler = h
        log.withLock { $0 = [] }
        cancelled.withLock { $0 = [] }
        slowBody = nil
        lateBytes.withLock { $0 = 0 }
    }

    static var seen: [Seen] { log.withLock { $0 } }
    static func seen(_ path: String) -> [Seen] { seen.filter { $0.path == path } }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let gate = Self.slowBody?(request), let stream = request.httpBodyStream {
            return startSlowly(stream, gate)
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        let seen = Seen(method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: body)
        Self.log.withLock { $0.append(seen) }
        let reply = Self.handler?(seen) ?? Reply(status: 404)
        guard let gate = reply.hold else { return answer(reply) }
        // held: the request is in flight until the gate opens; a sender that cancels it meanwhile gets no answer
        waiting.withLock { $0 = seen }
        DispatchQueue.global().async { [self] in
            gate.wait()
            let still = waiting.withLock { (w: inout Seen?) -> Bool in
                let had = w != nil
                w = nil
                return had
            }
            if still { answer(reply) }
        }
    }

    /// A slow upload (`slowBody`): the first bytes now, the rest when the gate opens.
    private func startSlowly(_ stream: InputStream, _ gate: Gate) {
        stream.open()
        var buf = [UInt8](repeating: 0, count: Self.firstBytes)
        let n = stream.read(&buf, maxLength: buf.count)
        let first = n > 0 ? Data(buf[0..<n]) : Data()
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { a, _ in a }
        let started = Seen(method: method, url: url, headers: headers, body: first)
        Self.log.withLock { $0.append(started) }
        waiting.withLock { $0 = started }
        let rest = UncheckedBox(stream)
        DispatchQueue.global().async { [self] in
            gate.wait()
            // cancelled while the server waited: no more of the body is taken
            let cancelled = waiting.withLock { (w: inout Seen?) -> Bool in w == nil }
            if cancelled {
                rest.value.close()
                return
            }
            var body = first
            var late = 0
            var more = [UInt8](repeating: 0, count: 65_536)
            while rest.value.hasBytesAvailable {
                let k = rest.value.read(&more, maxLength: more.count)
                if k <= 0 { break }
                body.append(more, count: k)
                late += k
            }
            rest.value.close()
            let taken = late
            StubProtocol.lateBytes.withLock { $0 += taken }
            let still = waiting.withLock { (w: inout Seen?) -> Bool in
                let had = w != nil
                w = nil
                return had
            }
            if still { answer(StubProtocol.handler?(Seen(method: method, url: url, headers: headers, body: body)) ?? Reply(status: 404)) }
        }
    }

    private func answer(_ reply: Reply) {
        if reply.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // ended before its held answer came: the sender cancelled it
        let held = waiting.withLock { (w: inout Seen?) -> Seen? in
            let s = w
            w = nil
            return s
        }
        if let held { Self.cancelled.withLock { $0.append(held) } }
    }
}

/// App Attest stand-in. Keys are "fake-key-1", "fake-key-2", ... in the order they are made; an
/// assertion is the key id, its counter and the client data hash, so tests can check what it covers.
struct FakeAttester: AppAttesting {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var made = 0
        var counters: [String: Int] = [:]
        /// Keys that App Attest no longer has (a reinstall, a reset): assertions throw invalidKey.
        var lost: Set<String> = []
        var attestations = 0
        var assertions = 0
        /// Assertions under way at once, and the most seen.
        var concurrent = 0
        var maxConcurrent = 0
        func with<R>(_ body: (State) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(self) }
    }

    var isSupported: Bool
    var state = State()
    /// How long an assertion takes, to let concurrent refreshes overlap.
    var assertionDelay: UInt64 = 0

    func generateKey() async throws -> String {
        state.with { s in s.made += 1; return "fake-key-\(s.made)" }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        state.with { $0.attestations += 1 }
        return Data("attestation-over-".utf8) + clientDataHash
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        let n: Int? = state.with { s in
            if s.lost.contains(keyID) { return nil }
            s.assertions += 1
            s.concurrent += 1
            s.maxConcurrent = max(s.maxConcurrent, s.concurrent)
            s.counters[keyID, default: 0] += 1
            return s.counters[keyID]!
        }
        guard let n else { throw DCError(.invalidKey) }
        if assertionDelay > 0 { try? await Task.sleep(nanoseconds: assertionDelay) }
        state.with { $0.concurrent -= 1 }
        return Data("assertion:\(keyID):\(n):".utf8) + clientDataHash
    }
}

/// The install record's device key, kept in memory: the tests' stand-in for the Keychain (no test touches a real
/// one). `forget()` is a device that has no key (any more); `fail(_:)` a key store that does not answer.
final class MemoryInstallKeyStore: InstallKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    private var failure: String?
    private var counted = (loads: 0, creates: 0)

    init(key: Data? = nil) { self.key = key }

    func load() -> InstallKeyLookup {
        lock.lock()
        defer { lock.unlock() }
        counted.loads += 1
        if let failure { return .failed(failure) }
        return key.map { .key($0) } ?? .none
    }

    func create() -> InstallKeyLookup {
        lock.lock()
        defer { lock.unlock() }
        counted.creates += 1
        if let failure { return .failed(failure) }
        let made = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        key = made
        return .key(made)
    }

    func forget() { lock.lock(); key = nil; lock.unlock() }
    func fail(_ why: String?) { lock.lock(); failure = why; lock.unlock() }
    var hasKey: Bool { lock.lock(); defer { lock.unlock() }; return key != nil }
    var creates: Int { lock.lock(); defer { lock.unlock() }; return counted.creates }
}

/// The Keychain's stand-in: shared by the clouds a test makes, as the Keychain is by an app's launches.
final class MemoryAttestKeyStore: AttestKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func load() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ keyID: String) { lock.lock(); value = keyID; lock.unlock() }
    func delete() { lock.lock(); value = nil; lock.unlock() }
}

enum CloudFixtures {
    static let api = URL(string: "https://api.test")!
    static let cdn = URL(string: "https://cdn.test")!
    static let key = "qlk_v1_test-dev_AAAAAAAAAAAAAAAAAAAAAA"
    static let app = AppIdentity(platform: "ios", bundleID: "com.example.quran", name: "Example", version: "2.1")
    static let signer = Curve25519.Signing.PrivateKey()

    static func storage() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("zf-cloud-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func options(analytics: AnalyticsLevel = .on, updates: UpdatePolicy = .automatic,
                        signingKeys: [Data]? = nil, contributions: Bool = false, storage: URL? = nil,
                        cdnURL: URL? = CloudFixtures.cdn) -> QuranLab.Options {
        QuranLab.Options(modelSource: [.cache], updates: updates, analytics: analytics, storageDirectory: storage,
                         cloud: CloudOptions(apiURL: api, cdnURL: cdnURL,
                                             signingKeys: signingKeys ?? [signer.publicKey.rawRepresentation],
                                             updatesOnWiFiOnly: false,
                                             app: app, urlSession: StubProtocol.session(),
                                             parallelDownloads: 3, rangeSize: 1000),
                         contributions: contributions)
    }

    /// The device key of the install record for every server client these fixtures make: one device for the test
    /// process, so a second Client on the same storage is a relaunch on the same device. A test about another
    /// device, or about a key store that fails, passes its own.
    static let installKeys = MemoryInstallKeyStore()

    static func cloud(storage: URL, options: QuranLab.Options? = nil, attester: any AppAttesting = FakeAttester(isSupported: false),
                      attestKeys: any AttestKeyStoring = MemoryAttestKeyStore(),
                      installKeys: any InstallKeyStoring = CloudFixtures.installKeys,
                      networkAllowed: (@Sendable (Bool) async -> Bool)? = { _ in true },
                      clock: @escaping @Sendable () -> Date = { Date() }) -> QuranLabCloud {
        QuranLabCloud(key: key, options: options ?? Self.options(), storage: storage, attester: attester, attestKeys: attestKeys,
                      installKeys: installKeys, networkAllowed: networkAllowed, clock: clock)
    }

    /// A signed config body and its headers.
    static func config(models: [String: String] = ["Quran-Lab/tajweedformer-v4": "rev-b"],
                       deny: [[String: Any]] = [], flags: [String: Any] = [:], inference: [String: Any]? = nil,
                       recommended: [String: Any]? = nil, base: Any? = nil,
                       expires: Int = Int(Date().timeIntervalSince1970) + 86_400,
                       key: Curve25519.Signing.PrivateKey = signer, extra: [String: Any] = [:]) -> StubProtocol.Reply {
        let now = Int(Date().timeIntervalSince1970)
        var cfg: [String: Any] = [
            "v": 1, "app": "ios:com.example.quran", "channel": "stable", "issued_at": now, "expires_at": expires,
            "models": models.mapValues { ["revision": $0, "version": "4.0.0", "source": "stable"] }, "denylist": deny,
            "flags": (["analytics": true, "issues": true, "contributions": true] as [String: Any]).merging(flags) { _, b in b },
        ]
        if let recommended { cfg["recommended"] = recommended }
        if let base { cfg["base"] = base }
        if let inference { cfg["inference"] = inference }
        for (k, v) in extra { cfg[k] = v }
        let body = try! JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])
        let sig = try! key.signature(for: body)
        let kid = ConfigVerifier.keyID(key.publicKey.rawRepresentation)
        let etag = "\"" + Data(SHA256.hash(data: body).prefix(16)).hex + "\""
        return StubProtocol.Reply(status: 200, headers: ["content-type": "application/json", "etag": etag,
                                                        "x-qlab-signature": "ed25519=" + sig.base64URL, "x-qlab-key-id": kid], body: body)
    }

    /// A verified config already on disk (as after an earlier launch), so a cloud made in `storage` has it in force
    /// at once: since 2.0.1 sharing is offered only where the signed config says so.
    static func seedConfig(storage: URL, flags: [String: Any] = [:]) {
        let r = config(flags: flags)
        let saved = ConfigStore.Saved(body: r.body, signature: r.headers["x-qlab-signature"] ?? "", keyID: r.headers["x-qlab-key-id"], etag: r.headers["etag"])
        JSONFile<ConfigStore.Saved>(url: storage.appendingPathComponent("cloud/config.json")).write(saved)
    }

    static let token: StubProtocol.Reply = .json(["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false])
    static let attestedToken: StubProtocol.Reply = .json(["token": "qlt_v1.eyJ2IjoxfQ.att", "expires_in": 86_400, "attested": true])

    /// The routes of a healthy server.
    static func server(config: StubProtocol.Reply = config(), token: StubProtocol.Reply = token,
                       extra: (@Sendable (StubProtocol.Seen) -> StubProtocol.Reply?)? = nil) -> @Sendable (StubProtocol.Seen) -> StubProtocol.Reply {
        { s in
            if let r = extra?(s) { return r }
            switch s.path {
            case "/v1/attest/challenge": return .json(["challenge": "c1.1790538034.P7cQRSKHbtf5lbPqTWcE6A.3DXJOorkOhcv9Z8sE10upQ", "expires_in": 300])
            case "/v1/attest": return token
            case "/v1/attest/assert": return attestedToken
            case "/v1/register": return .json(["ok": true, "app_id": "ios:com.example.quran", "store_status": "pending"])
            case "/v1/config": return config
            case "/v1/events": return .json(["ok": true, "points": 1], status: 202)
            case "/v1/issues": return .json(["ok": true], status: 202)
            default: return StubProtocol.Reply(status: 404)
            }
        }
    }
}
