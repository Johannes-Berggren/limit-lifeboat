import XCTest
@testable import LLMUsageMonitorCore

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

    func testTargetWithoutStoredCredentialsIsIneligible() {
        let target = candidate(
            label: "Claude B",
            hasStoredCredentials: false,
            snapshot: freshSnapshot(usedPercent: 15)
        )

        let advice = advisor.advise(candidates: [depletedActive(), target], now: now)

        XCTAssertNil(advice.bestCandidateID)
        XCTAssertFalse(advice.shouldAutoSwitch)
        XCTAssertNil(advice.reason)
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

    // MARK: - Fixtures

    private func depletedActive() -> SwitchCandidate {
        candidate(label: "Claude A", isActiveCLI: true, snapshot: freshSnapshot(usedPercent: 100))
    }

    private func candidate(
        label: String,
        isActiveCLI: Bool = false,
        hasStoredCredentials: Bool = true,
        snapshot: UsageSnapshot?
    ) -> SwitchCandidate {
        SwitchCandidate(
            profileID: UUID(),
            label: label,
            isActiveCLI: isActiveCLI,
            hasStoredCredentials: hasStoredCredentials,
            snapshot: snapshot
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
