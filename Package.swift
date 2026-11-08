// swift-tools-version:6.0
import PackageDescription

// TajweedFormer SDK 2.0.0: TajweedFormer V4 on iPhone and Mac (sdk/v4.0: every head of the network, the decoded
// layer and the calibrated tajweed checks). Two backends behind one API: the CoreML package on the Neural Engine
// (iOS 18, macOS 15), and tajweedformer-sdk's exact CPU engine (the same bits on every device, always available as
// the fallback), both from one signed model folder.
let package = Package(
    name: "TajweedFormer",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TajweedFormer", targets: ["TajweedFormer"]),
    ],
    targets: [
        // Built by scripts/build_xcframework.sh from the pinned engine (engine/), with ZF_RELEASE on: the exact
        // engine, the V4 tajweed library (zf_tajweed.h: streams and scorer) and the CoreML sidecar rebuild (zf/zfs.h).
        .binaryTarget(name: "ZipformerCore", path: "ZipformerCore.xcframework"),
        // libopus 1.6.1 for sharing (module COpus), built by scripts/opus/build_opus_xcframework.sh
        // (reproducible: the same zip from any checkout) and attached to the release libopus-1.6.1-1.
        // The release asset of this repository (libopus-1.6.1-1).
        .binaryTarget(
            name: "COpus",
            url: "https://github.com/Quran-Lab/tajweedformer-apple/releases/download/libopus-1.6.1-1/Opus.xcframework.zip",
            checksum: "7729c0e3e06d86956c2d3dc066a0e3863a84e86ea0fee618cbaf42f6b9cfd48d"
        ),
        .target(
            name: "TajweedFormer",
            dependencies: ["ZipformerCore", "COpus"],
            resources: [.copy("Resources/SelfTest"), .copy("Resources/SharingCopy")]
        ),
        .testTarget(name: "TajweedFormerTests", dependencies: ["TajweedFormer", "COpus"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
