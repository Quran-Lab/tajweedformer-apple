import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.1, contract section 28 (`sdk_4.0.0/ENDPOINTS_40.md`) on the SDK's real HTTP code (28.8 checks 1, 2, 5, 6 and
/// 8): three `api` hosts and two `models` hosts answered by the stand-in server by host (`StubProtocol`), a clock the
/// test moves; what each request asked, what it ended on, the sticky host, the probe back, `lastFailover`, the
/// silent `failover` report and `diagnose()`'s `endpoints`; the manifest from the lease's folder (28.4).
final class HostFailoverTests: XCTestCase {
    override func tearDown() {
        HTTPClient.silenceLimit.withLock { $0 = Endpoints.silenceLimit }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    static let a = URL(string: "https://api.test")!, b = URL(string: "https://api-b.test")!, g = URL(string: "https://api-g.test")!
    static let cdn = URL(string: "https://cdn.test")!, cdnB = URL(string: "https://cdn-b.test")!

    /// An HTTP client over the stand-in with the api hosts a, b, g and the models hosts cdn, cdn-b, on `clock`.
    static func client(_ clock: Locked<Date>) -> (HTTPClient, EndpointSet) {
        let e = EndpointSet(api: [a, b, g], models: [cdn, cdnB], clock: { clock.withLock { $0 } })
        return (HTTPClient(session: StubProtocol.session(), endpoints: e), e)
    }

    /// A request of the API made on its first host (as every request of the SDK is), through the role's order.
    static func get(_ http: HTTPClient, _ path: String = "v1/register") async -> Result<HTTPClient.Response, CloudError> {
        let r = URLRequest(url: a.appendingPathComponent(path))
        do throws(CloudError) { return .success(try await http.send(r)) } catch { return .failure(error) }
    }

    /// The hosts the stand-in saw, in order, since the last reset.
    static var asked: [String] { StubProtocol.seen.map { $0.url.host ?? "" } }

    /// A stand-in answering each host its own way (nil: 404).
    static func serve(_ byHost: [String: StubProtocol.Reply]) {
        StubProtocol.reset { s in byHost[s.url.host ?? ""] ?? StubProtocol.Reply(status: 404) }
    }

    static let ok = StubProtocol.Reply.json(["ok": true])
    static let unavailable = StubProtocol.Reply.json(["error": "service_unavailable"], status: 503)

    /// Check 1: the first host down (no answer, then a 503): the second answers, and the next request goes to it first.
    func testTheFirstHostDownTheSecondAnswersAndIsAskedFirstAfter() async throws {
        for (down, reason, status) in [(StubProtocol.Reply.down, "network", nil as Int?), (Self.unavailable, "http", 503)] {
            let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
            let (http, e) = Self.client(clock)
            Self.serve(["api.test": down, "api-b.test": Self.ok])
            let r = try await Self.get(http).get()
            XCTAssertEqual(r.status, 200)
            XCTAssertEqual(Self.asked, ["api.test", "api-b.test"])
            // the same path, method and body on the second host
            XCTAssertEqual(Set(StubProtocol.seen.map(\.path)), ["/v1/register"])
            XCTAssertEqual(e.preferred(.api), "api-b.test")
            let f = try XCTUnwrap(e.lastFailover)
            XCTAssertEqual(f, EndpointSet.Failover(role: .api, from: "api.test", to: "api-b.test", reason: reason, status: status, at: 1_800_000_000))
            Self.serve(["api.test": Self.ok, "api-b.test": Self.ok])
            _ = try await Self.get(http).get()
            XCTAssertEqual(Self.asked, ["api-b.test"], "the sticky host first")
        }
    }

    /// Check 2: a refusal on the second host is the answer (the third is never asked); a 429 on the first is the
    /// answer (no other host is asked, P stays).
    func testARefusalAndA429AreTheAnswer() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, e) = Self.client(clock)
        Self.serve(["api.test": .down, "api-b.test": .json(["error": "app_blocked", "reason": "app_blocked"], status: 403), "api-g.test": Self.ok])
        let refused = try await Self.get(http).get()
        XCTAssertEqual(refused.status, 403)
        XCTAssertEqual(Self.asked, ["api.test", "api-b.test"])
        XCTAssertEqual(e.preferred(.api), "api-b.test", "the host that refused is P")

