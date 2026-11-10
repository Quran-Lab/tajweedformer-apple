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
        let rule: [String: Any] = ["platform": "ios", "os_version": "*", "device_class": "*", "sdk_version": "2.*",
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
        XCTAssertEqual(q.first { $0.name == "sdk" }?.value, "2.0.1")
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

    /// The upload trust tier per platform, and the tajweed block with its word level, come through the signed config.
    func testUploadTrustAndTajweedBlock() async throws {
        StubProtocol.reset(CloudFixtures.server(config: CloudFixtures.config(flags: ["upload_trust": ["ios": "capped", "macos": "off"]],
                                                                             tajweed: ["v": 1, "preset": "strict", "word": ["preset": "beginner"]])))
        let cloud = CloudFixtures.cloud(storage: CloudFixtures.storage())
        let fetched = await cloud.refreshConfig()
        let cfg = try XCTUnwrap(fetched)
        XCTAssertEqual(UploadTrust.tier(cfg, platform: "ios"), "capped")
        XCTAssertEqual(UploadTrust.tier(cfg, platform: "macos"), "off")
        XCTAssertEqual(UploadTrust.tier(cfg, platform: "windows"), "attested")
        let block = try XCTUnwrap(RemoteTajweedBlock.parse(cfg.tajweed).block)
        XCTAssertEqual(block.preset, .strict)
        XCTAssertEqual(block.word, .beginner)
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
                       context: .init(platform: "ios", sdkVersion: "2.0.0", appVersion: "2.1", deviceClass: "A17", soc: "a17",
                                      osMajor: 18, ramTier: "8_16"),
                       clock: { date })
    }

    static let cpu = TelemetryCohort(revision: "rev-a", context: "c16_l64", backend: "cpu", preset: "balanced", wordLevel: "general",
                                     wordBucket: "", siteOverrides: 1)
    static var ane: TelemetryCohort {
        var c = cpu
        c.backend = "ane"
        return c
    }

    static func session(_ c: TelemetryCohort, _ seconds: Double, _ chunks: [Double]) -> AnalyticsEvent {
        .sessionFinished(SessionTelemetry(cohort: c, audioSeconds: seconds, chunkSeconds: chunks, chunkAudioSeconds: 0.32,
                                          checksOn: ["letters", "vowels"], throttled: false, thermalTransitions: 0, coldStartMs: nil))
    }

    /// The v2 body: exactly the documented fields, per cohort sums and histograms, coverage and downloads, nothing
    /// identifying, under the 32 KB cap.
    func testDailyAggregatesAndTheirV2Payload() async throws {
        let a = store(CloudFixtures.storage(), at: day1)
        a.record(Self.session(Self.ane, 90, [0.004, 0.009, 0.012, 0.5]))
        a.record(Self.session(Self.ane, 30, [0.015]))
        a.record(Self.session(Self.cpu, 60, [0.02]))
        a.record(.fallback(.deadline, cohort: Self.ane))
        a.record(.selfTest(passed: true, cohort: Self.ane))
        var sc = ScoreTelemetry(cohort: Self.ane, surah: 112)
        sc.classes["cons_sub"] = .init(sites: 10, flagged: 1)
        sc.maddCounts = [2: 3, 4: 1]
        sc.maddFlagged = 1
        sc.wordsScored = 4
        sc.wordsFlagged = 1
        sc.margins = [0.3, 5]
        sc.confidences = [0.99]
        a.record(.scored(sc))
        a.record(.download(revision: "rev-b", profile: "apple-coreml", bytes: 1234, success: true, resumed: true))
        let days = a.pending
        XCTAssertEqual(days.count, 1)
        let p = a.payload(days[0], reportID: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(Set(p.keys), ["v", "day", "product", "platform", "sdk_version", "app_version", "device", "cohorts", "coverage", "downloads",
                                     "report_id", "ayahs", "surah_ayahs", "words", "rule_checks", "rule_flags"],
                       "2.0.1: the report id, and the counters that are not zero")
        XCTAssertEqual(p["report_id"] as? String, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(p["ayahs"] as? Int, 1)
        XCTAssertEqual(p["surah_ayahs"] as? [String: Int], ["112": 1])
        XCTAssertEqual(p["words"] as? Int, 4)
        XCTAssertEqual(p["rule_checks"] as? [String: Int], ["cons_sub": 10, "madd": 4, "word": 4])
        XCTAssertEqual(p["rule_flags"] as? [String: Int], ["cons_sub": 1, "madd": 1, "word": 1])
        XCTAssertEqual(p["v"] as? Int, 2)
        XCTAssertEqual(p["product"] as? String, "apple")
        XCTAssertEqual(p["day"] as? String, "2026-09-21")
        let device = try XCTUnwrap(p["device"] as? [String: Any])
        XCTAssertEqual(device["class"] as? String, "A17")
        XCTAssertEqual(device["soc"] as? String, "a17")
        XCTAssertEqual(device["os_major"] as? Int, 18)
        XCTAssertEqual(device["ram_tier"] as? String, "8_16")
        let cohorts = try XCTUnwrap(p["cohorts"] as? [[String: Any]])
        XCTAssertEqual(cohorts.count, 2)
        let ne = try XCTUnwrap(cohorts.first { $0["backend"] as? String == "ane" })
        XCTAssertEqual(ne["sessions"] as? Int, 2)
        XCTAssertEqual(ne["minutes"] as? Double, 2)
        XCTAssertEqual(ne["chunks"] as? Int, 5)
        XCTAssertEqual(ne["latency_ms"] as? [String: Int], ["le_5": 1, "le_10": 1, "le_20": 2, "le_40": 0, "le_80": 0, "le_160": 0, "le_320": 0, "gt_320": 1])
        XCTAssertEqual((ne["fallbacks"] as? [String: Int])?["deadline"], 1)
        XCTAssertEqual(ne["self_test"] as? [String: Int], ["pass": 1, "fail": 0])
        XCTAssertEqual((ne["classes"] as? [String: [String: Int]])?["cons_sub"], ["sites": 10, "flagged": 1])
        XCTAssertEqual(ne["madd"] as? [String: Int], ["c2": 3, "c4": 1, "c6": 0, "flagged": 1])
        XCTAssertEqual(ne["words"] as? [String: Int], ["scored": 4, "flagged": 1])
        XCTAssertEqual((ne["session_flag_pct"] as? [String: Int])?["le_10"], 1)
        XCTAssertEqual((ne["margin"] as? [String: Int])?["le_0_5"], 1)
        XCTAssertEqual((ne["confidence"] as? [String: Int])?["gt_0_95"], 1)
        XCTAssertEqual((ne["checks_on"] as? [String: Int])?["letters"], 2)
        XCTAssertEqual(Set(ne.keys), ["revision", "context", "backend", "preset", "word_level", "word_bucket", "site_overrides",
                                      "sessions", "minutes", "chunks", "aborted", "fallbacks", "self_test", "latency_ms", "rtf",
                                      "cold_start_ms", "model_load_ms", "thermal", "checks_on", "classes", "session_flag_pct",
                                      "margin", "confidence", "madd", "words"])
        XCTAssertEqual(p["coverage"] as? [String: Int], ["112": 1])
        let dl = try XCTUnwrap((p["downloads"] as? [[String: Any]])?.first)
        XCTAssertEqual(dl["profile"] as? String, "apple-coreml")
        XCTAssertEqual(dl["resumed"] as? Int, 1)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: p), as: UTF8.self)
        for banned in ["uuid", "device_id", "install", "idfv", "\"ip\"", "time", "contributor", "locale"] { XCTAssertFalse(text.contains(banned), banned) }
        XCTAssertLessThan(text.utf8.count, 32 * 1024)
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
