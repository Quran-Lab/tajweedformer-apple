import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 35 on the SDK's real HTTP code: the installer, the CDN client and URLSession against
/// loopback hosts that pace their answers (`HostServer.paced`, a rate per host and a link shared by all, as the
/// reference simulator models them), with the contract's constants. Each case is the simulator's trace of the same
/// rates (`tools/split40.py` `Sim`, sized on 2026-11-23): what the decide starts, cuts and counts, and when the file is
/// whole and right.
final class SplitHookTests: XCTestCase {
    static let mib = 1 << 20
    static let weights = "layers.zfw.qle"

    /// The CPU set of a stand-in build: the weights file and three small files beside it (lanes).
    static func layout(weights size: Int) -> [(path: String, context: String, role: String, size: Int)] {
        [("tokens.txt.qle", "*", "tokens", 100_000), ("calibration.json.qle", "*", "calibration", 10_000),
         (weights, "*", "weights", size), ("c16_l64/frames.zfw.qle", "c16_l64", "frames", 200_000)]
    }

    /// Bytes for a file: a random MiB repeated, each copy marked with its place.
    static func bytes(_ n: Int, seed: UInt64) -> Data {
        var g = SystemRandomNumberGenerator()
        var block = Data(count: 1 << 20)
        block.withUnsafeMutableBytes { raw in
            for i in 0..<(raw.count / 8) { raw.storeBytes(of: g.next() as UInt64, toByteOffset: i * 8, as: UInt64.self) }
        }
        var d = Data(capacity: n)
        var k = seed << 32
        while d.count < n {
            var piece = block.prefix(min(block.count, n - d.count))
            withUnsafeBytes(of: k) { mark in piece.replaceSubrange(piece.startIndex..<(piece.startIndex + min(8, piece.count)), with: mark.prefix(piece.count)) }
            d.append(piece)
            k += 1
        }
        return d
    }

    final class Rig: @unchecked Sendable {
        let a: HostServer, b: HostServer, d: HostServer
        let files: [String: Data]
        let manifest: ModelManifest
        let memory: SplitMemory
        let counts = Locked<[String]>([])
        let wasted = Locked<[(host: String, bytes: Int64)]>([])
        let settled = Locked<[URL]>([])
        let trace = Locked<[String]>([])
        /// The report of the last install (SDK 4.0.5, 38.8: what it continued from).
        let report = Locked(InstallReport())
        let endpoints: EndpointSet
        let storage: URL

        /// Three hosts in this order (a first); `serve` answers each host's requests.
        init(weights size: Int, memory: SplitMemory = SplitMemory(),
             serve: @escaping @Sendable (_ host: String, _ r: HostServer.Request, _ data: Data) -> HostServer.Reply) throws {
            var f: [String: Data] = [:]
            for (k, x) in SplitHookTests.layout(weights: size).enumerated() { f[x.path] = SplitHookTests.bytes(x.size, seed: UInt64(k)) }
            let files = f
            self.files = files
            func handler(_ name: String) -> @Sendable (HostServer.Request) -> HostServer.Reply {
                { r in
                    guard let at = r.path.range(of: "/sdk/v4.0/"), let data = files[String(r.path[at.upperBound...])] else {
                        return .answer(status: 404, headers: [:], body: Data())
                    }
                    return serve(name, r, data)
                }
            }
            a = try HostServer("a", handler: handler("a"))
            b = try HostServer("b", handler: handler("b"))
            d = try HostServer("d", handler: handler("d"))
            self.memory = memory
            let ms = SplitHookTests.layout(weights: size).map { x -> ModelManifest.File in
                let sha = Data(SHA256.hash(data: files[x.path]!)).hex
                return ModelManifest.File(path: x.path, size: Int64(x.size), sha256: sha, platforms: ["*"], context: x.context, role: x.role,
                                          encoding: "qle1", decoded: .init(path: String(x.path.dropLast(4)), size: Int64(x.size - 20), sha256: sha))
            }
            var m = ModelManifest(modelID: "v4.0", revision: "split", version: "4.0.0", minSDKVersion: "4.0.0",
                                  tokensSHA256: String(repeating: "0", count: 64), defaultContext: "c16_l64", contexts: ["c16_l64"], files: ms)
            m.encryption = .init(keyID: "d14d9aeeeecb3a238cb86c41a5e8b0c2", root: 1)
            manifest = m
            endpoints = EndpointSet(api: [URL(string: "https://api.quranlab.ai")!], models: [a.origin, b.origin, d.origin])
            storage = CloudFixtures.storage()
        }

        func key(_ s: HostServer) -> String { "127.0.0.1:\(s.port)" }

