import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 40 (`sdk_4.0.0/ATTEST_40.md` 40.2, 40.5, 40.6): the cause chain an operation records and
/// the report carries, the owed attestation's state, and the codes of `invalid_answer`. Pure logic: this file builds and
/// runs on Linux too (scripts/linux_logic_tests.sh), and on the Mac in the package's suite.
final class CauseChainReportTests: XCTestCase {
    static func hop(_ code: String, host: String = "api.quranlab.ai", status: Int? = 200) -> CauseHop {
        CauseHop.made(stage: "lease", reason: "invalid_answer", hostRole: "api", hostName: host, httpStatus: status, errorCode: code)!
    }

    /// An operation's box keeps its hops; a cause made in it carries the last 8; outside one nothing is kept.
    func testTheOperationsChain() async {
        CauseChain.add(Self.hop("not_json"))
        XCTAssertNil(CauseChain.current, "outside an operation nothing is kept")
        let got = await CauseChain.scope { () -> [CauseHop]? in
            for i in 0..<10 { CauseChain.add(Self.hop("lease_detail:\(i)")) }
            // an operation inside another is the outer one's
            await CauseChain.scope { CauseChain.add(Self.hop("expired_on_arrival", host: "api-b.tajweedformer.com")) }
            return CauseChain.current
        }
        XCTAssertEqual(got?.count, 8)
        XCTAssertEqual(got?.first?.errorCode, "lease_detail:3")
        XCTAssertEqual(got?.last?.errorCode, "expired_on_arrival")
        XCTAssertEqual(got?.last?.host, "standby")
        XCTAssertEqual(got?.first?.host, "first")
        XCTAssertNil(CauseChain.current)
    }

    /// A hop never carries a host name or a value that fails its pattern; a hop whose reason is not a token is none.
    func testAHopIsTokensOnly() throws {
        let h = try XCTUnwrap(CauseHop.made(stage: "lease", reason: "network", hostRole: "api", hostName: "api-g.tajweedformer.com",
                                            errorName: "NSURLErrorDomain", errorCode: "-1009"))
        XCTAssertEqual(h.host, "standby")
        let wire = String(data: try JSONEncoder().encode(h.wire), encoding: .utf8) ?? ""
        XCTAssertFalse(wire.contains("tajweedformer"), wire)
        XCTAssertNil(CauseHop.made(stage: "lease", reason: "Not a token"))
        XCTAssertNil(CauseHop.made(stage: "lease", reason: "http", errorCode: String(repeating: "x", count: 33))?.errorCode)
        XCTAssertNil(CauseHop.made(stage: "attest", reason: "attestation_failed", hostRole: "cdn", hostName: "x.quranlab.ai")?.host,
                     "no role, no host")
        XCTAssertEqual(CauseHop.made(stage: "lease", reason: "http", httpStatus: 99)?.httpStatus, nil)
        XCTAssertEqual(h.diagnosisJSON,
                       "{\"stage\": \"lease\", \"hostRole\": \"api\", \"host\": \"standby\", \"reason\": \"network\", \"errorName\": \"NSURLErrorDomain\", \"errorCode\": \"-1009\"}")
    }

    /// The report book keeps the chain as an occurrence's field: a later occurrence of the signature that day replaces it
    /// (24.5), and it never changes the signature or the cause's equality.
    func testTheBookKeepsTheLastOccurrencesChain() {
        var book = ErrorReportBook()
        var c = ErrorCause(stage: "lease", reason: "invalid_answer", httpStatus: 200, errorCode: "expired_on_arrival", hostRole: "api",
                           fallback: true)
        c.chain = [Self.hop("expired_on_arrival"), Self.hop("expired_on_arrival", host: "api-b.tajweedformer.com")]
        XCTAssertTrue(book.occur(day: "2026-11-25", cause: c, code: "download_failed", firstLaunch: false))
        XCTAssertEqual(book.queue.first?.chain?.count, 2)
        var again = c
        again.chain = [Self.hop("signature")]
        XCTAssertEqual(again, c, "the chain takes no part in a cause's equality")
        XCTAssertFalse(book.occur(day: "2026-11-25", cause: again, code: "download_failed", firstLaunch: false))
        XCTAssertEqual(book.queue.count, 1)
        XCTAssertEqual(book.queue.first?.count, 2)
        XCTAssertEqual(book.queue.first?.chain, [Self.hop("signature")])
        // kept across launches (the book is JSON in the SDK's folder)
        let data = try? JSONEncoder().encode(book)
        let back = data.flatMap { try? JSONDecoder().decode(ErrorReportBook.self, from: $0) }
        XCTAssertEqual(back, book)
        // a book an earlier SDK wrote (no chain) reads back
        let old = #"{"queue":[{"day":"2026-11-24","sig":"x","stage":"lease","reason":"expired","code":"needs_connection","count":1,"firstReport":true,"firstLaunch":false}],"days":{},"reported":[]}"#
        XCTAssertNil(try? JSONDecoder().decode(ErrorReportBook.self, from: Data(old.utf8)).queue.first?.chain ?? nil)
        XCTAssertNotNil(try? JSONDecoder().decode(ErrorReportBook.self, from: Data(old.utf8)))
    }

