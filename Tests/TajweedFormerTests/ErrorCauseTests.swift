import Foundation
import XCTest
@testable import TajweedFormer

/// How the SDK reads a failure into an error report's cause, and what of it a body may carry (24.2:
/// tokens only, never a message or a path).
final class ErrorCauseTests: XCTestCase {
    func testAnswersAndNoAnswers() {
        let redirect = ErrorCause.answer("the server answered with a redirect (HTTP 302), which the SDK never follows", stage: "download")
        XCTAssertEqual(redirect, ErrorCause(stage: "download", reason: "redirect", httpStatus: 302))
        XCTAssertEqual(ErrorCause.answer("HTTP 503", stage: "config"), ErrorCause(stage: "config", reason: "http", httpStatus: 503))
        XCTAssertEqual(ErrorCause.answer("the lease could not be renewed now (HTTP 429)", stage: "lease"),
                       ErrorCause(stage: "lease", reason: "rate_limited", httpStatus: 429))
        let timedOut = ErrorCause.answer(ErrorCause.noAnswer(URLError(.timedOut)), stage: "download")
        XCTAssertEqual(timedOut.reason, "timeout")
        XCTAssertEqual(timedOut.errorName, NSURLErrorDomain)
        XCTAssertEqual(timedOut.errorCode, "-1001")
        let offline = ErrorCause.answer(ErrorCause.noAnswer(URLError(.notConnectedToInternet)), stage: "manifest")
        XCTAssertEqual(offline.reason, "network")
        XCTAssertNil(offline.httpStatus)
        XCTAssertEqual(ErrorCause.answer("needs_connection: the lease has expired (qlc_model_open)", stage: "lease").reason, "expired")
        XCTAssertEqual(ErrorCause.of(RecognizerError.offline("needs_connection: no valid lease for this model on the device")),
                       ErrorCause(stage: "lease", reason: "network"))
        XCTAssertEqual(ErrorCause.answer("unexpected body for model.bin", stage: "download").reason, "invalid_answer")
    }

    func testRefusals() {
        XCTAssertEqual(ErrorCause.refusal(status: 403, code: "origin_not_allowed", reason: nil, stage: "download"),
                       ErrorCause(stage: "download", reason: "refused", httpStatus: 403, errorCode: "origin_not_allowed"))
        // a 401 invalid_token with no stop reason is the token's answer (renewed once), never a refusal: download_failed
        // for a model call, as the model-gate vector's "no error of its own" requires; with a stop reason it refuses
        XCTAssertEqual(ErrorCause.refusal(status: 401, code: "invalid_token", reason: nil, stage: "config"),
                       ErrorCause(stage: "config", reason: "http", httpStatus: 401, errorCode: "invalid_token"))
        XCTAssertEqual(ErrorRules.modelCallCode(ErrorCause.refusal(status: 401, code: "invalid_token", reason: nil, stage: "config"),
                                                onDevice: .nothing), "download_failed")
        // a refusal's error_code is its reason when it names one (the vectors' error_code)
        XCTAssertEqual(ErrorCause.refusal(status: 401, code: "invalid_token", reason: "key_revoked", stage: "config"),
                       ErrorCause(stage: "config", reason: "refused", httpStatus: 401, errorCode: "key_revoked"))
        XCTAssertEqual(ErrorCause.refusal(status: 429, code: "model_limit", reason: nil, stage: "download"),
                       ErrorCause(stage: "download", reason: "rate_limited", httpStatus: 429, errorCode: "model_limit"))
        XCTAssertEqual(ErrorCause.refusal(status: 404, code: "http_404", reason: nil, stage: "manifest"),
                       ErrorCause(stage: "manifest", reason: "http", httpStatus: 404))
        XCTAssertEqual(ErrorCause.refusal(status: 200, code: "invalid_response", reason: nil, stage: "lease"),
                       ErrorCause(stage: "lease", reason: "invalid_answer", httpStatus: 200))
        XCTAssertEqual(ErrorCause.of(CloudError.invalid("config signature does not verify"), stage: "config").reason, "signature")
        XCTAssertEqual(ErrorCause.of(CloudError.invalid("config expired"), stage: "config").reason, "expired")
    }

