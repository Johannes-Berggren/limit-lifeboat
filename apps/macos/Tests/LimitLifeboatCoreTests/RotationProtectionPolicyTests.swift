import XCTest
@testable import LimitLifeboatCore

final class RotationProtectionPolicyTests: XCTestCase {
    func testSiblingOfActiveSharedAccountIsProtected() {
        let active = profile(accountID: "acct-1", organizationID: "org-team", isActiveCLI: true)
        let sibling = profile(accountID: "acct-1", organizationID: "org-individual")

        XCTAssertTrue(
            RotationProtectionPolicy.accountIsLiveElsewhere(
                profile: sibling,
                among: [active, sibling],
                storedFingerprint: "individual-fp",
                duplicatedStoredFingerprints: []
            )
        )
    }

    func testActiveProfileIsNeverProtected() {
        let active = profile(accountID: "acct-1", organizationID: "org-team", isActiveCLI: true)
        let sibling = profile(accountID: "acct-1", organizationID: "org-individual")

        XCTAssertFalse(
            RotationProtectionPolicy.accountIsLiveElsewhere(
                profile: active,
                among: [active, sibling],
                storedFingerprint: "team-fp",
                duplicatedStoredFingerprints: ["team-fp"]
            )
        )
    }

    func testDuplicatedStoredFingerprintIsProtected() {
        let a = profile(accountID: nil, organizationID: nil)
        let b = profile(accountID: nil, organizationID: nil)

        XCTAssertTrue(
            RotationProtectionPolicy.accountIsLiveElsewhere(
                profile: a,
                among: [a, b],
                storedFingerprint: "shared-fp",
                duplicatedStoredFingerprints: ["shared-fp"]
            )
        )
    }

    func testDistinctInactiveAccountIsNotProtected() {
        let active = profile(accountID: "acct-1", organizationID: "org-1", isActiveCLI: true)
        let other = profile(accountID: "acct-2", organizationID: "org-2")

        XCTAssertFalse(
            RotationProtectionPolicy.accountIsLiveElsewhere(
                profile: other,
                among: [active, other],
                storedFingerprint: "other-fp",
                duplicatedStoredFingerprints: []
            )
        )
    }

    func testSharedAccountIDWithNoActiveSiblingIsNotProtectedByAccountBranch() {
        // Two inactive siblings share an account, but neither is the live login
        // and their stored chains differ — nothing to protect against yet.
        let a = profile(accountID: "acct-1", organizationID: "org-a")
        let b = profile(accountID: "acct-1", organizationID: "org-b")

        XCTAssertFalse(
            RotationProtectionPolicy.accountIsLiveElsewhere(
                profile: a,
                among: [a, b],
                storedFingerprint: "a-fp",
                duplicatedStoredFingerprints: []
            )
        )
    }

    private func profile(
        accountID: String?,
        organizationID: String?,
        isActiveCLI: Bool = false
    ) -> AccountProfile {
        AccountProfile(
            provider: .claude,
            label: organizationID ?? "profile",
            identity: AccountIdentity(
                email: "user@example.com",
                organizationID: organizationID,
                accountID: accountID,
                source: .manual
            ),
            isActiveCLI: isActiveCLI
        )
    }
}