        /// One install of the CPU set through the SDK's installer, into a new folder: how long it took, and the Core's
        /// stand-in (it installs a file only when it is whole and its SHA-256 is the manifest's).
        func install(share: Bool = true) async throws -> (seconds: Double, core: ModelDownloadTests.CoreStandIn) {
            let folder = storage.appendingPathComponent("models/v4.0/.download-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let client = CDNClient(http: HTTPClient(session: HostSession.make(), endpoints: endpoints), base: a.origin,
                                   auth: .fixed(key: "qlk_v1_test", token: "qlt_test"),
                                   verifier: ManifestVerifier(trustedKeys: [], requireSignature: false))
            let base = a.origin.appendingPathComponent("models/Quran-Lab/m/b/sdk/v4.0/", isDirectory: true)
            var installer = ModelInstaller(source: client.source(ModelID("v4.0", repository: "Quran-Lab/m"), revision: "split", base: base),
                                           retryPauses: [0.2, 0.2, 0.2, 0.2, 0.2])
            let core = ModelDownloadTests.CoreStandIn()
            installer.install = core.install(in: folder)
            var plan = SplitPlan(shareOn: share)
            plan.conn = "wifi"
            plan.memory = memory
            let counts = self.counts, wasted = self.wasted, settled = self.settled, trace = self.trace
            plan.count = { f, h, n in counts.withLock { $0.append("\(f) \(h) \(n)") } }
            plan.wasted = { h, n in wasted.withLock { $0.append((h, n)) } }
            // P through the Client's own endpoint set, so the hosts' later answers are seen to keep it (or not)
            let endpoints = self.endpoints
            plan.settle = { o in
                settled.withLock { $0.append(o) }
                endpoints.settle(.models, o, at: Date(), probe: false)
            }
            plan.trace = { line in trace.withLock { $0.append(line) } }
            installer.split = plan
            let began = Date()
            do {
                let r = try await installer.install(manifest, profile: DownloadProfile(context: "c16_l64", coreML: false), into: folder)
                report.withLock { $0 = r }
                return (Date().timeIntervalSince(began), core)
            } catch {
                // which side was silent: requests the hosts never logged are the client's or the connection's; logged
                // ones with no byte sent and not ended are answers that never started on the server
                print("SPLIT-RIG: the install failed after \(Int(Date().timeIntervalSince(began))) s (\(error)); \(diagnosis())")
                throw error
            }
        }

        /// Each host's requests and its paced answers: the bytes each sent and whether it ended.
        func diagnosis() -> String {
            [a, b, d].map { s in
                let sent = s.sent.withLock { $0 }.map { "\($0.bytes.withLock { $0 })\($0.ended.withLock { $0 } ? "" : " open")" }
                return "\(s.name): \(s.log.withLock { $0.count }) requests, answers sent [\(sent.joined(separator: ", "))]"
            }.joined(separator: "; ")
        }

        /// The weights file's answers of a host: Range, If-Range, body bytes sent.
        func weights(_ s: HostServer) -> [HostServer.Sent] {
            let paths = s.log.withLock { $0.map(\.path) }
            let sent = s.sent.withLock { $0 }
            return zip(paths, sent).filter { $0.0.hasSuffix("/" + SplitHookTests.weights) }.map(\.1)
        }

        func has(_ count: String) -> Bool { counts.withLock { $0 }.contains(count) }

        /// Waits up to 3 s for the discarded bytes of the cuts to be told (they are measured once a cut transfer stopped).
        func wastedSoon(_ n: Int) async -> [(host: String, bytes: Int64)] {
            for _ in 0..<60 where wasted.withLock({ $0.count }) < n { try? await Task.sleep(nanoseconds: 50_000_000) }
            return wasted.withLock { $0 }
        }

        func dump() -> String { trace.withLock { $0 }.joined(separator: "\n") }

        /// The host the next models request asks first: P as the Client keeps it.
        var p: URL? { endpoints.order(.models, at: Date()).hosts.first }
    }

    /// The range a `Range` header names.
    static func range(_ h: String?) -> (lo: Int, end: Int?)? {
        guard let h, h.hasPrefix("bytes=") else { return nil }
        let p = h.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 2, let lo = Int(p[0]) else { return nil }
        return (lo, Int(p[1]).map { $0 + 1 })
    }

