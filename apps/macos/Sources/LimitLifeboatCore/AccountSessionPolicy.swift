import Foundation

/// Identifies the credential owner an explicit authorization action should
/// unlock. The row already identifies the profile, so `.savedAccount` does not
/// carry an id; `.claudeCode` refers to the provider-owned live CLI item.
public enum CredentialAuthorizationSource: Equatable, Sendable {
    case claudeCode
    case savedAccount
}

/// What the app currently knows about the profile's durable credential copy.
/// Access failures stay distinct from absence so cached expiry metadata never
/// turns an unreadable Keychain item into a misleading "expired" diagnosis.
public enum StoredCredentialAvailability: Equatable, Sendable {
    case available
    case missing
    case authorizationRequired(source: CredentialAuthorizationSource)
    case accessBlocked(
        source: CredentialAuthorizationSource,
        disposition: CredentialAccessDisposition,
        reason: String
    )
}

/// Whether one switch source is allowed to select an account now.
public enum AccountSwitchEligibility: Equatable, Sendable {
    case eligible
    case blocked(reason: String)

    public var isEligible: Bool {
        if case .eligible = self {
            return true
        }
        return false
    }

    public var blockerReason: String? {
        if case .blocked(let reason) = self {
            return reason
        }
        return nil
    }
}

/// A single policy result consumed by row presentation, switch menus, the
/// advisor, notification re-resolution, and final switch preflight.
public struct AccountSessionEvaluation: Equatable, Sendable {
    public var manualSwitchEligibility: AccountSwitchEligibility
    public var automaticSwitchEligibility: AccountSwitchEligibility
    /// Ordered, actionable status rows. The policy deliberately caps this at
    /// two so a renewal warning can coexist with one compatible repair action
    /// without turning an account card into an error log.
    public var rowMessages: [AccountRowMessage]

    public init(
        manualSwitchEligibility: AccountSwitchEligibility,
        automaticSwitchEligibility: AccountSwitchEligibility,
        rowMessages: [AccountRowMessage]
    ) {
        self.manualSwitchEligibility = manualSwitchEligibility
        self.automaticSwitchEligibility = automaticSwitchEligibility
        self.rowMessages = Array(rowMessages.prefix(2))
    }
}

/// Pure session policy. Callers supply observed credential state and a clock;
/// this type never reads Keychain data or mutates a login.
public enum AccountSessionPolicy {
    public static let loginExpiryWarningInterval: TimeInterval = 5 * 24 * 60 * 60

    public static func evaluate(
        provider: Provider,
        isActiveCLI: Bool,
        wasPreviouslyLinked: Bool,
        storedCredentials: StoredCredentialAvailability,
        sharesActiveCredentialChain: Bool = false,
        refreshState: AccountRefreshState,
        loginExpiresAt: Date?,
        now: Date = Date()
    ) -> AccountSessionEvaluation {
        let accessMessage = accessMessage(
            storedCredentials: storedCredentials,
            refreshState: refreshState
        )
        let accessBlocker = accessBlocker(
            storedCredentials: storedCredentials,
            refreshState: refreshState
        )

        // Access state outranks cached expiry: until the credential is readable
        // we cannot safely claim it is expired or switchable.
        if let accessBlocker {
            let blocked = AccountSwitchEligibility.blocked(reason: accessBlocker)
            return AccountSessionEvaluation(
                manualSwitchEligibility: blocked,
                automaticSwitchEligibility: blocked,
                rowMessages: accessMessage.map { [$0] } ?? []
            )
        }

        let effectiveExpiry = provider == .claude ? loginExpiresAt : nil
        let loginIsExpired = effectiveExpiry.map { now >= $0 } == true
        if loginIsExpired {
            let reason = "Log in to this account again before switching the CLI to it."
            return AccountSessionEvaluation(
                manualSwitchEligibility: .blocked(reason: reason),
                automaticSwitchEligibility: .blocked(reason: reason),
                rowMessages: [expiredLoginMessage()]
            )
        }

        if case .needsLogin(let reason) = refreshState {
            let blocker = "Log in to this account again before switching the CLI to it."
            return AccountSessionEvaluation(
                manualSwitchEligibility: .blocked(reason: blocker),
                automaticSwitchEligibility: .blocked(reason: blocker),
                rowMessages: [loginMessage(wasPreviouslyLinked: wasPreviouslyLinked, reason: reason)]
            )
        }

        if case .missing = storedCredentials {
            let blocker = "Log in to this account before switching the CLI to it."
            return AccountSessionEvaluation(
                manualSwitchEligibility: .blocked(reason: blocker),
                automaticSwitchEligibility: .blocked(reason: blocker),
                rowMessages: [
                    loginMessage(
                        wasPreviouslyLinked: wasPreviouslyLinked,
                        reason: "No captured OAuth credentials are available for this account."
                    )
                ]
            )
        }

        let manualEligibility = switchEligibility(for: refreshState, automatic: false)
        let automaticEligibility = switchEligibility(for: refreshState, automatic: true)

        var messages: [AccountRowMessage] = []
        let requiresSwitchForRenewal = refreshState.requiresSwitchBeforeRefresh
            || (provider == .claude && !isActiveCLI && sharesActiveCredentialChain)
        if let effectiveExpiry,
           effectiveExpiry <= now.addingTimeInterval(loginExpiryWarningInterval) {
            messages.append(
                expiringLoginMessage(
                    expiresAt: effectiveExpiry,
                    now: now,
                    requiresSwitch: requiresSwitchForRenewal,
                    renewalActivatesAccount: isActiveCLI
                )
            )
        }

        if var refreshMessage = refreshMessage(for: refreshState) {
            // Renewal must never run as a non-activating login for a profile
            // that still shares the live single-use chain. A 403 is still a
            // valid credential, but the CLI must own it before renewal.
            if requiresSwitchForRenewal, refreshMessage.action == .renew {
                refreshMessage.action = .switchCLI
                refreshMessage.help += " Switch the CLI to this profile before renewing its login."
            }

            // `.switchRequired` and the shared-chain expiry warning express the
            // same instruction. Other compatible diagnostics (Retry/repair or
            // forbidden guidance) remain visible as the ordered second row.
            let duplicatesRequiredSwitch: Bool
            if case .switchRequired = refreshState {
                duplicatesRequiredSwitch = refreshMessage.action == .switchCLI
                    && messages.contains(where: { $0.action == .switchCLI })
            } else {
                duplicatesRequiredSwitch = false
            }
            if !duplicatesRequiredSwitch {
                if refreshMessage.action == .renew,
                   messages.contains(where: { $0.action == .renew }) {
                    refreshMessage.action = .none
                }
                if refreshMessage.action == .switchCLI,
                   messages.contains(where: { $0.action == .switchCLI }) {
                    refreshMessage.action = .none
                }
                messages.append(refreshMessage)
            }
        }

        return AccountSessionEvaluation(
            manualSwitchEligibility: manualEligibility,
            automaticSwitchEligibility: automaticEligibility,
            rowMessages: messages
        )
    }

