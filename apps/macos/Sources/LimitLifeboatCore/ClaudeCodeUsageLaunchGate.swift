import Foundation

public enum ClaudeCodeUsageLaunchGateError: Error, LocalizedError, Equatable {
    case invalidOAuthToken

    public var errorDescription: String? {
        switch self {
        case .invalidOAuthToken:
            return "Claude Code /usage requires a valid, unexpired OAuth token."
        }
    }
}

/// Prevents a `/usage` subprocess from falling back to Claude Code's own
/// Keychain lookup. The launch closure is invoked only after the caller has
/// supplied a nonempty token that is safe to place in the child environment.
public enum ClaudeCodeUsageLaunchGate {
    public static func run<Output: Sendable>(
        oauthToken: String,
        launch: @Sendable (String) async throws -> Output
    ) async throws -> Output {
        guard isValid(oauthToken) else {
            throw ClaudeCodeUsageLaunchGateError.invalidOAuthToken
        }
        return try await launch(oauthToken)
    }

    public static func isValid(_ oauthToken: String) -> Bool {
        !oauthToken.isEmpty
            && oauthToken.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }
    }
}
