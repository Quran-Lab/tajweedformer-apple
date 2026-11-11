import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

final class RegistrationAndConfigTests: XCTestCase {
    func testRegistrationSendsOnlyTheDocumentedFieldsAndTheNewInstallFlag() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let storage = CloudFixtures.storage()
        let first = CloudFixtures.cloud(storage: storage)
        let sent = await first.register()
        XCTAssertTrue(sent)
        let body = try XCTUnwrap(StubProtocol.seen("/v1/register").last?.json)
        XCTAssertEqual(Set(body.keys), ["platform", "bundle_id", "app_name", "app_version", "sdk_version", "new_install"])
        XCTAssertEqual(body["bundle_id"] as? String, "com.example.quran")
        XCTAssertEqual(body["sdk_version"] as? String, SDKInfo.version)
        XCTAssertEqual(body["new_install"] as? Bool, true)
        // the token request carries the app and nothing else
        let attest = try XCTUnwrap(StubProtocol.seen("/v1/attest").first?.json)
        XCTAssertEqual(Set(attest.keys), ["platform", "bundle_id"])

        // the next launch, the next UTC day (2.0.1 registers once a day), is a returning one
        let second = CloudFixtures.cloud(storage: storage, clock: { Date().addingTimeInterval(86_400) })
        _ = await second.register()
        XCTAssertEqual(StubProtocol.seen("/v1/register").last?.json?["new_install"] as? Bool, false)
    }

    func testAnOfflineFirstLaunchStaysNewUntilSent() async throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset { _ in .down }
        let first = CloudFixtures.cloud(storage: storage)
        let sent = await first.register()
        XCTAssertFalse(sent)
        StubProtocol.reset(CloudFixtures.server())
        _ = await CloudFixtures.cloud(storage: storage).register()
        XCTAssertEqual(StubProtocol.seen("/v1/register").last?.json?["new_install"] as? Bool, true,
                       "the first launch's flag must survive the offline launch")
        _ = await CloudFixtures.cloud(storage: storage, clock: { Date().addingTimeInterval(86_400) }).register()
        XCTAssertEqual(StubProtocol.seen("/v1/register").last?.json?["new_install"] as? Bool, false)
    }

    func testAppAttestWhereSupportedAndTokenCaching() async throws {
        StubProtocol.reset(CloudFixtures.server(token: CloudFixtures.attestedToken))
        let storage = CloudFixtures.storage()
        var o = CloudFixtures.options()
        o.cloud?.appleTeamID = "ABCDE12345"
        let cloud = CloudFixtures.cloud(storage: storage, options: o, attester: FakeAttester(isSupported: true))
        let t = try await cloud.tokens!.token()
        XCTAssertTrue(t.attested)
        let body = try XCTUnwrap(StubProtocol.seen("/v1/attest").first?.json)
        XCTAssertEqual(Set(body.keys), ["platform", "bundle_id", "team_id", "key_id", "attestation", "challenge"])
        // the attestation is over SHA-256 of the challenge, as qlab-api checks it
        let challenge = body["challenge"] as! String
        let object = Data(base64Encoded: body["attestation"] as! String)!
        XCTAssertEqual(object, Data("attestation-over-".utf8) + Data(SHA256.hash(data: Data(challenge.utf8))))
        XCTAssertEqual(StubProtocol.seen("/v1/attest/challenge").first?.headers["x-qlab-key"], CloudFixtures.key)

        // cached for 24 h, on disk: another instance asks for nothing
        let before = StubProtocol.seen.count
        let again = CloudFixtures.cloud(storage: storage, options: o, attester: FakeAttester(isSupported: true))
        let t2 = try await again.tokens!.token()
        XCTAssertEqual(t2, t)
        XCTAssertEqual(StubProtocol.seen.count, before)
    }

    func testUnsupportedAppAttestRunsUnattested() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), attester: FakeAttester(isSupported: false))
        let t = try await cloud.tokens!.token()
        XCTAssertFalse(t.attested)
        XCTAssertTrue(StubProtocol.seen("/v1/attest/challenge").isEmpty)
    }

    func testARejectedAttestationFallsBackToUnattested() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            if s.path == "/v1/attest", s.json?["attestation"] != nil {
                return .json(["error": "attestation_failed", "message": "bad"], status: 401)
            }
            return nil
        }))
        var o = CloudFixtures.options()
        o.cloud?.appleTeamID = "ABCDE12345"
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage(), options: o, attester: FakeAttester(isSupported: true))
        let t = try await cloud.tokens!.token()
        XCTAssertFalse(t.attested)
        XCTAssertEqual(StubProtocol.seen("/v1/attest").count, 2)
    }

    func testConfigIsVerifiedAndKept() async throws {
        let storage = CloudFixtures.storage()
        StubProtocol.reset(CloudFixtures.server())
        let cloud = CloudFixtures.cloud(storage: storage)
        let cfg = await cloud.refreshConfig()
        XCTAssertEqual(cfg?.models["Quran-Lab/tajweedformer-v4"]?.revision, "rev-b")
        XCTAssertEqual(cloud.targetRevision(.v4_0), "rev-b")
        // the verified config survives a restart, offline
        StubProtocol.reset { _ in .down }
        let later = CloudFixtures.cloud(storage: storage)
        XCTAssertEqual(later.currentConfig?.models["Quran-Lab/tajweedformer-v4"]?.revision, "rev-b")
        let none = await later.refreshConfig()
        XCTAssertNil(none)
        XCTAssertNotNil(later.currentConfig, "an offline refresh keeps the last verified config")
    }

    func testConfigSignatureFailuresAreRefused() async throws {
        let other = Curve25519.Signing.PrivateKey()
        var tampered = CloudFixtures.config()
        tampered.body = Data(String(decoding: tampered.body, as: UTF8.self).replacingOccurrences(of: "rev-b", with: "rev-x").utf8)
        var unsigned = CloudFixtures.config()
        unsigned.headers["x-qlab-signature"] = nil
        var wrongKid = CloudFixtures.config()
        wrongKid.headers["x-qlab-key-id"] = "0000000000000000"
        let cases: [(String, StubProtocol.Reply)] = [
            ("tampered body", tampered),
            ("another key", CloudFixtures.config(key: other)),
            ("unsigned", unsigned),
            ("unknown key id", wrongKid),
            ("expired", CloudFixtures.config(expires: Int(Date().timeIntervalSince1970) - 10)),
        ]
        for (what, reply) in cases {
            StubProtocol.reset(CloudFixtures.server(config: reply))
            let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
            let cfg = await cloud.refreshConfig()
            XCTAssertNil(cfg, what)
            XCTAssertNil(cloud.currentConfig, what)
            XCTAssertNil(cloud.targetRevision(.v4_0), what)
        }
    }

    func testRolloutBucketIsDrawnOnceAndSent() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let storage = CloudFixtures.storage()
        _ = await CloudFixtures.cloud(storage: storage).refreshConfig()
        _ = await CloudFixtures.cloud(storage: storage).refreshConfig()
        let buckets = StubProtocol.seen("/v1/config").compactMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "bucket" }?.value
        }
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0], buckets[1], "the bucket is kept on the device")
        XCTAssertTrue((0..<100).contains(Int(buckets[0])!))
        // the server applies the rollout; the SDK follows the revision it is given, and a local
        // pin wins over it
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": "rev-old"])))
        let c = CloudFixtures.cloud(storage: storage)
        _ = await c.refreshConfig()
        XCTAssertEqual(c.targetRevision(.v4_0), "rev-old")
        let pinned = CloudFixtures.cloud(storage: storage, options: CloudFixtures.options(updates: .pinned("rev-pin")))
        XCTAssertEqual(pinned.targetRevision(.v4_0), "rev-pin")
    }

    func testDenyListMatching() async throws {
        let rule: [String: Any] = ["platform": "ios", "os_version": "*", "device_class": "*", "sdk_version": "3.*",
                                   "model_revision": "*", "backend_forced": "exact", "reason": "bad fp16 on this build"]
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(deny: [rule])))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        _ = await cloud.refreshConfig()
        let forced = try XCTUnwrap(cloud.forcedBackend(revision: "anything"))
        XCTAssertEqual(forced.backend, .exact)
        XCTAssertTrue(forced.reason.contains("bad fp16"))
        XCTAssertTrue(RemoteConfig.match("18.2*", "18.2.1"))
        XCTAssertFalse(RemoteConfig.match("18.2*", "18.3"))
        XCTAssertTrue(RemoteConfig.match("A12", "A12"))
        XCTAssertFalse(RemoteConfig.match("A12", "A17"))
        // a rule for another platform or SDK does not apply
        let other: [String: Any] = rule.merging(["sdk_version": "9.*"]) { _, b in b }
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(deny: [other])))
        let c2 = CloudFixtures.cloud(storage: CloudFixtures.storage())
        _ = await c2.refreshConfig()
        XCTAssertNil(c2.forcedBackend(revision: "anything"))
    }

    /// GET /v1/config sends the SDK version and If-None-Match; a 304 keeps the stored signed body.
    func testConfigETagAnd304() async throws {
        let reply = CloudFixtures.config()
        let etag = try XCTUnwrap(reply.headers["etag"])
        StubProtocol.reset(CloudFixtures.server(config: reply, extra: { s in
            if s.path == "/v1/config", s.headers["if-none-match"] == etag { return StubProtocol.Reply(status: 304, headers: [:]) }
            return nil
        }))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let first = await cloud.refreshConfig()
        XCTAssertNotNil(first)
        let again = await cloud.refreshConfig()
        XCTAssertEqual(again, first, "a 304 keeps the stored config")
        let seen = StubProtocol.seen("/v1/config")
        XCTAssertEqual(seen.count, 2)
        XCTAssertNil(seen[0].headers["if-none-match"])
        XCTAssertEqual(seen[1].headers["if-none-match"], etag)
        let q = URLComponents(url: seen[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "sdk" }?.value, SDKInfo.version)
    }

    /// A config without a key id is refused: the kid must name a key compiled into the SDK.
    func testConfigWithoutKeyIDIsRefused() async throws {
        var r = CloudFixtures.config()
        r.headers["x-qlab-key-id"] = nil
        StubProtocol.reset(CloudFixtures.server(config: r))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let cfg = await cloud.refreshConfig()
        XCTAssertNil(cfg)
    }

    /// The upload trust tier per platform, and `inference.context`, come through the signed config. Anything but an
    /// object with a string there is ignored and never fails the config.
    func testUploadTrustAndTheInferenceContext() async throws {
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["upload_trust": ["ios": "capped", "macos": "off"]],
                                                                             inference: ["context": "c24_l72"])))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let fetched = await cloud.refreshConfig()
        let cfg = try XCTUnwrap(fetched)
        XCTAssertEqual(UploadTrust.tier(cfg, platform: "ios"), "capped")
        XCTAssertEqual(UploadTrust.tier(cfg, platform: "macos"), "off")
        XCTAssertEqual(UploadTrust.tier(cfg, platform: "windows"), "attested")
        XCTAssertEqual(cfg.inferenceContext, "c24_l72")
        XCTAssertEqual(cfg.models["Quran-Lab/tajweedformer-v4"]?.version, "4.0.0")
        XCTAssertEqual(cloud.targetVersion(.v4_0), "4.0.0")
        let odds: [Any] = ["c16_l64", 3, ["context": 7], ["v": 1], [1, 2]]
        for odd in odds {
            StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(extra: ["inference": odd])))
            let c = CloudFixtures.cloud(storage: CloudFixtures.storage())
            let got = await c.refreshConfig()
            XCTAssertNotNil(got, "\(odd): the config still loads")
            XCTAssertNil(got?.inferenceContext, "\(odd)")
        }
        // a pinned version the server could not serve is named, and Quran Lab's choice stands
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(extra: ["pin": ["version": "4.1.0", "status": "unavailable"]])))
        let pinned = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let withPin = await pinned.refreshConfig()
        XCTAssertEqual(withPin?.pinUnavailable, "4.1.0")
        XCTAssertEqual(pinned.targetRevision(.v4_0), "rev-b")
    }

    /// A pin goes out as `model_version`, and a body fetched with another pin is not confirmed by its ETag.
    func testThePinIsSentWithTheConfigRequest() async throws {
        let reply = CloudFixtures.config()
        let etag = try XCTUnwrap(reply.headers["etag"])
        StubProtocol.reset(CloudFixtures.server(config: reply, extra: { s in
            if s.path == "/v1/config", s.headers["if-none-match"] == etag { return StubProtocol.Reply(status: 304, headers: [:]) }
            return nil
        }))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        _ = await cloud.refreshConfig()
        await cloud.pin(version: "4.0.0")
        await cloud.pin(version: "4.0.0")
        let seen = StubProtocol.seen("/v1/config")
        XCTAssertEqual(seen.count, 2, "the same pin again asks for nothing")
        func query(_ s: StubProtocol.Seen, _ name: String) -> String? {
            URLComponents(url: s.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
        XCTAssertNil(query(seen[0], "model_version"))
        XCTAssertEqual(query(seen[1], "model_version"), "4.0.0")
        XCTAssertNil(seen[1].headers["if-none-match"], "the stored body was asked without the pin")
        await cloud.pin(version: nil)
        let last = try XCTUnwrap(StubProtocol.seen("/v1/config").last)
        XCTAssertNil(query(last, "model_version"))
    }
    /// 403 sdk_too_old at registration stops every network call this launch.
    func testFatalRefusalStopsTheLaunch() async throws {
        StubProtocol.reset(CloudFixtures.server(extra: { s in
            s.path == "/v1/register" ? .json(["error": "sdk_too_old", "message": ""], status: 403) : nil
        }))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let sent = await cloud.register()
        XCTAssertFalse(sent)
        XCTAssertTrue(cloud.isStopped)
        let before = StubProtocol.seen.count
        _ = await cloud.refreshConfig()
        XCTAssertEqual(StubProtocol.seen.count, before)
    }
}

final class AnalyticsAndIssueTests: XCTestCase {
    let day1 = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
    var day2: Date { day1.addingTimeInterval(86_400) }

    private func store(_ storage: URL, enabled: Bool = true, at date: Date) -> AnalyticsStore {
        AnalyticsStore(storage: storage, enabled: enabled,
                       context: .init(platform: "ios", sdkVersion: "3.0.0", appVersion: "2.1", deviceClass: "A17", soc: "a17",
                                      osMajor: 18, ramTier: "8_16"),
                       clock: { date })
    }

    static let build = "8b9e3beb169a41b234eacc93252d7bcc141f0b27"
    static let cpu = TelemetryCohort(revision: "4.0.0", build: build, context: "c16_l64", backend: "cpu")
    static var ane: TelemetryCohort {
        var c = cpu
        c.backend = "ane"
        return c
    }

    static func session(_ c: TelemetryCohort, _ seconds: Double, _ chunks: [Double]) -> AnalyticsEvent {
        .sessionFinished(SessionTelemetry(cohort: c, audioSeconds: seconds, chunkSeconds: chunks, chunkAudioSeconds: 0.32))
    }

    /// The v2 body as SDK 3.0.0 sends it: exactly the documented fields (the server's schema is closed), per cohort the
    /// sums, the histograms and the SDK-measured counters, the app-reported counters with `reported`, the downloads
    /// with their build, nothing identifying, under the 32 KB cap.
    func testDailyAggregatesAndTheirV2Payload() async throws {
        let a = store(CloudFixtures.storage(), at: day1)
        var first = SessionTelemetry(cohort: Self.ane, audioSeconds: 90, chunkSeconds: [0.004, 0.009, 0.012, 0.5], chunkAudioSeconds: 0.32)
        // 35 frames, tokens at frames 1, 2 and 4, and a timing head that hears nothing: those three frames are speech
        // (no padding around a token), 32 are silence
        let ids: [String: [Int]] = ["log_probs": [0, 3, 3, 0, 4] + [Int](repeating: 0, count: 30),
                                    "inter1_log_probs": [0, 3] + [Int](repeating: 0, count: 33)]
        first.count(audioMs: 90_000, selected: ["log_probs", "inter1_log_probs", "timing_log_probs"], computeMicroseconds: 525_400) { ids[$0] ?? [] }
        first.margins = [0.3, 5]
        first.confidences = [0.99]
        a.record(.sessionFinished(first))
        var cancelled = SessionTelemetry(cohort: Self.ane, audioSeconds: 30, chunkSeconds: [0.015], chunkAudioSeconds: 0.32)
        cancelled.counts = false
        a.record(.sessionFinished(cancelled))
        a.record(Self.session(Self.cpu, 60, [0.02]))
        a.record(.fallback(.deadline, cohort: Self.ane))
        a.record(.selfTest(passed: true, cohort: Self.ane))
        a.reportRecited(surah: 112, ayahFrom: 1, ayahTo: 4)
        a.reportChecks(rule: "cons_sub", checked: 10, flagged: 1)
        a.reportChecks(rule: "madd", checked: 4, flagged: 1)
        a.reportChecks(rule: "word", checked: 4, flagged: 1)
        a.reportChecks(rule: "qalqalah", checked: 3, flagged: 0)
        a.reportChecks(rule: "ghunna", checked: 0, flagged: 0)
        a.record(.download(revision: "4.0.0", build: Self.build, profile: "apple-coreml", bytes: 1234, success: true, resumed: true))
        let days = a.pending
        XCTAssertEqual(days.count, 1)
        let p = a.payload(days[0], reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(Set(p.keys), ["v", "day", "product", "platform", "sdk_version", "app_version", "device", "cohorts", "coverage", "downloads",
                                     "report_id", "ayahs", "surah_ayahs", "words", "rule_checks", "rule_flags", "reported"],
                       "the report id, the counters that are not zero, and which of them the app reported")
        XCTAssertEqual(p["report_id"] as? String, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(p["ayahs"] as? Int, 4)
        XCTAssertEqual(p["surah_ayahs"] as? [String: Int], ["112": 4])
        XCTAssertEqual(p["coverage"] as? [String: Int], ["112": 4])
        XCTAssertEqual(p["words"] as? Int, 4)
        XCTAssertEqual(p["rule_checks"] as? [String: Int], ["cons_sub": 10, "madd": 4, "word": 4, "qalqalah": 3], "a rule checked 0 times is not there")
        XCTAssertEqual(p["rule_flags"] as? [String: Int], ["cons_sub": 1, "madd": 1, "word": 1], "only rules with a flag")
        XCTAssertEqual(p["reported"] as? [String], ["ayahs", "surah_ayahs", "coverage", "words", "rule_checks", "rule_flags"])
        XCTAssertEqual(p["v"] as? Int, 2)
        XCTAssertEqual(p["product"] as? String, "apple")
        XCTAssertEqual(p["sdk_version"] as? String, "3.0.0")
        XCTAssertEqual(p["day"] as? String, "2026-09-21")
        let device = try XCTUnwrap(p["device"] as? [String: Any])
        XCTAssertEqual(device["class"] as? String, "A17")
        XCTAssertEqual(device["soc"] as? String, "a17")
        XCTAssertEqual(device["os_major"] as? Int, 18)
        XCTAssertEqual(device["ram_tier"] as? String, "8_16")
        let cohorts = try XCTUnwrap(p["cohorts"] as? [[String: Any]])
        XCTAssertEqual(cohorts.count, 2)
        let ne = try XCTUnwrap(cohorts.first { $0["backend"] as? String == "ane" })
        XCTAssertEqual(ne["revision"] as? String, "4.0.0", "the model version")
        XCTAssertEqual(ne["build"] as? String, Self.build)
        XCTAssertEqual(ne["sessions"] as? Int, 2)
        XCTAssertEqual(ne["aborted"] as? Int, 1, "the cancelled take")
        XCTAssertEqual(ne["minutes"] as? Double, 2)
        XCTAssertEqual(ne["chunks"] as? Int, 5)
        XCTAssertEqual(ne["latency_ms"] as? [String: Int], ["le_5": 1, "le_10": 1, "le_20": 2, "le_40": 0, "le_80": 0, "le_160": 0, "le_320": 0, "gt_320": 1])
        XCTAssertEqual((ne["fallbacks"] as? [String: Int])?["deadline"], 1)
        XCTAssertEqual(ne["self_test"] as? [String: Int], ["pass": 1, "fail": 0])
        XCTAssertEqual((ne["margin"] as? [String: Int])?["le_0_5"], 1)
        XCTAssertEqual((ne["confidence"] as? [String: Int])?["gt_0_95"], 1)
        XCTAssertEqual(ne["takes"] as? Int, 1, "takes = sessions - aborted")
        XCTAssertEqual(ne["audio_s"] as? Double, 90)
        XCTAssertEqual(ne["speech_s"] as? Double, 0.12)
        XCTAssertEqual(ne["silence_s"] as? Double, 1.28)
        XCTAssertEqual(ne["tokens"] as? [String: Int], ["log_probs": 2, "inter1_log_probs": 1], "a selected head without a token is left out")
        XCTAssertEqual(ne["compute_s"] as? Double, 0.525, "whole microseconds, rounded to milliseconds")
        XCTAssertEqual(Set(ne.keys), ["revision", "build", "context", "backend", "sessions", "minutes", "chunks", "aborted", "fallbacks", "self_test",
                                      "latency_ms", "rtf", "cold_start_ms", "model_load_ms", "thermal", "margin", "confidence", "takes", "audio_s",
                                      "speech_s", "silence_s", "tokens", "compute_s"])
        let plain = try XCTUnwrap(cohorts.first { $0["backend"] as? String == "cpu" })
        XCTAssertEqual(plain["takes"] as? Int, 1)
        XCTAssertEqual(Set(plain.keys), ["revision", "build", "context", "backend", "sessions", "minutes", "chunks", "aborted", "fallbacks", "self_test",
                                         "latency_ms", "rtf", "cold_start_ms", "model_load_ms", "thermal", "margin", "confidence", "takes"],
                       "a counter that is zero is left out")
        let dl = try XCTUnwrap((p["downloads"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(dl.keys), ["revision", "build", "profile", "bytes", "success", "failed", "resumed"])
        XCTAssertEqual(dl["revision"] as? String, "4.0.0")
        XCTAssertEqual(dl["build"] as? String, Self.build)
        XCTAssertEqual(dl["profile"] as? String, "apple-coreml")
        XCTAssertEqual(dl["resumed"] as? Int, 1)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: p), as: UTF8.self)
        for banned in ["uuid", "device_id", "install", "idfv", "\"ip\"", "time", "contributor", "locale", "preset", "word_level", "word_bucket",
                       "site_overrides", "checks_on", "classes", "session_flag_pct"] {
            XCTAssertFalse(text.contains(banned), banned)
        }
        XCTAssertLessThan(text.utf8.count, 32 * 1024)
    }

    /// A day on which the app called neither API carries none of the six fields and no `reported`; one field alone is
    /// listed alone.
    func testReportedListsExactlyTheAppReportedFieldsInTheBody() {
        let quiet = store(CloudFixtures.storage(), at: day1)
        quiet.record(Self.session(Self.cpu, 60, [0.01]))
        let q = quiet.payload(quiet.pending[0], reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertNil(q["reported"])
        for f in AnalyticsStore.appReported { XCTAssertNil(q[f], f) }
        let checks = store(CloudFixtures.storage(), at: day1)
        checks.reportChecks(rule: "madd", checked: 5, flagged: 0)
        let c = checks.payload(checks.pending[0], reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(c["reported"] as? [String], ["rule_checks"])
        XCTAssertNil(c["rule_flags"])
        XCTAssertNil(c["words"])
        let words = store(CloudFixtures.storage(), at: day1)
        words.reportChecks(rule: "word", checked: 5, flagged: 2)
        let w = words.payload(words.pending[0], reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(w["reported"] as? [String], ["words", "rule_checks", "rule_flags"])
        let recited = store(CloudFixtures.storage(), at: day1)
        recited.reportRecited(surah: 1, ayahFrom: 1, ayahTo: 7)
        let r = recited.payload(recited.pending[0], reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(r["reported"] as? [String], ["ayahs", "surah_ayahs", "coverage"])
    }
    /// 2.0.1: each send point sends what was counted since the previous one (today included), once.
    func testEachFlushSendsADeltaOfWhatIsNewOnce() async throws {
        let storage = CloudFixtures.storage()
        let a = store(storage, at: day1)
        a.record(Self.session(Self.cpu, 60, [0.01]))
        a.waitForSave()
        let bodies = Locked<[[String: Any]]>([])
        let send = { (d: Data) async throws(CloudError) -> Void in
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            bodies.withLock { $0.append(o) }
        }
        let n0 = await a.flush(send: send)
        XCTAssertEqual(n0, 1, "today is sent as a delta")
        let n1 = await a.flush(send: send)
        XCTAssertEqual(n1, 0, "nothing new, nothing sent")
        a.record(Self.session(Self.cpu, 30, [0.01]))
        let n2 = await a.flush(send: send)
        XCTAssertEqual(n2, 1)
        let sent = bodies.withLock { $0 }
        XCTAssertEqual(sent.count, 2)
        let sessions: [Int] = sent.map { (o: [String: Any]) -> Int in ((o["cohorts"] as? [[String: Any]])?.first?["sessions"] as? Int) ?? -1 }
        XCTAssertEqual(sessions, [1, 1], "the second delta has only what was counted after the first")
        XCTAssertNotEqual(sent[0]["report_id"] as? String, sent[1]["report_id"] as? String)
        XCTAssertTrue(a.pending.isEmpty && a.sealed.isEmpty)
        XCTAssertTrue(store(storage, at: day1).sealed.isEmpty, "sent deltas are gone from disk too")
    }

    func testOfflineKeepsRefusedDropsOldDrops() async throws {
        let storage = CloudFixtures.storage()
        let a = store(storage, at: day1)
        a.record(Self.session(Self.cpu, 60, [0.01]))
        a.waitForSave()
        let b = store(storage, at: day2)
        let n = await b.flush(send: { (_: Data) async throws(CloudError) -> Void in throw CloudError.offline("down") })
        XCTAssertEqual(n, 0)
        XCTAssertEqual(store(storage, at: day2).sealed.count, 1, "an offline flush keeps the sealed delta on disk")
        XCTAssertEqual(store(storage, at: day2).sealed.first?.day, "2026-09-21", "sealed under the day it was counted in")
        let c = store(storage, at: day2)
        _ = await c.flush(send: { (_: Data) async throws(CloudError) -> Void in
            throw CloudError.rejected(status: 400, code: "invalid_body", message: "")
        })
        XCTAssertTrue(store(storage, at: day2).sealed.isEmpty, "a refused delta is dropped, never retried")
        let old = store(storage, at: day1)
        old.record(Self.session(Self.cpu, 60, [0.01]))
        old.waitForSave()
        let late = store(storage, at: day1.addingTimeInterval(9 * 86_400))
        let calls = Locked(0)
        _ = await late.flush(send: { (_: Data) async throws(CloudError) -> Void in calls.withLock { $0 += 1 } })
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertTrue(late.pending.isEmpty && late.sealed.isEmpty, "older than 7 days: deleted unsent")
    }

    func testOffRecordsNothing() {
        let off = store(CloudFixtures.storage(), enabled: false, at: day1)
        off.record(Self.session(Self.cpu, 60, [0.01]))
        XCTAssertTrue(off.pending.isEmpty)
    }

    func testCloudFlushSendsEventsAndIssuesWithTheToken() async throws {
        StubProtocol.reset(CloudFixtures.server())
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        cloud.record(Self.session(Self.cpu, 60, [0.01]))
        cloud.issues.add(QuranLabCloud.issue(kind: "engine_failed", code: "engine:3", app: CloudFixtures.app, backend: .exact, revision: "sha-a"))
        await cloud.flush(includingToday: true)
        let ev = try XCTUnwrap(StubProtocol.seen("/v1/events").first)
        XCTAssertEqual(ev.headers["authorization"], "Bearer qlt_v1.eyJ2IjoxfQ.sig")
        XCTAssertEqual(ev.json?["v"] as? Int, 2)
        XCTAssertEqual(ev.json?["platform"] as? String, "ios")
        let issue = try XCTUnwrap(StubProtocol.seen("/v1/issues").first?.json)
        XCTAssertEqual(Set(issue.keys), ["day", "platform", "sdk_version", "app_version", "os_version", "device_class", "backend", "revision", "kind", "code"])
        XCTAssertEqual(issue["backend"] as? String, "cpu")
        XCTAssertNil(issue["message"], "SDK 2.0.0 never sends free text")
        XCTAssertTrue(cloud.issues.pending.isEmpty)
    }

    /// The kill switch: flags.analytics false sends nothing and drops the queue.
    func testRemoteFlagsTurnUploadsOffAndDropTheQueue() async throws {
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["analytics": false, "issues": false])))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        _ = await cloud.refreshConfig()
        cloud.record(Self.session(Self.cpu, 60, [0.01]))
        await cloud.flush(includingToday: true)
        XCTAssertTrue(StubProtocol.seen("/v1/events").isEmpty)
        XCTAssertTrue(StubProtocol.seen("/v1/issues").isEmpty)
        XCTAssertTrue(cloud.analytics.pending.isEmpty)
    }


    func testIssueQueueIsCappedAndPersisted() async throws {
        let storage = CloudFixtures.storage()
        let q = IssueQueue(storage: storage, cap: 5)
        for i in 0..<8 {
            q.add(QuranLabCloud.issue(kind: "engine_failed", code: "engine:\(i)", app: CloudFixtures.app, backend: .exact, revision: "r"))
        }
        q.add(QuranLabCloud.issue(kind: "engine_failed", code: "engine:7", app: CloudFixtures.app, backend: .exact, revision: "r"))
        XCTAssertEqual(q.pending.map(\.code), ["engine:3", "engine:4", "engine:5", "engine:6", "engine:7"], "oldest dropped, duplicates merged")
        let reopened = IssueQueue(storage: storage, cap: 5)
        XCTAssertEqual(reopened.pending.count, 5)
        // offline part way: what was sent is gone, the rest stays
        var n = 0
        _ = await reopened.flush(send: { (_: Data) async throws(CloudError) -> Void in
            n += 1
            if n > 2 { throw CloudError.offline("down") }
        })
        XCTAssertEqual(IssueQueue(storage: storage, cap: 5).pending.map(\.code), ["engine:5", "engine:6", "engine:7"])
    }

    func testIssueClassificationCarriesNoMessage() {
        let c = IssueQueue.classify(.engineFailed(code: 3, message: "/Users/someone/private/path"))
        XCTAssertEqual(c?.kind, "engine_failed")
        XCTAssertEqual(c?.code, "engine:3")
        XCTAssertNil(IssueQueue.classify(.cancelled))
        XCTAssertNil(IssueQueue.classify(.sessionActive))
    }
}
