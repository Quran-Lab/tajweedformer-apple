import Foundation

/// The words the SDK shows when it asks to share recitations, thanks the learner, and lets them stop or delete
/// (`quranlab.sharing-copy/1`, one deck per language, bundled in Resources/SharingCopy). Disclosure lines
/// (`sheet.what`, `sheet.who`, `sheet.control`, `what.detail`, `delete.*`, the guardian lines) may be restyled, never
/// reworded, shortened or hidden. The hadith lines appear only from a deck whose hadith entry was verified
/// (`hadith_source.verified_at`).
public struct SharingCopy: Sendable, Hashable {
    public let lang: String
    public let version: String
    /// Right to left (Arabic, Urdu): lay the sheet out in this direction.
    public let rightToLeft: Bool
    /// Sent as the upload's `consent_version`: what the learner agreed to (the same in every language).
    public let consentVersion: String
    /// Fills `{days}` in the deletion lines.
    public let deleteDays: Int
    /// The hadith lines may be shown (the deck's entry was verified against its source).
    public let hadithVerified: Bool
    let strings: [String: String]
    let plurals: [String: [String: String]]

    /// A string by key, placeholders filled (`{days}`); empty when the deck has none.
    public func string(_ key: String) -> String {
        if (key == "sheet.hadith" || key == "sheet.hadith_ref") && !hadithVerified { return "" }
        return (strings[key] ?? "").replacingOccurrences(of: "{days}", with: String(deleteDays))
    }

    /// The impact line for the learner's real shared minutes (rounded down), with the language's plural form.
    public func impact(minutes: Double) -> String {
        let n = Int(max(0, minutes.rounded(.down)))
        let forms = plurals["impact.minutes"] ?? [:]
        let category = Self.pluralCategory(n, lang: lang)
        let f = NumberFormatter()
        f.locale = Locale(identifier: lang)
        let text = forms[category] ?? forms["other"] ?? ""
        return text.replacingOccurrences(of: "{minutes}", with: f.string(from: NSNumber(value: n)) ?? String(n))
    }

    /// CLDR cardinal categories for the shipped languages (integers only).
    static func pluralCategory(_ n: Int, lang: String) -> String {
        switch lang {
        case "en", "tr", "ur", "bn": return n == 1 ? "one" : "other"
        case "fr": return n == 0 || n == 1 ? "one" : (n != 0 && n % 1_000_000 == 0 ? "many" : "other")
        case "ar":
            let m = n % 100
            if n == 0 { return "zero" }
            if n == 1 { return "one" }
            if n == 2 { return "two" }
            if (3...10).contains(m) { return "few" }
            if (11...99).contains(m) { return "many" }
            return "other"
        default: return "other"
        }
    }

    init(json: Data) throws(RecognizerError) {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              o["format"] as? String == "quranlab.sharing-copy/1",
              let lang = o["lang"] as? String, let version = o["version"] as? String,
              let cv = o["consent_version"] as? String, let raw = o["strings"] as? [String: Any] else {
            throw .manifestInvalid("not a quranlab.sharing-copy/1 deck")
        }
        self.lang = lang
        self.version = version
        consentVersion = cv
        rightToLeft = (o["dir"] as? String) == "rtl"
        deleteDays = (o["delete_days"] as? Int) ?? 30
        let hs = o["hadith_source"] as? [String: Any]
        hadithVerified = (hs?["verified"] as? Bool) == true || ((hs?["verified_at"] as? String)?.isEmpty == false)
        var s: [String: String] = [:], p: [String: [String: String]] = [:]
        for (k, v) in raw {
            if let t = v as? String { s[k] = t } else if let d = v as? [String: String] { p[k] = d }
        }
        strings = s
        plurals = p
    }

    /// The bundled deck for `locale` (its language), else English.
    public static func forLocale(_ locale: Locale?) -> SharingCopy {
        let lang = (locale ?? Locale.current).identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? "en"
        return bundled(lang) ?? bundled("en")!
    }

    static func bundled(_ lang: String) -> SharingCopy? {
        guard let dir = Bundle.module.url(forResource: "SharingCopy", withExtension: nil),
              let d = try? Data(contentsOf: dir.appendingPathComponent("\(lang).json")) else { return nil }
        return try? SharingCopy(json: d)
    }
}
