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
    public let label: String

    public init(
        serviceName: String,
        accountName: String,
        keychainPath: String,
        persistentReference: Data,
        creationDate: Date,
        modificationDate: Date,
        label: String? = nil
    ) {
        self.serviceName = serviceName
        self.accountName = accountName
        self.keychainPath = keychainPath
        self.persistentReference = persistentReference
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.label = label ?? serviceName
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
    case keychainLocked(ClaudeKeychainItemLocation?)
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
        case .keychainLocked:
            // Locking is transient (not an ACL denial). Metadata and the ACL
            // gate remain prompt-free, so a later cycle may retry after wake
            // or after the user unlocks the login Keychain.
            return false
        case .notFound:
            return currentItem == nil
        case .unknown, .ready:
            return false
        }
    }
}

/// Whether Claude Code's own `/usr/bin/security` storage backend can access an
/// exact legacy Keychain item without presenting UI. This inspection reads
/// only Keychain and ACL metadata; it never requests the item's secret data.
enum ClaudeSecurityToolAccessStatus: Equatable, Sendable {
    case ready
    case needsAuthorization
    case keychainLocked
    case unsupported(String)
}

/// Test seam around Security.framework. Tests use an in-memory implementation,
/// which avoids inspecting or modifying the user's real login keychain.
protocol ClaudeKeychainSecurityClient: Sendable {
    func locateItems(
        serviceName: String,
        accountName: String,
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeKeychainItemLocation]

    func securityToolAccessStatus(
        at location: ClaudeKeychainItemLocation
    ) throws -> ClaudeSecurityToolAccessStatus
}

extension ClaudeKeychainSecurityClient {
    /// Existing in-memory clients model an already-authorized item. Production
    /// overrides this with exact ACL and lock-state inspection.
    func securityToolAccessStatus(
        at location: ClaudeKeychainItemLocation
    ) throws -> ClaudeSecurityToolAccessStatus {
        .ready
    }
}

