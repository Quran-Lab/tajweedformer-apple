import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The raw golden test: its signed tolerance (`golden_raw_tolerance`), the measures and the verdict by the shared
/// vectors, what an incident reports; then the persisted promotion (golden again only when the program changed or is
/// gone), `accel_deny`, and the `demoted` counter.
final class GoldenAndDenyTests: XCTestCase {
    // MARK: golden_raw_tolerance in the signed manifest

    func manifest(raw: Any?, legacy: [String: Any]? = nil) throws -> ModelManifest {
        var o: [String: Any] = ["format": 3, "model_id": "v4.0", "family": "tajweedformer", "revision": "r", "version": "4.0.0",
                                "min_sdk_version": "3.0.0", "engine_format": 3, "coreml_format": 9, "tokens": "tokens.txt",
                                "tokens_sha256": String(repeating: "a", count: 64), "default_context": "c16_l64", "contexts": ["c16_l64"],
                                "files": [["path": "tokens.txt", "size": 3, "sha256": String(repeating: "a", count: 64), "platforms": "*",
                                           "soc": "*", "context": "*", "role": "tokens", "need": "required", "encoding": "identity"]]]
        if let raw { o["golden_raw_tolerance"] = raw }
        if let legacy { o["golden_tolerance"] = legacy }
        return try ModelManifest.parse(try JSONSerialization.data(withJSONObject: o))
    }

    func signed(_ m: ModelManifest, key: Curve25519.Signing.PrivateKey, tolerance: Bool = true, raw: Bool = true) throws -> ModelManifest {
        var s = m
        s.signature = try key.signature(for: Data(m.signedText(tolerance: tolerance, raw: raw).utf8)).base64EncodedString()
        return s
    }

    static var coreml: [String: Any] { ["log_probs": ["token_edits": 0, "lp_mean": 0.05, "lp_p99": 1.5],
                                        "inter1_log_probs": ["token_edits": 1, "lp_mean": 0.1, "lp_p99": 2], "attr": ["p_mean": 0.02]] }

    func testTheRawToleranceIsTrustedOnlyWhenTheSignatureCoversIt() throws {
        let key = Curve25519.Signing.PrivateKey()
        let v = ManifestVerifier(trustedKeys: [key.publicKey.rawRepresentation], requireSignature: true)
        let npu: [String: Any] = ["log_probs": ["token_edits": 0, "lp_mean": 0.08, "lp_p99": 2.0]]
        let m = try manifest(raw: ["coreml": Self.coreml, "npu:exynos2500:c16_l64": npu] as [String: Any])
        XCTAssertNil(m.rawTolerance(build: "coreml"), "nothing is trusted before the signature is checked")
        let text = m.signedText()
        XCTAssertTrue(text.contains("contexts c16_l64\ngolden_raw coreml attr p_mean=0.02\n"
                                    + "golden_raw coreml inter1_log_probs token_edits=1 lp_mean=0.1 lp_p99=2.0\n"
                                    + "golden_raw coreml log_probs token_edits=0 lp_mean=0.05 lp_p99=1.5\n"
                                    + "golden_raw npu:exynos2500:c16_l64 log_probs token_edits=0 lp_mean=0.08 lp_p99=2.0\nfile "), text)
        XCTAssertTrue(text.contains("revision r\nversion 4.0.0\nmin_sdk_version 3.0.0\n"), "the version line follows the revision")
        // signed with the lines: kept
        let good = try v.verifySignature(try signed(m, key: key), required: true)
        XCTAssertTrue(good.goldenRawSigned)
        let t = try XCTUnwrap(good.rawTolerance(build: "coreml"))
        XCTAssertEqual(t.heads["log_probs"], GoldenRawTolerance.Head(tokenEdits: 0, lpMean: 0.05, lpP99: 1.5))
        XCTAssertEqual(t.heads["inter1_log_probs"], GoldenRawTolerance.Head(tokenEdits: 1, lpMean: 0.1, lpP99: 2))
        XCTAssertEqual(t.pMean, 0.02)
        XCTAssertNil(good.rawTolerance(build: "coreml-compact"), "a build not listed has no tolerance: tokens only")
        // signed without them (a writer that does not cover the field): verified, and the tolerance counts as absent
        let unsigned = try v.verifySignature(try signed(m, key: key, raw: false), required: true)
        XCTAssertFalse(unsigned.goldenRawSigned)
        XCTAssertNil(unsigned.rawTolerance(build: "coreml"))
        // a tolerance loosened after signing: refused
        var loose = try signed(m, key: key)
        loose.goldenRawField = .object(["coreml": .object(["log_probs": .object(["token_edits": .number(9), "lp_mean": .number(0.05), "lp_p99": .number(1.5)])])])
        XCTAssertThrowsError(try v.verifySignature(loose, required: true)) { XCTAssertEqual($0 as? RecognizerError, .signatureInvalid) }
        // without the field: no line
        let plain = try manifest(raw: nil)
        XCTAssertFalse(plain.signedText().contains("golden_raw"))
        XCTAssertNoThrow(try v.verifySignature(try signed(plain, key: key), required: true))
        // it survives the folder's manifest.json
        let again = try ModelManifest.parse(good.jsonData())
        XCTAssertEqual(try v.verifySignature(again, required: true).rawTolerance(build: "coreml")?.pMean, 0.02)
        // a 2.x golden_tolerance next to it is signed text only: each signed with or without its lines
        let both = try manifest(raw: ["coreml": Self.coreml] as [String: Any], legacy: ["coreml": ["token_diffs": 0, "site_flag_diffs": 1, "word_flag_diffs": 1]])
        XCTAssertTrue(both.signedText().contains("contexts c16_l64\ngolden_tolerance coreml 0 1 1\ngolden_raw coreml attr"))
        let rawOnly = try v.verifySignature(try signed(both, key: key, tolerance: false, raw: true), required: true)
        XCTAssertTrue(rawOnly.goldenRawSigned)
        XCTAssertFalse(rawOnly.goldenToleranceSigned)
        let neither = try v.verifySignature(try signed(both, key: key, tolerance: false, raw: false), required: true)
        XCTAssertFalse(neither.goldenRawSigned)
        XCTAssertNil(neither.rawTolerance(build: "coreml"))
    }

