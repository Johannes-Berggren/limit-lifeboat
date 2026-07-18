import AppKit
import Foundation
import LimitLifeboatCore
import UserNotifications

/// Category/action identifiers for the actionable "switch" notifications.
/// Action titles are fixed at registration (dynamic per-target titles would
/// require re-registering the category set before every post, which relabels
/// already-delivered notifications), so the target lives in `userInfo` and
/// the click re-resolves against live advice. File-scope (not nested in the
/// controller) so the nonisolated notification-delegate callbacks can read it.
enum NotificationSwitchAction {
    static let categoryBest = "limit-switch"
    static let categoryThisAccount = "limit-switch-here"
    static let actionID = "switch-now"
    static let actionKey = "action"
    static let actionValue = "switch"
    static let providerKey = "provider"
    static let targetKey = "target"
}

@MainActor
final class UsageAlertController {
    private var lastNotifiedRisk: [AlertWindowKey: RiskLevel] = [:]
    /// Only used for `currentRisk` re-arming, which is session-flag-independent;
    /// alert planning constructs a planner per call with the user's setting.
    private let thresholdPlanner = ThresholdAlertPlanner()
    private let notifiedResetsKey = "notifiedResetDates"
    private let notifiedPaceKey = "notifiedPaceAlerts"

    /// Reset alerts survive relaunches (persisted, keyed by account+window and
    /// reset date) so a restart does not re-announce quotas that were already
    /// reported back. The UserDefaults key is `"<profileID>|<windowID>"`.
    func notifiedResetKeys() -> [AlertWindowKey: Date] {
        windowKeyedDates(forKey: notifiedResetsKey)
    }

    /// Same persistence scheme for "on pace to run out" alerts.
    func notifiedPaceKeys() -> [AlertWindowKey: Date] {
        windowKeyedDates(forKey: notifiedPaceKey)
    }

    private func windowKeyedDates(forKey defaultsKey: String) -> [AlertWindowKey: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        var result: [AlertWindowKey: Date] = [:]
        for (key, value) in stored {
            // Legacy entries were bare UUIDs (no window component); drop them —
            // the worst case is one duplicate "quota back" alert after upgrade.
            guard let separator = key.firstIndex(of: "|") else {
                continue
            }
            let idPart = String(key[..<separator])
            let windowID = String(key[key.index(after: separator)...])
            guard let id = UUID(uuidString: idPart), !windowID.isEmpty else {
                continue
            }
            result[AlertWindowKey(profileID: id, windowID: windowID)] = Date(timeIntervalSince1970: value)
        }
        return result
    }

