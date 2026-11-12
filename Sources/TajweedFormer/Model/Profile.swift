import Foundation

/// What one device downloads of a model folder.
///
/// - The CPU set: every file for `apple` (or `*`) that is `required`, for any SoC, for context `*` or the chosen
///   context. The exact engine runs from it alone, on every iPhone and Mac. The first install of a model fetches
///   only this (`ModelUpdater`), so the first session never waits for the Neural Engine's files.
/// - The accelerator files, fetched later by the promotion pipeline (`AcceleratorController`, stage `download`) on
///   iOS 18 / macOS 15 when the folder ships them: ONE CoreML build, by default the fp16 package (role `coreml`,
///   `coreml/tajweedformer_v4.mlmodelc`), with `compact` the int8 package (`coreml-compact`), plus the context's keep
///   table (`coreml-keeps`) when the manifest lists one, and the self-test set (`selftest`) the build must pass
///   before it is used. Only for a context the build serves (`ModelManifest.serving`, SPEC 5.4): the signed
///   tolerance names the context under `<build>:<context>`, or a keep table is listed for it. For any other context
///   nothing of the build is fetched. Until 3.0.1 the SDK carried its own list of CPU-only contexts (`c8_l64`);
///   since 3.0.2 the manifest decides, also for a context that list named.
///   Not fetched since 2.0.1: the correction files (`correction`, `correction-compact`). They rebuilt the CPU weights
///   from the package so the package could be downloaded instead of the weights; with the CPU set first, the weights
///   are already on disk when the package arrives, and the CPU engine must run from them at once on a failover.
struct DownloadProfile: Sendable, Hashable {
    static let platform = "apple"
    /// The roles of every Apple file (both builds); never part of the CPU set.
    static let appleRoles: Set<String> = ["coreml", "coreml-keeps", "correction", "coreml-compact", "correction-compact",
                                                 "coreml-delta", "coreml-compact-delta"]
    /// The CoreML package roles.
    static let packageRoles: Set<String> = ["coreml", "coreml-compact"]

    let context: String
    /// Whether the Apple files may be part of the profile (the OS can run the CoreML package and the app allows
    /// it). Whether they are is the manifest's to say: `appleFiles` is empty for a context the build does not serve.
    let coreML: Bool
    /// The compact (int8) CoreML build (`coreml-compact`) instead of the fp16 one (`coreml`). The SDK asks for the
    /// fp16 build, as in 2.x; it asks for the compact one only for a Session whose `backend` names `coreml-compact`.
    let compact: Bool

    init(context: String, coreML: Bool = DownloadProfile.osRunsCoreML, compact: Bool = false) {
        self.context = context
        self.coreML = coreML
        self.compact = compact
    }

    /// iOS 18 / macOS 15: the CoreML package is specification 9 (multifunction, weights stored once for every context).
    static var osRunsCoreML: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    /// The package role of this profile's build.
    var packageRole: String { compact ? "coreml-compact" : "coreml" }
    /// Roles never kept in a folder: both corrections (not used since 2.0.1; a folder installed by 2.0.0 may still
    /// hold one). The other CoreML build is not one of them (SDK 3.0.0): a folder may hold the fp16 build, which a
    /// device gets by default, and the compact build, which a device gets when an app names it, and installing one
    /// leaves the other where it is.
    var otherRoles: Set<String> { ["correction", "correction-compact"] }

    func inContext(_ f: ModelManifest.File) -> Bool { f.context == "*" || f.context == context }

    /// The CPU set for this context.
    func cpuFiles(_ m: ModelManifest) -> [ModelManifest.File] {
        // the self-test set comes with the accelerator (appleFiles), even where a manifest marks it required, so a first
        // install is the bare CPU set, as on Android
        m.files.filter { $0.isFor(platform: Self.platform) && $0.need == .required && inContext($0) && !Self.appleRoles.contains($0.role)
            && $0.role != "selftest" }
    }

    /// The accelerator files of this profile's build for this context: the package, the context's keep table when
    /// the manifest lists one (a package that carries its keep table inside lists none) and the self-test set.
    /// Empty without `coreML`, and for a context the build does not serve (`ModelManifest.serving`): nothing of a
    /// build is fetched for such a context.
    /// Tried before (to 3.0.1): the list was empty unless the manifest listed both the package and a keep table for
    /// the context, so a one-file package was never fetched.
    func appleFiles(_ m: ModelManifest) -> [ModelManifest.File] {
        guard coreML, m.serving(build: packageRole, context: context) != nil else { return [] }
        // the self-test set comes with either build: the accelerator is promoted only after it passes it
        let roles: Set<String> = [packageRole, "coreml-keeps", "selftest"]
        return m.files.filter { $0.isFor(platform: Self.platform) && roles.contains($0.role) && inContext($0) }
    }

    /// The delta role of this profile's build (QLPD1: its program rebuilt from the CPU weights on the device).
    var deltaRole: String { compact ? "coreml-compact-delta" : "coreml-delta" }

    /// The build's program delta and the program it rebuilds (the package's `weights/weight.bin`), when the folder
    /// lists both: the delta is fetched in place of the program, which stays the fallback.
    func programDelta(_ m: ModelManifest) -> (delta: ModelManifest.File, program: ModelManifest.File)? {
        let apple = appleFiles(m)
        guard !apple.isEmpty else { return nil }
        for d in m.files where d.role == deltaRole && d.isFor(platform: Self.platform) && inContext(d) && d.localPath.hasSuffix(".qlpd") {
            let target = String(d.localPath.dropLast(5))
            if let p = apple.first(where: { $0.localPath == target && $0.role == packageRole }) { return (d, p) }
        }
        return nil
    }

    /// Everything this profile keeps on disk once the accelerator files are in.
    func files(_ m: ModelManifest) -> [ModelManifest.File] { cpuFiles(m) + appleFiles(m) }

    /// The files of `otherRoles` (the corrections: deleted from the folder when this profile's accelerator files
    /// are installed).
    func otherBuildFiles(_ m: ModelManifest) -> [ModelManifest.File] { m.files.filter { otherRoles.contains($0.role) } }

    /// Bytes downloaded (stored, compressed size) for `files`.
    static func bytes(_ files: [ModelManifest.File]) -> Int64 { files.reduce(0) { $0 + $1.size } }
}
