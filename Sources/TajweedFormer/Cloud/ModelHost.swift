import Foundation

/// Where model files are served: one host, `{base}/{owner}/{repo}/{revision}/{folder}/{path}`, with the app key in
/// `x-qlab-key`.
enum ModelHost {
    /// Used when neither the app nor a verified config names a base.
    static let defaultBase = URL(string: "https://cdn.quranlab.ai/models")!

    /// The app's own base wins, then the verified config's, then the default.
    static func base(explicit: URL?, config: RemoteConfig?) -> URL { explicit ?? config?.modelBase ?? defaultBase }

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
