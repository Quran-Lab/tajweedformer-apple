import CryptoKit
import DeviceCheck
import Foundation
import XCTest
@testable import TajweedFormer

/// App Attest through a flaky network (SDK 4.0.5, contract ATTEST_40.md 40.2; UNTESTED on the Mac when written, 11-25).
/// 4.0.2 held every failure after the attestation for 1 hour doubling to 24 hours (`AttestBackoff`) and made the
/// install's certificate without attestation meanwhile, which a strict app's lease refuses: a -1009 on `/v1/attest`
/// locked a learner out for a day. From 4.0.5 the hold is for judged failures only (the server refused the attestation);
/// a network moment and Apple's `serverUnavailable` keep the same App Attest key and come back by the owed attestation's
/// row (`AttestState`), and the certificate is never made without attestation for them. The fake attester and the stub
/// server; the client's clock moves by hand, and the waits inside a call are scaled down (`AttestPolicy.timeScale`).
final class AttestThrottleTests: XCTestCase {
    static let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() {
        Self.now.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000) }
        AttestPolicy.timeScale.withLock { $0 = 0.001 }
        NetworkWatch.override.withLock { $0 = true }
    }

    override func tearDown() {
        AttestPolicy.timeScale.withLock { $0 = 1 }
        NetworkWatch.override.withLock { $0 = nil }
    }

    private func options() -> QuranLab.Options {
        var o = CloudFixtures.options()
        o.cloud?.appleTeamID = "ABCDE12345"
        return o
    }

    private func cloud(_ attester: FakeAttester, storage: URL = CloudFixtures.storage()) -> QuranLabCloud {
        CloudFixtures.cloud(storage: storage, options: options(), attester: attester, attestKeys: MemoryAttestKeyStore(),
                            clock: { AttestThrottleTests.now.withLock { $0 } })
    }

    private func advance(_ s: TimeInterval) { Self.now.withLock { $0 = $0.addingTimeInterval(s) } }

    /// A storage folder whose config in force says the lease needs attestation (ATTEST_40.md 40.2 item 1: a strict app).
    private static func requiredStorage() -> URL {
        let storage = CloudFixtures.storage()
        let r = CloudFixtures.config(extra: ["attest": "required"])
        let saved = ConfigStore.Saved(body: r.body, signature: r.headers["x-qlab-signature"] ?? "", keyID: r.headers["x-qlab-key-id"], etag: r.headers["etag"])
        JSONFile<ConfigStore.Saved>(url: storage.appendingPathComponent("cloud/config.json")).write(saved)
        return storage
    }

    /// A challenge in the strict form whose life runs `seconds` past the test's clock.
    private static func challenge(fresh seconds: Int = 300) -> StubProtocol.Reply {
        let exp = Int(now.withLock { $0 }.timeIntervalSince1970) + seconds
        return .json(["challenge": "c1.\(exp).P7cQRSKHbtf5lbPqTWcE6A.3DXJOorkOhcv9Z8sE10upQ", "expires_in": 300])
    }

    func testTheWaits() {
        XCTAssertEqual((1...7).map { AttestBackoff.wait($0) }, [3600, 7200, 14_400, 28_800, 57_600, 86_400, 86_400])
    }

    /// The token: Apple's service unavailable. One try (the token's attestation is not the patient one), an unattested
    /// token, nothing fails; the attestation is owed with its key kept, and Apple is not asked again before its 60 s
    /// floor, across a restart too; after it the SAME key is attested again (Apple: "retry attestation again using the
    /// same key"); when Apple takes it the token is attested and nothing is owed.
    func testAppleUnavailableKeepsTheKeyAndComesBackAfterItsFloor() async throws {
        let attester = FakeAttester(isSupported: true)
        attester.state.with { $0.attestError = DCError(.serverUnavailable) }
        let storage = CloudFixtures.storage()
        let c = cloud(attester, storage: storage)
        StubProtocol.reset(CloudFixtures.server(token: CloudFixtures.token))
        let first = try await c.tokens!.token()
        XCTAssertFalse(first.attested, "unattested, no failure")
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1)
        XCTAssertTrue(c.tokens!.attestationThrottled)
        let owed = c.tokens!.attestState.withLock { $0 }
        XCTAssertTrue(owed.owed)
        XCTAssertEqual(owed.keyID, "fake-key-1", "the key is kept")
        XCTAssertEqual(owed.nextTry, 1_800_000_060, "Apple's floor")
        for _ in 0..<5 {
            await c.tokens!.invalidate()
            _ = try await c.tokens!.token()
        }
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1, "no attestation before the floor")
        // a restart keeps the row
        let again = cloud(attester, storage: storage)
        await again.tokens!.invalidate()
        _ = try await again.tokens!.token()
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1)
        // the floor passes: the same key, refused again
        advance(61)
        await again.tokens!.invalidate()
        _ = try await again.tokens!.token()
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 2)
        XCTAssertEqual(attester.state.with { $0.made }, 1, "no new key for a retry")
        let wait = (again.tokens!.attestState.withLock { $0.nextTry } ?? 0) - 1_800_000_061
        XCTAssertTrue((60...90).contains(wait), "the second wait: 60 s times a draw, at least the floor (\(wait))")
        XCTAssertEqual(again.tokens!.attestBackoff.withLock { $0 }, AttestBackoff(), "no 4.0.2 hold for Apple's service")
        // Apple takes it: an attested token with the same key, and nothing is owed
        attester.state.with { $0.attestError = nil }
        StubProtocol.reset(CloudFixtures.server(token: CloudFixtures.attestedToken))
        advance(91)
        await again.tokens!.invalidate()
        let attested = try await again.tokens!.token()
        XCTAssertTrue(attested.attested)
        XCTAssertEqual(attester.state.with { $0.attestations }, 1)
        XCTAssertEqual(attester.state.with { $0.made }, 1)
        XCTAssertEqual(again.tokens!.attestState.withLock { $0 }, AttestState())
        XCTAssertFalse(again.tokens!.attestationThrottled)
    }

    /// The certificate with the API unreachable after Apple gave its object (a 503 on every try): the tries inside the
    /// call send the SAME object again (its challenge fresh), App Attest is asked once, and NO certificate is made
    /// without attestation (4.0.2 made one inside its hold, which a strict app's lease refuses): the call fails with the
    /// last failure and the attestation is owed. When the API answers, the same object is taken.
    func testTheCertificateWaitsForItsAttestationAndSendsTheSameObjectAgain() async throws {
        let attester = FakeAttester(isSupported: true)
        let c = cloud(attester, storage: Self.requiredStorage())
        XCTAssertEqual(c.config.current?.attestRequired, true)
        let down = Locked(true)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/attest/challenge" { return AttestThrottleTests.challenge() }
            guard s.path == "/v1/attest", s.json?["install_key"] != nil else { return nil }
            if down.withLock({ $0 }) { return .json(["error": "service_unavailable"], status: 503) }
            return .json(["token": "qlt_v1.eyJ2IjoxfQ.att", "expires_in": 86_400, "attested": true, "install_cert": "cert-text"])
        }))
        let key = SoftwareInstallKey(P256KeyFor.tests())
        do {
            _ = try await c.tokens!.certify(key)
            XCTFail("no certificate while the attestation cannot reach Quran Lab")
        } catch {}
        let sent = StubProtocol.seen("/v1/attest").compactMap { $0.json }
        XCTAssertGreaterThanOrEqual(sent.count, 3, "three tries inside the call")
        XCTAssertTrue(sent.allSatisfy { $0["attestation"] != nil }, "never a certificate without attestation")
        XCTAssertEqual(Set(sent.compactMap { $0["attestation"] as? String }).count, 1, "the same object each time")
        XCTAssertEqual(attester.state.with { $0.attestations }, 1, "App Attest asked once")
        XCTAssertTrue(c.tokens!.attestState.withLock { $0.owed })
        XCTAssertEqual(c.tokens!.attestBackoff.withLock { $0 }, AttestBackoff(), "no 4.0.2 hold for a network moment")
        // the API answers again: the same key's object is taken, the key becomes the install's, nothing is owed
        down.withLock { $0 = false }
        let cert = try await c.tokens!.certify(key)
        XCTAssertEqual(cert, "cert-text")
        XCTAssertEqual(attester.state.with { $0.attestations }, 1)
        XCTAssertEqual(attester.state.with { $0.made }, 1)
        XCTAssertEqual(c.tokens!.attestState.withLock { $0 }, AttestState())
    }

    /// A judged failure keeps 4.0.2's hold: the server refused the attestation, the install goes on unattested (as
    /// before), the key is forgotten, and within the hour no attestation is made.
    func testARefusedAttestationKeepsTheHold() async throws {
        let attester = FakeAttester(isSupported: true)
        let c = cloud(attester)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/attest/challenge" { return AttestThrottleTests.challenge() }
            guard s.path == "/v1/attest", s.json?["install_key"] != nil else { return nil }
            if s.json?["attestation"] != nil { return .json(["error": "attestation_failed", "message": "bad"], status: 401) }
            return .json(["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false, "install_cert": "cert-text"])
        }))
        let first = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()))
        XCTAssertEqual(first, "cert-text")
        XCTAssertEqual(c.tokens!.attestBackoff.withLock { $0.failures }, 1)
        XCTAssertNil(c.tokens!.attestState.withLock { $0.keyID }, "the refused key is forgotten")
        XCTAssertNil(StubProtocol.seen("/v1/attest").last?.json?["attestation"], "then sent without one")
        _ = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()))
        XCTAssertEqual(attester.state.with { $0.attestations }, 1, "no attestation while the hold runs")
    }

    /// A 429 on the attest route (the server sheds, ENDPOINTS_40 28.10): the token call gets the 429 (the route is held),
    /// the attestation is owed with the answer's Retry-After as the floor of its next try, and no 4.0.2 hold starts.
    func testA429OnAttestIsOwedWithItsRetryAfterAsTheFloor() async throws {
        let attester = FakeAttester(isSupported: true)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            guard s.path == "/v1/attest" else { return nil }
            return .json(["error": "rate_limited", "message": "too many requests, retry later"], status: 429, headers: ["Retry-After": "900"])
        }))
        let c = cloud(attester)
        do {
            _ = try await c.tokens!.token()
            XCTFail("the 429 is the call's answer")
        } catch {}
        XCTAssertEqual(attester.state.with { $0.attestations }, 1)
        XCTAssertGreaterThanOrEqual(c.tokens!.attestState.withLock { $0.nextTry } ?? 0, 1_800_000_900)
        XCTAssertEqual(c.tokens!.attestBackoff.withLock { $0 }, AttestBackoff())
    }

    /// 40.3: a device App Attest does not serve gives the named path, and the certificate goes without attestation.
    func testAnUnsupportedDeviceNamesItsPath() async throws {
        let attester = FakeAttester(isSupported: false)
        let c = cloud(attester)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            guard s.path == "/v1/attest", s.json?["install_key"] != nil else { return nil }
            return .json(["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false, "install_cert": "cert-text"])
        }))
        _ = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()))
        XCTAssertEqual(c.tokens!.whyUnattested.withLock { $0 }, "unsupported")
        XCTAssertEqual(c.tokens!.diagnosis(certificateAtt: "none").why, "unsupported")
        XCTAssertEqual(c.tokens!.diagnosis(certificateAtt: "none").state, "unattested")
        // a refusal for attestation owes nothing here: attesting again would only make a new key and the same refusal
        c.tokens!.oweAttestation()
        XCTAssertFalse(c.tokens!.attestState.withLock { $0.owed })
    }

    /// 40.2 item 6: a key whose object Apple gave and which can no longer be sent (its challenge ended) is replaced by a
    /// new key; Apple does not say a key can be attested twice.
    func testAnObjectThatCanNoLongerBeSentTakesANewKey() async throws {
        let attester = FakeAttester(isSupported: true)
        let c = cloud(attester, storage: Self.requiredStorage())
        let down = Locked(true)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/attest/challenge" { return AttestThrottleTests.challenge() }
            guard s.path == "/v1/attest", s.json?["install_key"] != nil else { return nil }
            if down.withLock({ $0 }) { return .json(["error": "service_unavailable"], status: 503) }
            return .json(["token": "qlt_v1.eyJ2IjoxfQ.att", "expires_in": 86_400, "attested": true, "install_cert": "cert-text"])
        }))
        let key = SoftwareInstallKey(P256KeyFor.tests())
        do { _ = try await c.tokens!.certify(key); XCTFail("owed") } catch {}
        XCTAssertEqual(c.tokens!.attestState.withLock { $0.keyID }, "fake-key-1")
        // the challenge Apple's object covers has ended
        advance(400)
        down.withLock { $0 = false }
        _ = try await c.tokens!.certify(key)
        XCTAssertEqual(attester.state.with { $0.made }, 2, "a new key")
        XCTAssertEqual(attester.state.with { $0.attestations }, 2)
    }

    /// 40.2 item 8: a lease refused for attestation makes the attestation owed now; inside 4.0.2's hold of a judged
    /// failure it waits for the hold (a refused attestation is not asked for again at once); the network coming back
    /// tries whatever the row's wait, never inside that hold.
    func testARefusalForAttestationMakesItOwedNow() {
        let attester = FakeAttester(isSupported: true)
        let c = cloud(attester)
        c.tokens!.attestState.withLock { $0.failed(.transient, at: 1_800_000_000, answered: false, service: false, draw: 1) }
        XCTAssertFalse(c.tokens!.attestationOwedAndDue())
        XCTAssertTrue(c.tokens!.attestationOwedAndDue(networkBack: true))
        c.tokens!.oweAttestation()
        XCTAssertTrue(c.tokens!.attestationOwedAndDue())
        XCTAssertEqual(c.tokens!.diagnosis(certificateAtt: "none").state, "pending")
        c.tokens!.attestBackoff.withLock { $0.failed(Date(timeIntervalSince1970: 1_800_000_000), throttled: false) }
        c.tokens!.oweAttestation()
        XCTAssertFalse(c.tokens!.attestationOwedAndDue(), "4.0.2's hold runs")
        XCTAssertFalse(c.tokens!.attestationOwedAndDue(networkBack: true))
    }

    /// 40.2 item 1, an app whose lease needs no attestation (no `attest` in the config): the lease is not held up. One
    /// attestation try in the call (no waits); a network moment on it gives the certificate without attestation at once,
    /// and the attestation stays owed. The upgrade (`attestedOnly`) gives an attested certificate when it succeeds and
    /// a failure otherwise, never a certificate without attestation.
    func testAnAppWhoseLeaseNeedsNoAttestationIsNotHeldUp() async throws {
        let attester = FakeAttester(isSupported: true)
        let c = cloud(attester)
        XCTAssertEqual(c.config.current?.attestRequired ?? false, false)
        let down = Locked(true)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/attest/challenge" { return AttestThrottleTests.challenge() }
            guard s.path == "/v1/attest", s.json?["install_key"] != nil else { return nil }
            if s.json?["attestation"] != nil {
                if down.withLock({ $0 }) { return .json(["error": "service_unavailable"], status: 503) }
                return .json(["token": "qlt_v1.eyJ2IjoxfQ.att", "expires_in": 86_400, "attested": true, "install_cert": "cert-attested"])
            }
            return .json(["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false, "install_cert": "cert-none"])
        }))
        let first = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()))
        XCTAssertEqual(first, "cert-none", "the certificate without attestation at once")
        let attested = StubProtocol.seen("/v1/attest").compactMap { $0.json }.filter { $0["attestation"] != nil }
        XCTAssertGreaterThanOrEqual(attested.count, 1)
        XCTAssertEqual(attester.state.with { $0.attestations }, 1, "one try, no waits")
        XCTAssertTrue(c.tokens!.attestState.withLock { $0.owed }, "the attestation stays owed")
        XCTAssertNil(c.tokens!.whyUnattested.withLock { $0 }, "no named path: the platform can attest")
        // the upgrade while it is still down: a failure, and no certificate without attestation is asked
        let before = StubProtocol.seen("/v1/attest").count
        do {
            _ = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()), attestedOnly: true)
            XCTFail("no attested certificate yet")
        } catch {}
        XCTAssertTrue(StubProtocol.seen("/v1/attest").dropFirst(before).allSatisfy { $0.json?["attestation"] != nil })
        // up again: the upgrade gives the attested certificate, and nothing is owed
        down.withLock { $0 = false }
        let up = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()), attestedOnly: true)
        XCTAssertEqual(up, "cert-attested")
        XCTAssertEqual(c.tokens!.attestState.withLock { $0 }, AttestState())
    }
}

/// A software P-256 agreement key for the tests' install certificates.
enum P256KeyFor {
    static func tests() -> P256.KeyAgreement.PrivateKey { P256.KeyAgreement.PrivateKey() }
}
