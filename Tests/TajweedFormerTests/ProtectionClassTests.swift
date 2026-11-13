import Foundation
import XCTest
@testable import TajweedFormer

/// The protection class of what the SDK keeps on the device (3.1.4): "complete until first user authentication",
/// by name, on the files and folders of its storage, also on those an earlier release wrote.
///
/// These tests can show something only on a machine that tells the classes apart: where a file written with the
/// class "complete" shows "complete". Each test prints what this machine shows (the line "PROTECTION-MEASURE:")
/// and is skipped where it does not tell them apart. On the CI's Mac runner every file shows "complete until
/// first user authentication", whatever class its write names, so there the tests are skipped and show nothing:
/// only a device, in an app whose files have another class by default, can show that the SDK's files carry the
/// class. No test here runs on a phone.
final class ProtectionClassTests: UnreadableStorageTestCase {
    /// The protection class the system reports for a file or folder, in plain words; nil where it reports none.
    static func protection(_ url: URL) -> String? {
        if let p = (try? url.resourceValues(forKeys: [.fileProtectionKey]))?.fileProtection {
            if p == URLFileProtection.completeUntilFirstUserAuthentication { return wanted }
            if p == URLFileProtection.complete { return "complete" }
            if p == URLFileProtection.completeUnlessOpen { return "complete unless open" }
            return p.rawValue
        }
        if let p = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType {
            if p == FileProtectionType.completeUntilFirstUserAuthentication { return wanted }
            if p == FileProtectionType.complete { return "complete" }
            if p == FileProtectionType.completeUnlessOpen { return "complete unless open" }
            return p.rawValue
        }
        return nil
    }

    static let wanted = "complete until first user authentication"

    /// Whether this machine tells the protection classes apart: a file written with the class "complete" shows
    /// "complete", and one written with "complete until first user authentication" shows that.
    func machineShowsClasses() throws -> Bool {
        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("protection-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: probe) }
        try Data("probe".utf8).write(to: probe, options: [.atomic, .completeFileProtection])
        let complete = ProtectionClassTests.protection(probe)
        try Data("probe".utf8).write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let named = ProtectionClassTests.protection(probe)
        // what a replacement of that file shows when its write names no class
        try Data("again".utf8).write(to: probe, options: [.atomic])
        let replaced = ProtectionClassTests.protection(probe)
        print("PROTECTION-MEASURE: on this machine a file written with the class complete shows \(complete ?? "no class"); "
            + "one written with the class complete until first user authentication shows \(named ?? "no class"); "
            + "after an atomic replacement that names no class it shows \(replaced ?? "no class")")
        return complete == "complete" && named == ProtectionClassTests.wanted
    }

    /// What the SDK wrote in a process where the learner said yes and made a recording: the stored answer, the
    /// queue's folder, the recording's folder and its files carry the class.
    func testWhatTheSDKWritesCarriesTheProtectionClass() async throws {
        guard try machineShowsClasses() else {
            throw XCTSkip("this machine does not tell the protection classes apart: only a device can show that the SDK's files carry the class")
        }
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let made = try await firstProcess(server, storage)
        let folder = made.root.appendingPathComponent(made.id)
        var looked = 0
        for url in [storage.appendingPathComponent("cloud/sharing-state.json"), made.root, folder]
            + ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []) {
            XCTAssertEqual(ProtectionClassTests.protection(url), ProtectionClassTests.wanted, url.lastPathComponent)
            looked += 1
        }
        XCTAssertGreaterThan(looked, 5, "the stored answer, the queue, the recording and its files")
    }

    /// A file and a folder that an earlier release wrote in the storage without naming a class get the class at a
    /// start.
    func testWhatAnEarlierReleaseWroteGetsTheProtectionClassAtAStart() async throws {
        guard try machineShowsClasses() else {
            throw XCTSkip("this machine does not tell the protection classes apart: only a device can show that an earlier release's files get the class")
        }
        let server = SharingTests.Server()
        StubProtocol.reset(server.handler)
        let storage = CloudFixtures.storage()
        let fm = FileManager.default
        // as an earlier release left them: the stored answer and a folder with a file, written with no class named
        let state = storage.appendingPathComponent("cloud/sharing-state.json")
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(UnreadableStateTests.storedDeclined.utf8).write(to: state, options: [.atomic])
        let old = storage.appendingPathComponent("outbox/kept-from-before")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let file = old.appendingPathComponent("note.json")
        try Data("{}".utf8).write(to: file, options: [.atomic])
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: state.path)

        _ = await launch(storage: storage)
        let set = await until(10) { ProtectionClassTests.protection(state) == ProtectionClassTests.wanted && ProtectionClassTests.protection(file) == ProtectionClassTests.wanted && ProtectionClassTests.protection(old) == ProtectionClassTests.wanted }
        XCTAssertTrue(set, "the stored answer shows \(ProtectionClassTests.protection(state) ?? "no class"), the old folder \(ProtectionClassTests.protection(old) ?? "no class"), "
            + "its file \(ProtectionClassTests.protection(file) ?? "no class")")
    }

    /// Which paths the walk of a start visits (this the Mac can show, whatever it shows of the classes): the SDK's
    /// own four folders in the storage folder and everything in them, and nothing else. Not the storage folder
    /// itself, which is the app's choice, and not a file or a folder of the app's own that lies in it, also not one
    /// whose name begins like one of the SDK's.
    func testTheWalkOfAStartVisitsOnlyTheSDKsOwnFolders() throws {
        let storage = CloudFixtures.storage()
        let fm = FileManager.default
        let files = ["cloud/sharing-state.json", "outbox/abc/seg-00001.opus", "models/v4.0/rev/layers.zfw", "accelerator/promotions.json",
                     "app-notes.txt", "app-own/secret.db", "cloudy/other.json"]
        for path in files {
            let url = storage.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let base = storage.resolvingSymlinksInPath().path
        var visited: [String] = []
        StorageProtection.walk(storage) { (url: URL) in
            visited.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        XCTAssertEqual(visited.sorted(), ["accelerator", "accelerator/promotions.json", "cloud", "cloud/sharing-state.json", "models",
                                          "models/v4.0", "models/v4.0/rev", "models/v4.0/rev/layers.zfw", "outbox", "outbox/abc",
                                          "outbox/abc/seg-00001.opus"])
        XCTAssertEqual(StorageProtection.own, ["cloud", "models", "outbox", "accelerator"])
    }
}
