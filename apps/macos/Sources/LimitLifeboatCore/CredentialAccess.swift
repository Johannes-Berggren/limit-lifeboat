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

/// A stable, UI-facing classification of credential access failures. Keeping
/// this separate from raw Security.framework status codes lets callers avoid
/// treating a cancellation like an authorization failure that should be
/// retried, while preserving the status on genuinely unknown failures.
public enum CredentialAccessDisposition: Equatable, Sendable {
    case interactionRequired
    case userCancelled
    case codeSignatureInvalid
    case unavailable
    case other(OSStatus)

    public init(status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed:
            self = .interactionRequired
        case errSecUserCanceled:
            self = .userCancelled
        case let status where CredentialStoreError.isCodeSigningStatus(status):
            self = .codeSignatureInvalid
        case errSecNotAvailable, errSecNoSuchKeychain, errSecInvalidKeychain, errSecNoDefaultKeychain:
            self = .unavailable
        default:
            self = .other(status)
        }
    }

    public init(underlying error: Error) {
        if error is RunningExecutableIntegrityError {
            self = .codeSignatureInvalid
            return
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            self.init(status: OSStatus(nsError.code))
        } else {
            self = .unavailable
        }
    }

    public var isAccessDenied: Bool {
        switch self {
        case .interactionRequired, .userCancelled, .codeSignatureInvalid:
            return true
        case .unavailable, .other:
            return false
        }
    }
}

/// Privacy-safe operation totals for one credential workflow. These counters
/// contain no item identifiers or secret material and are suitable for unified
/// logging and regression assertions.
public struct CredentialKeychainIOCounts: Equatable, Sendable {
    public var metadataReads: Int
    public var dataReads: Int
    public var writes: Int

    public init(metadataReads: Int = 0, dataReads: Int = 0, writes: Int = 0) {
        self.metadataReads = metadataReads
        self.dataReads = dataReads
        self.writes = writes
    }
}

public final class CredentialKeychainIOCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = CredentialKeychainIOCounts()

    public init() {}

    public var snapshot: CredentialKeychainIOCounts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    fileprivate func recordMetadataRead() {
        lock.lock()
        counts.metadataReads += 1
        lock.unlock()
    }

    fileprivate func recordDataRead() {
        lock.lock()
        counts.dataReads += 1
        lock.unlock()
    }

    fileprivate func recordWrite() {
        lock.lock()
        counts.writes += 1
        lock.unlock()
    }
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

    /// Drops any authentication cached by this workflow. Authorization flows
    /// must do this before their fresh noninteractive verification so a
    /// one-time Keychain "Allow" cannot be mistaken for a durable ACL grant.
    public func invalidate() {
        authenticationContext.invalidate()
    }
}

/// Task-scoped credential interaction policy. Keychain primitives consume the
/// current session automatically, while AppState explicitly opens a
/// user-initiated scope only around actions such as Retry or Switch.
public enum CredentialAccess {
    @TaskLocal public static var currentSession: CredentialAccessSession?
    @TaskLocal static var currentIOCounter: CredentialKeychainIOCounter?

    public static var currentMode: CredentialAccessMode {
        currentSession?.mode ?? .nonInteractive
    }

    public static func userInitiated<T>(
        reason: String = "access saved CLI account credentials",
        operation: () throws -> T
    ) rethrows -> T {
        let session = CredentialAccessSession(mode: .userInitiated, reason: reason)
        defer { session.invalidate() }
        return try $currentSession.withValue(
            session,
            operation: operation
        )
    }

    public static func userInitiated<T>(
        reason: String = "access saved CLI account credentials",
        operation: () async throws -> T
    ) async rethrows -> T {
        let session = CredentialAccessSession(mode: .userInitiated, reason: reason)
        defer { session.invalidate() }
        return try await $currentSession.withValue(
            session,
            operation: operation
        )
    }

    public static func nonInteractive<T>(operation: () async throws -> T) async rethrows -> T {
        try await $currentSession.withValue(
            CredentialAccessSession(mode: .nonInteractive),
            operation: operation
        )
    }

    public static func counting<T>(
        _ counter: CredentialKeychainIOCounter,
        operation: () throws -> T
    ) rethrows -> T {
        try $currentIOCounter.withValue(counter, operation: operation)
    }

    public static func counting<T>(
        _ counter: CredentialKeychainIOCounter,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentIOCounter.withValue(counter, operation: operation)
    }

    /// Installs one outermost counter for a complete credential workflow.
    /// Nested phases receive the same counter with `ownsScope == false`, so
    /// they contribute to their owner's totals without emitting duplicate or
    /// misleading partial log lines.
    public static func withWorkflowCounter<T>(
        operation: (CredentialKeychainIOCounter, Bool) throws -> T
    ) rethrows -> T {
        if let currentIOCounter {
            return try operation(currentIOCounter, false)
        }
        let counter = CredentialKeychainIOCounter()
        return try $currentIOCounter.withValue(counter) {
            try operation(counter, true)
        }
    }

    public static func withWorkflowCounter<T>(
        operation: (CredentialKeychainIOCounter, Bool) async throws -> T
    ) async rethrows -> T {
        if let currentIOCounter {
            return try await operation(currentIOCounter, false)
        }
        let counter = CredentialKeychainIOCounter()
        return try await $currentIOCounter.withValue(counter) {
            try await operation(counter, true)
        }
    }

    /// Starts an independently scheduled workflow without inheriting an
    /// already-finished parent's accounting scope. Credential access mode is
    /// intentionally untouched; callers still choose noninteractive or the
    /// one explicit user-initiated scope separately.
    public static func independentWorkflow<T>(
        operation: () throws -> T
    ) rethrows -> T {
        try $currentIOCounter.withValue(nil, operation: operation)
    }

    public static func independentWorkflow<T>(
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $currentIOCounter.withValue(nil, operation: operation)
    }

    static func recordKeychainMetadataRead() {
        currentIOCounter?.recordMetadataRead()
    }

    static func recordKeychainDataRead() {
        currentIOCounter?.recordDataRead()
    }

    static func recordKeychainWrite() {
        currentIOCounter?.recordWrite()
    }

    static func authenticationContext(for mode: CredentialAccessMode) -> LAContext {
        if let currentSession, currentSession.mode == mode {
            return currentSession.authenticationContext
        }
        return CredentialAccessSession(mode: mode).authenticationContext
    }
}
