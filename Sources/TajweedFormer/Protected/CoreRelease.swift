import Foundation

/// The Core release this SDK is pinned to: Core 4.0.0-c3 (quranlab-core f006676 with its Apple build fix; contract
/// sdk-4.0.0-protected 1c971ab), as Android's and C's `CORE_RELEASE`. The binaries are not in this repository:
/// `scripts/build_core_xcframework.py --from-release <the release's folder>` wraps the release's shipped dylibs into
/// QuranLabCore.xcframework (the install name becomes the framework's, the integrity regions stay as they are), and
/// `CoreReleasePinTests` checks a build linked against it (the production pins). The unit tests link the test release
/// 4.0.0-c1 instead (`--test-release`, the contract's test root).
enum CoreRelease {
    static let release = "4.0.0-c3"
    static let core = "quranlab-core f006676"
    /// SDK 4.0.2: the SwiftPM checksum (SHA-256) of the published QuranLabCore.xcframework.zip, the release tools'
    /// `--core-checksum`. The binaries are the c3 ones 4.0.0 and 4.0.1 shipped, byte for byte (`slices`); only each
    /// slice's Info.plist changed (`scripts/build_core_xcframework.py --repack`): `CFBundleVersion` is the build number
    /// 3, which App Store Connect requires to be up to three period-separated integers (it refused "4.0.0-c3"), and the
    /// release is in `QLCoreRelease`. 4.0.0 and 4.0.1 shipped
    /// 5a3bfa4223c8887f04d544e8e5c73b6ad74c9b947d8fa0c70df151f49c42d797.
    static let xcframeworkZip = "c0ff71dbd6c2c99308507da1827c02d0735e9d7b21faa7610cd35abab80a0706"
    /// The build number in the Core framework's `CFBundleVersion` (`--repack`'s `bundle_version`: the n of "-cn").
    static let bundleVersion = "3"

    struct Slice: Sendable, Equatable {
        /// The integrity digest in the server's `core_releases` row for this target.
        let digest: String
        /// SHA-256 of the release's shipped `qlcore.dylib`.
        let shipped: String
        /// SHA-256 of the framework binary `--from-release` makes from it (the same code; install name and ad hoc
        /// signature only).
        let framework: String
    }

    /// The xcframework's slices (the Core's macos-x86_64 is not shipped: the SDK is for Apple silicon Macs).
    static let slices: [String: Slice] = [
        "ios-arm64": Slice(digest: "a7007b82fd150c7c89fa1fce73c77610ecb1e839ce2c403eb9bca1cc017f3814",
                           shipped: "ecb146ebf8071deb00488a79f965bb8ce522ed0212cb91a27431b082f8a6ff27",
                           framework: "461354675a7d8c4f1b24efdd38e0664bb44fb6b27c52cf7bfd47bf27e09438c7"),
        "ios-arm64-simulator": Slice(digest: "403bfa847f9f9b6ce6597f7305d5833234285f36ee5e751742804e0d2006e40b",
                                     shipped: "e71dc398bbe16c428559a55c8937e5247ef9c91f99b4b689cf745eaff00be8e6",
                                     framework: "8b9c2032621060b36110c134c9ce23baaccceebe49259fcd8d58533b0922b831"),
        "macos-arm64": Slice(digest: "519de1203df6cfc5f27bc3055c91c1752f7e37b63dc031de6e9547caf63ed101",
                             shipped: "324d56cdc334c3444b16e03d6faad9497ce457fc8f820ca7915daf4a8de245bb",
                             framework: "b89329ff45932b44139f9b299315c7d7bcd0258e78d379e7b873cfdafc3aaac2"),
    ]

    /// Every function of qlcore.h the SDK knows (65): the pinned c3 header's 63 (the grace's `qlc_lease_attempt` and
    /// `qlc_lease_grace` among them) and the two of spec fix 17 (`clockAnchorFunctions`).
    static let functions = [
        "qlc_accel_allowed", "qlc_accel_prepare", "qlc_accel_release", "qlc_attest_sig", "qlc_calibration",
        "qlc_clock_ask", "qlc_create",
        "qlc_days_judged", "qlc_days_mark", "qlc_days_read", "qlc_days_seal", "qlc_days_trend_sent", "qlc_destroy",
        "qlc_detail", "qlc_install", "qlc_lease_accept", "qlc_lease_ask", "qlc_lease_attempt", "qlc_lease_eph",
        "qlc_lease_grace", "qlc_lease_piece", "qlc_lease_time", "qlc_model_chunk_ms", "qlc_model_close", "qlc_model_open",
        "qlc_model_token_count", "qlc_model_token_name", "qlc_notice", "qlc_open_default_options", "qlc_recited_begin",
        "qlc_recited_done", "qlc_recited_feed", "qlc_recited_feed_stream", "qlc_recited_finish", "qlc_recited_index",
        "qlc_recited_open", "qlc_recited_reported", "qlc_recited_totals", "qlc_reference_ayah_count",
        "qlc_reference_expected", "qlc_refusal_accept", "qlc_resampler_create", "qlc_resampler_destroy",
        "qlc_resampler_finish", "qlc_resampler_max_out", "qlc_resampler_push", "qlc_resampler_reset", "qlc_set_site",
        "qlc_stream_backend", "qlc_stream_create", "qlc_stream_create_on", "qlc_stream_destroy", "qlc_stream_finish",
        "qlc_stream_greedy", "qlc_stream_heads", "qlc_stream_push", "qlc_stream_push_s16", "qlc_stream_reset",
        "qlc_stream_set_callback", "qlc_stream_set_heads", "qlc_stream_topk", "qlc_tick", "qlc_topk", "qlc_usage",
        "qlc_version",
    ]

    /// The exports of spec fix 17 (quranlab-core clock-anchor, `QLC_CLOCK_ANCHOR`): the lease answer's signed time and
    /// the clock record for a route other than the lease's. Not in the pinned release 4.0.0-c3, whose binaries are
    /// built: the SDK finds `qlc_lease_time` by name at run time (`CoreOptional.leaseTime`) and calls nothing with c3.
    /// A Core release that carries spec fix 17 exports both.
    static let clockAnchorFunctions = ["qlc_clock_ask", "qlc_lease_time"]
}
