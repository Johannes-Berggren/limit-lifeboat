import Darwin
import Foundation
import LocalAuthentication
import Security

/// A durable identity for one legacy macOS Keychain item. Persistent
/// references are intentionally never rendered in descriptions or logs.
public struct ClaudeKeychainItemIdentity: Hashable, Sendable {
    public let keychainPath: String
    public let persistentReference: Data

    public init(keychainPath: String, persistentReference: Data) {
        self.keychainPath = keychainPath
        self.persistentReference = persistentReference
    }
}

/// Metadata that changes when Claude replaces or updates its shared item.
/// This contains no secret data and is suitable for noninteractive login
/// completion polling.
public struct ClaudeKeychainItemModificationStamp: Hashable, Sendable {
    public let identity: ClaudeKeychainItemIdentity
    public let modificationDate: Date

    public init(identity: ClaudeKeychainItemIdentity, modificationDate: Date) {
        self.identity = identity
        self.modificationDate = modificationDate
    }
}

/// The exact shared Claude credential item selected from the user's Keychain
/// search list. The persistent reference pins subsequent operations to this
/// item instead of repeating a broad service/account search.
public struct ClaudeKeychainItemLocation: Hashable, Sendable {
    public let serviceName: String
    public let accountName: String
    public let keychainPath: String
    public let persistentReference: Data
    public let creationDate: Date
    public let modificationDate: Date

    public init(
        serviceName: String,
        accountName: String,
        keychainPath: String,
        persistentReference: Data,
        creationDate: Date,
        modificationDate: Date
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.keychainPath = keychainPath
        self.persistentReference = persistentReference
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    public var identity: ClaudeKeychainItemIdentity {
        ClaudeKeychainItemIdentity(
            keychainPath: keychainPath,
            persistentReference: persistentReference
        )
    }

    public var modificationStamp: ClaudeKeychainItemModificationStamp {
        ClaudeKeychainItemModificationStamp(
            identity: identity,
            modificationDate: modificationDate
        )
    }
}

/// Item-scoped state for the one explicit native Keychain authorization flow.
/// A caller should only enter `ready` after a fresh noninteractive data read.
public enum ClaudeKeychainAuthorizationState: Equatable, Sendable {
    case unknown
    case ready(ClaudeKeychainItemLocation)
    case needsAuthorization(
        item: ClaudeKeychainItemLocation?,
        disposition: CredentialAccessDisposition
    )
    case authorizing(ClaudeKeychainItemLocation?)
    case notFound
    case failed(message: String)

    /// Background work may retry a denied provider item only after metadata
    /// proves that Claude created or modified a different generation. This is
    /// intentionally metadata-only: a cancellation or one-time Allow must not
    /// turn polling, popover opens, wake handling, or usage refreshes into a
    /// stream of denied secret reads.
    public func suppressesAutomaticDataRead(
        currentItem: ClaudeKeychainItemLocation?
    ) -> Bool {
        switch self {
        case .needsAuthorization(let deniedItem, _):
            guard let deniedItem else {
                // The denial happened before an exact item could be retained.
                // Fail closed until an explicit authorization attempt or a
                // later metadata sample can be anchored by the caller.
                return true
            }
            guard let currentItem else {
                return true
            }
            return deniedItem.modificationStamp == currentItem.modificationStamp
        case .authorizing, .failed:
            return true
        case .notFound:
            return currentItem == nil
        case .unknown, .ready:
            return false
        }
    }
}

/// Test seam around Security.framework. Tests use an in-memory implementation,
/// which avoids inspecting or modifying the user's real login keychain.
protocol ClaudeKeychainSecurityClient: Sendable {
    func locateItems(
        serviceName: String,
        accountName: String,
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeKeychainItemLocation]

    func readData(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data?

    /// Returns false when the resolved item was removed or replaced.
    func updateData(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Bool

    func deleteItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws
}

/// Query construction is kept separate so unit tests can assert that secret
/// operations use kSecMatchItemList and can never broaden back to all items
/// sharing the service/account pair.
enum ClaudeKeychainQuery {
    static func discovery(
        serviceName: String,
        accountName: String,
        accessMode: CredentialAccessMode
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: CredentialAccess.authenticationContext(for: accessMode)
        ]
    }

    static func pinned(
        to location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: location.serviceName,
            kSecAttrAccount as String: location.accountName,
            kSecMatchItemList as String: [location.persistentReference],
            kSecUseAuthenticationContext as String: CredentialAccess.authenticationContext(for: accessMode)
        ]
    }
}

struct SystemClaudeKeychainSecurityClient: ClaudeKeychainSecurityClient, @unchecked Sendable {
    private let searchList: [SecKeychain]?

