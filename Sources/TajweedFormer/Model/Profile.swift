import Foundation

/// What one device downloads of a model folder.
///
/// - The CPU set: every file for `apple` (or `*`) that is `required`, for any SoC, for context `*` or the chosen
///   context. The exact engine runs from it alone, on every iPhone and Mac. The first install of a model fetches
///   only this (`ModelUpdater`), so the first session never waits for the Neural Engine's files.
/// - The accelerator files, fetched later by the promotion pipeline (`AcceleratorController`, stage `download`) on
///   iOS 18 / macOS 15 when the folder ships them: ONE CoreML build, by default the fp16 package (role `coreml`,
///   `coreml/tajweedformer_v4.mlmodelc`), with `compact` the int8 package (`coreml-compact`), plus the context's keep
///   table (`coreml-keeps`) and the self-test set (`selftest`) the build must pass before it is used.
///   Not fetched since 2.0.1: the correction files (`correction`, `correction-compact`). They rebuilt the CPU weights
///   from the package so the package could be downloaded instead of the weights; with the CPU set first, the weights
///   are already on disk when the package arrives, and the CPU engine must run from them at once on a failover.
public enum ModelContexts {
    /// Contexts with no CoreML package: the exact CPU engine runs them on every device, whatever backend is requested.
    /// c8_l64 is 8 frames at 20 ms per step (160 ms chunks) with 64 left frames.
    public static let cpuOnly: Set<String> = ["c8_l64"]

    public static func isCPUOnly(_ context: String) -> Bool { cpuOnly.contains(context) }
}

public struct DownloadProfile: Sendable, Hashable {
    public static let platform = "apple"
    /// The roles of every Apple file (both builds); never part of the CPU set.
    public static let appleRoles: Set<String> = ["coreml", "coreml-keeps", "correction", "coreml-compact", "correction-compact",
                                                 "coreml-delta", "coreml-compact-delta"]
    /// The CoreML package roles.
    public static let packageRoles: Set<String> = ["coreml", "coreml-compact"]

    public let context: String
    /// Whether the Apple files are part of the profile (the OS can run the CoreML package, the app allows it, and the
    /// context is not CPU-only).
    public let coreML: Bool
    /// The compact (int8) CoreML build instead of the default fp16 one.
    public let compact: Bool

    public init(context: String, coreML: Bool = DownloadProfile.osRunsCoreML, compact: Bool = false) {
        self.context = context
        self.coreML = coreML && !ModelContexts.isCPUOnly(context)
        self.compact = compact
    }

    /// iOS 18 / macOS 15: the CoreML package is specification 9 (multifunction, weights stored once for every context).
    public static var osRunsCoreML: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    /// The package role of this profile's build.
    public var packageRole: String { compact ? "coreml-compact" : "coreml" }
    /// Roles never kept with this build: the other build's package, and both corrections (not used since 2.0.1;
    /// a folder installed by 2.0.0 may still hold one).
    public var otherRoles: Set<String> {
        let package: Set<String> = compact ? ["coreml", "coreml-delta"] : ["coreml-compact", "coreml-compact-delta"]
        return package.union(["correction", "correction-compact"])
    }

    func inContext(_ f: ModelManifest.File) -> Bool { f.context == "*" || f.context == context }

    /// The CPU set for this context.
    public func cpuFiles(_ m: ModelManifest) -> [ModelManifest.File] {
        // the self-test set comes with the accelerator (appleFiles), even where a manifest marks it required, so a first
        // install is the bare CPU set, as on Android
        m.files.filter { $0.isFor(platform: Self.platform) && $0.need == .required && inContext($0) && !Self.appleRoles.contains($0.role)
            && $0.role != "selftest" }
    }

    /// The accelerator files of this profile's build for this context: the package, the context's keep table and the
    /// self-test set (empty without `coreML`, or when the folder ships none of that build).
    public func appleFiles(_ m: ModelManifest) -> [ModelManifest.File] {
        guard coreML else { return [] }
        // the self-test set comes with either build: the accelerator is promoted only after it passes it
        let roles: Set<String> = [packageRole, "coreml-keeps", "selftest"]
        let a = m.files.filter { $0.isFor(platform: Self.platform) && roles.contains($0.role) && inContext($0) }
        // the package and the keep table belong together: without either, no Apple file is worth fetching
        guard a.contains(where: { $0.role == packageRole }), a.contains(where: { $0.role == "coreml-keeps" && $0.context == context }) else {
            return []
        }
        return a
    }

    /// The delta role of this profile's build (QLPD1: its program rebuilt from the CPU weights on the device).
    public var deltaRole: String { compact ? "coreml-compact-delta" : "coreml-delta" }

    /// The build's program delta and the program it rebuilds (the package's `weights/weight.bin`), when the folder
    /// lists both: the delta is fetched in place of the program, which stays the fallback.
    public func programDelta(_ m: ModelManifest) -> (delta: ModelManifest.File, program: ModelManifest.File)? {
        let apple = appleFiles(m)
        guard !apple.isEmpty else { return nil }
        for d in m.files where d.role == deltaRole && d.isFor(platform: Self.platform) && inContext(d) && d.localPath.hasSuffix(".qlpd") {
            let target = String(d.localPath.dropLast(5))
            if let p = apple.first(where: { $0.localPath == target && $0.role == packageRole }) { return (d, p) }
        }
        return nil
    }

    /// Everything this profile keeps on disk once the accelerator files are in.
    public func files(_ m: ModelManifest) -> [ModelManifest.File] { cpuFiles(m) + appleFiles(m) }

    /// The files of `otherRoles` (deleted from the folder when this profile's accelerator files are installed).
    public func otherBuildFiles(_ m: ModelManifest) -> [ModelManifest.File] { m.files.filter { otherRoles.contains($0.role) } }

    /// Bytes downloaded (stored, compressed size) for `files`.
    public static func bytes(_ files: [ModelManifest.File]) -> Int64 { files.reduce(0) { $0 + $1.size } }
}