    /// 35.11 item 2 (the simulator's `throttled`: the first host at 1 MB/s, the second at 10 MB/s, 20 MiB): the second
    /// host takes the tail at 5.5 s, a server-bound verdict, P the second host, done well before one host's 21 s; the
    /// file whole and right, its hash still made as its bytes were joined.
    func testAThrottledHostGetsASecondHostForItsTail() async throws {
        let size = 20 * Self.mib
        let pa = Pacer(1_000_000), pb = Pacer(10_000_000)
        let rig = try Rig(weights: size) { host, r, data in
            HostServer.file(r, data: data, pacers: host == "a" ? [pa] : [pb])
        }
        let readAgain = PartHasher.readAgain.withLock { $0 }
        let (seconds, core) = try await rig.install()
        print("throttled: \(String(format: "%.1f", seconds)) s; a: \(rig.weights(rig.a).map { "\($0.range ?? "whole") sent \($0.bytes.withLock { $0 })" }); "
            + "b: \(rig.weights(rig.b).map { "\($0.range ?? "whole") sent \($0.bytes.withLock { $0 })" }); counts \(rig.counts.withLock { $0 })")
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(Self.layout(weights: size).map(\.path)), "every file whole and right")
        let onB = rig.weights(rig.b)
        XCTAssertFalse(onB.isEmpty, "the second host took a range\n\(rig.dump())")
        let first = try XCTUnwrap(Self.range(onB.first?.range))
        XCTAssertEqual(first.lo % SplitConstants.align, 0, "the split point is a multiple of 64 KiB")
        XCTAssertEqual(first.end, size, "B's first range runs to the end of the file")
        XCTAssertTrue(onB.allSatisfy { $0.ifRange == nil }, "a range never carries If-Range")
        XCTAssertNil(rig.weights(rig.a).first?.range, "the file's own request is one GET, no Range")
        XCTAssertTrue(rig.has("would_probe \(rig.key(rig.a)) 1"))
        XCTAssertTrue(rig.has("probes \(rig.key(rig.b)) 1"))
        XCTAssertTrue(rig.counts.withLock { $0 }.contains { $0.hasPrefix("gain \(rig.key(rig.a)) ") && Int($0.split(separator: " ").last!)! >= 3 },
                      "a verdict of 1.5 or more on the first host")
        XCTAssertTrue(rig.trace.withLock { $0 }.contains { $0.contains("verdict(kind: \"server_bound\"") })
        XCTAssertEqual(rig.settled.withLock { $0 }.last, rig.b.origin, "P is the second host")
        XCTAssertEqual(rig.p, rig.b.origin, "P stays the second host: the first host's cut answer does not take it back")
        XCTAssertLessThan(seconds, 15, "well before one host's 21 s")
        XCTAssertEqual(PartHasher.readAgain.withLock { $0 }, readAgain, "the hash was made as the bytes were written and joined")
        // SDK 4.0.5 (38.8): the second host's range of this call is no kept byte and no system's carrier
        let report = rig.report.withLock { $0 }
        XCTAssertFalse(report.joinedBackground, "the split's own range is not a background task's")
        XCTAssertEqual(report.keptBytes, 0)
        XCTAssertNil(DownloadContinuity(report).continued)
        // no byte twice: the ranges written are disjoint, and the bytes sent are the file plus at most the discards
        let total = (rig.weights(rig.a) + rig.weights(rig.b)).map { $0.bytes.withLock { $0 } }.reduce(0, +)
        XCTAssertLessThanOrEqual(total, size + 2 * Self.mib, "what both hosts sent of the weights: the file and the bytes in flight at the cuts")
    }

    /// 35.11 item 3 (the simulator's `phone 1MB`: both hosts fast, the phone's link at 1 MB/s for all): one range, a
    /// phone-bound verdict, no steal, the bytes discarded at the cut under 1 MiB, P unchanged, the finish within 8% of
    /// what the link alone allows; then a second download within 30 min sends no range.
    func testAPhoneBoundLinkSplitsOnceThenHoldsOff() async throws {
        let size = 20 * Self.mib
        let link = Pacer(1_000_000)
        let memory = SplitMemory()
        let rig = try Rig(weights: size, memory: memory) { _, r, data in HostServer.file(r, data: data, pacers: [link]) }
        let (seconds, core) = try await rig.install()
        let wasted = await rig.wastedSoon(1)
        let all = Self.layout(weights: size).map(\.size).reduce(0, +)
        print("phone-bound: \(String(format: "%.1f", seconds)) s for \(all) bytes at 1 MB/s; b: \(rig.weights(rig.b).map { $0.range ?? "" }); "
            + "wasted \(wasted); a sent \(rig.weights(rig.a).map { $0.bytes.withLock { $0 } })")
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(Self.layout(weights: size).map(\.path)))
        XCTAssertEqual(rig.weights(rig.b).count, 1, "one range\n\(rig.dump())")
        XCTAssertEqual(rig.weights(rig.a).count, 1, "no steal")
        XCTAssertTrue(rig.trace.withLock { $0 }.contains { $0.contains("verdict(kind: \"phone_bound\"") })
        XCTAssertTrue(rig.settled.withLock { $0 }.isEmpty, "P does not change")
        XCTAssertEqual(rig.p, rig.a.origin, "P is the first host")
        XCTAssertTrue(wasted.contains { $0.host == rig.key(rig.a) }, "the first host's cut at m is measured (35.5 item 4)")
        XCTAssertLessThanOrEqual(wasted.map(\.bytes).reduce(0, +), Int64(Self.mib), "the bytes discarded at the cut")
        let alone = Double(all) / 1_000_000
        XCTAssertLessThan(seconds, alone * 1.08, "within 8% of one host's time on this link (\(alone) s)")
        XCTAssertGreaterThan(memory.phoneBoundUntil("wifi"), SplitClock.now(), "probes held off on this connection type")

        // the second download within 30 min: a stall triggers, and is counted, and no range goes out
        let pa = Pacer(4_000_000, stalls: [(from: 2.0, to: 5.0)])
        let again = try Rig(weights: size, memory: memory) { host, r, data in HostServer.file(r, data: data, pacers: host == "a" ? [pa] : []) }
        _ = try await again.install()
        XCTAssertTrue(again.has("would_probe \(again.key(again.a)) 1"), "\(again.counts.withLock { $0 })")
        XCTAssertTrue(again.weights(again.b).isEmpty, "no range within 30 min of a phone-bound verdict")
    }

    /// 35.11 item 4 (the simulator's `corrupt_a 500k`): the first host serves one wrong byte; the mismatch fetches the
    /// first host's ranges again from the host that brought the most bytes, the file then passes, `bad_body` on the
    /// first host, which is bad for the process; the file is not downloaded again.
    func testAWrongByteOnTheFirstHostIsFoundByFetchingItsRangesAgain() async throws {
        let size = 20 * Self.mib
        let pa = Pacer(500_000), pb = Pacer(10_000_000)
        let rig = try Rig(weights: size) { host, r, data in
            var d = data
            if host == "a", r.path.hasSuffix("/" + SplitHookTests.weights) { d[100_000] ^= 0xFF }
            return HostServer.file(r, data: d, pacers: host == "a" ? [pa] : [pb])
        }
        let (seconds, core) = try await rig.install()
        print("corrupt a: \(String(format: "%.1f", seconds)) s; a: \(rig.weights(rig.a).map { $0.range ?? "whole" }); b: \(rig.weights(rig.b).map { $0.range ?? "" }); "
            + "counts \(rig.counts.withLock { $0 })")
        XCTAssertTrue(core.installed.withLock { $0 }.contains(Self.weights), "the file installs right\n\(rig.dump())")
        XCTAssertTrue(rig.has("bad_body \(rig.key(rig.a)) 1"))
        XCTAssertEqual(rig.memory.snapshot.bad, [rig.key(rig.a)])
        XCTAssertTrue(rig.weights(rig.b).contains { Self.range($0.range)?.lo == 0 }, "the first host's range fetched again from the second")
        XCTAssertEqual(rig.weights(rig.a).filter { $0.range == nil }.count, 1, "the file was not started again")
    }

    /// 35.5 item 3 (the simulator's `stall_a`): the first host stops sending at 2 s; 2 s of silence later the file goes
    /// on from its byte on the second host, `slow_switches` on the first, and P is the host that finished it.
    func testAStalledFirstHostMovesTheRestToTheNext() async throws {
        let size = 20 * Self.mib
        let pa = Pacer(4_000_000, stalls: [(from: 2.0, to: 600)]), pb = Pacer(10_000_000)
        let rig = try Rig(weights: size) { host, r, data in HostServer.file(r, data: data, pacers: host == "a" ? [pa] : [pb]) }
        let (seconds, core) = try await rig.install()
        print("stall a: \(String(format: "%.1f", seconds)) s; b: \(rig.weights(rig.b).map { $0.range ?? "" }); counts \(rig.counts.withLock { $0 })")
        XCTAssertTrue(core.installed.withLock { $0 }.contains(Self.weights), "\(rig.dump())")
        let moved = try XCTUnwrap(Self.range(rig.weights(rig.b).first?.range))
        XCTAssertGreaterThan(moved.lo, 0)
        XCTAssertEqual(moved.end, size)
        XCTAssertTrue(rig.has("slow_switches \(rig.key(rig.a)) 1"))
        XCTAssertEqual(rig.settled.withLock { $0 }.last, rig.b.origin, "P is the host that finished the file")
        XCTAssertEqual(rig.p, rig.b.origin, "and it stays so")
        XCTAssertLessThan(seconds, 12)
    }

    /// 35.2: outside the share, a trigger is counted (`would_probe`) and nothing is sent.
    func testOutsideTheShareTheTriggerIsCountedAndNothingIsSent() async throws {
        let size = 20 * Self.mib
        let pa = Pacer(4_000_000, stalls: [(from: 2.0, to: 5.5)])
        let rig = try Rig(weights: size) { host, r, data in HostServer.file(r, data: data, pacers: host == "a" ? [pa] : []) }
        let (_, core) = try await rig.install(share: false)
        XCTAssertTrue(core.installed.withLock { $0 }.contains(Self.weights))
        XCTAssertTrue(rig.has("would_probe \(rig.key(rig.a)) 1"), "\(rig.counts.withLock { $0 })")
        XCTAssertTrue(rig.weights(rig.b).isEmpty)
        XCTAssertTrue(rig.b.log.withLock { $0 }.isEmpty, "the second host is never asked")
    }

    /// 35.11 item 5 (16.7): a fast host: one request per file, no Range, nothing counted, the hook on.
    func testAFastHostIsOneRequestPerFile() async throws {
        let size = 20 * Self.mib
        let rig = try Rig(weights: size) { _, r, data in HostServer.file(r, data: data, pacers: []) }
        let (_, core) = try await rig.install()
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(Self.layout(weights: size).map(\.path)))
        let asked = rig.a.sent.withLock { $0 }
        XCTAssertEqual(asked.count, Self.layout(weights: size).count, "one request per file")
        XCTAssertTrue(asked.allSatisfy { $0.range == nil }, "no Range")
        XCTAssertTrue(rig.b.log.withLock { $0 }.isEmpty)
        XCTAssertTrue(rig.counts.withLock { $0 }.isEmpty)
    }

    /// The same install with every thread of the shared global queue parked. In the full runs of 2026-11-23 from 17:06
    /// to 19:02 every test of this class failed so after 70 s (`the host sent no byte before an answer within 10 s`):
    /// the hosts logged each request and none of their paced answers started. These tests now need nothing of that
    /// queue (`HostServerTests.testAPacedAnswerGoesOutWhileTheSharedPoolIsParked`).
    func testTheHostsAnswerWithTheSharedPoolParked() async throws {
        let size = 8 * Self.mib
        let rig = try Rig(weights: size) { _, r, data in HostServer.file(r, data: data, pacers: []) }
        let (seconds, core) = try await HostServerTests.withTheSharedPoolParked { try await rig.install() }
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(Self.layout(weights: size).map(\.path)))
        XCTAssertLessThan(seconds, 10, "no request waited for the silence limit")
    }

    /// 34.4: the first host has no status 1.5 s after the request; the same request goes to the next host, without
    /// If-Range, its answer is taken, the first request is cancelled, and the files go on there (P), with `hedged`.
    func testASilentFirstHostIsHedgedAt1_5s() async throws {
        let size = 2 * Self.mib
        let rig = try Rig(weights: size) { host, r, data in host == "a" ? .hold : HostServer.file(r, data: data, pacers: []) }
        let samples = Locked<[ModelHostSample]>([])
        let (seconds, core) = try await rig.install()
        _ = samples
        print("hedge: \(String(format: "%.2f", seconds)) s; b: \(rig.b.sent.withLock { $0 }.map { "\($0.range ?? "whole") if-range \($0.ifRange ?? "none")" })")
        XCTAssertEqual(Set(core.installed.withLock { $0 }), Set(Self.layout(weights: size).map(\.path)))
        XCTAssertGreaterThanOrEqual(seconds, 1.4)
        XCTAssertLessThan(seconds, 6)
        XCTAssertTrue(rig.b.sent.withLock { $0 }.allSatisfy { $0.ifRange == nil }, "a second request never carries If-Range")
        XCTAssertEqual(rig.endpoints.preferred(.models), "127.0.0.1", "P is the host whose answer was taken")
        XCTAssertTrue(rig.trace.withLock { $0 }.contains { $0.contains("hostOut") && $0.contains(rig.key(rig.a)) },
                      "the first host is out for the split before the second's answer is its `main`\n\(rig.dump())")
    }
}

