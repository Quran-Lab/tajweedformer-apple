import Foundation

/// A model the SDK knows by name. The revision (the exact files) comes from the manifest. SDK 2.0.0 hosts only
/// TajweedFormer V4 (`.v4_0`); the earlier phoneme models stay with the 1.x SDKs.
public struct ModelID: Sendable, Hashable, CustomStringConvertible {
    public let name: String
    /// The Hugging Face repository the CDN mirrors it from, and the key of the remote config's `models`.
    public let repository: String
    /// The folder inside the repository holding the SDK build (manifest.json and its files).
    public let folder: String

    public init(_ name: String, repository: String, folder: String? = nil) {
        self.name = name
        self.repository = repository
        self.folder = folder ?? "sdk/\(name)"
    }

    /// TajweedFormer V4: 38 tj3 tokens, blank 0, every head of the network and the calibrated tajweed checks;
    /// contexts c16_l64 (320 ms chunks, the default), c24_l72 and c24_l256 (480 ms).
    public static let v4_0 = ModelID("v4.0", repository: "Quran-Lab/tajweedformer-v4", folder: "sdk/v4.0")

    /// Whatever TajweedFormer model Quran Lab recommends for this app and SDK version (the signed remote config's
    /// `recommended`, remembered for offline launches; `.v4_0` before any is known). Resolved by `TajweedModel.load`.
    public static let recommended = ModelID("recommended", repository: "", folder: "")

    public var isRecommended: Bool { name == "recommended" && repository.isEmpty }

    public var description: String { name }
}

/// Resolves `ModelID.recommended`: the verified config's recommendation, remembered in
/// `<storage>/models/recommended.json`, else the remembered one, else `.v4_0`.
enum RecommendedModel {
    struct Saved: Codable, Equatable {
        let model: String
        let model_id: String
        let folder: String
    }

    static func file(_ storage: URL) -> JSONFile<Saved> { JSONFile(url: storage.appendingPathComponent("models/recommended.json")) }

    static func remember(_ r: RemoteConfig.Recommended, storage: URL) {
        let s = Saved(model: r.model, model_id: r.model_id, folder: r.folder)
        let f = file(storage)
        if f.read() != s { f.write(s) }
    }

    static func resolve(config: RemoteConfig?, storage: URL) -> ModelID {
        if let r = config?.recommended {
            remember(r, storage: storage)
            return r.modelID
        }
        if let s = file(storage).read() { return ModelID(s.model_id, repository: s.model, folder: s.folder) }
        return .v4_0
    }
}

/// Where the SDK looks for a model, tried in the order given.
public enum ModelSource: Sendable, Hashable {
    /// A folder holding manifest.json and the decoded files it lists.
    case directory(URL)
    /// The app bundle: `QuranLabModels/<model>/` in the main bundle's resources.
    case bundle
    /// The SDK's own store: `<storage>/models/<model>/<revision>/`, the revision named by the `current` pointer.
    case cache
    /// Quran Lab's CDN: the download profile of this device, installed into the store.
    case cdn
}

/// The model's vocabulary, from tokens.txt ("<symbol> <id>" per line).
public struct Vocabulary: Sendable, Hashable {
    /// Symbols by id.
    public let symbols: [String]
    /// The CTC blank's id (0 for tj3).
    public let blank: Int

    public var count: Int { symbols.count }

    public func symbol(_ id: Int) -> String { id >= 0 && id < symbols.count ? symbols[id] : "?" }

    init(tokensFile url: URL) throws(RecognizerError) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw .modelMissing("cannot read \(url.lastPathComponent)") }
        try self.init(text: text)
    }

    init(text: String) throws(RecognizerError) {
        var map: [Int: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            if parts.count >= 2, let id = Int(parts[parts.count - 1]) {
                map[id] = parts[0..<(parts.count - 1)].joined(separator: " ")
            }
        }
        guard let top = map.keys.max(), map.count == top + 1 else {
            throw .manifestInvalid("tokens.txt does not number its tokens 0..<n")
        }
        symbols = (0...top).map { map[$0]! }
        blank = symbols.firstIndex(of: "<blk>") ?? symbols.firstIndex(of: "<blank>") ?? 0
    }

    init(symbols: [String], blank: Int) {
        self.symbols = symbols
        self.blank = blank
    }
}
