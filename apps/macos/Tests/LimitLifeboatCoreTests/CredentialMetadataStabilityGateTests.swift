import XCTest
@testable import LimitLifeboatCore

final class CredentialMetadataStabilityGateTests: XCTestCase {
    func testFileOnlyChangesNeverTriggerCredentialRead() {
        var gate = CredentialMetadataStabilityGate<String?, String>(
            lastAttemptedItem: "old-item"
        )

        XCTAssertFalse(gate.shouldRead(item: "old-item", settle: "file-v2"))
        XCTAssertFalse(gate.shouldRead(item: "old-item", settle: "file-v3"))
    }

    func testChangedItemTriggersOneReadOnlyAfterMetadataSettles() {
        var gate = CredentialMetadataStabilityGate<String?, String>(
            lastAttemptedItem: "old-item"
        )

        XCTAssertFalse(gate.shouldRead(item: "new-item", settle: "writing"))
        XCTAssertFalse(gate.shouldRead(item: "new-item", settle: "settled"))
        XCTAssertTrue(gate.shouldRead(item: "new-item", settle: "settled"))
        XCTAssertFalse(gate.shouldRead(item: "new-item", settle: "later-file-event"))
    }

    func testReplacementDuringSettleRestartsConfirmation() {
        var gate = CredentialMetadataStabilityGate<String?, String>(
            lastAttemptedItem: nil
        )

        XCTAssertFalse(gate.shouldRead(item: "first", settle: "stable"))
        XCTAssertFalse(gate.shouldRead(item: "replacement", settle: "stable"))
        XCTAssertTrue(gate.shouldRead(item: "replacement", settle: "stable"))
    }

    func testSettledFileChangeReevaluatesCachedReadWithoutAnotherRead() {
        var gate = CredentialMetadataStabilityGate<String?, String>(
            lastAttemptedItem: "old-item"
        )

        XCTAssertEqual(gate.decision(item: "new-item", settle: "initial"), .wait)
        XCTAssertEqual(gate.decision(item: "new-item", settle: "initial"), .read)
        XCTAssertEqual(gate.decision(item: "new-item", settle: "identity-writing"), .wait)
        XCTAssertEqual(gate.decision(item: "new-item", settle: "identity-ready"), .wait)
        XCTAssertEqual(
            gate.decision(item: "new-item", settle: "identity-ready"),
            .reevaluateCachedRead
        )
        XCTAssertEqual(gate.decision(item: "new-item", settle: "identity-ready"), .wait)
    }

    func testSameStampFileChangeAllowsOneSettledCollisionFallbackRead() {
        var gate = CredentialMetadataStabilityGate<String?, String>(
            lastAttemptedItem: "same-second-stamp",
            initialSettle: "before-login",
            allowSettledFallbackRead: true
        )

        XCTAssertEqual(gate.decision(item: "same-second-stamp", settle: "after-login"), .wait)
        XCTAssertEqual(
            gate.decision(item: "same-second-stamp", settle: "after-login"),
            .fallbackRead
        )
        XCTAssertEqual(gate.decision(item: "same-second-stamp", settle: "later"), .wait)
        XCTAssertEqual(
            gate.decision(item: "same-second-stamp", settle: "later"),
            .reevaluateCachedRead
        )
    }

    func testRejectedFallbackWaitsForRealItemGeneration() {
        var gate = CredentialMetadataStabilityGate<String?, String>(
            lastAttemptedItem: "same-stamp",
            initialSettle: "before",
            allowSettledFallbackRead: true
        )

        XCTAssertEqual(gate.decision(item: "same-stamp", settle: "files-first"), .wait)
        XCTAssertEqual(gate.decision(item: "same-stamp", settle: "files-first"), .fallbackRead)
        gate.discardFallbackRead()
        XCTAssertEqual(gate.decision(item: "same-stamp", settle: "files-later"), .wait)
        XCTAssertEqual(gate.decision(item: "same-stamp", settle: "files-later"), .wait)
        XCTAssertEqual(gate.decision(item: "new-generation", settle: "files-later"), .wait)
        XCTAssertEqual(gate.decision(item: "new-generation", settle: "files-later"), .read)
    }
}
