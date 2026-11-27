// Debug builds only: the tests name hosts through StagingHooks.hostOrigins, which a release build does not have.
#if DEBUG
import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.1, contract 28.5 and 28.8 on REAL sockets: four `api` hosts stood in by loopback servers (`HostServer`,
/// named by the debug-only `StagingHooks.hostOrigins`, so the SDK's built-in list of names is what is asked), the
/// SDK's own HTTP client and lease route, and the Core's test release (lease.json's lease for manifest_40.json's
/// build, as ProtectedCoreTests): `endpoints_40.json`'s `attempts` replayed request by request, check 3 (the grace
/// across hosts), the largest Retry-After across hosts, and the cause of a lease request naming its role and fallback.
/// Needs the test release (4.0.0-c1); with a real release linked these tests skip.
final class LeaseFailoverTests: XCTestCase {
    typealias P = ProtectedCoreTests
    static let names = ["api.quranlab.ai", "api-b.tajweedformer.com", "api-g.tajweedformer.com", "api-a.tajweedformer.com"]

    override func tearDown() {
        StagingHooks.hostOrigins.withLock { $0 = [:] }
    }

    /// The four hosts, the runtime over them, and every request in the order it arrived (host name, route).
    final class Rig: @unchecked Sendable {
        /// Per route, the answers of its requests in order: each step answers `count` host requests of the route (a
        /// request through the order asks one host after another), the last step answers the rest. A host a step does
        /// not name closes the connection (no answer).
        struct Step: @unchecked Sendable {
            let answers: [String: HostServer.Reply]
            let count: Int
        }

        var servers: [String: HostServer] = [:]
        var runtime: ProtectedRuntime!
        /// The Core's saved state of the rig's folder (a runtime made on it in a test shares the Core's lease).
        var state: P.MemoryState!
        let manifest: ModelManifest
        let clocks: P.MovingClocks
        let answer: [String: Any]
        let lease: Data
        let key: SoftwareInstallKey
        let signer: (public: Data, private: Curve25519.Signing.PrivateKey)
        let log = Locked<[(host: String, route: String, body: [String: Any]?)]>([])
        let script = Locked<[String: [Step]]>([:])
        let stops = Locked(0)
        /// SDK 4.0.2 (a rig made with `holds`): the HTTP client's clock, which the hosts' Retry-After holds go by, and a
        /// new process on the same storage (a runtime over a new HTTP client that reads the holds back).
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        var restart: (() -> ProtectedRuntime)?
        /// Called with each request's route as a host gets it, before it answers (on the host's thread).
        let onRequest = Locked<(@Sendable (String) -> Void)?>(nil)

        init(manifest: ModelManifest, clocks: P.MovingClocks, answer: [String: Any], lease: Data, key: SoftwareInstallKey,
             signer: (public: Data, private: Curve25519.Signing.PrivateKey)) {
            self.manifest = manifest
            self.clocks = clocks
            self.answer = answer
            self.lease = lease
            self.key = key
            self.signer = signer
        }

        func stop() { servers.values.forEach { $0.stop() } }

        /// Hosts that give no answer at all: their servers stop, so a connection to them is refused. (A server that
        /// accepts and closes is asked again by the system: URLSession repeats a request whose connection was lost
        /// before any answer, up to three times.)
        func refuse(_ hosts: [String]) { hosts.forEach { servers[$0]?.stop() } }

        /// One answer set per route for every request.
        func serve(_ routes: [String: [String: HostServer.Reply]]) {
            script.withLock { $0 = routes.mapValues { [Step(answers: $0, count: Int.max)] } }
        }

        /// The answer to the `n`-th host request of `route` (from 0), on `host`.
        func answer(_ route: String, _ n: Int, _ host: String) -> HostServer.Reply {
            let steps = script.withLock { $0[route] } ?? []
            var cum = 0
            for st in steps {
                cum = st.count == Int.max ? Int.max : cum + st.count
                if n < cum { return st.answers[host] ?? .close }
            }
            return steps.last?.answers[host] ?? .close
        }

        /// The requests of `route` (all of them when nil), by host, in order.
        func asked(_ route: String? = nil) -> [String] { log.withLock { $0.filter { route == nil || $0.route == route }.map(\.host) } }
        func clear() { log.withLock { $0 = [] } }

        /// The JSON of a route's answer: a challenge, the lease answer (the lease made unreadable for the Core when
        /// `core` is refused), a token; else the refusal's error and reason (signed for this request when `core` is
        /// stop).
        func json(_ route: String, _ a: [String: Any]) -> [String: Any] {
            if let e = a["error"] as? String {
                var o: [String: Any] = ["error": e, "message": "stand-in"]
                if let r = a["reason"] as? String { o["reason"] = r }
                if a["core"] as? String == "stop" { o["signed"] = signedStop(reason: a["reason"] as? String ?? "key_revoked") }
                return o
            }
            switch route {
            case "challenge": return ["challenge": P.challenge, "expires_in": 300]
            case "model-key":
                var o = answer
                if a["core"] as? String == "refused" {
                    var bad = lease
                    bad[bad.count / 2] ^= 0x5a
                    o["lease"] = bad.base64URL
                }
                return o
            default: return ["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false]
            }
        }

        /// A stop signed by the contract's test signer for this install and challenge (refusal_signed.json's form).
        func signedStop(reason: String) -> String {
            let text = "quranlab-refusal 1\napps-one\n\(reason)\n\(key.installHash)\n\(P.challenge)\n\(clocks.wallMs() / 1000)\n"
            let sig = (try? signer.private.signature(for: Data(text.utf8))) ?? Data()
            return Data(text.utf8).base64URL + "." + sig.base64URL
        }

        /// A vector answer (endpoints_40.json `answers_are`) as the loopback server sends it.
        func reply(_ route: String, _ a: [String: Any]) -> HostServer.Reply {
            if let none = a["answer"] as? String { return none == "stalled" ? .hold : .close }
            let status = a["status"] as? Int ?? 200
            var headers: [String: String] = [:]
            if let ra = a["retry_after"] as? Int { headers["retry-after"] = String(ra) }
            switch a["body"] as? String {
            case "json": return .json(json(route, a), status: status, headers: headers)
            case "html": return .answer(status: status, headers: ["content-type": "text/html"], body: Data("<html>a page</html>".utf8))
            default: return .answer(status: status, headers: headers, body: Data())
            }
        }
    }

    static func route(_ path: String) -> String {
        if path.hasSuffix("/v1/attest/challenge") { return "challenge" }
        if path.hasSuffix("/v1/model-key") { return "model-key" }
        if path.hasSuffix("/v1/attest") { return "attest" }
        return path
    }

    /// The rig: four loopback servers named as the built-in api hosts, the SDK's HTTP client over them, a runtime on
    /// the Core's test release. The install starts with its certificate (the vectors' attempts do); a new one (after
    /// install_cert_invalid) and a renewed token ask `POST /v1/attest` through the api order, as the Client's token
    /// provider does (the vector's `attest` and `token` routes).
    func rig(holds: Bool = false, owed: Locked<Bool>? = nil) throws -> Rig {
        guard CoreHost.version.hasPrefix("4.0.0-c1 ") else {
            throw XCTSkip("the linked Core is \(CoreHost.version), not the test release 4.0.0-c1")
        }
        let lv = try V40.json("lease.json")
        let signer = try V40.signer(lv)
        let ecdh = try XCTUnwrap(lv["install_ecdh"] as? [String: Any])
        let key = try XCTUnwrap(SoftwareInstallKey(der: try XCTUnwrap(Data(base64URL: try XCTUnwrap(ecdh["pkcs8_b64u"] as? String)))))
        let accept = try XCTUnwrap((lv["accept"] as? [[String: Any]])?.first)
        let lease = V40.hex(try XCTUnwrap(accept["lease_hex"] as? String))
        let fields = try XCTUnwrap(accept["fields"] as? [String: Any])
        let now = Int64(try XCTUnwrap(lv["now"] as? Int))
        let cert = try P.certificate(for: key, signer: signer.private, now: now, validity: 30 * 86_400)
        var m = try ModelManifest.parse(try V40.manifest().data)
        m.sha256 = try XCTUnwrap(lv["build"] as? String) + String(repeating: "0", count: 24)
        let answer: [String: Any] = ["v": 1, "lease": lease.base64URL, "iat": fields["iat"]!, "exp": fields["exp"]!,
                                     "refresh_after": fields["refresh_after"]!,
                                     "base": "https://cdn-b.tajweedformer.com/models/Quran-Lab/m/b/sdk/v4.0/", "install_cert": cert]
        let clocks = P.MovingClocks(wallS: now)
        let rig = Rig(manifest: m, clocks: clocks, answer: answer, lease: lease, key: key, signer: signer)
        for name in Self.names {
            rig.servers[name] = try HostServer(name) { [weak rig] r in
                guard let rig else { return .close }
                let route = Self.route(r.path)
                let n = rig.log.withLock { (l: inout [(host: String, route: String, body: [String: Any]?)]) -> Int in
                    defer { l.append((name, route, r.json)) }
                    return l.filter { $0.route == route }.count
                }
                rig.onRequest.withLock { $0 }?(route)
                return rig.answer(route, n, name)
            }
        }
        let map = rig.servers.mapValues(\.origin)
        StagingHooks.hostOrigins.withLock { $0 = map }
        let storage = Fixtures.storage()
        let state = P.MemoryState()
        let holdsFile = holds ? storage.appendingPathComponent("cloud/retry-after.json") : nil
        let testNow = rig.now
        let httpClock: @Sendable () -> Date = { holds ? testNow.withLock { $0 } : Date() }
        let makeHTTP = { () -> HTTPClient in
            HTTPClient(session: HostSession.make(),
                       endpoints: EndpointSet(api: EndpointSet.builtInOrigins(.api), models: [URL(string: "https://cdn.test")!],
                                              clock: httpClock, holdsFile: holdsFile))
        }
        let http = makeHTTP()
        let apiURL = try XCTUnwrap(rig.servers[Self.names[0]]).origin
        let certified = Locked(0)
        var server = LeaseServer(transport: http, apiURL: apiURL, key: "qlk_v1_apps-one_sig", platform: "ios",
                                 token: { (renew: Bool) async throws(CloudError) -> String in
                                     if renew { _ = try await http.send(URLRequest(url: apiURL.appendingPathComponent("v1/attest"))) }
                                     return "qlt_test"
                                 },
                                 certify: { (_: any InstallKey) async throws(CloudError) -> String in
                                     let again = certified.withLock { (n: inout Int) -> Bool in
                                         defer { n += 1 }
                                         return n > 0
                                     }
                                     if again { _ = try await http.send(URLRequest(url: apiURL.appendingPathComponent("v1/attest"))) }
                                     // an attestation owed (40.2): the certificate's attestation pays it
                                     owed?.withLock { $0 = false }
                                     return cert
                                 },
                                 trustedKeys: [signer.public])
        if let owed {
            server.attestationOwedAndDue = { _ in owed.withLock { $0 } }
            server.attestationOwed = { owed.withLock { $0 } }
        }
        rig.runtime = ProtectedRuntime(storage: storage, server: server, keys: P.FixedKeys(key), state: state, clocks: clocks)
        rig.state = state
        rig.restart = {
            let next = LeaseServer(transport: makeHTTP(), apiURL: server.apiURL, key: server.key, platform: server.platform,
                                   token: server.token, certify: server.certify, trustedKeys: server.trustedKeys)
            return ProtectedRuntime(storage: storage, server: next, keys: P.FixedKeys(key), state: state, clocks: clocks)
        }
        rig.runtime.onStop = { @Sendable [weak rig] _ in rig?.stops.withLock { $0 += 1 } }
        return rig
    }

    /// The healthy first host: a challenge, a lease, a token.
    static func healthy(_ rig: Rig, on host: String = names[0]) -> [String: [String: HostServer.Reply]] {
        ["challenge": [host: rig.reply("challenge", ["status": 200, "body": "json"])],
         "model-key": [host: rig.reply("model-key", ["status": 200, "body": "json", "core": "accepted"])],
         "attest": [host: rig.reply("attest", ["status": 200, "body": "json"])]]
    }

    // MARK: endpoints_40.json attempts

    func testTheAttempts() async throws {
        let cases = try XCTUnwrap(try EndpointsVectorTests.vectors()["attempts"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 10)
        for c in cases { try await replay(c) }
    }

    private func replay(_ c: [String: Any]) async throws {
        let name = c["name"] as? String ?? "?"
        let rig = try rig()
        defer { rig.stop() }
        let requests = try XCTUnwrap(c["requests"] as? [[String: Any]])
        // each request of the vector is one step of its route: the answers of the hosts it asked (a repeat of a route,
        // after invalid_token or install_cert_invalid, is that route's next step)
        var script: [String: [Rig.Step]] = [:]
        var want: [String] = []
        for r in requests {
            let given = try XCTUnwrap(r["route"] as? String)
            let route = given == "token" ? "attest" : given
            let answers = try XCTUnwrap(r["answers"] as? [String: [String: Any]]).mapValues { rig.reply(route, $0) }
            let asked = try XCTUnwrap(r["asked"] as? [String])
            script[route, default: []].append(Rig.Step(answers: answers, count: asked.count))
            want += asked.map { "\($0) \(route)" }
        }
        rig.script.withLock { $0 = script }
        // a host whose every answer in the attempt is none refuses the connection
        let all = requests.compactMap { $0["answers"] as? [String: [String: Any]] }
        let silent = Self.names.filter { h in
            let given = all.compactMap { $0[h] }
            return !given.isEmpty && given.allSatisfy { $0["answer"] as? String == "none" }
        }
        rig.refuse(silent)
        // a refused connection reaches no server: those hosts' requests are not in the servers' log
        want = want.filter { w in !silent.contains { w.hasPrefix($0 + " ") } }
        var failure: RecognizerError?
        do throws(RecognizerError) { _ = try await rig.runtime.ensureLease(rig.manifest) } catch { failure = error }

        let got = rig.log.withLock { $0.map { "\($0.host) \($0.route)" } }
        XCTAssertEqual(got, want, "\(name): the requests, host by host")
        switch try XCTUnwrap(c["outcome"] as? String) {
        case "lease":
            XCTAssertNil(failure, "\(name): \(String(describing: failure))")
            XCTAssertTrue(rig.runtime.hasValidLease(build: rig.manifest.build), name)
        case "refused":
            guard case .serverRejected = failure else { return XCTFail("\(name): a refusal, got \(String(describing: failure))") }
            XCTAssertFalse(rig.runtime.hasValidLease(build: rig.manifest.build), name)
        case "stop":
            XCTAssertNotNil(failure, name)
            XCTAssertEqual(rig.stops.withLock { $0 }, 1, "\(name): a stop the Core verified")
        default:
            guard case .offline = failure else { return XCTFail("\(name): unreachable, got \(String(describing: failure))") }
            if let ra = c["retry_after"] as? Int {
                // 18.4.7.3 (SDK 4.0.2): the Retry-After is the floor of a wait drawn from 600 to 1800 s
                let wait = rig.runtime.retryState.notBefore - rig.clocks.wallMs() / 1000
                XCTAssertTrue((max(600, Int64(ra))...max(1800, Int64(ra))).contains(wait), "\(name): the next attempt waits \(wait) s, at least \(ra)")
            }
        }
        // a lease request goes to every host with the challenge it was asked with (28.5)
        let challenges = Set(rig.log.withLock { $0.filter { $0.route == "model-key" }.compactMap { $0.body?["challenge"] as? String } })
        XCTAssertLessThanOrEqual(challenges.count, 1, "\(name): one challenge across hosts")
    }

    // MARK: 28.8 check 3, the grace across hosts

    /// A rig whose lease was given by the first host and has expired an hour ago.
    func expired() async throws -> Rig {
        let rig = try rig()
        rig.serve(Self.healthy(rig))
        _ = try await rig.runtime.ensureLease(rig.manifest)
        let st = rig.runtime.status()
        rig.clocks.advance(seconds: st.expiresAt - st.now + 3600)
        rig.clear()
        return rig
    }

    /// An expired lease opens in its grace only when every host was unreachable, or a 429 ended the attempt; a
    /// refusal from any host ends it.
    func testTheGraceAcrossHosts() async throws {
        // every host unreachable (a refused connection, a 503, a firewall's page, a refused connection): the grace
        let down = try await expired()
        defer { down.stop() }
        down.refuse([Self.names[0], Self.names[3]])
        down.serve(["challenge": [Self.names[1]: .json(["error": "service_unavailable"], status: 503),
                                  Self.names[2]: .answer(status: 403, headers: ["content-type": "text/html"], body: Data("<html/>".utf8))]])
        let r = try await down.runtime.ensureLease(down.manifest)
        XCTAssertEqual(r.build, down.manifest.build)
        XCTAssertTrue(try XCTUnwrap(try down.runtime.host()).leaseGrace().inGrace, "every host unreachable: the grace")
        XCTAssertEqual(down.asked("challenge"), [Self.names[1], Self.names[2]], "every host asked (the first and the fourth refused)")

        // the first host down, the second refuses: the attempt's refusal, no grace, the third never asked
        let refusing = try await expired()
        defer { refusing.stop() }
        refusing.refuse([Self.names[0]])
        refusing.serve(["challenge": [Self.names[1]: refusing.reply("challenge", ["status": 200, "body": "json"])],
                        "model-key": [Self.names[1]: .json(["error": "lease_attestation_required", "message": "no"], status: 403)]])
        do {
            _ = try await refusing.runtime.ensureLease(refusing.manifest)
            XCTFail("a refusal from the second host ends the grace")
        } catch {}
        XCTAssertFalse(try XCTUnwrap(try refusing.runtime.host()).leaseGrace().inGrace)
        XCTAssertEqual(refusing.asked("model-key"), [Self.names[1]], "the refusal is the answer: no third host")

        // a 429 on the first host: no other host is asked, and the grace opens (a slow down never locks a learner out)
        let slow = try await expired()
        defer { slow.stop() }
        slow.serve(["challenge": [Self.names[0]: .json(["error": "rate_limited"], status: 429, headers: ["retry-after": "60"])]])
        _ = try await slow.runtime.ensureLease(slow.manifest)
        XCTAssertTrue(try XCTUnwrap(try slow.runtime.host()).leaseGrace().inGrace, "a 429: the grace")
        XCTAssertEqual(slow.asked(), [Self.names[0]], "a 429 is never taken to another host")
    }

    /// 28.7, the report of an open in grace (E6 found it without the two fields): lease, grace, host_role api, and
    /// fallback true when the attempt asked more than one host (every host unreachable), false when only the first was
    /// asked (a 429 is never taken to another host).
    func testTheGraceReportNamesItsRoleAndFallback() async throws {
        let down = try await expired()
        defer { down.stop() }
        let silent = Locked<[ErrorCause]>([])
        down.runtime.onSilent = { @Sendable c in silent.withLock { $0.append(c) } }
        down.refuse(Self.names)
        _ = try await down.runtime.ensureLease(down.manifest)
        XCTAssertTrue(try XCTUnwrap(try down.runtime.host()).leaseGrace().inGrace)
        let g = try XCTUnwrap(silent.withLock { $0 }.last { $0.reason == "grace" }, "\(silent.withLock { $0 })")
        XCTAssertEqual([g.stage, g.errorCode ?? "-", g.hostRole ?? "-", g.fallback.map { $0 ? "true" : "false" } ?? "-"],
                       ["lease", "network", "api", "true"])

        let slow = try await expired()
        defer { slow.stop() }
        let slowSilent = Locked<[ErrorCause]>([])
        slow.runtime.onSilent = { @Sendable c in slowSilent.withLock { $0.append(c) } }
        slow.serve(["challenge": [Self.names[0]: .json(["error": "rate_limited"], status: 429, headers: ["retry-after": "60"])]])
        _ = try await slow.runtime.ensureLease(slow.manifest)
        let s = try XCTUnwrap(slowSilent.withLock { $0 }.last { $0.reason == "grace" }, "\(slowSilent.withLock { $0 })")
        XCTAssertEqual([s.hostRole ?? "-", s.fallback.map { $0 ? "true" : "false" } ?? "-"], ["api", "false"])
    }

    // MARK: SDK 4.0.5, contract ATTEST_40.md 40.5 and 40.6 (UNTESTED on the Mac when written, 11-25)

    /// Every api host answers 200 with a lease the Core refuses (the 2026-11-24 reports, "lease, expired, -5", had no
    /// more than that): each host is asked (28.5), and the cause names the check the Core's refusal is (not the status),
    /// reason invalid_answer, status 200, role api, fallback true, and a chain with one hop per host (first, then the
    /// standbys, never a name). The app's code is download_failed: an answer is never needs_connection (24.4 rule 2).
    /// SDK 4.0.5 (ATTEST_40.md 40.2 item 4): no model on the device yet, the app asked for one that did not come, an
    /// attestation owed: the network coming back attests and leases in the background, with no call of the app, for the
    /// build the config names (its manifest found with no model file). Before the app asked for a model, nothing goes out.
    func testTheNetworkBackLeasesBeforeAnyModelIsOnTheDevice() async throws {
        let owed = Locked(true)
        let rig = try rig(owed: owed)
        defer { rig.stop() }
        AttestPolicy.timeScale.withLock { $0 = 0.001 }
        defer { AttestPolicy.timeScale.withLock { $0 = 1 } }
        rig.serve(Self.healthy(rig))
        let m = rig.manifest
        let found = Locked(0)
        rig.runtime.leaseManifest = { found.withLock { $0 += 1 }; return m }
        // the app has not asked for a model in this process: nothing is asked
        rig.runtime.attestIfOwed(nil, networkBack: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(found.withLock { $0 }, 0)
        XCTAssertEqual(rig.asked(), [], "nothing before the app asked for a model")
        // the app asked (its model() failed with no network); the network comes back
        rig.runtime.modelWanted()
        rig.runtime.networkBack()
        let t0 = Date()
        while !rig.runtime.status().valid, Date().timeIntervalSince(t0) < 20 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(rig.runtime.status().valid, "the lease came by itself")
        XCTAssertFalse(owed.withLock { $0 }, "the attestation was made")
        XCTAssertEqual(found.withLock { $0 }, 1, "the manifest was found once")
        XCTAssertEqual(rig.asked("model-key"), [Self.names[0]])
        XCTAssertEqual(Set(rig.log.withLock { $0 }.map(\.route)).subtracting(["challenge", "model-key", "attest"]), [], "no model file")
        // nothing more is owed: the next network back asks nothing
        let before = rig.asked().count
        rig.runtime.attestIfOwed(nil, networkBack: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.asked().count, before)
    }

    /// SDK 4.0.5: a background try that finds no manifest (no config yet, the CDN unreachable) waits 30 s, doubling,
    /// before the next of the minute's timer; the network coming back does not wait.
    func testABackgroundTryWithNoManifestWaitsBeforeTheNext() async throws {
        let owed = Locked(true)
        let rig = try rig(owed: owed)
        defer { rig.stop() }
        rig.serve(Self.healthy(rig))
        let found = Locked(0)
        rig.runtime.leaseManifest = { found.withLock { $0 += 1 }; return nil }
        rig.runtime.modelWanted()
        rig.runtime.attestIfOwed(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        rig.runtime.attestIfOwed(nil)
        rig.runtime.attestIfOwed(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(found.withLock { $0 }, 1, "the timer's tries wait 30 s after one that found none")
        rig.runtime.attestIfOwed(nil, networkBack: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(found.withLock { $0 }, 2, "the network coming back tries at once")
        XCTAssertEqual(rig.asked(), [], "no lease without a manifest")
    }

    func testALeaseEveryHostGaveAndTheCoreRefusedNamesItsCheckAndItsHops() async throws {
        let rig = try rig()
        defer { rig.stop() }
        rig.serve(["challenge": [Self.names[0]: rig.reply("challenge", ["status": 200, "body": "json"])],
                   "model-key": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, rig.reply("model-key", ["status": 200, "body": "json", "core": "refused"])) })])
        do {
            _ = try await rig.runtime.ensureLease(rig.manifest)
            XCTFail("no lease the Core takes")
        } catch {}
        XCTAssertEqual(rig.asked("model-key"), Self.names, "every host asked")
        let c = try XCTUnwrap(rig.runtime.lastFailure.withLock { $0 }?.cause)
        XCTAssertEqual([c.stage, c.reason, c.hostRole ?? "-"], ["lease", "invalid_answer", "api"])
        XCTAssertEqual(c.httpStatus, 200)
        XCTAssertEqual(c.fallback, true)
        let check = try XCTUnwrap(c.errorCode)
        XCTAssertTrue(AnswerCheck.isCheck(check) && !check.hasPrefix("-"), check)
        let hops = try XCTUnwrap(c.chain).filter { $0.stage == "lease" && $0.reason == "invalid_answer" }
        XCTAssertEqual(hops.map { $0.host ?? "-" }, ["first", "standby", "standby", "standby"])
        XCTAssertTrue(hops.allSatisfy { $0.errorCode == check && $0.httpStatus == 200 })
        XCTAssertEqual(ErrorRules.modelCallCode(c, onDevice: .complete), "download_failed")
        // diagnose() names it too
        let d = rig.runtime.diagnosis()
        XCTAssertEqual(d.lastFailure?.errorCode, check)
        XCTAssertEqual(d.lastFailure?.chain.count, 4)
    }

    // MARK: SDK 4.0.5, contract ATTEST_40.md 40.2 item 10 (UNTESTED on the Mac when written, 11-25)

    /// Two install keys: the rig's (generation 1) and the next one (2), current once promoted.
    final class TwoKeys: InstallKeySource, @unchecked Sendable {
        let first: any InstallKey, second: any InstallKey
        let promoted = Locked(false)
        init(_ first: any InstallKey, _ second: any InstallKey) { self.first = first; self.second = second }
        func current() -> (any InstallKey)? { promoted.withLock { $0 } ? second : first }
        var generation: Int { promoted.withLock { $0 } ? 2 : 1 }
        func makeNext() -> (key: any InstallKey, generation: Int)? { (second, 2) }
        func promote(_ key: any InstallKey, generation: Int) { if generation == 2 { promoted.withLock { $0 = true } } }
        func discard(generation: Int) {}
    }

    /// An App Attest certificate for `key`, signed by the contract's test signer.
    static func attestedCertificate(for key: any InstallKey, signer: Curve25519.Signing.PrivateKey, now: Int64) throws -> String {
        let text = "quranlab-install-cert 1\napp ios:ai.quranlab.sdk.tests\nplatform ios\nkey apps-one\ninstall \(key.installHash)\n"
            + "sign \(Data(SHA256.hash(data: key.spki)).hex)\natt apple\nhw 1\niat \(now - 100)\nexp \(now + 30 * 86_400)\nrecheck 0\nbatch -\ndigest -\n"
        return Data(text.utf8).base64URL + "." + (try signer.signature(for: Data(text.utf8))).base64URL
    }

    /// The upgrade of a capped install (an app whose lease needs no attestation): the attestation succeeds, the full lease
    /// does not come (503 on every api host). The capped lease, its certificate and its key stay in force and keep the
    /// model's lease valid; the full lease was asked with the NEXT key; the keys are not switched; the next try reuses the
    /// attested certificate (no second attestation) and the attestation is owed again for a restart.
    func testAnUpgradeWhoseFullLeaseFailsKeepsTheCappedLease() async throws {
        let rig = try rig()
        defer { rig.stop() }
        rig.serve(Self.healthy(rig))
        _ = try await rig.runtime.ensureLease(rig.manifest)
        XCTAssertTrue(rig.runtime.hasValidLease(build: rig.manifest.build))
        let next = SoftwareInstallKey(P256.KeyAgreement.PrivateKey())
        let keys = TwoKeys(rig.key, next)
        let attested = try Self.attestedCertificate(for: next, signer: rig.signer.private, now: rig.clocks.wallMs() / 1000)
        let asked = Locked(0), owedAgain = Locked<[Int]>([])
        var server = try XCTUnwrap(rig.runtime.server)
        server.attestRequired = { false }
        server.upgrade = { (_: any InstallKey) async throws(CloudError) -> String in
            asked.withLock { $0 += 1 }
            return attested
        }
        server.oweAttestationAfter = { (s: Int) in owedAgain.withLock { $0.append(s) } }
        let runtime = ProtectedRuntime(storage: rig.runtime.storage, server: server, keys: keys, state: rig.state, clocks: rig.clocks)
        rig.clear()
        rig.serve(["challenge": [Self.names[0]: rig.reply("challenge", ["status": 200, "body": "json"])],
                   "model-key": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, HostServer.Reply.json(["error": "service_unavailable"], status: 503)) })])
        for round in 1...2 {
            do {
                _ = try await runtime.upgradeLease(rig.manifest, server)
                XCTFail("round \(round): no full lease")
            } catch {}
            XCTAssertFalse(keys.promoted.withLock { $0 }, "round \(round): the keys are not switched")
            XCTAssertTrue(runtime.hasValidLease(build: rig.manifest.build), "round \(round): the capped lease is still in force")
            XCTAssertTrue(runtime.leaseCanOpen(), "round \(round): the model still opens")
        }
        let sent = rig.log.withLock { $0.filter { $0.route == "model-key" }.compactMap { $0.body?["install_key"] as? String } }
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(sent.allSatisfy { $0 == next.spki.base64URL }, "the full lease is asked with the next key")
        XCTAssertEqual(asked.withLock { $0 }, 1, "the next try reuses the attested certificate")
        XCTAssertEqual(owedAgain.withLock { $0.count }, 2, "owed again after each failed try")
        XCTAssertEqual(runtime.retryState, LeaseRetry(), "the capped lease's own row does not move")
    }

    /// 40.2 item 10 and Core c3's counter (CoreStateGate): while an upgrade try asks the full lease, the capped Core
    /// writes nothing (its ticks during the request, two per request here, are held back), so the try's Core, made when
    /// the try began, can never save below the counter. The try fails on every host: the held saves are written, the
    /// gate is open again, and a Core made from the saved state over the capped key (a restart) holds the capped lease.
    func testTheCappedCoreSavesNothingDuringAnUpgradeTryAndWritesItsSavesAfterIt() async throws {
        let rig = try rig()
        defer { rig.stop() }
        rig.serve(Self.healthy(rig))
        _ = try await rig.runtime.ensureLease(rig.manifest)
        let next = SoftwareInstallKey(P256.KeyAgreement.PrivateKey())
        let keys = TwoKeys(rig.key, next)
        let attested = try Self.attestedCertificate(for: next, signer: rig.signer.private, now: rig.clocks.wallMs() / 1000)
        var server = try XCTUnwrap(rig.runtime.server)
        server.attestRequired = { false }
        server.upgrade = { (_: any InstallKey) async throws(CloudError) -> String in attested }
        server.oweAttestationAfter = { (_: Int) in }
        let runtime = ProtectedRuntime(storage: rig.runtime.storage, server: server, keys: keys, state: rig.state, clocks: rig.clocks)
        _ = rig.runtime.status()
        let before = rig.state.counter()
        let during = Locked<[UInt64]>([])
        let capped = rig.runtime!, state = rig.state!
        rig.onRequest.withLock {
            $0 = { (route: String) in
                guard route == "model-key" else { return }
                XCTAssertTrue(capped.status().valid, "the capped lease is in force during the try")
                _ = capped.status()
                during.withLock { $0.append(state.counter()) }
            }
        }
        rig.clear()
        rig.serve(["challenge": [Self.names[0]: rig.reply("challenge", ["status": 200, "body": "json"])],
                   "model-key": Dictionary(uniqueKeysWithValues: Self.names.map { ($0, HostServer.Reply.json(["error": "service_unavailable"], status: 503)) })])
        do {
            _ = try await runtime.upgradeLease(rig.manifest, server)
            XCTFail("no full lease")
        } catch {}
        rig.onRequest.withLock { $0 = nil }
        let seen = during.withLock { $0 }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { $0 == before }, "the capped Core wrote nothing during the try: \(seen), before \(before)")
        let after = rig.state.counter()
        XCTAssertGreaterThan(after, before, "its saves held back are written when the try ends without a switch")
        _ = rig.runtime.status()
        XCTAssertGreaterThan(rig.state.counter(), after, "the gate is open again")
        XCTAssertFalse(keys.promoted.withLock { $0 })
        let restarted = try CoreHost(platform: CorePlatform(storage: CoreStorage(root: rig.runtime.storage), key: rig.key, state: rig.state,
                                                            clocks: rig.clocks))
        let s = restarted.tick()
        XCTAssertTrue(s.hasLease && s.valid, "a restart finds the capped lease")
    }

    // MARK: 28.8 check 6, a lease whose base names a backup model host

    /// The first api host refuses connections; the second gives a lease the Core accepts, whose `base` names the
    /// backup model host cdn-b. The build's files come from that folder through the models order (cdn.quranlab.ai
    /// refuses, cdn-b serves, by Range), and the Core installs each one to its device form. The lease's folder is
    /// what the manifest is read from (`leaseFolder`). Not shown here: the manifest from that folder verified end to
    /// end (the vector build's manifest is not signed for its test build id; a real backup host serving a real build
    /// is Part 9's end-to-end run).
    func testALeaseFromABackupHostNamesItsModelFolderAndTheFilesComeFromIt() async throws {
        let rig = try rig()
        defer { rig.stop() }
        let v = try V40.json("manifest_40.json")
        let containers = try XCTUnwrap(v["containers_hex"] as? [String: String]).mapValues { V40.hex($0) }
        let folderPath = "/models/Quran-Lab/m/b/sdk/v4.0/"
        var cdns: [String: HostServer] = [:]
        for name in ["cdn.quranlab.ai", "cdn-b.tajweedformer.com", "cdn-g.tajweedformer.com", "cdn-a.tajweedformer.com"] {
            cdns[name] = try HostServer(name) { r in
                guard r.path.hasPrefix(folderPath), let bytes = containers[String(r.path.dropFirst(folderPath.count))] else {
                    return .answer(status: 404, headers: [:], body: Data())
                }
                guard let range = r.headers["range"], range.hasPrefix("bytes=") else {
                    return .answer(status: 200, headers: ["etag": "\"b-1\""], body: bytes)
                }
                let parts = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                let lower = parts.first ?? 0, upper = min(parts.count > 1 ? parts[1] : bytes.count - 1, bytes.count - 1)
                return .answer(status: 206, headers: ["etag": "\"b-1\"", "content-range": "bytes \(lower)-\(upper)/\(bytes.count)"],
                               body: bytes.subdata(in: lower..<(upper + 1)))
            }
        }
        defer { cdns.values.forEach { $0.stop() } }
        let cdnMap = cdns.mapValues(\.origin)
        StagingHooks.hostOrigins.withLock { $0.merge(cdnMap) { _, new in new } }
        cdns["cdn.quranlab.ai"]?.stop()
        rig.refuse([Self.names[0]])
        rig.serve(Self.healthy(rig, on: Self.names[1]))
        let models = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models))
        let client = CDNClient(http: HTTPClient(session: HostSession.make(), endpoints: models), base: ModelHost.defaultBase,
                               auth: .fixed(key: "qlk_v1_apps-one_sig", token: "qlt_test"),
                               verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        let source = try await ModelUpdater.leasedSource(client, rig.runtime, rig.manifest, id: ModelID("v4.0", repository: "Quran-Lab/m"),
                                                          revision: rig.manifest.build)
        XCTAssertEqual(rig.asked("model-key"), [Self.names[1]], "the lease from the backup api host")
        XCTAssertEqual(source.base.host, "cdn-b.tajweedformer.com")
        XCTAssertEqual(rig.runtime.leaseFolder(rig.manifest.build)?.absoluteString, "https://cdn-b.tajweedformer.com" + folderPath,
                       "the build's manifest is read from the lease's folder")
        let dir = Fixtures.storage().appendingPathComponent("models/v4.0/\(rig.manifest.build)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var installer = ModelInstaller(source: source, retryPauses: [0, 0, 0, 0, 0])
        let runtime = rig.runtime!, manifest = rig.manifest
        installer.install = EncryptedInstall { (f: ModelManifest.File) throws(RecognizerError) in
            try runtime.install(manifest, decodedPath: f.localPath, in: dir)
        }
        let encrypted = manifest.files.filter { $0.isEncrypted && containers[$0.path] != nil && !$0.path.hasPrefix("npu/") && !$0.path.hasPrefix("coreml/") }
        XCTAssertFalse(encrypted.isEmpty)
        for f in encrypted {
            var report = InstallReport()
            try await installer.ensure(f, in: dir, report: &report)
            XCTAssertTrue(ModelInstaller.present(f, in: dir), "\(f.path): installed by the Core from the backup host's folder")
        }
        let served = try XCTUnwrap(cdns["cdn-b.tajweedformer.com"]).paths
        XCTAssertEqual(Set(served), Set(encrypted.map { folderPath + $0.path }), "every file from cdn-b, the lease's folder")
        XCTAssertEqual(models.order(.models, at: Date()).hosts.first, cdns["cdn-b.tajweedformer.com"]?.origin, "cdn-b answered: it is P")
    }

    // MARK: 28.11, the lease route held by a Retry-After (SDK 4.0.2)

    /// 28.11 item 6 and 18.4.7.3 item 4 (dd76474): a 429 with Retry-After 90 on the lease route asks no other host;
    /// for 90 s a call with no lease fails as that answer did and sends nothing (no challenge either), in this process
    /// and in a new one started 10 s after the 429; then one request, and a lease. The held calls move no retry wait.
    func testA429OnTheLeaseRouteHoldsItAcrossARestart() async throws {
        let rig = try rig(holds: true)
        defer { rig.stop() }
        rig.serve([
            "challenge": [Self.names[0]: rig.reply("challenge", ["status": 200, "body": "json"])],
            "model-key": [Self.names[0]: .json(["error": "rate_limited", "message": "too many requests, retry later"], status: 429,
                                               headers: ["retry-after": "90"])],
        ])
        let manifest = rig.manifest
        let call = { (r: ProtectedRuntime) async -> String? in
            do throws(RecognizerError) {
                _ = try await r.ensureLease(manifest)
                return nil
            } catch {
                return TajweedError(from: error).code
            }
        }
        let advance = { (s: TimeInterval) in rig.now.withLock { $0 = $0.addingTimeInterval(s) } }
        let first = await call(rig.runtime)
        XCTAssertNotNil(first)
        XCTAssertEqual(rig.asked("model-key"), [Self.names[0]], "a 429 asks no other host")
        let row = rig.runtime.retryState
        XCTAssertEqual(row.failures, 1)
        rig.clear()
        advance(5)
        let held = await call(rig.runtime)
        XCTAssertEqual(held, first, "the call fails as the 429 did")
        XCTAssertEqual(rig.asked(), [], "and sends nothing")
        XCTAssertEqual(rig.runtime.retryState, row, "a held call is no failed attempt")
        advance(5)
        let again = try XCTUnwrap(rig.restart?())
        XCTAssertEqual(again.retryState, row, "the new process reads the row back")
        let afterRestart = await call(again)
        XCTAssertEqual(afterRestart, first)
        advance(79)
        let last = await call(again)
        XCTAssertEqual(last, first)
        XCTAssertEqual(rig.asked(), [], "the new process sends nothing on the route for the remaining 80 s")
        rig.serve(Self.healthy(rig))
        advance(1)
        let ok = await call(again)
        XCTAssertNil(ok, "after the Retry-After one request, and a lease")
        XCTAssertEqual(rig.asked("model-key"), [Self.names[0]])
        XCTAssertEqual(again.retryState, LeaseRetry(), "the lease ends the row")
    }

    // MARK: 28.5's Retry-After, and the cause of a lease request (24.2)

    /// The lease request unreachable on every host: the next attempt waits at least the largest Retry-After any host gave
    /// (2400, not the first host's 30; 18.4.7.3: the floor of the drawn wait), and the failure's cause is the first
    /// host's answer with host_role api and fallback.
    func testTheLargestRetryAfterAndTheCauseOfALeaseRequest() async throws {
        let rig = try rig()
        defer { rig.stop() }
        rig.serve([
            "challenge": [Self.names[0]: rig.reply("challenge", ["status": 200, "body": "json"])],
            "model-key": [Self.names[0]: .json(["error": "lease_unavailable"], status: 503, headers: ["retry-after": "30"]),
                          Self.names[1]: .json(["error": "lease_unavailable"], status: 503, headers: ["retry-after": "2400"])],
        ])
        do {
            _ = try await rig.runtime.renew(rig.manifest)
            XCTFail("no lease from any host")
        } catch {}
        XCTAssertEqual(rig.asked("model-key"), Self.names)
        XCTAssertEqual(rig.runtime.retryState.notBefore, rig.clocks.wallMs() / 1000 + 2400)
        let cause = try XCTUnwrap(rig.runtime.lastFailure.withLock { $0 }?.cause)
        XCTAssertEqual(cause.stage, "lease")
        XCTAssertEqual(cause.reason, "lease_unavailable")
        XCTAssertEqual(cause.httpStatus, 503)
        XCTAssertEqual(cause.hostRole, "api")
        XCTAssertEqual(cause.fallback, true)

        // the first host answers alone: fallback false
        let one = try self.rig()
        defer { one.stop() }
        one.serve([
            "challenge": [Self.names[0]: one.reply("challenge", ["status": 200, "body": "json"])],
            "model-key": [Self.names[0]: .json(["error": "lease_attestation_required", "message": "no"], status: 403)],
        ])
        do {
            _ = try await one.runtime.renew(one.manifest)
            XCTFail("a refusal")
        } catch {}
        XCTAssertEqual(one.asked("model-key"), [Self.names[0]])
        let refused = try XCTUnwrap(one.runtime.lastFailure.withLock { $0 }?.cause)
        XCTAssertEqual(refused.hostRole, "api")
        XCTAssertEqual(refused.fallback, false)
    }
}
#endif
