import XCTest
@testable import LimitLifeboatCore

final class NotificationSwitchResolverTests: XCTestCase {
    private let resolver = NotificationSwitchResolver()

    private func candidate(
        id: UUID = UUID(),
        label: String,
        isActiveCLI: Bool = false,
        hasStoredCredentials: Bool = true
    ) -> SwitchCandidate {
        SwitchCandidate(
            profileID: id,
            label: label,
            isActiveCLI: isActiveCLI,
            hasStoredCredentials: hasStoredCredentials,
            snapshot: nil
        )
    }

    /// The notification sat unclicked while the advisor's preference moved on:
    /// the click follows the CURRENT best, not the post-time target.
    func testStaleEmbeddedTargetLosesToCurrentAdvice() {
        let embedded = candidate(label: "Posted Best")
        let advised = candidate(label: "Current Best")
        let active = candidate(label: "Active", isActiveCLI: true)

        let resolution = resolver.resolve(
            embeddedTargetID: embedded.profileID,
            advice: SwitchAdvice(bestCandidateID: advised.profileID, bestCandidateLabel: advised.label),
            candidates: [embedded, advised, active]
        )

        XCTAssertEqual(resolution, .switchTo(profileID: advised.profileID, label: "Current Best"))
    }

    /// Auto-switch (or the user) already moved to the embedded target — the
    /// intent is satisfied; switching to the advisor's next-best would
    /// ping-pong the CLI.
    func testEmbeddedTargetAlreadyActiveWins() {
        let embedded = candidate(label: "Target", isActiveCLI: true)
        let advised = candidate(label: "Next Best")

        let resolution = resolver.resolve(
            embeddedTargetID: embedded.profileID,
            advice: SwitchAdvice(bestCandidateID: advised.profileID, bestCandidateLabel: advised.label),
            candidates: [embedded, advised]
        )

        XCTAssertEqual(resolution, .alreadyActive(label: "Target"))
    }

    func testEmbeddedTargetUsedWhenNoAdvice() {
        let embedded = candidate(label: "Target")
        let active = candidate(label: "Active", isActiveCLI: true)

        let resolution = resolver.resolve(
            embeddedTargetID: embedded.profileID,
            advice: nil,
            candidates: [embedded, active]
        )

        XCTAssertEqual(resolution, .switchTo(profileID: embedded.profileID, label: "Target"))
    }

    func testEmbeddedTargetWithoutCredentialsAndNoAdviceHasNoTarget() {
        let embedded = candidate(label: "Target", hasStoredCredentials: false)
        let active = candidate(label: "Active", isActiveCLI: true)

        let resolution = resolver.resolve(
            embeddedTargetID: embedded.profileID,
            advice: SwitchAdvice(),
            candidates: [embedded, active]
        )

        guard case .noEligibleTarget = resolution else {
            return XCTFail("Expected noEligibleTarget, got \(resolution)")
        }
    }

    /// A removed profile leaves a dangling UUID in the payload; with no advice
    /// there is nothing to switch to.
    func testRemovedEmbeddedTargetAndNoAdviceHasNoTarget() {
        let active = candidate(label: "Active", isActiveCLI: true)

        let resolution = resolver.resolve(
            embeddedTargetID: UUID(),
            advice: nil,
            candidates: [active]
        )

        guard case .noEligibleTarget = resolution else {
            return XCTFail("Expected noEligibleTarget, got \(resolution)")
        }
    }

    /// Advice can go stale too: an advised target that became the active CLI
    /// since the advice was computed must not be "switched" to again.
    func testAdvisedTargetThatBecameActiveReportsAlreadyActive() {
        let advised = candidate(label: "Advised", isActiveCLI: true)

        let resolution = resolver.resolve(
            embeddedTargetID: advised.profileID,
            advice: SwitchAdvice(bestCandidateID: advised.profileID, bestCandidateLabel: advised.label),
            candidates: [advised]
        )

        XCTAssertEqual(resolution, .alreadyActive(label: "Advised"))
    }

    /// The advised target losing its credentials mid-flight falls back to the
    /// embedded target rather than giving up.
    func testAdvisedWithoutCredentialsFallsBackToEmbedded() {
        let advised = candidate(label: "Advised", hasStoredCredentials: false)
        let embedded = candidate(label: "Embedded")

        let resolution = resolver.resolve(
            embeddedTargetID: embedded.profileID,
            advice: SwitchAdvice(bestCandidateID: advised.profileID, bestCandidateLabel: advised.label),
            candidates: [advised, embedded]
        )

        XCTAssertEqual(resolution, .switchTo(profileID: embedded.profileID, label: "Embedded"))
    }
}
