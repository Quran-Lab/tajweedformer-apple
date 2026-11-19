// A screen on the released SDK 3.1.4 for the reading of an upgrade. The app's own file is these lines (put your key
// in, and give the project the SAME bundle id as the DownloadCheck app):
//
//     import SwiftUI
//     import UpgradeSeed
//
//     @main
//     struct SeedApp: App {
//         init() { UpgradeSeed.shared.key = "qlk_v1_..." }
//         var body: some Scene { WindowGroup { UpgradeSeedView() } }
//     }
//
// What it does: makes a Client, shows the SDK's sharing sheet on "Ask to share" (answer it either way: the answer
// is then written on the device), and on "Show" says the SDK's version and the protection class of the saved
// sharing answer and of the config. Then install the DownloadCheck app over it from Xcode: the same bundle id
// keeps the same container, which is what an upgrade from 3.1.4 finds.
import Foundation
import SwiftUI
import TajweedFormer

@MainActor
public final class UpgradeSeed: ObservableObject {
    public static let shared = UpgradeSeed()

    /// The app's key (set in the App's init).
    public var key = ""
    @Published public private(set) var lines: [String] = []
    private var client: TajweedClient?

    private init() {}

    private func note(_ text: String) {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        lines.append(clock.string(from: Date()) + "  " + text)
    }

    /// Makes the Client once.
    public func start() {
        guard client == nil else { return }
        guard !key.isEmpty else { return note("no key: set UpgradeSeed.shared.key in the App's init") }
        do {
            client = try TajweedClient(key: key)
            note("Client made")
        } catch {
            note("the Client could not be made: \(error)")
        }
    }

    /// The SDK's sharing sheet, when Quran Lab offers sharing to the key's app (the config may need a few seconds
    /// after the start).
    public func ask() {
        guard let client else { return }
        guard client.sharing.isAvailable else { return note("sharing is not offered (yet): wait a few seconds and tap again") }
        note(client.sharing.ask() ? "the sharing sheet is shown: answer it" : "no ask is allowed now (answered already)")
    }

    /// The SDK's version and the protection class of two of its files.
    public func show() async {
        guard let client else { return }
        let d = await client.diagnose()
        note("SDK " + d.sdkVersion + "; sharing is " + (client.sharing.isOn ? "on" : "not on"))
        note("protection: sharing-state.json " + Self.protection("cloud/sharing-state.json") + "; config.json " + Self.protection("cloud/config.json"))
    }

    /// The protection class of a file in the SDK's default storage folder (`Application Support/QuranLab`).
    static func protection(_ path: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("QuranLab").appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return "not there yet" }
        guard let p = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType else { return "no class" }
        return p.rawValue
    }
}

/// The screen: two buttons and the lines.
public struct UpgradeSeedView: View {
    @ObservedObject private var seed = UpgradeSeed.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button("Ask to share") { seed.ask() }
                Button("Show") { Task { await seed.show() } }
            }
            ScrollView {
                Text(seed.lines.joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .onAppear { seed.start() }
    }
}
