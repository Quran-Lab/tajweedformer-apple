import Foundation

/// The counters SDK 4.0 adds to a day: what was recited, measured by the SDK or reported by
/// the app, how it was judged by the app, when and how long learners recite, whether installs come back, and how the
/// protected model's lease fared. Counts only: no ayah number, no order, no time finer than the local hour's bucket
/// leaves the device.
struct RecitedDay: Codable, Equatable, Sendable {
    /// App-reported ranges of takes the detector counted nothing for (17.1): `app_ayahs`, `app_surah_ayahs`.
    var appAyahs = 0
    var appSurahAyahs: [String: Int] = [:]
    /// Measured ayahs per juz (17.8 `juz_ayahs`), and measured ayahs recited again in the same session.
    var juzAyahs: [String: Int] = [:]
    var repeatAyahs = 0
    /// Per finished take: `measured`, `context`, `none`, `app`, `recovered`, `dropped` (17.8 `recited_takes`).
    var recitedTakes: [String: Int] = [:]
    /// Finished takes and closed sessions by their seconds of audio (17.8 `take_s`, `session_s`).
    var takeSeconds = [Int](repeating: 0, count: 8)
    var sessionSeconds = [Int](repeating: 0, count: 7)
    /// Milliseconds of speech by the learner's local hour (17.8 `hour_speech_s`, sent as seconds).
    var hourSpeechMs: [String: Int] = [:]
    /// The lease's refreshes (17.8 `lease`): `ok`, and the failures by cause.
    var leaseOK = 0
    var leaseFailed: [String: Int] = [:]
    /// The app's judgement (17.9): `judged`, `judged_surah_ayahs`, `correct_surah_ayahs`, `judged_tenure`.
    var judged: [String: Int] = [:]
    var judgedSurahAyahs: [String: Int] = [:]
    var correctSurahAyahs: [String: Int] = [:]
    var tenure: [String: [String: Int]] = [:]
    /// Sealed into the first delta of an active day only (17.8 `learner`, `learner_gap`, `streak`), and once per UTC
    /// week (17.9 `trend`).
    var learner: [String: Int]?
    var learnerGap: String?
    var streak: String?
    var trend: String?

    var isEmpty: Bool { self == RecitedDay() }

    static let takeBuckets = (["le_5", "le_15", "le_30", "le_60", "le_120", "le_300", "le_600", "gt_600"], [5.0, 15, 30, 60, 120, 300, 600])
    static let sessionBuckets = (["le_60", "le_300", "le_600", "le_1200", "le_1800", "le_3600", "gt_3600"], [60.0, 300, 600, 1200, 1800, 3600])
    static let leaseCauses = ["offline", "refused", "expired", "clock", "attestation", "other"]
    static let recitedKeys = ["measured", "context", "none", "app", "recovered", "dropped"]
    static let judgedKeys = ["ayahs", "correct", "incorrect", "mistakes", "first", "first_correct", "repeat", "repeat_correct", "measured", "unpaired"]
    static let tenureKeys = ["w1", "w2_4", "m2_3", "later"]

    /// The groups `flags.metrics` switches (17.8, 17.9; absent or true: on), and the fields of each.
    static let groups: [String: [String]] = [
        "juz": ["juz_ayahs"], "hours": ["hour_speech_s"], "lengths": ["take_s", "session_s"],
        "learner": ["learner", "learner_gap", "streak"], "repeats": ["repeat_ayahs"], "health": ["recited_takes", "lease"],
        "judged": ["judged", "judged_surah_ayahs", "correct_surah_ayahs", "judged_tenure", "trend"],
    ]