/// SDK 4.0.5 (34.4) for a model request that is not a file (the build's manifest, through `routed`): the first host
/// silent, the same request to the next host at 1.5 s, its answer taken, P that host, and both requests counted with
/// `hedged` on the first. The `api` role is never hedged.
final class ManifestHedgeTests: XCTestCase {
    func testASilentManifestHostIsHedgedAndTheApiRoleIsNot() async throws {
        let a = try HostServer("a") { _ in .hold }
        let b = try HostServer("b") { _ in .json(["ok": true]) }
        let endpoints = EndpointSet(api: [a.origin, b.origin], models: [a.origin, b.origin])
        let http = HTTPClient(session: HostSession.make(), endpoints: endpoints)
        let samples = Locked<[ModelHostSample]>([])
        http.modelHosts.withLock { $0 = { s in samples.withLock { $0.append(s) } } }
        let began = Date()
        let r = try await http.checked(URLRequest(url: a.origin.appendingPathComponent("models/m/b/manifest.json")), role: .models)
        let took = Date().timeIntervalSince(began)
        XCTAssertEqual(r.status, 200)
        XCTAssertGreaterThanOrEqual(took, 1.4)
        XCTAssertLessThan(took, 5, "not the 10 s of the first host's silence")
        XCTAssertEqual(b.paths, ["/models/m/b/manifest.json"])
        XCTAssertEqual(endpoints.preferred(.models), "127.0.0.1")
        XCTAssertEqual(endpoints.order(.models, at: Date()).hosts.first, b.origin, "P is the host whose answer was taken")
        let s = samples.withLock { $0 }
        XCTAssertEqual(s.count, 2, "both requests count")
        XCTAssertEqual(s.filter(\.hedged).count, 1)
        XCTAssertFalse(s.contains { $0.unreachable }, "the cancelled one is no unreachable host")

        // the api role: the silent first host is asked alone until its silence limit
        let limit = HTTPClient.silenceLimit.withLock { $0 }
        HTTPClient.silenceLimit.withLock { $0 = 2.5 }
        defer { HTTPClient.silenceLimit.withLock { $0 = limit } }
        b.reset { _ in .json(["ok": true]) }
        let began2 = Date()
        _ = try await http.checked(URLRequest(url: a.origin.appendingPathComponent("v1/config")), role: .api)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began2), 2.4, "no hedge for the api role")
    }
}

