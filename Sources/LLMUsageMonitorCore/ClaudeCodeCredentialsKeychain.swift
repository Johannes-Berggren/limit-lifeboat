import Foundation
import Security

public enum ClaudeCodeCredentialsKeychainError: Error, LocalizedError {
    case credentialAccessUnavailable(underlying: Error)
    case missingLiveItem
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .credentialAccessUnavailable(let underlying):
            return underlying.localizedDescription
        case .missingLiveItem:
            return "Claude Code is not logged in. Run `claude /login` before switching accounts."
        case .keychainError(let status):
            if CredentialStoreError.isCodeSigningStatus(status) {
                return CredentialStoreError.keychainError(status).localizedDescription
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
            return "Could not access Claude Code credentials (Keychain status \(status): \(detail))."
        }
    }

    public var isKeychainAccessDenied: Bool {
        switch self {
        case .credentialAccessUnavailable:
            return true
        case .missingLiveItem:
            return false
        case .keychainError(let status):
            return status == errSecInteractionNotAllowed
                || status == errSecInteractionRequired
                || status == errSecAuthFailed
                || status == errSecUserCanceled
                || CredentialStoreError.isCodeSigningStatus(status)
        }
    }
}

/// Where the live Claude Code CLI credentials come from and go back to.
/// Abstracted so tests (and the switcher's snapshot store) can substitute an
/// in-memory source.
public protocol ClaudeCLICredentialSource: Sendable {
    /// The full keychain item JSON, or nil when no item exists (logged out).
    func readLiveItemJSON(accessMode: CredentialAccessMode) throws -> Data?
    func writeLiveItemJSON(_ data: Data, accessMode: CredentialAccessMode) throws
    func deleteLiveItem(accessMode: CredentialAccessMode) throws
}

public extension ClaudeCLICredentialSource {
    func readLiveItemJSON() throws -> Data? {
        try readLiveItemJSON(accessMode: CredentialAccess.currentMode)
    }

    func writeLiveItemJSON(_ data: Data) throws {
        try writeLiveItemJSON(data, accessMode: CredentialAccess.currentMode)
    }

    func deleteLiveItem() throws {
        try deleteLiveItem(accessMode: CredentialAccess.currentMode)
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

    public init(
        serviceName: String = Self.serviceName,
        accountName: String = NSUserName(),
        validateAccess: @escaping @Sendable () throws -> Void = {}
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.validateAccess = validateAccess
    }

    public func readLiveItemJSON(accessMode: CredentialAccessMode) throws -> Data? {
        try validateCredentialAccess()

        var query = baseQuery(accessMode: accessMode)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        guard let data = result as? Data else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(errSecDecode)
        }

        return data
    }

    public func writeLiveItemJSON(_ data: Data, accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()

        let status = SecItemUpdate(
            baseQuery(accessMode: accessMode) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess {
            return
        }
        if status == errSecItemNotFound {
            throw ClaudeCodeCredentialsKeychainError.missingLiveItem
        }
        throw ClaudeCodeCredentialsKeychainError.keychainError(status)
    }

    public func deleteLiveItem(accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()

        let status = SecItemDelete(baseQuery(accessMode: accessMode) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
    }

    private func baseQuery(accessMode: CredentialAccessMode) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecUseAuthenticationContext as String: CredentialAccess.authenticationContext(for: accessMode)
        ]
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
/// every sibling (especially the machine-level "mcpOAuth") byte-for-byte in
/// place, so an account switch never clobbers machine state.
public func mergeClaudeAiOauth(_ claudeAiOauthObjectJSON: Data, intoItemJSON existing: Data?) -> Data {
    var item: [String: Any] = [:]
    if let existing,
       let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
        item = parsed
    }

    if let claudeAiOauth = try? JSONSerialization.jsonObject(with: claudeAiOauthObjectJSON) as? [String: Any] {
        item["claudeAiOauth"] = claudeAiOauth
    }

    guard let merged = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else {
        return existing ?? Data("{}".utf8)
    }
    return merged
}
