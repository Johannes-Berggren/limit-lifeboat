import Foundation
import Security

public enum ClaudeCodeCredentialsKeychainError: Error, LocalizedError {
    case credentialAccessUnavailable(underlying: Error)
    case missingLiveItem
    case duplicateLiveItems([ClaudeKeychainItemLocation])
    case malformedItemMetadata(String)
    case malformedCredentialJSON(String)
    case itemIdentityMismatch
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
        case .missingLiveItem, .duplicateLiveItems, .malformedItemMetadata,
             .malformedCredentialJSON, .itemIdentityMismatch:
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

/// Reads and writes the "Claude Code-credentials" generic password directly
/// through Security.framework. Existing items keep their ACL because updates
/// modify only kSecValueData. This app deliberately never creates the live
/// item: Claude Code must remain its owner so its access-control list is not
/// replaced with one that makes the CLI repeatedly request authorization.
public struct ClaudeCodeCredentialsKeychain: ClaudeCLICredentialSource {
    public static let serviceName = "Claude Code-credentials"

    private let serviceName: String
    private let accountName: String
    private let validateAccess: @Sendable () throws -> Void
    private let securityClient: any ClaudeKeychainSecurityClient

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
    }

    init(
        serviceName: String = Self.serviceName,
        accountName: String = NSUserName(),
        validateAccess: @escaping @Sendable () throws -> Void = {},
        securityClient: any ClaudeKeychainSecurityClient
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.validateAccess = validateAccess
        self.securityClient = securityClient
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
        return try securityClient.readData(at: location, accessMode: accessMode)
    }

    public func readLiveItemJSON(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        try validateCredentialAccess()
        try validate(location: location)
        return try securityClient.readData(at: location, accessMode: accessMode)
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

    public func deleteLiveItem(accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()
        guard let location = try locateValidated(accessMode: accessMode) else { return }
        try securityClient.deleteItem(at: location, accessMode: accessMode)
    }

    public func deleteLiveItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        try validateCredentialAccess()
        try validate(location: location)
        try securityClient.deleteItem(at: location, accessMode: accessMode)
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
        accessMode: CredentialAccessMode
    ) throws {
        let updated = try securityClient.updateData(data, at: location, accessMode: accessMode)
        guard updated else {
            throw ClaudeCodeCredentialsKeychainError.missingLiveItem
        }
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