/// SDK 4.0.5 (35.8): Client start-up never waits for the connection type. The path monitor is started and the type is
/// `other` until its first answer. Red on addb9a2, where `begin` waited up to 0.1 s for that answer.
final class NetworkTypeStartTests: XCTestCase {
    override func tearDown() {
        NetworkType.starter.withLock { $0 = nil }
        NetworkType.forgetForTests()
    }

    func testClientStartUpNeverWaitsForTheConnectionType() throws {
        NetworkType.forgetForTests()
        let tell = Locked<(@Sendable (String) -> Void)?>(nil)
        // a path monitor that has not answered, and will not until the test tells it to
        NetworkType.starter.withLock { $0 = { t in tell.withLock { $0 = t } } }
        let t0 = DispatchTime.now().uptimeNanoseconds
        NetworkType.begin()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        XCTAssertLessThan(ms, 20, "begin returns at once")
        XCTAssertNotNil(tell.withLock { $0 }, "the monitor was started")
        XCTAssertEqual(NetworkType.now, "other", "the type is other until known")

        // a Client made while the monitor has no answer starts without it, and starts the monitor
        NetworkType.forgetForTests()
        tell.withLock { $0 = nil }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let made = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000
        withExtendedLifetime(cloud) {}
        print("a Client made in \(String(format: "%.1f", made)) ms with no connection type known")
        XCTAssertNotNil(tell.withLock { $0 }, "the Client started the monitor")
        XCTAssertEqual(NetworkType.now, "other")
        tell.withLock { $0 }?("wifi")
        XCTAssertEqual(NetworkType.now, "wifi", "known once the monitor answers")
    }
}

