import Foundation

/// Selects a credential that can be injected into the Claude `/usage`
/// subprocess without any Keychain fallback. Live and stored inputs are
/// intentionally independent so a denied live item does not discard a valid
/// app-owned snapshot.
public enum ClaudeUsageProbeCredentialSelector {
    public static func select(
        live: ClaudeOAuthCredentials?,
        stored: ClaudeOAuthCredentials?,
        now: Date = Date()
    ) -> ClaudeOAuthCredentials? {
        [live, stored]
            .compactMap { $0 }
            .filter { isValid($0, now: now) }
            .max { lhs, rhs in
                let lhsLogin = lhs.refreshTokenExpiresAt ?? .distantPast
                let rhsLogin = rhs.refreshTokenExpiresAt ?? .distantPast
                if lhsLogin != rhsLogin { return lhsLogin < rhsLogin }
                return (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
            }
    }

    public static func isValid(
        _ credentials: ClaudeOAuthCredentials,
        now: Date = Date()
    ) -> Bool {
        // Missing access expiry is malformed for process-launch purposes: the
        // app cannot prove that the injected token is current.
        credentials.expiresAt != nil
            && !credentials.isExpired(asOf: now)
            && !credentials.isLoginExpired(asOf: now)
            && ClaudeCodeUsageLaunchGate.isValid(credentials.accessToken)
    }
}
