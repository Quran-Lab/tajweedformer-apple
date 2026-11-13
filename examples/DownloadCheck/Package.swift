// swift-tools-version:6.0
import PackageDescription

// A screen for checking the model download on a phone: it downloads the model, shows how long that took and which
// protocol it went by, switches between the transports of a download, and keeps a log with the time of day that
// the next launch still shows (so it can be read after the app was suspended, started by the system, or quit).
// It is a library, because an iOS app needs an Xcode project of your own (your team, your bundle id, your key):
//   1. In Xcode: File > New > Project > iOS > App (SwiftUI). Use the bundle id your key is for.
//   2. File > Add Package Dependencies > Add Local: this folder. Add the library DownloadCheck to the app.
//   3. Replace the project's App file by the few lines at the top of Sources/DownloadCheck/DownloadCheck.swift.
let package = Package(
    name: "DownloadCheck",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "DownloadCheck", targets: ["DownloadCheck"])],
    dependencies: [.package(name: "TajweedFormer", path: "../..")],
    targets: [
        .target(name: "DownloadCheck", dependencies: [.product(name: "TajweedFormer", package: "TajweedFormer")]),
    ],
    swiftLanguageModes: [.v6]
)