    private static func switchEligibility(
        for state: AccountRefreshState,
        automatic: Bool
    ) -> AccountSwitchEligibility {
        switch state {
        case .idle, .ok, .readFailed:
            return .eligible
        case .providerAccessForbidden:
            return automatic
                ? .blocked(reason: "Usage access must be restored before automatic switching.")
                : .eligible
        case .refreshing:
            return .blocked(reason: "Wait for the current refresh to finish before switching.")
        case .rotationDeferred, .usagePaused:
            return automatic
                ? .blocked(reason: "This login requires a deliberate credential refresh before switching.")
                : .eligible
        case .switchRequired:
            return automatic
                ? .blocked(reason: "This shared login requires a user-initiated switch.")
                : .eligible
        case .credentialRepairRequired:
            return .blocked(reason: "Repair this saved login before switching.")
        case .authorizationRequired, .keychainLocked:
            return .blocked(reason: "Authorize credential access before switching.")
        case .credentialAccessBlocked:
            return .blocked(reason: "Credential access is blocked; relaunch or repair the app before switching.")
        case .needsLogin:
            return .blocked(reason: "Log in to this account again before switching.")
        }
    }

    private static func accessBlocker(
        storedCredentials: StoredCredentialAvailability,
        refreshState: AccountRefreshState
    ) -> String? {
        switch storedCredentials {
        case .authorizationRequired:
            return "Authorize credential access before switching."
        case .accessBlocked(_, _, let reason):
            return reason.isEmpty
                ? "Credential access is blocked; relaunch or repair the app before switching."
                : reason
        case .available, .missing:
            break
        }

        switch refreshState {
        case .authorizationRequired:
            return "Authorize credential access before switching."
        case .credentialAccessBlocked(_, _, let reason):
            return reason.isEmpty
                ? "Credential access is blocked; relaunch or repair the app before switching."
                : reason
        case .keychainLocked:
            return "Authorize credential access before switching."
        default:
            return nil
        }
    }

    private static func accessMessage(
        storedCredentials: StoredCredentialAvailability,
        refreshState: AccountRefreshState
    ) -> AccountRowMessage? {
        switch storedCredentials {
        case .authorizationRequired(let source):
            return authorizationMessage(source: source, reason: nil)
        case .accessBlocked(let source, let disposition, let reason):
            return blockedAccessMessage(source: source, disposition: disposition, reason: reason)
        case .available, .missing:
            break
        }

        switch refreshState {
        case .authorizationRequired(let source, let reason):
            return authorizationMessage(source: source, reason: reason)
        case .credentialAccessBlocked(let source, let disposition, let reason):
            return blockedAccessMessage(source: source, disposition: disposition, reason: reason)
        case .keychainLocked:
            return authorizationMessage(
                source: .claudeCode,
                reason: "macOS denied access to this account's saved credentials."
            )
        default:
            return nil
        }
    }

