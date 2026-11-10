import CryptoKit
import Foundation

/// The words the SDK shows when it asks to share recitations, thanks the learner, and lets them stop or delete
/// (`quranlab.sharing-copy/1`, one deck per language, bundled in Resources/SharingCopy). Disclosure lines
/// (`sheet.what`, `sheet.who`, `sheet.control`, `what.detail`, `delete.*`, the guardian lines) may be restyled, never
/// reworded, shortened or hidden by the deck's own rules; an app that wants its own words sets them with
/// `Contributions.setWording(_:)`, and the learner then agrees to those words under their own consent version. The
/// hadith lines appear only from a deck whose hadith entry was verified (`hadith_source.verified_at`).
public struct SharingCopy: Sendable, Hashable {
    public let lang: String
    public let version: String
    /// Right to left (Arabic, Urdu): lay the sheet out in this direction.
    public let rightToLeft: Bool
    /// Sent as the upload's `consent_version`: what the learner agreed to (the same in every language). The deck's own
    /// version, or with the app's own wording `custom-` and the first 24 hex digits of `consentTextSHA256`.
    public private(set) var consentVersion: String
    /// The deck's own consent version, whatever wording the app set.
    public let baseConsentVersion: String
    /// With the app's own wording: the SHA-256 (lower-case hex) of `consentText`, sent with every shared session as
    /// `consent_text_sha256` so Quran Lab can review the wording. Nil with the deck's words.
    public private(set) var consentTextSHA256: String?
    /// With the app's own wording: the canonical text the hash is over (`quranlab.consent-text/1`, the base version,
    /// then each replaced key and its escaped text, by the keys' UTF-8 bytes). Nil with the deck's words.
    public private(set) var consentText: String?
    /// The app's own wording in force, by key (empty: the deck's words).
    public private(set) var overrides: [String: String] = [:]
    /// Fills `{days}` in the deletion lines of decks before 2026-11-07.2 (later decks have no placeholder).
    public let deleteDays: Int
    /// The hadith lines may be shown (the deck's entry was verified against its source).
    public let hadithVerified: Bool
    let strings: [String: String]
    let plurals: [String: [String: String]]

    /// Every string key of the deck, a plural line by category (`impact.minutes.one`, `impact.minutes.other`, ...),
    /// sorted: the keys an app may give its own wording for (`Contributions.setWording(_:)`).
    public var keys: [String] {
        var out: [String] = Array(strings.keys)
        for (k, forms) in plurals {
            for c in forms.keys { out.append(k + "." + c) }
        }
        return out.sorted()
    }

    /// A string by key (the app's own wording where it set one), placeholders filled (`{days}`); empty when the deck has
    /// none.
    public func string(_ key: String) -> String {
        if (key == "sheet.hadith" || key == "sheet.hadith_ref") && !hadithVerified { return "" }
        return (overrides[key] ?? strings[key] ?? "").replacingOccurrences(of: "{days}", with: String(deleteDays))
    }

    /// The impact line for the learner's real shared minutes (rounded down), with the language's plural form.
    public func impact(minutes: Double) -> String {
        let n = Int(max(0, minutes.rounded(.down)))
        let forms = plurals["impact.minutes"] ?? [:]
        let category = Self.pluralCategory(n, lang: lang)
        let f = NumberFormatter()
        f.locale = Locale(identifier: lang)
        let text = overrides["impact.minutes." + category] ?? forms[category] ?? overrides["impact.minutes.other"] ?? forms["other"] ?? ""
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
        baseConsentVersion = cv
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

    /// This deck with the app's own wording (`Contributions.setWording(_:)`, already validated): the strings replaced,
    /// and the consent version and hash derived from the wording. Without overrides, the deck as it is.
    func applying(_ wording: [String: String]) -> SharingCopy {
        var c = self
        c.overrides = wording
        guard !wording.isEmpty else { return c }
        let text = Self.canonical(base: baseConsentVersion, overrides: wording)
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        c.consentText = text
        c.consentTextSHA256 = hash
        c.consentVersion = "custom-" + String(hash.prefix(24))
        return c
    }

    /// The canonical text of custom wording (the same in every TajweedFormer SDK; the shared vector
    /// `consent_text.json`): "quranlab.consent-text/1", "base " and the deck's consent version, then for each key in
    /// the order of its UTF-8 bytes the key, a tab and the escaped text, each line ending in a newline.
    /// Tried and rejected: JSON canonicalisation (escaping differs between platforms' encoders); hashing the whole merged
    /// deck (a deck string the app never shows would change the version); Unicode normalisation (the bytes the app gave
    /// are the bytes the learner saw).
    static func canonical(base: String, overrides: [String: String]) -> String {
        var out = "quranlab.consent-text/1\nbase " + base + "\n"
        let keys = overrides.keys.sorted { (a: String, b: String) -> Bool in a.utf8.lexicographicallyPrecedes(b.utf8) }
        for k in keys {
            out += k + "\t" + escape(overrides[k] ?? "") + "\n"
        }
        return out
    }

    /// Backslash, newline, carriage return and tab escaped (nothing else), scalar by scalar.
    static func escape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Every key of every bundled deck: the keys custom wording may replace.
    static let allKeys: Set<String> = {
        var all = Set<String>()
        for lang in bundledLanguages { all.formUnion(bundled(lang)?.keys ?? []) }
        return all
    }()

    static let bundledLanguages = ["ar", "bn", "en", "fr", "id", "ms", "tr", "ur"]

    /// The bundled deck for `locale` (its language), else English.
    public static func forLocale(_ locale: Locale?) -> SharingCopy {
        let lang = (locale ?? Locale.current).identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init) ?? "en"
        return bundled(lang) ?? bundled("en")!
    }

    private static let cache = Locked<[String: SharingCopy]>([:])

    /// A bundled deck, read once per process.
    static func bundled(_ lang: String) -> SharingCopy? {
        if let c = cache.withLock({ $0[lang] }) { return c }
        guard let dir = Bundle.module.url(forResource: "SharingCopy", withExtension: nil),
              let d = try? Data(contentsOf: dir.appendingPathComponent("\(lang).json")),
              let c = try? SharingCopy(json: d) else { return nil }
        cache.withLock { $0[lang] = c }
        return c
    }
}
