import Foundation
import XCTest
@testable import TajweedFormer

/// Test inputs. Model files are never committed: the V4 folders and CoreML packages are release assets of this
/// repository that CI downloads (see .github/workflows/ci.yml); the parity audio is TestAudio/ (raw 16 kHz
/// float32, without the flush) or ZIPFORMER_AUDIO.
enum Fixtures {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../..").standardized

    static func audioDirectory() throws -> URL {
        let url = ProcessInfo.processInfo.environment["ZIPFORMER_AUDIO"].map { URL(fileURLWithPath: $0) }
            ?? repo.appendingPathComponent("TestAudio")
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Husary_001001.pcm").path) else {
            throw XCTSkip("no parity audio at \(url.path); set ZIPFORMER_AUDIO")
        }
        return url
    }

    static func samples(_ clip: String) throws -> [Float] {
        let data = try Data(contentsOf: try audioDirectory().appendingPathComponent("\(clip).pcm"))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The bundled test folder (scripts/make_test_folder_v4.py): `decoded/`, `server/`, `signed_text.txt`, `key.txt`.
    static func v4mini() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "v4mini", withExtension: nil, subdirectory: "Fixtures"))
    }

    /// The test signing key of the bundled folder (raw 32 bytes).
    static func v4miniKey() throws -> Data {
        let hex = try String(contentsOf: v4mini().appendingPathComponent("key.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// A private storage folder so verdicts and the store never touch the real Application Support.
    static func storage() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tf-storage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func configure(storage: URL = Fixtures.storage()) {
        QuranLab.configure(options: .init(modelSource: [], analytics: .off, storageDirectory: storage, cloud: nil))
    }

    /// A format 3 manifest for a decoded folder as it is on disk, unsigned: every file tagged by its path (layout v2
    /// names; a layout v1 context's own `layers.zfw` / `frontend.zfw` are tagged to that context).
    static func manifest(for dir: URL, revision: String = "test") throws -> ModelManifest {
        let root = dir.resolvingSymlinksInPath().path
        let e = FileManager.default.enumerator(atPath: root)!
        var files: [ModelManifest.File] = []
        while let rel = e.nextObject() as? String {
            var isDir: ObjCBool = false
            guard rel != "manifest.json", !rel.hasPrefix("."), FileManager.default.fileExists(atPath: root + "/" + rel, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let (size, sha) = try ModelManifest.digest(dir.appendingPathComponent(rel))
            let parts = rel.split(separator: "/").map(String.init)
            func isContext(_ s: String) -> Bool { s.range(of: #"^c[0-9]+_l[0-9]+$"#, options: .regularExpression) != nil }
            var ctx = parts.count == 2 && isContext(parts[0]) ? parts[0] : "*"
            let name = parts.last!
            var role: String
            var need = ModelManifest.Need.required
            var platforms = ["*"]
            switch name {
            case "tokens.txt": role = "tokens"
            case "calibration.json": role = "calibration"
            case "expected_tj3.zfx": role = "reference"; need = .optional
            case "layers.zfw": role = "weights"
            case "frontend.zfw": role = "frontend"
            case "model_engine2.onnx.zfg": role = "graph"
            case "model_engine2.onnx.zfg.bin": role = "graph-data"
            case "frames.zfw": role = "frames"
            case "model_engine2.onnx": role = "ort-graph"; need = .optional; platforms = ["native"]
            default: role = "doc"; need = .optional
            }
            if parts[0] == "coreml" || parts[0] == "coreml-compact" {
                let compact = parts[0] == "coreml-compact"
                platforms = ["apple"]
                need = .optional
                if parts.count == 3 && isContext(parts[1]) && name == "keeps.bin" { role = "coreml-keeps"; ctx = parts[1] }
                else if parts.count == 2 && name == "engine.zfs" { role = compact ? "correction-compact" : "correction" }
                else { role = compact ? "coreml-compact" : "coreml" }
            }
            files.append(.init(path: rel, size: size, sha256: sha, platforms: platforms, context: ctx, role: role, need: need))
        }
        let tok = try XCTUnwrap(files.first { $0.path == "tokens.txt" }).sha256
        // the contexts: the folders of the CPU engine's graphs, the default as calibration.json names it
        let contexts = Array(Set(files.compactMap { $0.context == "*" ? nil : $0.context })).sorted()
        let cal = JSONValue(data: (try? Data(contentsOf: dir.appendingPathComponent("calibration.json"))) ?? Data())
        let first = try XCTUnwrap(cal?["default_context"]?.string ?? contexts.first)
        return ModelManifest(modelID: "v4.0", revision: revision, tokensSHA256: tok, defaultContext: first, contexts: contexts, files: files)
    }
}