    /// The body's fields of these counters, each left out when empty (the server's closed schema), and none of a group
    /// the signed config switches off.
    func fields(off: Set<String> = []) -> [String: Any] {
        var p: [String: Any] = [:]
        func clip(_ n: Int) -> Int { AnalyticsStore.clip(n) }
        func surahs(_ m: [String: Int]) -> [String: Int] {
            var out: [String: Int] = [:]
            for (k, v) in m { if let n = Int(k), (1...114).contains(n), v > 0 { out[String(n)] = clip(v) } }
            return out
        }
        if appAyahs > 0 { p["app_ayahs"] = clip(appAyahs) }
        let app = surahs(appSurahAyahs)
        if !app.isEmpty { p["app_surah_ayahs"] = app }
        var juz: [String: Int] = [:]
        for (k, v) in juzAyahs { if let n = Int(k), (1...30).contains(n), v > 0 { juz[String(n)] = clip(v) } }
        if !juz.isEmpty { p["juz_ayahs"] = juz }
        if repeatAyahs > 0 { p["repeat_ayahs"] = clip(repeatAyahs) }
        let takes = recitedTakes.filter { $0.value > 0 && Self.recitedKeys.contains($0.key) }.mapValues(clip)
        if !takes.isEmpty { p["recited_takes"] = takes }
        if takeSeconds.contains(where: { $0 > 0 }) { p["take_s"] = AnalyticsStore.hist(Self.takeBuckets.0, takeSeconds) }
        if sessionSeconds.contains(where: { $0 > 0 }) { p["session_s"] = AnalyticsStore.hist(Self.sessionBuckets.0, sessionSeconds) }
        var hours: [String: Double] = [:]
        for (k, ms) in hourSpeechMs { if let h = Int(k), (0...23).contains(h), ms > 0 { hours[String(h)] = min(86_400, Double(ms) / 1000) } }
        if !hours.isEmpty { p["hour_speech_s"] = hours }
        var lease: [String: Any] = [:]
        if leaseOK > 0 { lease["ok"] = clip(leaseOK) }
        let failed = leaseFailed.filter { $0.value > 0 && Self.leaseCauses.contains($0.key) }.mapValues(clip)
        if !failed.isEmpty { lease["failed"] = failed }
        if !lease.isEmpty { p["lease"] = lease }
        let j = judged.filter { $0.value > 0 && Self.judgedKeys.contains($0.key) }.mapValues(clip)
        if !j.isEmpty { p["judged"] = j }
        let js = surahs(judgedSurahAyahs), cs = surahs(correctSurahAyahs)
        if !js.isEmpty { p["judged_surah_ayahs"] = js }
        if !cs.isEmpty { p["correct_surah_ayahs"] = cs }
        var t: [String: [String: Int]] = [:]
        for (k, v) in tenure where Self.tenureKeys.contains(k) && (v["judged"] ?? 0) > 0 {
            t[k] = ["judged": clip(v["judged"] ?? 0), "correct": clip(min(v["correct"] ?? 0, v["judged"] ?? 0))]
        }
        if !t.isEmpty { p["judged_tenure"] = t }
        if let learner { p["learner"] = learner }
        if let learnerGap { p["learner_gap"] = [learnerGap: 1] }
        if let streak { p["streak"] = [streak: 1] }
        if let trend { p["trend"] = [trend: 1] }
        for g in off { for f in Self.groups[g] ?? [] { p[f] = nil } }
        return p
    }
}

/// A take whose count is not decided yet (17.6): opened in the Core's journal, finished there, and counted here in
/// the same atomic write that removes it, so a kill at any point neither loses nor doubles it.
struct PendingTake: Codable, Equatable, Sendable {
    var day: String
}

/// The analytics session that is open (17.8 `session_s`; the session of `repeat_ayahs` and of 17.9's first and repeat):
/// from the first take with audio until the app leaves the foreground, the Model closes or the Client ends. One a kill
/// left open is closed at the next start.
struct OpenAnalyticsSession: Codable, Equatable, Sendable {
    var day: String
    var audioMs = 0
}

/// One UTC week's judgement (17.9 `trend`).
struct JudgedWeek: Codable, Equatable, Sendable {
    var judged = 0
    var correct = 0
}

