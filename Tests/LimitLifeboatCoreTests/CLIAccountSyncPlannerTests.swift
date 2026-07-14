import XCTest
@testable import LimitLifeboatCore

final class CLIAccountSyncPlannerTests: XCTestCase {
    private let planner = CLIAccountSyncPlanner()

    func testNilIdentityDeactivatesAll() {
        let profiles = [profile(.claude, email: "a@example.com")]
        XCTAssertEqual(planner.plan(provider: .claude, currentIdentity: nil, profiles: profiles), .deactivateAll)
    }

    func testActivatesProfileMatchingAccountID() {
        let match = profile(.codex, email: "other@example.com", accountID: "acct-1")
        let profiles = [profile(.codex, email: "first@example.com"), match]
        let identity = AccountIdentity(email: "cli@example.com", accountID: "acct-1", source: .codexIDToken)

        XCTAssertEqual(planner.plan(provider: .codex, currentIdentity: identity, profiles: profiles), .activate(match.id))
    }

    func testActivatesProfileMatchingEmailCaseInsensitively() {
        let match = profile(.claude, email: "User@Example.com")
        let profiles = [profile(.claude, email: "someone-else@example.com"), match]
        let identity = AccountIdentity(email: "user@example.com", source: .claudeCodeUsage)

        XCTAssertEqual(planner.plan(provider: .claude, currentIdentity: identity, profiles: profiles), .activate(match.id))
    }

    func testDoesNotActivateClaudeProfileWithSameEmailAndDifferentOrganizationID() {
        let team = profile(
            .claude,
            email: "user@example.com",
            accountID: "acct-1",
            organization: "Team",
            organizationID: "org-team"
        )
        let individualPlaceholder = placeholder(.claude)
        let profiles = [team, individualPlaceholder]
        let identity = AccountIdentity(
            email: "user@example.com",
            organization: "user@example.com's Organization",
            organizationID: "org-individual",
            accountID: "acct-1",
            source: .claudeCodeUsage
        )

        XCTAssertEqual(
            planner.plan(provider: .claude, currentIdentity: identity, profiles: profiles),
            .adopt(individualPlaceholder.id)
        )
    }

    func testAdoptsFirstIdentityLessProfileOfSameProvider() {
        let codexPlaceholder = placeholder(.codex)
        let claudeFirstPlaceholder = placeholder(.claude)
        let claudeSecondPlaceholder = placeholder(.claude)
        let profiles = [
            profile(.claude, email: "known@example.com"),
            codexPlaceholder,
            claudeFirstPlaceholder,
            claudeSecondPlaceholder,
        ]
        let identity = AccountIdentity(email: "new@example.com", source: .claudeCodeUsage)

        XCTAssertEqual(
            planner.plan(provider: .claude, currentIdentity: identity, profiles: profiles),
            .adopt(claudeFirstPlaceholder.id)
        )
    }

    func testCreatesWhenNoMatchAndNoPlaceholder() {
        let profiles = [profile(.claude, email: "a@example.com"), profile(.claude, email: "b@example.com")]
        let identity = AccountIdentity(email: "c@example.com", source: .claudeCodeUsage)

        XCTAssertEqual(planner.plan(provider: .claude, currentIdentity: identity, profiles: profiles), .create)
    }

    func testCredentialFingerprintWinsBeforeStaleIdentity() {
        let first = profile(.codex, email: "first@example.com")
        let second = profile(.codex, email: "second@example.com")
        let staleIdentity = AccountIdentity(email: "first@example.com", source: .codexIDToken)

        XCTAssertEqual(
            planner.plan(
                provider: .codex,
                currentIdentity: staleIdentity,
                profiles: [first, second],
                liveCredentialFingerprint: "second-fingerprint",
                storedCredentialFingerprints: [second.id: "second-fingerprint"],
                profilesWithStoredCredentials: [first.id, second.id]
            ),
            .activate(second.id)
        )
    }

    func testPopulatedPlaceholderIsNeverAdopted() {
        let populated = placeholder(.claude)
        let identity = AccountIdentity(email: "new@example.com", source: .claudeCodeUsage)

        XCTAssertEqual(
            planner.plan(
                provider: .claude,
                currentIdentity: identity,
                profiles: [populated],
                profilesWithStoredCredentials: [populated.id]
            ),
            .create
        )
    }

    func testNeverMatchesAcrossProviders() {
        let profiles = [profile(.codex, email: "same@example.com"), placeholder(.codex)]
        let identity = AccountIdentity(email: "same@example.com", source: .claudeCodeUsage)

        XCTAssertEqual(planner.plan(provider: .claude, currentIdentity: identity, profiles: profiles), .create)
    }

    func testOrganizationSimilarityAloneDoesNotActivate() {
        let sameOrg = profile(.claude, email: "colleague@example.com", organization: "Acme")
        let identity = AccountIdentity(email: "me@example.com", organization: "Acme", source: .claudeCodeUsage)

        XCTAssertEqual(planner.plan(provider: .claude, currentIdentity: identity, profiles: [sameOrg]), .create)
    }

    private func profile(
        _ provider: Provider,
        email: String,
        accountID: String? = nil,
        organization: String? = nil,
        organizationID: String? = nil
    ) -> AccountProfile {
        AccountProfile(
            provider: provider,
            label: email,
            identity: AccountIdentity(
                email: email,
                organization: organization,
                organizationID: organizationID,
                accountID: accountID,
                source: .manual
            )
        )
    }

    private func placeholder(_ provider: Provider) -> AccountProfile {
        AccountProfile(provider: provider, label: "Placeholder")
    }
}
