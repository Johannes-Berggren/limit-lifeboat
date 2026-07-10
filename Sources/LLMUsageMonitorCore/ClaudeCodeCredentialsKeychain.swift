import Foundation
import Security

public enum ClaudeCodeCredentialsKeychainError: Error, LocalizedError {
    case credentialAccessUnavailable(underlying: Error)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .credentialAccessUnavailable(let underlying):
            return underlying.localizedDescription
        case .keychainError(let status):
            if CredentialStoreError.isCodeSigningStatus(status) {
                return CredentialStoreError.keychainError(status).localizedDescription
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
            return "Could not access Claude Code credentials (Keychain status \(status): \(detail))."
        }
    }
}

/// Where the live Claude Code CLI credentials come from and go back to.
/// Abstracted so tests (and the switcher's snapshot store) can substitute an
/// in-memory source.
public protocol ClaudeCLICredentialSource: Sendable {
    /// The full keychain item JSON, or nil when no item exists (logged out).
    func readLiveItemJSON() throws -> Data?
    func writeLiveItemJSON(_ data: Data) throws
}

/// Reads and writes the "Claude Code-credentials" generic password directly
/// through Security.framework. Existing items keep their ACL because updates
/// modify only kSecValueData. A newly-created item explicitly trusts both this
/// app and /usr/bin/security so the Claude Code CLI remains interoperable.
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

    public func readLiveItemJSON() throws -> Data? {
        try validateCredentialAccess()

        var query = baseQuery()
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

    public func writeLiveItemJSON(_ data: Data) throws {
        try validateCredentialAccess()

        let status = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }

        try addSharedItem(data)
    }

    private func addSharedItem(_ data: Data) throws {
        let access = try makeSharedAccess()
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccess as String] = access

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }

        // Another process may have created the item after our update missed
        // it. Retry as a data-only update so its ACL remains untouched.
        if status == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                baseQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw ClaudeCodeCredentialsKeychainError.keychainError(retryStatus)
            }
            return
        }

        throw ClaudeCodeCredentialsKeychainError.keychainError(status)
    }

    private func makeSharedAccess() throws -> SecAccess {
        var currentApplication: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &currentApplication)
        guard status == errSecSuccess, let currentApplication else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }

        var securityTool: SecTrustedApplication?
        status = "/usr/bin/security".withCString {
            SecTrustedApplicationCreateFromPath($0, &securityTool)
        }
        guard status == errSecSuccess, let securityTool else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }

        var access: SecAccess?
        status = SecAccessCreate(
            serviceName as CFString,
            [currentApplication, securityTool] as CFArray,
            &access
        )
        guard status == errSecSuccess, let access else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        return access
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
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