    /// 24.4 through the model call's rule: a token that got no answer and no config is `needs_connection`; any answer
    /// is `download_failed`.
    func testTheModelCallsCode() {
        XCTAssertEqual(ErrorRules.modelCallCode(ErrorCause(stage: "attest", reason: "network"), onDevice: .nothing), "needs_connection")
        XCTAssertEqual(ErrorRules.modelCallCode(ErrorCause(stage: "attest", reason: "http", httpStatus: 503), onDevice: .nothing), "download_failed")
        XCTAssertEqual(ErrorRules.modelCallCode(ErrorCause(stage: "lease", reason: "redirect", httpStatus: 302), onDevice: .nothing), "download_failed")
        XCTAssertEqual(ErrorRules.modelCallCode(ErrorCause(stage: "download", reason: "network", partial: true), onDevice: .partial), "download_failed")
    }

    /// 24.4 on the lease route: only a stop the Core verified is a stop (rule 3), an unsigned one is `server_rejected`
    /// with its error; no valid lease and no answer is `needs_connection` (rule 1); a 5xx or 429 is `download_failed`.
    func testTheLeaseRoute() {
        let unsigned = ErrorCause(stage: "lease", reason: "refused", httpStatus: 401, errorCode: "key_revoked")
        XCTAssertEqual(TajweedClient.modelCallError(unsigned, onDevice: .complete).code, "server_rejected")
        let verified = ErrorCause(stage: "lease", reason: "stopped", httpStatus: 401, errorCode: "key_revoked")
        XCTAssertEqual(TajweedClient.modelCallError(verified, onDevice: .complete).code, "invalid_key")
        let blocked = ErrorCause(stage: "lease", reason: "stopped", httpStatus: 403, errorCode: "app_blocked")
        XCTAssertEqual(TajweedClient.modelCallError(blocked, onDevice: .complete).code, "server_rejected")
        XCTAssertEqual(TajweedClient.modelCallError(ErrorCause(stage: "lease", reason: "http", httpStatus: 503), onDevice: .complete).code,
                       "download_failed")
        XCTAssertEqual(TajweedClient.modelCallError(ErrorCause(stage: "lease", reason: "rate_limited", httpStatus: 429), onDevice: .complete).code,
                       "download_failed")
        XCTAssertEqual(TajweedClient.modelCallError(ErrorCause(stage: "lease", reason: "network"), onDevice: .complete).code, "needs_connection")
        XCTAssertEqual(TajweedError(from: .offline("needs_connection: the lease has expired (qlc_model_open)")).code, "needs_connection")
        // the refusal's reason, when it names one, is the report's error_code (the vectors' `error_code`)
        XCTAssertEqual(ErrorCause.refusal(status: 401, code: "invalid_key", reason: "key_revoked", stage: "config").errorCode, "key_revoked")
    }

    /// A field that is not the token its pattern asks for is left out, never cut into one.
    func testTheBodyCarriesTokensOnly() throws {
        let e = ErrorReportBook.Entry(day: "2026-11-18", sig: "s", stage: "storage", reason: "write", code: "storage_failed", httpStatus: 99,
                                      count: 0, firstReport: true, firstLaunch: false, errorName: "could not allocate",
                                      errorCode: "/data/x", retries: 5000, revision: "4.0.0", build: "abc")
        let d = try JSONEncoder().encode(ErrorReportBody(e, app: CloudFixtures.app))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        XCTAssertEqual(o["kind"] as? String, "error")
        XCTAssertEqual(o["revision"] as? String, "4.0.0")
        let error = try XCTUnwrap(o["error"] as? [String: Any])
        // and no free space (E174.1: nothing derived from it leaves the device)
        for gone in ["http_status", "error_name", "error_code", "build", "storage_free"] { XCTAssertNil(error[gone], gone) }
        XCTAssertEqual(error["count"] as? Int, 1)
        XCTAssertEqual(error["retries"] as? Int, 1000)
    }

