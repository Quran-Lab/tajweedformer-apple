import Foundation

/// The SDK's own version, sent in registration, events and issue reports.
enum SDKInfo {
    static let version = "4.0.2"
    /// Where the SDK runs: the one sentence every `runtime_unsupported` error ends its fix with. It says what the
    /// README's "Before you start" says.
    static let minimum = "iOS 15 or macOS 12 or later, on Apple silicon (an arm64 device, the arm64 simulator or an arm64 Mac)"
}

/// Whether this process can run the SDK. The engine's binary has arm64 slices only, so an Intel Mac and the x86_64
/// simulator cannot run it; that is `runtime_unsupported`, never a fault of the model.
enum RuntimeSupport {
    /// The processor this process was built for.
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "another processor"
        #endif
    }

    /// Why the SDK cannot run on `architecture`; nil when it can.
    static func problem(architecture: String = RuntimeSupport.architecture) -> String? {
        if architecture == "arm64" { return nil }
        return architecture == "x86_64" ? "this is an Intel processor (x86_64)" : "this is not Apple silicon (\(architecture))"
    }

    /// Throws `runtime_unsupported` where the SDK cannot run.
    static func check(architecture: String = RuntimeSupport.architecture) throws(TajweedError) {
        if let why = problem(architecture: architecture) { throw TajweedError(.runtimeUnsupported, ["detail": why]) }
    }
}

/// Which app the SDK runs in: what registration sends. Read from the main bundle; a host (or a
/// test) can set it explicitly in `CloudOptions.app`.
struct AppIdentity: Sendable, Hashable {
    /// "ios" or "macos".
    var platform: String
    var bundleID: String
    var name: String?
    var version: String
    /// SDK 4.0.1 (section 27): the app's build number, `CFBundleVersion` or the app's own (`TajweedClientOptions.appBuild`);
    /// nil when not known. Sent only on the config request.
    var build: String?

    init(platform: String = AppIdentity.currentPlatform, bundleID: String, name: String? = nil, version: String, build: String? = nil) {
        self.platform = platform
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
    }

    static var currentPlatform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// The main bundle's identifier, display name and short version.
    static var main: AppIdentity {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = Bundle.main.bundleIdentifier ?? "unknown.app"
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        return AppIdentity(bundleID: bundle, name: name.map { String($0.prefix(80)) },
                           version: registerVersion(info["CFBundleShortVersionString"] as? String),
                           build: info["CFBundleVersion"] as? String)
    }

    /// Contract section 27.1 (564c144), the one cleaning of `app_version` and `app_build` on every platform, in order:
    /// keep only the ASCII characters `0-9 A-Z a-z . + -`; drop `.`, `+` and `-` from the start; keep the first 32.
    /// ` 7.1 (beta)` is `7.1beta`, `-7.1` is `7.1`, `7.1-` and a letter outside ASCII is `7.1-`, `...` is empty. (4.0.0 kept any Unicode letter or
    /// digit, and no leading sign was dropped.)
    static func cleaned(_ raw: String?) -> String {
        guard let raw else { return "" }
        let kept = raw.unicodeScalars.filter { s in
            (48...57).contains(s.value) || (65...90).contains(s.value) || (97...122).contains(s.value) || ".+-".unicodeScalars.contains(s)
        }
        let signs = ".+-".unicodeScalars
        let trimmed = kept.drop { signs.contains($0) }
        return String(String.UnicodeScalarView(trimmed.prefix(32)))
    }

    /// Register's `app_version` (27.1, PLATFORM_CLIENT 5): the cleaned version, or `"0"` when it is not known or
    /// cleans down to nothing (register requires the field).
    static func registerVersion(_ raw: String?) -> String {
        let v = cleaned(raw)
        return v.isEmpty ? "0" : v
    }
}

/// Coarse device context for analytics and issue reports: never an identifier.
enum DeviceContext {
    /// The chip family ("A17", "M2"), or "simulator", "iPad", "unknown". Coarse on purpose.
    static let deviceClass: String = classify(model: DeviceInfo.model, brand: DeviceInfo.sysctl("machdep.cpu.brand_string"))

