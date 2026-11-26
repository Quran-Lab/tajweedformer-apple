import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5, contract section 40 (`sdk_4.0.0/ATTEST_40.md`, vectors `attest_40.json`): the checks a rejected answer
/// names, the attestation's retry policy, the renewal's time and the cause chain, replayed on the SDK's own code. Pure
/// logic: this file builds and runs on Linux too (scripts/linux_logic_tests.sh), and on the Mac in the package's suite.
final class Attest40VectorTests: XCTestCase {
    static func vectors(_ name: String = "attest_40.json") throws -> [String: Any] {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "vectors40", withExtension: nil, subdirectory: "Fixtures"))
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func cases(_ key: String, _ name: String = "attest_40.json") throws -> [[String: Any]] {
        try XCTUnwrap(try vectors(name)[key] as? [[String: Any]], key)
    }

    // MARK: 40.5 the checks

    /// The SDK's set is the contract's, token for token.
    func testTheClosedSetIsTheContracts() throws {
        let contract = try Self.cases("checks").compactMap { $0["check"] as? String }
        XCTAssertEqual(contract.count, 41)
        XCTAssertEqual(Set(contract), Set(AnswerCheck.all))
        for t in contract { XCTAssertNotNil(ErrorRules.token(t, ErrorRules.errorCodePattern), t) }
    }

    /// Every status and detail of a failed `qlc_lease_accept` to its check (the 4.0.2 report "lease, expired, -5" is
    /// `expired_on_arrival`); every `QLC_D_LEASE_*` the contract lists under a lease status names a check of its own.
    func testCoreAccept() throws {
        let cases = try Self.cases("core_accept")
        XCTAssertEqual(cases.count, 49)
        for c in cases {
            let status = try XCTUnwrap(c["status"] as? Int), detail = try XCTUnwrap(c["detail"] as? Int)
            XCTAssertEqual(AnswerCheck.coreAccept(status: status, detail: detail), c["check"] as? String, "\(status) \(detail)")
            XCTAssertTrue(AnswerCheck.isCheck(AnswerCheck.coreAccept(status: status, detail: detail)))
        }
        XCTAssertEqual(AnswerCheck.coreAccept(status: AnswerCheck.Core.needsConnection, detail: 8), "expired_on_arrival")
        let named = Set(cases.filter { ($0["status"] as? Int) == AnswerCheck.Core.lease }.compactMap { $0["detail"] as? Int })
        for d in named where d != 9 && d != 33 {
            XCTAssertNotNil(AnswerCheck.leaseDetails[d], "QLC_D_LEASE \(d) has a check of its own")
        }
    }

    func testLeaseAnswers() throws {
        let cases = try Self.cases("lease_answers")
        XCTAssertEqual(cases.count, 23)
        for c in cases {
            let body = Data(try XCTUnwrap(c["body"] as? String).utf8)
            XCTAssertEqual(LeaseAnswer.check(body), c["check"] as? String, c["name"] as? String ?? "?")
        }
    }

    func testChallengesAndTokens() throws {
        for c in try Self.cases("challenges") {
            XCTAssertEqual(AnswerCheck.challenge(Data(try XCTUnwrap(c["body"] as? String).utf8)).check, c["check"] as? String,
                           c["name"] as? String ?? "?")
        }
        for c in try Self.cases("tokens") {
            let body = Data(try XCTUnwrap(c["body"] as? String).utf8)
            XCTAssertEqual(AnswerCheck.tokenAnswer(body, installKeys: c["install_keys"] as? Bool ?? false), c["check"] as? String,
                           c["name"] as? String ?? "?")
        }
        XCTAssertEqual(AnswerCheck.challengeExpiry("c1.1795000300." + String(repeating: "A", count: 22) + "." + String(repeating: "b", count: 22)),
                       1_795_000_300)
    }

    /// The certificate's three checks in their order, on certificates signed here: its form, its signature, its install.
    func testCertificates() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let install = String(repeating: "a", count: 64)
        func cert(_ lines: [String], key: Curve25519.Signing.PrivateKey) throws -> String {
            let text = Data(("quranlab-install-cert 1\n" + lines.joined(separator: "\n") + "\n").utf8)
            return text.base64URL + "." + (try key.signature(for: text)).base64URL
        }
        let lines = ["app ios:a.b", "platform ios", "key k1", "install \(install)", "sign \(install)", "att apple", "hw 1", "iat 1",
                     "exp 2", "recheck 0", "batch -", "digest -"]
        let keys = [signer.publicKey.rawRepresentation]
        XCTAssertNil(InstallCertificate.check(try cert(lines, key: signer), trustedKeys: keys, installHash: install))
        XCTAssertEqual(InstallCertificate.check(try cert(Array(lines.dropLast()), key: signer), trustedKeys: keys, installHash: install), "cert_format")
        XCTAssertEqual(InstallCertificate.check("not.a.cert", trustedKeys: keys, installHash: install), "cert_format")
        XCTAssertEqual(InstallCertificate.check(try cert(lines, key: other), trustedKeys: keys, installHash: install), "cert_signature")
        XCTAssertEqual(InstallCertificate.check(try cert(lines, key: signer), trustedKeys: keys, installHash: String(repeating: "b", count: 64)),
                       "cert_install")
        XCTAssertEqual(InstallCertificate.parse(try cert(lines, key: signer), trustedKeys: keys)?.att, "apple")
    }

    /// The download code's words of an answer that was not the file, to their checks.
    func testFileWords() {
        XCTAssertEqual(AnswerCheck.file(fromWords: "a 200 of 999 bytes for a file of 1000"), "size")
        XCTAssertEqual(AnswerCheck.file(fromWords: "a 200 that runs past the file's 1000 bytes"), "size")
        XCTAssertEqual(AnswerCheck.file(fromWords: "a 206 without a Content-Range it can be held to"), "content_range")
        XCTAssertEqual(AnswerCheck.file(fromWords: "a 206 for another range or another file size than the one asked for (bytes 1-2/3)"), "range_mismatch")
        XCTAssertEqual(AnswerCheck.file(fromWords: HTTPWords.notItsRange + ": HTTP 200 bytes 0-1/2"), "range_mismatch")
        XCTAssertEqual(AnswerCheck.file(fromWords: "a 206 without a byte"), "no_bytes")
        XCTAssertEqual(AnswerCheck.file(fromWords: "the download server's answer brought no new byte of layers.zfw.qle"), "no_bytes")
        XCTAssertEqual(AnswerCheck.file(fromWords: "HTTP 204 is not a file"), "status")
        XCTAssertEqual(AnswerCheck.file(fromWords: "short range for layers.zfw.qle"), "short_range")
        XCTAssertNil(AnswerCheck.file(fromWords: "the connection was lost"))
        XCTAssertEqual(AnswerCheck.named(in: "attest response has no token (schema:token)"), "schema:token")
        XCTAssertNil(AnswerCheck.named(in: "the lease could not be renewed now (HTTP 503)"))
    }

    // MARK: 40.2 the policy

    static func failure(_ f: [String: Any]) -> AttestFailure? {
        switch f["kind"] as? String {
        case "no_answer": return .noAnswer
        case "timeout": return .timeout
        case "invalid_answer": return .invalidAnswer
        case "apple": return .apple(f["code"] as? String ?? "")
        case "http": return .http(status: f["status"] as? Int ?? 0, error: f["error"] as? String)
        default: return nil // Play and Key Attestation: Android's
        }
    }

    func testClassify() throws {
        var n = 0
        for c in try Self.cases("classify") {
            guard let f = Self.failure(try XCTUnwrap(c["failure"] as? [String: Any])) else { continue }
            XCTAssertEqual(AttestPolicy.classify(f).rawValue, c["class"] as? String, "\(f)")
            n += 1
        }
        XCTAssertEqual(n, 22, "the Apple and request cases")
    }

    func testBackground() throws {
        for c in try Self.cases("background") {
            let cls = try XCTUnwrap(AttestClass(rawValue: c["class"] as? String ?? ""))
            let got = AttestPolicy.background(cls, failures: c["failures"] as? Int ?? 0, draw: (c["draw"] as? NSNumber)?.doubleValue ?? 1,
                                              retryAfter: c["retry_after"] as? Int ?? 0, judged: c["judged"] as? Int ?? 0)
            XCTAssertEqual(got, c["wait"] as? Int, "\(c)")
        }
        let p = try XCTUnwrap(try Self.vectors()["policy"] as? [String: Any])
        XCTAssertEqual(p["in_call_tries"] as? Int, AttestPolicy.inCallTries)
        XCTAssertEqual((p["in_call_waits"] as? [NSNumber])?.map(\.doubleValue), AttestPolicy.inCallWaits)
        XCTAssertEqual((p["in_call_wall"] as? NSNumber)?.doubleValue, AttestPolicy.inCallWall)
        XCTAssertEqual(p["background_base"] as? Int, AttestPolicy.backgroundBase)
        XCTAssertEqual(p["background_cap"] as? Int, AttestPolicy.backgroundCap)
        XCTAssertEqual(p["apple_floor"] as? Int, AttestPolicy.appleFloor)
        XCTAssertEqual(p["path_min_gap"] as? Int, Int(AttestPolicy.pathMinGap))
        XCTAssertEqual(p["hold_base"] as? Int, AttestPolicy.holdBase)
        XCTAssertEqual(p["hold_cap"] as? Int, AttestPolicy.holdCap)
        XCTAssertEqual(p["named_after"] as? Int, Int(AttestPolicy.namedAfter))
        XCTAssertEqual(p["named_min_tries"] as? Int, AttestPolicy.namedMinTries)
    }

    func testInCall() throws {
        let cases = try Self.cases("in_call")
        XCTAssertEqual(cases.count, 13)
        for c in cases {
            let failures = try XCTUnwrap(c["failures"] as? [Any]).map { ($0 as? String).flatMap(AttestClass.init(rawValue:)) }
            let draws = (c["draws"] as? [NSNumber] ?? []).map(\.doubleValue)
            let back = (c["path_back_at"] as? NSNumber)?.doubleValue
            let took = (c["elapsed"] as? [NSNumber])?.map(\.doubleValue)
            let got = AttestPolicy.inCall(failures, draws: draws, pathBackAt: back, elapsed: took)
            XCTAssertEqual(got.starts, (c["starts"] as? [NSNumber] ?? []).map(\.doubleValue), c["name"] as? String ?? "?")
            XCTAssertEqual(got.outcome, c["outcome"] as? String, c["name"] as? String ?? "?")
        }
    }

    func testNamed() throws {
        var n = 0
        for c in try Self.cases("named") where c["platform"] as? String == "ios" {
            let history = try XCTUnwrap(c["history"] as? [[Any]]).map { h in
                AttestState.Failure(at: (h[0] as? NSNumber)?.int64Value ?? 0, cls: AttestClass(rawValue: h[1] as? String ?? "") ?? .transient,
                                    answered: h[2] as? Bool ?? false, service: h[3] as? String == "apple")
            }
            XCTAssertEqual(AttestPolicy.named(history), c["unattested"] as? String, c["name"] as? String ?? "?")
            n += 1
        }
        XCTAssertEqual(n, 4)
    }

    func testRenew() throws {
        for c in try Self.cases("renew") {
            let iat = (c["iat"] as? NSNumber)?.int64Value
            let due = AttestPolicy.renewDue(iat: iat, exp: (c["exp"] as? NSNumber)?.int64Value ?? 0,
                                            refreshAfter: (c["refresh_after"] as? NSNumber)?.int64Value ?? 0)
            XCTAssertEqual(due, (c["due"] as? NSNumber)?.int64Value, c["name"] as? String ?? "?")
        }
    }

    /// 40.2 item 1: the order by what the lease needs.
    func testPlans() throws {
        let cases = try Self.cases("plans")
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let required = try XCTUnwrap(c["attest_required"] as? Bool), how = try XCTUnwrap(c["in_call"] as? String)
            let got = AttestPolicy.plan(required: required, inCall: how)
            XCTAssertEqual(got.certificate, c["certificate"] as? String, "\(required) \(how)")
            XCTAssertEqual(got.owed, c["owed"] as? Bool, "\(required) \(how)")
            // the tries inside the call: item 3's where the lease needs attestation, one elsewhere
            XCTAssertEqual(c["in_call_tries"] as? String, required ? "patient" : "one")
        }
    }

    /// 40.2 item 10: an upgrade never loses the lease in use.
    func testUpgrades() throws {
        let cases = try Self.cases("upgrades")
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            let got = AttestPolicy.upgradeOutcome(modelOpen: c["model_open"] as? Bool ?? false, attestation: c["attestation"] as? String ?? "",
                                                  lease: c["lease"] as? String)
            let name = c["name"] as? String ?? "?"
            XCTAssertEqual(got.inForce, c["in_force"] as? String, name)
            XCTAssertEqual(got.key, c["key"] as? String, name)
            XCTAssertEqual(got.owed, c["owed"] as? Bool, name)
            XCTAssertEqual(got.nextKept, c["next_kept"] as? Bool, name)
        }
    }

    // MARK: 40.6 the chain

    func testChains() throws {
        for c in try Self.cases("chains") {
            let hops = try XCTUnwrap(c["hops"] as? [[String: Any]]).compactMap { h in
                CauseHop.made(stage: h["stage"] as? String ?? "", reason: h["reason"] as? String ?? "", hostRole: h["host_role"] as? String,
                              hostName: h["host"] as? String, httpStatus: h["http_status"] as? Int, errorName: h["error_name"] as? String,
                              errorCode: h["error_code"] as? String)
            }
            let sent = CauseChain.last(hops).map { $0.map(\.wire) }
            let data = try JSONEncoder().encode(sent)
            let got = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]]
            let want = c["chain"] as? [[String: Any]]
            XCTAssertEqual(got.map { $0.map { NSDictionary(dictionary: $0) } }, want.map { $0.map { NSDictionary(dictionary: $0) } },
                           c["name"] as? String ?? "?")
        }
    }
}
