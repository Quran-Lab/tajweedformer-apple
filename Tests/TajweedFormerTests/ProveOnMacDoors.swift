import Foundation
@testable import TajweedFormer

// The doors of the Mac proof (ProveOnMac.swift) into the SDK's internals: only what the public API has no door for.
// Nothing here runs a take or decides a verdict; it reads what the SDK already holds.

extension ProveDoors {
    /// The doors over the SDK as it is configured now.
    /// - Parameter trustedKeys: the keys a model manifest must verify with (the release key; tests pass their own).
    static func real(trustedKeys: [Data] = [ManifestVerifier.quranLabPublicKey]) -> ProveDoors {
        // the device fields of an accelerator incident (`QuranLabCloud.deviceValues`), in the order they are printed
        var fields: [(name: String, value: String)] = []
        fields.append((name: "platform", value: AppIdentity.currentPlatform))
        fields.append((name: "os_version", value: DeviceContext.osVersionString))
        fields.append((name: "os_build", value: DeviceInfo.osBuild))
        fields.append((name: "device_model", value: DeviceInfo.model))
        if let chip = DeviceContext.soc { fields.append((name: "chip", value: chip)) }
        fields.append((name: "sdk_version", value: SDKInfo.version))
        return ProveDoors(
            releaseKeyID: trustedKeys.first.map { ConfigVerifier.keyID($0) } ?? "none",
            osRunsCoreML: DownloadProfile.osRunsCoreML,
            device: "\(DeviceInfo.model), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            deviceFields: fields,
            blocker: { () async -> String? in
                await PromotionConditions.current(network: true).blocker(for: .download)
            },
            configModel: { () -> (version: String?, build: String?) in
                guard let cloud = QuranLab.cloud else { return (nil, nil) }
                let id = RecommendedModel.resolve(config: cloud.currentConfig, storage: QuranLab.configuration.storageDirectory)
                return (cloud.targetVersion(id), cloud.targetRevision(id))
            },
            refusal: { () -> ProveRefusal? in
                guard let cloud = QuranLab.cloud, let r = cloud.rejection, let raised = cloud.rejectionError else { return nil }
                // what `client.model()` throws for it: the catalogue's message and fix (the reason's, when it has one).
                // The answer's `reason` is read first, then its `error`: a key that belongs to another app arrives as
                // a refused key with `reason: app_not_allowed`.
                let error = TajweedError(from: raised)
                return ProveRefusal(error: error, serverCode: TajweedError.knownReason(r.reason) ?? r.code, status: r.status)
            },
            verify: { (model: TajweedModel, version: String?, build: String?) -> ProveVerified in
                let folder = model.folder
                let verifier = ManifestVerifier(trustedKeys: trustedKeys, requireSignature: true)
                do throws(RecognizerError) {
                    let opened = try ModelFolder.open(directory: folder.directory, verifier: verifier, build: build, version: version)
                    let files = opened.manifest.files.filter { opened.verifiedFiles.contains($0.localPath) }
                    var bytes: Int64 = 0
                    for f in files { bytes += f.localSize }
                    return ProveVerified(ok: true, files: files.count, listed: opened.manifest.files.count, bytes: bytes, problem: nil)
                } catch {
                    let e = TajweedError(from: error)
                    return ProveVerified(ok: false, files: 0, listed: folder.manifest.files.count, bytes: 0, problem: "\(e.code): \(e.message)")
                }
            },
            fetchSelfTest: { (model: TajweedModel) async throws -> Int in
                guard let cloud = QuranLab.cloud else { throw TajweedError(.needsConnection) }
                let folder = model.folder
                var fetched = 0
                for file in folder.manifest.files(role: "selftest") where file.isFor(platform: DownloadProfile.platform) {
                    do throws(RecognizerError) {
                        try await cloud.updater.install(file, of: folder)
                    } catch {
                        throw TajweedError(from: error)
                    }
                    fetched += 1
                }
                return fetched
            },
            expectedTokens: { (model: TajweedModel, context: String) -> [String: [Int]]? in
                let folder = model.folder
                let path = "selftest/expected_\(context).json"
                // the file as the signed manifest lists it, nothing else
                guard let file = folder.manifest.file(local: path), ModelInstaller.verified(file, in: folder.directory),
                      let data = try? Data(contentsOf: folder.directory.appendingPathComponent(path)),
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let clips = o["clips"] as? [String: Any] else { return nil }
                var out: [String: [Int]] = [:]
                for (id, entry) in clips {
                    if let tokens = (entry as? [String: Any])?["tokens"] as? [Int] { out[id] = tokens }
                }
                return out.isEmpty ? nil : out
            },
            hasBuild: { (model: TajweedModel, build: String, context: String) -> Bool in
                // the manifest says which contexts a build serves (SPEC 5.4): the profile lists nothing for the others
                guard DownloadProfile.osRunsCoreML else { return false }
                let profile = DownloadProfile(context: context, coreML: true, compact: build == "coreml-compact")
                return !profile.appleFiles(model.folder.manifest).isEmpty
            },
            servedByKey: { (model: TajweedModel, build: String, context: String) -> Bool in
                model.folder.manifest.serving(build: build, context: context)?.by == .tolerance
            },
            promotion: { (model: TajweedModel, build: String, context: String) -> ProvePromotion? in
                let store = PromotionStore(dir: QuranLab.configuration.storageDirectory.appendingPathComponent("accelerator"))
                let key = AcceleratorController.key(revision: model.folder.identity, context: context, build: build)
                guard let r = store.record(key) else { return nil }
                return ProvePromotion(status: r.status.rawValue, stage: r.lastStage?.rawValue, reason: r.lastReason?.rawValue,
                                      detail: r.lastDetail, compileMs: r.compileMs, acceleratorMedianMs: r.acceleratorMedianMs,
                                      cpuMedianMs: r.cpuMedianMs, measures: r.golden.map { ProveMeasures($0) })
            },
            flushTelemetry: { () async -> (sent: Int, waiting: Int)? in
                guard let cloud = QuranLab.cloud, QuranLab.configuration.options.analytics != .off else { return nil }
                let sent = await cloud.flush()
                return (sent.events, cloud.analytics.sealed.count)
            },
            secrets: { () -> [String] in
                var s = [NSHomeDirectory(), QuranLab.configuration.storageDirectory.path]
                if let cloud = QuranLab.cloud {
                    s.append(cloud.app.bundleID)
                    if let key = cloud.key { s.append(key) }
                }
                return s
            })
    }
}

