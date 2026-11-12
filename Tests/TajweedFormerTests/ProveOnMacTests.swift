import Foundation
import XCTest
@testable import TajweedFormer

/// The proof a person runs on a Mac (`scripts/prove-on-mac.sh <key> [<clips folder>]`): `testProveOnMac` is that run
/// and needs a real key, so it is skipped everywhere else. The other tests here run on CI: the parts of the proof that
/// need no model (the summary and its exit status, the measures' records, what is never printed, the conformance hash,
/// the distances), and a rehearsal of the whole run against a stub server with stand-in engines.
final class ProveOnMacTests: XCTestCase {
    // MARK: the run on a Mac

    /// Run by scripts/prove-on-mac.sh, which sets the environment: the key (never printed, never stored), the folder
    /// the run works in, and what the signed config is expected to name.
    func testProveOnMac() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["QURANLAB_PROVE_KEY"], !key.isEmpty else {
            throw XCTSkip("scripts/prove-on-mac.sh runs this on a Mac with a real key; it does not run on CI")
        }
        func value(_ name: String) -> String? { env[name].flatMap { $0.isEmpty || $0 == "any" ? nil : $0 } }
        let work = URL(fileURLWithPath: env["QURANLAB_PROVE_DIR"] ?? NSTemporaryDirectory().appending("tajweedformer-prove"))
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var config = ProveConfig(key: key, appId: value("QURANLAB_APP_ID") ?? ProveOnMac.proofIdentifier,
                                 storage: work.appendingPathComponent("storage", isDirectory: true))
        config.clips = value("QURANLAB_PROVE_CLIPS").map { URL(fileURLWithPath: $0) }
        config.expectedRows = value("QURANLAB_PROVE_EXPECTED").map { URL(fileURLWithPath: $0) }
        config.expectVersion = value("QURANLAB_EXPECT_VERSION")
        config.expectBuild = value("QURANLAB_EXPECT_BUILD")
        config.contexts = value("QURANLAB_PROVE_CONTEXTS")?.split(separator: " ").map(String.init)
        if let builds = value("QURANLAB_PROVE_BUILDS") { config.builds = builds.split(separator: " ").map(String.init) }
        let out = ProveOut(progress: work.appendingPathComponent("prove.out"), echo: false)
        let settings = config
        let report = await ProveOnMac.run(config, doors: .real(), out: out) { try ProveOnMac.client(settings) }
        try Self.write(report, to: work)
        XCTAssertEqual(report.status, 0, "a step failed: see the summary")
    }

    /// What the script reads when the run is over: the summary it prints last, and the status it exits with.
    static func write(_ report: ProveReport, to work: URL) throws {
        try (report.summary.joined(separator: "\n") + "\n").write(to: work.appendingPathComponent("prove.summary"), atomically: true, encoding: .utf8)
        try "\(report.status)\n".write(to: work.appendingPathComponent("prove.status"), atomically: true, encoding: .utf8)
    }

    // MARK: the parts that need no model

    static func steps(_ verdicts: [ProveVerdict]) -> [ProveStep] {
        ProveOnMac.titles.enumerated().map { ProveStep(number: $0.offset, title: $0.element, verdict: verdicts[$0.offset], note: "") }
    }

    static func measures(_ scale: Double) -> ProveMeasures {
        var m = ProveMeasures()
        m.ctc["log_probs"] = .init(tokenEdits: 0, lpMean: 0.0123456789 * scale, lpP99: 0.4567891234 * scale, frames: 613)
        m.ctc["inter1_log_probs"] = .init(tokenEdits: 0, lpMean: 0.02 * scale, lpP99: 0.7 * scale, frames: 613)
        m.ctc["timing_log_probs"] = .init(tokenEdits: 1, lpMean: 0.031 * scale, lpP99: 1.25 * scale, frames: 1226)
        m.pMean = 0.0012345678 * scale
        m.values = 20_842
        m.tokensExpected = 79
        return m
    }

    /// The model, the clips and the device that go with every record of measures.
    static var facts: ProveFacts {
        var f = ProveFacts()
        f.modelVersion = "4.0.0"
        f.modelBuild = String(repeating: "ab", count: 20)
        f.clips = 5
        f.cleanClips = 4
        f.device = [(name: "platform", value: "macos"), (name: "os_version", value: "15.1"), (name: "os_build", value: "24B83"),
                    (name: "device_model", value: "Mac14,9"), (name: "chip", value: "m2"), (name: "sdk_version", value: "3.0.0")]
        return f
    }

    /// The summary's last lines are the ones to paste back: one line per step with its verdict, in order, then the
    /// golden stage's measures and the tolerance proposed from them. The exit status is 0 only when every step that
    /// ran passed.
    func testTheSummaryEndsWithTheLinesToPasteBack() throws {
        var steps = Self.steps([.pass, .pass, .pass, .pass, .pass, .skipped, .pass])
        steps[5].note = "no clips folder was given"
        let measured = [ProveMeasured(build: "coreml", context: "c16_l64", measures: Self.measures(1))]
        let lines = ProveOnMac.summary(steps: steps, header: ["TajweedFormer", "model 4.0.0"], measured: measured, device: "Mac14,9", facts: Self.facts)
        let cut = try XCTUnwrap(lines.firstIndex(of: "----- paste from here -----"))
        XCTAssertEqual(Array(lines[..<cut]), ["TajweedFormer", "model 4.0.0"], "the header and the counts come first")
        let pasted = Array(lines[(cut + 1)...])
        for (i, title) in ProveOnMac.titles.enumerated() {
            XCTAssertTrue(pasted[i].hasPrefix("step \(i)  \(title)"), pasted[i])
            XCTAssertTrue(pasted[i].contains(i == 5 ? "SKIPPED  no clips folder was given" : "PASS"), pasted[i])
        }
        XCTAssertTrue(pasted[7].hasPrefix("measures of the golden stage on Mac14,9"), "the measures follow the steps")
        XCTAssertTrue(pasted[8].hasPrefix("these are measurements: the golden stage judges a build by the tolerance"), pasted[8])
        XCTAssertEqual(pasted.count, 14, "seven steps, two lines of words, one record, the proposal in four lines")
        XCTAssertTrue(pasted[9].hasPrefix("{\"build\": \"coreml\", \"context\": \"c16_l64\"") && pasted[9].hasSuffix("}"), "a record")
        XCTAssertTrue(pasted[10].hasPrefix("a proposal for the model side, not a tolerance in force"), pasted[10])
        XCTAssertEqual(pasted[11], "\"golden_raw_tolerance\": {")
        XCTAssertTrue(pasted[12].hasPrefix(" \"coreml\": {"), pasted[12])
        XCTAssertEqual(pasted[13], "}", "the proposal is the last thing printed")
        XCTAssertLessThanOrEqual(lines.count, 24, "one screen")
        XCTAssertEqual(ProveOnMac.status(steps), 0, "a skipped step did not run")
        steps[3].verdict = .fail
        XCTAssertEqual(ProveOnMac.status(steps), 1)
        XCTAssertTrue(ProveOnMac.summary(steps: steps, header: [], measured: [], device: "x", facts: Self.facts).contains { $0.contains("step 3") && $0.contains("FAIL") })
        XCTAssertEqual(ProveOnMac.status(Self.steps([.pass, .fail, .notRun, .notRun, .notRun, .notRun, .notRun])), 1)
        XCTAssertEqual(ProveOnMac.status(Self.steps([.pass, .pass, .pass, .pass, .pass, .pass, .notRun])), 1, "a step that did not run is no pass")
    }

    /// The golden stage's measures are records: one JSON object per build and context that reached the stage, with
    /// the field names of the server's notes, under two lines that say what they are and how the stage judges (by
    /// the tolerance the signed manifest gives a build, on identical tokens when it gives none).
    func testTheMeasuresAreRecords() throws {
        let measured = [
            ProveMeasured(build: "coreml", context: "c16_l64", measures: Self.measures(1)),
            ProveMeasured(build: "coreml", context: "c24_l72", measures: Self.measures(1.5)),
            ProveMeasured(build: "coreml-compact", context: "c16_l64", measures: Self.measures(3)),
        ]
        var failed = ProveMeasured(build: "coreml-compact", context: "c24_l72", measures: Self.measures(2))
        failed.passed = false
        let lines = ProveOnMac.measuresBlock(measured + [failed], device: "Mac14,9, macOS 15.1", facts: Self.facts)
        XCTAssertEqual(lines.count, 6, "two lines of words, then one record per build and context")
        XCTAssertTrue(lines[0].hasPrefix("measures of the golden stage on Mac14,9, macOS 15.1"), lines[0])
        XCTAssertTrue(lines[0].hasSuffix("4 records, 3 passed"), lines[0])
        XCTAssertTrue(lines[0].contains("lp_mean and lp_p99 in nats, p_mean a probability"), lines[0])
        XCTAssertEqual(lines[1], "these are measurements: the golden stage judges a build by the tolerance its signed manifest gives it, and on "
            + "identical tokens when the manifest gives it none")
        XCTAssertFalse(lines.contains { $0.contains("no tolerance") || $0.contains("none that allows") }, "nothing says a tolerance cannot be signed")
        // each record is a JSON object with the server notes' field names
        for line in lines[2...] {
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
            XCTAssertEqual(Set(o.keys), ["build", "context", "model_version", "model_build", "clips", "clean_clips", "tokens_expected", "heads", "passed",
                                         "platform", "os_version", "os_build", "device_model", "chip", "sdk_version"])
            XCTAssertEqual(o["model_version"] as? String, "4.0.0")
            XCTAssertEqual(o["model_build"] as? String, String(repeating: "ab", count: 20))
            XCTAssertEqual(o["clips"] as? Int, 5)
            XCTAssertEqual(o["clean_clips"] as? Int, 4)
            XCTAssertEqual(o["device_model"] as? String, "Mac14,9")
            let heads = try XCTUnwrap(o["heads"] as? [String: [String: Any]])
            XCTAssertEqual(Set(heads.keys), ["log_probs", "inter1_log_probs", "timing_log_probs", "attr"])
            XCTAssertEqual(Set(try XCTUnwrap(heads["log_probs"]).keys), ["token_edits", "lp_mean", "lp_p99", "frames"])
            XCTAssertEqual(Set(try XCTUnwrap(heads["attr"]).keys), ["p_mean", "values"])
            // no number has more than 6 decimals or an exponent
            XCTAssertNil(line.range(of: #"\.[0-9]{7}|[0-9][eE][-+0-9]"#, options: .regularExpression), line)
        }
        // the record's `heads` is the shape of an incident report's `detail.divergence.heads`: the SDK reads it back
        let first = try JSONDecoder().decode(Divergence.self, from: Data(lines[2].utf8))
        XCTAssertEqual(first.tokensExpected, 79)
        XCTAssertEqual(first.heads?["timing_log_probs"]??.tokenEdits, 1)
        XCTAssertEqual(first.heads?["timing_log_probs"]??.frames, 1226)
        XCTAssertEqual(first.heads?["log_probs"]??.lpMean ?? -1, 0.012346, accuracy: 1e-9)
        XCTAssertEqual(first.heads?["attr"]??.pMean ?? -1, 0.001235, accuracy: 1e-9)
        XCTAssertEqual(first.heads?["attr"]??.values, 20_842)
        XCTAssertTrue(lines[2].contains("\"passed\": true"))
        XCTAssertTrue(lines[5].contains("\"passed\": false"), "a golden stage that did not pass is a record too")
        XCTAssertEqual(ProveOnMac.quoted("a\"b\\c"), "\"a\\\"b\\\\c\"")
        // a measure is written with at most 6 decimals and never below what was measured
        XCTAssertEqual(ProveOnMac.number(0), "0.0")
        XCTAssertEqual(ProveOnMac.number(0.05), "0.05")
        XCTAssertEqual(ProveOnMac.number(0.0123451), "0.012346", "rounded up")
        XCTAssertEqual(ProveOnMac.number(1.5), "1.5")
        XCTAssertEqual(ProveOnMac.measuresBlock([], device: "x", facts: Self.facts), ["measures of the golden stage: none (no build reached its golden stage)"])
    }

    /// A line per head shows why a build passed or which measure was outside: what was measured next to the bound
    /// the signed manifest gives the build. Without a tolerance the lines say so, and that identical tokens decided.
    func testTheJudgementShowsTheMeasuresAgainstTheSignedBounds() {
        var m = Self.measures(1)
        // the bounds production signs for the fp16 build
        var t = ProveMeasures.Tolerance()
        t.ctc["log_probs"] = .init(tokenEdits: 2, lpMean: 0.36, lpP99: 0.65, frames: 0)
        t.ctc["inter1_log_probs"] = .init(tokenEdits: 3, lpMean: 0.23, lpP99: 0.49, frames: 0)
        t.ctc["timing_log_probs"] = .init(tokenEdits: 4, lpMean: 0.49, lpP99: 1.19, frames: 0)
        t.pMean = 0.0014
        m.tolerance = t
        XCTAssertEqual(ProveOnMac.judgement(m, build: "coreml"), [
            "golden stage, judged by the tolerance the signed manifest gives coreml (measured / bound):",
            "log_probs: token_edits 0 / 2, lp_mean 0.012346 / 0.36, lp_p99 0.45679 / 0.65: inside",
            "inter1_log_probs: token_edits 0 / 3, lp_mean 0.02 / 0.23, lp_p99 0.7 / 0.49: OUTSIDE (lp_p99)",
            "timing_log_probs: token_edits 1 / 4, lp_mean 0.031 / 0.49, lp_p99 1.25 / 1.19: OUTSIDE (lp_p99)",
            "attr: p_mean 0.001235 / 0.0014: inside",
        ])
        XCTAssertEqual(m.outside, ["inter1_log_probs.lp_p99", "timing_log_probs.lp_p99"])
        // more edits than the bound, and a probability difference above its bound
        m.ctc["timing_log_probs"] = .init(tokenEdits: 5, lpMean: 0.031, lpP99: 1.0, frames: 1226)
        m.ctc["inter1_log_probs"]?.lpP99 = 0.4
        m.pMean = 0.002
        let over = ProveOnMac.judgement(m, build: "coreml")
        XCTAssertEqual(over[2], "inter1_log_probs: token_edits 0 / 3, lp_mean 0.02 / 0.23, lp_p99 0.4 / 0.49: inside")
        XCTAssertEqual(over[3], "timing_log_probs: token_edits 5 / 4, lp_mean 0.031 / 0.49, lp_p99 1.0 / 1.19: OUTSIDE (token_edits)")
        XCTAssertEqual(over[4], "attr: p_mean 0.002 / 0.0014: OUTSIDE (p_mean)")
        // a head the tolerance does not name is held to identical tokens
        m.tolerance?.ctc["timing_log_probs"] = nil
        XCTAssertEqual(ProveOnMac.judgement(m, build: "coreml")[3],
                       "timing_log_probs: token_edits 5 (no bound for this head: must be 0): OUTSIDE; lp_mean 0.031, lp_p99 1.0 measured, not judged")
        // a build the manifest gives no tolerance: it says so, and the tokens decided
        var alone = Self.measures(1)
        XCTAssertEqual(ProveOnMac.judgement(alone, build: "coreml-compact"), [
            "golden stage, the signed manifest gives coreml-compact no tolerance: identical tokens decided",
            "log_probs: token_edits 0 (must be 0); lp_mean 0.012346, lp_p99 0.45679 measured, not judged",
            "inter1_log_probs: token_edits 0 (must be 0); lp_mean 0.02, lp_p99 0.7 measured, not judged",
            "timing_log_probs: token_edits 1 (must be 0): OUTSIDE; lp_mean 0.031, lp_p99 1.25 measured, not judged",
            "attr: p_mean 0.001235 measured, not judged",
        ])
        alone.ctc["timing_log_probs"]?.tokenEdits = 0
        XCTAssertEqual(alone.outside, [])
    }

    /// The tolerance made from the measures is a proposal for the model side and says so: per build the largest
    /// value over its records (the ones that did not pass included), no margin, in a shape that pastes into a
    /// manifest and that the SDK's own manifest reader takes as well formed. What was measured is inside it.
    func testTheProposalForTheModelSideIsNamedAndPastesIntoAManifest() throws {
        let measured = [
            ProveMeasured(build: "coreml", context: "c16_l64", measures: Self.measures(1)),
            ProveMeasured(build: "coreml", context: "c24_l72", measures: Self.measures(1.5)),
            ProveMeasured(build: "coreml-compact", context: "c16_l64", measures: Self.measures(3)),
        ]
        var failed = ProveMeasured(build: "coreml-compact", context: "c24_l72", measures: Self.measures(2))
        failed.passed = false
        failed.measures.ctc["inter1_log_probs"]?.tokenEdits = 4
        let lines = ProveOnMac.proposalBlock(measured + [failed])
        XCTAssertEqual(lines.count, 5, "one line of words, the field, one line per build, the closing brace")
        XCTAssertEqual(lines[0], "a proposal for the model side, not a tolerance in force: per build the largest value of each measure over the "
            + "records above, no margin added (the margin and the signing are the model side's)")
        XCTAssertEqual(lines[1], "\"golden_raw_tolerance\": {")
        XCTAssertEqual(lines[4], "}")
        let json = "{" + lines[1...].joined(separator: "\n") + "}"
        let field = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["golden_raw_tolerance"] as? [String: Any])
        XCTAssertEqual(Set(field.keys), ["coreml", "coreml-compact"])
        let parsed = GoldenRawTolerance.parse(JSONValue(any: field))
        XCTAssertEqual(parsed.bad, [], "every entry is well formed")
        let coreml = try XCTUnwrap(parsed.good["coreml"])
        let largest = Self.measures(1.5)
        for (head, m) in largest.ctc {
            let t = try XCTUnwrap(coreml.heads[head], head)
            XCTAssertEqual(t.tokenEdits, m.tokenEdits, head)
            XCTAssertGreaterThanOrEqual(t.lpMean, m.lpMean, "\(head): the measured value is inside the proposal")
            XCTAssertLessThan(t.lpMean - m.lpMean, 0.000_001_5, "\(head): rounded up to the sixth decimal, no margin")
            XCTAssertGreaterThanOrEqual(t.lpP99, m.lpP99, head)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(coreml.pMean), try XCTUnwrap(largest.pMean))
        // a record the golden stage did not pass counts: the proposal bounds what was measured
        let compact = try XCTUnwrap(parsed.good["coreml-compact"])
        XCTAssertEqual(compact.heads["inter1_log_probs"]?.tokenEdits, 4)
        XCTAssertEqual(compact.heads["timing_log_probs"]?.tokenEdits, 1)
        XCTAssertEqual(compact.heads["log_probs"]?.lpMean ?? -1, 0.037038, accuracy: 1e-9, "the largest over its records")
        XCTAssertEqual(parsed.lines.count, 8, "three CTC heads and attr for each of the two builds")
        // every record judged by the proposal is inside it
        for m in measured + [failed] {
            var judged = m.measures
            let t = try XCTUnwrap(parsed.good[m.build])
            var kept = ProveMeasures.Tolerance()
            for (head, h) in t.heads { kept.ctc[head] = .init(tokenEdits: h.tokenEdits, lpMean: h.lpMean, lpP99: h.lpP99, frames: 0) }
            kept.pMean = t.pMean
            judged.tolerance = kept
            XCTAssertEqual(judged.outside, [], "\(m.build) \(m.context)")
        }
        XCTAssertEqual(ProveOnMac.proposalBlock([]), [], "nothing measured: nothing proposed")
    }

    /// Step 4 passes when every build and context ended promoted, or on the CPU engine for a reason the pipeline names:
    /// tokens that differ are the pipeline doing its job. It fails only on a fault of the pipeline. Its line says how
    /// many ended each way.
    func testStepFourPassesWhenEveryBuildEndedPromotedOrOnTheCPUEngineForANamedReason() {
        func ended(_ build: String, _ context: String, _ outcome: ProveOutcome, edits: Int = 0) -> ProveEnded {
            var m = Self.measures(1)
            m.ctc["timing_log_probs"]?.tokenEdits = edits
            return ProveEnded(build: build, context: context, outcome: outcome, measures: m)
        }
        let differ = ProveOutcome.demoted(reason: "golden_mismatch", detail: "golden: the tokens differ")
        // the first real run: six builds and contexts, three promoted, three with tokens that differ
        let first = [ended("coreml", "c16_l64", differ, edits: 1), ended("coreml", "c24_l72", differ, edits: 2), ended("coreml", "c24_l256", .promoted),
                     ended("coreml-compact", "c16_l64", .promoted), ended("coreml-compact", "c24_l72", differ, edits: 3),
                     ended("coreml-compact", "c24_l256", .promoted)]
        var v = ProveOnMac.pipelineVerdict(first)
        XCTAssertEqual(v.verdict, .pass)
        XCTAssertEqual(v.note, "promoted 3 of 6; 3 stayed on the CPU engine: tokens differ")
        v = ProveOnMac.pipelineVerdict(Array(first.suffix(3)))
        XCTAssertEqual(v.note, "promoted 2 of 3; 1 stayed on the CPU engine: tokens differ")
        XCTAssertEqual(v.verdict, .pass)
        v = ProveOnMac.pipelineVerdict([ended("coreml-compact", "c16_l64", .promoted)])
        XCTAssertEqual(v.note, "promoted 1 of 1")
        XCTAssertEqual(v.verdict, .pass)
        // every build on the CPU engine is still the pipeline's answer
        v = ProveOnMac.pipelineVerdict([ended("coreml-compact", "c16_l64", differ, edits: 1), ended("coreml-compact", "c24_l72", .demoted(reason: "compile_error", detail: ""))])
        XCTAssertEqual(v.verdict, .pass)
        XCTAssertEqual(v.note, "promoted 0 of 2; 2 stayed on the CPU engine: 1 tokens differ, 1 the compile failed")
        // the faults of the pipeline: it failed, a stage did not end, a promotion although tokens differ, a promotion
        // with nothing measured, no build at all
        v = ProveOnMac.pipelineVerdict([ended("coreml-compact", "c16_l64", .promoted), ended("coreml-compact", "c24_l72", .failed("crash: the app stopped during the compile stage"))])
        XCTAssertEqual(v.verdict, .fail)
        XCTAssertEqual(v.note, "promoted 1 of 2; 1 pipeline error: coreml-compact c24_l72: crash: the app stopped during the compile stage")
        v = ProveOnMac.pipelineVerdict([ended("coreml-compact", "c16_l64", .promoted, edits: 2)])
        XCTAssertEqual(v.verdict, .fail)
        XCTAssertTrue(v.note.contains("was promoted although its tokens differ"), v.note)
        v = ProveOnMac.pipelineVerdict([ProveEnded(build: "coreml-compact", context: "c16_l64", outcome: .promoted, measures: nil)])
        XCTAssertEqual(v.verdict, .fail)
        XCTAssertEqual(ProveOnMac.pipelineVerdict([]).verdict, .fail)
        // served pairs and nothing through the pipeline is a fault; no served pair at all is not (SDK 3.0.2): the
        // step passes with one sentence
        v = ProveOnMac.pipelineVerdict([], served: 2)
        XCTAssertEqual(v.verdict, .fail)
        XCTAssertEqual(v.note, "no build went through the pipeline, although the model has 2 build and context pairs served")
        v = ProveOnMac.pipelineVerdict([], served: 0)
        XCTAssertEqual(v.verdict, .pass)
        XCTAssertEqual(v.note, "no accelerator build serves any context of this build: every context runs on the CPU engine, and there is nothing to promote")
        XCTAssertEqual(ProveOnMac.nothingServed(builds: ["coreml"], others: [], contexts: ["c16_l64", "c24_l72"]),
                       "no accelerator build serves the contexts of this run (c16_l64 c24_l72): every context runs on the CPU engine, and there is nothing to promote")
        XCTAssertEqual(ProveOnMac.nothingServed(builds: ["coreml"], others: ["coreml-compact"], contexts: nil),
                       "the builds of this run (coreml) serve none of its contexts; coreml-compact does, and was not asked for: in this run every context "
                       + "runs on the CPU engine, and there is nothing to promote")
        // builds that ended are judged as before, whatever `served` says
        v = ProveOnMac.pipelineVerdict([ended("coreml-compact", "c16_l64", .promoted)], served: 1)
        XCTAssertEqual(v.verdict, .pass)
        // a build whose signed manifest gives it a tolerance: a promotion with token edits inside it is the tolerance
        // at work, a promotion outside it is the pipeline's fault, and a build that did not pass is outside it
        func judged(_ outcome: ProveOutcome, edits: Int, allowed: Int) -> ProveEnded {
            var e = ended("coreml", "c16_l64", outcome, edits: edits)
            var t = ProveMeasures.Tolerance()
            for (head, m) in e.measures?.ctc ?? [:] {
                t.ctc[head] = .init(tokenEdits: head == "timing_log_probs" ? allowed : 0, lpMean: m.lpMean + 0.1, lpP99: m.lpP99 + 0.1, frames: 0)
            }
            t.pMean = 0.5
            e.measures?.tolerance = t
            return e
        }
        v = ProveOnMac.pipelineVerdict([judged(.promoted, edits: 2, allowed: 2)])
        XCTAssertEqual(v.verdict, .pass)
        XCTAssertEqual(v.note, "promoted 1 of 1")
        v = ProveOnMac.pipelineVerdict([judged(.promoted, edits: 3, allowed: 2)])
        XCTAssertEqual(v.verdict, .fail)
        XCTAssertTrue(v.note.contains("coreml c16_l64 was promoted outside its tolerance (timing_log_probs.token_edits)"), v.note)
        v = ProveOnMac.pipelineVerdict([judged(differ, edits: 3, allowed: 2)])
        XCTAssertEqual(v.verdict, .pass)
        XCTAssertEqual(v.note, "promoted 0 of 1; 1 stayed on the CPU engine: outside the tolerance")
        XCTAssertEqual(ProveOnMac.words(reason: "golden_mismatch", tolerance: true), "outside the tolerance")
        // which reasons are the pipeline's answer and which its fault
        for reason in ProveOnMac.demotionReasons { XCTAssertFalse(ProveOnMac.words(reason: reason).isEmpty, reason) }
        XCTAssertEqual(ProveOnMac.demotionReasons, PromotionReason.allCases.map(\.rawValue), "the reasons the pipeline names")
        XCTAssertEqual(ProveOnMac.pipelineFaults, ["crash", "hang", "compile_timeout"])
        XCTAssertEqual(ProveOnMac.words(reason: "golden_mismatch"), "tokens differ")
        XCTAssertEqual(ProveOnMac.still("compiling"), "still compiling")
        XCTAssertEqual(ProveOnMac.still("cpu"), "still waiting for the pipeline to start")
    }

    /// The summary says in words how this SDK stands to the newest release the signed config names.
    func testTheSummarySaysWhenThisSDKIsNewerThanTheNewestRelease() {
        XCTAssertEqual(ProveOnMac.sdkLine(version: "3.0.0", latest: "2.0.2"), "this SDK, 3.0.0, is newer than the newest release, 2.0.2")
        XCTAssertEqual(ProveOnMac.sdkLine(version: "3.0.0", latest: "3.0.0"), "SDK 3.0.0, which is the newest release")
        XCTAssertEqual(ProveOnMac.sdkLine(version: "3.0.0", latest: "3.0.1"), "SDK 3.0.0; a newer release, 3.0.1, is out")
        XCTAssertEqual(ProveOnMac.sdkLine(version: "3.0.0", latest: nil), "SDK 3.0.0")
        XCTAssertEqual(ProveOnMac.sdkLine(version: "3.10.0", latest: "3.9.9"), "this SDK, 3.10.0, is newer than the newest release, 3.9.9", "numbers, not characters")
        XCTAssertEqual(ProveOnMac.compare("3.0", "3.0.0"), 0)
        XCTAssertLessThan(ProveOnMac.compare("2.0.2", "3.0.0"), 0)
    }

    /// Nothing in the output names the key, a token, the app or a folder under the user's home.
    func testNothingPrintedNamesTheKeyTheAppOrAHomeFolder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prove-\(UUID().uuidString).out")
        let out = ProveOut(progress: file, echo: false)
        let key = "qlk_v1_abcdEFGH_0123456789abcdefghijkl"
        out.redact([key, "com.example.reciter", "", "ab"])
        out.say("the key \(key) for com.example.reciter was refused")
        out.say("token qlt_v1.eyJ2IjoxfQ.c2ln and another key qlk_v1_zzzz_AAAAAAAAAAAAAAAAAAAAAA")
        let another = "/Users" + "/someone"  // another account's home folder, as a path in an error could name it
        out.say("model at \(NSHomeDirectory())/Library/Application Support/x and \(another)/Library/y")
        out.say("an ordinary line: 12 of 12 takes, ab")
        let text = out.lines.joined(separator: "\n")
        for secret in [key, "com.example.reciter", "qlt_v1.", "qlk_v1_", NSHomeDirectory(), another] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("an ordinary line: 12 of 12 takes, ab"), "a short string is no secret")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text + "\n", "the file the script follows has the same lines")
    }

    /// The conformance compare is the engine's: FNV-1a 64 of every output of every chunk, the running hash of
    /// `log_probs`, the chunk count and the tokens.
    func testTheConformanceCompareIsTheEnginesHash() throws {
        var chunks: [[String: [Float]]] = []
        for c in 0..<3 {
            chunks.append(["log_probs": (0..<(8 * 38)).map { Float($0 + c) * -0.01 }, "conf": (0..<16).map { Float($0 * c) }])
        }
        var logp = TajweedConformanceTests.fnv0
        for c in chunks { logp = TajweedConformanceTests.fnv(logp, c["log_probs"]!) }
        var out: [String: [String]] = [:]
        for name in ["log_probs", "conf"] {
            out[name] = chunks.map { String(format: "%016llx", TajweedConformanceTests.fnv(TajweedConformanceTests.fnv0, $0[name]!)) }
        }
        let row = ProveRow(clip: "x", chunks: 3, tokens: [3, 4], logpFNV: String(format: "%016llx", logp), outFNV: out)
        let same = ProveOnMac.compare(row, tokens: [3, 4], chunks: chunks)
        XCTAssertEqual(same.mismatches, 0)
        XCTAssertNil(same.why)
        XCTAssertEqual(same.outputs, 6)
        XCTAssertEqual(same.values, 3 * (8 * 38 + 16))
        var other = chunks
        other[1]["log_probs"]![5] += 0.000_001
        let differs = ProveOnMac.compare(row, tokens: [3, 4], chunks: other)
        XCTAssertEqual(differs.mismatches, 2, "the running hash and the chunk's own")
        XCTAssertEqual(ProveOnMac.compare(row, tokens: [3], chunks: chunks).mismatches, 1)
        XCTAssertEqual(ProveOnMac.compare(row, tokens: [3, 4], chunks: Array(chunks.prefix(2))).why, "2 chunks, expected 3")
        // a row file as the engine writes it
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rows-\(UUID().uuidString).jsonl")
        let line: [String: Any] = ["clip": "x", "chunks": 3, "tokens": [3, 4], "logp_fnv": row.logpFNV, "out_fnv": out]
        try (String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self) + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProveOnMac.rows(file), [row])
        XCTAssertNil(ProveOnMac.rows(file.appendingPathExtension("missing")))
        // a clips folder: the clips in audio/, and not the hidden files an archive made on a Mac leaves beside them
        let clips = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: clips.appendingPathComponent("audio"), withIntermediateDirectories: true)
        for name in ["B_002.pcm", "A_001.pcm", "._A_001.pcm", "notes.txt"] {
            try Data(count: 8).write(to: clips.appendingPathComponent("audio/\(name)"))
        }
        XCTAssertEqual(ProveOnMac.clipNames(clips), ["A_001", "B_002"])
        XCTAssertEqual(ProveOnMac.audio(clips, "A_001")?.lastPathComponent, "A_001.pcm")
        XCTAssertNil(ProveOnMac.audio(clips, "C_003"))
        XCTAssertEqual(ProveOnMac.pcm(clips.appendingPathComponent("audio/A_001.pcm")), [0, 0])
        XCTAssertEqual(ProveOnMac.clipNames(clips.appendingPathComponent("none")), [])
    }

    /// The parity's distance and edit count are the golden test's.
    func testTheDistancesAreTheGoldenTests() throws {
        var g = SystemRandomNumberGenerator()
        let frames = 150
        let cpu: [Float] = (0..<(frames * 38)).map { _ in -Float.random(in: 0...35, using: &g) }
        let acc: [Float] = cpu.map { $0 + Float.random(in: -0.4...0.4, using: &g) }
        let d = try XCTUnwrap(ProveOnMac.distances(acc, cpu, classes: 38))
        XCTAssertEqual(d.count, frames)
        let s = ProveOnMac.spread(d)
        let clip = GoldenRaw.Clip(id: "x", clean: true, expectedTokens: nil, cpu: ["log_probs": GoldenRaw.Matrix(cpu, cols: 38)],
                                  accelerator: ["log_probs": GoldenRaw.Matrix(acc, cols: 38)])
        let golden = try XCTUnwrap(GoldenRaw.evaluate([clip], tolerance: nil).ctc["log_probs"].flatMap { $0 })
        XCTAssertEqual(s.mean, golden.lpMean, accuracy: 1e-12)
        XCTAssertEqual(s.p99, golden.lpP99, accuracy: 1e-12)
        XCTAssertNil(ProveOnMac.distances(acc, Array(cpu.dropLast(38)), classes: 38), "another shape")
        for _ in 0..<50 {
            let a = (0..<Int.random(in: 0...12, using: &g)).map { _ in Int.random(in: 1...5, using: &g) }
            let b = (0..<Int.random(in: 0...12, using: &g)).map { _ in Int.random(in: 1...5, using: &g) }
            XCTAssertEqual(ProveOnMac.edits(a, b), Divergence.edits(a, b), "\(a) \(b)")
        }
    }

    // MARK: a rehearsal of the whole run

    /// What the stand-in CPU engine hears in `samples`: its greedy tokens.
    static func standInTokens(_ samples: [Float]) -> [Int] {
        let engine = FakeCPUEngine()
        var heads = HeadsBuffer()
        let pushed = (try? samples.withUnsafeBufferPointer { (p) throws(RecognizerError) in try engine.push(p) }) ?? []
        let flushed = (try? engine.finish()) ?? []
        for c in pushed + flushed { heads.append(c) }
        return heads.greedy
    }

    /// A clips folder for step 5 with two recitations, and the expected rows the stand-in engine gives for them.
    static func clipsFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prove-clips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio"), withIntermediateDirectories: true)
        var lines: [String] = []
        for (i, name) in ["Rehearsal_001", "Rehearsal_002"].enumerated() {
            let samples = fakeRecitation(seconds: 2 + Double(i), seed: i + 3)
            try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("audio/\(name).pcm"))
            let engine = FakeCPUEngine()
            let chunks = try samples.withUnsafeBufferPointer { (p) throws(RecognizerError) in try engine.push(p) } + engine.finish()
            var all = HeadsBuffer()
            var logp = TajweedConformanceTests.fnv0
            var hashes: [String] = []
            for c in chunks {
                all.append(c)
                logp = TajweedConformanceTests.fnv(logp, c.logProbs)
                hashes.append(String(format: "%016llx", TajweedConformanceTests.fnv(TajweedConformanceTests.fnv0, c.logProbs)))
            }
            let row: [String: Any] = ["clip": name, "chunks": chunks.count, "tokens": all.greedy, "logp_fnv": String(format: "%016llx", logp),
                                      "out_fnv": ["log_probs": hashes]]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("v4_c16_l64_audio_expected.jsonl"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The run as the script starts it, against a stub server that serves the bundled test folder, with a stand-in CPU
    /// engine and stand-in pipeline stages: the Client and the config, the download with its progress, the verified
    /// model, the sample clips on the CPU and on the accelerator, both builds through the pipeline with their golden measures,
    /// the conformance clips, diagnose, the summary. Every step passes, and nothing printed names the key or the app.
    func testARehearsalAgainstTheStubServer() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs macOS 15") }
        let server = try Fixtures.v4mini().appendingPathComponent("server")
        let build = String(Manifest30VectorTests.sha256(try Data(contentsOf: server.appendingPathComponent("manifest.json"))).prefix(40))
        let modelKey = try Fixtures.v4miniKey()
        // the newest SDK release the signed config names changes while the run goes on (as it did in the first run on
        // a Mac): 2.0.2 when the run starts, 9.9.9 from step 2 on
        let raised = Locked(false)
        let models = ["Quran-Lab/tajweedformer-v4": build]
        let early = CloudFixtures.config(models: models, extra: ["sdk_latest": ["version": "2.0.2", "severity": "info", "url": "https://x"]])
        let later = CloudFixtures.config(models: models, extra: ["sdk_latest": ["version": "9.9.9", "severity": "info", "url": "https://x"]])
        StubProtocol.reset(CloudFixtures.server(config: early, extra: { s in
            if s.path == "/v1/config" { return raised.withLock { $0 } ? later : early }
            // the CDN: the stored files of the test folder
            guard s.url.host == CloudFixtures.cdn.host, let at = s.path.range(of: "/sdk/v4.0/") else { return nil }
            guard let data = try? Data(contentsOf: server.appendingPathComponent(String(s.path[at.upperBound...]))) else {
                return StubProtocol.Reply(status: 404)
            }
            return StubProtocol.Reply(status: 200, headers: ["content-type": "application/octet-stream"], body: data)
        }))
        // stand-ins: the CPU engine, and a pipeline whose accelerator is that engine and whose golden stage measured this
        var golden = Divergence()
        golden.tokensExpected = 12
        golden.heads = ["log_probs": .some(.init(tokenEdits: 0, lpMean: 0.0123456789, lpP99: 0.4567891, frames: 24)),
                        "inter1_log_probs": .some(.init(tokenEdits: 0, lpMean: 0.02, lpP99: 0.7, frames: 24)),
                        "attr": .some(.init(pMean: 0.00123456, values: 480))]
        // the compact build is judged by a tolerance of its signed manifest, and is inside it
        golden.tolerance = ["log_probs": .init(tokenEdits: 2, lpMean: 0.13, lpP99: 0.5), "inter1_log_probs": .init(tokenEdits: 2, lpMean: 0.16, lpP99: 0.8),
                            "attr": .init(pMean: 0.002)]
        golden.failed = []
        let measures = golden
        // the fp16 build has no tolerance here, and its golden stage finds one token of an intermediate head that
        // differs: not promoted
        var other = golden
        other.tolerance = nil
        other.heads?["inter1_log_probs"] = Divergence.Head(tokenEdits: 1, lpMean: 0.145803, lpP99: 0.288019, frames: 24)
        other.failed = ["inter1_log_probs.token_edits"]
        let differing = other
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        TajweedRecognizer.stagesOverride.withLock {
            $0 = { recognizer in
                // the build is the Session's: `auto` asked for the fp16 one, `coremlCompact` named the compact one
                let compact = recognizer.compact
                return AcceleratorController.Stages(
                    download: { () async throws(PromotionFailure) -> Void in },
                    compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                        // a compile that takes a while, as a real one does
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        return UncheckedBox(FakeAccelerator() as any AcceleratorBackend)
                    },
                    warmup: { (_: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in },
                    golden: { (_: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                        // the compact build passes, the fp16 one differs in a token
                        if compact {
                            return .passed(accelerator: [0.002, 0.002], cpu: [0.008, 0.008], measures: measures)
                        }
                        return .failed(PromotionFailure(.goldenMismatch, "the tokens differ from the CPU engine's (this build has no tolerance): "
                            + "inter1_log_probs.token_edits", divergence: differing))
                    },
                    sessionActive: { () async -> Bool in false },
                    waitIdle: { () async -> Void in })
            }
        }
        defer {
            TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
            TajweedRecognizer.stagesOverride.withLock { $0 = nil }
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }

        let storage = CloudFixtures.storage()
        let clips = try Self.clipsFolder()
        var config = ProveConfig(key: CloudFixtures.key, storage: storage)
        config.clips = clips
        config.expectedRows = clips
        // no version is told to the run: it takes the one the signed config names, as the script does since 3.0.2
        XCTAssertNil(config.expectVersion)
        let version = try ModelManifest.parse(Data(contentsOf: server.appendingPathComponent("manifest.json"))).version
        config.expectBuild = build
        config.contexts = ["c16_l64"]   // the stand-in engine's chunk is 320 ms
        config.builds = ["coreml", "coreml-compact"]   // as the script with --compact: the default build, then the compact one
        config.stillEvery = 0.4
        config.promotionTimeout = 60
        config.takeTimeout = 30
        var doors = ProveDoors.real(trustedKeys: [modelKey])
        // the stand-in engine does not hear the test folder's expected tokens: what it hears is the expectation here
        doors.expectedTokens = { (model: TajweedModel, context: String) -> [String: [Int]]? in
            guard let set = SelfTestSet.load(model.folder.directory, context: context) else { return nil }
            var out: [String: [Int]] = [:]
            for c in set.clips { out[c.id] = ProveOnMacTests.standInTokens(c.samples) }
            return out
        }
        // between step 1 and step 6 the server raises the newest release, and the SDK fetches the config again
        let fetch = doors.fetchSelfTest
        doors.fetchSelfTest = { (model: TajweedModel) async throws -> Int in
            raised.withLock { $0 = true }
            _ = await QuranLab.cloud?.refreshConfig()
            return try await fetch(model)
        }
        let signingKeys = [CloudFixtures.signer.publicKey.rawRepresentation, modelKey]
        // `scripts/prove-on-mac.sh --rehearse` (CI) names a folder: the script then follows this run as it follows a real one
        let work = ProcessInfo.processInfo.environment["QURANLAB_PROVE_REHEARSAL_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        if let work { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
        let out = ProveOut(progress: work?.appendingPathComponent("prove.out"), echo: true)
        let report = await ProveOnMac.run(config, doors: doors, out: out) {
            let options = CloudFixtures.options(signingKeys: signingKeys, storage: storage)
            return try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
                // as `TajweedClient(key:)` does: the launch sequence runs in the background (the config, the update check)
                let cloud = CloudFixtures.cloud(storage: root, options: options)
                Task.detached(priority: .utility) { await cloud.launch() }
                return cloud
            })
        }
        for line in report.summary { print(line) }
        if let work { try Self.write(report, to: work) }

        let verdicts = report.steps.map(\.verdict)
        XCTAssertEqual(verdicts, [.pass, .pass, .pass, .pass, .pass, .pass, .pass], report.steps.map { "\($0.number) \($0.verdict.rawValue) \($0.note)" }.joined(separator: " | "))
        XCTAssertEqual(report.status, 0)
        // step 1 and 2: what the config named is what was downloaded and verified with the folder's key, with progress
        XCTAssertEqual(report.steps[1].note, "model \(version), build \(build)")
        XCTAssertTrue(StubProtocol.seen.contains { $0.path.hasSuffix("/sdk/v4.0/manifest.json") }, "the manifest came from the CDN")
        XCTAssertTrue(out.lines.contains { $0.contains(" MB") && $0.hasPrefix("        ") }, "the download's progress was said")
        // step 3: three sample clips on the CPU engine and on the build that was promoted
        XCTAssertEqual(report.steps[3].note, "coreml-compact 3 of 3, cpu 3 of 3")
        // step 4 passes: the fp16 build stays on the CPU engine because its tokens differ, which is the pipeline's
        // answer, and the compact build, named after it, was promoted
        XCTAssertEqual(report.steps[4].note, "promoted 1 of 2; 1 stayed on the CPU engine: tokens differ")
        XCTAssertEqual(report.measured.map { "\($0.build) \($0.context)" }, ["coreml c16_l64", "coreml-compact c16_l64"])
        XCTAssertEqual(report.measured.map(\.passed), [false, true])
        XCTAssertEqual(report.measured.last?.measures, ProveMeasures(measures))
        XCTAssertEqual(report.measured.first?.measures.ctc["inter1_log_probs"]?.tokenEdits, 1)
        XCTAssertTrue(out.lines.contains("        coreml c16_l64: stays on the CPU engine: tokens differ (golden: the tokens differ from the CPU engine's "
            + "(this build has no tolerance): inter1_log_probs.token_edits)"), out.lines.joined(separator: "\n"))
        // the summary's line about the SDK is the LAST diagnosis's: the newest release changed during the run, and
        // the summary says what the report printed in step 6 says
        XCTAssertTrue(out.lines.contains { $0.contains("\"latest\": \"9.9.9\"") }, "step 6 prints the newest release as it is then")
        XCTAssertTrue(report.summary.contains("SDK \(SDKInfo.version); a newer release, 9.9.9, is out"), report.summary.joined(separator: "\n"))
        XCTAssertFalse(report.summary.contains { $0.contains("newest release, 2.0.2") }, "not what the first config of the run named")
        // each build's golden stage as lines: what was measured next to the signed bound, or that it has none
        let judged = try XCTUnwrap(out.lines.firstIndex(of: "        golden stage, judged by the tolerance the signed manifest gives coreml-compact "
            + "(measured / bound):"), out.lines.joined(separator: "\n"))
        XCTAssertEqual(out.lines[judged + 1], "          log_probs: token_edits 0 / 2, lp_mean 0.012346 / 0.13, lp_p99 0.45679 / 0.5: inside")
        XCTAssertEqual(out.lines[judged + 2], "          inter1_log_probs: token_edits 0 / 2, lp_mean 0.02 / 0.16, lp_p99 0.7 / 0.8: inside")
        XCTAssertEqual(out.lines[judged + 3], "          attr: p_mean 0.001235 / 0.002: inside")
        XCTAssertTrue(out.lines[judged + 4].hasPrefix("          compile "), out.lines[judged + 4])
        let alone = try XCTUnwrap(out.lines.firstIndex(of: "        golden stage, the signed manifest gives coreml no tolerance: identical tokens decided"),
                                  out.lines.joined(separator: "\n"))
        XCTAssertEqual(out.lines[alone + 2], "          inter1_log_probs: token_edits 1 (must be 0): OUTSIDE; lp_mean 0.145803, lp_p99 0.288019 measured, not judged")
        // a compile that takes a while says so
        XCTAssertTrue(out.lines.contains { $0.hasPrefix("        coreml c16_l64: still compiling, 0:0") }, out.lines.joined(separator: "\n"))
        XCTAssertTrue(out.lines.contains { $0.hasPrefix("        coreml-compact c16_l64: still compiling, 0:0") }, out.lines.joined(separator: "\n"))
        // step 5: the two clips, bit for bit on the CPU engine, and the same tokens on the promoted build
        XCTAssertTrue(report.steps[5].note.hasPrefix("CPU: 2 clip takes, "), report.steps[5].note)
        XCTAssertTrue(report.steps[5].note.contains(", 0 mismatches; Neural Engine: 2 clip takes, 0 with other tokens"), report.steps[5].note)
        // the summary ends with the lines to paste back: the steps, the measures as records, then the tolerance made
        // from them, named a proposal for the model side
        let cut = try XCTUnwrap(report.summary.firstIndex(of: "----- paste from here -----"))
        XCTAssertEqual(report.summary[(cut + 1)...].filter { $0.hasPrefix("step ") }.count, 7)
        XCTAssertTrue(report.summary.contains { $0.hasPrefix("these are measurements: the golden stage judges a build by the tolerance") })
        let proposal = try XCTUnwrap(report.summary.firstIndex(of: "\"golden_raw_tolerance\": {"), report.summary.joined(separator: "\n"))
        XCTAssertTrue(report.summary[proposal - 1].hasPrefix("a proposal for the model side, not a tolerance in force"), report.summary[proposal - 1])
        XCTAssertTrue(report.summary[proposal + 1].hasPrefix(" \"coreml\": {") && report.summary[proposal + 1].contains("\"inter1_log_probs\": {\"token_edits\": 1,"),
                      "the fp16 build's token edit is in the proposal: \(report.summary[proposal + 1])")
        XCTAssertTrue(report.summary[proposal + 2].hasPrefix(" \"coreml-compact\": {"), report.summary[proposal + 2])
        XCTAssertEqual(report.summary.last, "}", "the proposal is the last thing printed")
        XCTAssertTrue(report.summary.contains { $0.hasSuffix("2 records, 1 passed") }, report.summary.joined(separator: "\n"))
        let lastRecord = report.summary[proposal - 2]
        XCTAssertTrue(lastRecord.hasPrefix("{\"build\": \"coreml-compact\", \"context\": \"c16_l64\"") && lastRecord.contains("\"passed\": true"), lastRecord)
        XCTAssertTrue(report.summary.contains { $0.hasPrefix("{\"build\": \"coreml\", \"context\": \"c16_l64\"") && $0.contains("\"passed\": false") },
                      "the fp16 build's record, not passed")
        // each record names the model, the clips compared, the verdict and the device, in the server notes' fields
        let wanted = "{\"build\": \"coreml-compact\", \"context\": \"c16_l64\", \"model_version\": \"\(version)\", \"model_build\": \"\(build)\", "
            + "\"clips\": 3, \"clean_clips\": 2, \"tokens_expected\": 12, \"heads\": {\"log_probs\": {\"token_edits\": 0, \"lp_mean\": 0.012346, "
            + "\"lp_p99\": 0.45679, \"frames\": 24}, \"inter1_log_probs\": {\"token_edits\": 0, \"lp_mean\": 0.02, \"lp_p99\": 0.7, \"frames\": 24}, "
            + "\"attr\": {\"p_mean\": 0.001235, \"values\": 480}}, \"passed\": true, \"platform\": \"macos\", "
        XCTAssertTrue(report.summary.contains { $0.hasPrefix(wanted) && $0.contains("\"sdk_version\": \"\(SDKInfo.version)\"}") }, report.summary.joined(separator: "\n"))
        // nothing printed names the key, the app, the storage folder or the home folder
        let printed = (out.lines + report.summary).joined(separator: "\n")
        for secret in [CloudFixtures.key, CloudFixtures.app.bundleID, storage.path, NSHomeDirectory(), "qlt_v1."] {
            XCTAssertFalse(printed.contains(secret), "the output names \(secret.prefix(12))")
        }
    }

    /// A stop says what to do: when the server refuses the key, the run stops at step 1 with the SDK's own error for
    /// the refusal, its message and on the line under it its fix (both from the error catalogue), and the step's line
    /// of the summary carries the fix too.
    func testAKeyTheServerRefusesStopsTheRunWithWhatToDo() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the run's first step needs macOS 15") }
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path == "/v1/attest" ? .json(["error": "developer_not_approved", "message": "the developer account is not approved"], status: 403) : nil
        }))
        defer { QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil) }
        let storage = CloudFixtures.storage()
        var config = ProveConfig(key: CloudFixtures.key, storage: storage)
        config.configTimeout = 20
        let signingKeys = [CloudFixtures.signer.publicKey.rawRepresentation]
        let out = ProveOut(echo: true)
        let report = await ProveOnMac.run(config, doors: .real(), out: out) {
            let options = CloudFixtures.options(signingKeys: signingKeys, storage: storage)
            return try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
                let cloud = CloudFixtures.cloud(storage: root, options: options)
                Task.detached(priority: .utility) { await cloud.launch() }
                return cloud
            })
        }
        for line in report.summary { print(line) }
        XCTAssertEqual(report.steps.map(\.verdict), [.pass, .fail, .notRun, .notRun, .notRun, .notRun, .notRun],
                       report.steps.map { "\($0.number) \($0.verdict.rawValue) \($0.note)" }.joined(separator: " | "))
        XCTAssertEqual(report.status, 1)
        // what the SDK raises for that refusal
        let refused = TajweedError(from: .serverRejected(status: 403, code: "developer_not_approved", message: ""))
        XCTAssertEqual(refused.code, "server_rejected")
        XCTAssertFalse(refused.fix.isEmpty)
        XCTAssertTrue(refused.fix.contains("https://sdk.quranlab.ai/start"), "the catalogue's reason says where to go: \(refused.fix)")
        XCTAssertEqual(refused.message, "The account behind this key has no access to Quran Lab yet (developer_not_approved).")
        let at = try XCTUnwrap(out.lines.firstIndex { $0.hasPrefix("    the server refused the key: ") }, out.lines.joined(separator: "\n"))
        XCTAssertEqual(out.lines[at], "    the server refused the key: server_rejected: \(refused.message)")
        XCTAssertEqual(out.lines[at + 1], "    what to do: \(refused.fix)", "the fix is the line under the message")
        XCTAssertEqual(report.steps[1].note, "the server refused the key: server_rejected: \(refused.message) \(refused.fix)")
        XCTAssertTrue(report.summary.contains { $0.hasPrefix("step 1") && $0.contains("FAIL") && $0.hasSuffix(refused.fix) }, "the summary's line says what to do")
        XCTAssertEqual(report.summary.last, "measures of the golden stage: none (no build reached its golden stage)")
        let printed = (out.lines + report.summary).joined(separator: "\n")
        for secret in [CloudFixtures.key, CloudFixtures.app.bundleID, storage.path, "qlt_v1."] {
            XCTAssertFalse(printed.contains(secret), "the output names \(secret.prefix(12))")
        }
    }

    /// A key that belongs to another app: the API answers it as a refused key (401 `invalid_key`) and names the check
    /// in the answer's `reason`. The run stops at step 1 with that reason's own words, its fix on the line under
    /// them, and what to do about the identifier this run registers as.
    func testAKeyThatBelongsToAnotherAppStopsTheRunWithItsFix() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the run's first step needs macOS 15") }
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path == "/v1/attest" ? .json(["error": "invalid_key", "message": "This key is not valid.", "reason": "app_not_allowed"], status: 401) : nil
        }))
        defer { QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil) }
        let storage = CloudFixtures.storage()
        var config = ProveConfig(key: CloudFixtures.key, storage: storage)
        config.configTimeout = 20
        let signingKeys = [CloudFixtures.signer.publicKey.rawRepresentation]
        let out = ProveOut(echo: true)
        let report = await ProveOnMac.run(config, doors: .real(), out: out) {
            let options = CloudFixtures.options(signingKeys: signingKeys, storage: storage)
            return try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
                let cloud = CloudFixtures.cloud(storage: root, options: options)
                Task.detached(priority: .utility) { await cloud.launch() }
                return cloud
            })
        }
        XCTAssertEqual(report.steps.map(\.verdict), [.pass, .fail, .notRun, .notRun, .notRun, .notRun, .notRun],
                       report.steps.map { "\($0.number) \($0.verdict.rawValue) \($0.note)" }.joined(separator: " | "))
        XCTAssertEqual(report.status, 1)
        let at = try XCTUnwrap(out.lines.firstIndex { $0.hasPrefix("    the server refused the key: ") }, out.lines.joined(separator: "\n"))
        XCTAssertEqual(out.lines[at], "    the server refused the key: server_rejected: This key belongs to another app (app_not_allowed).")
        XCTAssertEqual(out.lines[at + 1], "    what to do: A key works for the first app that used it. Make a key for this app at "
            + "https://sdk.quranlab.ai/keys, or allow this app's identifier on the key's page.")
        XCTAssertEqual(out.lines[at + 2], "    " + ProveOnMac.identifierAdvice, "and what this run can change about itself")
    }

    /// The run registers its app under a name a person recognises on the key's page: the registration's `app_name`
    /// is "SDK proof (Mac)", with the run's app id.
    func testTheRunRegistersUnderANameAPersonRecognises() async throws {
        let config = ProveConfig(key: CloudFixtures.key, appId: "ai.quranlab.sdk.prove", storage: CloudFixtures.storage())
        XCTAssertEqual(config.appName, "SDK proof (Mac)")
        var options = ProveOnMac.options(config)
        XCTAssertEqual(options.cloud?.app?.name, "SDK proof (Mac)")
        XCTAssertEqual(options.cloud?.app?.bundleID, "ai.quranlab.sdk.prove")
        XCTAssertEqual(options.storageDirectory, config.storage)
        // the same configuration over the stub network: what the registration sends
        StubProtocol.reset(CloudFixtures.server())
        options.cloud?.apiURL = CloudFixtures.api
        options.cloud?.urlSession = StubProtocol.session()
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: options)
        let sent = await cloud.register()
        XCTAssertTrue(sent)
        let body = try XCTUnwrap(StubProtocol.seen("/v1/register").last?.json)
        XCTAssertEqual(body["app_name"] as? String, "SDK proof (Mac)")
        XCTAssertEqual(body["bundle_id"] as? String, "ai.quranlab.sdk.prove")
        XCTAssertEqual(body["platform"] as? String, AppIdentity.currentPlatform)
        let attest = try XCTUnwrap(StubProtocol.seen("/v1/attest").first?.json)
        XCTAssertEqual(attest["bundle_id"] as? String, "ai.quranlab.sdk.prove")
        // the identifier is the proof's own: it may be printed, where an app's is not, and the advice names it
        XCTAssertEqual(ProveOnMac.proofIdentifier, "ai.quranlab.sdk.prove")
        let said = ProveOut(echo: false)
        said.redact(["ai.quranlab.sdk.prove", "com.example.reciter"])
        said.say("    " + ProveOnMac.identifierAdvice)
        said.say("    registered as com.example.reciter")
        XCTAssertTrue(said.lines[0].contains("this run registers as ai.quranlab.sdk.prove"), said.lines[0])
        XCTAssertTrue(said.lines[0].contains("Use a key made for the proof, or allow that identifier on the key's page"), said.lines[0])
        XCTAssertFalse(said.lines[1].contains("com.example.reciter"), "an app's identifier is not printed")
        // which build a Session asks for is the public API's: `auto` the fp16 one, `coremlCompact` the compact one
        XCTAssertEqual(ProveOnMac.backend(for: "coreml"), .auto)
        XCTAssertEqual(ProveOnMac.backend(for: "coreml-compact"), .coremlCompact)
        XCTAssertEqual(ProveConfig(key: "k", storage: CloudFixtures.storage()).builds, ["coreml"], "the run takes the default build unless it names more")
    }

    /// The line under a stop, for any SDK error: its `fix`. An error that is not the SDK's is shown as it is.
    func testAStopPrintsTheErrorsFixUnderItsMessage() throws {
        let out = ProveOut(echo: false)
        let missing = TajweedError(.needsConnection)
        XCTAssertFalse(missing.fix.isEmpty)
        let note = ProveOnMac.stop(out, missing)
        XCTAssertEqual(out.lines, ["    needs_connection: \(missing.message)", "    what to do: \(missing.fix)"])
        XCTAssertEqual(note, "needs_connection: \(missing.message) \(missing.fix)")
        // every code of the catalogue has a fix to print
        for code in ErrorCode.allCases {
            let e = TajweedError(code, ["detail": "x", "version": "9.9.9", "needed": "2", "available": "1", "file": "f", "minimum": "m"])
            let lines = ProveOut(echo: false)
            ProveOnMac.stop(lines, e, what: "at a stop: ")
            XCTAssertEqual(lines.lines.count, 2, code.rawValue)
            XCTAssertEqual(lines.lines.first, "    at a stop: \(code.rawValue): \(e.message)")
            XCTAssertEqual(lines.lines.last, "    what to do: \(e.fix)", code.rawValue)
        }
        let plain = ProveOut(echo: false)
        XCTAssertEqual(ProveOnMac.stop(plain, ProveFailure(what: "the folder is gone")), "the folder is gone")
        XCTAssertEqual(plain.lines, ["    the folder is gone"])
    }
}