    init(searchList: [SecKeychain]? = nil) {
        self.searchList = searchList
    }

    func locateItems(
        serviceName: String,
        accountName: String,
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeKeychainItemLocation] {
        var query = ClaudeKeychainQuery.discovery(
            serviceName: serviceName,
            accountName: accountName,
            accessMode: accessMode
        )
        if let searchList {
            query[kSecMatchSearchList as String] = searchList
        }
        var result: CFTypeRef?
        CredentialAccess.recordKeychainMetadataRead()
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        guard let result else {
            throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                "the metadata query returned no result"
            )
        }

        let rawRows: [Any]
        if let rows = result as? [Any] {
            rawRows = rows
        } else {
            rawRows = [result]
        }

        return try rawRows.map { rawRow in
            guard let row = rawRow as? [String: Any] else {
                throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                    "the metadata result was not a dictionary"
                )
            }
            guard let persistentReference = row[kSecValuePersistentRef as String] as? Data,
                  !persistentReference.isEmpty else {
                throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                    "the item has no persistent reference"
                )
            }
            guard let returnedService = row[kSecAttrService as String] as? String,
                  let returnedAccount = row[kSecAttrAccount as String] as? String,
                  returnedService == serviceName,
                  returnedAccount == accountName else {
                throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                    "the returned service or account did not match the query"
                )
            }
            guard let creationDate = row[kSecAttrCreationDate as String] as? Date,
                  let modificationDate = row[kSecAttrModificationDate as String] as? Date else {
                throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                    "the item has no creation or modification date"
                )
            }
            guard let itemReference = row[kSecValueRef as String] else {
                throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                    "the item has no transient reference"
                )
            }

            return ClaudeKeychainItemLocation(
                serviceName: returnedService,
                accountName: returnedAccount,
                keychainPath: try keychainPath(for: itemReference),
                persistentReference: persistentReference,
                creationDate: creationDate,
                modificationDate: modificationDate
            )
        }
    }

    func readData(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Data? {
        var query = try pinnedQuery(to: location, accessMode: accessMode)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        CredentialAccess.recordKeychainDataRead()
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

    func updateData(
        _ data: Data,
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        CredentialAccess.recordKeychainWrite()
        let status = SecItemUpdate(
            try pinnedQuery(to: location, accessMode: accessMode) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        return true
    }

    func deleteItem(
        at location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws {
        CredentialAccess.recordKeychainWrite()
        let status = SecItemDelete(
            try pinnedQuery(to: location, accessMode: accessMode) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
    }

    /// A persistent reference identifies the item; the owning-keychain search
    /// list additionally prevents a search-list change or similarly encoded
    /// reference from redirecting a secret operation to another keychain.
    private func pinnedQuery(
        to location: ClaudeKeychainItemLocation,
        accessMode: CredentialAccessMode
    ) throws -> [String: Any] {
        var owningKeychain: SecKeychain?
        let openStatus = SecKeychainOpen(location.keychainPath, &owningKeychain)
        guard openStatus == errSecSuccess, let owningKeychain else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(openStatus)
        }
        var query = ClaudeKeychainQuery.pinned(to: location, accessMode: accessMode)
        query[kSecMatchSearchList as String] = [owningKeychain]
        return query
    }

    private func keychainPath(for rawItemReference: Any) throws -> String {
        let cfReference = rawItemReference as CFTypeRef
        guard CFGetTypeID(cfReference) == SecKeychainItemGetTypeID() else {
            throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                "the transient reference was not a legacy Keychain item"
            )
        }
        let itemReference = unsafeBitCast(cfReference, to: SecKeychainItem.self)

        var keychain: SecKeychain?
        let copyStatus = SecKeychainItemCopyKeychain(itemReference, &keychain)
        guard copyStatus == errSecSuccess, let keychain else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(copyStatus)
        }

        var pathLength = UInt32(MAXPATHLEN)
        var pathBuffer = [CChar](repeating: 0, count: Int(pathLength) + 1)
        let pathStatus = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            SecKeychainGetPath(keychain, &pathLength, buffer.baseAddress!)
        }
        guard pathStatus == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(pathStatus)
        }

        let bytes = pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
