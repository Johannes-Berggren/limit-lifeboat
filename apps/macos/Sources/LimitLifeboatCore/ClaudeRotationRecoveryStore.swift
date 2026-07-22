import Foundation
import CryptoKit
import os
import Security

/// One owner that must receive a remotely rotated Claude OAuth generation.
/// The record containing these destinations lives in the app-owned Keychain;
/// diagnostics may mention only destination kinds and profile UUIDs.
public enum ClaudeRotationRecoveryDestination: Codable, Equatable, Hashable, Sendable {
    case liveClaudeCode
    case storedProfile(UUID)
}

/// A prepared record durably pins the intended owners before an irreversible
/// exchange. Once the token response is known, the same record is advanced to
/// `freshGeneration` with the encrypted OAuth payload. The optional storage in
/// `ClaudeRotationRecoveryRecord` keeps records written by older builds
/// decodable; a missing phase is an already-fresh legacy record.
public enum ClaudeRotationRecoveryPhase: String, Codable, Equatable, Sendable {
    case prepared
    case freshGeneration
}

/// Privacy-safe identity for the OAuth fields advanced by one token exchange.
/// Recovery uses this only for compare-and-swap baselines; it must never be
/// logged or used as an account identity (the refresh-chain digest serves that
/// separate purpose).
enum ClaudeOAuthGenerationFingerprint {
    static func make(_ credentials: ClaudeOAuthCredentials) -> String {
        let components = [
            credentials.accessToken,
            credentials.refreshToken ?? "",
            credentials.expiresAt.map {
                String(Int64(($0.timeIntervalSince1970 * 1_000).rounded()))
            } ?? "",
            credentials.refreshTokenExpiresAt.map {
                String(Int64(($0.timeIntervalSince1970 * 1_000).rounded()))
            } ?? ""
        ]
        var data = Data()
        for component in components {
            var length = UInt64(component.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: component.utf8)
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Crash/partial-write recovery for an irreversible refresh-token exchange.
/// `oauthJSON` is secret material and must only be persisted by a conforming
/// encrypted recovery store, never in Application Support or unified logs.
public struct ClaudeRotationRecoveryRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var staleChainFingerprint: String
    public var freshChainFingerprint: String?
    public var oauthJSON: Data
    public var pendingDestinations: Set<ClaudeRotationRecoveryDestination>
    /// Exact, pre-exchange generations for every owner that existed when the
    /// refresh began. A non-nil map distinguishes an intentionally absent
    /// owner from a legacy journal record. Recovery may replay only over an
    /// owner whose generation still matches its entry; any other generation,
    /// even on the same refresh-token chain, wins as a concurrent update.
    public var ownerGenerationBaselines: [ClaudeRotationRecoveryDestination: String]?
    public var phase: ClaudeRotationRecoveryPhase?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        staleChainFingerprint: String,
        freshChainFingerprint: String?,
        oauthJSON: Data,
        pendingDestinations: Set<ClaudeRotationRecoveryDestination>,
        ownerGenerationBaselines: [ClaudeRotationRecoveryDestination: String]? = nil,
        phase: ClaudeRotationRecoveryPhase? = .freshGeneration
    ) {
        self.id = id
        self.createdAt = createdAt
        self.staleChainFingerprint = staleChainFingerprint
        self.freshChainFingerprint = freshChainFingerprint
        self.oauthJSON = oauthJSON
        self.pendingDestinations = pendingDestinations
        self.ownerGenerationBaselines = ownerGenerationBaselines
        self.phase = phase
    }

    public var credentials: ClaudeOAuthCredentials? {
        ClaudeOAuthCredentials(claudeAiOauthJSON: oauthJSON)
    }

    public var isPrepared: Bool { phase == .prepared }

    /// True only when this record proves that the app-owned profile advanced
    /// while the provider-owned live item is still exactly the pinned stale
    /// generation. Scheduled reconciliation can then leave the stored owner
    /// untouched until explicit recovery runs. A different live generation is
    /// never classified as stale, so an external login remains authoritative.
    public func protectsStoredOwnerFromStaleLiveCapture(
        profileID: UUID,
        stored: ClaudeOAuthCredentials,
        live: ClaudeOAuthCredentials
    ) -> Bool {
        let storedDestination = ClaudeRotationRecoveryDestination.storedProfile(
            profileID
        )
        guard pendingDestinations.contains(.liveClaudeCode)
                || pendingDestinations.contains(storedDestination),
              let baselines = ownerGenerationBaselines,
              let liveBaseline = baselines[.liveClaudeCode],
              ClaudeOAuthGenerationFingerprint.make(live) == liveBaseline else {
            return false
        }

        let storedGeneration = ClaudeOAuthGenerationFingerprint.make(stored)
        if isPrepared {
            // A missing baseline intentionally means this destination did not
            // exist before the request. If it now exists while the live owner
            // remains exactly stale, preserve it: it is an external/new owner
            // (or a surviving write from an older build), never evidence that
            // stale live should overwrite it.
            guard pendingDestinations.contains(storedDestination) else {
                return false
            }
            guard let storedBaseline = baselines[storedDestination] else {
                return true
            }
            return storedGeneration != storedBaseline
        }

        guard let fresh = credentials else { return false }
        return storedGeneration == ClaudeOAuthGenerationFingerprint.make(fresh)
    }
}

public protocol ClaudeRotationRecoveryStoring: Sendable {
    func save(
        _ record: ClaudeRotationRecoveryRecord,
        accessMode: CredentialAccessMode
    ) throws
    func loadAll(
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeRotationRecoveryRecord]
    func delete(
        id: UUID,
        accessMode: CredentialAccessMode
    ) throws
}

public extension ClaudeRotationRecoveryStoring {
    func save(_ record: ClaudeRotationRecoveryRecord) throws {
        try save(record, accessMode: CredentialAccess.currentMode)
    }

