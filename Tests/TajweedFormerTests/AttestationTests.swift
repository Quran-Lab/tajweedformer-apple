import CryptoKit
import DeviceCheck
import Foundation
import XCTest
@testable import TajweedFormer

/// One attestation per install; tokens renew with assertions.
final class AttestationTests: XCTestCase {
    private func options() -> QuranLab.Options {
        var o = CloudFixtures.options()
        o.cloud?.appleTeamID = "ABCDE12345"
        return o
    }

    private func attestedServer(extra: (@Sendable (StubProtocol.Seen) -> StubProtocol.Reply?)? = nil) -> @Sendable (StubProtocol.Seen) -> StubProtocol.Reply {
        CloudFixtures.server(token: CloudFixtures.attestedToken, extra: extra)
    }

    private func attestations() -> [StubProtocol.Seen] { StubProtocol.seen("/v1/attest").filter { $0.json?["attestation"] != nil } }

    func testFirstTokenAttestsThenRenewalsUseAssertions() async throws {
        StubProtocol.reset(attestedServer())
        let storage = CloudFixtures.storage()
        let keys = MemoryAttestKeyStore()
        let attester = FakeAttester(isSupported: true)
        let cloud = CloudFixtures.cloud(storage: storage, options: options(), attester: attester, attestKeys: keys)
        let first = try await cloud.tokens!.token()
        XCTAssertTrue(first.attested)
        XCTAssertEqual(attestations().count, 1)
        XCTAssertEqual(keys.load(), "fake-key-1", "the attested key id is kept in the Keychain")

        // the token expires (or a 401 drops it): the next one is an assertion by the same key
        await cloud.tokens!.invalidate()
        let second = try await cloud.tokens!.token()
        XCTAssertTrue(second.attested)
        XCTAssertEqual(attestations().count, 1, "no second attestation")
        XCTAssertEqual(attester.state.with { $0.attestations }, 1)
        let assert = try XCTUnwrap(StubProtocol.seen("/v1/attest/assert").first)
        let body = try XCTUnwrap(assert.json)
        XCTAssertEqual(Set(body.keys), ["platform", "bundle_id", "key_id", "challenge", "assertion"])
        XCTAssertEqual(body["key_id"] as? String, "fake-key-1")
        XCTAssertEqual(assert.headers["x-qlab-key"], CloudFixtures.key)
        // the assertion is over SHA-256 of the fresh challenge, as qlab-api checks it
        let challenge = try XCTUnwrap(body["challenge"] as? String)
        let assertion = try XCTUnwrap(Data(base64Encoded: body["assertion"] as! String))
        XCTAssertEqual(assertion, Data("assertion:fake-key-1:1:".utf8) + Data(SHA256.hash(data: Data(challenge.utf8))))
        XCTAssertEqual(StubProtocol.seen("/v1/attest/challenge").count, 2)

        // the next launch (a new provider, same Keychain, same files) asserts too, counting on
        let later = CloudFixtures.cloud(storage: storage, options: options(), attester: attester, attestKeys: keys)
        await later.tokens!.invalidate()
        _ = try await later.tokens!.token()
        XCTAssertEqual(StubProtocol.seen("/v1/attest/assert").count, 2)
        XCTAssertEqual(attestations().count, 1)
        XCTAssertEqual(attester.state.with { $0.counters["fake-key-1"] }, 2)
    }

