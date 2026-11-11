import Foundation

/// Everything the SDK throws. Every public throwing call throws this and nothing else.
enum RecognizerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No model was found in any configured source, or a file the model needs is not there.
    case modelMissing(String)
    /// A model file's SHA-256 differs from the manifest's. The model is refused, never used.
    case checksumMismatch(file: String)
    /// The manifest carries a signature that does not verify against the SDK's public key, or a
    /// signature is required and there is none.
    case signatureInvalid
    /// The manifest cannot be read, or leaves out a file the model needs.
    case manifestInvalid(String)
    /// The model build does not run on this SDK: a build for SDK 2.x (no version), one that needs a newer SDK, another
    /// engine format or model family.
    case modelIncompatible(String)
    /// Audio the SDK cannot take yet: a sample rate the resampler does not take (8, 11.025, 16, 22.05, 24, 32, 44.1, 48 kHz),
    /// or a sample format other than Float32 or Int16.
    case unsupportedAudioFormat(String)
    /// The microphone cannot be used: access was denied, there is no input device, or the audio
    /// session or engine would not start.
    case microphoneUnavailable(String)
    /// The Neural Engine backend was asked for and cannot run here (OS older than iOS 18 / macOS 15,
    /// the package does not load, or the device failed its self-test).
    case neuralEngineUnavailable(String)
    /// The engine failed: `code` is its ZfStatus (1 argument, 2 memory, 3 engine; -1 when a stream
    /// could not be made, -100 a self-test mismatch) and `message` zf_stream_last_error's text.
    case engineFailed(code: Int, message: String)
    /// A recognizer runs one take at a time; finish or cancel the current one first.
    case sessionActive
    /// No take is open (startTake first), or it has already finished or failed.
    case sessionClosed
    /// The take was cancelled.
    case cancelled
    /// A service that needs Quran Lab's servers (downloads, contributions) is not available in
    /// this build of the SDK.
    case serviceUnavailable(String)
    /// The server could not be reached (or answered with a server error); try again later.
    case offline(String)
    /// The server refused the request, with its HTTP status and error code, and the answer's `reason` (the check
    /// that refused) when it names one.
    case serverRejected(status: Int, code: String, message: String, reason: String? = nil)
    /// Not enough free space for a model update.
    case insufficientStorage(needed: Int64, available: Int64)
    /// A model update was not started (policy: no Wi-Fi, updates off) or not activated yet.
    case updateDeferred(String)
    /// A file could not be written or moved (a model file, the sharing outbox).
    case storageFailed(String)
    /// No such item in the sharing outbox, or it cannot do that in its state (an upload in flight
    /// cannot be cancelled).
    case contributionUnavailable(String)
    /// A value the API does not accept (an unknown context or head name, a sample rate, a rule name).
    case invalidArgument(String)

    var description: String {
        switch self {
        case .modelMissing(let why): return "model missing: \(why)"
        case .checksumMismatch(let file): return "checksum mismatch: \(file)"
        case .signatureInvalid: return "the model manifest's signature is invalid"
        case .manifestInvalid(let why): return "invalid model manifest: \(why)"
        case .modelIncompatible(let why): return "model not for this SDK: \(why)"
        case .unsupportedAudioFormat(let why): return "unsupported audio format: \(why)"
        case .microphoneUnavailable(let why): return "microphone unavailable: \(why)"
        case .neuralEngineUnavailable(let why): return "Neural Engine unavailable: \(why)"
        case .engineFailed(let code, let message): return "engine failed (\(code)): \(message)"
        case .sessionActive: return "a session is already running on this recognizer"
        case .sessionClosed: return "the session is closed"
        case .cancelled: return "the session was cancelled"
        case .serviceUnavailable(let what): return "\(what) is not available in this build"
        case .offline(let why): return "offline: \(why)"
        case .serverRejected(let s, let code, let m, _): return "server refused (\(s) \(code)): \(m)"
        case .insufficientStorage(let n, let a): return "not enough space: \(n) bytes needed, \(a) free"
        case .updateDeferred(let why): return "update deferred: \(why)"
        case .storageFailed(let why): return "storage failed: \(why)"
        case .contributionUnavailable(let why): return "sharing: \(why)"
        case .invalidArgument(let why): return "invalid argument: \(why)"
        }
    }
}