/// This install's own days, kept on the device and never sent (17.8): its first active UTC day, its active UTC days
/// and local days of the last weeks, the streak at each active day, which days' learner facts were sealed, and five
/// weeks of (judged, correct) for the trend (17.9).
///
/// R10 (quranlab-core cd24aa3): with a Core they live in the Core's recited journal (`qlc_days_*`, `CoreLearnerDays`),
/// and this is the view the facts are computed from; each change goes to the Core after the analytics state that
/// counts it is saved, so a kill in between can lose one mark, never count one twice. Without a Core (the tests, an
/// install before its first key) they stay in the analytics state, as before.
struct LearnerJournal: Codable, Equatable, Sendable {
    var firstDay: String?
    var activeDays: [String] = []
    var localDays: [String] = []
    var streaks: [String: Int] = [:]
    var sentDays: [String] = []
    var weeks: [String: JudgedWeek] = [:]
    var trendWeek: String?

    /// A take with audio on this UTC day and this local day.
    mutating func markActive(utc: String, local: String) {
        if firstDay.map({ utc < $0 }) ?? true { firstDay = utc }
        if !activeDays.contains(utc) { activeDays = Self.recent(activeDays + [utc], keep: 40) }
        if !localDays.contains(local) { localDays = Self.recent(localDays + [local], keep: 40) }
        streaks[utc] = streak(endingAt: local)
        streaks = streaks.filter { activeDays.contains($0.key) && $0.key >= (activeDays.suffix(10).first ?? $0.key) }
    }

    /// Consecutive active local days up to and including `local`.
    func streak(endingAt local: String) -> Int {
        var n = 0
        var d: String? = local
        while let day = d, localDays.contains(day) {
            n += 1
            d = DayMath.add(day, -1)
        }
        return n
    }

    /// The learner facts of an active UTC day, once (nil for a day that was not active or was sent already); marks it
    /// sent.
    mutating func takeFacts(for day: String) -> (learner: [String: Int], gap: String, streak: String)? {
        guard activeDays.contains(day), !sentDays.contains(day), let first = firstDay, let since = DayMath.days(from: first, to: day) else {
            return nil
        }
        sentDays = Self.recent(sentDays + [day], keep: 10)
        let learner = ["active": 1, "new": since == 0 ? 1 : 0, "d1": since == 1 ? 1 : 0, "d7": since == 7 ? 1 : 0, "d30": since == 30 ? 1 : 0]
        let gap: String
        if let prev = activeDays.filter({ $0 < day }).max(), let n = DayMath.days(from: prev, to: day) {
            gap = n > 30 ? "gt_30" : String(n)
        } else {
            // no earlier day in the kept weeks: the first day itself, or one more than 30 days back
            gap = first == day ? "new" : "gt_30"
        }
        let s = streaks[day] ?? 1
        let bucket = s >= 30 ? "ge_30" : s >= 14 ? "14_29" : s >= 7 ? "7_13" : s >= 4 ? "4_6" : s >= 2 ? "2_3" : "1"
        return (learner, gap, bucket)
    }

    /// One judged ayah on a UTC day.
    mutating func judged(on day: String, correct: Bool) {
        guard let w = DayMath.monday(day) else { return }
        var x = weeks[w] ?? JudgedWeek()
        x.judged += 1
        if correct { x.correct += 1 }
        weeks[w] = x
        let keep = Set(Self.recent(Array(weeks.keys), keep: 6))
        weeks = weeks.filter { keep.contains($0.key) }
    }

    /// 17.9's trend of the week that ended last before `day`, once per week: the install's last week against its four
    /// weeks before; both need 20 judged ayahs, else `not_enough`; a move of the correct share by 5 points or more is
    /// `better` or `worse`, else `same`. Nil when it was sent already, or when none of those five weeks holds a judged
    /// ayah (an app that judges nothing sends no trend).
    mutating func takeTrend(sealing day: String) -> String? {
        guard let thisWeek = DayMath.monday(day), let last = DayMath.add(thisWeek, -7) else { return nil }
        if let sent = trendWeek, sent >= last { return nil }
        let lw = weeks[last] ?? JudgedWeek()
        var pw = JudgedWeek()
        for k in 1...4 {
            guard let w = DayMath.add(last, -7 * k), let x = weeks[w] else { continue }
            pw.judged += x.judged
            pw.correct += x.correct
        }
        guard lw.judged + pw.judged > 0 else { return nil }
        trendWeek = last
        guard lw.judged >= 20, pw.judged >= 20 else { return "not_enough" }
        let move = 100 * (Double(lw.correct) / Double(lw.judged) - Double(pw.correct) / Double(pw.judged))
        return move >= 5 ? "better" : move <= -5 ? "worse" : "same"
    }