    func testAMalformedBuildIsJudgedOnTokensOnly() throws {
        let key = Curve25519.Signing.PrivateKey()
        let v = ManifestVerifier(trustedKeys: [key.publicKey.rawRepresentation], requireSignature: true)
        let ok: [String: Any] = ["log_probs": ["token_edits": 0, "lp_mean": 0.05, "lp_p99": 1.5]]
        let entries: [String: Any] = [
            "coreml": ok,
            "a": ["log_probs": ["token_edits": -1, "lp_mean": 0.05, "lp_p99": 1.5]],
            "b": ["log_probs": ["token_edits": 0, "lp_mean": "0.05", "lp_p99": 1.5] as [String: Any]],
            "c": ["log_probs": ["token_edits": 0, "lp_mean": 0.05]],
            "d": ["log_probs": ["token_edits": 0, "lp_mean": 0.05, "lp_p99": 31]],
            "e": ["attr": ["p_mean": 1.5]],
            "f": ["log_probs": ["token_edits": 0, "lp_mean": 0.0000001, "lp_p99": 1.5]],
            "g": ["log_probs": ["token_edits": 0, "lp_mean": 0.05, "lp_p99": 1.5], "Bad Head": ["p_mean": 0.1]],
            "h": "loose",
            "i": ["attr": ["p_mean": true]],
        ]
        let m = try manifest(raw: entries)
        let trusted = try v.verifySignature(try signed(m, key: key), required: true)
        XCTAssertEqual(Set(trusted.goldenRaw.keys), ["coreml"])
        XCTAssertEqual(trusted.tokensOnlyBuilds, ["a", "b", "c", "d", "e", "f", "g", "h", "i"])
        XCTAssertEqual(trusted.signedText().components(separatedBy: "\n").filter { $0.hasPrefix("golden_raw ") },
                       ["golden_raw coreml log_probs token_edits=0 lp_mean=0.05 lp_p99=1.5"])
        XCTAssertNoThrow(try manifest(raw: "loose"), "the CPU path never depends on it")
        XCTAssertNil(try v.verifySignature(try signed(try manifest(raw: "loose"), key: key), required: true).rawTolerance(build: "coreml"))
    }