    func handlePaceAlert(_ alert: PaceAlert, provider: Provider, advisedTargetID: UUID? = nil) {
        markWindowNotified(
            defaultsKey: notifiedPaceKey,
            profileID: alert.profileID,
            windowID: alert.windowID,
            date: alert.resetDate ?? Date()
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var parts = [
            "At the current pace, \(provider.displayName) \(alert.windowLabel) usage runs out around \(formatter.string(from: alert.projectedDepletion))."
        ]
        if let reset = alert.resetDate {
            parts.append("The window resets \(formatter.string(from: reset)).")
        }
        postNotification(
            identifier: "pace-\(alert.profileID.uuidString)-\(alert.windowID)-\(Int(alert.projectedDepletion.timeIntervalSince1970))",
            title: "\(alert.profileLabel): on pace to hit the \(alert.windowLabel) limit",
            body: parts.joined(separator: " "),
            categoryIdentifier: NotificationSwitchAction.categoryBest,
            userInfo: switchUserInfo(provider: provider, targetID: advisedTargetID)
        )
    }

    func handleAutoSwitch(fromLabel: String?, toLabel: String, provider: Provider, reason: String?) {
        var parts: [String] = []
        if let fromLabel {
            parts.append("\(fromLabel) hit its limit.")
        }
        if let reason {
            parts.append(reason)
        }
        parts.append("New terminal sessions use \(toLabel).")
        postNotification(
            identifier: "autoswitch-\(toLabel)-\(Int(Date().timeIntervalSince1970))",
            title: "Switched \(provider.displayName) CLI to \(toLabel)",
            body: parts.joined(separator: " ")
        )
    }

    /// Drops every persisted and in-memory dedupe key for a removed profile
    /// so UserDefaults does not accumulate dead entries forever.
    func forgetProfile(_ profileID: UUID) {
        let prefix = "\(profileID.uuidString)|"
        for defaultsKey in [notifiedResetsKey, notifiedPaceKey] {
            let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
            let remaining = stored.filter { !$0.key.hasPrefix(prefix) }
            UserDefaults.standard.set(remaining, forKey: defaultsKey)
        }
        lastNotifiedRisk = lastNotifiedRisk.filter { $0.key.profileID != profileID }
    }

    // MARK: - Shared posting/persistence

    private func markWindowNotified(defaultsKey: String, profileID: UUID, windowID: String, date: Date) {
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        stored["\(profileID.uuidString)|\(windowID)"] = date.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    private func postNotification(
        identifier: String,
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [String: Any]? = nil
    ) {
        // UNUserNotificationCenter requires a real bundle; an unbundled
        // `swift run` must not crash.
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        if let userInfo {
            content.userInfo = userInfo
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        NSApplication.shared.requestUserAttention(.informationalRequest)
    }

    /// The switch-action payload. The posted-time target is a fallback only;
    /// the click handler re-resolves against live advice.
    private func switchUserInfo(provider: Provider, targetID: UUID?) -> [String: Any] {
        var info: [String: Any] = [
            NotificationSwitchAction.actionKey: NotificationSwitchAction.actionValue,
            NotificationSwitchAction.providerKey: provider.rawValue
        ]
        if let targetID {
            info[NotificationSwitchAction.targetKey] = targetID.uuidString
        }
        return info
    }

    /// Feedback for a clicked switch action that did not result in a switch —
    /// the user acted on a notification, so silence would read as a break.
    func handleNotificationSwitchOutcome(title: String, body: String) {
        postNotification(
            identifier: "switch-outcome-\(Int(Date().timeIntervalSince1970))",
            title: title,
            body: body
        )
    }

    func handleResetElapsed(_ alert: ResetAlert) {
        markWindowNotified(
            defaultsKey: notifiedResetsKey,
            profileID: alert.profileID,
            windowID: alert.windowID,
            date: alert.resetDate
        )
        postNotification(
            identifier: "reset-\(alert.profileID.uuidString)-\(alert.windowID)-\(Int(alert.resetDate.timeIntervalSince1970))",
            title: "\(alert.profileLabel): \(alert.windowLabel) quota likely back",
            body: "The \(alert.provider.displayName) \(alert.windowLabel) limit window has rolled over since the last reading. Switch the CLI to \(alert.profileLabel) to keep using included usage.",
            categoryIdentifier: NotificationSwitchAction.categoryThisAccount,
            userInfo: switchUserInfo(provider: alert.provider, targetID: alert.profileID)
        )
    }

    func requestAuthorization() {
        // UNUserNotificationCenter requires a real bundle; guard so an
        // unbundled `swift run` does not crash at startup.
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let switchToBest = UNNotificationCategory(
            identifier: NotificationSwitchAction.categoryBest,
            actions: [
                UNNotificationAction(identifier: NotificationSwitchAction.actionID, title: "Switch to Best Account")
            ],
            intentIdentifiers: []
        )
        let switchToThisAccount = UNNotificationCategory(
            identifier: NotificationSwitchAction.categoryThisAccount,
            actions: [
                UNNotificationAction(identifier: NotificationSwitchAction.actionID, title: "Switch to This Account")
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([switchToBest, switchToThisAccount])
    }

    /// Per-window near-limit alerts. Session (5h) windows only notify when the
    /// user opts in — heavy sessions would fire on every burn-down.
    /// Each window re-arms once it drops back below the warning band.
    func handleThresholds(
        snapshot: UsageSnapshot,
        profile: AccountProfile,
        includeSessionWindows: Bool = false,
        advisedTargetID: UUID? = nil
    ) {
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }

        guard snapshot.parseConfidence != .none else {
            return
        }

        rearmRecoveredWindows(snapshot: snapshot, profile: profile)

        let alerts = ThresholdAlertPlanner(includeSessionWindows: includeSessionWindows).alerts(
            snapshot: snapshot,
            profile: profile,
            lastNotified: lastNotifiedRisk
        )
        for alert in alerts {
            lastNotifiedRisk[AlertWindowKey(profileID: alert.profileID, windowID: alert.windowID)] = alert.riskLevel
            postNotification(
                identifier: "usage-\(alert.profileID.uuidString)-\(alert.windowID)-\(alert.riskLevel.rawValue)",
                title: notificationTitle(alert: alert, profile: profile),
                body: notificationBody(alert: alert, snapshot: snapshot, profile: profile),
                categoryIdentifier: NotificationSwitchAction.categoryBest,
                userInfo: switchUserInfo(provider: profile.provider, targetID: advisedTargetID)
            )
        }
    }

    /// Clears dedupe keys for windows that dropped back below the warning
    /// band, without firing anything — used directly for inactive accounts.
    func rearmThresholds(snapshot: UsageSnapshot, profile: AccountProfile) {
        guard snapshot.parseConfidence != .none else {
            return
        }
        rearmRecoveredWindows(snapshot: snapshot, profile: profile)
    }

    private func rearmRecoveredWindows(snapshot: UsageSnapshot, profile: AccountProfile) {
        let currentRisk = thresholdPlanner.currentRisk(snapshot: snapshot, profile: profile)
        for (key, risk) in currentRisk where risk != .warning && risk != .depleted {
            lastNotifiedRisk[key] = nil
        }
    }

    private func notificationTitle(alert: ThresholdAlert, profile: AccountProfile) -> String {
        if alert.riskLevel == .depleted {
            return "\(profile.label): \(alert.windowLabel) limit reached"
        }
        return "\(profile.label): \(alert.windowLabel) \(Int(alert.usedPercent.rounded()))% used"
    }

    private func notificationBody(alert: ThresholdAlert, snapshot: UsageSnapshot, profile: AccountProfile) -> String {
        var parts = [
            "\(profile.provider.displayName) \(alert.windowLabel) usage is \(alert.riskLevel == .depleted ? "depleted" : "near the limit")."
        ]
        if let reset = alert.resetDescription ?? snapshot.resetDescription {
            parts.append("Resets \(reset).")
        }
        if let credit = snapshot.creditStatus {
            parts.append(credit)
        }
        return parts.joined(separator: " ")
    }
}