    /// ERRORS_40 24.3: a `403 lease_integrity_failed` at the attest or the lease is
    /// `integrity_failed`, its `error_code` the answer's `why`, `:` and its `check` (`verdict:boot`), `why` alone when the
    /// two would pass 32 characters or `check` is not a token, `lease_integrity_failed` with no `why`; the developer's
    /// message names the same check, and the app's code stays `server_rejected`.
    func testAnIntegrityRefusalNamesItsCheck() throws {
        XCTAssertEqual(ErrorCause.integrityCode(why: "verdict", check: "boot"), "verdict:boot")
        XCTAssertEqual(ErrorCause.integrityCode(why: "verdict", check: "digest"), "verdict:digest")
        XCTAssertEqual(ErrorCause.integrityCode(why: "verdict", check: "recorded"), "verdict:recorded")
        XCTAssertEqual(ErrorCause.integrityCode(why: "downgrade", check: nil), "downgrade")
        XCTAssertEqual(ErrorCause.integrityCode(why: "core", check: nil), "core")
        XCTAssertEqual(ErrorCause.integrityCode(why: nil, check: "boot"), "lease_integrity_failed", "no why")
        XCTAssertEqual(ErrorCause.integrityCode(why: "verdict", check: String(repeating: "c", count: 25)), "verdict", "the two pass 32")
        XCTAssertEqual(ErrorCause.integrityCode(why: "verdict", check: "not a token!"), "verdict", "the check is no token")
        XCTAssertEqual(ErrorCause.integrityCode(why: "no token!", check: "boot"), "lease_integrity_failed")
        func body(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        let verdict: [String: Any] = ["error": "lease_integrity_failed", "message": "This device could not be verified.", "why": "verdict", "check": "boot"]
        // the lease route: the cause (as ProtectedRuntime makes it), and the error the app gets
        let refusal = LeaseRefusal.classify(status: 403, body: body(verdict))
        guard case .refused(code: "lease_integrity_failed", why: .some("verdict")) = refusal else { return XCTFail("\(refusal)") }
        let e = refusal.error(status: 403, body: body(verdict))
        guard case .serverRejected(403, "lease_integrity_failed", _, .some("verdict:boot")) = e else { return XCTFail("\(e)") }
        let made = TajweedError(from: e, cause: ErrorCause(stage: "lease", reason: "integrity_failed", httpStatus: 403, errorCode: "verdict:boot"))
        XCTAssertEqual(made.code, "server_rejected")
        XCTAssertTrue(made.message.contains("verdict:boot"), made.message)
        XCTAssertNil(ModelGate.stopReasons.first { $0 == "verdict:boot" }, "never a stop")
        // the attest's answer, through the HTTP client's refusal
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: body(verdict)) as? [String: Any])
        let attest = CloudError.rejected(status: 403, code: "lease_integrity_failed", message: HTTPClient.message(o), reason: HTTPClient.reason(o))
        XCTAssertEqual(ErrorCause.of(attest, stage: "attest"),
                       ErrorCause(stage: "attest", reason: "integrity_failed", httpStatus: 403, errorCode: "verdict:boot"))
        // no why: the error's own name, as the vector's case has it
        let bare = CloudError.rejected(status: 403, code: "lease_integrity_failed", message: "", reason: HTTPClient.reason(["error": "lease_integrity_failed"]))
        XCTAssertEqual(ErrorCause.of(bare, stage: "lease"),
                       ErrorCause(stage: "lease", reason: "integrity_failed", httpStatus: 403, errorCode: "lease_integrity_failed"))
        let plain = TajweedError(from: LeaseRefusal.classify(status: 403, body: body(["error": "lease_integrity_failed"]))
            .error(status: 403, body: body(["error": "lease_integrity_failed"])))
        XCTAssertEqual(plain.code, "server_rejected")
        XCTAssertTrue(plain.message.contains("lease_integrity_failed"), plain.message)
    }
}
