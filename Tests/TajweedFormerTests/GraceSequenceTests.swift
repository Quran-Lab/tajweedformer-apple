import CryptoKit
import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// Contract 18.4.7.1 and 18.4.7.2 (1c971ab): `vectors/grace.json`'s 3 `override_leases` and 15 `sequences` through this
/// SDK's Core host, platform table (storage, clocks), key and saved state and the real Core, as the C SDK's
/// tf40_grace_vectors does. The sequences name each lease by its iat and exp only; `grace_seq.json` holds their bytes,
/// made by tajweedformer-native's test/make_grace40.py from the contract's test keys (lease.json's install, the test
/// release 4.0.0-c1's K_core, the test signer). Each check is a model open at that clock: the state (valid, grace,
/// needs_connection, stopped), the Core's now and `qlc_lease_grace`'s until. Needs the test release.
final class GraceSequenceTests: XCTestCase {
    final class SetClocks: CoreClocks, @unchecked Sendable {
        private let t = Locked<(wall: Int64, boot: Int64, id: [UInt8])>((0, 0, []))
        func set(wall: Int64, bootMs: Int64, id: String) {
            t.withLock { $0 = (wall * 1000, bootMs, Array(SHA256.hash(data: Data(id.utf8)))) }
        }
        func wallMs() -> Int64 { t.withLock { $0.wall } }
        func boot() -> (ms: Int64, id: [UInt8]) { t.withLock { ($0.boot, $0.id) } }
    }

    struct Host {
        let clocks = SetClocks()
        let state = ProtectedCoreTests.MemoryState()
        let storage = Fixtures.storage()
        let key: SoftwareInstallKey
        var core: CoreHost

        init(key: SoftwareInstallKey) throws {
            self.key = key
            core = try CoreHost(platform: CorePlatform(storage: CoreStorage(root: storage), key: key, state: state, clocks: clocks))
        }

        /// A new process: the Core made again from the state the last one saved.
        mutating func restart() throws {
            core = try CoreHost(platform: CorePlatform(storage: CoreStorage(root: storage), key: key, state: state, clocks: clocks))
        }
    }

    var manifest = Data()
    var build = ""
    var folder: URL!

    override func setUpWithError() throws {
        guard CoreHost.version.hasPrefix("4.0.0-c1 ") else {
            throw XCTSkip("the linked Core is \(CoreHost.version), not the test release 4.0.0-c1 (build_core_xcframework.py --test-release)")
        }
        var m = try ModelManifest.parse(try V40.manifest().data)
        m.sha256 = try XCTUnwrap(try V40.json("lease.json")["build"] as? String) + String(repeating: "0", count: 24)
        manifest = try XCTUnwrap(m.raw)
        build = m.build
    }

    func key() throws -> SoftwareInstallKey {
        let ecdh = try XCTUnwrap(try V40.json("lease.json")["install_ecdh"] as? [String: Any])
        return try XCTUnwrap(SoftwareInstallKey(der: try XCTUnwrap(Data(base64URL: try XCTUnwrap(ecdh["pkcs8_b64u"] as? String)))))
    }

