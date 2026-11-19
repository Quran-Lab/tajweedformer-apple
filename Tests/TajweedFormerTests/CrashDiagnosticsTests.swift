import XCTest
@testable import TajweedFormer

/// SDK 4.0's crash evidence: MetricKit's call stack tree read innermost first, the app's own frames never named, the
/// report inside the server's schema and its 4,096-byte cap, and the sentinel's heartbeat when there is no diagnostic.
/// The payload delivery itself (MXMetricManager) is checked on a device: Xcode's Debug > Simulate MetricKit Payloads,
/// and a real crash (the Mac prompt's step).
final class CrashDiagnosticsTests: XCTestCase {
    static let uuidCoreML = "6F8E1C2A-1B3D-4E5F-8A9B-0C1D2E3F4A5B"
    static let uuidApp = "11111111-2222-3333-4444-555555555555"

    /// A crashing thread as MetricKit writes it (callStackPerThread, one chain of subFrames).
    static func tree(outermostFirst: Bool = false) -> Data {
        var chain: [[String: Any]] = [
            ["binaryName": "CoreML", "binaryUUID": uuidCoreML, "offsetIntoBinaryTextSegment": 123_456, "sampleCount": 1],
            ["binaryName": "Espresso", "binaryUUID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "offsetIntoBinaryTextSegment": 7_890, "sampleCount": 1],
            ["binaryName": "MyQuranApp", "binaryUUID": uuidApp, "offsetIntoBinaryTextSegment": 42, "sampleCount": 1],
            ["binaryName": "dyld", "binaryUUID": "99999999-8888-7777-6666-555555555555", "offsetIntoBinaryTextSegment": 1, "sampleCount": 1],
        ]
        if outermostFirst { chain.reverse() }
        var node: [String: Any]? = nil
        for f in chain.reversed() {
            var n = f
            if let node { n["subFrames"] = [node] }
            node = n
        }
        let other: [String: Any] = ["threadAttributed": false, "callStackRootFrames": [["binaryName": "libsystem_kernel.dylib",
                                                                                          "offsetIntoBinaryTextSegment": 5]]]
        let crashing: [String: Any] = ["threadAttributed": true, "callStackRootFrames": [node!]]
        return try! JSONSerialization.data(withJSONObject: ["callStackPerThread": true, "callStacks": [other, crashing]])
    }

    func testTheCrashingThreadIsReadInnermostFirst() {
        for outer in [false, true] {
            let f = CrashStacks.crashingThread(Self.tree(outermostFirst: outer))
            XCTAssertEqual(f.map(\.binary), ["CoreML", "Espresso", "MyQuranApp", "dyld"], "outermost first in: \(outer)")
            XCTAssertEqual(f.first?.offset, 123_456)
        }
    }

    func testTheAppsFramesAreNeverNamedAndImagesCarryUUIDs() {
        let f = CrashStacks.crashingThread(Self.tree())
        let d = CrashStacks.describe(f, app: "MyQuranApp", resolve: { fr in
            fr.binary == "CoreML" ? ("-[MLE5ProgramLibrary _programLibraryHandleWithForceRespecialization:error:]", 48)
                : fr.binary == "MyQuranApp" ? ("$s10MyQuranApp12SecretScreenC4loadyyF", 8) : nil
        })
        XCTAssertEqual(d.frames, ["CoreML!-[MLE5ProgramLibrary _programLibraryHandleWithForceRespecialization:error:]+48",
                                  "Espresso+0x1ed2", "app+0x2a", "dyld+0x1"])
        XCTAssertEqual(d.images.first, "CoreML:6F8E1C2A1B3D4E5F8A9B0C1D2E3F4A5B")
        XCTAssertFalse(d.images.contains { $0.hasPrefix("app") || $0.contains("11111111") }, "the app's binary is not listed")
        // the SDK's own symbols in the app's binary are kept
        let sdk = CrashStacks.describe([CrashFrame(binary: "MyQuranApp", uuid: Self.uuidApp, offset: 9)], app: "MyQuranApp",
                                       resolve: { _ in ("$s13TajweedFormer21AcceleratorControllerC4warm", 4) })
        XCTAssertEqual(sdk.frames, ["app!$s13TajweedFormer21AcceleratorControllerC4warm+4"])
    }

    func testAMatchedCrashBecomesTheEvidence() {
        var s = PromotionStore.Sentinel(key: "k", stage: .warmup)
        s.pid = 4242
        s.at = Date(timeIntervalSince1970: 1_000)
        s.heartbeat = Date(timeIntervalSince1970: 1_013)
        s.osBuild = "26C5035r"
        s.footprintMB = 812
        s.foreground = true
        let c = CrashDiagnostics.Crash(pid: 4242, begin: Date(timeIntervalSince1970: 900), end: Date(timeIntervalSince1970: 1_100),
                                       osBuild: "26C5035r", exceptionType: 1, exceptionCode: 0, signal: 11,
                                       termination: "Namespace SIGNAL, Code 11 Segmentation fault: 11 at /Users/someone/x 1234567",
                                       objcException: nil, frames: CrashStacks.crashingThread(Self.tree()))
        let e = CrashDiagnostics.evidence(s, (c, "pid"), app: "MyQuranApp")
        XCTAssertEqual(e.exit, "crash")
        XCTAssertEqual(e.match, "pid")
        XCTAssertEqual(e.signal, 11)
        XCTAssertEqual(e.exceptionType, 1)
        XCTAssertEqual(e.osBuild, "26C5035r")
        XCTAssertEqual(e.stageSeconds, 13)
        XCTAssertEqual(e.footprintMB, 812)
        let t = e.termination ?? ""
        XCTAssertFalse(t.contains("/Users") || t.contains("1234567"), t)
        XCTAssertEqual(e.frames?.count, 4)
        // no diagnostic: what the sentinel saw
        var bg = s
        bg.foreground = false
        XCTAssertEqual(CrashDiagnostics.evidence(bg, nil, app: nil).exit, "background")
        var q = s
        q.quit = true
        XCTAssertEqual(CrashDiagnostics.evidence(q, nil, app: nil).exit, "quit")
        XCTAssertEqual(CrashDiagnostics.evidence(s, nil, app: nil).exit, "unknown")
        XCTAssertEqual(CrashDiagnostics.build(of: "macOS 27.3 (26C5035r)"), "26C5035r")
        XCTAssertEqual(CrashDiagnostics.build(of: "iPhone OS 27.0.1 (24A446)"), "24A446")
    }

    /// The largest crash a report can carry stays under the server's 4,096 bytes, with the keys its schema takes.
    func testTheLargestReportFitsTheServersCap() throws {
        Fixtures.configure()
        var e = CrashEvidence(exit: "crash")
        e.match = "pid"; e.exceptionType = 1; e.exceptionCode = 2; e.signal = 11
        e.termination = String(repeating: "x", count: 300)
        e.objcException = "NSInvalidArgumentException"
        e.osBuild = "26C5035r"; e.footprintMB = 1_900; e.headroomMB = 120; e.stageSeconds = 61.5
        e.images = (0..<20).map { "Binary\($0):" + String(repeating: "A", count: 32) }
        e.frames = (0..<40).map { "Binary\($0)!" + String(repeating: "s", count: 200) + "+12" }
        var inc = AcceleratorIncident(kind: .promotionFailed, stage: "warmup", cause: "crash_on_last_run", message: "the app stopped during the warmup stage",
                                      revision: "4.0.0", build: String(repeating: "b", count: 40), context: "c16_l64")
        inc.crash = e
        inc.foreground = true
        let r = QuranLabCloud.incidentReport(inc, app: IncidentTests.app, chip: "m5", deviceModel: "Mac17,12", osBuild: "26C5035r")
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let data = try enc.encode(r)
        XCTAssertLessThanOrEqual(data.count, 3_900)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        IncidentTests.validate(body)
        let c = try XCTUnwrap((body["detail"] as? [String: Any])?["crash"] as? [String: Any])
        let keys: Set<String> = ["exit", "match", "exception_type", "exception_code", "signal", "termination", "objc_exception", "os_build",
                                 "footprint_mb", "headroom_mb", "stage_s", "images", "frames"]
        XCTAssertTrue(Set(c.keys).isSubset(of: keys), "\(Set(c.keys).subtracting(keys))")
        XCTAssertLessThanOrEqual((c["frames"] as? [String])?.count ?? 0, 12)
        XCTAssertLessThanOrEqual((c["images"] as? [String])?.count ?? 0, 8)
        XCTAssertTrue(((c["frames"] as? [String]) ?? []).allSatisfy { $0.count <= 120 })
        XCTAssertLessThanOrEqual((c["termination"] as? String)?.count ?? 0, 120)
    }
}