    private static func authorizationMessage(
        source: CredentialAuthorizationSource,
        reason: String?
    ) -> AccountRowMessage {
        let owner = source == .claudeCode ? "Claude Code" : "saved login"
        return AccountRowMessage(
            text: "Keychain access needed",
            icon: "lock",
            tone: .stale,
            help: reason ?? ("Authorize access to the " + owner + " credentials to continue."),
            action: .authorize(source: source)
        )
    }

    private static func blockedAccessMessage(
        source: CredentialAuthorizationSource,
        disposition: CredentialAccessDisposition,
        reason: String
    ) -> AccountRowMessage {
        let fallback: String
        switch disposition {
        case .codeSignatureInvalid:
            fallback = "The running app no longer matches the copy authorized by macOS. Relaunch the installed app and try again."
        case .unavailable:
            fallback = "The macOS Keychain is unavailable. Unlock it or relaunch the app and try again."
        case .interactionRequired, .userCancelled:
            fallback = "Authorize credential access and try again."
        case .other:
            fallback = "Credential access is blocked. Relaunch the app and try again."
        }
        let action: AccountRowAction = (disposition == .interactionRequired || disposition == .userCancelled)
            ? .authorize(source: source)
            : .none
        return AccountRowMessage(
            text: "Credential access blocked",
            icon: "lock.trianglebadge.exclamationmark",
            tone: .stale,
            help: reason.isEmpty ? fallback : reason,
            action: action
        )
    }

    private static func expiredLoginMessage() -> AccountRowMessage {
        AccountRowMessage(
            text: "Login expired — sign in again",
            icon: "person.crop.circle.badge.questionmark",
            tone: .warning,
            help: "This Claude login expired on this Mac. Other Macs keep their own device-local logins.",
            action: .login
        )
    }

    private static func loginMessage(wasPreviouslyLinked: Bool, reason: String) -> AccountRowMessage {
        AccountRowMessage(
            text: wasPreviouslyLinked
                ? "Login expired — sign in again"
                : "Not linked — log in to track usage",
            icon: "person.crop.circle.badge.questionmark",
            tone: wasPreviouslyLinked ? .warning : .secondary,
            help: reason,
            action: .login
        )
    }

    private static func expiringLoginMessage(
        expiresAt: Date,
        now: Date,
        requiresSwitch: Bool,
        renewalActivatesAccount: Bool
    ) -> AccountRowMessage {
        let remaining = expiresAt.timeIntervalSince(now)
        let text: String
        if remaining < 24 * 60 * 60 {
            text = "Login expires today"
        } else {
            let days = Int(ceil(remaining / (24 * 60 * 60)))
            text = "Login expires in \(days) days"
        }

        let help: String
        let action: AccountRowAction
        if requiresSwitch {
            help = "This profile shares the active Claude login. Switch the CLI to it to renew safely before it expires."
            action = .switchCLI
        } else {
            help = renewalActivatesAccount
                ? "Renew this Claude login before it expires. Renewal affects this Mac only."
                : "Renew this Claude login without changing the active CLI account. Renewal affects this Mac only."
            action = .renew
        }
        return AccountRowMessage(
            text: text,
            icon: "clock.badge.exclamationmark",
            tone: .warning,
            help: help,
            action: action
        )
    }

    private static func refreshMessage(for state: AccountRefreshState) -> AccountRowMessage? {
        switch state {
        case .idle, .refreshing, .ok, .needsLogin, .authorizationRequired,
             .credentialAccessBlocked, .keychainLocked:
            return nil
        case .readFailed(let reason):
            return AccountRowMessage(
                text: "Couldn't refresh",
                icon: "exclamationmark.triangle",
                tone: .warning,
                help: reason,
                action: .retry
            )
        case .providerAccessForbidden(let reason):
            return AccountRowMessage(
                text: "Usage access denied",
                icon: "exclamationmark.shield",
                tone: .warning,
                help: reason,
                action: .renew
            )
        case .rotationDeferred(let reason):
            return AccountRowMessage(
                text: "Usage paused — click to refresh",
                icon: "pause.circle",
                tone: .secondary,
                help: reason,
                action: .retry
            )
        case .usagePaused:
            return AccountRowMessage(
                text: "Usage paused — click to refresh",
                icon: "pause.circle",
                tone: .secondary,
                help: "Limit Lifeboat paused auto-refresh so it won't disturb your Claude login. Click Retry to update usage now.",
                action: .retry
            )
        case .switchRequired(let reason):
            return AccountRowMessage(
                text: "Switch to refresh usage",
                icon: "arrow.triangle.2.circlepath",
                tone: .secondary,
                help: reason,
                action: .switchCLI
            )
        case .credentialRepairRequired(let reason):
            return AccountRowMessage(
                text: "Saved login needs repair",
                icon: "wrench.and.screwdriver",
                tone: .warning,
                help: reason,
                action: .retry
            )
        }
    }
}

private extension AccountRefreshState {
    var requiresSwitchBeforeRefresh: Bool {
        if case .switchRequired = self {
            return true
        }
        return false
    }
}
