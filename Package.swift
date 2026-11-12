// swift-tools-version:6.0
import PackageDescription

// TajweedFormer SDK 3.0.2: TajweedFormer V4 on iPhone and Mac, as a pure inference engine (every head of the
// network and the decoded layer). Two backends behind one API: the exact CPU engine (the same bits on every
// device, always there) and, once promoted, the CoreML build on the Neural Engine (iOS 18, macOS 15), both from
// one signed model folder.
let package = Package(
    name: "TajweedFormer",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TajweedFormer", targets: ["TajweedFormer"]),
    ],
    targets: [
        // Built by scripts/build_xcframework.sh from the pinned engine (engine/), with ZF_RELEASE on: the exact
        // engine, the V4 tajweed library, inference only (zf_tajweed.h), and the CoreML sidecar rebuild (zf/zfs.h).
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
            resources: [.copy("Resources/SelfTest"), .copy("Resources/SharingCopy"), .copy("Resources/Errors"),
                        .copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "TajweedFormerTests", dependencies: ["TajweedFormer", "COpus"],
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
