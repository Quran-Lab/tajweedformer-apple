// Debug builds only: the tests stand in for the Core through StagingHooks.core, which a release build does not have.
#if DEBUG
import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// A protected build with two contexts, `c16_l64` (the default) and `c24_l256`: its signed manifest and the CDN form of
/// each file (small random bytes that stand for ciphertext, as StubBuild's). The tokens' decoded form is the tj3
/// vocabulary the SDK carries, so the folder opens; the Core's part (the lease, each file's install) is the stand-in of
/// `StagingHooks.core` (`NoWaitHarness.core`), and the CPU engine is `FakeCPUEngine`.
enum TwoContextBuild {
    static let other = "c24_l256"
    static let tokensSHA256 = "66fe6eb81b15506270f9e3c6efb0724cda757cd54326f26ca4bcd6be4f3b2aa4"

    static let stored: [(path: String, context: String, data: Data)] = {
        var g = SystemRandomNumberGenerator()
        func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }) }
        return [("tokens.txt.qle", "*", bytes(300)), ("layers.zfw.qle", "*", bytes(2420)),
                ("c16_l64/frames.zfw.qle", "c16_l64", bytes(610)), ("c24_l256/frames.zfw.qle", "c24_l256", bytes(970))]
    }()
    /// The accelerator build of a build made `accelerator: true` (the Core ML package and the default context's keep
    /// table): never part of an install, fetched by the promotion's download stage.
    static let acceleratorFiles: [(path: String, context: String, role: String, data: Data)] = {
        var g = SystemRandomNumberGenerator()
        func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }) }
        return [("coreml/tajweedformer_v4.mlmodelc/weights/weight.bin.qle", "*", "coreml", bytes(1500)),
                ("c16_l64/keeps.bin.qle", "c16_l64", "coreml-keeps", bytes(130))]
    }()

    static func data(_ path: String) -> Data? { stored.first { $0.path == path }?.data ?? acceleratorFiles.first { $0.path == path }?.data }

    /// The signed manifest.json of the build (signed with the fixtures' key, which the test Client trusts), its build id
    /// and the manifest. `revision` makes another build of the same files.
    static func manifest(revision: String = "no-wait-40", accelerator: Bool = false) throws -> (data: Data, build: String, manifest: ModelManifest) {
        let url = try XCTUnwrap(SDKResources.bundle.url(forResource: tokensSHA256, withExtension: "txt", subdirectory: "Vocabulary"))
        let tokens = try Data(contentsOf: url)
        var files = stored.map { s -> ModelManifest.File in
            let sha = Data(SHA256.hash(data: s.data)).hex
            let decoded = s.path == "tokens.txt.qle"
                ? ModelManifest.Decoded(path: "tokens.txt", size: Int64(tokens.count), sha256: tokensSHA256)
                : ModelManifest.Decoded(path: String(s.path.dropLast(4)), size: Int64(s.data.count - 20), sha256: sha)
            return ModelManifest.File(path: s.path, size: Int64(s.data.count), sha256: sha, context: s.context,
                                      role: s.path.hasPrefix("tokens") ? "tokens" : "weights", encoding: "qle1", decoded: decoded)
        }
        if accelerator {
            files += acceleratorFiles.map { a -> ModelManifest.File in
                let sha = Data(SHA256.hash(data: a.data)).hex
                return ModelManifest.File(path: a.path, size: Int64(a.data.count), sha256: sha, platforms: ["apple"], context: a.context,
                                          role: a.role, encoding: "qle1",
                                          decoded: .init(path: String(a.path.dropLast(4)), size: Int64(a.data.count - 20), sha256: sha))
            }
        }
        var m = ModelManifest(modelID: "v4.0", revision: revision, version: "4.0.0", minSDKVersion: "4.0.0", tokensSHA256: tokensSHA256,
                              defaultContext: "c16_l64", contexts: ["c16_l64", other], files: files)
        m.encryption = .init(keyID: "d14d9aeeeecb3a238cb86c41a5e8b0c2", root: 1)
        m.signature = try CloudFixtures.signer.signature(for: Data(m.signedText().utf8)).base64EncodedString()
        let data = m.jsonData()
        let parsed = try ModelManifest.parse(data)
        return (data, parsed.build, parsed)
    }

    /// The stored path a model request asks for (under the build's folder), or nil.
    static func path(_ seen: StubProtocol.Seen) -> String? {
        guard let at = seen.url.path.range(of: "/sdk/v4.0/") else { return nil }
        return String(seen.url.path[at.upperBound...])
    }
}

