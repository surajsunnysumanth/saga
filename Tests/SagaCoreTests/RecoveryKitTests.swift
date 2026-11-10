import XCTest
@testable import SagaCore

final class RecoveryKitTests: XCTestCase {
    func testConfirmationRequiresExportAcknowledgementAndCoreAcceptance() throws {
        var state = RecoveryKitConfirmation()
        var calls = 0
        state.typedCode = "synthetic-complete-code"
        state.hasSavedCopy = true
        XCTAssertThrowsError(try state.confirm { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
        state.recordExport(.saved)
        // Each save attempt resets the acknowledgement.
        XCTAssertThrowsError(try state.confirm { _ in calls += 1 })
        state.hasSavedCopy = true
        try state.confirm { code in
            XCTAssertEqual(code, "synthetic-complete-code")
            calls += 1
        }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(state.isConfirmed)
        XCTAssertEqual(state.typedCode, "")
        XCTAssertFalse(state.hasSavedCopy)
    }

    func testMaterialPreservesSuppliedCodeWithoutExposingItInReflection() {
        let code = "SYNTHETIC-ONLY-RECOVERY-CREDENTIAL"
        let material = RecoveryKitMaterial(vaultID: "synthetic-vault", recoveryCode: code)
        XCTAssertEqual(material.recoveryCode, code)
        XCTAssertEqual(material.vaultID, "synthetic-vault")
        XCTAssertFalse(String(describing: material).contains(code))
        XCTAssertFalse(String(reflecting: material).contains(code))
    }

    func testCancelledOrFailedExportNeverCountsAndCoreRejectionAllowsRetry() throws {
        var state = RecoveryKitConfirmation()
        state.typedCode = "code"
        for r in [RecoveryKitExportResult.cancelled, .failed] {
            state.recordExport(r)
            state.hasSavedCopy = true
            XCTAssertThrowsError(try state.confirm { _ in XCTFail("must not call") }) {
                XCTAssertEqual($0 as? RecoveryKitConfirmationError, .notSaved)
            }
        }
        state.recordExport(.saved)
        state.hasSavedCopy = true
        struct Mismatch: Error {}
        XCTAssertThrowsError(try state.confirm { _ in throw Mismatch() })
        XCTAssertFalse(state.isConfirmed)
        XCTAssertEqual(state.typedCode, "code") // kept for correction
        try state.confirm { _ in }
        XCTAssertTrue(state.isConfirmed)
    }

    func testEmptyTypeBackRejectedAndClearWipesState() {
        var state = RecoveryKitConfirmation()
        state.recordExport(.saved); state.hasSavedCopy = true
        XCTAssertThrowsError(try state.confirm { _ in XCTFail() }) {
            XCTAssertEqual($0 as? RecoveryKitConfirmationError, .emptyCode)
        }
        state.typedCode = "x"; state.clear()
        XCTAssertEqual(state.typedCode, ""); XCTAssertFalse(state.hasSavedCopy)
    }

    func testPageTextHasOnlyKitFields() {
        let m = RecoveryKitMaterial(vaultID: "VID-1", recoveryCode: "AAAA-BBBB")
        let p = RecoveryKit.pageText(for: m)
        XCTAssertEqual(p.header, ["Saga Recovery Kit", "Kit version 1", "Archive ID: VID-1"])
        XCTAssertEqual(p.code, "AAAA-BBBB")
        XCTAssertFalse(p.body.contains("AAAA-BBBB"))
        XCTAssertTrue(p.body.contains("VID-1"))
        XCTAssertTrue(p.body.contains("Saga cannot recover"))
    }
}