/// SDK 4.0.5 (plan 4.13): what the decide costs while a split file downloads: a tick twice a second and an event per
/// 64 KiB written. Measured here on the build machine (a phone is slower; the Alcatel gate of 35.11 item 7 measures it
/// there): the time of one tick and of one `bytes` event in a split with two ranges and lanes, over a file of the
/// release build's size.
final class SplitTickCostTests: XCTestCase {
    func testTheTickAndTheByteEventCostLittle() {
        let size = 53_650_685
        let d = SplitDecide(size: size, order: ["a", "b", "d"], noHelper: [], shareOn: true, memory: SplitMemory(), conn: "wifi")
        _ = d.event(.main(t: 0, id: "r1", host: "a", lo: 0))
        var t = 0, pos = 0
        var bytesNs: UInt64 = 0, ticksNs: UInt64 = 0, nBytes = 0, nTicks = 0
        // 256 kB/s on a, a 64 KiB event every 250 ms, a tick every 500 ms, three lanes of other files
        while t < 600_000, d.phase == "single" || d.phase == "split" {
            t += 250
            var s = DispatchTime.now().uptimeNanoseconds
            _ = d.event(.bytes(t: t, id: "r1", n: 65_536))
            _ = d.event(.lane(t: t, host: "a", n: 1000))
            bytesNs += DispatchTime.now().uptimeNanoseconds - s
            nBytes += 2
            pos += 65_536
            if t % 500 == 0 {
                s = DispatchTime.now().uptimeNanoseconds
                let acts = d.event(.tick(t: t))
                ticksNs += DispatchTime.now().uptimeNanoseconds - s
                nTicks += 1
                for case .start(let id, _, _, _) in acts {
                    _ = d.event(.status(t: t, id: id, kind: "taken"))
                }
            }
            if pos >= size { break }
        }
        let perTick = Double(ticksNs) / Double(max(1, nTicks)) / 1000, perEvent = Double(bytesNs) / Double(max(1, nBytes)) / 1000
        print("split decide cost on this machine: \(String(format: "%.2f", perTick)) us a tick (\(nTicks) ticks), "
            + "\(String(format: "%.2f", perEvent)) us a bytes or lane event (\(nBytes)); phase \(d.phase)")
        XCTAssertLessThan(perTick, 200, "a tick is well under a millisecond")
        XCTAssertLessThan(perEvent, 200)
    }
}

