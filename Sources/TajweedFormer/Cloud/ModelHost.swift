import Foundation

/// Where model manifests are served: one host, `{base}/{owner}/{repo}/{revision}/{folder}/{path}`, with the app key in
/// `x-qlab-key`. SDK 4.0: a build's files come only from the model folder its lease answer names
/// (`ProtectedRuntime.acceptedBase`), never from here and never from a config.
enum ModelHost {
    /// Quran Lab's model host.
    static let defaultBase = URL(string: "https://cdn.quranlab.ai/models")!

    /// Where the manifest is read: the app's own base (`CloudOptions.cdnURL`), else Quran Lab's. A base a config
    /// names is never used (the 4.0 config names none; qlab-api f7c5d2a). The manifest is signed either way.
    static func manifestBase(explicit: URL?) -> URL { explicit ?? defaultBase }

    /// A bare CDN host, the shape of older configurations: their files stay under `/hf`. A base with a path, such as
    /// `https://cdn.quranlab.ai/models`, is never one.
    static func isBareCDNHost(_ base: String) -> Bool {
        base.range(of: #"^https://((weur|eeur|enam|wnam|apac|oc)\.)?cdn\.quranlab\.ai$"#, options: .regularExpression) != nil
    }

    /// `{base}/{owner}/{repo}/{revision}/{folder}/`.
    static func folderURL(base: URL, repository: String, revision: String, folder: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        if isBareCDNHost(root) { root += "/hf" }
        var url = URL(string: root)!
        for part in [repository, revision, folder].flatMap({ $0.split(separator: "/") }) {
            url.appendPathComponent(String(part), isDirectory: true)
        }
        return url
    }
}