    /// The state a model open meets now: the Core's tick, its grace, and the open itself (needs_connection exactly when
    /// the state is).
    func state(_ h: Host) -> (state: String, now: Int64, until: Int64, hasLease: Bool, openNeedsConnection: Bool) {
        let s = h.core.tick()
        let g = h.core.leaseGrace()
        let dir = h.storage.appendingPathComponent("models/\(build)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var needs = false
        do {
            let m = try h.core.open(manifest: manifest, in: dir, context: "c16_l64", threads: 1)
            m.close()
        } catch {
            needs = Int(error.status) == Int(QLC_E_NEEDS_CONNECTION)
        }
        let st = s.stopped ? "stopped" : s.valid ? "valid" : g.inGrace ? "grace" : "needs_connection"
        return (st, s.now, g.until, s.hasLease, needs)
    }

    func testOverrideLeases() throws {
        let v = try V40.json("grace.json")
        let cases = try XCTUnwrap(v["override_leases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 3)
        var checks = 0
        for o in cases {
            let name = o["name"] as? String ?? "?"
            let f = try XCTUnwrap(o["fields"] as? [String: Any])
            let iat = Int64(try XCTUnwrap(f["iat"] as? Int)), acceptAt = Int64(try XCTUnwrap(o["accept_at"] as? Int))
            var h = try Host(key: try key())
            h.clocks.set(wall: acceptAt, bootMs: 1000, id: "b1")
            let accepted: (expiresAt: Int64, refreshAfter: Int64)?
            do {
                accepted = try h.core.leaseAccept(V40.hex(try XCTUnwrap(o["lease_hex"] as? String)), manifest: manifest, build: build)
            } catch {
                accepted = nil
            }
            XCTAssertEqual(accepted != nil, o["expect"] as? String == "accept", name)
            if let a = accepted { XCTAssertEqual(a.expiresAt, Int64(try XCTUnwrap(f["exp"] as? Int)), "\(name): held to its own exp") }
            var told = false
            for c in try XCTUnwrap(o["checks"] as? [[String: Any]]) {
                if c["attempt_before"] as? Bool == true, !told {
                    h.core.leaseAttempt(refused: false)
                    told = true
                }
                let at = Int64(try XCTUnwrap(c["at"] as? Int))
                h.clocks.set(wall: acceptAt + (at - iat), bootMs: 1000 + (at - iat) * 1000, id: "b1")
                let s = state(h)
                XCTAssertEqual(s.state, c["state"] as? String, "\(name) at \(at)")
                XCTAssertEqual(s.now, at, "\(name) at \(at): the Core's clock")
                XCTAssertEqual(s.openNeedsConnection, s.state == "needs_connection", "\(name) at \(at): the open")
                checks += 1
            }
            try h.restart() // the saved state loads
        }
        XCTAssertGreaterThan(checks, 0)
    }

    /// The sequences this Core is held to. A Core of spec fix 17 (quranlab-core clock-anchor; it has `qlc_lease_time`)
    /// reads no wall clock: after a reboot the new boot's own time counts, never the time the device was off. Its own
    /// grace.json (docs/spec-fixes/vectors at e9f498a, copied as grace_17.json) changes the two reboot sequences and no
    /// other; those two are replayed from it, each lease's bytes taken from grace_seq.json by its iat and exp.
    static func sequences(_ seq: [String: Any]) throws -> (sequences: [[String: Any]], names: [String?]) {
        var sequences = try XCTUnwrap(seq["sequences"] as? [[String: Any]])
        let contract = try XCTUnwrap(try V40.json("grace.json")["sequences"] as? [[String: Any]])
        guard CoreOptional.leaseTime != nil else { return (sequences, contract.map { $0["name"] as? String }) }
        let fixed = try XCTUnwrap(try V40.json("grace_17.json")["sequences"] as? [[String: Any]])
        XCTAssertEqual(fixed.count, sequences.count)
        var bytes: [String: String] = [:]
        for s in sequences {
            for st in (s["steps"] as? [[String: Any]]) ?? [] {
                if let l = st["lease"] as? [String: Any], let hex = st["lease_hex"] as? String { bytes["\(l["iat"] ?? "") \(l["exp"] ?? "")"] = hex }
            }
        }
        var replaced = 0
        for (i, s) in fixed.enumerated() where (s["name"] as? String) != (sequences[i]["name"] as? String) {
            var steps: [[String: Any]] = []
            for var st in try XCTUnwrap(s["steps"] as? [[String: Any]]) {
                XCTAssertNil(st["stop"], "a stop in a changed sequence has no refusal bytes here")
                if let l = st["lease"] as? [String: Any] { st["lease_hex"] = try XCTUnwrap(bytes["\(l["iat"] ?? "") \(l["exp"] ?? "")"]) }
                steps.append(st)
            }
            sequences[i] = ["name": s["name"] ?? "", "steps": steps]
            replaced += 1
        }
        XCTAssertEqual(replaced, 2, "spec fix 17 changes the two reboot sequences")
        return (sequences, fixed.map { $0["name"] as? String })
    }

    func testSequences() throws {
        let seq = try V40.json("grace_seq.json")
        let challenge = try XCTUnwrap(seq["challenge"] as? String), apiKey = try XCTUnwrap(seq["key"] as? String)
        let (sequences, names) = try Self.sequences(seq)
        XCTAssertEqual(sequences.count, 15)
        // the same sequences as the contract's grace.json (spec fix 17's on a Core of it), by name
        XCTAssertEqual(sequences.map { $0["name"] as? String }, names)
        var steps = 0
        for s in sequences {
            let name = s["name"] as? String ?? "?"
            var h = try Host(key: try key())
            for (k, st) in try XCTUnwrap(s["steps"] as? [[String: Any]]).enumerated() {
                let at = "\(name), step \(k)"
                steps += 1
                if st["lease"] != nil {
                    h.clocks.set(wall: Int64(try XCTUnwrap(st["wall"] as? Int)), bootMs: Int64(try XCTUnwrap(st["boot"] as? Int)) * 1000,
                                 id: try XCTUnwrap(st["boot_id"] as? String))
                    var ok = true
                    do {
                        _ = try h.core.leaseAccept(V40.hex(try XCTUnwrap(st["lease_hex"] as? String)), manifest: manifest, build: build)
                    } catch {
                        ok = false
                    }
                    XCTAssertEqual(ok, st["accepted"] as? Bool, "\(at): the lease")
                    if ok { XCTAssertEqual(h.core.tick().now, Int64(try XCTUnwrap(st["anchor"] as? Int)), "\(at): the anchor") }
                } else if let a = st["attempt"] as? String {
                    let r = h.core.leaseAttempt(refused: a == "refused")
                    let want: Int32 = switch st["result"] as? String {
                    case "ok": Int32(QLC_OK)
                    case "stopped": Int32(QLC_E_STOPPED)
                    default: Int32(QLC_E_NEEDS_CONNECTION)
                    }
                    XCTAssertEqual(r, want, "\(at): attempt \(a)")
                } else if st["stop"] != nil {
                    _ = try? h.core.leaseAsk(challenge: challenge, build: build)
                    let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(st["refusal"] as? [String: Any]))
                    XCTAssertTrue(h.core.refusal(body, apiKeyID: apiKey), "\(at): a verified stop")
                } else if st["restart"] != nil {
                    try h.restart()
                } else if let c = st["check"] as? [String: Any] {
                    h.clocks.set(wall: Int64(try XCTUnwrap(c["wall"] as? Int)), bootMs: Int64(try XCTUnwrap(c["boot"] as? Int)) * 1000,
                                 id: try XCTUnwrap(c["boot_id"] as? String))
                    let got = state(h)
                    // null in the vectors (no lease, or a stop): 0, as the Core gives it
                    let now = Int64(st["now"] as? Int ?? 0)
                    XCTAssertEqual(got.state, st["state"] as? String, "\(at): the state")
                    // now 0 in the vectors: no lease, so no clock anchored yet
                    XCTAssertTrue(got.now == now || (now == 0 && !got.hasLease), "\(at): now \(got.now), want \(now)")
                    XCTAssertEqual(got.until, Int64(st["until"] as? Int ?? 0), "\(at): until")
                    XCTAssertEqual(got.openNeedsConnection, got.state == "needs_connection", "\(at): the open")
                }
            }
        }
        print("grace.json: \(steps) sequence steps of \(sequences.count) sequences replayed")
    }
}
