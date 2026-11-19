#if DEBUG
import Foundation

/// Two hooks for the staging fault runs of a hosted test (Stage B), in debug builds only: a release build compiles
/// none of this, so no shipped binary can set them. Internal, reached by a test through `@testable import`.
enum StagingHooks {
    /// Hosts, besides Quran Lab's own, whose https model folder `ProtectedRuntime.acceptedBase` takes from a lease
    /// answer (the staging CDN). Empty by default.
    static let baseHosts = Locked<Set<String>>([])
    /// The clocks the next Client's protected runtime judges its lease by (a test moves them past `exp`). Nil by
    /// default: the system's clocks.
    static let clocks = Locked<(any CoreClocks)?>(nil)
}
#endif