    func testToleranceNumbersAreWrittenInOneForm() {
        XCTAssertEqual(GoldenRawTolerance.number(.number(0.05), 0, 30), "0.05")
        XCTAssertEqual(GoldenRawTolerance.number(.number(2), 0, 30), "2.0")
        XCTAssertEqual(GoldenRawTolerance.number(.number(1.5), 0, 30), "1.5")
        XCTAssertEqual(GoldenRawTolerance.number(.number(0), 0, 30), "0.0")
        XCTAssertEqual(GoldenRawTolerance.number(.number(30), 0, 30), "30.0")
        XCTAssertEqual(GoldenRawTolerance.number(.number(0.000001), 0, 30), "0.000001")
        XCTAssertNil(GoldenRawTolerance.number(.number(0.0000001), 0, 30), "more than 6 digits after the dot")
        XCTAssertNil(GoldenRawTolerance.number(.number(30.5), 0, 30))
        XCTAssertNil(GoldenRawTolerance.number(.string("0.05"), 0, 30))
        XCTAssertNil(GoldenRawTolerance.number(.bool(true), 0, 1))
        XCTAssertEqual(GoldenRawTolerance.count(.number(3)), "3")
        XCTAssertNil(GoldenRawTolerance.count(.number(0.5)))
        XCTAssertNil(GoldenRawTolerance.count(.number(1_000_001)))
    }

    // MARK: the raw golden test (golden_raw.json)

    func matrix(_ rows: [[Double]]) -> GoldenRaw.Matrix {
        GoldenRaw.Matrix(rows: rows.count, cols: rows.first?.count ?? 0, values: rows.flatMap { $0.map { Float($0) } })
    }

    func heads(_ any: Any?) -> [String: GoldenRaw.Matrix] {
        ((any as? [String: [[Double]]]) ?? [:]).mapValues { matrix($0) }
    }