    /// The days since the first active day, as 17.9's tenure: 0 to 6 `w1`, 7 to 27 `w2_4`, 28 to 89 `m2_3`, 90 on `later`.
    func tenure(on day: String) -> String {
        let n = firstDay.flatMap { DayMath.days(from: $0, to: day) } ?? 0
        return n < 7 ? "w1" : n < 28 ? "w2_4" : n < 90 ? "m2_3" : "later"
    }

    static func recent(_ days: [String], keep: Int) -> [String] { Array(Set(days).sorted().suffix(keep)) }

    init() {}

    /// The Core's days (R10) as this view: days since 1970-01-01 as `yyyy-MM-dd`.
    init(core d: CoreDays) {
        func s(_ n: Int64) -> String? { n >= 0 ? DayMath.string(number: n) : nil }
        firstDay = s(d.firstDay)
        activeDays = d.active.compactMap(s)
        localDays = d.local.compactMap(s)
        for (k, v) in d.streaks { if let day = s(k) { streaks[day] = v } }
        sentDays = d.sealed.compactMap(s)
        for (k, v) in d.weeks { if let w = s(k) { weeks[w] = JudgedWeek(judged: v.judged, correct: v.correct) } }
        trendWeek = s(d.trendWeek)
    }
}

/// Where the learner's days live (R10): the Core's journal, or (nil source) the analytics state.
protocol LearnerDaysSource: Sendable {
    /// The days now; nil when the source cannot say (no Core yet).
    func read() -> LearnerJournal?
    func mark(utc: String, local: String)
    func judged(utc: String, judged: Int, correct: Int)
    func seal(utc: String)
    func trendSent(week: String)
}

/// The learner's days in the Core's recited journal (`qlc_days_mark`, `_judged`, `_seal`, `_trend_sent`, `_read`).
struct CoreLearnerDays: LearnerDaysSource {
    let host: @Sendable () -> CoreHost?

    func read() -> LearnerJournal? { host()?.daysRead().map(LearnerJournal.init(core:)) }

    func mark(utc: String, local: String) {
        guard let h = host(), let u = DayMath.number(utc), let l = DayMath.number(local) else { return }
        h.daysMark(utc: u, local: l)
    }

    func judged(utc: String, judged: Int, correct: Int) {
        guard judged > 0, let h = host(), let u = DayMath.number(utc) else { return }
        h.daysJudged(utc: u, judged: judged, correct: correct)
    }

    func seal(utc: String) {
        guard let h = host(), let u = DayMath.number(utc) else { return }
        h.daysSeal(utc: u)
    }

    func trendSent(week: String) {
        guard let h = host(), let w = DayMath.number(week) else { return }
        h.daysTrendSent(week: w)
    }
}

/// Day arithmetic on `yyyy-MM-dd` strings: UTC days, and the learner's local day.
enum DayMath {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func string(_ date: Date, _ cal: Calendar = utc) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func days(from a: String, to b: String) -> Int? {
        guard let x = date(a), let y = date(b) else { return nil }
        return utc.dateComponents([.day], from: x, to: y).day
    }

    static func add(_ day: String, _ n: Int) -> String? {
        guard let d = date(day), let e = utc.date(byAdding: .day, value: n, to: d) else { return nil }
        return string(e)
    }

    /// Days since 1970-01-01, the Core's day numbers (R5, R10).
    static func number(_ day: String) -> Int64? { days(from: "1970-01-01", to: day).map(Int64.init) }

