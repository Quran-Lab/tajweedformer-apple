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
        XCTAssertEqual(ErrorCause.refusal(status: 401, code: "invalid_token", reason: "key_revoked", stage: "config"),
                       ErrorCause(stage: "config", reason: "refused", httpStatus: 401, errorCode: "invalid_token"))
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
}
