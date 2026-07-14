import Foundation
import LocalAuthentication
import Security

/// Whether a credential operation may ask the user to authenticate. The
/// default is intentionally non-interactive: background refreshes, polling,
/// and SwiftUI rendering must never summon a Keychain password dialog.
public enum CredentialAccessMode: Equatable, Sendable {
    case nonInteractive
    case userInitiated
}

/// One reusable LocalAuthentication context for a credential workflow. Reuse
/// matters for user actions that touch the live CLI item and a stored account
/// snapshot in the same transaction: an authentication satisfied for the
/// first operation can be reused by the following operations.
public final class CredentialAccessSession: @unchecked Sendable {
    public let mode: CredentialAccessMode
    let authenticationContext: LAContext

    public init(
        mode: CredentialAccessMode,
        reason: String = "access saved CLI account credentials"
    ) {
        self.mode = mode
        let context = LAContext()
        switch mode {
        case .nonInteractive:
            context.interactionNotAllowed = true
        case .userInitiated:
            context.localizedReason = reason
        }
        self.authenticationContext = context
    }
}

/// Task-scoped credential interaction policy. Keychain primitives consume the
/// current session automatically, while AppState explicitly opens a
/// user-initiated scope only around actions such as Retry or Switch.
public enum CredentialAccess {
    @TaskLocal public static var currentSession: CredentialAccessSession?

    public static var currentMode: CredentialAccessMode {
        currentSession?.mode ?? .nonInteractive
    }

    public static func userInitiated<T>(
        reason: String = "access saved CLI account credentials",
        operation: () throws -> T
    ) rethrows -> T {
        try $currentSession.withValue(
            CredentialAccessSession(mode: .userInitiated, reason: reason),
            operation: operation
        )
    }

    public static func userInitiated<T>(
        reason: String = "access saved CLI account credentials",
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentSession.withValue(
            CredentialAccessSession(mode: .userInitiated, reason: reason),
            operation: operation
        )
    }

    public static func nonInteractive<T>(operation: () async throws -> T) async rethrows -> T {
        try await $currentSession.withValue(
            CredentialAccessSession(mode: .nonInteractive),
            operation: operation
        )
    }

    static func authenticationContext(for mode: CredentialAccessMode) -> LAContext {
        if let currentSession, currentSession.mode == mode {
            return currentSession.authenticationContext
        }
        return CredentialAccessSession(mode: mode).authenticationContext
    }
}
