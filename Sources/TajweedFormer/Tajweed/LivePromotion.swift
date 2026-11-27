import Foundation

// Live promotion (SDK 4.0.5, contract section 30, `sdk_4.0.0/LIVE_PROMOTION_41.md`): a take that started on the exact
// CPU engine moves to the accelerator during the take, once the accelerator's build becomes ready. Until 4.0.4 the swap
// happened at a session boundary only (sdk_2.0.1 SPEC_PROMOTION.md 2 and 3), so a take started at launch ran on the CPU
// for its whole length while the promoted build was being loaded and warmed beside it.
//
// The rules and the take's decide are pure, in LiveTake.swift (`LiveRules`, `LiveTake`), replayed by the contract's
// vectors (`live_41.json`, format 2). The take runner (Failover.swift) feeds the decide and carries out its actions:
// - When (30.2): one attempt per take, never after a failover, never when the app asked for the CPU engine, in the
//   pipeline's own conditions, never in a stall (a chunk handed out late, an interruption), not after 1,140 s of audio,
//   not within 10 s of a source's end, not once the app asked the take to finish, and not when the signed config's
//   `flags.live_promotion` is false.
// - Rebuild, do not transplant (30.3): nothing of the CPU engine's state is copied. The accelerator is reset and fed
//   the take's audio from the earliest chunk start still in the 30 s ring, on its own serial queue, while the CPU
//   engine keeps serving; then it catches up with the audio that arrived meanwhile and gets each new piece the CPU
//   engine gets. A take of 30 s or less is replayed whole, which is exact.
// - Check before trusting (30.4): when the accelerator caught up, the newest W comparable chunks (W = max(4,
//   ceil(2 s / chunk))) of both engines are judged with the golden test's rule on raw outputs (`judge` here) and the
//   build's tolerance. An exact replay has that one window; one that is not exact up to two more.
// - Swap at a pause (30.5): from the commit on, at the boundary after the first CPU chunk whose last two frames are
//   blank or the word bar, or after 8 s of audio without one; never in a stall, and a stall that lasts 20 s ends the
//   attempt. Chunks up to it are the CPU's as handed out, the next ones the accelerator's; nothing is handed out twice,
//   and the app gets `backendChanged` with `fromChunk` the first accelerator chunk.
// Every attempt ends with one outcome (30.6); what it writes into the promotion record is the failover's rule for the
// same kind of trouble (AcceleratorController.liveEnded). After a swap the take is an accelerator take in every
// respect, the failover of 2.0.2 included.

enum LivePromotion {
    /// 30.3: the take's ring, 30 s of 16 kHz audio (the failover's, `PromotionPolicy.ringSeconds`).
    static let ringSamples = LiveRules.ringSamples

    /// How an attempt ended (30.6).
    enum Outcome: String, Sendable, Codable, CaseIterable {
        case swapped
        case mismatch
        case mismatchInexact = "mismatch_inexact"
        case accelFailed = "accel_failed"
        case stalled
        case aborted
    }

    /// What an outcome writes into the promotion record: the failover's rule for the same kind of trouble.
    enum RecordRule: String, Sendable {
        /// As a confirmed blank disagreement: a transient demotion; a second one turns the build off for the key.
        case disagreement
        /// As a deadline miss: demoted only after misses in 3 different sessions within 24 h.
        case deadlineMiss = "deadline_miss"
        /// As a failover of that cause (an exception, NaN or infinite, out of range, a deadline miss).
        case byCause = "by_cause"
    }

    /// 30.6: nil when the outcome writes nothing.
    static func recordRule(_ o: Outcome) -> RecordRule? { LiveRules.recordRule(o.rawValue).flatMap(RecordRule.init(rawValue:)) }

    /// The window check (30.4): the compared heads of the window's chunks, joined frame after frame for each engine,
    /// judged with the golden test's rule as one clean clip with no expected tokens (`GoldenRaw.evaluate`). Only the
    /// heads both engines returned are compared (the CPU engine computes the selected and kept heads, the accelerator
    /// all of them): a head one side lacks is not a shape failure here. `log_probs` is always compared.
    static func judge(cpu: HeadsBuffer, accelerator: HeadsBuffer, tolerance: GoldenRawTolerance?) -> LiveRules.Verdict {
        var c = GoldenRaw.heads(cpu), a = GoldenRaw.heads(accelerator)
        let both = Set(c.keys).intersection(a.keys)
        guard both.contains("log_probs") else { return .outside }
        c = c.filter { both.contains($0.key) }
        a = a.filter { both.contains($0.key) }
        let v = GoldenRaw.evaluate([GoldenRaw.Clip(id: "live", clean: true, expectedTokens: nil, cpu: c, accelerator: a)], tolerance: tolerance)
        return v.pass ? .within : .outside
    }

    /// 30.8, `flags.live_promotion` as the signed config's decoder keeps it: only a literal false turns it off.
    static func configOn(_ v: JSONValue?) -> Bool { v != .bool(false) }

    /// The thermal state as the rule reads it.
    static func thermal(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "critical"
        }
    }

    /// The pipeline's conditions as the rule reads them (a battery level below 0 is one the device does not give).
    static func device(_ p: PromotionConditions, finishing: Bool, sourceLeftSeconds: Double?) -> LiveRules.Device {
        LiveRules.Device(lowPower: p.lowPower, battery: p.battery.flatMap { $0 >= 0 ? Double($0) : nil }, charging: p.charging,
                         thermal: thermal(p.thermal), finishing: finishing, sourceLeftSeconds: sourceLeftSeconds)
    }
}

/// The live promotions of this process for `diagnose()` (30.10): counts and the last outcome; no identifier, no time.
/// Nil until an attempt started in the process, so a report before one is unchanged.
enum LiveDiagnosis {
    struct Stats: Sendable, Equatable {
        var attempts = 0
        var swaps = 0
        /// The most recent attempt's outcome, or `running`.
        var last = "running"
        /// The `fromChunk` of the most recent swap.
        var lastFromChunk: Int?
    }

    static let stats = Locked<Stats?>(nil)

    static func started() {
        stats.withLock { (s: inout Stats?) in
            var v = s ?? Stats()
            v.attempts += 1
            v.last = "running"
            s = v
        }
    }

    static func ended(_ o: LivePromotion.Outcome, fromChunk: Int?) {
        stats.withLock { (s: inout Stats?) in
            var v = s ?? Stats()
            v.last = o.rawValue
            if o == .swapped {
                v.swaps += 1
                v.lastFromChunk = fromChunk
            }
            s = v
        }
    }

    /// Tests: the process as before any attempt.
    static func reset() { stats.withLock { $0 = nil } }
}
