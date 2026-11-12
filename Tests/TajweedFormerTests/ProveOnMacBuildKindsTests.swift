import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// The proof (`scripts/prove-on-mac.sh`, `ProveOnMac.run`) on the kinds of build it has to pass on since 3.0.2,
/// rehearsed against the stub server like `ProveOnMacTests.testARehearsalAgainstTheStubServer`, with a stand-in CPU
/// engine and stand-in pipeline stages:
/// - a build with no accelerator for any context (no CoreML files at all, or a package for which the manifest signs
///   no context): the pipeline step says so in one sentence and passes, and nothing is counted as a promotion;
/// - a build without keep tables (SPEC 5.1 and 5.4): the pipeline runs in each context the signed tolerance names,
///   the measures are printed whatever the golden verdict, and the proposal has one entry per build and context
///   under `<build>:<context>`.
/// No model version is told to the run: it takes the one the signed config names.
/// The manifests are the bundled test folder's, changed and signed again with the suite's test key.
final class ProveOnMacBuildKindsTests: XCTestCase {
    /// What the stand-in pipeline ran, in order: `<build> <stage>`.
    let ran = Locked<[String]>([])

    override func tearDown() {
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        TajweedRecognizer.stagesOverride.withLock { $0 = nil }
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// The test folder's manifest.json after `change` (the whole object, and its file lines), signed with the
    /// suite's test key.
    static func manifest(_ change: (_ object: inout [String: Any], _ files: inout [[String: Any]]) -> Void) throws -> Data {
        let url = try Fixtures.v4mini().appendingPathComponent("server").appendingPathComponent("manifest.json")
        var o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try XCTUnwrap(o["files"] as? [[String: Any]])
        change(&o, &files)
        o["files"] = files
        o["signature"] = nil
        let unsigned = try ModelManifest.parse(try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
        o["signature"] = try CloudFixtures.signer.signature(for: Data(unsigned.signedText().utf8)).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// The identical-tokens entry a first build without keep tables signs per context (SPEC 5.1).
    static var identicalTokens: [String: Any] { ["log_probs": ["token_edits": 0, "lp_mean": 30.0, "lp_p99": 30.0]] }

    /// One run of the proof in c16_l64 over a stub that serves `manifest`, with `builds` as the script's builds. The
    /// stand-in golden stage answers `golden(compact)`.
    func rehearse(_ manifest: Data, builds: [String],
                  golden: @escaping @Sendable (_ compact: Bool) -> AcceleratorController.GoldenOutcome) async throws -> (report: ProveReport, out: ProveOut, build: String, records: [String: PromotionRecord]) {
        let build = try OneFileBuildTests.serve(manifest)
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { _ in FakeCPUEngine() } }
        let ran = self.ran
        TajweedRecognizer.stagesOverride.withLock {
            $0 = { recognizer in
                let compact = recognizer.compact
                let name = recognizer.buildKey
                return AcceleratorController.Stages(
                    download: { () async throws(PromotionFailure) -> Void in ran.withLock { $0.append("\(name) download") } },
                    compile: { () async throws(PromotionFailure) -> UncheckedBox<any AcceleratorBackend> in
                        ran.withLock { $0.append("\(name) compile") }
                        return UncheckedBox(FakeAccelerator() as any AcceleratorBackend)
                    },
                    warmup: { (_: UncheckedBox<any AcceleratorBackend>) async throws(PromotionFailure) -> Void in },
                    golden: { (_: UncheckedBox<any AcceleratorBackend>) async -> AcceleratorController.GoldenOutcome in
                        ran.withLock { $0.append("\(name) golden") }
                        return golden(compact)
                    },
                    sessionActive: { () async -> Bool in false },
                    waitIdle: { () async -> Void in })
            }
        }
        let storage = CloudFixtures.storage()
        var config = ProveConfig(key: CloudFixtures.key, storage: storage)
        config.contexts = ["c16_l64"]   // the stand-in engine's chunk is 320 ms
        config.builds = builds
        config.stillEvery = 0.4
        config.promotionTimeout = 60
        config.takeTimeout = 30
        XCTAssertNil(config.expectVersion, "no model version is told to the run")
        let signingKeys = [CloudFixtures.signer.publicKey.rawRepresentation]
        var doors = ProveDoors.real(trustedKeys: signingKeys)
        // the stand-in engine does not hear the test folder's expected tokens: what it hears is the expectation here
        doors.expectedTokens = { (model: TajweedModel, context: String) -> [String: [Int]]? in
            guard let set = SelfTestSet.load(model.folder.directory, context: context) else { return nil }
            var out: [String: [Int]] = [:]
            for c in set.clips { out[c.id] = ProveOnMacTests.standInTokens(c.samples) }
            return out
        }
        let out = ProveOut(echo: true)
        let report = await ProveOnMac.run(config, doors: doors, out: out) {
            let options = CloudFixtures.options(signingKeys: signingKeys, storage: storage)
            return try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { root in
                let cloud = CloudFixtures.cloud(storage: root, options: options)
                Task.detached(priority: .utility) { await cloud.launch() }
                return cloud
            })
        }
        for line in report.summary { print(line) }
        // the promotion records the run left in its storage
        let records = PromotionStore(dir: storage.appendingPathComponent("accelerator")).all()
        return (report, out, build, records)
    }

    static func steps(_ report: ProveReport) -> String {
        report.steps.map { "\($0.number) \($0.verdict.rawValue) \($0.note)" }.joined(separator: " | ")
    }

    /// A build with no accelerator for any context of the run: once with no CoreML file at all, once with both
    /// packages listed and no context signed for them (no keep table and no tolerance). Every step passes (the
    /// conformance step is skipped: no clips folder); the pipeline step says in one sentence that no accelerator
    /// build serves the run's contexts; no pipeline stage ran, nothing was measured or proposed, no promotion
    /// record is kept, nothing of a package was asked of the download server, and no issue was sent.
    func testTheProofPassesOnABuildWithNoAcceleratorForAnyContext() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the run's first step needs macOS 15") }
        let noFiles = try Self.manifest { o, files in
            files.removeAll { DownloadProfile.appleRoles.contains($0["role"] as? String ?? "") }
            o["golden_raw_tolerance"] = nil
            o["revision"] = "v4.0-test.cpu"
        }
        let nothingSigned = try Self.manifest { o, files in
            files.removeAll { ($0["role"] as? String) == "coreml-keeps" }
            o["golden_raw_tolerance"] = nil
            o["revision"] = "v4.0-test.unsigned"
        }
        for (name, manifest) in [("no CoreML file", noFiles), ("packages and no context signed", nothingSigned)] {
            ran.withLock { $0 = [] }
            let version = try ModelManifest.parse(manifest).version
            let r = try await rehearse(manifest, builds: ["coreml", "coreml-compact"]) { _ in .aborted }
            XCTAssertEqual(r.report.steps.map(\.verdict), [.pass, .pass, .pass, .pass, .pass, .skipped, .pass], "\(name): \(Self.steps(r.report))")
            XCTAssertEqual(r.report.status, 0, name)
            XCTAssertEqual(r.report.steps[1].note, "model \(version), build \(r.build)", "\(name): the version is the one the signed config names")
            XCTAssertEqual(r.report.steps[3].note, "cpu 3 of 3", name)
            let sentence = "no accelerator build serves the contexts of this run (c16_l64): every context runs on the CPU engine, and there is nothing to promote"
            XCTAssertEqual(r.report.steps[4].note, sentence, name)
            XCTAssertTrue(r.out.lines.contains("    the promotion pipeline: \(sentence)"), "\(name): the run says it when it gets there")
            XCTAssertTrue(r.report.summary.contains { $0.hasPrefix("step 4  the promotion pipeline") && $0.contains("PASS  \(sentence)") },
                          "\(name): \(r.report.summary.joined(separator: "\n"))")
            XCTAssertEqual(ran.withLock { $0 }, [], "\(name): no pipeline stage ran")
            XCTAssertEqual(r.report.measured, [], name)
            XCTAssertTrue(r.report.summary.contains("measures of the golden stage: none (no build reached its golden stage)"), name)
            XCTAssertFalse(r.report.summary.contains("\"golden_raw_tolerance\": {"), "\(name): nothing measured, nothing proposed")
            XCTAssertTrue(r.report.summary.contains { $0.contains("builds through the pipeline 0 (0 promoted)") }, name)
            XCTAssertTrue(r.records.isEmpty, "\(name): no promotion record: \(r.records.keys.sorted())")
            XCTAssertFalse(OneFileBuildTests.fetched.contains { $0.hasPrefix("coreml") }, "\(name): nothing of a package was asked for")
            XCTAssertEqual(StubProtocol.seen("/v1/issues").count, 0, "\(name): no issue or incident was sent")
            XCTAssertTrue(r.out.lines.contains { $0.contains("\"backend\": {\"kind\": \"cpu\", \"name\": \"cpu\", \"stage\": \"cpu\", \"reason\": null}") },
                          "\(name): diagnose reports the CPU engine")
            QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
        }
    }

