import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2: one Core per storage folder and install key in the process (`LiveCores`), and the lease files stored
/// monotonically (`ProtectedRuntime.storeLease`). A Client that is closed may still have a lease attempt on its way;
/// a new Client on the same folder takes the same Core, so the late answer lands in the state the new one keeps, and
/// an older lease never replaces a newer one. Leases of grace_seq.json (the test release's, for lease.json's install
/// and build), told apart by their issue times; the restart is a runtime made after every holder of the Core let go.
extension ProtectedCoreTests {
    /// A lease of grace_seq.json and its answer.
    static func graceLease(iat: Int64, exp: Int64) throws -> HTTPClient.Response {
        let v = try V40.json("grace_seq.json")
        for s in try XCTUnwrap(v["sequences"] as? [[String: Any]]) {
            for st in (s["steps"] as? [[String: Any]]) ?? [] {
                guard let l = st["lease"] as? [String: Any], (l["iat"] as? NSNumber)?.int64Value == iat,
                      (l["exp"] as? NSNumber)?.int64Value == exp, let hex = st["lease_hex"] as? String else { continue }
                return response(200, ["v": 1, "lease": V40.hex(hex).base64URL, "iat": iat, "exp": exp, "refresh_after": iat + 3600,
                                      "base": "https://cdn.quranlab.ai/models/Quran-Lab/m/b/sdk/v4.0/"], headers: [:])
            }
        }
        throw XCTSkip("grace_seq.json has no lease \(iat) \(exp)")
    }

    static let l1 = (iat: Int64(1_790_000_000), exp: Int64(1_790_604_800))
    static let l4 = (iat: Int64(1_790_604_820), exp: Int64(1_791_209_620))
    static let l3 = (iat: Int64(1_790_608_400), exp: Int64(1_791_213_200))

    /// A runtime on the setup's folder, install key and state store: a Client's.
    func client(_ s: Setup, _ clocks: any CoreClocks, server: Bool = true) -> ProtectedRuntime {
        ProtectedRuntime(storage: s.storage, server: server ? s.runtime.server : nil, keys: FixedKeys(s.key), state: s.state, clocks: clocks)
    }

    /// A stop for lease.json's install and the test challenge, signed by the contract's test signer (refusal_signed.json's
    /// form) at `t`, the Core's own clock: after lease.json's lease that is the lease's iat, since the Core does not take
    /// a wall clock ahead of it, and a stop signed outside the Core's time window is not verified.
    static func signedStop(at t: Int64) throws -> HTTPClient.Response {
        let lv = try V40.json("lease.json")
        let signer = try V40.signer(lv)
        let installHash = try XCTUnwrap((lv["install_ecdh"] as? [String: Any])?["install_hash_hex"] as? String)
        let text = "quranlab-refusal 1\napps-one\nkey_revoked\n\(installHash)\n\(challenge)\n\(t)\n"
        let signed = Data(text.utf8).base64URL + "." + (try signer.private.signature(for: Data(text.utf8))).base64URL
        return response(401, ["error": "invalid_key", "message": "stand-in", "reason": "key_revoked", "signed": signed], headers: [:])
    }

