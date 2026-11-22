#if DEBUG
import Foundation

/// Hooks for the staging fault runs of a hosted test (Stage B) and for the tests that stand loopback servers in for
/// Quran Lab's hosts, in debug builds only: a release build compiles none of this, so no shipped binary can set them.
/// Internal, reached by a test through `@testable import`.
enum StagingHooks {
    /// Hosts, besides Quran Lab's own, whose https model folder `ProtectedRuntime.acceptedBase` takes from a lease
    /// answer (the staging CDN). Empty by default.
    static let baseHosts = Locked<Set<String>>([])
    /// The clocks the next Client's protected runtime judges its lease by (a test moves them past `exp`). Nil by
    /// default: the system's clocks.
    static let clocks = Locked<(any CoreClocks)?>(nil)
    /// SDK 4.0.1 (section 28): where a host NAME of a role is asked instead of `https://<name>`, for the tests that
    /// stand loopback servers in for Quran Lab's hosts (a config's endpoints name hosts, never origins). Empty by
    /// default; a release build has no such map.
    static let hostOrigins = Locked<[String: URL]>([:])
    /// SDK 4.0.1 Phase E: the proxy the next Client's foreground session goes through (`connectionProxyDictionary`,
    /// e.g. an HTTPS CONNECT proxy on the loopback that refuses the primary hosts), for a hosted test that runs the
    /// real SDK against production with some hosts unreachable for the test process only. Nil by default: the
    /// system's proxy settings. Background sessions are not changed.
    static let connectionProxy = Locked<[String: any Sendable]?>(nil)
    /// SDK 4.0.2: the Core's part of a model install, for the tests that run an install and a Session through the
    /// public Client (no stub server can give a lease the Core accepts): the lease answer of a build, each file's
    /// install to its device form, and whether the lease in force allows accelerator programs. Nil by default: the
    /// Core.
    static let core = Locked<CoreStandIn?>(nil)
    /// Tests only (SDK 4.0.2): told right before a lease the Core accepted is stored (`storeLease`), so a test can hold
    /// that store while a stop arrives.
    static let beforeLeaseStore = Locked<(@Sendable () -> Void)?>(nil)
}

/// What `StagingHooks.core` stands in for (`ProtectedRuntime.ensureLease`, `install`, `acceleratorAllowed`).
/// (untyped throws: a typed-throws function type as a generic argument needs iOS 18 / macOS 15 at run time)
struct CoreStandIn: Sendable {
    var lease: @Sendable (_ manifest: ModelManifest) async throws -> LeaseRecord
    var install: @Sendable (_ manifest: ModelManifest, _ decodedPath: String, _ folder: URL) throws -> Void
    var acceleratorAllowed: @Sendable () -> Bool? = { nil }
}
#endif