    static func classify(model: String, brand: String) -> String {
        if model.hasPrefix("Simulator") { return "simulator" }
        if model.hasPrefix("iPhone") {
            let digits = model.dropFirst("iPhone".count).split(separator: ",")
            if let major = digits.first.flatMap({ Int($0) }) {
                // iPhone10 A11, iPhone11 A12 ... iPhone18 A19: the model identifier's major number
                // tracks the chip generation from the iPhone 8 on
                if (10...30).contains(major) { return "A\(major + 1)" }
            }
            return "unknown"
        }
        if model.hasPrefix("iPad") { return "iPad" }
        // Macs: "Apple M2 Pro" -> "M2"
        if brand.hasPrefix("Apple ") {
            let parts = brand.split(separator: " ")
            if parts.count >= 2, parts[1].hasPrefix("M") { return String(parts[1].prefix(8)) }
        }
        if brand.contains("Intel") { return "intel" }
        return "unknown"
    }

    /// The chip in telemetry's form ("a17", "m2"); nil when it is not known.
    static let soc: String? = {
        let c = deviceClass.lowercased()
        guard let f = c.first, f == "a" || f == "m", c.dropFirst().allSatisfy({ $0.isNumber }), c.count > 1 else { return nil }
        return c
    }()

    /// The RAM tier: lt2, 2_4, 4_8, 8_16 or ge16 (GB).
    static let ramTier: String = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gb < 2 ? "lt2" : gb < 4 ? "2_4" : gb < 8 ? "4_8" : gb < 16 ? "8_16" : "ge16"
    }()

    static var osVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }

    static var osMajor: Int { max(1, min(99, osVersion.majorVersion)) }

    /// "18.2.1" (or "18.2" when there is no patch number).
    static var osVersionString: String {
        let v = osVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }
}

/// The device's model code, sent with each shared recording as `device_model` (SDK 4.0, SHARING_40.md 19.2) beside
/// `device_class`: the hardware identifier (`sysctl hw.machine` on iOS and iPadOS, the environment's
/// `SIMULATOR_MODEL_IDENTIFIER` on a simulator, `sysctl hw.model` on a Mac, where `hw.machine` is `arm64`). A model, not
/// an identifier of the device: every phone of that model says the same.
enum DeviceModel {
    /// This device's, normalised; nil when the system gives none (the field is then left out).
    static let current: String? = normalize([raw])

    /// What the system says, before normalising.
    static var raw: String? {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        #elseif os(macOS)
        return sysctl("hw.model")
        #else
        return sysctl("hw.machine")
        #endif
    }

    /// A string sysctl value; nil when there is none.
    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every SDK's rule (19.2, `tools/sharing40.py` `device_model`): each part trimmed, the non-empty parts joined
    /// with one space, every code point outside `A-Z a-z 0-9`, space and `_ . , + ( ) / -` made one `_`, every run of
    /// spaces made one, the characters before the first letter or digit dropped, cut to 64 characters, trailing
    /// spaces dropped; nil when nothing is left. The result always matches the server's pattern
    /// `^[A-Za-z0-9][A-Za-z0-9 _.,+()/-]{0,63}$`.
    static func normalize(_ parts: [String?]) -> String? {
        // Python's str.strip() whitespace: Foundation's, and the four separators U+001C to U+001F
        var space = CharacterSet.whitespacesAndNewlines
        space.insert(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}")
        let joined = parts.compactMap { (p: String?) -> String? in p?.trimmingCharacters(in: space) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let blank: Unicode.Scalar = " "
        let other: Unicode.Scalar = "_"
        var scalars: [Unicode.Scalar] = []
        for u in joined.unicodeScalars {
            let c = allowed(u) ? u : other
            // a run of spaces is one
            if c == blank, let last = scalars.last, last == blank { continue }
            scalars.append(c)
        }
        guard let first = scalars.firstIndex(where: { (u: Unicode.Scalar) -> Bool in alphanumeric(u) }) else { return nil }
        var kept = Array(scalars[first...].prefix(64))
        while let last = kept.last, last == blank { kept.removeLast() }
        var out = ""
        out.unicodeScalars.append(contentsOf: kept)
        return out.isEmpty ? nil : out
    }

    /// `A-Z`, `a-z`, `0-9`.
    private static func alphanumeric(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0x30...0x39).contains(v)
    }

    private static func allowed(_ u: Unicode.Scalar) -> Bool {
        alphanumeric(u) || " _.,+()/-".unicodeScalars.contains(u)
    }
}

/// UTC day strings, the finest time anything the SDK sends carries.
enum Day {
    static func string(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