    /// The measures of a stand-in golden stage: three CTC heads and the attribute heads, judged by the
    /// identical-tokens entry (which bounds `log_probs` only).
    static func divergence(edits: Int) -> Divergence {
        var d = Divergence()
        d.tokensExpected = 12
        d.heads = ["log_probs": .some(.init(tokenEdits: 0, lpMean: 0.0123456789, lpP99: 0.4567891, frames: 24)),
                   "inter1_log_probs": .some(.init(tokenEdits: edits, lpMean: 0.02 + Double(edits) * 0.1, lpP99: 0.7, frames: 24)),
                   "attr": .some(.init(pMean: 0.00123456, values: 480))]
        d.tolerance = ["log_probs": .init(tokenEdits: 0, lpMean: 30, lpP99: 30)]
        d.failed = edits == 0 ? [] : ["inter1_log_probs.token_edits"]
        return d
    }

    /// A build without keep tables whose manifest signs the identical-tokens entry for c16_l64 under
    /// `coreml:c16_l64` and `coreml-compact:c16_l64`. The pipeline runs for both builds; the fp16 one differs by a
    /// token and is demoted with `golden_mismatch`, which is a pass of the step; its measures are printed and
    /// recorded like the promoted build's; the proposal has one entry per build and context under
    /// `<build>:<context>`, each what was measured there, and its line of words says so and why.
    func testTheProofOnABuildWithoutKeepTablesMeasuresAndProposesPerContext() async throws {
        guard DownloadProfile.osRunsCoreML else { throw XCTSkip("the promotion needs macOS 15") }
        let manifest = try Self.manifest { o, files in
            files.removeAll { ($0["role"] as? String) == "coreml-keeps" }
            o["golden_raw_tolerance"] = ["coreml:c16_l64": Self.identicalTokens, "coreml-compact:c16_l64": Self.identicalTokens] as [String: Any]
            o["revision"] = "v4.0-test.onefile"
        }
        let passing = Self.divergence(edits: 0), differing = Self.divergence(edits: 1)
        let r = try await rehearse(manifest, builds: ["coreml", "coreml-compact"]) { compact in
            if compact { return .passed(accelerator: [0.002, 0.002], cpu: [0.008, 0.008], measures: passing) }
            return .failed(PromotionFailure(.goldenMismatch, "outside the signed tolerance: inter1_log_probs.token_edits", divergence: differing))
        }
        XCTAssertEqual(r.report.steps.map(\.verdict), [.pass, .pass, .pass, .pass, .pass, .skipped, .pass], Self.steps(r.report))
        XCTAssertEqual(r.report.status, 0)
        // both builds went through the pipeline in the context the tolerance names; a demotion for golden_mismatch
        // is the pipeline's answer and the step passes
        XCTAssertEqual(ran.withLock { $0 }.filter { $0.hasSuffix(" golden") }, ["coreml golden", "coreml-compact golden"])
        XCTAssertEqual(r.report.steps[4].note, "promoted 1 of 2; 1 stayed on the CPU engine: outside the tolerance")
        XCTAssertEqual(r.report.steps[3].note, "coreml-compact 3 of 3, cpu 3 of 3")
        // the measures of both, whatever the verdict, each marked as measured under its own key
        XCTAssertEqual(r.report.measured.map { "\($0.build) \($0.context)" }, ["coreml c16_l64", "coreml-compact c16_l64"])
        XCTAssertEqual(r.report.measured.map(\.passed), [false, true])
        XCTAssertEqual(r.report.measured.map(\.keyed), [true, true])
        XCTAssertEqual(r.report.measured.first?.measures.ctc["inter1_log_probs"]?.tokenEdits, 1)
        for build in ["coreml", "coreml-compact"] {
            XCTAssertTrue(r.out.lines.contains("        golden stage, judged by the tolerance the signed manifest gives \(build):c16_l64 (measured / bound):"),
                          "\(build): \(r.out.lines.joined(separator: "\n"))")
        }
        XCTAssertTrue(r.report.summary.contains { $0.hasSuffix("2 records, 1 passed") }, r.report.summary.joined(separator: "\n"))
        XCTAssertTrue(r.report.summary.contains { $0.hasPrefix("{\"build\": \"coreml\", \"context\": \"c16_l64\"") && $0.contains("\"passed\": false") })
        // the proposal: per build and context, under <build>:<context>, and it says so
        let field = try XCTUnwrap(r.report.summary.firstIndex(of: "\"golden_raw_tolerance\": {"), r.report.summary.joined(separator: "\n"))
        XCTAssertEqual(r.report.summary[field - 1], ProveOnMac.proposalPerContext)
        XCTAssertTrue(r.report.summary[field - 1].hasPrefix("a proposal for the model side, not a tolerance in force"))
        XCTAssertTrue(r.report.summary[field + 1].hasPrefix(" \"coreml:c16_l64\": {") && r.report.summary[field + 1].contains("\"inter1_log_probs\": {\"token_edits\": 1,"),
                      r.report.summary[field + 1])
        XCTAssertTrue(r.report.summary[field + 2].hasPrefix(" \"coreml-compact:c16_l64\": {"), r.report.summary[field + 2])
        XCTAssertEqual(r.report.summary[field + 3], "}")
        XCTAssertEqual(r.report.summary.last, "}", "the proposal is the last thing printed")
        XCTAssertFalse(r.report.summary.contains(ProveOnMac.proposalPerBuild), "no entry per build: this build has no keep tables")
        // each build's record is the record of `coreml` / `coreml-compact` in c16_l64, never of the tolerance key
        XCTAssertEqual(r.records.count, 2, "\(r.records.keys.sorted())")
        XCTAssertFalse(r.records.keys.contains { $0.contains(":c16_l64") }, "\(r.records.keys.sorted())")
    }