    func loadAll() throws -> [ClaudeRotationRecoveryRecord] {
        try loadAll(accessMode: CredentialAccess.currentMode)
    }

    func delete(id: UUID) throws {
        try delete(id: id, accessMode: CredentialAccess.currentMode)
    }
}

/// Security.framework rejects legacy-Keychain queries that combine
/// `kSecReturnData` with `kSecMatchLimitAll` (`errSecParam`). Keep inventory
/// and secret reads separate so listing can never become a multi-item
/// credential read.
enum ClaudeRotationRecoveryKeychainQuery {
    static func inventory(
        service: String,
        accessMode: CredentialAccessMode
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String:
                CredentialAccess.authenticationContext(for: accessMode)
        ]
    }

    static func pinnedRead(
        service: String,
        account: String,
        persistentReference: Data,
        accessMode: CredentialAccessMode
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchItemList as String: [persistentReference],
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String:
                CredentialAccess.authenticationContext(for: accessMode)
        ]
    }
}

struct KeychainClaudeRotationRecoveryStoreOperations {
    let copyMatching: (
        CFDictionary,
        UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    static let live = KeychainClaudeRotationRecoveryStoreOperations(
        copyMatching: { query, result in
            SecItemCopyMatching(query, result)
        }
    )
}

/// Keychain-backed recovery journal. Items are additive/updateable by
/// transaction UUID and device-local, matching the protection of saved
/// credential snapshots. Listing is required so launch recovery does not rely
/// on an unencrypted sidecar index.
public final class KeychainClaudeRotationRecoveryStore: ClaudeRotationRecoveryStoring,
    @unchecked Sendable {
    private let service: String
    private let validateAccess: @Sendable () throws -> Void
    private let keychain: SecKeychain?
    private let operations: KeychainClaudeRotationRecoveryStoreOperations
    private let encoder = JSONEncoder.appEncoder
    private let decoder = JSONDecoder.appDecoder

    public init(
        service: String = "com.limitlifeboat.app.claude-rotation-recovery",
        validateAccess: @escaping @Sendable () throws -> Void = {}
    ) {
        self.service = service
        self.validateAccess = validateAccess
        self.keychain = nil
        self.operations = .live
    }

    /// Integration-test initializer for a disposable legacy Keychain. It is
    /// internal so production recovery records always use the configured user
    /// search list and existing service identity.
    init(
        service: String,
        validateAccess: @escaping @Sendable () throws -> Void = {},
        keychain: SecKeychain
    ) {
        self.service = service
        self.validateAccess = validateAccess
        self.keychain = keychain
        self.operations = .live
    }

    init(
        service: String,
        validateAccess: @escaping @Sendable () throws -> Void = {},
        keychain: SecKeychain,
        operations: KeychainClaudeRotationRecoveryStoreOperations
    ) {
        self.service = service
        self.validateAccess = validateAccess
        self.keychain = keychain
        self.operations = operations
    }

    public func save(
        _ record: ClaudeRotationRecoveryRecord,
        accessMode: CredentialAccessMode
    ) throws {
        try validateCredentialAccess()
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw CredentialStoreError.encodeFailed
        }

        let query = baseQuery(account: record.id.uuidString, accessMode: accessMode)
        CredentialAccess.recordKeychainWrite()
        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(update)
        }