    func waitFor(_ what: String, _ done: @escaping @Sendable () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !done() {
            guard Date() < end else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Two runtimes made back to back on one folder and install key take the same Core; once the last holder lets go
    /// it is freed, and a fresh runtime makes a new one.
    func testRuntimesOfOneFolderShareOneCoreUntilTheLastLetsGo() async throws {
        let s = try prepare(certValidity: 30 * 86_400)
        let clocks = MovingClocks(wallS: Self.l1.iat)
        weak var first: CoreHost?
        do {
            let a = client(s, clocks), b = client(s, clocks)
            let ha = try XCTUnwrap(try a.host()), hb = try XCTUnwrap(try b.host())
            XCTAssertTrue(ha === hb, "the same Core")
            first = ha
        }
        XCTAssertNil(first, "the last holder let go: the Core was freed")
        let c = client(s, clocks)
        XCTAssertNotNil(try c.host())
    }

    /// The grace case: client A's renewal (past its lease's exp, in its grace) is held at the server; A is closed and
    /// client B opens the folder and ticks. A's answer then comes: B's ticks keep the refreshed lease, and a restart with
    /// no network opens it. (To 4.0.1 B had a Core of its own, whose next save rolled the lease back to the one in grace.)
    func testARenewalAnsweredAfterANewClientKeepsItsLease() async throws {
        let first = try Self.graceLease(iat: Self.l1.iat, exp: Self.l1.exp), refreshed = try Self.graceLease(iat: Self.l4.iat, exp: Self.l4.exp)
        let gate = StubProtocol.Gate()
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            if n == 1 { return first }
            gate.wait()
            return refreshed
        }, certValidity: 30 * 86_400)
        let clocks = MovingClocks(wallS: Self.l1.iat)
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            core = try a.host()
            clocks.advance(seconds: 1_790_604_900 - Self.l1.iat)
            XCTAssertFalse(a.hasValidLease(build: s.manifest.build), "past exp: in the grace")
            let m = s.manifest
            let renewal = Task { [a, m] () -> Bool in (try? await a.renew(m)) != nil }
            try await waitFor("the renewal at the server") { asked.withLock { $0 } == 2 }
            // A is closed (the app drops it; its attempt goes on); B opens the folder and ticks
            let b = client(s, clocks)
            _ = b.status()
            gate.open()
            let renewed = await renewal.value
            XCTAssertTrue(renewed)
            _ = b.status()
            XCTAssertTrue(b.hasValidLease(build: s.manifest.build), "B holds the refreshed lease")
        }
        XCTAssertNil(core, "every holder let go")
        let restart = client(s, clocks, server: false)
        XCTAssertTrue(restart.hasValidLease(build: s.manifest.build), "a restart with no network opens the refreshed lease")
        XCTAssertEqual(restart.leaseRecord?.expiresAt, Self.l4.exp)
    }

    /// A late, older lease: A's renewal (answered with a lease issued at l4) is held; B renews meanwhile and gets a newer
    /// one (l3). A's answer then comes: it is never put in the newer one's place, in lease.json or the Core, and a restart
    /// opens B's lease.
    func testALateOlderLeaseNeverReplacesANewerOne() async throws {
        let first = try Self.graceLease(iat: Self.l1.iat, exp: Self.l1.exp)
        let older = try Self.graceLease(iat: Self.l4.iat, exp: Self.l4.exp), newer = try Self.graceLease(iat: Self.l3.iat, exp: Self.l3.exp)
        let gate = StubProtocol.Gate()
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            if n == 1 { return first }
            if n == 2 {
                gate.wait()
                return older
            }
            return newer
        }, certValidity: 30 * 86_400)
        let clocks = MovingClocks(wallS: Self.l1.iat)
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            core = try a.host()
            clocks.advance(seconds: 1_790_608_500 - Self.l1.iat)
            let m = s.manifest
            let renewal = Task { [a, m] () -> Bool in (try? await a.renew(m)) != nil }
            try await waitFor("A's renewal at the server") { asked.withLock { $0 } == 2 }
            let b = client(s, clocks)
            _ = try await b.renew(s.manifest)
            XCTAssertEqual(b.leaseRecord?.expiresAt, Self.l3.exp, "B's newer lease")
            gate.open()
            _ = await renewal.value
            XCTAssertEqual(b.leaseRecord?.expiresAt, Self.l3.exp, "A's older lease did not replace it")
            _ = b.status()
        }
        XCTAssertNil(core)
        let restart = client(s, clocks, server: false)
        XCTAssertTrue(restart.hasValidLease(build: s.manifest.build))
        XCTAssertEqual(restart.leaseRecord?.expiresAt, Self.l3.exp, "a restart opens B's lease")
    }

    /// The control: with no second client, the late answer of a closed client's renewal is kept, and a restart opens it.
    func testWithNoSecondClientALateAnswerIsKept() async throws {
        let first = try Self.graceLease(iat: Self.l1.iat, exp: Self.l1.exp), refreshed = try Self.graceLease(iat: Self.l4.iat, exp: Self.l4.exp)
        let gate = StubProtocol.Gate()
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            if n == 1 { return first }
            gate.wait()
            return refreshed
        }, certValidity: 30 * 86_400)
        let clocks = MovingClocks(wallS: Self.l1.iat)
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            core = try a.host()
            clocks.advance(seconds: 1_790_604_900 - Self.l1.iat)
            let m = s.manifest
            let renewal = Task { [a, m] () -> Bool in (try? await a.renew(m)) != nil }
            try await waitFor("the renewal at the server") { asked.withLock { $0 } == 2 }
            gate.open()
            let renewed = await renewal.value
            XCTAssertTrue(renewed)
        }
        XCTAssertNil(core)
        let restart = client(s, clocks, server: false)
        XCTAssertTrue(restart.hasValidLease(build: s.manifest.build))
        XCTAssertEqual(restart.leaseRecord?.expiresAt, Self.l4.exp)
    }

    /// The clear paths do not go through the monotonic store: a signed stop for this install (401 invalid_key,
    /// key_revoked, refusal_signed.json's form) after a stored lease with its issue time. The Core clears its lease and
    /// says stopped, lease.json goes, and a restart with no network opens no model.
    func testASignedStopClearsTheLeaseForAnOfflineRestart() async throws {
        let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
        let stop = Locked<HTTPClient.Response?>(nil)
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            return n == 1 ? nil : stop.withLock { $0 }
        }, certValidity: 30 * 86_400)
        let clocks = FixedClocks(wall: now * 1000, bootMs: 5_000_000, id: Array(SHA256.hash(data: Data("boot-1".utf8))))
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            let signed = try Self.signedStop(at: try XCTUnwrap(try a.host()).tick().now)
            stop.withLock { $0 = signed }
            XCTAssertNotNil(a.leaseRecord?.issuedAt, "the stored lease has its issue time")
            do {
                _ = try await a.renew(s.manifest)
                XCTFail("a signed stop")
            } catch {}
            XCTAssertNil(a.leaseRecord, "lease.json went with the stop")
            XCTAssertTrue(a.status().stopped)
            core = try a.host()
        }
        XCTAssertNil(core)
        let restart = client(s, clocks, server: false)
        XCTAssertTrue(restart.status().stopped, "the stop is in the Core's saved state")
        XCTAssertFalse(restart.hasValidLease(build: s.manifest.build))
        do {
            _ = try await restart.ensureLease(s.manifest)
            XCTFail("no model opens offline after a stop")
        } catch {}
    }

    // debug builds only: the store is held at StagingHooks.beforeLeaseStore, which a release build does not have
    #if DEBUG
    /// A save started before a stop never lands after it: client A's renewed lease, accepted by the Core, waits to be
    /// stored (held at `StagingHooks.beforeLeaseStore`) while client B meets a verified stop; then A's store goes on.
    /// lease.json stays gone, the Core stays stopped, and a restart with no network opens no model. (Without the stop's
    /// clear under the folder's lock and the stopped Core's refusal in `storeLease`, A's store put lease.json back.)
    func testALeaseStoreHeldAcrossAStopNeverPutsTheLeaseBack() async throws {
        let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
        let stop = Locked<HTTPClient.Response?>(nil)
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            return n <= 2 ? nil : stop.withLock { $0 }
        }, certValidity: 30 * 86_400)
        let clocks = FixedClocks(wall: now * 1000, bootMs: 5_000_000, id: Array(SHA256.hash(data: Data("boot-1".utf8))))
        let armed = Locked(false), reached = Locked(false)
        let gate = StubProtocol.Gate()
        StagingHooks.beforeLeaseStore.withLock {
            $0 = {
                guard armed.withLock({ $0 }) else { return }
                reached.withLock { $0 = true }
                gate.wait()
            }
        }
        defer { StagingHooks.beforeLeaseStore.withLock { $0 = nil } }
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            let signed = try Self.signedStop(at: try XCTUnwrap(try a.host()).tick().now)
            stop.withLock { $0 = signed }
            core = try a.host()
            armed.withLock { $0 = true }
            let m = s.manifest
            let renewal = Task { [a, m] () -> Bool in (try? await a.renew(m)) != nil }
            try await waitFor("A's lease accepted and its store held") { reached.withLock { $0 } }
            armed.withLock { $0 = false }
            let b = client(s, clocks)
            do {
                _ = try await b.renew(s.manifest)
                XCTFail("a signed stop")
            } catch {}
            XCTAssertNil(b.leaseRecord, "the stop cleared lease.json")
            gate.open()
            _ = await renewal.value
            XCTAssertNil(b.leaseRecord, "A's store did not put it back")
            XCTAssertTrue(b.status().stopped)
        }
        XCTAssertNil(core)
        let restart = client(s, clocks, server: false)
        XCTAssertTrue(restart.status().stopped)
        XCTAssertNil(restart.leaseRecord)
        do {
            _ = try await restart.ensureLease(s.manifest)
            XCTFail("no model opens offline after the stop")
        } catch {}
    }
    #endif

    /// A lease request on its way when a stop arrives on another request: the Core takes a verified lease even after a
    /// stop (quranlab-core core.c:357), so the answer to a request sent before the stop is never handed to it. The model
    /// stays stopped, no lease is stored, and a restart with no network opens no model. (Android: Lease.kt:832.)
    func testALeaseAnsweredAfterAStopIsNeverTaken() async throws {
        let now = Int64(try XCTUnwrap(try V40.json("lease.json")["now"] as? Int))
        let stop = Locked<HTTPClient.Response?>(nil)
        let gate = StubProtocol.Gate()
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            if n == 2 { gate.wait() }
            return n <= 2 ? nil : stop.withLock { $0 }
        }, certValidity: 30 * 86_400)
        let clocks = FixedClocks(wall: now * 1000, bootMs: 5_000_000, id: Array(SHA256.hash(data: Data("boot-1".utf8))))
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            let signed = try Self.signedStop(at: try XCTUnwrap(try a.host()).tick().now)
            stop.withLock { $0 = signed }
            core = try a.host()
            let m = s.manifest
            let renewal = Task { [a, m] () -> Bool in (try? await a.renew(m)) != nil }
            try await waitFor("A's lease request on its way") { asked.withLock { $0 } == 2 }
            let b = client(s, clocks)
            do {
                _ = try await b.renew(s.manifest)
                XCTFail("a signed stop")
            } catch {}
            XCTAssertTrue(b.status().stopped)
            gate.open()
            let renewed = await renewal.value
            XCTAssertFalse(renewed, "the answer to a request sent before the stop is not taken")
            XCTAssertTrue(b.status().stopped, "the model stays stopped")
            XCTAssertNil(b.leaseRecord, "no lease is stored")
        }
        XCTAssertNil(core)
        let restart = client(s, clocks, server: false)
        XCTAssertTrue(restart.status().stopped)
        XCTAssertFalse(restart.hasValidLease(build: s.manifest.build))
        do {
            _ = try await restart.ensureLease(s.manifest)
            XCTFail("no model opens offline after the stop")
        } catch {}
    }

    /// The same with the stop on another route: a renewal on its way when the API refuses the key on a model request
    /// (`ModelGate.note`: the gate keeps the stop and removes the models). The answer that comes after is not taken:
    /// lease.json and the Core keep the lease from before, and at a restart the gate still holds the stop and there is no
    /// newer lease. (To 4.0.1 the late answer's lease was accepted and stored.)
    func testALeaseAnsweredAfterAStopOnTheModelRouteIsNeverTaken() async throws {
        let first = try Self.graceLease(iat: Self.l1.iat, exp: Self.l1.exp), later = try Self.graceLease(iat: Self.l4.iat, exp: Self.l4.exp)
        let gate = StubProtocol.Gate()
        let asked = Locked(0)
        let s = try prepare(answer: { (r: URLRequest, _: Int) -> HTTPClient.Response? in
            guard r.url?.path.hasSuffix("v1/model-key") == true else { return nil }
            let n = asked.withLock { (k: inout Int) -> Int in k += 1; return k }
            if n == 1 { return first }
            gate.wait()
            return later
        }, certValidity: 30 * 86_400)
        let clocks = MovingClocks(wallS: Self.l1.iat)
        weak var core: CoreHost?
        do {
            let a = client(s, clocks)
            _ = try await a.ensureLease(s.manifest)
            core = try a.host()
            clocks.advance(seconds: 1_790_604_900 - Self.l1.iat)
            let m = s.manifest
            let renewal = Task { [a, m] () -> Bool in (try? await a.renew(m)) != nil }
            try await waitFor("A's lease request on its way") { asked.withLock { $0 } == 2 }
            ModelGate(storage: s.storage).note(.rejected(status: 401, code: "invalid_key", message: "", reason: "key_revoked"), from: .model)
            gate.open()
            let renewed = await renewal.value
            XCTAssertFalse(renewed, "the answer to a request sent before the stop is not taken")
            XCTAssertEqual(a.leaseRecord?.issuedAt, Self.l1.iat, "no lease is stored from it")
        }
        XCTAssertNil(core)
        XCTAssertEqual(ModelGate(storage: s.storage).stop?.reason, "key_revoked", "the stop is kept")
        let restart = client(s, clocks, server: false)
        XCTAssertEqual(restart.leaseRecord?.issuedAt, Self.l1.iat)
        XCTAssertEqual(restart.status().expiresAt, Self.l1.exp, "the Core's saved lease is the one from before")
        XCTAssertFalse(restart.hasValidLease(build: s.manifest.build), "no newer lease at the restart")
    }

    /// The lease file on its own: a record whose server issue time is older than the saved one of its build is refused,
    /// and the row of failures stays; a newer one is stored.
    func testAnOlderLeaseFileWriteIsRefused() throws {
        let storage = Fixtures.storage()
        let r = ProtectedRuntime(storage: storage, server: nil, keys: InstallKeyring(storage: storage))
        XCTAssertTrue(r.storeLease(LeaseRecord(build: "b", base: nil, expiresAt: 3000, refreshAfter: 2000, issuedAt: 1000)))
        XCTAssertFalse(r.storeLease(LeaseRecord(build: "b", base: nil, expiresAt: 2500, refreshAfter: 1500, issuedAt: 900)), "older: refused")
        XCTAssertEqual(r.leaseRecord?.issuedAt, 1000)
        XCTAssertTrue(r.storeLease(LeaseRecord(build: "b", base: nil, expiresAt: 4000, refreshAfter: 3000, issuedAt: 1100)))
        XCTAssertEqual(r.leaseRecord?.issuedAt, 1100)
        XCTAssertTrue(r.storeLease(LeaseRecord(build: "c", base: nil, expiresAt: 10, refreshAfter: 5, issuedAt: 1)), "another build")
    }
}