    /// Every case of the shared vector: the measures, the measures out of tolerance in the reference's order, and
    /// the verdict.
    func testGoldenRawVectors() throws {
        let v = try Vectors30.json("golden_raw.json")
        XCTAssertEqual(v["ctc_heads"] as? [String], GoldenRaw.ctcHeads)
        XCTAssertEqual(v["attr_heads"] as? [String], GoldenRaw.attrHeads)
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 20)
        var reports = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let build = try XCTUnwrap(c["build"] as? String, name)
            var tolerance: GoldenRawTolerance?
            if let entry = c["tolerance_entry"], !(entry is NSNull) { tolerance = GoldenRawTolerance.build(build, JSONValue(any: entry))?.tolerance }
            let clips = try XCTUnwrap(c["clips"] as? [[String: Any]], name).map { clip in
                GoldenRaw.Clip(id: clip["id"] as? String ?? "?", clean: (clip["kind"] as? String) == "clean",
                               expectedTokens: clip["expected_tokens"] as? [Int], cpu: heads(clip["cpu"]), accelerator: heads(clip["accelerator"]))
            }
            let got = GoldenRaw.evaluate(clips, tolerance: tolerance)
            let e = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(tolerance == nil, e["tolerance"] is NSNull, "\(name): the tolerance in force")
            XCTAssertEqual(got.pass, e["pass"] as? Bool, name)
            XCTAssertEqual(got.reason?.rawValue, e["reason"] as? String, name)
            XCTAssertEqual(got.failed, e["failed"] as? [String], name)
            let measures = try XCTUnwrap(e["measures"] as? [String: Any], name)
            XCTAssertEqual(Set(got.ctc.keys).union(got.attrCompared ? ["attr"] : []), Set(measures.keys), "\(name): the heads compared")
            for (head, any) in measures {
                let label = "\(name), \(head)"
                if head == "attr" {
                    guard let m = any as? [String: Any] else {
                        XCTAssertNil(got.pMean, label)
                        continue
                    }
                    XCTAssertEqual(try XCTUnwrap(got.pMean, label), try XCTUnwrap(m["p_mean"] as? Double, label), accuracy: 1e-6, label)
                    XCTAssertEqual(got.attrValues, m["values"] as? Int, label)
                } else {
                    let entry = try XCTUnwrap(got.ctc[head], label)
                    guard let m = any as? [String: Any] else {
                        XCTAssertNil(entry, "\(label): a head whose shapes differ has no measures")
                        continue
                    }
                    let measure = try XCTUnwrap(entry, label)
                    XCTAssertEqual(measure.tokenEdits, m["token_edits"] as? Int, label)
                    XCTAssertEqual(measure.lpMean, try XCTUnwrap(m["lp_mean"] as? Double, label), accuracy: 1e-6, label)
                    XCTAssertEqual(measure.lpP99, try XCTUnwrap(m["lp_p99"] as? Double, label), accuracy: 1e-6, label)
                    XCTAssertEqual(measure.frames, m["frames"] as? Int, label)
                }
            }
            // a case that fails carries the incident report's `detail.divergence`
            if let want = c["divergence"] as? [String: Any] {
                XCTAssertFalse(got.pass, name)
                let d = got.divergence(tolerance: tolerance).bounded
                let mine = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any], name)
                XCTAssertTrue(Telemetry30VectorTests.same(mine, want), "\(name): the divergence \(mine) against \(want)")
                reports += 1
            } else {
                XCTAssertTrue(got.pass, "\(name): a case that fails has a divergence")
            }
        }
        XCTAssertEqual(reports, 9)
    }

    /// What a failed golden test reports: the measures per head, the tolerance, what failed, the CPU's token count, in
    /// the shape the server takes (and none of the 2.x fields).
    func testTheDivergenceOfAnIncident() throws {
        func ids(_ tokens: [Int]) -> GoldenRaw.Matrix { GoldenRaw.Matrix(Vectors30.logProbs(tokens), cols: 38) }
        let cpu = ids([0, 3, 3, 0, 4, 0, 5, 0]), acc = ids([0, 3, 3, 0, 7, 0, 5, 0])
        let clip = GoldenRaw.Clip(id: "a", clean: true, expectedTokens: [3, 4, 5], cpu: ["log_probs": cpu], accelerator: ["log_probs": acc])
        let short = GoldenRaw.Clip(id: "b", clean: true, expectedTokens: [3, 4, 5], cpu: ["log_probs": cpu, "gem": GoldenRaw.Matrix([0.5, 0.5], cols: 2)],
                                   accelerator: ["log_probs": acc, "gem": GoldenRaw.Matrix([0.4, 0.6, 0.5, 0.5], cols: 2)])
        let tolerance = GoldenRawTolerance(heads: ["log_probs": .init(tokenEdits: 0, lpMean: 0.05, lpP99: 1.5)], pMean: 0.02)
        let verdict = GoldenRaw.evaluate([clip, short], tolerance: tolerance)
        XCTAssertEqual(verdict.reason, .goldenMismatch)
        XCTAssertEqual(verdict.failed, ["gem.shape", "log_probs.token_edits", "log_probs.lp_mean", "log_probs.lp_p99"])
        XCTAssertEqual(verdict.tokensExpected, 6)
        let d = verdict.divergence(tolerance: tolerance).bounded
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["tokens_expected", "heads", "tolerance", "failed"])
        XCTAssertEqual(o["tokens_expected"] as? Int, 6)
        let heads = try XCTUnwrap(o["heads"] as? [String: Any])
        XCTAssertEqual(Set(heads.keys), ["log_probs", "attr"])
        XCTAssertTrue(heads["attr"] is NSNull, "a head whose shapes differed is null")
        let lp = try XCTUnwrap(heads["log_probs"] as? [String: Any])
        XCTAssertEqual(Set(lp.keys), ["token_edits", "lp_mean", "lp_p99", "frames"])
        XCTAssertEqual(lp["token_edits"] as? Int, 2)
        XCTAssertEqual(lp["frames"] as? Int, 16)
        let tol = try XCTUnwrap(o["tolerance"] as? [String: [String: Any]])
        XCTAssertEqual(tol["log_probs"]?["lp_p99"] as? Double, 1.5)
        XCTAssertEqual(tol["attr"]?["p_mean"] as? Double, 0.02)
        XCTAssertEqual(o["failed"] as? [String], verdict.failed)
        XCTAssertEqual(try JSONDecoder().decode(Divergence.self, from: JSONEncoder().encode(d)), d)
        // a clean clip whose CPU tokens are not the expected ones is a cpu_mismatch, whatever else differs
        let wrong = GoldenRaw.Clip(id: "c", clean: true, expectedTokens: [3, 4], cpu: ["log_probs": cpu], accelerator: ["log_probs": cpu])
        XCTAssertEqual(GoldenRaw.evaluate([wrong], tolerance: nil).reason, .cpuMismatch)
        XCTAssertEqual(GoldenRaw.evaluate([wrong], tolerance: nil).cpuMismatchClip, "c")
        // the SDK's own clips have no expected tokens: tokens only, against the CPU run
        let own = GoldenRaw.Clip(id: "d", clean: true, expectedTokens: nil, cpu: ["log_probs": cpu], accelerator: ["log_probs": cpu])
        XCTAssertTrue(GoldenRaw.evaluate([own], tolerance: nil).pass)
    }
    // MARK: through the promotion pipeline, by a signed tolerance

    /// The tolerance Quran Lab signs for the two CoreML builds of model 4.0.0 (its numbers; the tests sign them with
    /// a key of their own): made from device measurements with a margin, it allows token edits, because the CPU
    /// engine runs int8 weights and an fp16 build is nearer the fp32 model.
    static var signedTolerance: [String: Any] {
        ["coreml": ["log_probs": ["token_edits": 2, "lp_mean": 0.36, "lp_p99": 0.65],
                    "inter1_log_probs": ["token_edits": 3, "lp_mean": 0.23, "lp_p99": 0.49],
                    "timing_log_probs": ["token_edits": 4, "lp_mean": 0.49, "lp_p99": 1.19], "attr": ["p_mean": 0.0014]],
         "coreml-compact": ["log_probs": ["token_edits": 2, "lp_mean": 0.13, "lp_p99": 0.26],
                            "inter1_log_probs": ["token_edits": 2, "lp_mean": 0.16, "lp_p99": 0.33],
                            "timing_log_probs": ["token_edits": 5, "lp_mean": 0.25, "lp_p99": 0.58], "attr": ["p_mean": 0.0008]]]
    }

    /// Rows of log-probabilities over six classes (0 is blank) whose greedy tokens are `tokens`: the frame's token at
    /// -0.6, one other class at -0.8, the rest at -12. In a frame of `swapped` the two change places: the greedy
    /// token is the other class, 0.2 nats away.
    static func rows(_ tokens: [Int], swapped: Set<Int> = []) -> GoldenRaw.Matrix {
        var values = [Float](repeating: -12, count: tokens.count * 6)
        for (f, t) in tokens.enumerated() {
            let other = t == 5 ? 4 : 5
            values[f * 6 + t] = swapped.contains(f) ? -0.8 : -0.6
            values[f * 6 + other] = swapped.contains(f) ? -0.6 : -0.8
        }
        return GoldenRaw.Matrix(values, cols: 6)
    }

    /// One clean clip as the two engines gave it: the same `log_probs`, and a timing head on which the accelerator
    /// is `edits` greedy tokens away from the CPU engine, each by 0.2 nats in one frame.
    static func clip(timingEdits edits: Int) -> GoldenRaw.Clip {
        let tokens = [0, 3, 3, 0, 4, 0, 5, 0]
        let timing = [0, 1, 0, 2, 0, 3, 0, 1, 0, 2, 0, 3, 0, 1, 0, 2]
        // the frames that hold a token: 1, 3, 5, ...
        let swapped = Set((0..<edits).map { 2 * $0 + 1 })
        return GoldenRaw.Clip(id: "a", clean: true, expectedTokens: [3, 4, 5],
                              cpu: ["log_probs": rows(tokens), "timing_log_probs": rows(timing)],
                              accelerator: ["log_probs": rows(tokens), "timing_log_probs": rows(timing, swapped: swapped)])
    }

    /// Through the promotion pipeline with the tolerance of a signed manifest: a build whose token edits are inside
    /// it is promoted, and its record keeps what was measured next to the bounds; a build with one edit more is not
    /// promoted, with `golden_mismatch` and the measure that was outside. Without a tolerance the first of the two
    /// is not promoted either: identical tokens decide.
    func testThePipelinePromotesInsideTheSignedToleranceAndDemotesOutsideIt() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let v = ManifestVerifier(trustedKeys: [key.publicKey.rawRepresentation], requireSignature: true)
        let m = try v.verifySignature(try signed(try manifest(raw: Self.signedTolerance), key: key), required: true)
        XCTAssertTrue(m.goldenRawSigned)
        XCTAssertEqual(m.signedText().components(separatedBy: "\n").filter { $0.hasPrefix("golden_raw ") }.count, 8, "the signed lines of the two builds")
        XCTAssertTrue(m.signedText().contains("golden_raw coreml timing_log_probs token_edits=4 lp_mean=0.49 lp_p99=1.19\n"), m.signedText())
        let tolerance = try XCTUnwrap(m.rawTolerance(build: "coreml"), "the fp16 build's tolerance, read for its build key")
        XCTAssertEqual(tolerance.heads["timing_log_probs"], GoldenRawTolerance.Head(tokenEdits: 4, lpMean: 0.49, lpP99: 1.19))
        XCTAssertEqual(m.rawTolerance(build: "coreml-compact")?.heads["timing_log_probs"]?.tokenEdits, 5)
        XCTAssertNil(m.rawTolerance(build: "npu:exynos2500:c16_l64"), "a build key without a tolerance: identical tokens")

        // four token edits on the timing head, the bound the manifest signs: promoted
        let inside = TajweedRecognizer.goldenOutcome([Self.clip(timingEdits: 4)], tolerance: tolerance, accelerator: [0.002, 0.003],
                                                     cpu: [0.008, 0.009], label: "coreml c16_l64")
        let h = PromotionTests.Harness()
        h.goldens.withLock { $0 = [inside] }
        let promoted = h.controller()
        await promoted.run(h.stages())
        XCTAssertEqual(h.calls.withLock { $0 }, ["download", "compile", "warmup", "golden"])
        XCTAssertEqual(promoted.state, .ready)
        XCTAssertEqual(promoted.record?.status, .ready)
        XCTAssertNotNil(promoted.leaseForSession(), "the next Session runs on the build")
        let kept = try XCTUnwrap(promoted.record?.golden)
        XCTAssertEqual(kept.heads?["timing_log_probs"]??.tokenEdits, 4)
        XCTAssertEqual(kept.heads?["timing_log_probs"]??.lpMean ?? -1, 0.05, accuracy: 1e-6, "four frames of sixteen, 0.2 nats each")
        XCTAssertEqual(kept.heads?["log_probs"]??.tokenEdits, 0)
        XCTAssertEqual(kept.tolerance?["timing_log_probs"]?.tokenEdits, 4, "the bound it was judged by is kept with it")
        XCTAssertEqual(kept.tolerance?["timing_log_probs"]?.lpP99, 1.19)
        XCTAssertEqual(kept.failed, [])

        // five: one edit outside the tolerance, not promoted, and the record says which measure
        let outside = TajweedRecognizer.goldenOutcome([Self.clip(timingEdits: 5)], tolerance: tolerance, accelerator: [0.002], cpu: [0.008],
                                                      label: "coreml c16_l64")
        guard case .failed(let failure) = outside else { return XCTFail("five token edits are outside a tolerance of four") }
        XCTAssertEqual(failure.reason, .goldenMismatch)
        let h2 = PromotionTests.Harness()
        h2.failures.withLock { $0[.golden] = failure }
        let demoted = h2.controller()
        await demoted.run(h2.stages())
        XCTAssertNotEqual(demoted.state, .ready)
        XCTAssertNil(demoted.leaseForSession(), "the Session stays on the CPU engine")
        XCTAssertEqual(demoted.record?.lastStage, .golden)
        XCTAssertEqual(demoted.record?.lastReason, .goldenMismatch)
        XCTAssertEqual(demoted.record?.lastDetail, "golden: out of tolerance against the CPU engine: timing_log_probs.token_edits")
        XCTAssertEqual(demoted.record?.golden?.failed, ["timing_log_probs.token_edits"])
        XCTAssertEqual(demoted.record?.golden?.heads?["timing_log_probs"]??.tokenEdits, 5)
        XCTAssertEqual(demoted.record?.golden?.tolerance?["timing_log_probs"]?.tokenEdits, 4)

        // the same four edits for a build the manifest gives no tolerance: identical tokens decide
        let alone = TajweedRecognizer.goldenOutcome([Self.clip(timingEdits: 4)], tolerance: nil, accelerator: [0.002], cpu: [0.008], label: "npu c16_l64")
        guard case .failed(let tokens) = alone else { return XCTFail("without a tolerance a token edit is not promoted") }
        XCTAssertEqual(tokens.reason, .goldenMismatch)
        XCTAssertEqual(tokens.detail, "the tokens differ from the CPU engine's (this build has no tolerance): timing_log_probs.token_edits")
        // and no edit at all passes with or without one
        guard case .passed(_, _, let same) = TajweedRecognizer.goldenOutcome([Self.clip(timingEdits: 0)], tolerance: nil, accelerator: [0.002],
                                                                              cpu: [0.008], label: "npu c16_l64") else {
            return XCTFail("identical tokens pass")
        }
        XCTAssertNil(same?.tolerance)
        XCTAssertEqual(same?.heads?["timing_log_probs"]??.tokenEdits, 0)
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
