import XCTest
@testable import LimitLifeboatCore

final class UsageParserTests: XCTestCase {
    private let parser = UsageTextParser()

    func testParsesHealthyRatioAsUsedOfLimit() {
        let account = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = parser.parse(
            text: "Codex usage dashboard Included usage 35 of 100 used Resets at 14:30 Credits balance 20",
            account: account,
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.includedRemaining, 65)
        XCTAssertEqual(snapshot.includedLimit, 100)
        XCTAssertEqual(snapshot.usedFraction, 0.35)
        XCTAssertEqual(snapshot.riskLevel, .healthy)
        XCTAssertEqual(snapshot.parseConfidence, .high)
        XCTAssertNotNil(snapshot.creditStatus)
        XCTAssertEqual(snapshot.resetDescription, "14:30")
    }

    func testParsesWarningPercentage() {
        let account = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = parser.parse(
            text: "Settings Usage 88% used Your usage resets in 2 hours",
            account: account
        )

        XCTAssertEqual(snapshot.includedRemaining, 12)
        XCTAssertEqual(snapshot.includedLimit, 100)
        XCTAssertEqual(snapshot.usedFraction, 0.88)
        XCTAssertEqual(snapshot.riskLevel, .warning)
        XCTAssertEqual(snapshot.parseConfidence, .medium)
    }

    func testParsesDepletedLimitReached() {
        let account = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = parser.parse(
            text: "Usage limit reached. 0 messages remaining. You can continue with usage credits.",
            account: account
        )

        XCTAssertEqual(snapshot.includedRemaining, 0)
        XCTAssertEqual(snapshot.riskLevel, .depleted)
        XCTAssertNotNil(snapshot.creditStatus)
    }

    func testDetectsLoggedOutDashboard() {
        let account = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = parser.parse(
            text: "Log in Sign up Continue with Google Continue with Microsoft Usage",
            account: account
        )

        XCTAssertEqual(snapshot.riskLevel, .stale)
        XCTAssertEqual(snapshot.parseConfidence, .low)
    }

    func testUnknownLayoutDoesNotInventUsage() {
        let account = AccountProfile(provider: .codex, label: "Codex")
        let snapshot = parser.parse(
            text: "Welcome to the dashboard. Recent activity and settings are loading.",
            account: account
        )

        XCTAssertNil(snapshot.includedRemaining)
        XCTAssertNil(snapshot.includedLimit)
        XCTAssertEqual(snapshot.riskLevel, .unknown)
        XCTAssertEqual(snapshot.parseConfidence, .none)
        XCTAssertEqual(snapshot.message, "Account page loaded, but usage limits are not visible.")
    }

    func testBillingModeSeparatesSubscriptionUsageFromPayAsYouGo() {
        let included = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            includedRemaining: 69,
            includedLimit: 100,
            creditStatus: "Usage credits 70% used.",
            riskLevel: .healthy,
            source: "test",
            parseConfidence: .high
        )
        XCTAssertEqual(included.billingUsageMode, .includedSubscription)

        let nearLimit = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            includedRemaining: 12,
            includedLimit: 100,
            riskLevel: .warning,
            source: "test",
            parseConfidence: .high
        )
        XCTAssertEqual(nearLimit.billingUsageMode, .includedSubscriptionNearLimit)

        let payAsYouGo = UsageSnapshot(
            accountID: UUID(),
            provider: .codex,
            includedRemaining: 0,
            includedLimit: 0,
            creditStatus: "Credits enabled; auto top-up may apply.",
            riskLevel: .depleted,
            source: "test",
            parseConfidence: .high
        )
        XCTAssertEqual(payAsYouGo.billingUsageMode, .overLimitPayAsYouGo)
    }
}
