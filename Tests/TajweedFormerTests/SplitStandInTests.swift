import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract 35.11: the checks on the stand-in (`tools/throttle_server.py`, loopback only), run by
/// `scripts/split_standin/run_standin.py` on a Mac. Skipped unless `QLAB_STANDIN` names the runner's plan: the hosts
/// (and the same hosts behind a shared link that applies backpressure, for the phone-bound case), the files, and the
/// scenarios with each host's mode. Each scenario sets the hosts' modes through the stand-in's control route, runs one
/// install of the CPU set through the SDK's installer and URLSession, and writes what happened (time, each host's
/// requests with their Range and bytes sent, the decide's counts and verdict, P, the bytes discarded) to the plan's
/// `out`; the runner compares it with the reference simulator on the same trace.
final class SplitStandInTests: XCTestCase {
    struct Plan: Decodable {
        struct File: Decodable {
            let path: String
            let role: String
            let context: String
        }
        struct Scenario: Decodable {
            let name: String
            /// each host's mode for throttle_server's control route (every field, so nothing is left from before)
            let modes: [String: [String: JSONValue]]
            /// the hosts of the order, first first
            let order: [String]
            /// through the shared link
            let link: Bool
            let share: Bool
            /// a second install right after, with the same process memory (35.11 item 3: within 30 min); its modes
            let again: [String: [String: JSONValue]]?
        }
        let root: String
        let strip: String
        let files: [File]
        let hosts: [String: String]
        let linked: [String: String]
        let out: String
        let scenarios: [Scenario]
    }

    func testTheStandInScenarios() async throws {
        guard let path = ProcessInfo.processInfo.environment["QLAB_STANDIN"] else { throw XCTSkip("QLAB_STANDIN is not set") }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // the manifest of the stand-in's files (their SHA-256 read once here)
        var files: [ModelManifest.File] = []
        for f in plan.files {
            let data = try Data(contentsOf: URL(fileURLWithPath: plan.root).appendingPathComponent(f.path))
            let sha = Data(SHA256.hash(data: data)).hex
            files.append(ModelManifest.File(path: f.path, size: Int64(data.count), sha256: sha, platforms: ["*"], context: f.context, role: f.role,
                                            encoding: "qle1", decoded: .init(path: String(f.path.dropLast(4)), size: Int64(data.count - 20), sha256: sha)))
        }
        var manifest = ModelManifest(modelID: "v4.0", revision: "standin", version: "4.0.0", minSDKVersion: "4.0.0",
                                     tokensSHA256: String(repeating: "0", count: 64), defaultContext: "c16_l64", contexts: ["c16_l64"], files: files)
        manifest.encryption = .init(keyID: "d14d9aeeeecb3a238cb86c41a5e8b0c2", root: 1)
        var results: [[String: Any]] = []
        for s in plan.scenarios {
            let memory = SplitMemory()
            var r = try await run(plan, s, s.modes, manifest, memory, link: s.link)
            if let again = s.again {
                // the phone-bound hold is the connection type's, whatever the link: the second download goes direct
                r["again"] = try await run(plan, s, again, manifest, memory, link: false)
            }
            results.append(r)
            print("stand-in \(s.name): \(r["seconds"] ?? "?") s, requests \(r["requests"] ?? "?"), verdict \(r["verdict"] ?? "none")")
            let d = try JSONSerialization.data(withJSONObject: ["results": results], options: [.prettyPrinted, .sortedKeys])
            try d.write(to: URL(fileURLWithPath: plan.out))
        }
    }