/// SDK 4.0.5 (34.4): the contract's `hedge` vectors (`steering_40.json`), replayed through the gate the SDK's hedge uses.
final class HedgeVectorTests: XCTestCase {
    func testEveryHedgeCaseReplays() throws {
        let h = try XCTUnwrap(try V40.json("steering_40.json")["hedge"] as? [String: Any])
        let hedgeS = try XCTUnwrap(h["hedge_s"] as? Double)
        XCTAssertEqual(hedgeS, CDNFileSource.hedgeAfter.withLock { $0 })
        let cases = try XCTUnwrap(h["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7, "every case of the file is read")
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let first = try XCTUnwrap(c["first"] as? [Any], name)
            let second = c["second"] as? [Any]
            let got = HedgeGate.replay(first: (try XCTUnwrap(first[0] as? Double), try XCTUnwrap(first[1] as? String)),
                                       second: second.map { ($0[0] as? Double ?? 0, $0[1] as? String ?? "") }, hedgeS: hedgeS)
            XCTAssertEqual(got.decidedBy, c["decided_by"] as? String, name)
            XCTAssertEqual(got.at, try XCTUnwrap(c["at"] as? Double, name), accuracy: 1e-9, name)
            XCTAssertEqual(got.outcome, c["outcome"] as? String, name)
            XCTAssertEqual(got.secondSentAt, c["second_sent_at"] as? Double, name)
        }
    }
}

/// SDK 4.0.5 (SPLIT_40 35.9): the five fields of section 35 in every `hosts` entry, a day stored before them read as 0,
/// and the decide's counts, the discarded bytes and the arms counted on their hosts and sent.
final class SplitTelemetryTests: XCTestCase {
    // the bodies with section 35's fields, as once the server takes them (`sendsSplitFields`, off until then)
    override func setUp() { AnalyticsStore.sendsSplitFields.withLock { $0 = true } }
    override func tearDown() { AnalyticsStore.sendsSplitFields.withLock { $0 = false } }

    /// 35.9 (on 11-23 the server did not take the five fields yet): off by default, the entries leave
    /// them out and keep the counts; on, every entry has them.
    func testTheFieldsWaitForTheServer() throws {
        AnalyticsStore.sendsSplitFields.withLock { $0 = false }
        var c = HostCount()
        c.split("probes", 1)
        let off = c.entry(host: "cdn2.quranlab.ai")
        for k in ["probes", "would_probe", "gain", "wasted", "arms"] { XCTAssertNil(off[k], k) }
        XCTAssertEqual(c.probes, 1, "counted all the same")
        XCTAssertNil(HostCountsTests.refusal([off]), "the server takes the entry without them")
        AnalyticsStore.sendsSplitFields.withLock { $0 = true }
        XCTAssertEqual(c.entry(host: "cdn2.quranlab.ai")["probes"] as? Int, 1)
    }

    func testEveryEntryHasTheFiveFields() throws {
        var c = HostCount()
        c.split("probes", 1)
        c.split("would_probe", 1)
        c.split("gain", 3)
        c.split("gain", 9)
        c.split("slow_switches", 1)
        c.split("bad_body", 1)
        c.wastedBytes = 1_234_567
        c.armActed[0] += 1
        c.armCount[1] += 2
        let e = c.entry(host: "cdn2.quranlab.ai")
        XCTAssertEqual(e["probes"] as? Int, 1)
        XCTAssertEqual(e["would_probe"] as? Int, 1)
        XCTAssertEqual(e["gain"] as? [Int], [0, 0, 0, 1, 0, 0], "a bucket out of range is not counted")
        XCTAssertEqual(e["wasted"] as? Int, 1234, "kB of 1000 bytes")
        XCTAssertEqual((e["arms"] as? [String: [Int]])?["count"], [0, 2])
        XCTAssertEqual((e["arms"] as? [String: [Int]])?["acted"], [1, 0])
        XCTAssertEqual(e["slow_switches"] as? Int, 1)
        XCTAssertEqual(e["fail"] as? [String: Int], ["bad_body": 1], "35.7's bad_body is a class of 34.9.1's fail")
        XCTAssertNil(HostCountsTests.refusal([e]), "the server takes it")
        let empty = HostCount().entry(host: "cdn2.quranlab.ai")
        XCTAssertEqual(empty["gain"] as? [Int], [0, 0, 0, 0, 0, 0])
        XCTAssertEqual((empty["arms"] as? [String: [Int]])?["count"], [0, 0])
    }

