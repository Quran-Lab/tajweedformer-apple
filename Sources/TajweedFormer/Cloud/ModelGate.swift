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
/// not cleared by an answer of the API, or it would be gone at the next registration: it holds without a network.
/// Once an answer of the API has accepted the key since the refusal (in this launch: a config, a registration or
/// a token), the next model call drops the remembered refusal and makes its model requests (`askAgain`), and the
/// CDN's answer decides and is reported as itself: a stop is remembered again, and every other answer (a build
/// that is served, `model_not_allowed`, a limit, no build named by the config) is what the app gets.
/// Tried before (3.1.0 to 3.1.2): only a config that could be fetched counted as the API's acceptance, and the
/// refusal ended only when the CDN SERVED a request. While the CDN answered anything else that was no stop, or
/// the config named no build, the app kept getting the old refusal's error and not the answer's own.
///
/// Not a stop, each of them "not now" or "not this request": every answer without a reason of the list, among
/// them a 401 `invalid_key` and the CDN's 401 without one, a 401 `invalid_token` without one (renew), a 403 the
/// catalogue does not know, a refusal of a model request for this install alone (`model_attestation_required`,
/// `model_not_allowed`), `sdk_too_old`, `environment_mismatch`, a 429, a 503 `network_blocked`, every 5xx, no
/// answer, an answer that does not verify. A learner without a connection keeps working after a real download.
///
/// A remembered refusal that is there and cannot be read is not "no refusal" (3.1.4): while the system does not
/// give the file, no model is opened and nothing is downloaded (`unreadable`, asked by `QuranLabCloud.modelStop`
/// and before every download), nothing is removed, and the file is read again at the next call. Until 3.1.3 the
/// file was read once, when the Client was made, and one that could not be read then was no refusal for the life
/// of the process: a model that was still on the device was opened.
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

    /// Whether a reason is one of `stopReasons`. Used where the status is a 401 already (the renewal of a token);
    /// whether an answer stops the model is `stops(status:reason:)`.
    static func stops(reason: String?) -> Bool {
        guard let reason else { return false }
        return stopReasons.contains(reason)
    }

    /// Whether an answer stops the model (SPEC 15.3 of contract 1.19.2): its status is 401 or 403 and its body's
    /// `reason` is one of `stopReasons`. A body that names a stop reason under any other status (a 429, a 404) is
    /// not a stop: nothing is remembered and nothing is removed.
    /// Tried before (3.1.0 to 3.1.4): only the reason counted, so a 4xx of any status whose body named a stop
    /// reason stopped the model, was remembered across launches, and removed the model files.
    static func stops(status: Int, reason: String?) -> Bool {
        (status == 401 || status == 403) && stops(reason: reason)
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
    private let state: Locked<StoredRead<Refusal>>
    /// Every model build the SDK holds: `<storage>/models`.
    private let models: URL
    /// The mark that a removal is owed (3.1.5): written by a stop, kept on the device, and taken away only when
    /// `<storage>/models` is gone. It outlives the refusal: when an accepting answer clears the refusal before the
    /// Model is closed or before the next start, or after a removal that failed, the files still go, before the
    /// next `model()` or `prefetch` uses them.
    /// Tried before (3.1.0 to 3.1.2): the removal was owed only while the refusal was remembered, so an accepting
    /// answer that came first left the refused install's model on the device and running.
    private let owedMark: URL
    private let owed: Locked<Bool>
    /// The Client holds an open Model: its files stay until it is closed.
    private let holdsOpenModel = Locked(false)
    /// An answer of the API has accepted the key since the remembered refusal of a model request arrived. Kept in
    /// memory only: a launch without a network has no such answer, and the refusal holds.
    private let acceptedByAPISince = Locked(false)
    /// For tests: whether the device refuses to remove the model files now (a storage error).
    static let refusesRemoval = Locked<(@Sendable () -> Bool)?>(nil)

    init(storage: URL) {
        file = JSONFile(url: storage.appendingPathComponent("cloud/model-stop.json"))
        let loaded = Self.load(file)
        state = Locked(loaded)
        // a refusal that cannot be read now owes nothing by itself: no model is opened or downloaded while it
        // cannot be read (`unreadable`), and it is read again at the next call
        let remembered = loaded.takingUnreadableAsMissing
        models = storage.appendingPathComponent("models")
        let mark = storage.appendingPathComponent("cloud/model-removal-owed")
        owedMark = mark
        // a refusal that 3.1.0 to 3.1.2 remembered has no mark: its removal is owed all the same, of everything
        let marked = FileManager.default.fileExists(atPath: mark.path)
        owed = Locked(marked || remembered != nil)
        if remembered != nil, !marked { Self.write(mark, nil) }
        // a start that finds a removal owed and any model file removes the files first
        removeOwedModels()
    }

    /// The build folders under `<storage>/models` now, as paths below it (`v4.0/<build>`, `v4.0/.download-<build>`).
    static func buildFolders(_ models: URL) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for model in (try? fm.contentsOfDirectory(atPath: models.path)) ?? [] {
            var isDir: ObjCBool = false
            let dir = models.appendingPathComponent(model)
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for build in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                var buildIsDir: ObjCBool = false
                if fm.fileExists(atPath: dir.appendingPathComponent(build).path, isDirectory: &buildIsDir), buildIsDir.boolValue {
                    out.append(model + "/" + build)
                }
            }
        }
        return out.sorted()
    }

    /// Writes the mark. `folders` nil: everything under `<storage>/models` is owed (a refusal an earlier version
    /// remembered, which named nothing).
    private static func write(_ mark: URL, _ folders: [String]?) {
        try? StorageProtection.makeFolder(mark.deletingLastPathComponent())
        let body = folders.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        try? body.write(to: mark, options: StorageProtection.atomic)
    }

    /// What the mark names.
    private enum Named {
        /// Everything under `<storage>/models` is owed: an empty mark, as a refusal that 3.1.0 to 3.1.2 remembered
        /// leaves it, or no mark.
        case all
        /// The build folders that were there when the stop arrived.
        case folders([String])
        /// The mark is there and the system does not give it now (3.1.4's rule): nothing is removed, and the
        /// removal is tried again later.
        case unreadable
    }

    private func named() -> Named {
        switch StorageSeam.read(owedMark) {
        case .missing: return .all
        case .unreadable(.refused): return .unreadable
        // damaged is taken as a mark that names nothing here, as an empty one: the removal it owes is of everything,
        // which is what a stop asks for
        case .unreadable(.damaged): return .all
        case .value(let body):
            guard !body.isEmpty, let folders = try? JSONDecoder().decode([String].self, from: body) else { return .all }
            return .folders(folders)
        }
    }

    /// A removal of model files is owed: a stop arrived and the folders it named have not been seen gone since.
    var removalOwed: Bool { owed.withLock { $0 } }

    /// With a removal owed and no Model open: removes the build folders the mark names (the ones that were on the
    /// device when the stop arrived), and takes the mark away once they are gone. A model's folder that holds no
    /// build any more goes whole, with its pointer files. A build that came later (an update fetched after the
    /// key was accepted again) is not named and stays. True when nothing is owed afterwards. A removal that fails
    /// changes nothing else and is tried again at the next start, the next refusal, the next model call and when
    /// the Model is closed.
    /// Tried before (the first candidate, never released): the mark named nothing and the whole of
    /// `<storage>/models` went, also a build that was downloaded after the server had accepted the key again.
    @discardableResult
    func removeOwedModels() -> Bool {
        guard owed.withLock({ $0 }) else { return true }
        guard !holdsOpenModel.withLock({ $0 }) else { return false }
        let fm = FileManager.default
        let what = named()
        if case .unreadable = what { return false }
        if case .folders(let folders) = what {
            let there = folders.map { models.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
            if !there.isEmpty {
                if Self.refusesRemoval.withLock({ $0 })?() ?? false { return false }
                var left = false
                for folder in there where (try? fm.removeItem(at: folder)) == nil { left = true }
                guard !left else { return false }
            }
            // a model's folder without a build left: its pointer files go with it
            for model in Set(folders.compactMap { $0.split(separator: "/").first.map(String.init) }) {
                let dir = models.appendingPathComponent(model)
                if Self.buildFolders(models).contains(where: { $0.hasPrefix(model + "/") }) { continue }
                try? fm.removeItem(at: dir)
            }
        } else if fm.fileExists(atPath: models.path) {
            if Self.refusesRemoval.withLock({ $0 })?() ?? false { return false }
            guard (try? fm.removeItem(at: models)) != nil else { return false }
        }
        owed.withLock { $0 = false }
        try? fm.removeItem(at: owedMark)
        return true
    }

    /// The Client holds an open Model from now on, or no longer. When it no longer does and a refusal arrived
    /// meanwhile (also one that an accepting answer has cleared since), the removal that was owed is done now.
    func modelOpen(_ isOpen: Bool) {
        holdsOpenModel.withLock { $0 = isOpen }
        if !isOpen { removeOwedModels() }
    }

    /// The remembered refusal as the device has it, in three results.
    private static func load(_ file: JSONFile<Refusal>) -> StoredRead<Refusal> {
        let read = file.read()
        // damaged is taken as not there here (bytes that were read and are not a refusal), as before 3.1.4: a
        // damaged file and a deleted one must not behave differently, and a refusal that is still in force comes
        // back with the server's next answer. A file the system does not give (refused) is held: no model is
        // opened and nothing is downloaded until it reads.
        if case .unreadable(.damaged) = read { return .missing }
        return read
    }

    /// The remembered refusal as this process has it now. One that could not be read is read again here.
    /// A refusal that could not be read when the Client was made and reads now owes the removal of the model files,
    /// as one that was read then does (the start marks it owed; this is the same mark, a little later).
    private func current() -> StoredRead<Refusal> {
        let file = self.file
        var readNow = false
        let now = state.withLock { (s: inout StoredRead<Refusal>) -> StoredRead<Refusal> in
            if s.isUnreadable {
                s = Self.load(file)
                readNow = !s.isUnreadable
            }
            return s
        }
        if readNow, case .value = now {
            let marked = FileManager.default.fileExists(atPath: owedMark.path)
            owed.withLock { $0 = true }
            if !marked { Self.write(owedMark, nil) }
        }
        return now
    }

    /// The refusal that stops the model now, when one is remembered.
    var stop: Refusal? { current().takingUnreadableAsMissing }

    /// Why the remembered refusal cannot be read now, when it is there and cannot: no model is opened and nothing
    /// is downloaded until it reads.
    var unreadable: String? {
        if case .unreadable(let why) = current() { return why.why }
        return nil
    }

    /// What a call raises while the remembered refusal cannot be read.
    static func unreadableError(_ why: String) -> RecognizerError {
        .storageFailed("what this device remembers of the server's last answer cannot be read now (\(why)); "
                       + "no model was opened or downloaded, and the next call tries again")
    }

    /// An answer of the server that was an error: when it is a stop it is remembered and the model files are
    /// removed, before the call that received it returns its error; else nothing.
    func note(_ e: CloudError, from: Source) {
        guard case .rejected(let status, let code, let message, let reason) = e, let reason, Self.stops(status: status, reason: reason) else { return }
        let r = Refusal(status: status, code: code, message: message, reason: reason, from: from)
        // a new refusal is the server's newest word: it is remembered also over a file that cannot be read now
        let changed = state.withLock { (s: inout StoredRead<Refusal>) -> Bool in
            defer { s = .value(r) }
            if case .value(let had) = s { return had != r }
            return true
        }
        if changed { file.write(r) }
        acceptedByAPISince.withLock { $0 = false }
        // the mark first, so that the removal stays owed whatever comes next. It names the build folders that are
        // on the device now, beside the ones an earlier stop named; a mark that names nothing owes everything
        owed.withLock { $0 = true }
        if !FileManager.default.fileExists(atPath: owedMark.path) {
            Self.write(owedMark, Self.buildFolders(models))
        } else if case .folders(let before) = named() {
            Self.write(owedMark, Array(Set(before).union(Self.buildFolders(models))).sorted())
        }
        removeOwedModels()
    }

    /// The server accepted the key: the API with a config, a registration or a token, or the CDN with a model
    /// request it served. A remembered refusal from the same side is over. A refusal of a model request stays
    /// when the API accepts, and the acceptance is noted for the next model call (`askAgain`).
    func accepted(_ by: Source) {
        // a refusal that cannot be read now is not cleared: what side it came from is not known, and the file stays
        let had = state.withLock { (s: inout StoredRead<Refusal>) -> Bool in
            guard case .value(let r) = s, r.from == by else { return false }
            s = .missing
            return true
        }
        if had { file.delete() }
        if by == .api, stop?.from == .model { acceptedByAPISince.withLock { $0 = true } }
    }

    /// A model call is about to make its model requests. A remembered refusal of a model request that an answer of
    /// the API has followed is dropped here, so that the call asks the CDN again; what the CDN answers decides (a
    /// stop is remembered again by `note`). Without such an answer since the refusal nothing changes. True when a
    /// refusal was dropped.
    @discardableResult
    func askAgain() -> Bool {
        guard acceptedByAPISince.withLock({ $0 }) else { return false }
        let had = state.withLock { (s: inout StoredRead<Refusal>) -> Bool in
            guard case .value(let r) = s, r.from == .model else { return false }
            s = .missing
            return true
        }
        if had {
            file.delete()
            acceptedByAPISince.withLock { $0 = false }
        }
        return had
    }
}
