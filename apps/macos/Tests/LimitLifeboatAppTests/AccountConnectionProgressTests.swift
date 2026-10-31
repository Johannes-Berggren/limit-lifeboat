import Foundation
import LimitLifeboatAppWorkflows
import LimitLifeboatCore
import XCTest

final class AccountConnectionProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyFreshUsageForTheResolvedAccountCompletesLogin() {
        let placeholder = AccountProfile(provider: .codex, label: "New account")
        let existing = AccountProfile(provider: .codex, label: "Existing account")
        var progress = AccountConnectionProgress(profileID: placeholder.id, detail: "Signing in", activateAfterLogin: false)
        // Login can match an existing saved account rather than the placeholder.
        progress.linked(profile: existing, detail: "Existing account verified.", now: now)
        progress.receivedUsage(snapshot(for: existing, at: now.addingTimeInterval(-1)))
        progress.receivedUsage(snapshot(for: placeholder, at: now.addingTimeInterval(1)))
        XCTAssertEqual(progress.stage, .loadingUsage)

        progress.receivedUsage(snapshot(for: existing, at: now.addingTimeInterval(1)))
        XCTAssertEqual(progress.stage, .connected)
        XCTAssertEqual(progress.profileID, existing.id)
        XCTAssertFalse(progress.activateAfterLogin, "A retry must preserve the request to keep the previous account active")
    }

    func testUsageRecoveryPreservesTheActualLoginOutcome() {
        let profile = AccountProfile(provider: .claude, label: "Work")
        var progress = AccountConnectionProgress(profileID: profile.id, detail: "Signing in")
        let outcome = "Work is now active because the previous account could not be restored."
        progress.linked(profile: profile, detail: outcome, now: now)
        progress.usageUnavailable(reason: "Offline.")
        XCTAssertTrue(progress.detail.contains(outcome))
        progress.receivedUsage(snapshot(for: profile, at: now.addingTimeInterval(60)))
        XCTAssertEqual(progress.stage, .connected)
        XCTAssertTrue(progress.detail.contains(outcome))
    }

    func testAnEmptyReadingDoesNotClaimUsageLoaded() {
        let profile = AccountProfile(provider: .codex, label: "Personal")
        var progress = AccountConnectionProgress(profileID: profile.id, detail: "Signing in")
        progress.linked(profile: profile, detail: "Verified.", now: now)
        progress.receivedUsage(UsageSnapshot(accountID: profile.id, provider: .codex, source: "Unavailable", lastRefreshed: now))
        XCTAssertEqual(progress.stage, .loadingUsage)
    }

    func testUsageCannotBypassAnUnverifiedOrUnauthorizedLogin() {
        let profile = AccountProfile(provider: .claude, label: "Work")
        for stage in [AccountConnectionProgress.Stage.waiting, .verifying,
                      .authorizationRequired(.claudeCode), .failed, .timedOut] {
            var progress = AccountConnectionProgress(profileID: profile.id, detail: "Not verified")
            progress.stage = stage
            progress.receivedUsage(snapshot(for: profile, at: now))
            XCTAssertEqual(progress.stage, stage)
        }
    }

    func testRecheckRequiresEveryOriginalDaemonToStop() {
        let first = CodexDaemonProcess(pid: 123, startedAt: now)
        let second = CodexDaemonProcess(pid: 456, startedAt: now)
        var receipt = codexReceipt(daemons: .running([first, second]))
        receipt.currentDaemons = .running([second])
        XCTAssertEqual(receipt.serverStatus, .restartNeeded)
        XCTAssertTrue(receipt.needsAttention)

        receipt.currentDaemons = .notRunning
        XCTAssertEqual(receipt.serverStatus, .previousServerStopped)
    }

    func testReusedPidWithNewStartTimeCountsAsAReplacementServer() {
        let old = CodexDaemonProcess(pid: 123, startedAt: now)
        let new = CodexDaemonProcess(pid: 123, startedAt: now.addingTimeInterval(30))
        var receipt = codexReceipt(daemons: .running([old]))
        receipt.currentDaemons = .running([new])
        XCTAssertEqual(receipt.serverStatus, .previousServerStopped)
        // This proves process replacement only. It never verifies server auth.
        receipt.loginVerification = .unavailable
        XCTAssertTrue(receipt.needsAttention)
    }

    func testAnUnknownDaemonObservationNeverConfirmsRestart() {
        let daemon = CodexDaemonProcess(pid: 123, startedAt: now)
        var receipt = codexReceipt(daemons: .running([daemon]))
        receipt.currentDaemons = .unavailable
        XCTAssertEqual(receipt.serverStatus, .unknown)
        XCTAssertTrue(receipt.needsAttention)

        receipt = codexReceipt(daemons: .unavailable)
        receipt.currentDaemons = .running([daemon])
        XCTAssertEqual(receipt.serverStatus, .unknown)
    }

    func testPlaintextOverrideAndChangedLoginRemainActionableWithoutADaemon() {
        let profile = AccountProfile(provider: .claude, label: "Work")
        var receipt = AccountSwitchReceipt(profile: profile, daemons: .notRunning, hasPlaintextOverride: true)
        XCTAssertTrue(receipt.needsAttention)
        receipt.hasPlaintextOverride = false
        XCTAssertFalse(receipt.needsAttention)
        receipt.loginVerification = .differentLogin
        XCTAssertTrue(receipt.needsAttention)
    }

    private func snapshot(for profile: AccountProfile, at date: Date) -> UsageSnapshot {
        UsageSnapshot(accountID: profile.id, provider: profile.provider,
                      windows: [UsageWindow(id: "session", kind: .session, label: "Session", usedPercent: 20)],
                      source: "Test", lastRefreshed: date)
    }

    private func codexReceipt(daemons: CodexDaemonState) -> AccountSwitchReceipt {
        AccountSwitchReceipt(profile: AccountProfile(provider: .codex, label: "Personal"), daemons: daemons, hasPlaintextOverride: false)
    }
}
