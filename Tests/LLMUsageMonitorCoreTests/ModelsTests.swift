import XCTest
@testable import LLMUsageMonitorCore

final class ModelsTests: XCTestCase {
    func testIdentitiesMatchOnAccountID() {
        let left = AccountIdentity(email: "left@example.com", accountID: "acct-1", source: .codexIDToken)
        let right = AccountIdentity(email: "right@example.com", accountID: "acct-1", source: .dashboard)
        XCTAssertTrue(left.matches(right))
    }

    func testIdentitiesMatchOnEmailCaseInsensitively() {
        let left = AccountIdentity(email: "User@Example.com", source: .dashboard)
        let right = AccountIdentity(email: "user@example.com", source: .claudeCodeUsage)
        XCTAssertTrue(left.matches(right))
    }

    func testDifferentAccountIDsDoNotMatchEvenWithSameEmailAbsent() {
        let left = AccountIdentity(displayName: "A", accountID: "acct-1", source: .codexIDToken)
        let right = AccountIdentity(displayName: "A", accountID: "acct-2", source: .codexIDToken)
        XCTAssertFalse(left.matches(right))
    }

    func testMatchingOrganizationAloneDoesNotMatch() {
        let left = AccountIdentity(email: "a@example.com", organization: "Acme", source: .dashboard)
        let right = AccountIdentity(email: "b@example.com", organization: "Acme", source: .dashboard)
        XCTAssertFalse(left.matches(right))
    }

    func testSnapshotStaleness() {
        let now = Date()
        let fresh = makeSnapshot(lastRefreshed: now.addingTimeInterval(-60))
        let old = makeSnapshot(lastRefreshed: now.addingTimeInterval(-3600))

        XCTAssertFalse(fresh.isStale(asOf: now))
        XCTAssertTrue(old.isStale(asOf: now))
    }

    func testResetHasElapsed() {
        let now = Date()
        let elapsed = makeSnapshot(lastRefreshed: now.addingTimeInterval(-7200), resetDate: now.addingTimeInterval(-60))
        let pending = makeSnapshot(lastRefreshed: now, resetDate: now.addingTimeInterval(3600))
        let unknown = makeSnapshot(lastRefreshed: now, resetDate: nil)

        XCTAssertTrue(elapsed.resetHasElapsed(asOf: now))
        XCTAssertFalse(pending.resetHasElapsed(asOf: now))
        XCTAssertFalse(unknown.resetHasElapsed(asOf: now))
    }

    private func makeSnapshot(lastRefreshed: Date, resetDate: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            resetDate: resetDate,
            riskLevel: .healthy,
            source: "test",
            lastRefreshed: lastRefreshed,
            parseConfidence: .high
        )
    }
}
