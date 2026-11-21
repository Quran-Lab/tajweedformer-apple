import CryptoKit
import Foundation
import XCTest
@testable import TajweedFormer

/// 4.0's stand-in for the download 3.1.5's tests ran through the public Client (`OnlineOnlyTests`,
/// `StubbedModelServer`, retired with the plaintext engine): in 4.0 a build is installed only under a lease the Core
/// holds, which a stub server cannot give, so the download tests run the same installer one layer down. The build is
/// a CPU set of three CDN forms (`qle1`; small random files that stand for ciphertext) with the sizes the 3.1.5 tests
/// count ranges by (the weights 420 bytes, five ranges of 100; the tokens 248, three), in install order: the context's
/// frames, the weights, the tokens. The Core's install is `ModelDownloadTests.CoreStandIn`.
enum StubBuild {
    static let build = String(repeating: "b", count: 40)
    static let base = URL(string: "https://cdn.quranlab.ai/models/Quran-Lab/tajweedformer-v4/\(build)/sdk/v4.0/")!
    static let weights = "layers.zfw.qle"
    static let tokens = "tokens.txt.qle"

    static let stored: [(path: String, data: Data)] = {
        var g = SystemRandomNumberGenerator()
        func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }) }
        return [("c16_l64/frames.zfw.qle", bytes(61)), (weights, bytes(420)), (tokens, bytes(248))]
    }()

    static func data(_ path: String) -> Data? { stored.first { $0.path == path }?.data }

    static let files: [ModelManifest.File] = stored.map { s in
        let local = String(s.path.dropLast(4))
        return ModelManifest.File(path: s.path, size: Int64(s.data.count), sha256: Data(SHA256.hash(data: s.data)).hex,
                                  context: s.path.hasPrefix("c16_l64/") ? "c16_l64" : "*", role: "weights", encoding: "qle1",
                                  decoded: .init(path: local, size: Int64(s.data.count - 20), sha256: String(repeating: "0", count: 64)))
    }

    /// The stored path a request of the stub asks for (under the build's folder), or nil.
    static func path(_ seen: StubProtocol.Seen) -> String? {
        guard let at = seen.url.path.range(of: "/sdk/v4.0/") else { return nil }
        return String(seen.url.path[at.upperBound...])
    }

    /// A download server's answer to a model request, as a real one gives it (`ModelDownloadTests.served`).
    static func served(_ path: String, _ seen: StubProtocol.Seen, etag: String? = "\"one\"") -> StubProtocol.Reply {
        guard let d = data(path) else { return StubProtocol.Reply(status: 404) }
        return ModelDownloadTests.served(seen, data: d, etag: etag)
    }

    /// The stub download server; `cdn` answers a stored path first (nil: served as a real server does). The build.
    @discardableResult
    static func serve(cdn: (@Sendable (String, StubProtocol.Seen) -> StubProtocol.Reply?)? = nil) -> String {
        StubProtocol.reset { seen in
            guard let p = path(seen) else { return StubProtocol.Reply(status: 404) }
            return cdn?(p, seen) ?? served(p, seen)
        }
        return build
    }

    /// The model requests the stub got, and the stored paths they asked for, in order.
    static var modelRequests: [StubProtocol.Seen] { StubProtocol.seen.filter { path($0) != nil } }
    static var fetched: [String] {
        var out: [String] = []
        for p in modelRequests.compactMap({ path($0) }) where !out.contains(p) { out.append(p) }
        return out
    }
}

/// One install of the stub build into a storage, as a run of the updater makes it: the CPU set file by file (each
/// handing the files after it to the background with it), the background plan when there is a transport, a model
/// gate fed by the range sink and by the CDN client, then the working files removed. What the 3.1.5 tests read off
/// the Client is here: the gate, the redirect issues, the abandoned and dropped counts.
final class StubInstall: @unchecked Sendable {
    let storage: URL
    let relative = "models/v4.0/.download-" + StubBuild.build
    var folder: URL { storage.appendingPathComponent(relative) }
    let gate: ModelGate
    /// The issues a redirect on a background transfer queues (`model_redirected:<host>`).
    let redirects = Locked<[String]>([])
    let abandoned = Locked(0)
    let dropped = Locked<(tasks: Int, bytes: Int64)>((0, 0))
    let core = ModelDownloadTests.CoreStandIn()
    private(set) var installer: ModelInstaller
    let sink: RangeDelivery.Sink

