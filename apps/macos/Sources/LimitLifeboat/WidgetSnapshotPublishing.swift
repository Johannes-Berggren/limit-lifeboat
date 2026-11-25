import Foundation
import LimitLifeboatCore
import WidgetKit

/// Keeps `Widget/widget-snapshot.json` in step with the account cards. The
/// file is rewritten whenever anything in it changes; WidgetKit is only asked
/// to redraw when something a glance would notice changed (a whole percent,
/// a note, the active account), because app-requested reloads are budgeted.
/// The widget's own timeline picks up curve-only changes every 15 minutes;
/// a quiet refresh still reloads after `widgetQuietReloadInterval` so the
/// "updated" age doesn't keep counting from an old reading.
extension AppState {
    static let widgetQuietReloadInterval: TimeInterval = 10 * 60

    func publishWidgetSnapshot(now: Date = Date()) {
        let snapshot = makeWidgetSnapshot(now: now)
        let previous = lastPublishedWidgetSnapshot
        if let previous, Self.widgetFileContentMatches(previous, snapshot) {
            return
        }
        do {
            try WidgetSnapshotStore(applicationSupportDirectory: applicationSupportDirectory).write(snapshot)
            lastPublishedWidgetSnapshot = snapshot
        } catch {
            AppLog.persistence.error("Could not save the widget snapshot: \(error.localizedDescription, privacy: .public)")
            return
        }
        if let previous, Self.widgetGlanceMatches(previous, snapshot),
           let lastReload = lastWidgetReloadAt,
           now.timeIntervalSince(lastReload) < Self.widgetQuietReloadInterval {
            return
        }
        // Unbundled `swift run` and test hosts have no widget to reload.
        guard Bundle.main.bundleIdentifier != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
        lastWidgetReloadAt = now
    }

    func makeWidgetSnapshot(now: Date = Date()) -> WidgetSnapshot {
        let inputs = profiles.map { profile in
            let estimates = burnRateEstimates[profile.id] ?? [:]
            let advice = switchAdvice[profile.provider]
            let presentation = AccountRowPresentation(
                profile: profile,
                snapshot: snapshots[profile.id],
                hasStoredSnapshot: storedSnapshotStatus(for: profile) == .present,
                storedCredentialAvailability: storedCredentialAvailability(for: profile),
                sharesActiveCredentialChain: sharesActiveClaudeCredentialChain(for: profile),
                refreshState: refreshStates[profile.id] ?? .idle,
                adviceReason: advice?.bestCandidateID == profile.id ? advice?.reason : nil,
                estimates: estimates,
                loginExpiresAt: loginExpiresAt(for: profile),
                showOrganizationName: settings.showOrganizationNames,
                now: now
            )
            return WidgetSnapshotBuilder.AccountInput(
                profile: profile,
                snapshot: snapshots[profile.id],
                presentation: presentation,
                readings: windowReadings[profile.id] ?? [:],
                estimates: estimates
            )
        }
        var bestNext: [Provider: UUID] = [:]
        for (provider, advice) in switchAdvice {
            if let id = advice.bestCandidateID {
                bestNext[provider] = id
            }
        }
        return WidgetSnapshotBuilder.build(
            accounts: inputs,
            bestNextIDs: bestNext,
            showsUsageCurves: settings.usageCurvesEnabled,
            now: now
        )
    }

    /// Equal apart from when it was generated.
    static func widgetFileContentMatches(_ lhs: WidgetSnapshot, _ rhs: WidgetSnapshot) -> Bool {
        var lhs = lhs
        lhs.generatedAt = rhs.generatedAt
        return lhs == rhs
    }

    /// Equal in everything the widget draws as text or bar length: whole
    /// percentages, resets, notes, risk and the active/advised accounts.
    static func widgetGlanceMatches(_ lhs: WidgetSnapshot, _ rhs: WidgetSnapshot) -> Bool {
        func glance(_ snapshot: WidgetSnapshot) -> WidgetSnapshot {
            var copy = snapshot
            copy.generatedAt = .distantPast
            copy.accounts = copy.accounts.map { account in
                var account = account
                account.lastRefreshed = nil
                account.windows = account.windows.map { window in
                    var window = window
                    window.usedPercent = window.usedPercent.rounded()
                    window.runway = nil
                    return window
                }
                return account
            }
            return copy
        }
        return glance(lhs) == glance(rhs)
    }
}