    /// One install of the CPU set with these modes; what happened.
    private func run(_ plan: Plan, _ s: Plan.Scenario, _ modes: [String: [String: JSONValue]], _ manifest: ModelManifest,
                     _ memory: SplitMemory, link: Bool) async throws -> [String: Any] {
        let ctl = try XCTUnwrap(URL(string: plan.hosts[s.order[0]]!)?.appendingPathComponent("_ctl"))
        try await post(ctl, ["reset_log": .bool(true)])
        for (host, mode) in modes.sorted(by: { $0.key < $1.key }) {
            var body = mode
            body["host"] = .string(host)
            try await post(ctl, body)
        }
        try await post(ctl, ["time_zero": .bool(true)])
        let origins = s.order.map { URL(string: (link ? plan.linked : plan.hosts)[$0]!)! }
        var named: [String: String] = [:]
        for (i, o) in origins.enumerated() { named[SplitHosts.key(o)] = s.order[i] }
        let names = named
        let endpoints = EndpointSet(api: [URL(string: "https://api.quranlab.ai")!], models: origins)
        let session = HostSession.make()
        let client = CDNClient(http: HTTPClient(session: session, endpoints: endpoints), base: origins[0],
                               auth: .fixed(key: "qlk_v1_test", token: "qlt_test"), verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
        let base = origins[0].appendingPathComponent(String(plan.strip.dropFirst()), isDirectory: true)
        var installer = ModelInstaller(source: client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "standin", base: base),
                                       retryPauses: [1, 2, 4, 8, 16])
        let folder = CloudFixtures.storage().appendingPathComponent("models/v4.0/.download-standin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        let core = ModelDownloadTests.CoreStandIn()
        installer.install = core.install(in: folder)
        let counts = Locked<[[Any]]>([]), wasted = Locked<[[Any]]>([]), settled = Locked<[String]>([]), verdicts = Locked<[String]>([])
        let actions = Locked<[String]>([])
        var p = SplitPlan(shareOn: s.share)
        p.conn = "wired"
        p.memory = memory
        p.count = { f, h, n in counts.withLock { $0.append([f, names[h] ?? h, n]) } }
        p.wasted = { h, n in wasted.withLock { $0.append([names[h] ?? h, n]) } }
        p.settle = { o in
            settled.withLock { $0.append(names[SplitHosts.key(o)] ?? o.absoluteString) }
            endpoints.settle(.models, o, at: Date(), probe: false)
        }
        p.trace = { line in
            if line.hasPrefix("action verdict") { verdicts.withLock { $0.append(line) } }
            if line.hasPrefix("action start") || line.hasPrefix("action cut") || line.hasPrefix("action restart") { actions.withLock { $0.append(line) } }
        }
        installer.split = p
        let cpu = DownloadProfile(context: "c16_l64", coreML: false)
        let began = Date()
        var failure: String?
        do {
            _ = try await installer.install(manifest, profile: cpu, into: folder)
        } catch {
            failure = "\(error)"
        }
        let seconds = Date().timeIntervalSince(began)
        // the cuts' discards are told once each cut transfer has stopped
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        var logs: [String: Any] = [:]
        for h in Set(s.order) {
            let u = URL(string: plan.hosts[h]!)!.appendingPathComponent("_log")
            let (d, _) = try await session.data(from: u)
            let o = try JSONSerialization.jsonObject(with: d) as? [String: Any]
            logs[h] = (o?["log"] as? [[String: Any]] ?? []).filter { ($0["path"] as? String ?? "").hasPrefix(plan.strip) }
        }
        let weights = manifest.files.first { $0.role == "weights" }!
        let installed = core.installed.withLock { $0 }
        return ["name": s.name, "seconds": seconds, "failure": failure as Any, "installed": installed.count,
                "weights_installed": installed.contains(weights.path), "files": manifest.files.count,
                "counts": counts.withLock { $0 }, "wasted": wasted.withLock { $0 }, "settled": settled.withLock { $0 },
                "verdicts": verdicts.withLock { $0 }, "actions": actions.withLock { $0 }, "logs": logs,
                "requests": (logs.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }).count,
                "bad": memory.snapshot.bad.map { names[$0] ?? $0 }, "read_again": PartHasher.readAgain.withLock { $0 },
                // P as the Client keeps it after the install: the host the next models request asks first
                "p": endpoints.order(.models, at: Date()).hosts.first.map { names[SplitHosts.key($0)] ?? $0.absoluteString } as Any]
    }

    private func post(_ url: URL, _ body: [String: JSONValue]) async throws {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = try JSONEncoder().encode(body)
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        let (_, resp) = try await HostSession.make().data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, "control \(body)")
    }
}
