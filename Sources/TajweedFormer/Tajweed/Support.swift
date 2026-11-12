import Foundation

/// The backend a recognizer runs on.
enum ActiveBackend: String, Sendable, Hashable, Codable {
    /// The CoreML package on the Neural Engine (iOS 18, macOS 15).
    case neuralEngine
    /// The exact CPU engine: the same bits on every device.
    case exact

    /// The name telemetry counts it under (`ane`, `cpu`).
    var telemetryName: String { self == .neuralEngine ? "ane" : "cpu" }
}

/// Moves a value the compiler cannot prove is safe to move across isolation, where the code makes sure it is.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum DeviceInfo {
    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// "iPhone16,2", "Mac14,9", or the simulated model.
    static let model: String = {
        #if targetEnvironment(simulator)
        return "Simulator-" + (ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown")
        #elseif os(macOS)
        return sysctl("hw.model")
        #else
        return sysctl("hw.machine")
        #endif
    }()

    /// The OS build, "23A344": a new build can change what the Neural Engine computes.
    static let osBuild: String = sysctl("kern.osversion")
}

/// The SDK's own clips (Resources/SelfTest): three short recitations, 16 kHz 16-bit, used for the accelerator's
/// self-test only when the model folder has no self-test set; the reference is then the exact CPU engine's decode.
struct SelfTestClips {
    struct Clip {
        let name: String
        let samples: [Float]
    }

    let clips: [Clip]

    /// The exact CPU engine's greedy tokens for the bundled clip `Saood_112002`, by context (the same values as the
    /// Android SDK's self-test). The engine gives the same tokens on every device.
    static let saood112002Tokens: [String: [Int]] = [
        "c16_l64": [2, 31, 24, 34, 27, 33, 15, 31, 25, 31, 9],
        "c8_l64": [2, 31, 24, 34, 27, 33, 15, 31, 25, 31, 9],
        "c24_l72": [2, 31, 24, 34, 27, 33, 15, 31, 25, 31, 9],
        "c24_l256": [2, 31, 24, 34, 27, 33, 15, 31, 25, 31, 9],
    ]

    static func load() throws(RecognizerError) -> SelfTestClips {
        guard let dir = Bundle.module.url(forResource: "SelfTest", withExtension: nil),
              let data = try? Data(contentsOf: dir.appendingPathComponent("selftest.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["clips"] as? [[String: Any]] else {
            throw .modelMissing("the SDK's self-test clips are missing")
        }
        var clips: [Clip] = []
        for c in list {
            guard let name = c["clip"] as? String, let raw = try? Data(contentsOf: dir.appendingPathComponent("\(name).s16")) else {
                throw .modelMissing("self-test clip missing")
            }
            let samples = raw.withUnsafeBytes { r in
                (0..<(r.count / 2)).map { Float(Int16(littleEndian: r.loadUnaligned(fromByteOffset: 2 * $0, as: Int16.self))) / 32768 }
            }
            clips.append(Clip(name: name, samples: samples))
        }
        return SelfTestClips(clips: clips)
    }
}

/// A running take is live, user-initiated work. On macOS an app that is not frontmost is put into App Nap, which
/// throttles its threads (exact engine chunks went from about 6 ms to about 2 s on an M2 Pro); every take holds a
/// `ProcessInfo` activity from start to end. iOS has no App Nap.
final class SessionActivity: @unchecked Sendable {
    #if os(macOS)
    private let token: NSObjectProtocol
    #endif

    init() {
        #if os(macOS)
        token = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                      reason: "Quran Lab recitation session")
        #endif
    }

    func end() {
        #if os(macOS)
        ProcessInfo.processInfo.endActivity(token)
        #endif
    }
}
