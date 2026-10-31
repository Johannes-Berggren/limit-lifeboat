import Foundation
import LimitLifeboatCore

/// Presentation state only: credential authority stays in the existing login
/// watcher and switch transaction. Progress survives popover closes and refresh
/// footer messages, and a cached pre-login reading cannot complete it.
package struct AccountConnectionProgress: Equatable {
    package enum Stage: Equatable {
        case starting, waiting, verifying, loadingUsage, connected
        case authorizationRequired(CredentialAuthorizationSource)
        case usageUnavailable, failed, timedOut

        package var isBusy: Bool {
            switch self {
            case .starting, .waiting, .verifying, .loadingUsage: return true
            default: return false
            }
        }
    }

    package var profileID: UUID
    package let activateAfterLogin: Bool
    package var stage: Stage = .starting
    package var detail: String
    package var usageRequestedAt: Date?
    private var linkedDetail: String?

    package init(profileID: UUID, detail: String, activateAfterLogin: Bool = true) {
        self.profileID = profileID
        self.detail = detail
        self.activateAfterLogin = activateAfterLogin
    }

    package mutating func linked(profile: AccountProfile, detail: String, now: Date = Date()) {
        profileID = profile.id
        stage = .loadingUsage
        linkedDetail = detail
        self.detail = "\(detail) Loading usage…"
        usageRequestedAt = now
    }

    package mutating func receivedUsage(_ snapshot: UsageSnapshot) {
        guard stage == .loadingUsage || stage == .usageUnavailable,
              snapshot.accountID == profileID,
              let usageRequestedAt,
              snapshot.lastRefreshed >= usageRequestedAt,
              !snapshot.orderedDisplayWindows.isEmpty || snapshot.payAsYouGoSpend != nil else { return }
        stage = .connected
        detail = "\(linkedDetail ?? "Account verified.") Usage loaded."
    }

    package mutating func usageUnavailable(reason: String) {
        guard stage == .loadingUsage else { return }
        stage = .usageUnavailable
        detail = "\(linkedDetail ?? "The account was saved.") \(reason) Retry usage from the account card."
    }
}

package struct AccountSwitchReceipt: Equatable, Identifiable {
    package enum LoginVerification: Equatable {
        case verified, differentLogin, unavailable
    }

    package enum ServerStatus: Equatable {
        case restartNeeded, unknown, previousServerStopped, notRunning
    }

    package let id = UUID()
    package let profileID: UUID
    package let label: String
    package let provider: Provider
    package let originalDaemons: CodexDaemonState
    package var currentDaemons: CodexDaemonState
    package var loginVerification: LoginVerification = .verified
    package var hasPlaintextOverride: Bool
    package var recheckMessage: String?

    package init(profile: AccountProfile, daemons: CodexDaemonState, hasPlaintextOverride: Bool) {
        profileID = profile.id
        label = profile.label
        provider = profile.provider
        originalDaemons = daemons
        currentDaemons = daemons
        self.hasPlaintextOverride = hasPlaintextOverride
    }

    package var serverStatus: ServerStatus {
        guard provider == .codex else { return .notRunning }
        switch currentDaemons {
        case .unavailable: return .unknown
        case .notRunning:
            return originalDaemons == .notRunning ? .notRunning : .previousServerStopped
        case .running(let current):
            guard case .running(let original) = originalDaemons else { return .unknown }
            return original.isDisjoint(with: current) ? .previousServerStopped : .restartNeeded
        }
    }

    package var needsAttention: Bool {
        loginVerification != .verified || hasPlaintextOverride
            || serverStatus == .restartNeeded || serverStatus == .unknown
    }
}
