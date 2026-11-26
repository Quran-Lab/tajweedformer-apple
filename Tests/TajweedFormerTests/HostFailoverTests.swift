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

    /// A model file's path held on its first host by a 503 with `Retry-After` kept from an earlier process: the next
    /// process goes to the next host without asking the held one, and sends no silent `failover` report (one goes out
    /// only when the first host was asked in this process and was unreachable). The held attempt still counts as one
    /// of the file's tries, as before: with no retry left the call fails there.
    func testAHeldHostIsNotAFailoverReport() async throws {
        typealias M = ModelDownloadTests
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let holds = CloudFixtures.storage().appendingPathComponent("cloud/retry-after.json")
        let folder = try XCTUnwrap(URL(string: "https://cdn.test/models/Quran-Lab/m/b/sdk/v4.0/"))
        func process() -> (EndpointSet, HTTPClient, Locked<Int>) {
            let e = EndpointSet(api: [Self.a, Self.b, Self.g], models: [Self.cdn, Self.cdnB], clock: { clock.withLock { $0 } }, holdsFile: holds)
            let reports = Locked(0)
            e.onFailover.withLock { $0 = { f, stage in if stage != nil, f.to != nil { reports.withLock { $0 += 1 } } } }
            return (e, HTTPClient(session: StubProtocol.session(), endpoints: e), reports)
        }
        func install(_ http: HTTPClient, pauses: [TimeInterval]) async -> RecognizerError? {
            let dir = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-b")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cdn = CDNClient(http: http, base: Self.cdn.appendingPathComponent("models"), auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                                verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
            var i = ModelInstaller(source: cdn.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: folder), retryPauses: pauses)
            i.install = M.CoreStandIn().install(in: dir)
            return await M.ensure(i, dir)
        }
        // an earlier process: the first host answers the file 503 with Retry-After 3600, kept with the SDK's state
        let (_, first, _) = process()
        Self.serve(["cdn.test": .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "3600"])])
        let part = CloudFixtures.storage().appendingPathComponent("held.part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let url = folder.appendingPathComponent(M.weights)
        _ = try? await first.stream(URLRequest(url: url), offset: 0, size: Int64(M.stored.count), into: part, started: { _, _ in }, received: { _ in })
        // a new process 10 s later: the hold is read back; the next host is asked, the held one is not
        clock.withLock { $0 = $0.addingTimeInterval(10) }
        StubProtocol.reset { s in M.served(s, data: M.stored) }
        let (e, http, reports) = process()
        let error = await install(http, pauses: [0])
        XCTAssertNil(error, "\(String(describing: error))")
        XCTAssertEqual(Self.asked, ["cdn-b.test"], "the next host, and not the held one")
        XCTAssertEqual(reports.withLock { $0 }, 0, "no failover report: the held host was not asked in this process")
        XCTAssertEqual(e.preferred(.models), "cdn-b.test")
        // the retry accounting is as before: the held attempt is one of the file's tries
        StubProtocol.reset { s in M.served(s, data: M.stored) }
        let (_, again, _) = process()
        let failed = await install(again, pauses: [])
        XCTAssertNotNil(failed, "with no retry left the held attempt ends the call")
        XCTAssertEqual(Self.asked, [], "and nothing was asked")
    }

    /// 28.7 on the manifest's request, per request: the request that gets a 503 with `Retry-After`
    /// from its first host asked it, and reports when the next host answers. A later request of the same path that
    /// skips that host for the hold (the probe back in the same process, and a new process) asked no first host: no
    /// report, even when the next host it asks is unreachable and a third answers.
    func testAManifestRequestThatSkippedAHeldHostIsNoFailoverReport() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let cdnG = try XCTUnwrap(URL(string: "https://cdn-g.test"))
        let holds = CloudFixtures.storage().appendingPathComponent("cloud/retry-after.json")
        func process() -> (HTTPClient, Locked<Int>) {
            let e = EndpointSet(api: [Self.a, Self.b, Self.g], models: [Self.cdn, Self.cdnB, cdnG], clock: { clock.withLock { $0 } }, holdsFile: holds)
            let reports = Locked(0)
            e.onFailover.withLock { $0 = { f, stage in if stage != nil, f.to != nil { reports.withLock { $0 += 1 } } } }
            return (HTTPClient(session: StubProtocol.session(), endpoints: e), reports)
        }
        let url = try XCTUnwrap(URL(string: "https://cdn.test/models/Quran-Lab/m/b/sdk/v4.0/manifest.json"))
        let (http, reports) = process()
        Self.serve(["cdn.test": .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "7200"]), "cdn-b.test": Self.ok, "cdn-g.test": Self.ok])
        _ = try await http.checked(URLRequest(url: url), role: .models)
        XCTAssertEqual(Self.asked, ["cdn.test", "cdn-b.test"])
        XCTAssertEqual(reports.withLock { $0 }, 1, "the request that got the 503 asked its first host, and reports")
        // the probe back, 31 minutes later in the same process: the list in order, its first host held
        clock.withLock { $0 = $0.addingTimeInterval(31 * 60) }
        Self.serve(["cdn.test": Self.ok, "cdn-b.test": Self.unavailable, "cdn-g.test": Self.ok])
        _ = try await http.checked(URLRequest(url: url), role: .models)
        XCTAssertEqual(Self.asked, ["cdn-b.test", "cdn-g.test"], "the held host is skipped")
        XCTAssertEqual(reports.withLock { $0 }, 1, "a request that skipped its first host for a hold sends no report")
        // a new process: the hold read back, the same
        clock.withLock { $0 = $0.addingTimeInterval(60) }
        let (again, reportsAgain) = process()
        Self.serve(["cdn.test": Self.ok, "cdn-b.test": Self.unavailable, "cdn-g.test": Self.ok])
        _ = try await again.checked(URLRequest(url: url), role: .models)
        XCTAssertEqual(Self.asked, ["cdn-b.test", "cdn-g.test"])
        XCTAssertEqual(reportsAgain.withLock { $0 }, 0)
    }

    /// ERRORS_40 24.2 `fallback` (SDK 4.0.2): true only when the request was asked of more than one host; a host skipped
    /// for a hold was not asked. The first host held, the next asked and failing: `fallback` false, for the manifest's
    /// request and for a model file.
    func testAHostSkippedForAHoldIsNoFallback() async throws {
        typealias M = ModelDownloadTests
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let holds = CloudFixtures.storage().appendingPathComponent("cloud/retry-after.json")
        let folder = try XCTUnwrap(URL(string: "https://cdn.test/models/Quran-Lab/m/b/sdk/v4.0/"))
        let manifest = folder.appendingPathComponent("manifest.json"), file = folder.appendingPathComponent(M.weights)
        func client() -> HTTPClient {
            HTTPClient(session: StubProtocol.session(),
                       endpoints: EndpointSet(api: [Self.a, Self.b, Self.g], models: [Self.cdn, Self.cdnB], clock: { clock.withLock { $0 } }, holdsFile: holds))
        }
        // an earlier process: both paths answered 503 with Retry-After by the first host
        let first = client()
        Self.serve(["cdn.test": .json(["error": "unavailable"], status: 503, headers: ["Retry-After": "3600"]), "cdn-b.test": Self.unavailable])
        _ = try? await first.checked(URLRequest(url: manifest), role: .models)
        let part = CloudFixtures.storage().appendingPathComponent("held.part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        _ = try? await first.stream(URLRequest(url: file), offset: 0, size: Int64(M.stored.count), into: part, started: { _, _ in }, received: { _ in })
        // a new process: the first host held for both, the next asked and failing
        clock.withLock { $0 = $0.addingTimeInterval(10) }
        let http = client()
        Self.serve(["cdn.test": Self.ok, "cdn-b.test": Self.unavailable])
        let manifestFallback = await RequestTrace.scope { () async -> Bool? in
            _ = try? await http.checked(URLRequest(url: manifest), role: .models)
            return RequestTrace.last?.fallback
        }
        XCTAssertEqual(Self.asked, ["cdn-b.test"])
        XCTAssertEqual(manifestFallback, false, "the manifest: one host asked")
        Self.serve(["cdn.test": Self.ok, "cdn-b.test": Self.unavailable])
        let dir = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-b")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cdn = CDNClient(http: http, base: Self.cdn.appendingPathComponent("models"), auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                            verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        var i = ModelInstaller(source: cdn.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: folder), retryPauses: [0])
        i.install = M.CoreStandIn().install(in: dir)
        let installer = i
        let (error, fileFallback) = await RequestTrace.scope { () async -> (RecognizerError?, Bool?) in
            let e = await M.ensure(installer, dir)
            return (e, RequestTrace.last?.fallback)
        }
        XCTAssertNotNil(error)
        XCTAssertEqual(Self.asked, ["cdn-b.test"], "the held host was not asked")
        XCTAssertEqual(fileFallback, false, "a model file: one host asked")
    }

    /// 28.7 and ERRORS_40 `failover`: the first host is asked and unreachable, and
    /// the next host's path is held by a 429 (here noted while the request runs: a 429's hold is the path's on every
    /// host, so one read back at a start holds the first host too). The request ends on the held 429 and asks no one
    /// else: no `failover` report, and `fallback` false. The control: the first unreachable, the second held by a 503,
    /// the third answers: a report, and `fallback` true. For a model file and for the manifest's request.
    func testAHeldFourTwentyNineAfterAnUnreachableFirstHostIsNoFailover() async throws {
        typealias M = ModelDownloadTests
        let cdnG = try XCTUnwrap(URL(string: "https://cdn-g.test"))
        let folder = try XCTUnwrap(URL(string: "https://cdn.test/models/Quran-Lab/m/b/sdk/v4.0/"))
        let manifestPath = folder.appendingPathComponent("manifest.json").path, filePath = folder.appendingPathComponent(M.weights).path
        struct Run { let error: Bool; let reports: Int; let fallback: Bool?; let asked: [String] }
        // `second`: what holds the path on cdn-b while the request runs (a 429 for the whole path, or a 503 for that host)
        func run(manifest: Bool, second: Int) async -> Run {
            let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
            let e = EndpointSet(api: [Self.a, Self.b, Self.g], models: [Self.cdn, Self.cdnB, cdnG], clock: { clock.withLock { $0 } })
            let reports = Locked(0)
            e.onFailover.withLock { $0 = { f, stage in if stage != nil, f.to != nil { reports.withLock { $0 += 1 } } } }
            let http = HTTPClient(session: StubProtocol.session(), endpoints: e)
            let path = manifest ? manifestPath : filePath
            StubProtocol.reset { s in
                if s.url.host == "cdn.test" {
                    // the first host is unreachable; meanwhile the path is held on cdn-b
                    e.holds.note("models:" + path, host: Self.cdnB, status: second, retryAfter: "90", now: clock.withLock { $0 })
                    return .json(["error": "unavailable"], status: 503)
                }
                return manifest ? Self.ok : M.served(s, data: M.stored)
            }
            if manifest {
                let fallback = await RequestTrace.scope { () async -> Bool? in
                    _ = try? await http.checked(URLRequest(url: folder.appendingPathComponent("manifest.json")), role: .models)
                    return RequestTrace.last?.fallback
                }
                return Run(error: false, reports: reports.withLock { $0 }, fallback: fallback, asked: Self.asked)
            }
            let dir = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-b")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cdn = CDNClient(http: http, base: Self.cdn.appendingPathComponent("models"), auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                                verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
            var i = ModelInstaller(source: cdn.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "b", base: folder), retryPauses: [0, 0])
            i.install = M.CoreStandIn().install(in: dir)
            let installer = i
            let (error, fallback) = await RequestTrace.scope { () async -> (Bool, Bool?) in
                let failure = await M.ensure(installer, dir)
                return (failure != nil, RequestTrace.last?.fallback)
            }
            return Run(error: error, reports: reports.withLock { $0 }, fallback: fallback, asked: Self.asked)
        }
        for manifest in [false, true] {
            let what = manifest ? "the manifest" : "a model file"
            let held = await run(manifest: manifest, second: 429)
            XCTAssertEqual(held.asked, ["cdn.test"], "\(what): it ended on the held 429 and asked no one else")
            if !manifest { XCTAssertTrue(held.error, "\(what): the held 429 is the call's answer") }
            XCTAssertEqual(held.reports, 0, "\(what): no other host answered: no failover report")
            XCTAssertNotNil(held.fallback, "\(what): the request names its hosts for the report's cause")
            XCTAssertEqual(held.fallback, false, "\(what): one host was asked")
            let control = await run(manifest: manifest, second: 503)
            XCTAssertEqual(control.asked, ["cdn.test", "cdn-g.test"], "\(what): the 503's host skipped, the third asked")
            XCTAssertFalse(control.error, what)
            XCTAssertEqual(control.reports, 1, "\(what): the first host was asked and unreachable, another answered: a report")
            XCTAssertEqual(control.fallback, true, "\(what): two hosts were asked")
        }
    }

    /// 28.4: a lease folder's host that the config's `models` list in force leaves
    /// out is asked first, even when it is a built-in host; a base host the list names keeps its place in the order
    /// (`P` first). To 4.0.2 a built-in host counted as the role's whatever the list said, and was never asked first.
    func testABaseHostTheListInForceLeavesOutIsAskedFirst() throws {
        let builtIn = EndpointSet.builtInOrigins(.models)
        XCTAssertGreaterThanOrEqual(builtIn.count, 3)
        let left = builtIn[0]
        let listed = Array(builtIn.dropFirst())
        let endpoints = JSONValue(any: ["models": listed.compactMap { $0.host }])
        let set = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: builtIn, config: { .some(endpoints) })
        XCTAssertEqual(set.hosts(.models), listed, "the config's list is in force")
        XCTAssertFalse(set.isRoleHost(.models, left), "a built-in host the list leaves out is not one of the role's now")
        XCTAssertEqual(FileHosts(endpoints: set, base: left).host(for: "layers.zfw.qle"), left, "the base host is asked first")
        let named = try XCTUnwrap(listed.last)
        XCTAssertEqual(FileHosts(endpoints: set, base: named).host(for: "layers.zfw.qle"), listed[0], "a listed base host keeps its place: P first")
    }

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

    // MARK: SDK 4.0.5

    /// A captive portal's page with 200 on the first host: not the answer (`not_json`), so the second host is asked;
    /// `lastFailover` names the check, and the operation's chain has the first host's hop (`first`, never its name).
    func testAPageWith200FailsOverAndNamesItsCheck() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, e) = Self.client(clock)
        Self.serve(["api.test": StubProtocol.Reply(status: 200, headers: ["content-type": "text/html"], body: Data("<html>Wi-Fi login</html>".utf8)),
                    "api-b.test": Self.ok])
        // every wait of this test is bounded: a step that does not end fails the test with where it stood (the public
        // CI, Swift 6.3.3 on macOS 26, hung here for 57 minutes on 2026-11-26 with no line after the test's start)
        let call = await HostFailoverTests.within(20) { [http] () -> (Result<HTTPClient.Response, CloudError>, [CauseHop]?) in
            await RequestTrace.scope { () -> (Result<HTTPClient.Response, CloudError>, [CauseHop]?) in
                let r = await HostFailoverTests.get(http)
                return (r, CauseChain.current)
            }
        }
        guard let call else {
            return XCTFail("no answer within 20 s; the stand-in saw \(Self.asked)")
        }
        let (answer, hops) = call
        XCTAssertEqual(try answer.get().status, 200, "the second host's answer")
        XCTAssertEqual(Self.asked, ["api.test", "api-b.test"])
        guard let read = HostFailoverTests.bounded(5, { [e] in e.lastFailover }) else { return XCTFail("lastFailover did not answer within 5 s") }
        let f = try XCTUnwrap(read)
        XCTAssertEqual(f.reason, "invalid_answer")
        XCTAssertEqual(f.check, "not_json")
        XCTAssertEqual(f.status, 200)
        XCTAssertEqual(hops, [CauseHop(stage: "register", hostRole: "api", host: "standby", httpStatus: 200, reason: "invalid_answer",
                                       errorName: nil, errorCode: "not_json")],
                       "the test hosts are not under quranlab.ai: standby")
        guard let diagnosis = HostFailoverTests.bounded(5, { [e] in e.diagnosis }) else { return XCTFail("diagnosis did not answer within 5 s") }
        XCTAssertEqual(diagnosis.lastFailover?.check, "not_json")
    }

    /// `body`'s value, or nil when it has not ended after `seconds` (then it is cancelled and left behind).
    static func within<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async -> T) async -> T? {
        let first = Locked(false)
        let claim: @Sendable () -> Bool = { first.withLock { (f: inout Bool) -> Bool in defer { f = true }; return !f } }
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let work = Task.detached {
                let v = await body()
                if claim() { c.resume(returning: v) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if claim() {
                    work.cancel()
                    c.resume(returning: nil)
                }
            }
        }
    }

    /// `body`'s value read on a thread of its own, or nil when it has not returned after `seconds` (a lock never let go).
    static func bounded<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () -> T) -> T? {
        let box = Locked<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread {
            let v = body()
            box.withLock { $0 = v }
            done.signal()
        }.start()
        return done.wait(timeout: .now() + seconds) == .success ? box.withLock { $0 } : nil
    }

    /// The token's challenge in another form on the first host: the next host is asked (4.0.2 took any JSON 2xx), and
    /// the call gets the strict challenge of the second.
    func testAChallengeInAnotherFormFailsOver() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let (http, _) = Self.client(clock)
        let strict = "c1.1790538034.P7cQRSKHbtf5lbPqTWcE6A.3DXJOorkOhcv9Z8sE10upQ"
        StubProtocol.reset { s in
            switch (s.url.host ?? "", s.path) {
            case ("api.test", "/v1/attest/challenge"): return .json(["challenge": "abc"])
            case (_, "/v1/attest/challenge"): return .json(["challenge": strict, "expires_in": 300])
            case (_, "/v1/attest"): return CloudFixtures.token
            default: return StubProtocol.Reply(status: 404)
            }
        }
        var r = URLRequest(url: Self.a.appendingPathComponent("v1/attest/challenge"))
        r.setValue(CloudFixtures.key, forHTTPHeaderField: "x-qlab-key")
        let resp = try await http.checked(r, role: .api, accept: { (a: HTTPClient.Response) -> Bool in
            if let c = AnswerCheck.challenge(a.body).check { AnswerCheck.failed(c); return false }
            return true
        })
        XCTAssertEqual(AnswerCheck.challenge(resp.body).challenge, strict)
        XCTAssertEqual(Self.asked, ["api.test", "api-b.test"])
    }

}
