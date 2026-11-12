import Foundation

/// A Client the server has refused does not run the model (SDK 3.1.0, SPEC 15.3; the shared vector
/// `model_gate.json`).
///
/// The rule: an answer stops a model exactly when its JSON body carries a `reason` that is in `stopReasons`. An
/// answer without a reason never stops a model, whatever its status and its `error`. The refusal is remembered on
/// the device, and `client.model()` and `prefetch` fail with the refusal's catalogue error: no model is opened,
/// also not one that a real download left, also not at a later launch without a network. A Model that is already
/// open when the refusal arrives keeps running until the app closes it.
///
/// A stop also removes the model from the device: every build the SDK holds, with the install
/// records, the partial downloads and the accelerator packages in the build folders, which is the whole of
/// `<storage>/models`, what `removeModels()` removes. It happens in the call that received the refusal, before
/// that call returns the refusal's error. While the Client holds an open Model the removal is owed (the engine
/// opens files of the folder again for another context and for the accelerator's build): it is done when that
/// Model is closed, and at the next start before the Client does anything else. A removal that fails is tried
/// again at every start and at every refusal, and is never an error of its own. The remembered refusal, the
/// device key, the sharing state and the unsent recordings are not touched. After a later answer has accepted the
/// key the device holds no model, and the next `client.model()` downloads the build as on a first install.
/// Not removed, because the SDK did not write it: what the system cached by itself from a package the SDK loaded
/// (the compiled form Core ML keeps for the Neural Engine).
///
/// What ends it depends on where the refusal came from. A refusal of the API holds until a later answer of the API
/// accepts the key (a config, a registration or a token that succeeds). A refusal of a model request (the CDN) is
/// not cleared by an answer of the API, or it would be gone at the next registration: it holds without a network,
/// and once the API has accepted the key (a fresh config) the next model call asks the CDN again, whose answer
/// decides.
///
/// Not a stop, each of them "not now" or "not this request": every answer without a reason of the list, among
/// them a 401 `invalid_key` and the CDN's 401 without one, a 401 `invalid_token` without one (renew), a 403 the
/// catalogue does not know, a refusal of a model request for this install alone (`model_attestation_required`,
/// `model_not_allowed`), `sdk_too_old`, `environment_mismatch`, a 429, a 503 `network_blocked`, every 5xx, no
/// answer, an answer that does not verify. A learner without a connection keeps working after a real download.
///
/// Tried before (to 3.0.1): a refusal stopped the network calls of the launch and nothing else; the model on the
/// device kept serving a refused key for ever.
final class ModelGate: Sendable {
    /// The reasons that stop a model on the device: the whole list, in this one place (the vector's
    /// `stop_reasons`; the server's list of 2026-11-12).
    static let stopReasons: Set<String> = [
        "key_revoked", "key_unknown", "app_not_allowed", "origin_not_allowed", "key_type_mismatch", "app_blocked", "developer_not_approved",
    ]

    /// The stop reasons whose error for the app is `invalid_key` (the vector's `key_reasons`); the others are
    /// `server_rejected` with the reason's own words.
    static let keyReasons: Set<String> = ["key_revoked", "key_unknown"]

    /// Whether an answer stops the model: its body's `reason` is one of `stopReasons`. Only the reason counts.
    static func stops(reason: String?) -> Bool {
        guard let reason else { return false }
        return stopReasons.contains(reason)
    }

    /// Where a refusal came from: an answer of the API, or the CDN's answer to a model request.
    enum Source: String, Codable, Sendable {
        case api
        case model
    }

    /// The refusal as the server gave it.
    struct Refusal: Codable, Sendable, Equatable {
        var status: Int
        var code: String
        var message: String
        var reason: String
        var from: Source

        var error: RecognizerError { .serverRejected(status: status, code: code, message: message, reason: reason) }
    }

    private let file: JSONFile<Refusal>
    private let state: Locked<Refusal?>
    /// Every model build the SDK holds: `<storage>/models`.
    private let models: URL
    /// The Client holds an open Model: its files stay until it is closed.
    private let holdsOpenModel = Locked(false)
    /// For tests: whether the device refuses to remove the model files now (a storage error).
    static let refusesRemoval = Locked<(@Sendable () -> Bool)?>(nil)

    init(storage: URL) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/model-stop.json"))
        state = Locked(file.read())
        models = storage.appendingPathComponent("models")
        // a start that finds a remembered refusal and any model file removes the files first
        removeModelsIfStopped()
    }

    /// With a refusal remembered and no Model open: removes every model build the SDK holds. True when the device
    /// holds none afterwards. A removal that fails changes nothing else and is tried again at the next start, the
    /// next refusal and the next model call.
    @discardableResult
    func removeModelsIfStopped() -> Bool {
        guard stop != nil, !holdsOpenModel.withLock({ $0 }) else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: models.path) else { return true }
        if Self.refusesRemoval.withLock({ $0 })?() ?? false { return false }
        return (try? fm.removeItem(at: models)) != nil
    }

    /// The Client holds an open Model from now on, or no longer. When it no longer does and a refusal arrived
    /// meanwhile, the removal that was owed is done now.
    func modelOpen(_ isOpen: Bool) {
        holdsOpenModel.withLock { $0 = isOpen }
        if !isOpen { removeModelsIfStopped() }
    }

    /// The refusal that stops the model now, when one is remembered.
    var stop: Refusal? { state.withLock { $0 } }

    /// An answer of the server that was an error: when it is a stop it is remembered and the model files are
    /// removed, before the call that received it returns its error; else nothing.
    func note(_ e: CloudError, from: Source) {
        guard case .rejected(let status, let code, let message, let reason) = e, let reason, Self.stops(reason: reason) else { return }
        let r = Refusal(status: status, code: code, message: message, reason: reason, from: from)
        let changed = state.withLock { (s: inout Refusal?) -> Bool in
            defer { s = r }
            return s != r
        }
        if changed { file.write(r) }
        removeModelsIfStopped()
    }

    /// The server accepted the key: the API with a config, a registration or a token, or the CDN with a model
    /// request it served. A remembered refusal from the same side is over; one from the other side stays.
    func accepted(_ by: Source) {
        let had = state.withLock { (s: inout Refusal?) -> Bool in
            guard s?.from == by else { return false }
            s = nil
            return true
        }
        if had { file.delete() }
    }
}
