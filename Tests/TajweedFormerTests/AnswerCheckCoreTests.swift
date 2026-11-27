import Foundation
import QuranLabCore
import XCTest
@testable import TajweedFormer

/// SDK 4.0.5: `AnswerCheck` holds the Core's
/// statuses by value (so it builds on Linux); here they are held to the pinned qlcore.h (c3), and every `QLC_D_LEASE_*`
/// a lease can be refused with names a check of its own. A detail the Core adds without a check fails this test.
final class AnswerCheckCoreTests: XCTestCase {
    func testTheStatusesAreTheHeaders() {
        XCTAssertEqual(AnswerCheck.Core.arg, Int(QLC_E_ARG))
        XCTAssertEqual(AnswerCheck.Core.nomem, Int(QLC_E_NOMEM))
        XCTAssertEqual(AnswerCheck.Core.storage, Int(QLC_E_STORAGE))
        XCTAssertEqual(AnswerCheck.Core.manifest, Int(QLC_E_MANIFEST))
        XCTAssertEqual(AnswerCheck.Core.needsConnection, Int(QLC_E_NEEDS_CONNECTION))
        XCTAssertEqual(AnswerCheck.Core.lease, Int(QLC_E_LEASE))
        XCTAssertEqual(AnswerCheck.Core.file, Int(QLC_E_FILE))
        XCTAssertEqual(AnswerCheck.Core.engine, Int(QLC_E_ENGINE))
        XCTAssertEqual(AnswerCheck.Core.stopped, Int(QLC_E_STOPPED))
        XCTAssertEqual(AnswerCheck.Core.keystore, Int(QLC_E_KEYSTORE))
        XCTAssertEqual(AnswerCheck.Core.busy, Int(QLC_E_BUSY))
    }

    /// Every lease refusal detail of the pinned header (QLC_D_LEASE_NO_ACCEL is the Core's own at an accelerator
    /// prepare, never an accept's) names a check that is not the catch-all `lease_detail:<n>`.
    func testEveryLeaseDetailHasACheck() {
        let details: [(String, Int)] = [
            ("FORMAT", Int(QLC_D_LEASE_FORMAT)), ("SIGNATURE", Int(QLC_D_LEASE_SIGNATURE)), ("INSTALL", Int(QLC_D_LEASE_INSTALL)),
            ("RELEASE", Int(QLC_D_LEASE_RELEASE)), ("BUILD", Int(QLC_D_LEASE_BUILD)), ("KEY_ID", Int(QLC_D_LEASE_KEY_ID)),
            ("MODEL", Int(QLC_D_LEASE_MODEL)), ("EXPIRED", Int(QLC_D_LEASE_EXPIRED)), ("OUTER_TAG", Int(QLC_D_LEASE_OUTER_TAG)),
            ("INNER_TAG", Int(QLC_D_LEASE_INNER_TAG)), ("SITE", Int(QLC_D_LEASE_SITE)), ("UNWRAP", Int(QLC_D_LEASE_UNWRAP)),
        ]
        // the node lease's details (Core c6, contract 36) are not in the c3 header this SDK pins: their checks by value
        for d in 13...18 { XCTAssertFalse(AnswerCheck.coreAccept(status: Int(QLC_E_LEASE), detail: d).hasPrefix("lease_detail:"), "\(d)") }
        for (name, d) in details {
            let check = AnswerCheck.coreAccept(status: Int(QLC_E_LEASE), detail: d)
            XCTAssertFalse(check.hasPrefix("lease_detail:"), "QLC_D_LEASE_\(name) has no check of its own")
        }
        XCTAssertEqual(AnswerCheck.coreAccept(status: Int(QLC_E_NEEDS_CONNECTION), detail: Int(QLC_D_LEASE_EXPIRED)), "expired_on_arrival")
        XCTAssertEqual(AnswerCheck.coreAccept(status: Int(QLC_E_KEYSTORE), detail: Int(QLC_D_LEASE_UNWRAP)), "unwrap")
    }
}
