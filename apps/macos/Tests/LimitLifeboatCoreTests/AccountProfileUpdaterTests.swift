import XCTest
@testable import LimitLifeboatCore

final class AccountProfileUpdaterTests: XCTestCase {
    func testActivationIsProviderScopedAndExclusive() {
        let first = AccountProfile(provider: .claude, label: "First", isActiveCLI: true)
        let second = AccountProfile(provider: .claude, label: "Second")
        let codex = AccountProfile(provider: .codex, label: "Codex", isActiveCLI: true)
        var profiles = [first, second, codex]

        let change = AccountProfileUpdater.setActiveCLI(
            profiles: &profiles,
            provider: .claude,
            profileID: second.id,
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(change.changed)
        XCTAssertEqual(change.activatedID, second.id)
        XCTAssertEqual(change.deactivatedIDs, [first.id])
        XCTAssertFalse(profiles[0].isActiveCLI)
        XCTAssertTrue(profiles[1].isActiveCLI)
        XCTAssertTrue(profiles[2].isActiveCLI)
    }

    func testEnrichmentMergesFieldsAndUpdatesTimestampOnce() {
        let originalDate = Date(timeIntervalSince1970: 100)
        let updateDate = Date(timeIntervalSince1970: 200)
        let profile = AccountProfile(
            provider: .claude,
            label: "Claude",
            identity: AccountIdentity(
                email: "person@example.com",
                organization: "Existing Org",
                source: .manual,
                updatedAt: originalDate
            ),
            createdAt: originalDate,
            updatedAt: originalDate
        )
        var profiles = [profile]

        let changed = AccountProfileUpdater.enrich(
            profiles: &profiles,
            profileID: profile.id,
            enrichment: AccountProfileEnrichment(
                planLabel: "Max 5x",
                identity: AccountIdentity(
                    displayName: "Person",
                    accountID: "account-id",
                    source: .claudeCodeUsage,
                    updatedAt: updateDate
                )
            ),
            now: updateDate
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(profiles[0].planLabel, "Max 5x")
        XCTAssertEqual(profiles[0].identity?.email, "person@example.com")
        XCTAssertEqual(profiles[0].identity?.displayName, "Person")
        XCTAssertEqual(profiles[0].identity?.organization, "Existing Org")
        XCTAssertEqual(profiles[0].identity?.accountID, "account-id")
        XCTAssertEqual(profiles[0].updatedAt, updateDate)
    }

    func testIdenticalEnrichmentDoesNotMutateProfile() {
        let date = Date(timeIntervalSince1970: 100)
        let identity = AccountIdentity(email: "person@example.com", source: .manual, updatedAt: date)
        let profile = AccountProfile(
            provider: .codex,
            label: "Codex",
            planLabel: "Plus",
            identity: identity,
            updatedAt: date
        )
        var profiles = [profile]

        let changed = AccountProfileUpdater.enrich(
            profiles: &profiles,
            profileID: profile.id,
            enrichment: AccountProfileEnrichment(planLabel: "Plus", identity: identity),
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(profiles[0].updatedAt, date)
    }
}