    static func string(number n: Int64) -> String? { add("1970-01-01", Int(n)) }

    /// The Monday that starts the UTC week (Monday to Sunday) of a day.
    static func monday(_ day: String) -> String? {
        guard let d = date(day) else { return nil }
        let weekday = utc.component(.weekday, from: d)   // 1 Sunday ... 7 Saturday
        return add(day, -((weekday + 5) % 7))
    }

    /// The device's local day of a moment (the streak's day, 17.8).
    static func local(_ date: Date, _ zone: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return string(date, c)
    }

    /// The device's local hour of a moment (17.8 `hour_speech_s`; only the bucket leaves the device).
    static func localHour(_ date: Date, _ zone: TimeZone = .current) -> Int {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c.component(.hour, from: date)
    }
}

/// The juz of an ayah (Hafs, the 30 standard parts): the starts of juz 1 to 30 as (surah, ayah).
enum QuranParts {
    static let juzStarts: [(Int, Int)] = [
        (1, 1), (2, 142), (2, 253), (3, 93), (4, 24), (4, 148), (5, 83), (6, 111), (7, 88), (8, 41), (9, 93), (11, 6), (12, 53),
        (15, 1), (17, 1), (18, 75), (21, 1), (23, 1), (25, 21), (27, 56), (29, 46), (33, 31), (36, 28), (39, 32), (41, 47), (46, 1),
        (51, 31), (58, 1), (67, 1), (78, 1),
    ]

    static func juz(surah: Int, ayah: Int) -> Int {
        var j = 1
        for (i, s) in juzStarts.enumerated() where (surah, ayah) >= s { j = i + 1 }
        return j
    }
}

extension AnalyticsStore {
    /// The ayahs of an ayah key set (surah * 1000 + ayah).
    static func key(_ surah: Int, _ ayah: Int) -> Int { surah * 1000 + ayah }

    /// A take opened in the Core's journal: pending until it is counted.
    func recitedBegan(_ take: UInt64) {
        mutate { d, s in
            var p = s.recitedPending ?? [:]
            p[String(take)] = PendingTake(day: d.day)
            s.recitedPending = p
        }
        saveNow()
    }

    /// A take that was cancelled or failed: finished in the journal, counted nowhere.
    func recitedDropped(_ take: UInt64) {
        mutate { _, s in s.recitedPending?[String(take)] = nil }
        saveNow()
    }

    /// The takes still pending (the runtime finishes them again at a start; the Core answers with the stored result).
    var pendingTakeIDs: [UInt64] { stateSnapshot.recitedPending.map { $0.keys.compactMap { UInt64($0) } } ?? [] }

    /// A take the Core finished at a start (17.6): counted as recovered, once.
    func countRecovered(take: UInt64, measured: CoreRecited?) {
        count(take: take, measured: measured, report: nil, late: false, recovered: true)
    }

