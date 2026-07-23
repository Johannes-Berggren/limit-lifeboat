import Foundation
import Security

public enum ClaudeCodeCredentialsKeychainError: Error, LocalizedError {
    case credentialAccessUnavailable(underlying: Error)
    case missingLiveItem
    case duplicateLiveItems([ClaudeKeychainItemLocation])
    case malformedItemMetadata(String)
    case malformedCredentialJSON(String)
    case itemIdentityMismatch
    case unsupportedSecurityToolAccess(String)
    case securityToolError(ClaudeSecurityToolCredentialError)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .credentialAccessUnavailable(let underlying):
            return underlying.localizedDescription
        case .missingLiveItem:
            return "Claude Code is not logged in. Run `claude /login` before switching accounts."
        case .duplicateLiveItems(let items):
            let keychains = items.map(\.keychainPath).sorted().joined(separator: ", ")
            return "Found \(items.count) matching Claude Code credential items in the Keychain search list"
                + (keychains.isEmpty ? "." : ": \(keychains).")
                + " Remove the duplicate before switching accounts."
        case .malformedItemMetadata(let detail):
            return "Could not safely identify the Claude Code credential item (\(detail)). No changes were made."
        case .malformedCredentialJSON(let detail):
            return "The Claude Code credential item contains malformed JSON (\(detail)). No changes were made. Recreate the Claude login explicitly."
        case .itemIdentityMismatch:
            return "The selected Keychain item does not belong to this Claude Code credential source. No changes were made."
        case .unsupportedSecurityToolAccess(let detail):
            return "Claude Code's standard macOS Keychain backend is unavailable (\(detail)). No changes were made."
        case .securityToolError(let error):
            return error.localizedDescription
        case .keychainError(let status):
            if CredentialStoreError.isCodeSigningStatus(status) {
                return CredentialStoreError.keychainError(status).localizedDescription
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
            return "Could not access Claude Code credentials (Keychain status \(status): \(detail))."
        }
    }

    public var isKeychainAccessDenied: Bool {
        credentialAccessDisposition?.isAccessDenied ?? false
    }

    public var credentialAccessDisposition: CredentialAccessDisposition? {
        switch self {
        case .credentialAccessUnavailable(let underlying):
            return CredentialAccessDisposition(underlying: underlying)
        case .keychainError(let status):
            return CredentialAccessDisposition(status: status)
        case .securityToolError(let error):
            switch error {
            case .authorizationDenied, .keychainLocked:
                return .interactionRequired
            case .userCancelled:
                return .userCancelled
            case .malformedToolOutput, .verificationFailed,
                 .toolTimedOut, .toolFailed:
                return .unavailable
            case .itemChanged, .invalidArgument, .payloadTooLarge:
                return nil
            }
        case .missingLiveItem, .duplicateLiveItems, .malformedItemMetadata,
             .malformedCredentialJSON, .itemIdentityMismatch,
             .unsupportedSecurityToolAccess:
            return nil
        }
    }
}

/// Where the live Claude Code CLI credentials come from and go back to.
/// Abstracted so tests (and the switcher's snapshot store) can substitute an
/// in-memory source.
public protocol ClaudeCLICredentialSource: Sendable {
    /// Production legacy-Keychain sources can pin an entire workflow to one
    /// persistent item identity. Lightweight test/provider sources may use
    /// the compatibility defaults instead.
    var supportsExactItemLocations: Bool { get }

    /// Metadata-only discovery across the user's Keychain search list. A nil
    /// result means Claude is logged out; multiple matches must be rejected.
    func locateLiveItem(accessMode: CredentialAccessMode) throws -> ClaudeKeychainItemLocation?

    /// The full keychain item JSON, or nil when no item exists (logged out).
    func readLiveItemJSON(accessMode: CredentialAccessMode) throws -> Data?
    func writeLiveItemJSON(_ data: Data, accessMode: CredentialAccessMode) throws
    func deleteLiveItem(accessMode: CredentialAccessMode) throws

    /// Exact-item variants used by login polling and authorization workflows.
    func readLiveItemJSON(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data?
    func writeLiveItemJSON(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws
    func deleteLiveItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws
}

/// Internal transaction receipt for the exact boundary where the security
/// helper may begin mutating Claude's provider-owned item.
final class ClaudeCredentialWriteAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var succeeded = false

    var helperStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var helperSucceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }

    func markHelperStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func markHelperSucceeded() {
        lock.lock()
        started = true
        succeeded = true
        lock.unlock()
    }
}

/// Production sources report the helper boundary so a transaction can avoid
/// both inventing a mutation before launch and stale rollback after launch.
protocol ClaudeCredentialWriteReporting: Sendable {
    func writeLiveItemJSON(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        mutationAttempt: ClaudeCredentialWriteAttempt
    ) throws
}

public extension ClaudeCLICredentialSource {
    var supportsExactItemLocations: Bool { false }

    /// Compatibility default for in-memory and provider-specific test doubles.
    /// Production Claude Keychain access overrides this with exact discovery.
    func locateLiveItem(accessMode: CredentialAccessMode) throws -> ClaudeKeychainItemLocation? {
        nil
    }