    /// `errors_40.json`: the codes of every case, the appended `invalid_answer` ones among them (rule 2: an answer is never
    /// needs_connection), and the chain bodies' hops as this SDK writes them.
    func testTheCodesAndTheChainBodies() throws {
        let v = try Attest40VectorTests.vectors("errors_40.json")
        let codes = try XCTUnwrap(v["codes"] as? [[String: Any]])
        XCTAssertEqual(codes.count, 81)
        for c in codes {
            let on = ErrorRules.OnDevice(rawValue: c["on_device"] as? String ?? "none") ?? .nothing
            let got = ErrorRules.code(stage: c["stage"] as? String ?? "", reason: c["reason"] as? String ?? "",
                                      status: c["http_status"] as? Int, onDevice: on, errorCode: c["error_code"] as? String)
            XCTAssertEqual(got, c["code"] as? String, "\(c)")
        }
        let bodies = try XCTUnwrap(v["bodies"] as? [[String: Any]])
        var chains = 0
        for b in bodies {
            guard let e = (b["body"] as? [String: Any])?["error"] as? [String: Any], let chain = e["chain"] as? [[String: Any]],
                  b["accepted"] as? Bool == true else { continue }
            chains += 1
            for h in chain {
                // the same hop made by this SDK writes the same object
                let made = try XCTUnwrap(CauseHop.made(stage: h["stage"] as? String ?? "", reason: h["reason"] as? String ?? "",
                                                       hostRole: h["host_role"] as? String,
                                                       hostName: (h["host"] as? String).map { $0 == "first" ? "api.quranlab.ai" : "api-b.tajweedformer.com" },
                                                       httpStatus: h["http_status"] as? Int, errorName: h["error_name"] as? String,
                                                       errorCode: h["error_code"] as? String))
                let back = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(made.wire)) as? [String: Any]
                XCTAssertEqual(back.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: h))
            }
        }
        XCTAssertEqual(chains, 4)
    }

    // MARK: 40.2 the owed attestation's state

    func testTheOwedAttestationsRow() {
        var s = AttestState()
        XCTAssertTrue(s.due(0))
        s.failed(.transient, at: 1000, answered: false, service: false, draw: 1)
        XCTAssertTrue(s.owed)
        XCTAssertEqual(s.nextTry, 1030)
        s.failed(.transient, at: 1030, answered: false, service: false, draw: 1)
        XCTAssertEqual(s.nextTry, 1090)
        s.failed(.transientApple, at: 1090, answered: true, service: true, draw: 0.5)
        XCTAssertEqual(s.nextTry, 1090 + 60, "Apple's floor")
        XCTAssertFalse(s.due(1100))
        // a clock moved back: a next try more than 6 hours ahead is now
        var back = s
        back.nextTry = 1000 + 30_000
        XCTAssertEqual(back.readBack(now: 1000).nextTry, 1000)
        // the object can be sent again only while its challenge is fresh and for the key it binds
        s.keyID = "k"
        s.object = Data([1])
        s.boundHash = "h"
        s.challenge = "c1.0000002000." + String(repeating: "A", count: 22) + "." + String(repeating: "b", count: 22)
        XCTAssertTrue(s.resendable(now: 1900, installHash: "h"))
        XCTAssertFalse(s.resendable(now: 1980, installHash: "h"), "less than 30 s left")
        XCTAssertFalse(s.resendable(now: 1900, installHash: "other"))
        s.forgetKey()
        XCTAssertNil(s.keyID)
        XCTAssertFalse(s.resendable(now: 1900, installHash: "h"))
        // judged: 4.0.2's hold, doubling
        s.failed(.judged, at: 2000, answered: true, service: false, draw: 1)
        XCTAssertEqual(s.nextTry, 2000 + 3600)
        s.failed(.judged, at: 6000, answered: true, service: false, draw: 1)
        XCTAssertEqual(s.nextTry, 6000 + 7200)
        s.attested()
        XCTAssertEqual(s, AttestState())
    }

    /// 40.3: App Attest unavailable for a day of tries while Quran Lab answered names `apple_unavailable`; offline it never does.
    func testTheNamedPathComesFromTheRow() {
        var s = AttestState()
        for i in 0..<7 { s.failed(.transientApple, at: Int64(i) * 4 * 3600, answered: true, service: true, draw: 1) }
        XCTAssertEqual(s.unattested, "apple_unavailable")
        var offline = AttestState()
        for i in 0..<7 { offline.failed(.transientApple, at: Int64(i) * 4 * 3600, answered: false, service: true, draw: 1) }
        XCTAssertNil(offline.unattested)
    }

    /// 40.2 item 3 on the call's own clock: three tries, then the background; a new key at once; the wall.
    func testTheTriesInsideACall() {
        var p = AttestPolicy.InCall()
        XCTAssertEqual(p.after(.transient, elapsed: 0.25, draw: 1), .again(after: 1, maxWait: 19.75))
        XCTAssertEqual(p.after(.transient, elapsed: 1.5, draw: 1.5), .again(after: 4.5, maxWait: 18.5))
        XCTAssertEqual(p.after(.transient, elapsed: 6.2, draw: 1), .stop("pending"))
        var k = AttestPolicy.InCall()
        XCTAssertEqual(k.after(.newKey, elapsed: 0, draw: 1), .now)
        XCTAssertEqual(k.after(.newKey, elapsed: 0, draw: 1), .stop("judged"))
        var w = AttestPolicy.InCall()
        XCTAssertEqual(w.after(.transient, elapsed: 21, draw: 1), .stop("pending"))
        XCTAssertEqual(AttestPolicy.appleCodeName(4), "serverUnavailable")
        XCTAssertEqual(AttestPolicy.appleCodeName(3), "invalidKey")
        XCTAssertEqual(AttestPolicy.appleCodeName(99), "unknownSystemFailure")
    }
}
