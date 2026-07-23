import XCTest
@testable import LimitLifeboatCore

final class SwitchAdvisorTests: XCTestCase {
    private let advisor = SwitchAdvisor()
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testNoCandidatesGivesEmptyAdvice() {
        let advice = advisor.advise(candidates: [], now: now)

        XCTAssertNil(advice.bestCandidateID)
        XCTAssertNil(advice.bestCandidateLabel)
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertNil(advice.reason)
    }

    func testDepletedActiveWithFreshHealthyTargetAutoSwitches() {
        let target = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 15))

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertEqual(advice.bestCandidateLabel, "Claude B")
        XCTAssertTrue(advice.shouldAutoSwitch)
        XCTAssertEqual(advice.reason, "Claude B has ~85% of its session window left")
    }

    func testStaleTargetWithoutElapsedResetIsIneligible() {
        let target = candidate(label: "Claude B", snapshot: staleSnapshot(usedPercent: 15))

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertNil(advice.bestCandidateID)
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertNil(advice.reason)
    }

    func testStaleTargetWithElapsedResetIsEligibleAndScoresFullQuota() {
        // Constrained old reading, but every window rolled over since: full
        // quota regardless of staleness, so the depleted active auto-switches.
        let target = candidate(
            label: "Claude B",
            snapshot: staleSnapshot(usedPercent: 92, resetDate: now.addingTimeInterval(-600))
        )

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertTrue(advice.shouldAutoSwitch)
        XCTAssertEqual(advice.reason, "Claude B's limit window has reset")
    }

    func testCodexTargetsAreProviderAgnostic() {
        // SwitchCandidate carries no provider, so a depleted active Codex login
        // and a Codex target whose window rolled over auto-switch exactly like
        // Claude — the parity that lets Codex reuse this advisor unchanged.
        let activeCodex = candidate(
            label: "Codex A",
            isActiveCLI: true,
            snapshot: codexSnapshot(usedPercent: 100, lastRefreshed: now.addingTimeInterval(-600), resetDate: nil)
        )
        let targetCodex = candidate(
            label: "Codex B",
            snapshot: codexSnapshot(usedPercent: 92, lastRefreshed: now.addingTimeInterval(-4 * 3600), resetDate: now.addingTimeInterval(-600))
        )

        let advice = advisor.advise(candidates: [activeCodex, targetCodex], now: now)

        XCTAssertEqual(advice.bestCandidateID, targetCodex.profileID)
        XCTAssertTrue(advice.shouldAutoSwitch)
    }

    func testStaleTargetWithElapsedSessionButPendingWeeklyIsIneligible() {
        // The session reset rolling over restores only the session quota; the
        // stale reading's nearly-depleted weekly window still stands, so the
        // candidate must not score as full quota or auto-switch — even though
        // the snapshot's scalar resetDate mirrors the elapsed session window.
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            windows: [
                window(
                    id: "session",
                    kind: .session,
                    label: "Session",
                    usedPercent: 96,
                    resetDate: now.addingTimeInterval(-600)
                ),
                window(
                    id: "weekly-all",
                    kind: .weekly,
                    label: "Weekly (all models)",
                    usedPercent: 95,
                    resetDate: now.addingTimeInterval(5 * 86_400)
                )
            ],
            resetDate: now.addingTimeInterval(-600),
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: 96),
            source: "test",
            lastRefreshed: now.addingTimeInterval(-4 * 3600),
            parseConfidence: .high
        )
        let target = candidate(label: "Claude B", snapshot: snapshot)

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertNil(advice.bestCandidateID)
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertNil(advice.reason)
    }

    func testFreshTargetWithElapsedSessionScoresTheRemainingWeekly() {
        // The elapsed session reset counts as full headroom, so the weekly
        // window's 40% remainder is the score — not an unconditional 100.
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            windows: [
                window(
                    id: "session",
                    kind: .session,
                    label: "Session",
                    usedPercent: 96,
                    resetDate: now.addingTimeInterval(-600)
                ),
                window(
                    id: "weekly-all",
                    kind: .weekly,
                    label: "Weekly (all models)",
                    usedPercent: 60,
                    resetDate: now.addingTimeInterval(5 * 86_400)
                )
            ],
            resetDate: now.addingTimeInterval(-600),
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: 96),
            source: "test",
            lastRefreshed: now.addingTimeInterval(-600),
            parseConfidence: .high
        )
        let target = candidate(label: "Claude B", snapshot: snapshot)

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertTrue(advice.shouldAutoSwitch)
        XCTAssertEqual(advice.reason, "Claude B has ~40% of its weekly window left")
    }

    func testWarningActiveHintsWithoutAutoSwitch() {
        let active = candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 85))
        let target = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 15))

        let advice = advisor.advise(candidates: [active, target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertEqual(advice.bestCandidateLabel, "Claude B")
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertNotNil(advice.reason)
    }

    func testImprovementBelowMarginDoesNotAutoSwitch() {
        let advisor = SwitchAdvisor(configuration: .init(minimumImprovementPercent: 90))
        let target = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 15))

        // Active headroom is 0, target headroom is 85: below the 90-point bar.
        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    func testHeadroomBelowMinimumDoesNotAutoSwitch() {
        let target = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 75))

        // 25% headroom clears the improvement margin but not the 30% floor.
        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    func testTargetBlockedBySessionPolicyIsIneligible() {
        let target = candidate(
            label: "Claude B",
            manualSwitchEligibility: .blocked(reason: "Login expired"),
            snapshot: freshSnapshot(usedPercent: 15)
        )

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertNil(advice.bestCandidateID)
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertNil(advice.reason)
    }

    func testManualOnlyTargetRemainsPassiveHintButCannotAutoSwitch() {
        let target = candidate(
            label: "Claude B",
            manualSwitchEligibility: .eligible,
            automaticSwitchEligibility: .blocked(reason: "Rotation required"),
            snapshot: freshSnapshot(usedPercent: 15)
        )

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertEqual(advice.bestCandidateID, target.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    func testAutomaticSwitchSkipsManualOnlyBestForNextReadOnlyTarget() {
        let manualOnly = candidate(
            label: "Manual Only",
            manualSwitchEligibility: .eligible,
            automaticSwitchEligibility: .blocked(reason: "Rotation required"),
            snapshot: freshSnapshot(usedPercent: 5)
        )
        let readOnly = candidate(
            label: "Read Only",
            snapshot: freshSnapshot(usedPercent: 15)
        )

        let advice = advisor.advise(
            candidates: [depletedActive(), manualOnly, readOnly],
            now: now
        )

        XCTAssertEqual(advice.bestCandidateID, readOnly.profileID)
        XCTAssertEqual(advice.bestCandidateLabel, "Read Only")
        XCTAssertTrue(advice.shouldAutoSwitch)
    }

    func testDepletedTargetIsIneligible() {
        let target = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 100))

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertNil(advice.bestCandidateID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    func testScoreIsTheTightestWindowsHeadroom() {
        let snapshot = UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            windows: [
                window(id: "session", kind: .session, label: "Session", usedPercent: 10),
                window(id: "weekly-all", kind: .weekly, label: "Weekly (all models)", usedPercent: 60)
            ],
            source: "test",
            lastRefreshed: now.addingTimeInterval(-600),
            parseConfidence: .high
        )
        let target = candidate(label: "Claude B", snapshot: snapshot)

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertTrue(advice.shouldAutoSwitch)
        XCTAssertEqual(advice.reason, "Claude B has ~40% of its weekly window left")
    }

    func testTieBreaksOnLabelForDeterminism() {
        let later = candidate(label: "Claude C", snapshot: freshSnapshot(usedPercent: 15))
        let earlier = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 15))

        let advice = advisor.advise(candidates: [depletedActive(), later, earlier], now: now)

        XCTAssertEqual(advice.bestCandidateID, earlier.profileID)
        XCTAssertEqual(advice.bestCandidateLabel, "Claude B")
    }

    // MARK: - Priority ordering

    func testHintPrefersHigherPriorityDespiteLowerHeadroom() {
        let active = candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 85))
        let preferred = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 60), priorityRank: 1)
        let roomier = candidate(label: "Claude C", snapshot: freshSnapshot(usedPercent: 10), priorityRank: 2)

        let advice = advisor.advise(candidates: [active, preferred, roomier], now: now)

        XCTAssertEqual(advice.bestCandidateID, preferred.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    func testDepletedActiveFallsThroughToLowerPriorityWhenGateFails() {
        // The preferred target's 25% headroom misses the 30% floor; the
        // depleted active must not stay stuck on it when the next account in
        // priority order qualifies.
        let active = candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 100))
        let preferred = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 75), priorityRank: 1)
        let fallback = candidate(label: "Claude C", snapshot: freshSnapshot(usedPercent: 15), priorityRank: 2)

        let advice = advisor.advise(candidates: [active, preferred, fallback], now: now)

        XCTAssertEqual(advice.bestCandidateID, fallback.profileID)
        XCTAssertTrue(advice.shouldAutoSwitch)
        XCTAssertFalse(advice.isRebalance)
    }

    func testDepletedActiveHintsHighestPriorityWhenNoTargetPassesGate() {
        let active = candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 100))
        let preferred = candidate(label: "Claude B", snapshot: freshSnapshot(usedPercent: 75), priorityRank: 1)
        let other = candidate(label: "Claude C", snapshot: freshSnapshot(usedPercent: 76), priorityRank: 2)

        let advice = advisor.advise(candidates: [active, preferred, other], now: now)

        XCTAssertEqual(advice.bestCandidateID, preferred.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    func testRebalancesToRecoveredHigherPriorityWhileActiveIsHealthy() {
        let active = candidate(label: "Claude B", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 40), priorityRank: 1)
        let preferred = candidate(
            label: "Claude A",
            snapshot: freshSnapshot(usedPercent: 92, resetDate: now.addingTimeInterval(-600)),
            priorityRank: 0
        )

        let advice = advisor.advise(candidates: [active, preferred], now: now)

        XCTAssertEqual(advice.bestCandidateID, preferred.profileID)
        XCTAssertTrue(advice.shouldAutoSwitch)
        XCTAssertTrue(advice.isRebalance)
        XCTAssertEqual(advice.reason, "Claude A is higher priority and its limit window has reset")
    }

    func testRebalanceRequiresTheStricterRecoveryBar() {
        let active = candidate(label: "Claude B", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 40), priorityRank: 1)
        let belowBar = candidate(label: "Claude A", snapshot: freshSnapshot(usedPercent: 60), priorityRank: 0)

        let hint = advisor.advise(candidates: [active, belowBar], now: now)

        // 40% headroom misses the 50% rebalance bar: passive hint only.
        XCTAssertEqual(hint.bestCandidateID, belowBar.profileID)
        XCTAssertFalse(hint.shouldAutoSwitch)

        let atBar = candidate(label: "Claude A", snapshot: freshSnapshot(usedPercent: 50), priorityRank: 0)
        let rebalance = advisor.advise(candidates: [active, atBar], now: now)

        XCTAssertEqual(rebalance.bestCandidateID, atBar.profileID)
        XCTAssertTrue(rebalance.shouldAutoSwitch)
        XCTAssertTrue(rebalance.isRebalance)
    }

    func testNoRebalanceTowardLowerPriority() {
        // A recovered account below the active one in priority is never an
        // automatic target while the active account still has quota.
        let active = candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 40), priorityRank: 0)
        let lower = candidate(
            label: "Claude B",
            snapshot: freshSnapshot(usedPercent: 92, resetDate: now.addingTimeInterval(-600)),
            priorityRank: 1
        )

        let advice = advisor.advise(candidates: [active, lower], now: now)

        XCTAssertEqual(advice.bestCandidateID, lower.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertFalse(advice.isRebalance)
    }

    func testRebalanceRequiresAutomaticEligibility() {
        let active = candidate(label: "Claude B", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 40), priorityRank: 1)
        let manualOnly = candidate(
            label: "Claude A",
            manualSwitchEligibility: .eligible,
            automaticSwitchEligibility: .blocked(reason: "Rotation required"),
            snapshot: freshSnapshot(usedPercent: 92, resetDate: now.addingTimeInterval(-600)),
            priorityRank: 0
        )

        let advice = advisor.advise(candidates: [active, manualOnly], now: now)

        XCTAssertEqual(advice.bestCandidateID, manualOnly.profileID)
        XCTAssertFalse(advice.shouldAutoSwitch)
    }

    // MARK: - Fixtures

    private func depletedActive() -> SwitchCandidate {
        candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 100))
    }

    private func candidate(
        label: String,
        isActiveCLI: Bool = false,
        manualSwitchEligibility: AccountSwitchEligibility = .eligible,
        automaticSwitchEligibility: AccountSwitchEligibility? = nil,
        snapshot: UsageSnapshot?,
        priorityRank: Int = 0
    ) -> SwitchCandidate {
        SwitchCandidate(
            profileID: UUID(),
            label: label,
            isActiveCLI: isActiveCLI,
            manualSwitchEligibility: manualSwitchEligibility,
            automaticSwitchEligibility: automaticSwitchEligibility ?? manualSwitchEligibility,
            snapshot: snapshot,
            priorityRank: priorityRank
        )
    }

    private func freshSnapshot(usedPercent: Double, resetDate: Date? = nil) -> UsageSnapshot {
        snapshot(usedPercent: usedPercent, lastRefreshed: now.addingTimeInterval(-600), resetDate: resetDate)
    }

    /// Older than the default 3h staleAfter.
    private func staleSnapshot(usedPercent: Double, resetDate: Date? = nil) -> UsageSnapshot {
        snapshot(usedPercent: usedPercent, lastRefreshed: now.addingTimeInterval(-4 * 3600), resetDate: resetDate)
    }

    private func snapshot(usedPercent: Double, lastRefreshed: Date, resetDate: Date?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            provider: .claude,
            windows: [
                window(id: "session", kind: .session, label: "Session", usedPercent: usedPercent, resetDate: resetDate)
            ],
            resetDate: resetDate,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent),
            source: "test",
            lastRefreshed: lastRefreshed,
            parseConfidence: .high
        )
    }

    private func codexSnapshot(usedPercent: Double, lastRefreshed: Date, resetDate: Date?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            provider: .codex,
            windows: [
                window(id: "codex-300", kind: .session, label: "Session", usedPercent: usedPercent, resetDate: resetDate)
            ],
            resetDate: resetDate,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent),
            source: "test",
            lastRefreshed: lastRefreshed,
            parseConfidence: .high
        )
    }

    private func window(
        id: String,
        kind: UsageWindowKind,
        label: String,
        usedPercent: Double,
        resetDate: Date? = nil
    ) -> UsageWindow {
        UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            resetDate: resetDate,
            riskLevel: UsageThresholds.standard.riskLevel(usedPercent: usedPercent)
        )
    }
}
