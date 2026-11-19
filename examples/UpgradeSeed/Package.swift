// swift-tools-version:6.0
import PackageDescription

// A screen for one reading of the phone list: an app on the RELEASED SDK 3.1.4 (the package is pinned to exactly
// that version) that puts a sharing answer on the device, so that the screen of examples/DownloadCheck, installed
// over it with the same bundle id, finds what a 3.1.4 install leaves (an upgrade). It is a library, because an iOS
// app needs an Xcode project of your own:
//   1. In Xcode: File > New > Project > iOS > App (SwiftUI). Use the SAME bundle id as the DownloadCheck app.
//   2. File > Add Package Dependencies > Add Local: this folder. Add the library UpgradeSeed to the app.
//   3. Replace the project's App file by the few lines at the top of Sources/UpgradeSeed/UpgradeSeed.swift.
let package = Package(
    name: "UpgradeSeed",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "UpgradeSeed", targets: ["UpgradeSeed"])],
    dependencies: [.package(url: "https://github.com/Quran-Lab/tajweedformer-apple", exact: "3.1.4")],
    targets: [
        .target(name: "UpgradeSeed", dependencies: [.product(name: "TajweedFormer", package: "tajweedformer-apple")]),
    ],
    swiftLanguageModes: [.v6]
)