/// The Client of these tests: the stub server (the API's routes, the config naming the build, the manifest and the
/// files by Range), the Core's stand-in and the CPU engine's.
enum NoWaitHarness {
    /// The files the Core's stand-in installed, in order (their stored paths).
    static let installed = Locked<[String]>([])

    /// The stand-in for the Core: a lease whose model folder is the build's on Quran Lab's model host, and an install
    /// that checks the CDN form against the manifest and writes a device form of the size the Core would.
    static func core(accelerator: Bool? = nil) -> CoreStandIn {
        CoreStandIn(lease: { (m: ModelManifest) async throws -> LeaseRecord in
            let now = Int64(Date().timeIntervalSince1970)
            return LeaseRecord(build: m.build, base: "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/\(m.build)/sdk/v4.0/",
                               expiresAt: now + 30 * 86_400, refreshAfter: now + 20 * 86_400)
        }, install: { (m: ModelManifest, decodedPath: String, folder: URL) throws in
            guard let f = m.files.first(where: { $0.localPath == decodedPath }) else { throw RecognizerError.manifestInvalid("no \(decodedPath)") }
            guard let bytes = try? Data(contentsOf: folder.appendingPathComponent(f.path)), bytes.count == f.size,
                  Data(SHA256.hash(data: bytes)).hex == f.sha256 else { throw RecognizerError.checksumMismatch(file: f.path) }
            let device = folder.appendingPathComponent(f.localPath + ".qld")
            try FileManager.default.createDirectory(at: device.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: Int(f.deviceFormSize)).write(to: device)
            installed.withLock { $0.append(f.path) }
        }, acceleratorAllowed: { accelerator })
    }

    /// The server: the API's routes, the config naming `build`, its manifest and its files (`down`: no answer at all,
    /// as with no network).
    static func serve(manifest: Data, build: String, down: Bool = false) {
        let config = CloudFixtures.config(models: ["Quran-Lab/tajweedformer-v4": build])
        let routes = CloudFixtures.server(config: config, extra: { (s: StubProtocol.Seen) -> StubProtocol.Reply? in
            guard let p = TwoContextBuild.path(s) else { return nil }
            if p == ModelManifest.fileName { return StubProtocol.Reply(status: 200, headers: ["content-type": "application/json"], body: manifest) }
            guard let d = TwoContextBuild.data(p) else { return StubProtocol.Reply(status: 404) }
            return ModelDownloadTests.served(s, data: d)
        })
        StubProtocol.reset { s in down ? .down : routes(s) }
    }

    /// The options of an app's Client: nothing about networks is set (the SDK's own defaults), only the test's
    /// servers, keys and pauses.
    static func options(_ storage: URL) -> QuranLab.Options {
        QuranLab.Options(modelSource: [.cache], updates: .automatic, storageDirectory: storage,
                         cloud: CloudOptions(apiURL: CloudFixtures.api, cdnURL: CloudFixtures.cdn,
                                             signingKeys: [CloudFixtures.signer.publicKey.rawRepresentation],
                                             app: CloudFixtures.app, urlSession: StubProtocol.session(),
                                             retryPauses: [0, 0, 0, 0, 0]),
                         contributions: false)
    }

    /// A Client on `storage` as an app makes it: the server client with the SDK's own network behaviour (no test
    /// switch of it), the fixtures' attester and key stores.
    static func client(_ storage: URL) throws -> TajweedClient {
        let o = options(storage)
        return try TajweedClient(key: CloudFixtures.key, configuration: o, cloud: { (dir: URL) -> QuranLabCloud? in
            QuranLabCloud(key: CloudFixtures.key, options: o, storage: dir, attester: FakeAttester(isSupported: false),
                          attestKeys: MemoryAttestKeyStore(), installKeys: CloudFixtures.installKeys)
        })
    }

