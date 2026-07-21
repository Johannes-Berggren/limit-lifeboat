import Foundation
import XCTest
@testable import LimitLifeboatCore

final class CodexResetControlTests: XCTestCase {
    func testAutomationRequiresExplicitActiveHardLimitAndAvailableReset() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let policy = CodexResetAutomationPolicy()
        let eligible = profile(active: true, automatic: true)
        let snapshot = resetSnapshot(now: now)

        XCTAssertTrue(
            policy.shouldRedeem(
                profile: eligible,
                snapshot: snapshot,
                lastAttempt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: profile(active: true, automatic: false),
                snapshot: snapshot,
                lastAttempt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: profile(active: false, automatic: true),
                snapshot: snapshot,
                lastAttempt: nil,
                now: now
            )
        )

        var workspaceLimit = snapshot
        workspaceLimit.codexRateLimitReachedType = "workspace_member_usage_limit_reached"
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: eligible,
                snapshot: workspaceLimit,
                lastAttempt: nil,
                now: now
            )
        )

        var noCredits = snapshot
        noCredits.codexRateLimitResetAvailability = CodexRateLimitResetAvailability(availableCount: 0)
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: eligible,
                snapshot: noCredits,
                lastAttempt: nil,
                now: now
            )
        )
    }

    func testAutomationRejectsStaleBlockedAndBackoffStates() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let policy = CodexResetAutomationPolicy(retryBackoff: 3600)
        let profile = profile(active: true, automatic: true)
        let fresh = resetSnapshot(now: now)

        XCTAssertFalse(
            policy.shouldRedeem(
                profile: profile,
                snapshot: fresh,
                redemptionState: .redeeming,
                lastAttempt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: profile,
                snapshot: fresh,
                redemptionState: .refreshRequired(reason: "refresh"),
                lastAttempt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: profile,
                snapshot: fresh,
                lastAttempt: now.addingTimeInterval(-3599),
                now: now
            )
        )
        XCTAssertTrue(
            policy.shouldRedeem(
                profile: profile,
                snapshot: fresh,
                lastAttempt: now.addingTimeInterval(-3600),
                now: now
            )
        )

        var stale = fresh
        stale.lastRefreshed = now.addingTimeInterval(-UsageThresholds.standard.staleAfter - 1)
        XCTAssertFalse(
            policy.shouldRedeem(
                profile: profile,
                snapshot: stale,
                lastAttempt: nil,
                now: now
            )
        )
    }

    func testRecoveryAlwaysEvaluatesResetBeforeSwitch() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let policy = CodexResetAutomationPolicy()
        let eligible = profile(active: true, automatic: true)

        XCTAssertEqual(
            policy.recoverySteps(
                profile: eligible,
                snapshot: resetSnapshot(now: now),
                lastAttempt: nil,
                now: now
            ),
            [.redeemReset, .evaluateAccountSwitch]
        )
        XCTAssertEqual(
            policy.recoverySteps(
                profile: profile(active: true, automatic: false),
                snapshot: resetSnapshot(now: now),
                lastAttempt: nil,
                now: now
            ),
            [.evaluateAccountSwitch]
        )
    }

    func testPresentationDistinguishesUnsupportedZeroPositiveAndStale() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        XCTAssertEqual(CodexResetPresentation(snapshot: nil, now: now).state, .unsupported)

        var snapshot = resetSnapshot(now: now)
        snapshot.codexRateLimitResetAvailability = CodexRateLimitResetAvailability(availableCount: 0)
        let zero = CodexResetPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(zero.state, .zero)
        XCTAssertEqual(zero.badgeText, "0 resets")
        XCTAssertFalse(zero.canRedeem)

        snapshot.codexRateLimitResetAvailability = CodexRateLimitResetAvailability(availableCount: 2)
        let positive = CodexResetPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(positive.state, .available(count: 2))
        XCTAssertEqual(positive.badgeText, "2 resets")
        XCTAssertTrue(positive.canRedeem)

        snapshot.lastRefreshed = now.addingTimeInterval(-UsageThresholds.standard.staleAfter - 1)
        let stale = CodexResetPresentation(snapshot: snapshot, now: now)
        XCTAssertEqual(stale.state, .stale(count: 2))
        XCTAssertFalse(stale.canRedeem)
    }

    func testPresentationDistinguishesBusyFailureAndRefreshRequired() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let snapshot = resetSnapshot(now: now)
        let busy = CodexResetPresentation(snapshot: snapshot, redemptionState: .redeeming, now: now)
        XCTAssertEqual(busy.state, .busy(count: 2))
        XCTAssertFalse(busy.canRedeem)

        let failed = CodexResetPresentation(
            snapshot: snapshot,
            redemptionState: .failed(reason: "Try again"),
            now: now
        )
        XCTAssertEqual(failed.state, .failed(count: 2, reason: "Try again"))
        XCTAssertTrue(failed.canRedeem)

        var staleSnapshot = snapshot
        staleSnapshot.lastRefreshed = now.addingTimeInterval(-UsageThresholds.standard.staleAfter - 1)
        let staleFailure = CodexResetPresentation(
            snapshot: staleSnapshot,
            redemptionState: .failed(reason: "Try again"),
            now: now
        )
        XCTAssertEqual(staleFailure.state, .stale(count: 2))
        XCTAssertFalse(staleFailure.canRedeem)

        let refreshRequired = CodexResetPresentation(
            snapshot: snapshot,
            redemptionState: .refreshRequired(reason: "Refresh first"),
            now: now
        )
        XCTAssertEqual(
            refreshRequired.state,
            .refreshRequired(count: 2, reason: "Refresh first")
        )
        XCTAssertFalse(refreshRequired.canRedeem)
    }

    func testAttemptStoreReusesPendingKeyAcrossInstancesUntilTerminalOutcome() throws {
        let suite = "CodexResetAttemptStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileID = UUID()

        let first = CodexResetAttemptStore(defaults: defaults)
        let key = first.idempotencyKey(for: profileID)
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(first.idempotencyKey(for: profileID), key)

        let afterRelaunch = CodexResetAttemptStore(defaults: defaults)
        XCTAssertEqual(afterRelaunch.pendingKey(for: profileID), key)
        XCTAssertEqual(afterRelaunch.idempotencyKey(for: profileID), key)

        afterRelaunch.completeAttempt(for: profileID)
        XCTAssertNil(first.pendingKey(for: profileID))
        XCTAssertNotEqual(first.idempotencyKey(for: profileID), key)
    }

    private func profile(active: Bool, automatic: Bool) -> AccountProfile {
        AccountProfile(
            provider: .codex,
            label: "Codex",
            isActiveCLI: active,
            autoUseCodexRateLimitResets: automatic
        )
    }

    private func resetSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: UUID(),
            provider: .codex,
            windows: [
                UsageWindow(
                    id: "codex-300",
                    kind: .session,
                    label: "Session",
                    usedPercent: 100,
                    riskLevel: .depleted
                )
            ],
            codexRateLimitResetAvailability: CodexRateLimitResetAvailability(availableCount: 2),
            codexRateLimitReachedType: "rate_limit_reached",
            riskLevel: .depleted,
            source: "Codex app server",
            lastRefreshed: now,
            parseConfidence: .high
        )
    }
}
