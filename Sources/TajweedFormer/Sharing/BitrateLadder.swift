import Foundation

/// The adaptive Opus bitrate of shared sessions (SDK 2.0.1, the same rules in every TajweedFormer SDK; the shared
/// vector `bitrate_ladder.json` replays them). Rungs 192, 96, 64 and 32 kbit/s; a process starts at the top.
///
/// - `uploadFailed()`: a shared-session upload request failed for network reasons (no connection, a timeout, HTTP 408
///   or 5xx) on POST /v1/uploads, POST /v1/uploads/{id}/urls or a segment PUT: one rung down, the success streak back
///   to 0. Refusals (a 403 on an expired URL, other 4xx, 429 volume limits) and waits (sharing paused by the config)
///   are not network failures.
/// - `uploadOk(backlogSeconds:)`: a segment PUT answered 2xx, with the seconds of closed audio still waiting after it:
///   the streak grows (at most 3); at 3 with at most 30 s waiting and not at the top, one rung up and the streak back
///   to 0.
/// - `segmentClosed(backlogSeconds:)`: a capture closed a segment, with the seconds of closed audio not yet uploaded
///   (every session in the outbox, this one included): at 120 s or more, one rung down and the streak back to 0.
///
/// The encoder takes `bitrate` when a segment opens (before its first packet), so each segment has one bitrate.
/// Tried and rejected: changing the bitrate mid-segment (a segment would have no single bitrate to record); keeping
/// the rung across launches (a stale bad network would cost quality on a good one); rungs below 32 kbit/s (log-mel
/// error on recitation 1.17 dB at 32k but 1.60 at 24k and 2.48 at 16k, for about 0.07 MB a minute saved per step).
final class BitrateLadder: @unchecked Sendable {
    /// The rungs in bit/s, top first.
    static let rungs = [192_000, 96_000, 64_000, 32_000]
    static let upStreak = 3
    static let upMaxBacklog = 30.0
    static let downBacklog = 120.0

    private let lock = NSLock()
    private var rung = 0
    private var streak = 0

    init() {}

    /// The bitrate the next segment opens with.
    var bitrate: Int {
        lock.lock(); defer { lock.unlock() }
        return Self.rungs[rung]
    }

    func uploadFailed() {
        lock.lock(); defer { lock.unlock() }
        rung = min(rung + 1, Self.rungs.count - 1)
        streak = 0
    }

    func uploadOk(backlogSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        streak = min(streak + 1, Self.upStreak)
        if streak >= Self.upStreak && backlogSeconds <= Self.upMaxBacklog && rung > 0 {
            rung -= 1
            streak = 0
        }
    }

    func segmentClosed(backlogSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if backlogSeconds >= Self.downBacklog {
            rung = min(rung + 1, Self.rungs.count - 1)
            streak = 0
        }
    }
}