    /// The stand-ins in place: the Core's, the CPU engine's, and the connection the system reports.
    static func setUp(connection: ConnectionKind, accelerator: Bool? = nil) {
        installed.withLock { $0 = [] }
        StagingHooks.core.withLock { $0 = core(accelerator: accelerator) }
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = { (_: String) throws -> any CPUStreamEngine in FakeCPUEngine() } }
        ConnectionKind.override.withLock { $0 = { connection } }
    }

    static func tearDown() {
        StagingHooks.core.withLock { $0 = nil }
        TajweedRecognizer.cpuEngineOverride.withLock { $0 = nil }
        ConnectionKind.override.withLock { $0 = nil }
        StubProtocol.reset { _ in .down }
    }

    /// The model requests (the manifest and every file range) the stub got, from `index` on.
    static func modelRequests(from index: Int = 0) -> [StubProtocol.Seen] {
        Array(StubProtocol.seen.dropFirst(index)).filter { TwoContextBuild.path($0) != nil }
    }
}

/// Section 33: nothing waits for Wi-Fi. The report that started it,
/// Apple 4.0.1: `prefetch()` installed the default context, then a Session on another context (`c24_l256`) on mobile data
/// got `model_missing` at every retry, because that context's files were taken for an update and updates waited for an
/// unmetered network. Through the public Client, with the SDK's own network behaviour (the options an app has, no test
/// switch of the gate) and the system reporting a metered connection.
final class NoWaitTests: XCTestCase {
    override func tearDown() {
        NoWaitHarness.tearDown()
        super.tearDown()
    }

    /// `other_context_metered` of no_wait_40.json: the default context installed through `prefetch()`, then a Session
    /// on `c24_l256` on a metered network: that context's files download and the Session opens, and no request (the
    /// manifest, every file range, the API's) carries a mark that keeps it off a metered or constrained network.
    func testAnotherContextsFilesDownloadOnAMeteredNetworkAndTheSessionOpens() async throws {
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest()
        NoWaitHarness.setUp(connection: .metered)
        NoWaitHarness.serve(manifest: build.data, build: build.build)
        let client = try NoWaitHarness.client(storage)
        defer { client.close() }
        try await client.prefetch()
        XCTAssertFalse(NoWaitHarness.installed.withLock { $0 }.contains("c24_l256/frames.zfw.qle"), "prefetch() brings the default context only")
        let model = try await client.model()
        let before = StubProtocol.seen.count
        var failure: TajweedError?
        do throws(TajweedError) {
            let session = try await model.session(options: TajweedSessionOptions(context: TwoContextBuild.other))
            await session.cancel()
        } catch {
            failure = error
        }
        XCTAssertNil(failure, "the Session on \(TwoContextBuild.other) opens (Apple 4.0.1: model_missing): \(failure?.description ?? "")")
        let asked = NoWaitHarness.modelRequests(from: before).compactMap { TwoContextBuild.path($0) }
        XCTAssertTrue(asked.contains("c24_l256/frames.zfw.qle"), "the context's files were asked for: \(asked)")
        XCTAssertTrue(NoWaitHarness.installed.withLock { $0 }.contains("c24_l256/frames.zfw.qle"), "and installed")
        let marked = StubProtocol.seen.filter { !$0.allowsExpensive || !$0.allowsConstrained }.map { $0.url.path }
        XCTAssertEqual(marked, [], "no request waits for an unmetered or unconstrained network")
        XCTAssertGreaterThan(NoWaitHarness.modelRequests().count, 0)
    }