        var add = query
        add.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain {
            add[kSecUseKeychain as String] = keychain
        }
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        CredentialAccess.recordKeychainWrite()
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            CredentialAccess.recordKeychainWrite()
            let retry = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retry == errSecSuccess else {
                throw CredentialStoreError.keychainError(retry)
            }
            return
        }
        throw CredentialStoreError.keychainError(status)
    }

    public func loadAll(
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeRotationRecoveryRecord] {
        try validateCredentialAccess()
        var query = ClaudeRotationRecoveryKeychainQuery.inventory(
            service: service,
            accessMode: accessMode
        )
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        CredentialAccess.recordKeychainMetadataRead()
        var result: CFTypeRef?
        let status = operations.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainError(status)
        }

        let rows: [[String: Any]]
        if let many = result as? [[String: Any]] {
            rows = many
        } else if let one = result as? [String: Any] {
            rows = [one]
        } else {
            throw CredentialStoreError.decodeFailed(underlying: nil)
        }

        // Inventory contains no secret bytes. Read each exact persistent item
        // separately so every credential query remains match-one. A malformed
        // or concurrently removed row must not sink independent recovery work.
        var records: [ClaudeRotationRecoveryRecord] = []
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String,
                  !account.isEmpty else {
                AppLog.credentials.error(
                    "Skipping rotation-recovery row with no account metadata."
                )
                continue
            }
            guard let persistentReference = row[kSecValuePersistentRef as String] as? Data,
                  !persistentReference.isEmpty else {
                AppLog.credentials.error(
                    "Skipping rotation-recovery row with no persistent reference (account \(account, privacy: .public))."
                )
                continue
            }

            var readQuery = ClaudeRotationRecoveryKeychainQuery.pinnedRead(
                service: service,
                account: account,
                persistentReference: persistentReference,
                accessMode: accessMode
            )
            if let keychain {
                readQuery[kSecMatchSearchList as String] = [keychain]
            }
            CredentialAccess.recordKeychainDataRead()
            var dataResult: CFTypeRef?
            let readStatus = operations.copyMatching(
                readQuery as CFDictionary,
                &dataResult
            )
            if readStatus == errSecItemNotFound {
                // The item was deleted or replaced after inventory. A later
                // load observes the replacement without broadening this read.
                continue
            }
            guard readStatus == errSecSuccess else {
                throw CredentialStoreError.keychainError(readStatus)
            }
            guard let data = dataResult as? Data else {
                AppLog.credentials.error(
                    "Skipping rotation-recovery row with no value data (account \(account, privacy: .public))."
                )
                continue
            }
            do {
                let record = try decoder.decode(ClaudeRotationRecoveryRecord.self, from: data)
                if account != record.id.uuidString {
                    AppLog.credentials.error(
                        "Skipping rotation-recovery row whose keychain account \(account, privacy: .public) does not match its record id."
                    )
                    continue
                }
                records.append(record)
            } catch {
                AppLog.credentials.error(
                    "Skipping undecodable rotation-recovery row (account \(account, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return records.sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(id: UUID, accessMode: CredentialAccessMode) throws {
        try validateCredentialAccess()
        CredentialAccess.recordKeychainWrite()
        let status = SecItemDelete(
            baseQuery(account: id.uuidString, accessMode: accessMode) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    private func baseQuery(
        account: String?,
        accessMode: CredentialAccessMode
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationContext as String:
                CredentialAccess.authenticationContext(for: accessMode)
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    private func validateCredentialAccess() throws {
        do {
            try validateAccess()
        } catch {
            throw CredentialStoreError.credentialAccessUnavailable(underlying: error)
        }
    }
}