extension ProveMeasures {
    /// The golden stage's measures as the promotion's record keeps them.
    init(_ d: Divergence) {
        self.init()
        tokensExpected = d.tokensExpected
        for (name, head) in d.heads ?? [:] {
            guard let head else { continue }
            if name == "attr" {
                pMean = head.pMean
                values = head.values ?? 0
            } else {
                ctc[name] = CTC(tokenEdits: head.tokenEdits ?? 0, lpMean: head.lpMean ?? 0, lpP99: head.lpP99 ?? 0, frames: head.frames ?? 0)
            }
        }
        // the tolerance the golden stage judged by, when the signed manifest gives the build one
        if let signed = d.tolerance {
            var kept = Tolerance()
            for (name, head) in signed {
                if name == "attr" {
                    kept.pMean = head.pMean
                } else {
                    kept.ctc[name] = CTC(tokenEdits: head.tokenEdits ?? 0, lpMean: head.lpMean ?? 0, lpP99: head.lpP99 ?? 0, frames: 0)
                }
            }
            tolerance = kept
        }
    }
}

extension ProveOnMac {
    /// The Client's configuration: what the public options (`TajweedClientOptions(appId:storage:)`) give, with the
    /// one thing the public API has no option for. The app's name: an app's comes from its bundle, a test process
    /// has none of its own, so the run names itself in the SDK's own `CloudOptions.app` and the registration shows
    /// that name.
    static func options(_ config: ProveConfig) -> QuranLab.Options {
        var options = TajweedClientOptions(appId: config.appId, storage: config.storage).configuration
        var cloud = options.cloud ?? CloudOptions()
        var app = cloud.app ?? AppIdentity.main
        app.name = config.appName
        cloud.app = app
        options.cloud = cloud
        return options
    }

    /// The Client over that configuration, by the initializer the public one calls.
    static func client(_ config: ProveConfig) throws -> TajweedClient {
        try TajweedClient(key: config.key, configuration: options(config), cloud: nil)
    }
}
