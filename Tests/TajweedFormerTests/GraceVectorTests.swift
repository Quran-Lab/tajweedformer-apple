import Foundation
import XCTest
@testable import TajweedFormer

/// Contract 18.4.7.1 (ca3f9a5, 1c971ab): `vectors/grace.json`'s 40 `outcomes`, each attempt's answers replayed in
/// order through the SDK's classifier (`LeaseAttemptTrace`: the answer of the attempt's last request decides) as the
/// lease route records them: the challenge and `model-key` answers as they arrive (`answered`), the token and attest
/// answers as the SDK's HTTP client words them (`failed`, a `CloudError`). A lease the Core accepts is a lease, a stop
/// the Core verifies is a stop; anything else is refused or unreachable. The sequences and the override leases are
/// replayed by the Core's own run_vectors (671 checks at 1c971ab); the SDK's side of them is in ProtectedCoreTests.
final class GraceVectorTests: XCTestCase {
    static func body(_ a: [String: Any]) -> Data {
        switch a["body"] as? String {
        case "json":
            var o: [String: Any] = [:]
            if let e = a["error"] as? String { o["error"] = e }
            if let r = a["reason"] as? String { o["reason"] = r }
            return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
        case "html": return Data("<html><body>Sign in to this network</body></html>".utf8)
        default: return Data()
        }
    }

    /// What the SDK's HTTP client throws for a token or attest answer that is not a 2xx (`HTTPClient.checked`).
    static func cloudError(_ a: [String: Any]) -> CloudError? {
        guard let status = a["status"] as? Int else { return .offline("no answer [NSURLErrorDomain -1001]") }
        if (200...299).contains(status) { return nil }
        if status >= 500 { return .offline("HTTP \(status)") }
        let code = (a["body"] as? String) == "json" ? (a["error"] as? String ?? "http_\(status)") : "http_\(status)"
        return .rejected(status: status, code: code, message: "", reason: a["reason"] as? String)
    }

    static func outcome(_ answers: [[String: Any]]) -> String {
        let trace = LeaseAttemptTrace()
        for a in answers {
            let route = a["route"] as? String ?? ""
            if route == "token" || route == "attest" {
                if let e = cloudError(a) { trace.failed(e) }
                continue
            }
            guard let status = a["status"] as? Int else {
                trace.asking() // none, stalled or late: no answer
                continue
            }
            trace.asking()
            trace.answered(status: status, body: body(a), retryAfter: nil)
            if route == "model-key", let core = a["core"] as? String {
                if core == "accepted" { return "lease" }
                if core == "stop" { trace.stop(); return "stop" }
                // a 2xx lease the Core refuses: recorded as the 200 it was (unreachable)
            }
        }
        return trace.apiRefusal ? "refused" : "unreachable"
    }

    func testTheOutcomes() throws {
        let v = try V40.json("grace.json")
        let cases = try XCTUnwrap(v["outcomes"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 40)
        for c in cases {
            let answers = try XCTUnwrap(c["answers"] as? [[String: Any]])
            XCTAssertEqual(Self.outcome(answers), c["outcome"] as? String, c["name"] as? String ?? "?")
        }
    }

    /// 18.4.7 (1c971ab): Retry-After is whole seconds 1 to 21600. 18.4.7.3 (SDK 4.0.2, dd76474): it is the floor of the
    /// drawn wait, never a replacement: a 30 still waits the drawn time, a 3000 waits 3000 (to 4.0.1 the 30 replaced
    /// the step).
    func testRetryAfter() {
        XCTAssertEqual(LeaseRetry.retryAfter("30"), 30)
        XCTAssertEqual(LeaseRetry.retryAfter(" 21600 "), 21_600)
        for bad in [nil, "0", "21601", "-5", "Wed, 21 Oct 2026 07:28:00 GMT", "3.5"] { XCTAssertEqual(LeaseRetry.retryAfter(bad), 0, bad ?? "nil") }
        var r = LeaseRetry()
        r.failed(now: 1000, retryAfter: 30, draw: { _ in 700 })
        XCTAssertEqual(r.notBefore, 1700)
        r.failed(now: 2000, draw: { _ in 1800 })
        XCTAssertEqual(r.notBefore, 3800)
        var s = LeaseRetry()
        s.failed(now: 1000, retryAfter: 3000, draw: { _ in 1800 })
        XCTAssertEqual(s.notBefore, 4000)
        s.failed(now: 5000, retryAfter: 30, draw: { _ in 600 })
        XCTAssertEqual(s.notBefore, 5600, "a later failure draws afresh")
        XCTAssertEqual(s.failures, 2)
    }

    /// The reason a report of an open in grace names (ERRORS_40 24.3): the cause's, else the status's.
    func testGraceReasons() {
        XCTAssertEqual(ProtectedRuntime.graceReason(ErrorCause(stage: "lease", reason: "lease_unavailable", httpStatus: 503), status: 503), "lease_unavailable")
        XCTAssertEqual(ProtectedRuntime.graceReason(nil, status: 0), "network")
        XCTAssertEqual(ProtectedRuntime.graceReason(nil, status: 429), "rate_limited")
        XCTAssertEqual(ProtectedRuntime.graceReason(nil, status: 302), "redirect")
        XCTAssertEqual(ProtectedRuntime.graceReason(nil, status: 200), "invalid")
        XCTAssertEqual(ProtectedRuntime.graceReason(nil, status: 502), "http")
        XCTAssertEqual(ErrorRules.code(stage: "lease", reason: "grace", status: 503, onDevice: .complete, errorCode: "lease_unavailable"), "none")
        XCTAssertEqual(ErrorRules.code(stage: "lease", reason: "lease_unavailable", status: 503, onDevice: .complete, errorCode: "lease_unavailable"), "download_failed")
    }
}