    func testADayStoredBeforeTheFieldsReadsThemAsZero() throws {
        let old = #"{"files":1,"bytes":5,"requests":2,"unreachable":0,"hedged":0,"slowSwitches":0,"ttfb":[1,0,0,0,0,0,0,0,0],"kbps":[0,0,0,0,0,0,0,0,0,1]}"#
        let c = try JSONDecoder().decode(HostCount.self, from: Data(old.utf8))
        XCTAssertEqual(c.files, 1)
        XCTAssertEqual(c.requests, 2)
        XCTAssertEqual(c.probes, 0)
        XCTAssertEqual(c.gain, [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(c.armActed, [0, 0])
        let again = try JSONDecoder().decode(HostCount.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(again, c)
    }

    func testTheCountsGoToTheirHostsAndAreSent() throws {
        let storage = CloudFixtures.storage()
        let store = AnalyticsStore(storage: storage, enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "4.0.5", appVersion: "2.1", deviceClass: "A17", soc: "a17",
                                                  osMajor: 18, ramTier: "8_16"))
        store.record(.modelHost(ModelHostSample(host: "cdn4.quranlab.ai", ttfbMs: 100, bytes: 300_000, bodySeconds: 1, unreachable: false, lastByte: false)))
        store.record(.modelSplit(host: "cdn4.quranlab.ai", field: "would_probe", n: 1))
        store.record(.modelSplit(host: "cdn4.quranlab.ai", field: "gain", n: 5))
        store.record(.modelSplit(host: "cdn2.quranlab.ai", field: "probes", n: 1))
        store.record(.modelWasted(host: "cdn4.quranlab.ai", bytes: 300_000))
        store.record(.modelArm(host: "cdn2.quranlab.ai", acted: true, failed: false))
        store.record(.modelSplit(host: "127.0.0.1", field: "probes", n: 1))
        let hosts = try XCTUnwrap(store.pending.compactMap { $0.hosts }.first)
        let body = HostCount.body(hosts)
        XCTAssertNil(HostCountsTests.refusal(body))
        let a = try XCTUnwrap(body.first { $0["host"] as? String == "cdn4.quranlab.ai" })
        let b = try XCTUnwrap(body.first { $0["host"] as? String == "cdn2.quranlab.ai" })
        XCTAssertEqual(a["would_probe"] as? Int, 1)
        XCTAssertEqual(a["gain"] as? [Int], [0, 0, 0, 0, 0, 1])
        XCTAssertEqual(a["wasted"] as? Int, 300)
        XCTAssertEqual(b["probes"] as? Int, 1)
        XCTAssertEqual((b["arms"] as? [String: [Int]])?["acted"], [1, 0])
        XCTAssertEqual(body.count, 2, "a host off the allow-list is not counted")
    }
}

/// SDK 4.0.5 (SPLIT_40 35.8): the models P per connection type, stored with the config in force, read back for 24 hours
/// and only with that config; the probe back at 30 minutes unchanged.
final class TypedPreferredTests: XCTestCase {
    static let models = ["https://cdn.quranlab.ai", "https://cdn2.quranlab.ai", "https://cdn4.quranlab.ai"].map { URL(string: $0)! }

    func testPIsKeptPerConnectionTypeAndStoredWithTheConfig() throws {
        let type = Locked("wifi")
        let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let file = CloudFixtures.storage().appendingPathComponent("cloud/models-p.json")
        let identity = Locked<String?>("\"etag-1\"")
        func make() -> EndpointSet {
            EndpointSet(api: [URL(string: "https://api.quranlab.ai")!], models: Self.models, clock: { now.withLock { $0 } },
                        connection: { type.withLock { $0 } }, pFile: file, configIdentity: { identity.withLock { $0 } })
        }
        let e = make()
        e.settle(.models, Self.models[2], at: now.withLock { $0 }, probe: false)
        XCTAssertEqual(e.preferred(.models), "cdn4.quranlab.ai", "wifi's P")
        type.withLock { $0 = "cellular" }
        XCTAssertEqual(e.preferred(.models), "cdn.quranlab.ai", "cellular has its own P, the first host")
        e.settle(.models, Self.models[1], at: now.withLock { $0 }, probe: false)
        type.withLock { $0 = "wifi" }
        XCTAssertEqual(e.preferred(.models), "cdn4.quranlab.ai")
        let stored = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(stored.contains("ssid") || stored.contains("carrier"), "no network's name: \(stored)")

        // a new start with the same config reads it back
        now.withLock { $0 = $0.addingTimeInterval(600) }
        XCTAssertEqual(make().preferred(.models), "cdn4.quranlab.ai")
        type.withLock { $0 = "cellular" }
        XCTAssertEqual(make().preferred(.models), "cdn2.quranlab.ai")
        // another config in force: nothing is read back
        identity.withLock { $0 = "\"etag-2\"" }
        XCTAssertEqual(make().preferred(.models), "cdn.quranlab.ai")
        identity.withLock { $0 = "\"etag-1\"" }
        // the probe back at 30 minutes is unchanged: a P read back is asked after the first host once its 30 minutes are
        // over (the order is the list's, as the probe)
        now.withLock { $0 = $0.addingTimeInterval(1500) }
        let back = make().order(.models, at: now.withLock { $0 })
        XCTAssertTrue(back.probe, "cellular's P was read back, and its 30 minutes are over")
        XCTAssertEqual(back.hosts.first, Self.models[0])
        // after 24 hours: nothing is read back (no P, so no probe either)
        now.withLock { $0 = $0.addingTimeInterval(24 * 3600) }
        let late = make().order(.models, at: now.withLock { $0 })
        XCTAssertFalse(late.probe)
        XCTAssertEqual(late.hosts, Self.models)
    }
}