    init(storage: URL = CloudFixtures.storage(), transport: (any BackgroundRangeTransport)? = nil, policy: BackgroundDownloadPolicy = .off,
         handOver: DownloadHandOver = DownloadHandOver(), base: URL = StubBuild.base, pauses: [TimeInterval] = [0, 0, 0, 0, 0],
         rangeSize: Int64 = 100, sendsKey: Bool = true, unmeteredOnly: Bool = false) {
        self.storage = storage
        let gate = ModelGate(storage: storage)
        self.gate = gate
        var client = CDNClient(http: HTTPClient(session: StubProtocol.session()), base: URL(string: "https://cdn.quranlab.ai/models")!,
                               auth: .fixed(key: CloudFixtures.key, token: "qlt_v1.eyJ2IjoxfQ.sig"),
                               verifier: ManifestVerifier(trustedKeys: [], requireSignature: false),
                               refused: { gate.note($0, from: .model) }, accepted: { gate.accepted(.model) })
        client.unmeteredOnly = unmeteredOnly
        let made = client
        let source = made.source(ModelID("v4.0", repository: "Quran-Lab/tajweedformer-v4"), revision: StubBuild.build, base: base)
        var i = ModelInstaller(source: source, rangeSize: rangeSize, retryPauses: pauses)
        let redirects = self.redirects, abandoned = self.abandoned, dropped = self.dropped
        sink = RangeDelivery.Sink(storage: storage, refused: { gate.note($0, from: .model) },
                                  redirected: { host in redirects.withLock { $0.append("model_redirected:" + host) } })
        if let transport, policy != .off {
            i.background = BackgroundPlan(transport: transport, policy: policy, handOver: handOver, folder: relative,
                                          request: { (path: String, lower: Int64, upper: Int64, validator: String?) async -> URLRequest? in
                                              await made.backgroundRequest(source.url(path), lower: lower, upper: upper, validator: validator,
                                                                             sendsKey: sendsKey)
                                          },
                                          abandoned: { n in abandoned.withLock { $0 += n } },
                                          stopped: { gate.stop?.error },
                                          dropped: { t, b in dropped.withLock { $0 = ($0.tasks + t, $0.bytes + b) } })
        }
        installer = i
        try? FileManager.default.createDirectory(at: storage.appendingPathComponent(relative), withIntermediateDirectories: true)
        installer.install = core.install(in: storage.appendingPathComponent(relative))
    }

    /// The install, as `client.model()` brought the build: the build, or the error the app would get.
    func model() async -> (build: String?, error: TajweedError?) {
        var report = InstallReport()
        let files = StubBuild.files
        do throws(RecognizerError) {
            if let stop = gate.stop { throw stop.error }
            // as `ModelInstaller.install` brings the CPU set (4.0.1: several files at a time while the app is in the
            // foreground, then one at a time, handing the files after each to the background with it)
            try await installer.ensureAll(files, in: folder, report: &report, counted: true)
            if let stop = gate.stop { throw stop.error }
            if let plan = installer.background { _ = await plan.transport.cancel(prefix: BackgroundRange.prefix(folder: plan.folder)) }
            ModelUpdater.pruneWorkingFiles(folder)
            return (StubBuild.build, nil)
        } catch {
            // a refusal that stops the model arrived while this ran: the refusal is the error
            if let stop = gate.stop { return (nil, TajweedError(from: stop.error)) }
            return (nil, TajweedError(from: error))
        }
    }

    /// (A Client's `close()` in the 3.1.5 tests.)
    func close() {}
}
