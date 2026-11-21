import Foundation
import XCTest
@testable import TajweedFormer

/// Contract section 24 (`sdk_4.0.0/ERRORS_40.md`): `vectors/errors_40.json` (copied into Fixtures/vectors40)
/// replayed through the SDK's rules: every `codes` case through `ErrorRules.code` and `reported` (24.4,
/// 24.1), every `queue` sequence through `ErrorReportBook` (24.5, 24.6), the `signatures` (24.5) and the `telemetry`
/// names of a failed download (24.8).
final class ErrorReportVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] { try V40.json("errors_40.json") }

    /// A JSON value that is a number, as an Int; nil for null.
    static func int(_ x: Any?) -> Int? { (x as? NSNumber)?.intValue }

    func testCodes() throws {
        let cases = try XCTUnwrap(try Self.vectors()["codes"] as? [[String: Any]])
        // 49 at 98e98f4, the 12 of rules 3 and 3a at f209443 (3 attest, 9 lease), 3 of the grace at ca3f9a5, 2 of 503
        // lease_unavailable at 1c971ab, 3 of section 28's silent failover at de2a2da and 4 of the Core's open at 7f097b9
        XCTAssertEqual(cases.count, 73)
        for c in cases {
            let stage = try XCTUnwrap(c["stage"] as? String), reason = try XCTUnwrap(c["reason"] as? String)
            let onDevice = try XCTUnwrap(ErrorRules.OnDevice(rawValue: try XCTUnwrap(c["on_device"] as? String)))
            let want = try XCTUnwrap(c["code"] as? String)
            let got = ErrorRules.code(stage: stage, reason: reason, status: Self.int(c["http_status"]), onDevice: onDevice,
                                      errorCode: c["error_code"] as? String)
            let name = "\(stage) \(reason) \(onDevice)"
            XCTAssertEqual(got, want, name)
            XCTAssertEqual(ErrorRules.reported(stage: stage, reason: reason, code: got), try XCTUnwrap(c["reported"] as? Bool), name)
        }
    }

    func testSignatures() throws {
        let cases = try XCTUnwrap(try Self.vectors()["signatures"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let stage = try XCTUnwrap(c["stage"] as? String), reason = try XCTUnwrap(c["reason"] as? String)
            let code = try XCTUnwrap(c["code"] as? String), status = Self.int(c["http_status"])
            XCTAssertEqual(ErrorRules.signature(stage: stage, reason: reason, code: code, status: status), c["string"] as? String)
            XCTAssertEqual(ErrorRules.signatureHex(stage: stage, reason: reason, code: code, status: status), c["hex"] as? String)
        }
    }

    func testTelemetryNames() throws {
        let cases = try XCTUnwrap(try Self.vectors()["telemetry"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 13)
        for c in cases {
            let reason = try XCTUnwrap(c["reason"] as? String), want = try XCTUnwrap(c["failure_reason"] as? String)
            XCTAssertEqual(ErrorRules.telemetryReason(reason), want, reason)
            // the SDK's telemetry counts it under the same name (Analytics `DownloadFailure`)
            XCTAssertEqual(DownloadFailure(reason: reason).rawValue, want, reason)
        }
    }

    /// The limits the vectors name are the book's.
    func testLimits() throws {
        let l = try XCTUnwrap(try Self.vectors()["limits"] as? [String: Any])
        XCTAssertEqual(Self.int(l["daily_signatures"]), ErrorReportBook.dailySignatures)
        XCTAssertEqual(Self.int(l["queue_max"]), ErrorReportBook.queueMax)
        XCTAssertEqual(Self.int(l["reported_max"]), ErrorReportBook.reportedMax)
        XCTAssertEqual(Self.int(l["first_again_days"]), ErrorReportBook.firstAgainDays)
        XCTAssertEqual(Self.int(l["keep_days"]), ErrorReportBook.keepDays)
        XCTAssertEqual(Self.int(l["count_max"]), ErrorReportBook.countMax)
        XCTAssertEqual(Set(try XCTUnwrap(try Self.vectors()["codes_not_reported"] as? [String])), ErrorRules.notReported)
    }

    /// Each sequence of occurrences, send points (the server's answers in order, null for none) and `issues_off`, on
    /// the vectors' days: what each occurrence made, and the requests each send point made, field by field.
    func testQueue() throws {
        let cases = try XCTUnwrap(try Self.vectors()["queue"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 15)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            var book = ErrorReportBook()
            var on = true
            for (i, step) in try XCTUnwrap(c["steps"] as? [[String: Any]]).enumerated() {
                let expect = try XCTUnwrap(step["expect"] as? [String: Any])
                let at = "\(name), step \(i)"
                switch try XCTUnwrap(step["op"] as? String) {
                case "occur":
                    let cause = ErrorCause(stage: try XCTUnwrap(step["stage"] as? String), reason: try XCTUnwrap(step["reason"] as? String),
                                           httpStatus: Self.int(step["http_status"]))
                    let made = book.occur(day: try XCTUnwrap(step["day"] as? String), cause: cause, code: try XCTUnwrap(step["code"] as? String),
                                          firstLaunch: try XCTUnwrap(step["first_launch"] as? Bool), enabled: on)
                    XCTAssertEqual(made, try XCTUnwrap(expect["made"] as? Bool), at)
                case "send":
                    var answers: [Int?] = try XCTUnwrap(step["answers"] as? [Any]).map { Self.int($0) }
                    var made: [[String: Any]] = []
                    for e in book.due(today: try XCTUnwrap(step["day"] as? String)) {
                        guard !answers.isEmpty else { break }
                        let a = answers.removeFirst()
                        made.append(["day": e.day, "stage": e.stage, "reason": e.reason, "code": e.code, "http_status": e.httpStatus as Any,
                                     "count": e.count, "first_report": e.firstReport, "first_launch": e.firstLaunch, "answer": a as Any])
                        if !book.answered(e, status: a) { break }
                    }
                    let want = try XCTUnwrap(expect["requests"] as? [[String: Any]])
                    XCTAssertEqual(made.count, want.count, at)
                    for (got, w) in zip(made, want) {
                        for k in ["day", "stage", "reason", "code"] { XCTAssertEqual(got[k] as? String, w[k] as? String, "\(at) \(k)") }
                        for k in ["first_report", "first_launch"] { XCTAssertEqual(got[k] as? Bool, w[k] as? Bool, "\(at) \(k)") }
                        XCTAssertEqual(got["count"] as? Int, Self.int(w["count"]), "\(at) count")
                        XCTAssertEqual(got["http_status"] as? Int, Self.int(w["http_status"]), "\(at) http_status")
                        XCTAssertEqual(got["answer"] as? Int, Self.int(w["answer"]), "\(at) answer")
                    }
                case "issues_off":
                    // flags.issues false: the queue goes and nothing is recorded
                    on = false
                    book.dropQueue()
                default:
                    XCTFail("an op the replay does not know: \(at)")
                }
            }
        }
    }
}
