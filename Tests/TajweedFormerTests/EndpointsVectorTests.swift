import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.1, contract section 28 (`sdk_4.0.0/ENDPOINTS_40.md`): `vectors/endpoints_40.json` (copied into
/// Fixtures/vectors40 from 564c144, the final section 28 with a fourth host per role) replayed on the SDK's own rules: the roles and limits, `hosts` through the
/// allow-list (`Endpoints.hostAllowed`), `config_lists` through `Endpoints.roleList`, `bases` through
/// `Endpoints.baseParts` and the order of the build's first model request (`EndpointSet.order`), `answers` through
/// `Endpoints.answerClass`, and every `requests` sequence of the `api` and `models` roles through an `EndpointSet` on a
/// fake clock (the order, the sticky host, the probe back, a config list that changes), and `first_manifest` through
/// `CDNClient.manifest` on the stand-in server. `web_frame` is the web's: this SDK has no such role. `downloads` are
/// replayed through the installer (EndpointsDownloadVectorTests); `attempts` (through the Core) are not replayed yet.
final class EndpointsVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] { try V40.json("endpoints_40.json") }

    static func role(_ name: String) -> EndpointRole? { EndpointRole(rawValue: name) }

    func testTheRolesAndLimitsAreTheSDKs() throws {
        let v = try Self.vectors()
        XCTAssertEqual(v["format"] as? String, "quranlab.endpoints-40/1")
        let roles = try XCTUnwrap(v["roles"] as? [String: [String]])
        XCTAssertEqual(Set(roles.keys), Set(EndpointRole.allCases.map(\.rawValue)))
        for (name, hosts) in roles { XCTAssertEqual(Endpoints.builtIn[try XCTUnwrap(Self.role(name))], hosts, name) }
        XCTAssertEqual(v["config_roles"] as? [String], Endpoints.configRoles.map(\.rawValue))
        XCTAssertEqual(v["suffixes"] as? [String], Endpoints.suffixes)
        let limits = try XCTUnwrap(v["limits"] as? [String: Any])
        XCTAssertEqual(limits["head_s"] as? Int, Int(Endpoints.silenceLimit))
        XCTAssertEqual(limits["probe_s"] as? Int, Int(Endpoints.probeAfter))
        XCTAssertEqual(limits["max_config_hosts"] as? Int, Endpoints.maxConfigHosts)
        XCTAssertEqual(limits["resumes"] as? Int, 5)
        // the production client's built-in lists are the vectors'
        XCTAssertEqual(CloudOptions().apiHosts.map { $0.host ?? "" }, roles["api"])
        XCTAssertEqual(CloudOptions().modelHosts.map { $0.host ?? "" }, roles["models"])
    }

    func testHosts() throws {
        let cases = try XCTUnwrap(try Self.vectors()["hosts"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 29)
        for c in cases {
            let host = try XCTUnwrap(c["host"] as? String)
            XCTAssertEqual(Endpoints.hostAllowed(host), try XCTUnwrap(c["allowed"] as? Bool), host)
        }
    }

    func testConfigLists() throws {
        let cases = try XCTUnwrap(try Self.vectors()["config_lists"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 17)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let endpoints: JSONValue? = JSONValue(any: c["endpoints"])
            let inForce = try XCTUnwrap(c["in_force"] as? Bool)
            let lists = try XCTUnwrap(c["lists"] as? [String: [String]])
            for role in Endpoints.configRoles {
                let got = Endpoints.roleList(role, endpoints: endpoints, inForce: inForce, builtIn: Endpoints.builtIn[role] ?? [])
                XCTAssertEqual(got, lists[role.rawValue], "\(name): \(role.rawValue)")
            }
            // and through the Client's endpoint set, with that config in force (or none)
            let set = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models),
                                  config: { inForce ? .some(endpoints) : nil })
            for role in Endpoints.configRoles {
                XCTAssertEqual(set.hosts(role).map { $0.host ?? "" }, lists[role.rawValue], "\(name): the set's \(role.rawValue)")
            }
        }
    }

    func testBases() throws {
        let cases = try XCTUnwrap(try Self.vectors()["bases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 18)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let base = try XCTUnwrap(c["base"] as? String)
            let parts = Endpoints.baseParts(base)
            let accepted = try XCTUnwrap(c["accepted"] as? Bool)
            XCTAssertEqual(parts != nil, accepted, name)
            // a lease answer's folder is taken only when it is a base of 28.4: the answer as qlab-api writes it, read by
            // LeaseAnswer.parse, then ProtectedRuntime.acceptedBase
            let answer = try JSONSerialization.data(withJSONObject: ["v": 1, "lease": "AQID", "iat": 1, "exp": 2, "refresh_after": 1, "base": base])
            let parsed = try XCTUnwrap(LeaseAnswer.parse(answer), name)
            XCTAssertEqual(ProtectedRuntime.acceptedBase(parsed.base) != nil, accepted, "\(name): the lease answer's base")
            guard accepted, let parts else { continue }
            XCTAssertEqual(parts.host, c["host"] as? String, name)
            XCTAssertEqual(parts.path, c["path"] as? String, name)
            // the hosts the build's first model request asks, P the first host, then P a backup host
            let origin = Endpoints.origin(parts.host)
            let set = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models))
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let first = set.isRoleHost(.models, origin) ? nil : origin
            XCTAssertEqual(set.order(.models, at: now, first: first).hosts.map { $0.host ?? "" }, c["asks_with_p_first"] as? [String], name)
            set.settle(.models, Endpoints.origin("cdn-b.tajweedformer.com"), at: now, probe: false)
            XCTAssertEqual(set.order(.models, at: now.addingTimeInterval(60), first: first).hosts.map { $0.host ?? "" },
                           c["asks_with_p_standby"] as? [String], "\(name): P a backup host")
        }
    }

    /// A vector answer as the bytes a host sends: the route's own answer (`json`, `bytes`), a refusal's JSON with its
    /// `error` and `reason`, a JSON without one, an HTML page, nothing, or an answer that fails the route's check.
    static func body(_ a: [String: Any]) -> Data {
        switch a["body"] as? String {
        case "json":
            if let e = a["error"] as? String {
                var o: [String: Any] = ["error": e]
                if let r = a["reason"] as? String { o["reason"] = r }
                return try! JSONSerialization.data(withJSONObject: o)
            }
            return Data(#"{"ok": true}"#.utf8)
        case "bytes": return Data([0x51, 0x4c, 0x45, 0x01, 0x00, 0x7f])
        case "html": return Data("<html><body>a page</body></html>".utf8)
        case "invalid": return Data(#"{"v": 1}"#.utf8)
        default: return Data()
        }
    }

    /// Whether a 2xx (or 304) is what `route` asks for (28.3 "taken"): a config that verifies, or a 304 to one with
    /// If-None-Match; a lease the Core accepts; a manifest that verifies; a file 16.1 holds to be the file; else the
    /// JSON (or empty) answer of the route (`Endpoints.jsonAnswer`, the other API routes).
    static func taken(_ route: String, _ a: [String: Any], _ r: HTTPClient.Response) -> Bool {
        let kind = a["body"] as? String
        switch route {
        case "config": return r.status == 304 || ((200..<300).contains(r.status) && kind == "json")
        case "model-key": return r.status == 200 && kind == "json" && a["core"] as? String == "accepted"
        case "manifest": return (200..<300).contains(r.status) && kind == "json"
        case "file", "engine": return (200..<300).contains(r.status) && kind == "bytes"
        default: return Endpoints.jsonAnswer(r)
        }
    }

    /// The class of one host's vector answer on `route` (nil: no answer, none or a stall).
    static func classify(_ route: String, _ a: [String: Any]) -> AnswerClass {
        guard let status = a["status"] as? Int else { return .unreachable }
        let r = HTTPClient.Response(status: status, headers: [:], body: body(a))
        return Endpoints.answerClass(status: status, body: r.body, taken: taken(route, a, r))
    }

    func testAnswers() throws {
        let cases = try XCTUnwrap(try Self.vectors()["answers"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 31)
        for c in cases {
            let route = try XCTUnwrap(c["route"] as? String), a = try XCTUnwrap(c["answer"] as? [String: Any])
            XCTAssertEqual(Self.classify(route, a).rawValue, c["class"] as? String, "\(route) \(a)")
        }
    }

    func testRequests() throws {
        let cases = try XCTUnwrap(try Self.vectors()["requests"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 24)
        var replayed = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            guard let role = Self.role(try XCTUnwrap(c["role"] as? String)), role != .webFrame else { continue }
            let hosts = try XCTUnwrap(c["hosts"] as? [String])
            XCTAssertEqual(hosts, Endpoints.builtIn[role], name)
            let clock = Locked(Date(timeIntervalSince1970: 0))
            // the config in force: none at first; a `list` step is a config whose list for the role is that list
            let config = Locked<JSONValue??>(nil)
            let set = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models),
                                  config: { config.withLock { $0 } }, clock: { clock.withLock { $0 } })
            for step in try XCTUnwrap(c["steps"] as? [[String: Any]]) {
                if let list = step["list"] as? [String] {
                    let e: JSONValue? = JSONValue(any: [role.rawValue: list])
                    config.withLock { $0 = .some(e) }
                    XCTAssertEqual(set.hosts(role).map { $0.host ?? "" }, list, "\(name): the list")
                    XCTAssertEqual(set.preferred(role), step["p_after"] as? String, "\(name): P after the list")
                    continue
                }
                let at = try XCTUnwrap(step["at"] as? Int)
                let now = Date(timeIntervalSince1970: TimeInterval(at))
                clock.withLock { $0 = now }
                let route = try XCTUnwrap(step["route"] as? String)
                let answers = try XCTUnwrap(step["answers"] as? [String: [String: Any]])
                let (order, probe) = set.order(role, at: now)
                var asked: [String] = [], ended: AnswerClass = .unreachable, by: String?
                for origin in order {
                    let host = origin.host ?? ""
                    asked.append(host)
                    let a = try XCTUnwrap(answers[host], "\(name) at \(at): \(host) was asked and the vector has no answer for it")
                    let cls = Self.classify(route, a)
                    if cls != .unreachable {
                        set.settle(role, origin, at: now, probe: probe)
                        ended = cls
                        by = host
                        break
                    }
                }
                let at_ = "\(name) at \(at)"
                XCTAssertEqual(asked, step["asked"] as? [String], at_)
                XCTAssertEqual(ended.rawValue, step["class"] as? String, at_)
                XCTAssertEqual(by, step["by"] as? String, at_)
                XCTAssertEqual(asked.count > 1, step["fallback"] as? Bool, at_)
                XCTAssertEqual(probe, step["probe"] as? Bool, at_)
                XCTAssertEqual(set.preferred(role), step["p_after"] as? String, "\(at_): P after")
                replayed += 1
            }
        }
        // every step of the api and models sequences (the web_frame one is the web's)
        XCTAssertEqual(replayed, 49)
    }

    /// 28.4: the manifest of a build before the install holds a lease of it comes from the folder
    /// qlab-api names in every lease answer (the model base's path, the config's model, the build, its folder); with a
    /// lease held, from that lease's folder; through the models order, a folder host that is not one of the role's
    /// first. Every host answers 503 here, so the request asks them all, in order.
    func testFirstManifest() async throws {
        let cases = try XCTUnwrap(try Self.vectors()["first_manifest"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 3)
        defer { StubProtocol.reset { _ in .down } }
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let r = try XCTUnwrap(c["recommended"] as? [String: String])
            let id = ModelID(try XCTUnwrap(r["model_id"]), repository: try XCTUnwrap(r["model"]), folder: r["folder"])
            let build = try XCTUnwrap(r["revision"])
            let leaseBase = (c["lease_base"] as? String).flatMap { URL(string: $0) }
            for (standby, key) in [(false, "asks_with_p_first"), (true, "asks_with_p_standby")] {
                let now = Date(timeIntervalSince1970: 1_800_000_000)
                let set = EndpointSet(api: EndpointSet.builtInOrigins(.api), models: EndpointSet.builtInOrigins(.models), clock: { now })
                if standby { set.settle(.models, Endpoints.origin("cdn-b.tajweedformer.com"), at: now, probe: false) }
                var cdn = CDNClient(http: HTTPClient(session: StubProtocol.session(), endpoints: set), base: ModelHost.manifestBase(explicit: nil),
                                    auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                                    verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
                cdn.leaseFolder = { (b: String) -> URL? in b == build ? leaseBase : nil }
                StubProtocol.reset { _ in StubProtocol.Reply.json(["error": "service_unavailable"], status: 503) }
                _ = try? await cdn.manifest(id, revision: build)
                XCTAssertEqual(StubProtocol.seen.map { $0.url.host ?? "" }, c[key] as? [String], "\(name): \(key)")
                XCTAssertEqual(Set(StubProtocol.seen.map(\.url.path)), [try XCTUnwrap(c["path"] as? String)], "\(name): the path")
            }
        }
    }
}
