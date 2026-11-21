import Foundation
import XCTest
@testable import TajweedFormer

/// SDK 4.0.1, contract section 27 (`sdk_4.0.0/APP_VERSION_40.md` at 564c144): the app's version and build on every
/// config request, cleaned by 27.1's one rule (ASCII `0-9 A-Z a-z . + -` only, the leading `.`, `+` and `-` dropped,
/// the first 32 kept; nothing left or `0` leaves the parameter out), `+` sent as `%2B`; register's `app_version` the
/// same cleaned string, or `"0"`. 27.3 checks 1, 2, 3 and 7.
final class AppVersionTests: XCTestCase {
    override func tearDown() {
        QuranLab.configure(key: nil, options: .init(cloud: nil), cloud: nil)
    }

    /// 27.3 check 7: the examples of 27.1, for the config parameter (nil: left out) and for register.
    func testTheCleaningOf27_1() {
        let forty = String(repeating: "1234567890", count: 4)
        let cases: [(String?, String?, String)] = [
            (" 7.1 (beta)", "7.1beta", "7.1beta"), ("-7.1", "7.1", "7.1"), ("v2.0+42", "v2.0+42", "v2.0+42"),
            ("7.1-\u{e9}", "7.1-", "7.1-"), ("...", nil, "0"), ("0", nil, "0"), (nil, nil, "0"), ("", nil, "0"),
            (forty, String(forty.prefix(32)), String(forty.prefix(32))), ("+-.7", "7", "7"), ("\u{FF11}\u{FF12}", nil, "0"),
            ("412", "412", "412"),
        ]
        for (raw, parameter, register) in cases {
            XCTAssertEqual(ConfigStore.appValue(raw), parameter, "\(raw ?? "nil")")
            XCTAssertEqual(AppIdentity.registerVersion(raw), register, "\(raw ?? "nil"): register")
        }
        // the parameters: app_version then app_build, a plus as %2B, a value that cleans to nothing left out
        let both = ConfigStore.appParameters(AppIdentity(platform: "ios", bundleID: "a.b", version: "v2.0+42", build: " 412 "))
        XCTAssertEqual(both.map(\.name), ["app_version", "app_build"])
        XCTAssertEqual(both.map(\.value), ["v2.0%2B42", "412"])
        let none = ConfigStore.appParameters(AppIdentity(platform: "ios", bundleID: "a.b", version: "0", build: "..."))
        XCTAssertTrue(none.isEmpty)
        // the app's override is what register sends, cleaned (4.0.0 sent it as it was)
        let options = TajweedClientOptions(appVersion: " 7.1 (beta)", appBuild: "+412").configuration
        XCTAssertEqual(options.cloud?.app?.version, "7.1beta")
        XCTAssertEqual(options.cloud?.app?.build, "+412", "the build is cleaned where it is sent, the config request")
    }

    /// 27.3 checks 1 and 3: the config request carries both after `bucket` and `sdk`, the version as register sent it.
    func testTheConfigRequestCarriesThem() async throws {
        let storage = CloudFixtures.storage()
        var o = CloudFixtures.options(storage: storage)
        o.cloud?.app = AppIdentity(platform: "ios", bundleID: "com.example.quran", name: "Example", version: "7.1+beta", build: "412")
        let options = o
        StubProtocol.reset(CloudFixtures.server())
        let client = try TajweedClient(key: CloudFixtures.key, configuration: options, cloud: { CloudFixtures.cloud(storage: $0, options: options) })
        defer { client.close() }
        let cloud = try XCTUnwrap(QuranLab.cloud)
        _ = await cloud.refreshConfig()
        let asked = try XCTUnwrap(StubProtocol.seen("/v1/config").first)
        let query = try XCTUnwrap(URLComponents(url: asked.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let names = query.split(separator: "&").map { String($0.split(separator: "=").first ?? "") }
        XCTAssertEqual(Array(names.prefix(2)), ["bucket", "sdk"])
        XCTAssertEqual(Array(names.suffix(2)), ["app_version", "app_build"])
        XCTAssertTrue(query.hasSuffix("app_version=7.1%2Bbeta&app_build=412"), query)
    }
}
