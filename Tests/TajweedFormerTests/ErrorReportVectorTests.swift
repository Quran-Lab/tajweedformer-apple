import Foundation
import XCTest
@testable import TajweedFormer

/// Contract section 24 (`sdk_4.0.0/ERRORS_40.md`): `vectors/errors_40.json` (copied into Fixtures/vectors40 from
/// adca6f6, SDK 4.0.2, with 24.13's `causes`; 7f097b9 before) replayed through the SDK's rules: every `codes` case through `ErrorRules.code` and `reported` (24.4,
/// 24.1), every `queue` sequence through `ErrorReportBook` (24.5, 24.6), the `signatures` (24.5) and the `telemetry`
/// names of a failed download (24.8).
final class ErrorReportVectorTests: XCTestCase {
    static func vectors() throws -> [String: Any] { try V40.json("errors_40.json") }

    /// A JSON value that is a number, as an Int; nil for null.
    static func int(_ x: Any?) -> Int? { (x as? NSNumber)?.intValue }

    func testCodes() throws {
        let cases = try XCTUnwrap(try Self.vectors()["codes"] as? [[String: Any]])
        // 49 at 98e98f4, the 12 of rules 3 and 3a at f209443 (3 attest, 9 lease), 3 of the grace at ca3f9a5, 2 of 503
        // lease_unavailable at 1c971ab, 3 of section 28's silent failover at de2a2da, 4 of the Core's open at 7f097b9 and
        // 2 of section 31's install_blocked at 0a4a46d (the copy of 3ca913b); 6 of 40.5 and 40.6 at 062689b (invalid_answer
        // for attest and lease, the fixture's SOURCE.txt)
        XCTAssertEqual(cases.count, 81)
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

    // MARK: 24.13, the cause on the app's error (SDK 4.0.2)

    /// The cause as the vectors write it: the report's names, an absent field left out.
    static func dict(_ c: TajweedError.Cause?) -> NSDictionary? {
        guard let c else { return nil }
        var d: [String: Any] = ["stage": c.stage, "reason": c.reason]
        if let v = c.httpStatus { d["http_status"] = v }
        if let v = c.errorName { d["error_name"] = v }
        if let v = c.errorCode { d["error_code"] = v }
        if let v = c.needs { d["needs"] = v }
        return d as NSDictionary
    }

    /// `causes`: each occurrence to the code the app gets and the cause its
    /// error carries, made where every error is made (`TajweedError.init`, which also makes the report): the report's
    /// tokens, a value that fails 24.2's pattern left out, `needs` on `needs_connection` only, by what of the call's
    /// files is on the device. No Client is configured here, so no report is made: the cause does not depend on reports.
    func testCauses() throws {
        let cases = try XCTUnwrap(try Self.vectors()["causes"] as? [[String: Any]])
        // 17 at 3ca913b: 24.14's two lease refusals for attestation appended; 19 at 062689b (40.5 and 40.6's two)
        XCTAssertEqual(cases.count, 19)
        XCTAssertNil(QuranLab.cloud, "no Client: no report is made, the cause is there all the same")
        for c in cases {
            let label = c["label"] as? String ?? "?"
            let onDevice = try XCTUnwrap(ErrorRules.OnDevice(rawValue: try XCTUnwrap(c["on_device"] as? String)), label)
            let cause = ErrorCause(stage: try XCTUnwrap(c["stage"] as? String), reason: try XCTUnwrap(c["reason"] as? String),
                                   httpStatus: Self.int(c["http_status"]), errorName: c["error_name"] as? String,
                                   errorCode: c["error_code"] as? String)
            let code = ErrorRules.code(stage: cause.stage, reason: cause.reason, status: cause.httpStatus, onDevice: onDevice,
                                       errorCode: cause.errorCode)
            XCTAssertEqual(code, c["code"] as? String, label)
            let want = (c["cause"] as? [String: Any]).map { $0 as NSDictionary }
            guard let known = ErrorCode(rawValue: code) else {
                // a silent failure makes no error
                XCTAssertEqual(code, "none", label)
                XCTAssertNil(want, label)
                XCTAssertNil(TajweedError.Cause.made(cause, code: code, onDevice: onDevice), label)
                continue
            }
            let error = TajweedError(known, cause: cause, onDevice: onDevice)
            XCTAssertEqual(error.code, code, label)
            XCTAssertEqual(Self.dict(error.cause), want, label)
        }
    }

    /// SDK 4.0.5 (24.14): `words`, the message and fix of the error the app gets for a code, the answer's error and a
    /// platform, from the embedded catalogue; and Apple's own platform names its fix (`ios` or `macos`).
    func testWords() throws {
        let cases = try XCTUnwrap(try Self.vectors()["words"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8, "every case of words is read")
        for c in cases {
            let label = c["label"] as? String ?? "?"
            let code = try XCTUnwrap(c["code"] as? String), error = c["error"] as? String, platform = try XCTUnwrap(c["platform"] as? String)
            XCTAssertEqual(TajweedError.knownReason(error), c["reason"] as? String, label)
            let t = try XCTUnwrap(ErrorCatalogue.shared.texts(code, reason: TajweedError.knownReason(error), platform: platform), label)
            XCTAssertEqual(t.message, c["message"] as? String, label)
            XCTAssertEqual(t.fix, c["fix"] as? String, label)
        }
        // the app's error: server_rejected with the reason's words and the fix of the platform the SDK runs on
        let e = TajweedError(from: .serverRejected(status: 403, code: "lease_attestation_required", message: "no"))
        XCTAssertEqual(e.code, "server_rejected")
        XCTAssertTrue(e.message.hasSuffix("(lease_attestation_required)."), e.message)
        let mine = try XCTUnwrap(cases.first { ($0["platform"] as? String) == ErrorCatalogue.platform && ($0["error"] as? String) == "lease_attestation_required" })
        XCTAssertEqual(e.fix, mine["fix"] as? String)
        XCTAssertTrue(["ios", "macos"].contains(ErrorCatalogue.platform))
    }

    /// The codes that only say the app used the API wrongly carry no cause (24.13 item 1), made either way; every other
    /// code carries one; and the cause takes part in the error's equality.
    func testWhichErrorsCarryACause() throws {
        let quiet = try XCTUnwrap(try Self.vectors()["codes_not_reported"] as? [String])
        XCTAssertEqual(Set(quiet), ErrorRules.notReported)
        for code in ErrorCode.allCases {
            let e = TajweedError(code)
            XCTAssertEqual(e.cause == nil, quiet.contains(code.rawValue), code.rawValue)
        }
        XCTAssertNil(TajweedError(from: .sessionActive).cause)
        XCTAssertNil(TajweedError(from: .invalidArgument("x")).cause)
        XCTAssertNil(TajweedError(from: .cancelled).cause)
        let a = TajweedError(.downloadFailed, cause: ErrorCause(stage: "download", reason: "http", httpStatus: 503))
        let b = TajweedError(.downloadFailed, cause: ErrorCause(stage: "manifest", reason: "http", httpStatus: 503))
        XCTAssertEqual([a.code, a.message], [b.code, b.message])
        XCTAssertNotEqual(a, b, "the cause takes part in equality")
        XCTAssertEqual(a, TajweedError(.downloadFailed, cause: ErrorCause(stage: "download", reason: "http", httpStatus: 503)))
        // nothing of the internal cause that is not a token reaches the app: a system message in a name or a code, a
        // status that is no HTTP status, a reason that is not a token
        let raw = ErrorCause(stage: "download", reason: "Not a token!", httpStatus: 42, errorName: "The Internet connection appears to be offline.",
                             errorCode: "https://cdn.quranlab.ai/models/x")
        let made = try XCTUnwrap(TajweedError(.downloadFailed, cause: raw).cause)
        XCTAssertEqual(Self.dict(made), ["stage": "download", "reason": "other"] as NSDictionary)
        // needs: model, unless every file the call needs is on the device; by the lease route when the caller did not say
        XCTAssertEqual(TajweedError(.needsConnection, cause: ErrorCause(stage: "download", reason: "network"), onDevice: .partial).cause?.needs, "model")
        XCTAssertEqual(TajweedError(.needsConnection, cause: ErrorCause(stage: "lease", reason: "network"), onDevice: .complete).cause?.needs, "lease")
        XCTAssertEqual(TajweedError(from: .offline("needs_connection: no valid lease for this model on the device")).cause?.needs, "lease")
        XCTAssertEqual(TajweedError(.needsConnection).cause?.needs, "model")
        XCTAssertNil(TajweedError(.downloadFailed).cause?.needs, "needs is on needs_connection only")
    }
}