    /// One finished take's count (17.1): the detector's range when it counted one (an app report then adds only its
    /// outcomes, paired with the measured ayahs, 17.9); else the app's report; else nothing. `late`: a report that
    /// came after the take ended (its take was counted already, so only the report's part counts now).
    func count(take: UInt64?, measured: CoreRecited?, report: SessionShared.Recited?, late: Bool, recovered: Bool = false) {
        let judgedSession = self.judgedAyahs, recitedSession = self.sessionAyahs
        let days = learnerDays.withLock { $0 }
        let coreJournal = days?.read()
        var judgedDelta: (day: String, judged: Int, correct: Int)?
        mutate { d, s in
            if let take {
                // counted once: a take that is not pending any more was counted already
                guard s.recitedPending?[String(take)] != nil else { return }
                s.recitedPending?[String(take)] = nil
            }
            var v = d.v4 ?? RecitedDay()
            var journal = coreJournal ?? s.learner ?? LearnerJournal()
            let week = DayMath.monday(d.day) ?? d.day
            let before = journal.weeks[week] ?? JudgedWeek()
            if let m = measured, (1...114).contains(m.surah), m.first >= 1, m.last >= m.first {
                if !late {
                    let n = m.last - m.first + 1
                    d.ayahs += n
                    d.surahAyahs[String(m.surah), default: 0] += n
                    v.recitedTakes["measured", default: 0] += 1
                    // R5: a take the session context (the last counted take) decided
                    if m.context { v.recitedTakes["context", default: 0] += 1 }
                    for a in m.first...m.last {
                        v.juzAyahs[String(QuranParts.juz(surah: m.surah, ayah: a)), default: 0] += 1
                        let fresh = recitedSession.withLock { $0.insert(Self.key(m.surah, a)).inserted }
                        if !fresh { v.repeatAyahs += 1 }
                    }
                }
                if let r = report {
                    Self.judge(r, ayahs: Array(m.first...m.last), surah: m.surah, measured: m, into: &v, day: &d, journal: &journal,
                               session: judgedSession)
                }
            } else if let r = report {
                let n = r.ayahTo - r.ayahFrom + 1
                v.appAyahs += n
                v.appSurahAyahs[String(r.surah), default: 0] += n
                v.recitedTakes["app", default: 0] += 1
                Self.judge(r, ayahs: Array(r.ayahFrom...r.ayahTo), surah: r.surah, measured: nil, into: &v, day: &d, journal: &journal,
                           session: judgedSession)
            } else if !late, take != nil {
                // the detector ran on this take and counted nothing, and the app reported nothing
                v.recitedTakes["none", default: 0] += 1
            }
            if recovered { v.recitedTakes["recovered", default: 0] += 1 }
            d.v4 = v
            let after = journal.weeks[week] ?? JudgedWeek()
            if after.judged > before.judged { judgedDelta = (d.day, after.judged - before.judged, after.correct - before.correct) }
            if coreJournal == nil { s.learner = journal }
        }
        saveNow()
        if let days, coreJournal != nil, let j = judgedDelta { days.judged(utc: j.day, judged: j.judged, correct: j.correct) }
    }

    /// The app's outcomes of a take (17.9), on `ayahs` of `surah`: the whole-range outcome on every ayah `perAyah` does
    /// not name; a `perAyah` entry outside the measured range is dropped (`unpaired`). Each rule of an incorrect ayah adds
    /// 1 to the day's checks and flags of that rule. A range outcome's mistakes count once for the range (decided
    /// 11-14). Each judged ayah counts toward the install's tenure and its week (17.9 `judged_tenure`, `trend`).
    static func judge(_ r: SessionShared.Recited, ayahs: [Int], surah: Int, measured: CoreRecited?, into v: inout RecitedDay,
                      day d: inout Day, journal: inout LearnerJournal, session: Locked<Set<Int>>) {
        guard r.outcome != nil || !r.perAyah.isEmpty else { return }
        for (a, _) in r.perAyah where measured != nil && (surah != r.surah || !ayahs.contains(a)) { v.judged["unpaired", default: 0] += 1 }
        if case .incorrect(let m, _) = r.outcome, let m { v.judged["mistakes", default: 0] += m }
        let tenure = journal.tenure(on: d.day)
        for a in ayahs {
            let o: TajweedRecitedOutcome? = (surah == r.surah ? r.perAyah[a] : nil) ?? r.outcome
            guard let o else { continue }
            let first = session.withLock { $0.insert(key(surah, a)).inserted }
            v.judged["ayahs", default: 0] += 1
            v.judgedSurahAyahs[String(surah), default: 0] += 1
            v.tenure[tenure, default: [:]]["judged", default: 0] += 1
            journal.judged(on: d.day, correct: o.isCorrect)
            if measured != nil { v.judged["measured", default: 0] += 1 }
            v.judged[first ? "first" : "repeat", default: 0] += 1
            if o.isCorrect {
                v.judged["correct", default: 0] += 1
                v.judged[first ? "first_correct" : "repeat_correct", default: 0] += 1
                v.correctSurahAyahs[String(surah), default: 0] += 1
                v.tenure[tenure, default: [:]]["correct", default: 0] += 1
            } else if case .incorrect(let m, let rules) = o {
                v.judged["incorrect", default: 0] += 1
                if r.perAyah[a] != nil, let m { v.judged["mistakes", default: 0] += m }
                for rule in Set(rules) where ruleKey(rule) {
                    d.ruleChecks[rule, default: 0] += 1
                    d.ruleFlags[rule, default: 0] += 1
                }
            }
        }
    }

