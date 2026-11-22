// swift-tools-version:6.0
import PackageDescription

// TajweedFormer SDK 4.0.0: TajweedFormer on iPhone and Mac, on Quran Lab's closed Core. The model is encrypted end
// to end: the SDK downloads ciphertext, the Core installs it to this device's form and opens it from a lease, and no
// plaintext model file is ever written. The SDK holds the public parts: the API, audio, networking, the install's
// key store, the consent sheet and sharing.
let package = Package(
    name: "TajweedFormer",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TajweedFormer", targets: ["TajweedFormer"]),
    ],
    targets: [
        // The Core (quranlab-core), a dynamic framework per slice (ios-arm64, ios-arm64-simulator, macos-arm64) that
        // exports only the functions of qlcore.h. Published with each release;
        // SwiftPM checks it against the checksum below.
        .binaryTarget(name: "QuranLabCore", url: "https://cdn.quranlab.ai/sdk/apple/4.0.3/QuranLabCore.xcframework.zip", checksum: "c0ff71dbd6c2c99308507da1827c02d0735e9d7b21faa7610cd35abab80a0706"),
        // libopus 1.6.1 for sharing, compiled from its source like any other target (scripts/opus/vendor_opus.sh).
        .target(
            name: "COpus",
            exclude: ["COPYING"],
            cSettings: [
                .define("HAVE_CONFIG_H"), .define("OPUS_BUILD"),
                .headerSearchPath("."), .headerSearchPath("include/COpus"), .headerSearchPath("celt"),
                .headerSearchPath("silk"), .headerSearchPath("silk/float"), .headerSearchPath("silk/fixed"),
            ]
        ),
        .target(
            name: "TajweedFormer",
            dependencies: ["QuranLabCore", "COpus"],
            resources: [.copy("Resources/SelfTest"), .copy("Resources/SharingCopy"), .copy("Resources/Errors"),
                        .copy("Resources/Vocabulary"), .copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "TajweedFormerTests", dependencies: ["TajweedFormer", "COpus"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