    /// The cases of no_wait_40.json that name Apple, each on a new storage folder with the
    /// system's connection report set to the case's (Low Data Mode, the data saver of the vectors, is a metered report
    /// here: the SDK reads neither), against the stub server; no answer at all where the connection is `none`. Every
    /// request the SDK sends carries no network condition, and each call ends as the case says. Two cases run where
    /// their path is: the upload's (SharingTests) and the one of what 4.0.1 queued (BackgroundSessionTests); the
    /// accelerator's runs here as its download through the updater, and its pipeline in PromotionTests.
    func testTheVectorsCasesThatNameApple() async throws {
        let v = try V40.json("no_wait_40.json")
        let cases = try XCTUnwrap(v["cases"] as? [[String: Any]]).filter { ($0["platforms"] as? [String])?.contains("apple") == true }
        XCTAssertEqual(cases.count, 12)
        let elsewhere = ["sharing_upload_metered": "SharingTests.testASharedRecordingUploadsOnAMeteredNetwork",
                         "queued_by_401_metered": "BackgroundSessionTests.testARangeTaskThat401LeftWaitingForWiFiGoesOn"]
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            XCTAssertEqual(c["network_condition"] as? String, "none", name)
            if let test = elsewhere[name] {
                print("no_wait_40 \(name): replayed by \(test)")
                continue
            }
            try await replay(c, name: name)
        }
    }

    /// One case (see `testTheVectorsCasesThatNameApple`).
    private func replay(_ c: [String: Any], name: String) async throws {
        let connection = try XCTUnwrap(ConnectionKind(rawValue: try XCTUnwrap(c["connection"] as? String)), name)
        let onDevice = c["on_device"] as? [String: Any] ?? [:]
        let call = try XCTUnwrap(c["call"] as? String)
        let storage = CloudFixtures.storage()
        let build = try TwoContextBuild.manifest(accelerator: call == "accelerator")
        NoWaitHarness.setUp(connection: connection)
        defer { NoWaitHarness.tearDown() }
        NoWaitHarness.serve(manifest: build.data, build: build.build)
        let client = try NoWaitHarness.client(storage)
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        // what is on the device first, brought on a network that answers
        if onDevice["c16_l64"] as? String == "complete" { try await client.prefetch() }
        if connection == .none { NoWaitHarness.serve(manifest: build.data, build: build.build, down: true) }
        var before = StubProtocol.seen.count
        let newer = try TwoContextBuild.manifest(revision: "no-wait-40-newer")
        var failure: TajweedError?
        do throws(TajweedError) {
            switch call {
            case "model":
                _ = try await client.model()
            case "prefetch":
                try await client.prefetch()
            case "session":
                let model = try await client.model()
                let session = try await model.session(options: TajweedSessionOptions(context: TwoContextBuild.other))
                await session.cancel()
            case "update":
                // the config names a newer build of the same model
                NoWaitHarness.serve(manifest: newer.data, build: newer.build)
                before = 0
                _ = await cloud.refreshConfig()
                switch await cloud.checkForUpdate() {
                case .pending, .installed: break
                case let other: XCTFail("\(name): the update ended \(other)")
                }
            case "accelerator":
                guard cloud.updater.coreML else { return print("no_wait_40 \(name): no accelerator in this process, its download not tried") }
                guard let installed = try? await ModelStore.standard.resolve(.v4_0, sources: [.cache], context: nil) else {
                    return XCTFail("\(name): the default context is not on the device")
                }
                do throws(RecognizerError) {
                    _ = try await cloud.updater.installAccelerator(installed, context: "c16_l64")
                } catch {
                    XCTFail("\(name): the accelerator's build did not download: \(error)")
                }
                let asked = NoWaitHarness.modelRequests(from: before).compactMap { TwoContextBuild.path($0) }
                XCTAssertTrue(asked.contains("coreml/tajweedformer_v4.mlmodelc/weights/weight.bin.qle"), "\(name): \(asked)")
            default:
                XCTFail("\(name): no replay for call \(call)")
            }
        } catch {
            failure = error
        }
        let after = Array(StubProtocol.seen.dropFirst(before))
        XCTAssertEqual(StubProtocol.seen.filter { !$0.allowsExpensive || !$0.allowsConstrained }.map { $0.url.path }, [],
                       "\(name): no request waits for a kind of network")
        if c["requests"] as? Bool == true { XCTAssertGreaterThan(after.count, 0, "\(name): the call sent its requests") }
        if c["outcome"] as? String == "error" {
            XCTAssertEqual(failure?.code, c["code"] as? String, "\(name): \(failure?.description ?? "no error")")
            XCTAssertEqual(failure?.cause?.needs, c["needs"] as? String, name)
        } else {
            XCTAssertNil(failure, "\(name): \(failure?.description ?? "")")
        }
    }
}
#endif