    /// One lease request's outcome (17.8 `lease`).
    func recordLease(_ o: LeaseOutcome) {
        mutate { d, _ in
            var v = d.v4 ?? RecitedDay()
            if o == .ok { v.leaseOK += 1 } else { v.leaseFailed[o.rawValue, default: 0] += 1 }
            d.v4 = v
        }
    }

    /// A take with audio (17.8): the day is active, the take's seconds (`take_s`, finished takes only), its speech by
    /// local hour (`hour_speech_s`), and its audio into the open session (`session_s`).
    func recordTake(_ t: SessionTelemetry) {
        let now = clock()
        let local = DayMath.local(now)
        let days = learnerDays.withLock { $0 }
        var active: String?
        mutate { d, s in
            var v = d.v4 ?? RecitedDay()
            if days == nil {
                var journal = s.learner ?? LearnerJournal()
                journal.markActive(utc: d.day, local: local)
                s.learner = journal
            } else {
                active = d.day
            }
            if t.counts, t.audioMs > 0 { v.takeSeconds[Histogram.index(Double(t.audioMs) / 1000, RecitedDay.takeBuckets.1)] += 1 }
            if t.counts { for (h, ms) in t.hourSpeechMs where ms > 0 { v.hourSpeechMs[String(h), default: 0] += ms } }
            var session = s.openSession ?? OpenAnalyticsSession(day: d.day)
            session.audioMs += max(0, Int((t.audioSeconds * 1000).rounded()))
            s.openSession = session
            d.v4 = v
        }
        if let days, let active { days.mark(utc: active, local: local) }
    }

    /// The analytics session ends (the app left the foreground, the Model closed, the Client ended, or a kill left one
    /// open): its seconds of audio into `session_s`, and the session's sets of counted and judged ayahs start again.
    func closeSession() {
        mutate { d, s in
            guard let o = s.openSession else { return }
            s.openSession = nil
            guard o.audioMs > 0 else { return }
            var v = d.v4 ?? RecitedDay()
            v.sessionSeconds[Histogram.index(Double(o.audioMs) / 1000, RecitedDay.sessionBuckets.1)] += 1
            d.v4 = v
        }
        sessionAyahs.withLock { $0 = [] }
        judgedAyahs.withLock { $0 = [] }
        saveNow()
    }

    /// The facts sealed into a day's first delta (17.8, 17.9): `learner`, `learner_gap` and `streak` once per active
    /// day, `trend` once per UTC week; written in the same state as the delta that carries them.
    /// `core`: the Core's days (R10), changed here as the facts are taken; the day sealed and the trend's week are
    /// returned, for the Core once the state is saved. Without it the analytics state's days.
    @discardableResult
    static func sealFacts(_ d: inout Day, _ s: inout State, off: Set<String>, core: inout LearnerJournal?)
        -> (sealed: String?, trendWeek: String?) {
        var journal = core ?? s.learner ?? LearnerJournal()
        let trendBefore = journal.trendWeek
        var v = d.v4 ?? RecitedDay()
        var sealed: String?
        if !off.contains("learner"), let f = journal.takeFacts(for: d.day) {
            v.learner = f.learner
            v.learnerGap = f.gap
            v.streak = f.streak
            sealed = d.day
        }
        if !off.contains("judged"), let t = journal.takeTrend(sealing: d.day) { v.trend = t }
        if core != nil { core = journal } else { s.learner = journal }
        if !v.isEmpty { d.v4 = v }
        return (sealed, journal.trendWeek != trendBefore ? journal.trendWeek : nil)
    }
}
