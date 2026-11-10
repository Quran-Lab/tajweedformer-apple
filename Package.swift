// swift-tools-version:6.0
import PackageDescription

// TajweedFormer SDK 2.0.2: TajweedFormer V4 on iPhone and Mac (sdk/v4.0: every head of the network, the decoded
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
        .binaryTarget(name: "TajweedFormerCore", path: "TajweedFormerCore.xcframework"),
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
            dependencies: ["TajweedFormerCore", "COpus"],
            resources: [.copy("Resources/SelfTest"), .copy("Resources/SharingCopy")]
        ),
        .testTarget(name: "TajweedFormerTests", dependencies: ["TajweedFormer", "COpus"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
