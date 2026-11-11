// swift-tools-version:6.0
import PackageDescription

// The TajweedFormer quick start as a program you can run on a Mac:
//   swift run QuickStart            a sample clip of the model, no microphone
//   swift run QuickStart --listen   the microphone
// It needs your key in the environment: QURANLAB_KEY=qlk_v1_... (sdk.quranlab.ai).
// In your own package, replace the path dependency by the line of the README's Install section.
let package = Package(
    name: "QuickStart",
    platforms: [.iOS(.v15), .macOS(.v12)],
    dependencies: [.package(name: "TajweedFormer", path: "../..")],
    targets: [
        .executableTarget(name: "QuickStart", dependencies: [.product(name: "TajweedFormer", package: "TajweedFormer")]),
    ],
    swiftLanguageModes: [.v6]
)