    func testInvalidKeyAttestsANewKey() async throws {
        StubProtocol.reset(attestedServer())
        let keys = MemoryAttestKeyStore()
        let attester = FakeAttester(isSupported: true)
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(), attester: attester, attestKeys: keys)
        _ = try await cloud.tokens!.token()
        attester.state.with { _ = $0.lost.insert("fake-key-1") }
        await cloud.tokens!.invalidate()
        let t = try await cloud.tokens!.token()
        XCTAssertTrue(t.attested)
        XCTAssertTrue(StubProtocol.seen("/v1/attest/assert").isEmpty, "DCError.invalidKey: nothing to send")
        XCTAssertEqual(attestations().count, 2)
        XCTAssertEqual(attestations().last?.json?["key_id"] as? String, "fake-key-2")
        XCTAssertEqual(keys.load(), "fake-key-2")
    }

    func testAKeyTheServerDoesNotKnowOrRevokedIsReplaced() async throws {
        for code in ["attest_key_unknown", "attest_key_revoked"] {
            StubProtocol.reset(attestedServer(extra: { s in
                s.path == "/v1/attest/assert" ? .json(["error": code, "message": "x"], status: 401) : nil
            }))
            let keys = MemoryAttestKeyStore()
            let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(),
                                            attester: FakeAttester(isSupported: true), attestKeys: keys)
            _ = try await cloud.tokens!.token()
            await cloud.tokens!.invalidate()
            let t = try await cloud.tokens!.token()
            XCTAssertTrue(t.attested, code)
            XCTAssertEqual(StubProtocol.seen("/v1/attest/assert").count, 1, code)
            XCTAssertEqual(attestations().count, 2, code)
            XCTAssertEqual(keys.load(), "fake-key-2", code)
        }
    }

    func testAReinstallAttestsANewKey() async throws {
        // the Keychain still holds a key id from before the reinstall; the app's files are new
        StubProtocol.reset(attestedServer())
        let keys = MemoryAttestKeyStore("fake-key-old")
        let attester = FakeAttester(isSupported: true)
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(), attester: attester, attestKeys: keys)
        let t = try await cloud.tokens!.token()
        XCTAssertTrue(t.attested)
        XCTAssertEqual(attester.state.with { $0.assertions }, 0)
        XCTAssertTrue(StubProtocol.seen("/v1/attest/assert").isEmpty)
        XCTAssertEqual(attestations().count, 1)
        XCTAssertEqual(keys.load(), "fake-key-1")
    }

    func testOneRefreshInFlightAtATime() async throws {
        StubProtocol.reset(attestedServer())
        let storage = CloudFixtures.storage()
        let keys = MemoryAttestKeyStore()
        let attester = FakeAttester(isSupported: true, assertionDelay: 50_000_000)
        let cloud = CloudFixtures.cloud(storage: storage, options: options(), attester: attester, attestKeys: keys)
        let tokens = cloud.tokens!
        _ = try await tokens.token()
        await tokens.invalidate()
        let all = try await withThrowingTaskGroup(of: APIToken.self) { g in
            for _ in 0..<12 { g.addTask { try await tokens.token() } }
            var out: [APIToken] = []
            for try await t in g { out.append(t) }
            return out
        }
        XCTAssertEqual(Set(all.map(\.token)).count, 1)
        XCTAssertEqual(attester.state.with { $0.assertions }, 1, "one assertion for twelve callers")
        XCTAssertEqual(attester.state.with { $0.maxConcurrent }, 1)
        XCTAssertEqual(StubProtocol.seen("/v1/attest/assert").count, 1)
        XCTAssertEqual(attestations().count, 1)
        // and after it settled, the next refresh is a new one (not a stale task)
        await tokens.invalidate()
        _ = try await tokens.token()
        XCTAssertEqual(attester.state.with { $0.assertions }, 2)
    }

    func testALostCounterRaceIsRetriedOnceWithANewAssertion() async throws {
        let calls = Locked(0)
        StubProtocol.reset(attestedServer(extra: { s in
            guard s.path == "/v1/attest/assert" else { return nil }
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1 ? .json(["error": "assertion_failed", "message": "counter_not_increasing"], status: 401) : nil
        }))
        let keys = MemoryAttestKeyStore()
        let attester = FakeAttester(isSupported: true)
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(), attester: attester, attestKeys: keys)
        _ = try await cloud.tokens!.token()
        await cloud.tokens!.invalidate()
        let t = try await cloud.tokens!.token()
        XCTAssertTrue(t.attested)
        let sent = StubProtocol.seen("/v1/attest/assert")
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotEqual(sent[0].json?["assertion"] as? String, sent[1].json?["assertion"] as? String)
        XCTAssertEqual(attestations().count, 1, "a lost race is not a reason to attest")
        XCTAssertEqual(keys.load(), "fake-key-1")
    }

    func testAssertionTroubleThatIsNotTheKeyKeepsItAndRunsUnattested() async throws {
        StubProtocol.reset(attestedServer(extra: { s in
            if s.path == "/v1/attest/assert" { return .json(["error": "challenge_invalid", "message": "x"], status: 401) }
            if s.path == "/v1/attest", s.json?["attestation"] == nil { return CloudFixtures.token }
            return nil
        }))
        let keys = MemoryAttestKeyStore()
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(),
                                        attester: FakeAttester(isSupported: true), attestKeys: keys)
        _ = try await cloud.tokens!.token()
        await cloud.tokens!.invalidate()
        let t = try await cloud.tokens!.token()
        XCTAssertFalse(t.attested)
        XCTAssertEqual(attestations().count, 1)
        XCTAssertEqual(keys.load(), "fake-key-1")

        // offline during a renewal: the error surfaces, the key stays
        StubProtocol.reset { _ in .down }
        await cloud.tokens!.invalidate()
        do {
            _ = try await cloud.tokens!.token()
            XCTFail("offline")
        } catch {
            XCTAssertTrue(error.retryable)
        }
        XCTAssertEqual(keys.load(), "fake-key-1")
    }

    func testARejectedAttestationKeepsNoKey() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path == "/v1/attest" && s.json?["attestation"] != nil ? .json(["error": "attestation_failed", "message": "bad"], status: 401) : nil
        }))
        let keys = MemoryAttestKeyStore()
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(),
                                        attester: FakeAttester(isSupported: true), attestKeys: keys)
        let t = try await cloud.tokens!.token()
        XCTAssertFalse(t.attested)
        XCTAssertNil(keys.load())
    }

    func testUnsupportedDevicesAreUnchanged() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let keys = MemoryAttestKeyStore("fake-key-1")
        let attester = FakeAttester(isSupported: false)
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options(), attester: attester, attestKeys: keys)
        let t = try await cloud.tokens!.token()
        XCTAssertFalse(t.attested)
        XCTAssertEqual(StubProtocol.seen.map(\.path), ["/v1/attest"])
        XCTAssertEqual(Set(try XCTUnwrap(StubProtocol.seen("/v1/attest").first?.json).keys), ["platform", "bundle_id"])
        XCTAssertEqual(attester.state.with { $0.assertions + $0.attestations }, 0)
        XCTAssertEqual(keys.load(), "fake-key-1", "an unsupported device touches no key")
    }

    func testDeviceCheckInvalidKeyIsRecognised() {
        XCTAssertTrue(DeviceCheckAttester.isInvalidKey(DCError(.invalidKey)))
        XCTAssertTrue(DeviceCheckAttester.isInvalidKey(DCError(.invalidInput)))
        XCTAssertFalse(DeviceCheckAttester.isInvalidKey(DCError(.serverUnavailable)))
        XCTAssertFalse(DeviceCheckAttester.isInvalidKey(URLError(.notConnectedToInternet)))
    }
}
