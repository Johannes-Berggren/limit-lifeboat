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
                    + "Quit and relaunch Limit Lifeboat, then try again."
            }
            return "Keychain operation failed with status \(status)."
        }
    }

    /// True when the failure is a locked or access-denied Keychain rather than a
    /// genuine absence, so the app can prompt the user to grant access instead
    /// of treating the account as having no saved credentials.
    public var isKeychainAccessDenied: Bool {
        credentialAccessDisposition?.isAccessDenied ?? false
    }

    /// Typed failure information survives through higher-level restore and
    /// rollback errors without forcing callers to parse localized strings.
    public var credentialAccessDisposition: CredentialAccessDisposition? {
        switch self {
        case .credentialAccessUnavailable(let underlying):
            return CredentialAccessDisposition(underlying: underlying)
        case .keychainError(let status):
            return CredentialAccessDisposition(status: status)
        case .encodeFailed, .decodeFailed:
            return nil
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

/// Opaque generation of one app-owned credential snapshot. Keychain-backed
/// stores rotate it on every write and match it atomically during replacement.
public struct CredentialStoreRevision: Equatable, Sendable {
    public let rawValue: Data

    public init(rawValue: Data) {
        self.rawValue = rawValue
    }
}

public struct VersionedCredentialSnapshot: Sendable {
    public var snapshot: CredentialSnapshot
    /// Nil only for an item written by a pre-revision app version. Its first
    /// mutation uses the legacy read/compare/write path and stamps a revision.
    public var revision: CredentialStoreRevision?

    public init(snapshot: CredentialSnapshot, revision: CredentialStoreRevision?) {
        self.snapshot = snapshot
        self.revision = revision
    }
}

public protocol CredentialStoreProtocol {
    func save(snapshot: CredentialSnapshot, for accountID: UUID, accessMode: CredentialAccessMode) throws
    /// Atomically inserts a snapshot only when the account has no existing
    /// credential item. A concurrent creator wins and leaves its bytes intact.
    /// Real credential-store implementations must override the compatibility
    /// fallback below so the absence check and insert are one operation.
    @discardableResult
    func insertSnapshotIfAbsent(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> Bool
    func loadVersionedSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> VersionedCredentialSnapshot?
    /// Atomically replaces an existing snapshot only while its opaque store
    /// revision still matches the generation the caller read.
    /// Implementations backed by a real credential store should override the
    /// default so the compare-and-swap does not require a second secret read.
    @discardableResult
    func replaceSnapshot(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        ifRevisionMatches expectedRevision: CredentialStoreRevision,
        accessMode: CredentialAccessMode
    ) throws -> CredentialStoreRevision?
    func loadSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> CredentialSnapshot?
    func deleteSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws
    func hasSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> Bool
}

public extension CredentialStoreProtocol {
    func save(snapshot: CredentialSnapshot, for accountID: UUID) throws {
        try save(snapshot: snapshot, for: accountID, accessMode: CredentialAccess.currentMode)
    }

    @discardableResult
    func insertSnapshotIfAbsent(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID
    ) throws -> Bool {
        try insertSnapshotIfAbsent(
            snapshot,
            for: accountID,
            accessMode: CredentialAccess.currentMode
        )
    }

    func loadSnapshot(for accountID: UUID) throws -> CredentialSnapshot? {
        try loadSnapshot(for: accountID, accessMode: CredentialAccess.currentMode)
    }

    func loadVersionedSnapshot(
        for accountID: UUID
    ) throws -> VersionedCredentialSnapshot? {
        try loadVersionedSnapshot(
            for: accountID,
            accessMode: CredentialAccess.currentMode
        )
    }

    /// Compatibility implementations for lightweight stores. Production's
    /// Keychain store overrides both with an opaque item revision, avoiding
    /// the replacement fallback's second read entirely.
    func loadVersionedSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> VersionedCredentialSnapshot? {
        guard let snapshot = try loadSnapshot(for: accountID, accessMode: accessMode) else {
            return nil
        }
        return VersionedCredentialSnapshot(
            snapshot: snapshot,
            revision: fallbackRevision(for: snapshot)
        )
    }

    /// Compatibility for in-memory and legacy stores. Production Keychain
    /// storage overrides this with one atomic `SecItemAdd`.
    @discardableResult
    func insertSnapshotIfAbsent(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        guard try loadVersionedSnapshot(
            for: accountID,
            accessMode: accessMode
        ) == nil else {
            return false
        }
        try save(snapshot: snapshot, for: accountID, accessMode: accessMode)
        return true
    }

    @discardableResult
    func replaceSnapshot(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        ifRevisionMatches expectedRevision: CredentialStoreRevision,
        accessMode: CredentialAccessMode
    ) throws -> CredentialStoreRevision? {
        guard let current = try loadSnapshot(for: accountID, accessMode: accessMode),
              fallbackRevision(for: current) == expectedRevision else {
            return nil
        }
        try save(snapshot: snapshot, for: accountID, accessMode: accessMode)
        return fallbackRevision(for: snapshot)
    }

    @discardableResult
    func replaceSnapshot(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        ifRevisionMatches expectedRevision: CredentialStoreRevision
    ) throws -> CredentialStoreRevision? {
        try replaceSnapshot(
            snapshot,
            for: accountID,
            ifRevisionMatches: expectedRevision,
            accessMode: CredentialAccess.currentMode
        )
    }

    func deleteSnapshot(for accountID: UUID) throws {
        try deleteSnapshot(for: accountID, accessMode: CredentialAccess.currentMode)
    }

    func hasSnapshot(for accountID: UUID) throws -> Bool {
        try hasSnapshot(for: accountID, accessMode: CredentialAccess.currentMode)
    }

    private func fallbackRevision(for snapshot: CredentialSnapshot) -> CredentialStoreRevision {
        CredentialStoreRevision(
            rawValue: Data(CredentialFingerprint.make(for: snapshot).utf8)
        )
    }
}

struct KeychainCredentialStoreOperations {
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let add: (CFDictionary) -> OSStatus

    static let live = KeychainCredentialStoreOperations(
        update: { query, attributes in
            SecItemUpdate(query, attributes)
        },
        add: { query in
            SecItemAdd(query, nil)
        }
    )
}

public final class KeychainCredentialStore: CredentialStoreProtocol {
    private let service: String
    private let validateAccess: @Sendable () throws -> Void
    private let operations: KeychainCredentialStoreOperations
    private let keychain: SecKeychain?
    private let encoder = JSONEncoder.appEncoder
    private let decoder = JSONDecoder.appDecoder

    public init(
        service: String = "com.limitlifeboat.app.credentials",
        validateAccess: @escaping @Sendable () throws -> Void = {}
    ) {
        self.service = service
        self.validateAccess = validateAccess
        self.operations = .live
        self.keychain = nil
    }

    init(
        service: String,
        validateAccess: @escaping @Sendable () throws -> Void = {},
        operations: KeychainCredentialStoreOperations
    ) {
        self.service = service
        self.validateAccess = validateAccess
        self.operations = operations
        self.keychain = nil
    }

    /// Integration-test initializer for a disposable legacy Keychain. It is
    /// internal so production app-owned snapshots always use the configured
    /// user search list.
    init(
        service: String,
        validateAccess: @escaping @Sendable () throws -> Void = {},
        keychain: SecKeychain
    ) {
        self.service = service
        self.validateAccess = validateAccess
        self.operations = .live
        self.keychain = keychain
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

        let revision = freshRevision()
        CredentialAccess.recordKeychainWrite()
        let updateStatus = operations.update(
            baseQuery(accountID: accountID, accessMode: accessMode) as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrGeneric as String: revision.rawValue
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(updateStatus)
        }

        var addQuery = baseQuery(accountID: accountID, accessMode: accessMode)
        addQuery.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain {
            addQuery[kSecUseKeychain as String] = keychain
        }
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrGeneric as String] = revision.rawValue
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        CredentialAccess.recordKeychainWrite()
        let addStatus = operations.add(addQuery as CFDictionary)
        if addStatus == errSecSuccess {
            return
        }

        // Another workflow may have inserted the same account after our
        // update reported not-found. Converge on its item without deleting it.
        if addStatus == errSecDuplicateItem {
            CredentialAccess.recordKeychainWrite()
            let retryStatus = operations.update(
                baseQuery(accountID: accountID, accessMode: accessMode) as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrGeneric as String: revision.rawValue
                ] as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw CredentialStoreError.keychainError(retryStatus)
            }
            return
        }

        throw CredentialStoreError.keychainError(addStatus)
    }

    /// `SecItemAdd` is the atomic absence predicate for a generic-password
    /// item. Unlike `save`, a duplicate is a compare-and-swap conflict and must
    /// never be followed by an update that overwrites the concurrent creator.
    @discardableResult
    public func insertSnapshotIfAbsent(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> Bool {
        try validateCredentialAccess()
        guard let data = try? encoder.encode(snapshot) else {
            throw CredentialStoreError.encodeFailed
        }

        var addQuery = baseQuery(accountID: accountID, accessMode: accessMode)
        addQuery.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain {
            addQuery[kSecUseKeychain as String] = keychain
        }
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrGeneric as String] = freshRevision().rawValue
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        CredentialAccess.recordKeychainWrite()
        let status = operations.add(addQuery as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecDuplicateItem { return false }
        throw CredentialStoreError.keychainError(status)
    }

    /// The opaque revision is mirrored into `kSecAttrGeneric`, which is a
    /// searchable generic-password attribute. `SecItemUpdate` therefore
    /// performs the generation check and value replacement atomically without
    /// returning or decoding the old secret bytes.
    @discardableResult
    public func replaceSnapshot(
        _ snapshot: CredentialSnapshot,
        for accountID: UUID,
        ifRevisionMatches expectedRevision: CredentialStoreRevision,
        accessMode: CredentialAccessMode
    ) throws -> CredentialStoreRevision? {
        try validateCredentialAccess()
        guard let data = try? encoder.encode(snapshot) else {
            throw CredentialStoreError.encodeFailed
        }

        let newRevision = freshRevision()
        var query = baseQuery(accountID: accountID, accessMode: accessMode)
        query[kSecAttrGeneric as String] = expectedRevision.rawValue
        CredentialAccess.recordKeychainWrite()
        let status = operations.update(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrGeneric as String: newRevision.rawValue
            ] as CFDictionary
        )
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
        return newRevision
    }

    public func loadSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> CredentialSnapshot? {
        try loadVersionedSnapshot(
            for: accountID,
            accessMode: accessMode
        )?.snapshot
    }

    public func loadVersionedSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> VersionedCredentialSnapshot? {
        try validateCredentialAccess()
        var query = baseQuery(accountID: accountID, accessMode: accessMode)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        CredentialAccess.recordKeychainDataRead()
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }
        let attributes = result as? [String: Any]
        guard let data = attributes?[kSecValueData as String] as? Data else {
            throw CredentialStoreError.decodeFailed(underlying: nil)
        }
        let snapshot: CredentialSnapshot
        do {
            snapshot = try decoder.decode(CredentialSnapshot.self, from: data)
        } catch {
            throw CredentialStoreError.decodeFailed(underlying: error)
        }

        let revision: CredentialStoreRevision?
        if let rawRevision = attributes?[kSecAttrGeneric as String] as? Data,
           !rawRevision.isEmpty {
            revision = CredentialStoreRevision(rawValue: rawRevision)
        } else {
            // There is no atomic Keychain predicate for "generic attribute is
            // absent" plus exact value bytes. Do not stamp a stale read and
            // risk making it match newer data. The first mutation takes the
            // legacy immediate read/compare/write path, whose save installs a
            // fresh opaque revision for all subsequent workflows.
            revision = nil
        }
        return VersionedCredentialSnapshot(snapshot: snapshot, revision: revision)
    }

    public func deleteSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()
        CredentialAccess.recordKeychainWrite()
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

        CredentialAccess.recordKeychainMetadataRead()
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecUseAuthenticationContext as String: CredentialAccess.authenticationContext(for: accessMode)
        ]
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    private func freshRevision() -> CredentialStoreRevision {
        CredentialStoreRevision(rawValue: Data(UUID().uuidString.utf8))
    }

    private func validateCredentialAccess() throws {
        do {
            try validateAccess()
        } catch {
            throw CredentialStoreError.credentialAccessUnavailable(underlying: error)
        }
    }
}
