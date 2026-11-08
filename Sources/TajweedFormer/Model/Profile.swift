import Foundation

/// What one device downloads of a model folder.
///
/// - The CPU set: every file for `apple` (or `*`) that is `required`, for any SoC, for context `*` or the chosen
///   context. The exact engine runs from it alone, on every iPhone and Mac.
/// - On iOS 18 / macOS 15 and later, when the folder ships them, the Apple files of ONE CoreML build: by default the
///   fp16 package (role `coreml`, `coreml/tajweedformer_v4.mlmodelc`) and its correction (`correction`,
///   `coreml/engine.zfs`); with `compact`, the int8 package (`coreml-compact`, `coreml-compact/...`) and its correction
///   (`correction-compact`), smaller and slightly less accurate. Both use the context's keep table (`coreml-keeps`).
///   The CPU engine's weight files are then rebuilt from the package's weights and the correction instead of
///   downloaded (`DownloadProfile.rebuilt`), and checked against the manifest's decoded SHA-256 like any download.
///   Older systems cannot run the package, so they skip it and download the CPU set.
public struct DownloadProfile: Sendable, Hashable {
    public static let platform = "apple"
    /// The roles of every Apple file (both builds); never part of the CPU set.
    public static let appleRoles: Set<String> = ["coreml", "coreml-keeps", "correction", "coreml-compact", "correction-compact"]
    /// The CoreML package roles.
    public static let packageRoles: Set<String> = ["coreml", "coreml-compact"]

    public let context: String
    /// Whether the Apple files are part of the profile (the OS can run the CoreML package and the app allows it).
    public let coreML: Bool
    /// The compact (int8) CoreML build instead of the default fp16 one.
    public let compact: Bool

    public init(context: String, coreML: Bool = DownloadProfile.osRunsCoreML, compact: Bool = false) {
        self.context = context
        self.coreML = coreML
        self.compact = compact
    }

    /// iOS 18 / macOS 15: the CoreML package is specification 9 (multifunction, weights stored once for every context).
    public static var osRunsCoreML: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    /// The package and correction roles of this profile's build.
    public var packageRole: String { compact ? "coreml-compact" : "coreml" }
    public var correctionRole: String { compact ? "correction-compact" : "correction" }
    /// The other build's roles (never downloaded with this one; deleted when the profile changes).
    public var otherRoles: Set<String> { compact ? ["coreml", "correction"] : ["coreml-compact", "correction-compact"] }

    func inContext(_ f: ModelManifest.File) -> Bool { f.context == "*" || f.context == context }

    /// The CPU set for this context.
    public func cpuFiles(_ m: ModelManifest) -> [ModelManifest.File] {
        m.files.filter { $0.isFor(platform: Self.platform) && $0.need == .required && inContext($0) && !Self.appleRoles.contains($0.role) }
    }

    /// The Apple files of this profile's build for this context (empty without `coreML`, or when the folder ships
    /// none of that build).
    public func appleFiles(_ m: ModelManifest) -> [ModelManifest.File] {
        guard coreML else { return [] }
        // the self-test set comes with either build: the accelerator is promoted only after it passes it
        let roles: Set<String> = [packageRole, correctionRole, "coreml-keeps", "selftest"]
        let a = m.files.filter { $0.isFor(platform: Self.platform) && roles.contains($0.role) && inContext($0) }
        // the package and the keep table belong together: without either, no Apple file is worth fetching
        guard a.contains(where: { $0.role == packageRole }), a.contains(where: { $0.role == "coreml-keeps" && $0.context == context }) else {
            return []
        }
        return a
    }

    /// The files the correction rebuilds, given the names it lists (`zf_zfs_file_name`): CPU-set files whose decoded
    /// path is one of them. Empty when the profile has no correction.
    public func rebuilt(_ m: ModelManifest, correctionNames: [String]) -> [ModelManifest.File] {
        guard appleFiles(m).contains(where: { $0.role == correctionRole }) else { return [] }
        let names = Set(correctionNames)
        return cpuFiles(m).filter { names.contains($0.localPath) }
    }

    /// Everything this profile keeps on disk, assuming the correction covers `rebuilt`.
    public func files(_ m: ModelManifest, correctionNames: [String] = []) -> [ModelManifest.File] {
        let skip = Set(rebuilt(m, correctionNames: correctionNames).map(\.path))
        return appleFiles(m) + cpuFiles(m).filter { !skip.contains($0.path) }
    }

    /// The other build's files (deleted from the folder when this profile is installed).
    public func otherBuildFiles(_ m: ModelManifest) -> [ModelManifest.File] { m.files.filter { otherRoles.contains($0.role) } }

    /// Bytes downloaded (stored, compressed size) for `files`.
    public static func bytes(_ files: [ModelManifest.File]) -> Int64 { files.reduce(0) { $0 + $1.size } }
}