    func readLiveItemJSON() throws -> Data? {
        try readLiveItemJSON(accessMode: CredentialAccess.currentMode)
    }

    func writeLiveItemJSON(_ data: Data) throws {
        try writeLiveItemJSON(data, accessMode: CredentialAccess.currentMode)
    }

    func deleteLiveItem() throws {
        try deleteLiveItem(accessMode: CredentialAccess.currentMode)
    }

    func readLiveItemJSON(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        try readLiveItemJSON(accessMode: accessMode)
    }

    func writeLiveItemJSON(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        try writeLiveItemJSON(data, accessMode: accessMode)
    }

    func deleteLiveItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        try deleteLiveItem(accessMode: accessMode)
    }
}

/// Discovers the exact provider-owned "Claude Code-credentials" item through
/// Security.framework, then reads and updates its data through Claude Code's
/// own `/usr/bin/security` backend. Matching Claude's storage identity keeps
/// Conductor, Terminal, IDE integrations, and Limit Lifeboat compatible
/// without rewriting partition ACLs or handling the login-keychain password.
public struct ClaudeCodeCredentialsKeychain:
    ClaudeCLICredentialSource,
    ClaudeCredentialWriteReporting
{
    public static let serviceName = "Claude Code-credentials"

    private let serviceName: String
    private let accountName: String
    private let validateAccess: @Sendable () throws -> Void
    private let securityClient: any ClaudeKeychainSecurityClient
    private let liveCredentialBackend: any ClaudeLiveCredentialBackend

    public var supportsExactItemLocations: Bool { true }

    public init(
        serviceName: String = Self.serviceName,
        accountName: String = NSUserName(),
        validateAccess: @escaping @Sendable () throws -> Void = {}
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.validateAccess = validateAccess
        self.securityClient = SystemClaudeKeychainSecurityClient()
        self.liveCredentialBackend = ClaudeSecurityToolCredentialBackend()
    }

    init(
        serviceName: String = Self.serviceName,
        accountName: String = NSUserName(),
        validateAccess: @escaping @Sendable () throws -> Void = {},
        securityClient: any ClaudeKeychainSecurityClient,
        liveCredentialBackend: any ClaudeLiveCredentialBackend
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.validateAccess = validateAccess
        self.securityClient = securityClient
        self.liveCredentialBackend = liveCredentialBackend
    }

    public func locateLiveItem(
        accessMode: CredentialAccessMode
    ) throws -> ClaudeKeychainItemLocation? {
        try validateCredentialAccess()
        return try locateValidated(accessMode: accessMode)
    }

    public func readLiveItemJSON(accessMode: CredentialAccessMode) throws -> Data? {
        try validateCredentialAccess()
        guard let location = try locateValidated(accessMode: accessMode) else { return nil }
        return try readValidated(at: location, accessMode: accessMode)
    }

    public func readLiveItemJSON(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        try validateCredentialAccess()
        try validate(location: location)
        return try readValidated(at: location, accessMode: accessMode)
    }

    public func writeLiveItemJSON(_ data: Data, accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()
        guard let location = try locateValidated(accessMode: accessMode) else {
            throw ClaudeCodeCredentialsKeychainError.missingLiveItem
        }
        try writeValidated(data, at: location, accessMode: accessMode)
    }

    public func writeLiveItemJSON(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        try validateCredentialAccess()
        try validate(location: location)
        try writeValidated(data, at: location, accessMode: accessMode)
    }

    func writeLiveItemJSON(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        mutationAttempt: ClaudeCredentialWriteAttempt
    ) throws {
        try validateCredentialAccess()
        try validate(location: location)
        try writeValidated(
            data,
            at: location,
            accessMode: accessMode,
            mutationAttempt: mutationAttempt
        )
    }

    public func deleteLiveItem(accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()
        guard try locateValidated(accessMode: accessMode) != nil else { return }
        throw ClaudeCodeCredentialsKeychainError.unsupportedSecurityToolAccess(
            "Limit Lifeboat never deletes Claude's provider-owned credential item"
        )
    }

    public func deleteLiveItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        try validateCredentialAccess()
        try validate(location: location)
        throw ClaudeCodeCredentialsKeychainError.unsupportedSecurityToolAccess(
            "Limit Lifeboat never deletes Claude's provider-owned credential item"
        )
    }

    private func locateValidated(
        accessMode: CredentialAccessMode
    ) throws -> ClaudeKeychainItemLocation? {
        let items = try securityClient.locateItems(
            serviceName: serviceName,
            accountName: accountName,
            accessMode: accessMode
        )
        guard items.count <= 1 else {
            throw ClaudeCodeCredentialsKeychainError.duplicateLiveItems(items)
        }
        return items.first
    }

    private func writeValidated(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode,
        mutationAttempt: ClaudeCredentialWriteAttempt? = nil
    ) throws {
        CredentialAccess.recordKeychainWrite()
        do {
            try liveCredentialBackend.updateData(
                data,
                at: location,
                accessMode: accessMode,
                authorizeAccess: { mode in
                    try authorizeSecurityToolAccess(at: location, accessMode: mode)
                },
                verifyBefore: {
                    // The ACL check (or an explicit authorization prompt) can
                    // outlive a cooperative mutation lease. Revalidate at the
                    // last synchronous boundary before `/usr/bin/security`
                    // starts, while allowing standalone exact-source tests
                    // and read-only callers that have no mutation context.
                    guard try currentLocationMatches(
                        location,
                        requireSameModificationStamp: true
                    ) else {
                        return false
                    }
                    try ClaudeOAuthMutationLeaseContext.current?.validate()
                    return true
                },
                verifyAfter: {
                    guard try currentLocationMatches(
                        location,
                        requireSameModificationStamp: false
                    ) else {
                        return false
                    }
                    return true
                },
                mutationAttempt: mutationAttempt
            )

            guard let freshLocation = try locateValidated(accessMode: .nonInteractive),
                  freshLocation.identity == location.identity,
                  freshLocation.label == location.label else {
                throw ClaudeSecurityToolCredentialError.itemChanged
            }
            try authorizeSecurityToolAccess(
                at: freshLocation,
                accessMode: .nonInteractive
            )
            let verified = try readBackendData(
                at: freshLocation,
                accessMode: .nonInteractive
            )
            guard verified == data else {
                throw ClaudeSecurityToolCredentialError.verificationFailed
            }
        } catch let error as ClaudeSecurityToolCredentialError {
            throw ClaudeCodeCredentialsKeychainError.securityToolError(error)
        }
    }

    private func readValidated(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        do {
            return try readBackendData(at: location, accessMode: accessMode)
        } catch let error as ClaudeSecurityToolCredentialError {
            throw ClaudeCodeCredentialsKeychainError.securityToolError(error)
        }
    }

    private func readBackendData(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data {
        CredentialAccess.recordKeychainDataRead()
        return try liveCredentialBackend.readData(
            at: location,
            accessMode: accessMode,
            authorizeAccess: { mode in
                try authorizeSecurityToolAccess(at: location, accessMode: mode)
            },
            verifyBefore: {
                try currentLocationMatches(
                    location,
                    requireSameModificationStamp: true
                )
            },
            verifyAfter: {
                try currentLocationMatches(
                    location,
                    requireSameModificationStamp: accessMode == .nonInteractive
                )
            }
        )
    }

    private func authorizeSecurityToolAccess(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        switch try securityClient.securityToolAccessStatus(at: location) {
        case .ready:
            return
        case .needsAuthorization:
            guard accessMode == .userInitiated else {
                throw ClaudeSecurityToolCredentialError.authorizationDenied
            }
        case .keychainLocked:
            guard accessMode == .userInitiated else {
                throw ClaudeSecurityToolCredentialError.keychainLocked
            }
        case .unsupported(let detail):
            throw ClaudeCodeCredentialsKeychainError.unsupportedSecurityToolAccess(detail)
        }
    }

    private func currentLocationMatches(
        _ expected: ClaudeKeychainItemLocation,
        requireSameModificationStamp: Bool
    ) throws -> Bool {
        guard let current = try locateValidated(accessMode: .nonInteractive),
              current.identity == expected.identity,
              current.label == expected.label else {
            return false
        }
        return !requireSameModificationStamp
            || current.modificationStamp == expected.modificationStamp
    }

    private func validate(location: ClaudeKeychainItemLocation) throws {
        guard location.serviceName == serviceName,
              location.accountName == accountName else {
            throw ClaudeCodeCredentialsKeychainError.itemIdentityMismatch
        }
    }

    private func validateCredentialAccess() throws {
        do {
            try validateAccess()
        } catch {
            throw ClaudeCodeCredentialsKeychainError.credentialAccessUnavailable(underlying: error)
        }
    }
}

/// Replaces only the "claudeAiOauth" key of the keychain item JSON, keeping
/// every sibling (especially the machine-level "mcpOAuth") semantically in
/// place, so an account switch never clobbers machine state. Malformed input
/// is never repaired by replacement: callers must abort without writing.
public func mergeClaudeAiOauth(
    _ claudeAiOauthObjectJSON: Data,
    intoItemJSON existing: Data?
) throws -> Data {
    var item: [String: Any] = [:]
    if let existing {
        guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw ClaudeCodeCredentialsKeychainError.malformedCredentialJSON(
                "the existing item is not a JSON object"
            )
        }
        item = parsed
    }

    guard let claudeAiOauth = try? JSONSerialization.jsonObject(
        with: claudeAiOauthObjectJSON
    ) as? [String: Any] else {
        throw ClaudeCodeCredentialsKeychainError.malformedCredentialJSON(
            "the incoming OAuth payload is not a JSON object"
        )
    }
    item["claudeAiOauth"] = claudeAiOauth

    do {
        return try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
    } catch {
        throw ClaudeCodeCredentialsKeychainError.malformedCredentialJSON(
            "the merged credential could not be encoded"
        )
    }
}
