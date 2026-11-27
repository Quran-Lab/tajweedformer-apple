import Foundation

// SDK 4.0.5: the value of a cause apart from the functions that make it (ErrorCause.swift), so the report's rules
// (ErrorRules, ErrorReportBook, CauseChain) build and are tested on Linux too (scripts/linux_logic_tests.sh).

/// What a failure was, as an error report names it: the
/// stage where the CAUSE is (not the call that failed), a reason token, the HTTP status of the answer that failed, and
/// the platform error's class and code. Never a message, a path, a URL or an identifier: every field is a token, a
/// small number or absent.
struct ErrorCause: Sendable, Equatable {
    var stage: String
    var reason: String
    var httpStatus: Int? = nil
    /// An `NSError` domain or a Swift error type.
    var errorName: String? = nil
    /// An `NSError` code, the server's `error` of a 4xx, a Core status.
    var errorCode: String? = nil
    /// The attempts the SDK made inside the failing call beyond the first.
    var retries: Int? = nil
    /// Part of the build was on the device when it failed (24.4's `partial`). Never sent.
    var partial = false
    /// SDK 4.0.1 (24.2, 28.7): the role of the request the cause is (`api`, `models`), on the stages of a request to a
    /// host of 28.1; never a host name.
    var hostRole: String? = nil
    /// SDK 4.0.1: that request was asked of more than one host (a failover happened in it).
    var fallback: Bool? = nil
    /// SDK 4.0.5 (ATTEST_40.md 40.6): the operation's hops before this cause (`CauseChain`), the last 8; nil when the
    /// cause was made outside an operation or the operation recorded none.
    var chain: [CauseHop]? = nil

    /// Two causes are the same failure whatever path led to them: the chain is the occurrence's, as `retries` and the
    /// device snapshot are (24.5), and it never takes part in a cause's equality (a test that means it compares it).
    static func == (a: ErrorCause, b: ErrorCause) -> Bool {
        a.stage == b.stage && a.reason == b.reason && a.httpStatus == b.httpStatus && a.errorName == b.errorName
            && a.errorCode == b.errorCode && a.retries == b.retries && a.partial == b.partial && a.hostRole == b.hostRole
            && a.fallback == b.fallback
    }
}
