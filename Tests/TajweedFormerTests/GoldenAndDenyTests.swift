import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The golden test in both directions with the signed tolerance, the persisted promotion (golden again only when the
/// program changed or is gone), `accel_deny`, and the `demoted` counter.
final class GoldenAndDenyTests: XCTestCase {
    // MARK: golden_tolerance in the signed manifest

    func manifest(tolerance: [String: Any]?) throws -> (ModelManifest, Data) {
        var o: [String: Any] = ["format": 3, "model_id": "v4.0", "family": "tajweedformer", "revision": "r", "min_sdk_version": "2.0.1",
                                "engine_format": 3, "coreml_format": 9, "tokens": "tokens.txt", "tokens_sha256": String(repeating: "a", count: 64),
                                "default_context": "c16_l64", "contexts": ["c16_l64"],
                                "files": [["path": "tokens.txt", "size": 3, "sha256": String(repeating: "a", count: 64), "platforms": "*",
                                           "soc": "*", "context": "*", "role": "tokens", "need": "required", "encoding": "identity"]]]
        if let tolerance { o["golden_tolerance"] = tolerance }
        let data = try JSONSerialization.data(withJSONObject: o)
        return (try ModelManifest.parse(data), data)
    }

    func signed(_ m: ModelManifest, key: Curve25519.Signing.PrivateKey, lines: Bool) throws -> ModelManifest {
        var s = m
        s.signature = try key.signature(for: m.signedMessage(tolerance: lines)).base64EncodedString()
        return s
    }

    func testTheToleranceIsTrustedOnlyWhenTheSignatureCoversIt() throws {
        let key = Curve25519.Signing.PrivateKey()
        let v = ManifestVerifier(trustedKeys: [key.publicKey.rawRepresentation], requireSignature: true)
        let tol: [String: Any] = ["coreml": ["token_diffs": 0, "site_flag_diffs": 1, "word_flag_diffs": 1],
                                  "npu:exynos2500:c16_l64": ["token_diffs": 0, "site_flag_diffs": 1, "word_flag_diffs": 1]]
        let (m, _) = try manifest(tolerance: tol)
        XCTAssertEqual(m.tolerance(build: "coreml"), .init(tokenDiffs: 0, siteFlagDiffs: 1, wordFlagDiffs: 1))
        XCTAssertEqual(m.tolerance(build: "coreml-compact"), .exact, "a build not listed is exact")
        let text = String(decoding: m.signedMessage, as: UTF8.self)
        XCTAssertTrue(text.contains("contexts c16_l64\ngolden_tolerance coreml 0 1 1\ngolden_tolerance npu:exynos2500:c16_l64 0 1 1\nfile "), text)
        // signed with the lines: kept
        let good = try v.verifySignature(try signed(m, key: key, lines: true), required: true)
        XCTAssertEqual(good.tolerance(build: "coreml").siteFlagDiffs, 1)
        // signed without them (a writer that does not cover the field): verified, the tolerance ignored (exact)
        let unsigned = try v.verifySignature(try signed(m, key: key, lines: false), required: true)
        XCTAssertEqual(unsigned.tolerance(build: "coreml"), .exact)
        // a tolerance loosened after signing: refused
        var loose = try signed(m, key: key, lines: true)
        loose.goldenTolerance["coreml"] = .init(tokenDiffs: 9, siteFlagDiffs: 9, wordFlagDiffs: 9)
        XCTAssertThrowsError(try v.verifySignature(loose, required: true))
        // without the field: today's signed text, unchanged
        let (plain, _) = try manifest(tolerance: nil)
        XCTAssertFalse(String(decoding: plain.signedMessage, as: UTF8.self).contains("golden_tolerance"))
        XCTAssertNoThrow(try v.verifySignature(try signed(plain, key: key, lines: true), required: true))
        // it survives the folder's manifest.json
        let again = try ModelManifest.parse(good.jsonData())
        XCTAssertNoThrow(try v.verifySignature(again, required: true))
        XCTAssertEqual(again.tolerance(build: "coreml").wordFlagDiffs, 1)
    }

    func testAMalformedToleranceIsExactForThatBuild() throws {
        let (m, _) = try manifest(tolerance: ["coreml": ["token_diffs": -1, "site_flag_diffs": 1, "word_flag_diffs": 1],
                                              "coreml-compact": ["token_diffs": 0.5, "site_flag_diffs": 1, "word_flag_diffs": 1],
                                              "npu:x:c16_l64": ["token_diffs": 0, "site_flag_diffs": true, "word_flag_diffs": 1],
                                              "npu:y:c16_l64": ["token_diffs": 0, "site_flag_diffs": 2],
                                              "npu:z:c16_l64": ["token_diffs": 0, "site_flag_diffs": 2, "word_flag_diffs": 3]])
        XCTAssertEqual(m.tolerance(build: "coreml"), .exact)
        XCTAssertEqual(m.tolerance(build: "coreml-compact"), .exact)
        XCTAssertEqual(m.tolerance(build: "npu:x:c16_l64"), .exact)
        XCTAssertEqual(m.tolerance(build: "npu:y:c16_l64"), .exact)
        XCTAssertEqual(m.tolerance(build: "npu:z:c16_l64"), .init(tokenDiffs: 0, siteFlagDiffs: 2, wordFlagDiffs: 3))
        XCTAssertNoThrow(try manifest(tolerance: ["coreml": "loose"]), "the CPU path never depends on it")
    }

    // MARK: the golden verdict in both directions

    static let expected = SelfTestSet.Expected(tokens: [4, 5, 6], flaggedSites: [], flaggedWords: [])
    static let plantedExpected = SelfTestSet.Expected(tokens: [4, 7, 6], flaggedSites: ["5|vowel_sub", "6|cons_sub"], flaggedWords: [1])

    func clean(_ id: String, acc: [Int] = [4, 5, 6], sites: Set<String> = [], words: Set<Int> = []) -> GoldenJudge.Clip {
        GoldenJudge.Clip(id: id, planted: false, plantedSite: nil, expected: Self.expected, cpuTokens: [4, 5, 6], accTokens: acc,
                         cpuSites: [], accSites: sites, cpuWords: [], accWords: words)
    }

    func planted(acc sites: Set<String>, words: Set<Int> = [1], tokens: [Int] = [4, 9, 6]) -> GoldenJudge.Clip {
        GoldenJudge.Clip(id: "Husary_112001_vsub2", planted: true, plantedSite: "5|vowel_sub", expected: Self.plantedExpected,
                         cpuTokens: [4, 7, 6], accTokens: tokens, cpuSites: ["5|vowel_sub", "6|cons_sub"], accSites: sites,
                         cpuWords: [1], accWords: words)
    }

    func testIdenticalDecisionsPassExact() {
        let r = GoldenJudge.evaluate([clean("a"), clean("b"), planted(acc: ["5|vowel_sub", "6|cons_sub"])], tolerance: .exact)
        XCTAssertNil(r.failure)
        XCTAssertTrue(r.totals.isZero, "a planted clip's tokens are not counted")
    }

    func testAnExtraOrAMissedFlagIsADifferenceEitherWay() {
        let extra = GoldenJudge.evaluate([clean("a", sites: ["3|vowel_sub"])], tolerance: .exact)
        XCTAssertEqual(extra.failure?.reason, .goldenMismatch)
        XCTAssertEqual(extra.totals.sitesDiffer, 1)
        let missed = GoldenJudge.evaluate([planted(acc: ["5|vowel_sub"])], tolerance: .exact)
        XCTAssertEqual(missed.failure?.reason, .goldenMismatch)
        XCTAssertEqual(missed.failure?.clip, "Husary_112001_vsub2")
        XCTAssertEqual(missed.totals.sitesDiffer, 1)
    }

    func testWithinTheToleranceItPassesBeyondItFailsWithTheCounts() {
        let t = ModelManifest.GoldenTolerance(tokenDiffs: 0, siteFlagDiffs: 1, wordFlagDiffs: 1)
        let one = GoldenJudge.evaluate([clean("a", words: [2]), clean("b")], tolerance: t)
        XCTAssertNil(one.failure)
        XCTAssertEqual(one.totals.wordsDiffer, 1)
        let two = GoldenJudge.evaluate([clean("a", words: [2]), clean("b", words: [0])], tolerance: t)
        XCTAssertEqual(two.failure?.reason, .goldenMismatch)
        XCTAssertEqual(two.failure?.divergence?.wordsDiffer, 2)
        XCTAssertEqual(two.failure?.clip, "a")
        let token = GoldenJudge.evaluate([clean("a", acc: [4, 6])], tolerance: t)
        XCTAssertEqual(token.failure?.divergence?.tokensDiffer, 1, "tokens 0 means exact on the clean clips")
    }

    func testAMissedPlantedMistakeAlwaysFails() {
        let wide = ModelManifest.GoldenTolerance(tokenDiffs: 100, siteFlagDiffs: 100, wordFlagDiffs: 100)
        let r = GoldenJudge.evaluate([planted(acc: ["6|cons_sub"])], tolerance: wide)
        XCTAssertEqual(r.failure?.reason, .goldenMismatch)
        XCTAssertTrue(r.failure!.detail.contains("planted mistake"), r.failure!.detail)
    }

    func testTheCPUMustEqualTheExpectedFile() {
        var c = clean("a")
        c.cpuTokens = [4, 5]
        c.accTokens = [4, 5]
        let r = GoldenJudge.evaluate([c], tolerance: .init(tokenDiffs: 5, siteFlagDiffs: 5, wordFlagDiffs: 5))
        XCTAssertEqual(r.failure?.reason, .cpuMismatch)
    }

    func testThePlantedSiteIsReadFromTheSet() throws {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "selftest_07f", withExtension: nil, subdirectory: "Fixtures"))
        let root = Fixtures.storage()
        let dir = root.appendingPathComponent("selftest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ["selftest.json", "expected_c16_l64.json"] { try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: dir.appendingPathComponent(f)) }
        let meta = try XCTUnwrap(JSONValue(data: Data(contentsOf: dir.appendingPathComponent("selftest.json"))))
        for c in meta["clips"]?.array ?? [] { try Data(count: 3200).write(to: dir.appendingPathComponent(c["file"]!.string!)) }
        let set = try XCTUnwrap(SelfTestSet.load(root, context: "c16_l64"))
        XCTAssertEqual(set.clips.last?.plantedSite, "5|vowel_sub")
        XCTAssertEqual(set.clips.filter { $0.plantedSite != nil }.count, 1)
    }

    // MARK: persistence

    func testAPromotedKeyIsGoldenTestedAgainOnlyWhenItsProgramChanged() async {
        let h = PromotionTests.Harness()
        let program = Locked<String?>("sha-1")
        func stages() -> AcceleratorController.Stages {
            var s = h.stages()
            s.fingerprint = { program.withLock { $0 } }
            return s
        }
        let c = h.controller()
        await c.run(stages())
        XCTAssertEqual(c.record?.programSHA256, "sha-1")
        h.resetCalls()
        let same = h.controller(launch: "L2")
        await same.run(stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["compile", "warmup"], "the same program: loaded and warmed, no golden test")
        h.resetCalls()
        program.withLock { $0 = "sha-2" }
        let changed = h.controller(launch: "L3")
        await changed.run(stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"], "a changed program is tested again")
        XCTAssertEqual(changed.state, .ready)
        XCTAssertEqual(changed.record?.failures, 0, "not a failure")
        h.resetCalls()
        program.withLock { $0 = "gone" }
        let gone = h.controller(launch: "L4")
        await gone.run(stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"], "a missing program is fetched and tested again")
    }

    // MARK: accel_deny

    static let device: [String: String] = ["platform": "ios", "os_version": "26.1", "os_build": "23B85", "device_class": "phone",
                                           "device_model": "iPhone16,2", "chip": "a17pro", "model_revision": "v4.0+abc", "sdk_version": "2.0.1"]

    func config(_ rules: Any) throws -> RemoteConfig {
        let o: [String: Any] = ["v": 1, "app": "ios:x", "channel": "stable", "issued_at": 1, "expires_at": 4_000_000_000, "models": [:],
                                "denylist": [], "flags": ["analytics": true, "issues": true, "contributions": true], "accel_deny": rules]
        return try JSONDecoder().decode(RemoteConfig.self, from: JSONSerialization.data(withJSONObject: o))
    }

    func rule(_ extra: [String: Any] = [:]) -> [String: Any] {
        ["platform": "ios", "os_version": "26.*", "device_class": "*", "accelerator": "ane", "model_revision": "*", "sdk_version": "2.0.*",
         "reason": "fp16 overflow on A17"].merging(extra) { _, b in b }
    }

    func testEachFieldMatchesOrNot() throws {
        XCTAssertNotNil(try config([rule()]).accelDenyRule(values: Self.device, kind: "ane"))
        let fields: [(String, String, String)] = [
            ("platform", "ios", "macos"), ("os_version", "26.1", "25.*"), ("os_build", "23B*", "22A*"), ("device_class", "phone", "tablet"),
            ("device_model", "iPhone16,*", "iPhone15,*"), ("chip", "a17pro", "m2"), ("model_revision", "v4.0+*", "v4.1*"),
            ("sdk_version", "2.0.1", "2.0.0"),
        ]
        for (f, yes, no) in fields {
            XCTAssertNotNil(try config([rule([f: yes])]).accelDenyRule(values: Self.device, kind: "ane"), "\(f) = \(yes)")
            XCTAssertNil(try config([rule([f: no])]).accelDenyRule(values: Self.device, kind: "ane"), "\(f) = \(no)")
        }
        XCTAssertNil(try config([rule(["delegate": "litert/*"])]).accelDenyRule(values: Self.device, kind: "ane"), "Apple has no delegate")
        XCTAssertNotNil(try config([rule(["delegate": "*"])]).accelDenyRule(values: Self.device, kind: "ane"))
    }

    func testTheAcceleratorKind() throws {
        XCTAssertNil(try config([rule(["accelerator": "gpu"])]).accelDenyRule(values: Self.device, kind: "ane"), "a gpu rule leaves the ANE alone")
        XCTAssertNil(try config([rule(["accelerator": "npu"])]).accelDenyRule(values: Self.device, kind: "ane"))
        XCTAssertNotNil(try config([rule(["accelerator": "*"])]).accelDenyRule(values: Self.device, kind: "ane"))
        XCTAssertNotNil(try config([rule(["accelerator": "npu"])]).accelDenyRule(values: Self.device, kind: "npu"))
    }

    func testUntilAndMalformedRules() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(try config([rule(["until": 1_700_000_000])]).accelDenyRule(values: Self.device, kind: "ane", now: now), "past: ignored")
        XCTAssertNotNil(try config([rule(["until": 1_900_000_000])]).accelDenyRule(values: Self.device, kind: "ane", now: now))
        var noPlatform = rule()
        noPlatform["platform"] = nil
        let malformed: [Any] = [noPlatform, rule(["os_build": 7]), rule(["until": "soon"]), rule(["reason": 3]), "not a rule", rule(["chip": ""])]
        let c = try config(malformed + [rule(["device_model": "iPhone16,2"])])
        XCTAssertEqual(c.accelDenyRules.count, 1, "malformed rules are skipped one by one")
        XCTAssertNotNil(c.accelDenyRule(values: Self.device, kind: "ane"))
        XCTAssertEqual(try config("not a list").accelDenyRules.count, 0, "the config itself still parses")
    }

    /// A rule that arrives while a session runs on the promoted build: that session stays on it; the next one starts on
    /// the CPU; counted once as reasons.denylist; no incident report and no `demoted`.
    func testADenyRuleTakesAPromotedBuildBackAtTheNextBoundary() async {
        let h = PromotionTests.Harness()
        let c = h.controller()
        await c.run(h.stages())
        let running = c.leaseForSession()
        XCTAssertNotNil(running)
        h.denied.withLock { $0 = "accel_deny: fp16 overflow" }
        XCTAssertFalse(running!.abandoned, "the session in progress keeps its accelerator")
        c.endLease()
        XCTAssertNil(c.leaseForSession(), "the next session starts on the CPU")
        XCTAssertNil(c.leaseForSession())
        XCTAssertEqual(h.incidents.withLock { $0 }.count, 0)
        let store = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "2.0.1", appVersion: "1", deviceClass: "phone", soc: nil, osMajor: 26, ramTier: "8gb"))
        for p in h.promotions { store.record(.promotion(p)) }
        let e = AnalyticsStore.promotions(store.pending.first!.promotions).first!
        XCTAssertEqual(e["reasons"] as? [String: Int], ["denylist": 1])
        XCTAssertNil(e["demoted"])
    }

    func testAFailoverCountsDemoted() async {
        let h = PromotionTests.Harness()
        let c = h.controller()
        await c.run(h.stages())
        c.failedOver(TakeRunner.Failover(cause: .nonFinite, detail: "NaN", chunk: 3, replayFrom: 0, stallMs: 40, cold: true, elapsedMs: nil,
                                         deadlineMs: 300, errorDomain: nil, errorCode: nil))
        let store = AnalyticsStore(storage: Fixtures.storage(), enabled: true,
                                   context: .init(platform: "ios", sdkVersion: "2.0.1", appVersion: "1", deviceClass: "phone", soc: nil, osMajor: 26, ramTier: "8gb"))
        for p in h.promotions { store.record(.promotion(p)) }
        let e = AnalyticsStore.promotions(store.pending.first!.promotions).first!
        XCTAssertEqual(e["demoted"] as? Int, 1)
        XCTAssertEqual(e["failovers"] as? Int, 1)
        XCTAssertEqual(e["promoted"] as? Int, 1)
    }
}