/// Query construction is kept separate so unit tests can assert that exact
/// metadata and ACL operations use kSecMatchItemList and can never broaden
/// back to all items sharing the service/account pair. Secret data is handled
/// only by Claude's `/usr/bin/security` storage path.
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
            guard let label = row[kSecAttrLabel as String] as? String else {
                throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                    "the item has no label"
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
                modificationDate: modificationDate,
                label: label
            )
        }
    }

    func securityToolAccessStatus(
        at location: ClaudeKeychainItemLocation
    ) throws -> ClaudeSecurityToolAccessStatus {
        let keychain = try owningKeychain(for: location)
        var keychainStatus = SecKeychainStatus()
        let status = SecKeychainGetStatus(keychain, &keychainStatus)
        guard status == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        guard keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) != 0 else {
            return .keychainLocked
        }

        let item = try itemReference(
            at: location,
            in: keychain,
            accessMode: .nonInteractive
        )
        var access: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(accessStatus)
        }

        guard let rawPartitionACLs = SecAccessCopyMatchingACLList(
            access,
            kSecACLAuthorizationPartitionID
        ),
        let partitionACLs = rawPartitionACLs as? [SecACL],
        partitionACLs.count == 1 else {
            return .unsupported("the item does not have exactly one partition ACL")
        }
        guard let partitions = try Self.partitions(in: partitionACLs[0]) else {
            return .unsupported("the partition ACL is malformed")
        }

        guard let rawDecryptACLs = SecAccessCopyMatchingACLList(
            access,
            kSecACLAuthorizationDecrypt
        ),
        let decryptACLs = rawDecryptACLs as? [SecACL],
        !decryptACLs.isEmpty else {
            return .unsupported("the item does not have a decrypt ACL")
        }
        let trustsSecurityTool = try decryptACLs.contains {
            try Self.trustsSecurityToolWithoutPrompt($0)
        }
        return partitions.contains("apple-tool:") && trustsSecurityTool
            ? .ready
            : .needsAuthorization
    }

    private func owningKeychain(
        for location: ClaudeKeychainItemLocation
    ) throws -> SecKeychain {
        var owningKeychain: SecKeychain?
        let openStatus = SecKeychainOpen(location.keychainPath, &owningKeychain)
        guard openStatus == errSecSuccess, let owningKeychain else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(openStatus)
        }
        return owningKeychain
    }

    private func itemReference(
        at location: ClaudeKeychainItemLocation,
        in keychain: SecKeychain,
        accessMode: CredentialAccessMode
    ) throws -> SecKeychainItem {
        var query = ClaudeKeychainQuery.pinned(to: location, accessMode: accessMode)
        query[kSecMatchSearchList as String] = [keychain]
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        CredentialAccess.recordKeychainMetadataRead()
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw ClaudeCodeCredentialsKeychainError.itemIdentityMismatch
        }
        guard status == errSecSuccess, let result else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        guard CFGetTypeID(result) == SecKeychainItemGetTypeID() else {
            throw ClaudeCodeCredentialsKeychainError.malformedItemMetadata(
                "the persistent reference did not resolve to a legacy Keychain item"
            )
        }
        return unsafeBitCast(result, to: SecKeychainItem.self)
    }

    private static func partitions(in acl: SecACL) throws -> [String]? {
        var applications: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector()
        let status = SecACLCopyContents(
            acl,
            &applications,
            &description,
            &selector
        )
        guard status == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        guard let encoded = description as String? else { return nil }
        return ClaudeSecurityToolPartitionList.decode(encoded)
    }

    private static func trustsSecurityToolWithoutPrompt(
        _ acl: SecACL
    ) throws -> Bool {
        var applications: CFArray?
        var description: CFString?
        var selector = SecKeychainPromptSelector()
        let status = SecACLCopyContents(
            acl,
            &applications,
            &description,
            &selector
        )
        guard status == errSecSuccess else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        guard !selector.contains(.requirePassphase) else {
            return false
        }
        // A nil application list means this ACL allows every application
        // without a per-use prompt. Otherwise require Claude's exact backend.
        guard let applications else {
            return true
        }
        guard let trustedApplications = applications as? [SecTrustedApplication] else {
            return false
        }
        let expectedIdentity = try securityToolTrustedApplicationIdentity()
        return try trustedApplications.contains { application in
            try trustedApplicationIdentity(application) == expectedIdentity
        }
    }

    /// `SecTrustedApplicationCopyData` is documented as opaque identity data,
    /// not a filesystem path. Compare an ACL candidate with a reference
    /// identity constructed from the hardcoded system helper.
    private static func securityToolTrustedApplicationIdentity() throws -> Data {
        var application: SecTrustedApplication?
        let status = SecTrustedApplicationCreateFromPath(
            "/usr/bin/security",
            &application
        )
        guard status == errSecSuccess, let application else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        return try trustedApplicationIdentity(application)
    }

    private static func trustedApplicationIdentity(
        _ application: SecTrustedApplication
    ) throws -> Data {
        var identity: CFData?
        let status = SecTrustedApplicationCopyData(application, &identity)
        guard status == errSecSuccess, let identity else {
            throw ClaudeCodeCredentialsKeychainError.keychainError(status)
        }
        return identity as Data
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

enum ClaudeSecurityToolPartitionList {
    static func decode(_ encoded: String) -> [String]? {
        guard let plistData = Data(strictHexEncoded: encoded),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ),
              let dictionary = plist as? [String: Any],
              let partitions = dictionary["Partitions"] as? [String],
              !partitions.isEmpty else {
            return nil
        }
        return partitions
    }
}

private extension Data {
    init?(strictHexEncoded string: String) {
        let encoded = Array(string.utf8)
        guard encoded.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.count / 2)
        for index in stride(from: 0, to: encoded.count, by: 2) {
            guard let high = Self.hexNibble(encoded[index]),
                  let low = Self.hexNibble(encoded[index + 1]) else {
                return nil
            }
            bytes.append((high << 4) | low)
        }
        self.init(bytes)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x41...0x46:
            return byte - 0x41 + 10
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }
}
