import CryptoKit
import DeviceCheck
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.2, App Attest under load (the Ramadan capacity model): Apple asks an app for fewer than 100 attestations a
/// second, and 4.0 attests twice per new install (the token's key and the certificate's). An attestation App Attest
/// refuses (`DCError.serverUnavailable` when Apple throttles), or one the API does not take, makes the install go on
/// unattested (ERRORS_40 24.4 rule 3a) and attest again only after a wait of 1 hour doubling to 24 hours
/// (`AttestBackoff`), never at every call. The fake attester and the stub server; the client's clock moves by hand.
final class AttestThrottleTests: XCTestCase {
    static let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { Self.now.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000) } }

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

    func testTheWaits() {
        XCTAssertEqual((1...7).map { AttestBackoff.wait($0) }, [3600, 7200, 14_400, 28_800, 57_600, 86_400, 86_400])
    }

    /// The token: Apple throttles, so the token is unattested and nothing fails; a token asked for again within the
    /// hour asks Apple nothing (4.0.1 attested a new key each time a token was asked for); after the hour it attests
    /// again, and an attested token ends the row. The wait outlives a restart.
    func testAThrottledAttestationGoesOnUnattestedAndWaits() async throws {
        let attester = FakeAttester(isSupported: true)
        attester.state.with { $0.attestError = DCError(.serverUnavailable) }
        let storage = CloudFixtures.storage()
        let c = cloud(attester, storage: storage)
        StubProtocol.reset(CloudFixtures.server(token: CloudFixtures.token))
        let first = try await c.tokens!.token()
        XCTAssertFalse(first.attested, "unattested, no failure")
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1)
        XCTAssertTrue(c.tokens!.attestationThrottled)
        for _ in 0..<5 {
            await c.tokens!.invalidate()
            _ = try await c.tokens!.token()
        }
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1, "no attestation while the wait runs")
        // a restart keeps the wait
        let again = cloud(attester, storage: storage)
        await again.tokens!.invalidate()
        _ = try await again.tokens!.token()
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1)
        // the hour passes: one attestation, refused again, then a wait of two hours
        advance(3601)
        await again.tokens!.invalidate()
        _ = try await again.tokens!.token()
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 2)
        XCTAssertEqual(again.tokens!.attestBackoff.withLock { $0.failures }, 2)
        advance(3601)
        await again.tokens!.invalidate()
        _ = try await again.tokens!.token()
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 2, "the second wait is two hours")
        // Apple takes it again: an attested token, and the row ends
        attester.state.with { $0.attestError = nil }
        StubProtocol.reset(CloudFixtures.server(token: CloudFixtures.attestedToken))
        advance(3600)
        await again.tokens!.invalidate()
        let attested = try await again.tokens!.token()
        XCTAssertTrue(attested.attested)
        XCTAssertEqual(attester.state.with { $0.attestations }, 1)
        XCTAssertEqual(again.tokens!.attestBackoff.withLock { $0 }, AttestBackoff())
        XCTAssertFalse(again.tokens!.attestationThrottled)
    }

    /// The API fails after Apple gave the attestation (a 503 on /v1/attest): the next calls that need a token do not
    /// attest a new key at each (4.0.1 did); they wait the hour.
    func testAnAttestationTheAPIDidNotTakeIsNotAskedAgainAtEveryCall() async throws {
        let attester = FakeAttester(isSupported: true)
        let c = cloud(attester)
        StubProtocol.reset(CloudFixtures.server(extra: { s in s.path == "/v1/attest" ? StubProtocol.Reply(status: 503) : nil }))
        for _ in 0..<4 {
            do {
                _ = try await c.tokens!.token()
                XCTFail("no token while the attest route answers 503")
            } catch {}
        }
        XCTAssertEqual(attester.state.with { $0.attestations }, 1, "one attestation, not one per call")
        XCTAssertFalse(c.tokens!.attestationThrottled, "not Apple's throttling")
    }

    /// The certificate: a throttled attestation makes the certificate's request go without one (att none: the
    /// 24-hour class), nothing fails; within the wait a new certificate asks Apple nothing.
    func testTheCertificateGoesUnattestedAndWaitsToo() async throws {
        let attester = FakeAttester(isSupported: true)
        attester.state.with { $0.attestError = DCError(.serverUnavailable) }
        let c = cloud(attester)
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            guard s.path == "/v1/attest", s.json?["install_key"] != nil else { return nil }
            return .json(["token": "qlt_v1.eyJ2IjoxfQ.sig", "expires_in": 86_400, "attested": false, "install_cert": "cert-text"])
        }))
        let key = SoftwareInstallKey(P256KeyFor.tests())
        let first = try await c.tokens!.certify(key)
        XCTAssertEqual(first, "cert-text")
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1)
        let sent = try XCTUnwrap(StubProtocol.seen("/v1/attest").last?.json)
        XCTAssertNil(sent["attestation"], "sent without an attestation")
        _ = try await c.tokens!.certify(SoftwareInstallKey(P256KeyFor.tests()))
        XCTAssertEqual(attester.state.with { $0.attestRefused }, 1, "no attestation while the wait runs")
        XCTAssertNil(StubProtocol.seen("/v1/attest").last?.json?["attestation"])
    }

    /// A 429 on the attest route (the server sheds, ENDPOINTS_40 28.10): the attestation was spent, and the next one
    /// waits the backoff with the answer's Retry-After as its floor (1 hour for a Retry-After of 90, 7200 s for one of
    /// 7200). Once the route's own hold is over and while the backoff runs, the install goes on unattested and makes no
    /// App Attest attestation; after the wait it attests again.
    func testA429OnAttestWaitsTheBackoffWithItsRetryAfterAsTheFloor() async throws {
        for (ra, wait) in [(90, 3600.0), (7200, 7200.0)] {
            Self.now.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000) }
            let t0 = Self.now.withLock { $0 }
            let attester = FakeAttester(isSupported: true)
            let shed = Locked(true)
            StubProtocol.reset(CloudFixtures.server(extra: { s in
                guard s.path == "/v1/attest", shed.withLock({ $0 }) else { return nil }
                return .json(["error": "rate_limited", "message": "too many requests, retry later"], status: 429,
                             headers: ["Retry-After": String(ra)])
            }))
            let c = cloud(attester)
            do {
                _ = try await c.tokens!.token()
                XCTFail("RA \(ra): the 429 is the call's answer")
            } catch {}
            XCTAssertEqual(attester.state.with { $0.attestations }, 1)
            XCTAssertEqual(c.tokens!.attestBackoff.withLock { $0.notBefore }, t0.addingTimeInterval(wait), "RA \(ra)")
            shed.withLock { $0 = false }
            advance(TimeInterval(ra) + 1)
            await c.tokens!.invalidate()
            _ = try await c.tokens!.token()
            if ra < 3600 {
                XCTAssertEqual(attester.state.with { $0.attestations }, 1, "unattested while the backoff runs, no attestation")
            } else {
                XCTAssertEqual(attester.state.with { $0.attestations }, 2, "after the Retry-After the install attests again")
            }
        }
    }
}

/// A software P-256 agreement key for the tests' install certificates.
enum P256KeyFor {
    static func tests() -> P256.KeyAgreement.PrivateKey { P256.KeyAgreement.PrivateKey() }
}
