// Debug builds only: the tests name hosts through StagingHooks.hostOrigins, which a release build does not have.
#if DEBUG
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.1, contract 28.2 and 28.8 check 7 on REAL sockets: a signed config's `endpoints` reorders and disables the
/// built-in api hosts and adds an allowed one, which is then asked; a host off the allow-list, a lookalike, a list of 9
/// and the hosts of a config that has expired are never asked. Every name is a loopback server (`HostServer`, through
/// the debug-only `StagingHooks.hostOrigins`), so a host that is asked shows in its own log.
final class ConfigEndpointsTests: XCTestCase {
    static let a = "api.quranlab.ai", b = "api-b.tajweedformer.com", g = "api-g.tajweedformer.com", x4 = "api-a.tajweedformer.com"
    static let added = "api-x.tajweedformer.com", off = "api.example.net", lookalike = "evilquranlab.ai"

    override func tearDown() {
        StagingHooks.hostOrigins.withLock { $0 = [:] }
    }

    /// The servers by name; each answers the token, the config of `config` and the probe route (`/v1/origin-check`) of
    /// `probe`; every probe request is logged by host.
    final class Hosts: @unchecked Sendable {
        var servers: [String: HostServer] = [:]
        let config = Locked<StubProtocol.Reply>(CloudFixtures.config())
        let probe = Locked<[String: HostServer.Reply]>([:])
        let probes = Locked<[String]>([])
        func stop() { servers.values.forEach { $0.stop() } }
        func clear() { probes.withLock { $0 = [] } }
    }

    func hosts() throws -> Hosts {
        let h = Hosts()
        for name in [Self.a, Self.b, Self.g, Self.x4, Self.added, Self.off, Self.lookalike] {
            h.servers[name] = try HostServer(name) { [weak h] r in
                guard let h else { return .close }
                switch r.path {
                case "/v1/attest": return .json(["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false])
                case "/v1/config":
                    let c = h.config.withLock { $0 }
                    return .answer(status: c.status, headers: c.headers, body: c.body)
                case "/v1/origin-check":
                    h.probes.withLock { $0.append(name) }
                    return h.probe.withLock { $0[name] } ?? .json(["ok": true])
                default: return .answer(status: 404, headers: [:], body: Data())
                }
            }
        }
        let map = h.servers.mapValues(\.origin)
        StagingHooks.hostOrigins.withLock { $0 = map }
        return h
    }

    /// A server client on the loopback hosts (its API at the first built-in host's server).
    func cloud(_ h: Hosts, storage: URL) throws -> QuranLabCloud {
        var o = CloudFixtures.options(storage: storage)
        o.cloud?.apiURL = try XCTUnwrap(h.servers[Self.a]).origin
        o.cloud?.urlSession = HostSession.make()
        return CloudFixtures.cloud(storage: storage, options: o)
    }

    /// One request of the API made on its first host, through the order in force.
    func probe(_ cloud: QuranLabCloud) async -> Int? {
        let r = URLRequest(url: cloud.options.apiURL.appendingPathComponent("v1/origin-check"))
        return try? await cloud.http.send(r).status
    }

    func testAConfigsEndpointsAreTheListWhileItIsInForce() async throws {
        let h = try hosts()
        defer { h.stop() }
        let cloud = try cloud(h, storage: CloudFixtures.storage())
        // the built-in list before any config: the first host
        _ = await probe(cloud)
        XCTAssertEqual(h.probes.withLock { $0 }, [Self.a])

        // a config that puts a backup host first, leaves the first host out, adds an allowed host, and names a host of
        // another domain and a lookalike (dropped)
        h.config.withLock { $0 = CloudFixtures.config(extra: ["endpoints": ["api": [Self.b, Self.added, Self.lookalike, Self.off]]]) }
        let first = await cloud.refreshConfig()
        XCTAssertNotNil(first)
        XCTAssertEqual(cloud.endpoints.hosts(.api).map { $0.port ?? 0 }, [h.servers[Self.b]!.port, h.servers[Self.added]!.port].map { Int($0) })
        h.clear()
        h.probe.withLock { $0 = [Self.b: .json(["error": "service_unavailable"], status: 503)] }
        let status = await probe(cloud)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(h.probes.withLock { $0 }, [Self.b, Self.added], "the config's list: the backup host first, then the added host")
        // the added host answered: it is asked first now; the first host, the lookalike and the other domain never
        h.clear()
        h.probe.withLock { $0 = [:] }
        _ = await probe(cloud)
        XCTAssertEqual(h.probes.withLock { $0 }, [Self.added])
        for never in [Self.lookalike, Self.off] {
            XCTAssertTrue(try XCTUnwrap(h.servers[never]).log.withLock { $0 }.isEmpty, "\(never) is never asked")
        }

        // a list of 9 is refused whole: the built-in list, from its first host
        h.config.withLock {
            $0 = CloudFixtures.config(extra: ["endpoints": ["api": (0..<9).map { "api-\($0).quranlab.ai" }]])
        }
        let nine = await cloud.refreshConfig()
        XCTAssertNotNil(nine)
        h.clear()
        _ = await probe(cloud)
        XCTAssertEqual(h.probes.withLock { $0 }, [Self.a], "more than 8: the built-in list")
    }

    /// A stored config past its `expires_at` is not in force: its hosts are never asked, the built-in list is.
    func testTheHostsOfAnExpiredConfigAreNeverAsked() async throws {
        let h = try hosts()
        defer { h.stop() }
        let storage = CloudFixtures.storage()
        let expired = CloudFixtures.config(expires: Int(Date().timeIntervalSince1970) - 60,
                                           extra: ["endpoints": ["api": [Self.added, Self.b]]])
        let saved = ConfigStore.Saved(body: expired.body, signature: expired.headers["x-qlab-signature"] ?? "",
                                      keyID: expired.headers["x-qlab-key-id"], etag: expired.headers["etag"])
        JSONFile<ConfigStore.Saved>(url: storage.appendingPathComponent("cloud/config.json")).write(saved)
        let cloud = try cloud(h, storage: storage)
        XCTAssertNil(cloud.currentConfig, "an expired config is not in force")
        _ = await probe(cloud)
        XCTAssertEqual(h.probes.withLock { $0 }, [Self.a])
        XCTAssertEqual(cloud.endpoints.hosts(.api).count, 4, "the built-in list")
        XCTAssertTrue(try XCTUnwrap(h.servers[Self.added]).log.withLock { $0 }.isEmpty, "the expired config's added host is never asked")
    }
}
#endif