        let (http2, e2) = Self.client(clock)
        Self.serve(["api.test": .json(["error": "rate_limited"], status: 429, headers: ["retry-after": "60"]), "api-b.test": Self.ok])
        let slow = try await Self.get(http2).get()
        XCTAssertEqual(slow.status, 429)
        XCTAssertEqual(Self.asked, ["api.test"], "a 429 never fails over")
        XCTAssertEqual(e2.preferred(.api), "api.test")
        XCTAssertNil(e2.lastFailover)
    }

    /// 28.3 item 4 and 28.7: every host unreachable: the request is the FIRST host's failure, P stays, and
    /// `lastFailover` names no host that answered. A list of one host is recorded the same way.
    func testEveryHostUnreachable() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, e) = Self.client(clock)
        Self.serve(["api.test": Self.unavailable, "api-b.test": .down, "api-g.test": StubProtocol.Reply(status: 502, headers: ["content-type": "text/html"])])
        let r = try await Self.get(http).get()
        XCTAssertEqual(r.status, 503, "the first host's answer")
        XCTAssertEqual(Self.asked, ["api.test", "api-b.test", "api-g.test"])
        XCTAssertEqual(e.preferred(.api), "api.test")
        XCTAssertEqual(e.lastFailover, EndpointSet.Failover(role: .api, from: "api.test", to: nil, reason: "http", status: 503, at: 1_800_000_000))

        let one = EndpointSet(api: [Self.a], models: [Self.cdn], clock: { clock.withLock { $0 } })
        Self.serve(["api.test": .down])
        let failed = await Self.get(HTTPClient(session: StubProtocol.session(), endpoints: one))
        guard case .failure(.offline(_)) = failed else { return XCTFail("no answer: \(failed)") }
        XCTAssertEqual(one.lastFailover?.to, nil)
        XCTAssertEqual(one.lastFailover?.reason, "network")
        XCTAssertEqual(one.lastFailover?.from, "api.test")
    }

    /// Check 5: 30 minutes after a failover the first host is asked first again (the probe back), and is P when it
    /// answers; when it does not, the backup host is P for 30 more minutes.
    func testTheProbeBack() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, e) = Self.client(clock)
        Self.serve(["api.test": .down, "api-b.test": Self.ok])
        _ = try await Self.get(http).get()
        clock.withLock { $0 = $0.addingTimeInterval(1799) }
        Self.serve(["api.test": .down, "api-b.test": Self.ok])
        _ = try await Self.get(http).get()
        XCTAssertEqual(Self.asked, ["api-b.test"])
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000 + 1800) }
        XCTAssertEqual(e.preferred(.api), "api.test", "the probe is due: the first host goes first")
        Self.serve(["api.test": .down, "api-b.test": Self.ok])
        _ = try await Self.get(http).get()
        XCTAssertEqual(Self.asked, ["api.test", "api-b.test"], "the probe, then the backup host")
        XCTAssertEqual(e.preferred(.api), "api-b.test", "the backup host for 30 more minutes")
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000 + 3599) }
        Self.serve(["api.test": Self.ok, "api-b.test": Self.ok])
        _ = try await Self.get(http).get()
        XCTAssertEqual(Self.asked, ["api-b.test"])
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000 + 3600) }
        Self.serve(["api.test": Self.ok, "api-b.test": Self.ok])
        _ = try await Self.get(http).get()
        XCTAssertEqual(Self.asked, ["api.test"])
        XCTAssertEqual(e.preferred(.api), "api.test", "the first host answered the probe: P again")
    }

    /// 28.3 item 6: a host that sends no byte within its limit (10 s; shortened here) is no answer, and the next host
    /// is asked. Its reason is `network` (a timeout before any answer).
    func testASilentHostIsNoAnswer() async throws {
        HTTPClient.silenceLimit.withLock { $0 = 0.5 }
        let gate = StubProtocol.Gate()
        defer { gate.open() }
        var held = Self.ok
        held.hold = gate
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, e) = Self.client(clock)
        Self.serve(["api.test": held, "api-b.test": Self.ok])
        let t0 = Date()
        let r = try await Self.get(http).get()
        XCTAssertEqual(r.status, 200)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        XCTAssertEqual(Self.asked, ["api.test", "api-b.test"])
        XCTAssertEqual(e.lastFailover?.reason, "network")
        XCTAssertNil(e.lastFailover?.status)
    }

    /// 28.4 (the lease-folder hook): the manifest of a build this install holds a lease of is read from the lease's
    /// folder (its path) through the `models` hosts; without one, from the build's folder under the model base. A
    /// folder on an allowed host that is not one of the role's is asked first.
    func testTheManifestComesFromTheLeasesFolder() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, _) = Self.client(clock)
        let build = String(repeating: "4b", count: 20)
        let folder = URL(string: "https://cdn-b.test/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/")!
        var cdn = CDNClient(http: http, base: Self.cdn.appendingPathComponent("models"), auth: .fixed(key: CloudFixtures.key, token: "t"),
                            verifier: ManifestVerifier(trustedKeys: [CloudFixtures.signer.publicKey.rawRepresentation], requireSignature: true))
        let id = ModelID("v4.0", repository: "Quran-Lab/tajweedformer-v4", folder: "sdk/v4.0")
        // no lease of the build: the build's folder under the model base, the role's order
        Self.serve(["cdn.test": Self.unavailable, "cdn-b.test": Self.unavailable])
        _ = try? await cdn.manifest(id, revision: build)
        XCTAssertEqual(StubProtocol.seen.map { $0.url.absoluteString },
                       ["https://cdn.test/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/manifest.json",
                        "https://cdn-b.test/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/manifest.json"])
        // a lease of the build names a folder on a backup host: its path, through the role's order (P first)
        cdn.leaseFolder = { (b: String) -> URL? in b == build ? folder : nil }
        Self.serve(["cdn.test": Self.unavailable, "cdn-b.test": Self.unavailable])
        _ = try? await cdn.manifest(id, revision: build)
        XCTAssertEqual(StubProtocol.seen.map { $0.url.path }, ["/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/manifest.json",
                                                                "/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/manifest.json"])
        XCTAssertEqual(Self.asked, ["cdn.test", "cdn-b.test"])
        // a folder on an allowed host that is not one of the role's: asked first, then the role's order
        let region = URL(string: "https://eu.cdn.quran-lab.com/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/")!
        cdn.leaseFolder = { (_: String) -> URL? in region }
        Self.serve([:])
        _ = try? await cdn.manifest(id, revision: build)
        XCTAssertEqual(Self.asked.first, "eu.cdn.quran-lab.com")
        XCTAssertEqual(Array(Self.asked.dropFirst()), ["cdn.test", "cdn-b.test"])
    }

    /// The runtime's half of the hook: the folder of the lease it holds for that build (an accepted base), else nil.
    func testTheRuntimeNamesTheFolderOfTheLeaseItHolds() throws {
        let storage = CloudFixtures.storage()
        let runtime = ProtectedRuntime(storage: storage, server: nil, keys: InstallKeyring(storage: storage))
        let build = String(repeating: "4b", count: 20)
        XCTAssertNil(runtime.leaseFolder(build), "no lease")
        let base = "https://cdn-b.tajweedformer.com/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/"
        JSONFile<LeaseRecord>(url: storage.appendingPathComponent("cloud/lease.json"))
            .write(LeaseRecord(build: build, base: base, expiresAt: 1, refreshAfter: 1))
        XCTAssertEqual(runtime.leaseFolder(build)?.absoluteString, base)
        XCTAssertEqual(runtime.leaseFolder(build.uppercased())?.absoluteString, base)
        XCTAssertNil(runtime.leaseFolder(String(repeating: "5c", count: 20)), "another build's lease")
        JSONFile<LeaseRecord>(url: storage.appendingPathComponent("cloud/lease.json"))
            .write(LeaseRecord(build: build, base: "https://cdn.example.net/models/x/", expiresAt: 1, refreshAfter: 1))
        XCTAssertNil(runtime.leaseFolder(build), "a base off the allow-list is no folder")
    }

    /// Check 8, a request's own cause (24.2, RequestTrace): the config asked of both API hosts, each answering 503. The
    /// refresh's cause is the FIRST host's answer (28.3 item 4) with host_role api and fallback true, and so is the
    /// silent report it leaves in the book; P stays the first host.
    func testTheCauseOfARequestEveryHostFailedNamesItsRoleAndFallback() async throws {
        let storage = CloudFixtures.storage()
        var o = CloudFixtures.options(storage: storage)
        o.cloud?.apiHostList = [Self.a, Self.b]
        let options = o
        let healthy = CloudFixtures.server()
        StubProtocol.reset { s in s.path == "/v1/config" ? Self.unavailable : healthy(s) }
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options,
                                       cloud: { CloudFixtures.cloud(storage: $0, options: options) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        let cause = try XCTUnwrap(cloud.configFailure.withLock { $0 })
        XCTAssertEqual(cause.stage, "config")
        XCTAssertEqual(cause.reason, "http")
        XCTAssertEqual(cause.httpStatus, 503)
        XCTAssertEqual(cause.hostRole, "api")
        XCTAssertEqual(cause.fallback, true)
        XCTAssertEqual(Set(StubProtocol.seen("/v1/config").map { $0.url.host ?? "" }), ["api.test", "api-b.test"])
        XCTAssertEqual(cloud.endpoints.preferred(.api), "api.test")
        cloud.errorReports.waitForSave()
        let r = try XCTUnwrap(cloud.errorReports.snapshot.queue.first { $0.stage == "config" && $0.reason == "http" })
        XCTAssertEqual(r.hostRole, "api")
        XCTAssertEqual(r.fallback, true)
    }

    /// The install's own cause (RequestTrace's install scope): the manifest asked of both models hosts, each answering
    /// 503. The install's cause is stage manifest, the first host's 503, host_role models and fallback true.
    func testTheCauseOfAnInstallNamesItsRoleAndFallback() async throws {
        let storage = CloudFixtures.storage()
        var o = CloudFixtures.options(storage: storage)
        o.cloud?.modelHostList = [Self.cdn, Self.cdnB]
        let options = o
        let healthy = CloudFixtures.server()
        StubProtocol.reset { s in s.path.hasSuffix("/manifest.json") ? Self.unavailable : healthy(s) }
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options,
                                       cloud: { CloudFixtures.cloud(storage: $0, options: options) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        let failed = await { () async -> String? in
            do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error.code }
        }()
        XCTAssertEqual(failed, "download_failed")
        XCTAssertEqual(Set(StubProtocol.seen.filter { $0.path.hasSuffix("/manifest.json") }.map { $0.url.host ?? "" }), ["cdn.test", "cdn-b.test"])
        let cause = try XCTUnwrap(cloud.updater.lastFailure.withLock { $0 }?.cause)
        XCTAssertEqual(cause.stage, "manifest")
        XCTAssertEqual(cause.httpStatus, 503)
        XCTAssertEqual(cause.hostRole, "models")
        XCTAssertEqual(cause.fallback, true)
    }

    /// The events route's own cause (28.7 lists `events`): the first API host answers 503, the second refuses the
    /// report (413). The silent report is events, http, 413, host_role api, fallback true.
    func testTheCauseOfAnEventsRequestNamesItsRoleAndFallback() async throws {
        let storage = CloudFixtures.storage()
        var o = CloudFixtures.options(storage: storage)
        o.cloud?.apiHostList = [Self.a, Self.b]
        let options = o
        let healthy = CloudFixtures.server()
        StubProtocol.reset { s in
            guard s.path == "/v1/events" else { return healthy(s) }
            return s.url.host == "api.test" ? Self.unavailable : .json(["error": "payload_too_large"], status: 413)
        }
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options,
                                       cloud: { CloudFixtures.cloud(storage: $0, options: options) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        cloud.record(.download(revision: "4.0.0", build: String(repeating: "b", count: 40), profile: "apple-cpu", bytes: 1234,
                               success: true, resumed: false))
        _ = await cloud.flush()
        XCTAssertFalse(StubProtocol.seen("/v1/events").isEmpty)
        cloud.errorReports.waitForSave()
        // the report is in the book, or already sent by the same send point (after the telemetry, 24.6)
        if let r = cloud.errorReports.snapshot.queue.first(where: { $0.stage == "events" && $0.reason == "http" }) {
            XCTAssertEqual([r.reason, String(r.httpStatus ?? 0), r.hostRole ?? "-", String(r.fallback ?? false)], ["http", "413", "api", "true"])
        } else {
            let sent = StubProtocol.seen("/v1/issues").compactMap(\.json).compactMap { $0["error"] as? [String: Any] }
            let e = try XCTUnwrap(sent.first { $0["stage"] as? String == "events" && $0["reason"] as? String == "http" }, "no events report: \(sent)")
            XCTAssertEqual(e["reason"] as? String, "http")
            XCTAssertEqual(e["http_status"] as? Int, 413)
            XCTAssertEqual(e["host_role"] as? String, "api")
            XCTAssertEqual(e["fallback"] as? Bool, true)
        }
    }

    /// A sharing request's own cause (28.7 lists `sharing`): "Delete what I shared" asks its challenge of both API
    /// hosts, each answering 503. The call fails, and its report is stage sharing, the first host's 503, host_role api
    /// and fallback true.
    func testTheCauseOfASharingRequestNamesItsRoleAndFallback() async throws {
        let storage = Fixtures.storage()
        CloudFixtures.seedConfig(storage: storage, flags: [:])
        var o = CloudFixtures.options(contributions: true, storage: storage)
        o.cloud?.apiHostList = [Self.a, Self.b]
        let options = o
        let healthy = CloudFixtures.server()
        StubProtocol.reset { s in s.path.hasPrefix("/v1/contributions/") ? Self.unavailable : healthy(s) }
        let cloud = CloudFixtures.cloud(storage: storage, options: options)
        QuranLab.configure(key: CloudFixtures.key, options: options, cloud: cloud)
        XCTAssertNotNil(ContributorKey.key(storage: storage), "the device key a deletion is signed with")
        var failed: TajweedError?
        do throws(TajweedError) { try await TajweedSharing().delete() } catch { failed = error }
        XCTAssertNotNil(failed, "no host took the deletion")
        XCTAssertEqual(Set(StubProtocol.seen("/v1/contributions/challenge").map { $0.url.host ?? "" }), ["api.test", "api-b.test"])
        cloud.errorReports.waitForSave()
        let r = try XCTUnwrap(cloud.errorReports.snapshot.queue.first { $0.stage == "sharing" && $0.reason != "failover" },
                              "\(cloud.errorReports.snapshot.queue)")
        XCTAssertEqual(r.httpStatus, 503)
        XCTAssertEqual(r.hostRole, "api")
        XCTAssertEqual(r.fallback, true)
    }

    /// 28.7, a call that fails on a remembered refusal (E6 found it without the two fields): the config asked of the
    /// first API host (503) and of the second, which refuses the key (401 `invalid_key`, `key_revoked`). The model
    /// call's `invalid_key` report names the request that brought the refusal: config, host_role api, fallback true.
    /// The refusal the gate remembers keeps them, so a later launch with no network, whose call fails on that
    /// refusal, names them too; with one API host, fallback is false.
    func testACallThatFailsOnARememberedRefusalNamesItsRoleAndFallback() async throws {
        let revoked = StubProtocol.Reply.json(["error": "invalid_key", "reason": "key_revoked", "message": "Quran Lab does not accept this key."],
                                              status: 401)
        for hosts in [[Self.a, Self.b], [Self.a]] {
            let storage = CloudFixtures.storage()
            var o = CloudFixtures.options(storage: storage)
            o.cloud?.apiHostList = hosts
            let options = o
            let healthy = CloudFixtures.server()
            let two = hosts.count > 1
            StubProtocol.reset { s in
                guard s.path == "/v1/config" else { return healthy(s) }
                return two && s.url.host == "api.test" ? Self.unavailable : revoked
            }
            do {
                let client = try TajweedClient(key: CloudFixtures.key, configuration: options,
                                               cloud: { CloudFixtures.cloud(storage: $0, options: options) })
                defer { client.close() }
                let cloud = try XCTUnwrap(QuranLab.cloud)
                let code = await { () async -> String? in
                    do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error.code }
                }()
                XCTAssertEqual(code, "invalid_key")
                XCTAssertEqual(cloud.gate.stop?.hostRole, "api")
                XCTAssertEqual(cloud.gate.stop?.fallback, two)
                cloud.errorReports.waitForSave()
                let r = try XCTUnwrap(cloud.errorReports.snapshot.queue.first { $0.code == "invalid_key" }, "\(cloud.errorReports.snapshot.queue)")
                XCTAssertEqual([r.stage, r.hostRole ?? "-", r.fallback.map { $0 ? "true" : "false" } ?? "-"], ["config", "api", two ? "true" : "false"])
            }
            // a later launch with no network: the call fails on the refusal the device remembers
            StubProtocol.reset { _ in .down }
            let client = try TajweedClient(key: CloudFixtures.key, configuration: options,
                                           cloud: { CloudFixtures.cloud(storage: $0, options: options) })
            defer { client.close() }
            let cloud = try XCTUnwrap(QuranLab.cloud)
            let code = await { () async -> String? in
                do throws(TajweedError) { _ = try await client.model(); return nil } catch { return error.code }
            }()
            XCTAssertEqual(code, "invalid_key")
            let stop = try XCTUnwrap(cloud.gate.stop)
            // the call's stage as before (a model call's, `download`), now with the request that brought the refusal
            let c = cloud.refusalCause(stop.error, gateFirst: true)
            XCTAssertEqual(c.stage, ErrorCause.of(stop.error).stage)
            XCTAssertEqual([c.hostRole ?? "-", c.fallback.map { $0 ? "true" : "false" } ?? "-"], ["api", two ? "true" : "false"])
            cloud.errorReports.waitForSave()
            let r = try XCTUnwrap(cloud.errorReports.snapshot.queue.first { $0.code == "invalid_key" && $0.stage == c.stage },
                                  "\(cloud.errorReports.snapshot.queue)")
            XCTAssertEqual([r.hostRole ?? "-", r.fallback.map { $0 ? "true" : "false" } ?? "-"], ["api", two ? "true" : "false"])
        }
    }

    /// Check 8 through a Client: the first API host answers 503 to everything and the second as a healthy server. The
    /// first request of the launch (the token, stage `attest`) fails over: one silent report `attest`, `failover` (code
    /// none, host_role api, fallback true, the first host's status and reason, no host name); the config after it goes
    /// to the second host first (the sticky host), so it is taken with no failover of its own; `diagnose()` names the
    /// second host for the API and the failover.
    func testTheFailoverReportAndDiagnose() async throws {
        let storage = CloudFixtures.storage()
        var o = CloudFixtures.options(storage: storage)
        o.cloud?.apiHostList = [Self.a, Self.b]
        let options = o
        let healthy = CloudFixtures.server()
        StubProtocol.reset { s in s.url.host == "api.test" ? Self.unavailable : healthy(s) }
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options,
                                       cloud: { CloudFixtures.cloud(storage: $0, options: options) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        XCTAssertNotNil(cloud.currentConfig, "the config from the second host")
        cloud.errorReports.waitForSave()
        let silent = cloud.errorReports.snapshot.queue.filter { $0.reason == "failover" }
        XCTAssertEqual(silent.map(\.stage), ["attest"], "\(cloud.errorReports.snapshot.queue)")
        XCTAssertTrue(StubProtocol.seen("/v1/config").allSatisfy { $0.url.host == "api-b.test" }, "the config went to the sticky host")
        let r = try XCTUnwrap(silent.first)
        XCTAssertEqual(r.code, "none")
        XCTAssertEqual(r.hostRole, "api")
        XCTAssertEqual(r.fallback, true)
        XCTAssertEqual(r.httpStatus, 503)
        XCTAssertEqual(r.errorCode, "http")
        let d = await client.diagnose()
        XCTAssertNil(DiagnosisTests.problem(try DiagnosisTests.report(d)))
        let e = try XCTUnwrap(d.endpoints)
        XCTAssertEqual(e.api, "api-b.test")
        XCTAssertEqual(e.models, "cdn.test")
        XCTAssertEqual(e.lastFailover?.role, "api")
        XCTAssertEqual(e.lastFailover?.from, "api.test")
        XCTAssertEqual(e.lastFailover?.to, "api-b.test")
        XCTAssertEqual(e.lastFailover?.status, 503)
        XCTAssertTrue(d.json.contains("\"endpoints\": {\"api\": \"api-b.test\", \"models\": \"cdn.test\", \"lastFailover\": {\"role\": \"api\""), d.json)
    }
}
