import Foundation

/// The SDK's own version, sent in registration, events and issue reports.
public enum SDKInfo {
    public static let version = "2.0.3"
}

/// Which app the SDK runs in: what registration sends. Read from the main bundle; a host (or a
/// test) can set it explicitly in `CloudOptions.app`.
public struct AppIdentity: Sendable, Hashable {
    /// "ios" or "macos".
    public var platform: String
    public var bundleID: String
    public var name: String?
    public var version: String

    public init(platform: String = AppIdentity.currentPlatform, bundleID: String, name: String? = nil, version: String) {
        self.platform = platform
        self.bundleID = bundleID
        self.name = name
        self.version = version
    }

    public static var currentPlatform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }

    /// The main bundle's identifier, display name and short version.
    public static var main: AppIdentity {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = Bundle.main.bundleIdentifier ?? "unknown.app"
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        let raw = (info["CFBundleShortVersionString"] as? String) ?? "0"
        let version = raw.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return AppIdentity(bundleID: bundle, name: name.map { String($0.prefix(80)) },
                           version: version.isEmpty ? "0" : String(version.prefix(32)))
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

/// UTC day strings, the finest time anything the SDK sends carries.
enum Day {
    static func string(_ date: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
