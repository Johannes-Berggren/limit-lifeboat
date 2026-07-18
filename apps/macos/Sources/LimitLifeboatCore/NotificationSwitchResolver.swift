import Foundation

/// What clicking a notification's switch action should do, resolved against
/// the CURRENT state rather than the state at post time.
public enum NotificationSwitchResolution: Equatable, Sendable {
    case switchTo(profileID: UUID, label: String)
    /// The intent is already satisfied — e.g. auto-switch or the user beat the
    /// click to it.
    case alreadyActive(label: String)
    case noEligibleTarget(reason: String)
}

/// Resolves a clicked switch-notification action. A notification can sit in
/// Notification Center for hours, during which auto-switch may have fired,
/// the embedded target may have depleted or lost its credentials, and the
/// advisor may prefer a different account — so the embedded target is only a
/// fallback and the click re-resolves against live advice. Pure logic so the
/// staleness policy is unit-testable.
public struct NotificationSwitchResolver: Sendable {
    public init() {}

    public func resolve(
        embeddedTargetID: UUID?,
        advice: SwitchAdvice?,
        candidates: [SwitchCandidate]
    ) -> NotificationSwitchResolution {
        func candidate(for id: UUID?) -> SwitchCandidate? {
            guard let id else {
                return nil
            }
            return candidates.first { $0.profileID == id }
        }

        // The embedded target being active means the switch already happened;
        // switching again to the advisor's next-best would ping-pong.
        if let embedded = candidate(for: embeddedTargetID), embedded.isActiveCLI {
            return .alreadyActive(label: embedded.label)
        }

        // Live advice wins over the post-time target: it reflects resets and
        // depletions that happened while the notification sat unclicked.
        if let advised = candidate(for: advice?.bestCandidateID),
           !advised.isActiveCLI,
           advised.hasStoredCredentials {
            return .switchTo(profileID: advised.profileID, label: advised.label)
        }

        if let embedded = candidate(for: embeddedTargetID), embedded.hasStoredCredentials {
            return .switchTo(profileID: embedded.profileID, label: embedded.label)
        }

        return .noEligibleTarget(reason: "No saved account is ready to switch to.")
    }
}