    /// The proposal's two forms, on records alone. With keep tables: one entry per build under the plain key, the
    /// largest over its contexts, and the line of words it always had. Without: one entry per build and context
    /// under `<build>:<context>`, each what was measured there (not the largest), under a line that says which form
    /// it is and why. Both paste into a manifest and are well formed for the SDK's own manifest reader. A run that
    /// measured both kinds prints both lines and both kinds of entry.
    func testTheProposalIsPerBuildWithKeepTablesAndPerContextWithout() throws {
        func record(_ build: String, _ context: String, _ scale: Double, keyed: Bool) -> ProveMeasured {
            ProveMeasured(build: build, context: context, measures: ProveOnMacTests.measures(scale), keyed: keyed)
        }
        func field(_ lines: [String], from start: Int) throws -> [String: Any] {
            let json = "{" + lines[start...].joined(separator: "\n") + "}"
            return try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["golden_raw_tolerance"] as? [String: Any])
        }
        // with keep tables: as since 3.0.0, line for line
        let tables = [record("coreml", "c16_l64", 1, keyed: false), record("coreml", "c24_l72", 1.5, keyed: false),
                      record("coreml-compact", "c16_l64", 3, keyed: false)]
        var lines = ProveOnMac.proposalBlock(tables)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "a proposal for the model side, not a tolerance in force: per build the largest value of each measure over the "
            + "records above, no margin added (the margin and the signing are the model side's)")
        XCTAssertEqual(lines[0], ProveOnMac.proposalPerBuild)
        XCTAssertEqual(Set(try field(lines, from: 1).keys), ["coreml", "coreml-compact"])

        // without keep tables: per build and context
        var failed = record("coreml-compact", "c24_l72", 2, keyed: true)
        failed.passed = false
        let keyed = [record("coreml", "c16_l64", 1, keyed: true), record("coreml", "c24_l72", 1.5, keyed: true),
                     record("coreml-compact", "c16_l64", 3, keyed: true), failed]
        lines = ProveOnMac.proposalBlock(keyed)
        XCTAssertEqual(lines.count, 7, "one line of words, the field, one line per build and context, the closing brace")
        XCTAssertEqual(lines[0], ProveOnMac.proposalPerContext)
        XCTAssertTrue(lines[0].contains("<build>:<context>") && lines[0].contains("because this build has no keep tables"), lines[0])
        XCTAssertEqual(lines[1], "\"golden_raw_tolerance\": {")
        XCTAssertEqual(lines[6], "}")
        let perContext = try field(lines, from: 1)
        XCTAssertEqual(Set(perContext.keys), ["coreml:c16_l64", "coreml:c24_l72", "coreml-compact:c16_l64", "coreml-compact:c24_l72"])
        let parsed = GoldenRawTolerance.parse(JSONValue(any: perContext))
        XCTAssertEqual(parsed.bad, [], "every entry is well formed")
        for m in keyed {
            // each entry is its own context's measures: the record is inside it, and it is not the largest of the build
            let t = try XCTUnwrap(parsed.good["\(m.build):\(m.context)"], "\(m.build) \(m.context)")
            let own = try XCTUnwrap(m.measures.ctc["log_probs"])
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(t.heads["log_probs"]).lpMean, own.lpMean)
            XCTAssertLessThan(try XCTUnwrap(t.heads["log_probs"]).lpMean - own.lpMean, 0.000_001_5, "\(m.build) \(m.context): its own measure, no margin")
        }
        XCTAssertLessThan(try XCTUnwrap(parsed.good["coreml:c16_l64"]?.heads["log_probs"]).lpMean,
                          try XCTUnwrap(parsed.good["coreml:c24_l72"]?.heads["log_probs"]).lpMean, "not one value for the build")

        // a run that measured both kinds
        lines = ProveOnMac.proposalBlock([record("coreml", "c16_l64", 1, keyed: false), record("coreml", "c24_l72", 2, keyed: true)])
        XCTAssertEqual(Array(lines.prefix(3)), [ProveOnMac.proposalPerBuild, ProveOnMac.proposalPerContext, "\"golden_raw_tolerance\": {"])
        XCTAssertEqual(Set(try field(lines, from: 2).keys), ["coreml", "coreml:c24_l72"])
        XCTAssertEqual(lines.last, "}")
    }

    /// The script names no model version: the version a run expects is the caller's (QURANLAB_EXPECT_VERSION) or the
    /// one the signed config names.
    func testTheScriptNamesNoModelVersion() throws {
        let script = Fixtures.repo.appendingPathComponent("scripts/prove-on-mac.sh")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { throw XCTSkip("the script is not in this checkout") }
        XCTAssertNil(text.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression).map { String(text[$0]) }, "a version is written into the script")
        XCTAssertTrue(text.contains("QURANLAB_EXPECT_VERSION:-any"), "unset, the run takes the version the signed config names")
    }
}
