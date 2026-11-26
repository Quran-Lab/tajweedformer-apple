import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, ERRORS_40 24.14 (`lease_attestation_required`, a strict app's unattested production install): the refusal
/// remembered for the app's next calls (item 4) and an unattested install of a new app release attesting again
/// (item 5). The words and the cause replay the contract's vectors in ErrorReportVectorTests (`testWords`,
/// `testCauses`); the runtime with the test Core in ProtectedCoreTests.
final class AttestStrictTests: XCTestCase {
    /// Item 4: an app call within 10 minutes of the refusal gets the same error, with the same cause, without a request;
    /// another version or build of the app asks at once.
    func testTheRefusalIsRememberedForTenMinutesOfTheSameRelease() {
        let r = AttestationRefusal(at: 1_000_000, appRelease: "2.1 (40)", status: 403, code: "lease_attestation_required", message: "no")
        XCTAssertTrue(r.holds(now: 1_000_000, release: "2.1 (40)"))
        XCTAssertTrue(r.holds(now: 1_000_599, release: "2.1 (40)"))
        XCTAssertFalse(r.holds(now: 1_000_600, release: "2.1 (40)"), "10 minutes later the call asks")
        XCTAssertFalse(r.holds(now: 1_000_010, release: "2.1 (41)"), "another build asks at once")
        XCTAssertFalse(r.holds(now: 1_000_010, release: "2.2 (40)"), "another version asks at once")
        XCTAssertFalse(r.holds(now: 999_000, release: "2.1 (40)"), "a clock set back asks")
        guard case .serverRejected(403, "lease_attestation_required", "no", nil) = r.error else { return XCTFail("\(r.error)") }
        XCTAssertEqual(r.cause, ErrorCause(stage: "lease", reason: "refused", httpStatus: 403, errorCode: "lease_attestation_required"))
        // the app's error: server_rejected, the reason's words, the cause of 24.14 item 2
        let e = TajweedError(from: r.error, cause: r.cause)
        XCTAssertEqual(e.code, "server_rejected")
        XCTAssertEqual(e.cause?.stage, "lease")
        XCTAssertEqual(e.cause?.reason, "refused")
        XCTAssertEqual(e.cause?.httpStatus, 403)
        XCTAssertEqual(e.cause?.errorCode, "lease_attestation_required")
    }

    /// Item 5: a certificate that says `att none` with `recheck 0` attests again when the app's release differs from the
    /// one it attested with (one an earlier SDK kept names none); an attested one, one Google's outage made (`recheck
    /// 1`) and an unknown release never do.
    func testAnUnattestedInstallOfANewReleaseAttestsAgain() {
        func cert(_ att: String, recheck: String = "0") -> InstallCertificate {
            InstallCertificate(encoded: "", fields: ["att": att, "recheck": recheck])
        }
        XCTAssertTrue(StoredCertificate.attestsAgain(cert("none"), attestedWith: "2.1 (40)", release: "2.2 (41)"))
        XCTAssertTrue(StoredCertificate.attestsAgain(cert("none"), attestedWith: nil, release: "2.2 (41)"), "kept by 4.0.4")
        XCTAssertFalse(StoredCertificate.attestsAgain(cert("none"), attestedWith: "2.2 (41)", release: "2.2 (41)"), "the same release")
        XCTAssertFalse(StoredCertificate.attestsAgain(cert("apple"), attestedWith: "2.1 (40)", release: "2.2 (41)"), "attested")
        XCTAssertFalse(StoredCertificate.attestsAgain(cert("none", recheck: "1"), attestedWith: "2.1 (40)", release: "2.2 (41)"))
        XCTAssertFalse(StoredCertificate.attestsAgain(cert("none"), attestedWith: "2.1 (40)", release: ""), "no release known")
        // a certificate stored by an earlier SDK (no release) still reads
        let old = try? JSONDecoder().decode(StoredCertificate.self, from: Data("{\"generation\":3,\"certificate\":\"x.y\"}".utf8))
        XCTAssertEqual(old?.generation, 3)
        XCTAssertNil(old?.appRelease)
    }

    /// Item 5: the App Attest retry hold is cleared before the attest again (a release that adds the capability is not
    /// held by the old release's failures).
    func testClearingTheAttestHold() throws {
        let storage = CloudFixtures.storage()
        let tokens = TokenProvider(http: HTTPClient(session: StubProtocol.session()), apiURL: CloudFixtures.api, key: CloudFixtures.key,
                                   app: CloudFixtures.app, teamID: nil, attester: FakeAttester(isSupported: true),
                                   attestKeys: MemoryAttestKeyStore(), storage: storage)
        tokens.attestBackoff.withLock { $0.failed(Date(), throttled: false) }
        XCTAssertGreaterThan(tokens.attestBackoff.withLock { $0.failures }, 0)
        tokens.clearAttestHold()
        XCTAssertEqual(tokens.attestBackoff.withLock { $0 }, AttestBackoff())
    }
}
