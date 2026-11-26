import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// Spec fix 17 (18.4.7.3) through the SDK's own binding (`CoreOptional.leaseTime`, `CoreHost.leaseTime`) on a Core that
/// has `qlc_lease_time` (quranlab-core clock-anchor): every signed time of clock_anchor.json (quranlab-core
/// docs/spec-fixes/vectors, branch clock-anchor at e9f498a; the contract's test signer, which the test release pins), handed to
/// a Core whose install key is the vectors' (lease.json's `install_ecdh`, install hash c5dc2834...). A verified time that
/// answers no ask of this Core moves its clock forward only (`QLC_OK`, detail 4 `QLC_D_TIME_STALE`); a refused one
/// changes nothing (`QLC_E_LEASE` and the detail of its check: 1 format, 2 signature, 3 install). The numbers are
/// qlcore.h's from clock-anchor, written here because the pinned c3 header, which this test also compiles against,
/// has no names for them. Skips on a Core without `qlc_lease_time` (c3: nothing is called).
final class LeaseTimeCoreTests: XCTestCase {
    static let details = ["format": 1, "signature": 2, "install": 3]
    static let stale = 4

    private func host() throws -> CoreHost {
        let lv = try V40.json("lease.json")
        let ecdh = try XCTUnwrap(lv["install_ecdh"] as? [String: Any])
        let der = try XCTUnwrap(Data(base64URL: try XCTUnwrap(ecdh["pkcs8_b64u"] as? String)))
        let key = try XCTUnwrap(SoftwareInstallKey(der: der))
        let platform = CorePlatform(storage: CoreStorage(root: Fixtures.storage()), key: key,
                                    state: ProtectedCoreTests.MemoryState(), clocks: SystemClocks())
        return try CoreHost(platform: platform)
    }

    func testTheVectorsSignedTimes() throws {
        guard CoreOptional.leaseTime != nil else {
            throw XCTSkip("the linked Core (\(CoreHost.version)) has no qlc_lease_time: with it the SDK calls nothing")
        }
        let v = try V40.json("clock_anchor.json")
        let time = try XCTUnwrap(v["time"] as? [String: Any])
        let accept = try XCTUnwrap(time["accept"] as? [[String: Any]])
        let refuse = try XCTUnwrap(time["refuse"] as? [[String: Any]])
        XCTAssertEqual(accept.count, 3)
        XCTAssertEqual(refuse.count, 17)
        for c in accept {
            let name = c["name"] as? String ?? "?"
            let h = try host()
            XCTAssertEqual(h.installHash, v["install_hash_hex"] as? String, "the vectors' install")
            let st = h.leaseTime(try XCTUnwrap(c["time"] as? String, name))
            XCTAssertEqual(st.map { Int($0) }, Int(QLC_OK), name)
            XCTAssertEqual(Int(h.detail), Self.stale, "\(name): no ask of this Core, forward only")
        }
        for c in refuse {
            let name = c["name"] as? String ?? "?"
            let want = try XCTUnwrap(Self.details[try XCTUnwrap(c["refuse"] as? String, name)], name)
            let h = try host()
            let st = h.leaseTime(try XCTUnwrap(c["time"] as? String, name))
            XCTAssertEqual(st.map { Int($0) }, Int(QLC_E_LEASE), name)
            XCTAssertEqual(Int(h.detail), want, name)
        }
    }
}
