import Foundation
import Security

public enum CredentialStoreError: Error, LocalizedError {
    case encodeFailed
    case decodeFailed(underlying: Error?)
    case credentialAccessUnavailable(underlying: Error)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "Could not encode the credential snapshot."
        case .decodeFailed(let underlying):
            let reason = underlying?.localizedDescription ?? "the data is not in the expected format"
            return "Could not decode the saved credentials (\(reason))."
        case .credentialAccessUnavailable(let underlying):
            return underlying.localizedDescription
        case .keychainError(let status):
            if Self.isCodeSigningStatus(status) {
                // The Keychain couldn't resolve this app's on-disk code to
                // authorize the item — almost always because the running copy
                // was rebuilt, moved, or deleted while open (e.g. -67068,
                // errSecCSStaticCodeNotFound). A bare status code is useless
                // here, so name the cause and the fix.
                return "macOS can't verify this app's code signature (Keychain status \(status)). "
                    + "The running copy was likely rebuilt, moved, or deleted while open. "
                    + "Quit and relaunch LLM Usage Monitor, then try again."
            }
            return "Keychain operation failed with status \(status)."
        }
    }

    /// True when the failure is a locked or access-denied Keychain rather than a
    /// genuine absence, so the app can prompt the user to grant access instead
    /// of treating the account as having no saved credentials.
    public var isKeychainAccessDenied: Bool {
        switch self {
        case .credentialAccessUnavailable:
            return true
        case .keychainError(let status):
            return status == errSecInteractionNotAllowed
                || status == errSecInteractionRequired
                || status == errSecAuthFailed
                || status == errSecUserCanceled
                || Self.isCodeSigningStatus(status)
        case .encodeFailed, .decodeFailed:
            return false
        }
    }

    /// Code-signing / static-code errors (the `errSecCS*` family, e.g.
    /// -67068 errSecCSStaticCodeNotFound) that surface from Keychain calls when
    /// macOS can't resolve the caller's on-disk code to evaluate an item ACL.
    /// These are recoverable by relaunching, so they count as access-denied
    /// rather than a missing item.
    static func isCodeSigningStatus(_ status: OSStatus) -> Bool {
        // errSecCSUnimplemented (-67072) … errSecCSInternalError (-67008).
        (-67072 ... -67008).contains(status)
    }
}

public protocol CredentialStoreProtocol {
    func save(snapshot: CredentialSnapshot, for accountID: UUID, accessMode: CredentialAccessMode) throws
    func loadSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> CredentialSnapshot?
    func deleteSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws
    func hasSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> Bool
}

public extension CredentialStoreProtocol {
    func save(snapshot: CredentialSnapshot, for accountID: UUID) throws {
        try save(snapshot: snapshot, for: accountID, accessMode: CredentialAccess.currentMode)
    }

    func loadSnapshot(for accountID: UUID) throws -> CredentialSnapshot? {
        try loadSnapshot(for: accountID, accessMode: CredentialAccess.currentMode)
    }

    func deleteSnapshot(for accountID: UUID) throws {
        try deleteSnapshot(for: accountID, accessMode: CredentialAccess.currentMode)
    }

    func hasSnapshot(for accountID: UUID) throws -> Bool {
        try hasSnapshot(for: accountID, accessMode: CredentialAccess.currentMode)
    }
}

public final class KeychainCredentialStore: CredentialStoreProtocol {
    private let service: String
    private let validateAccess: @Sendable () throws -> Void
    private let encoder = JSONEncoder.appEncoder
    private let decoder = JSONDecoder.appDecoder

    public init(
        service: String = "com.johannesberggren.LLMUsageMonitor.credentials",
        validateAccess: @escaping @Sendable () throws -> Void = {}
    ) {
        self.service = service
        self.validateAccess = validateAccess
    }

    public func save(
        snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws {
        try validateCredentialAccess()
        guard let data = try? encoder.encode(snapshot) else {
            throw CredentialStoreError.encodeFailed
        }

        var addQuery = baseQuery(accountID: accountID, accessMode: accessMode)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(accountID: accountID, accessMode: accessMode) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.keychainError(updateStatus)
            }
            return
        }

        throw CredentialStoreError.keychainError(addStatus)
    }

    public func loadSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> CredentialSnapshot? {
        try validateCredentialAccess()
        var query = baseQuery(accountID: accountID, accessMode: accessMode)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
        guard let data = result as? Data else {
            throw CredentialStoreError.decodeFailed(underlying: nil)
        }
        do {
            return try decoder.decode(CredentialSnapshot.self, from: data)
        } catch {
            throw CredentialStoreError.decodeFailed(underlying: error)
        }
    }

    public func deleteSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()
        let status = SecItemDelete(baseQuery(accountID: accountID, accessMode: accessMode) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    public func hasSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> Bool {
        try validateCredentialAccess()
        var query = baseQuery(accountID: accountID, accessMode: accessMode)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
        return true
    }

    private func baseQuery(accountID: UUID, accessMode: CredentialAccessMode) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecUseAuthenticationContext as String: CredentialAccess.authenticationContext(for: accessMode)
        ]
    }

    private func validateCredentialAccess() throws {
        do {
            try validateAccess()
        } catch {
            throw CredentialStoreError.credentialAccessUnavailable(underlying: error)
        }
    }
}
