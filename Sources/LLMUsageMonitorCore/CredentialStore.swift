import Foundation
import Security

public enum CredentialStoreError: Error, LocalizedError {
    case encodeFailed
    case decodeFailed(underlying: Error?)
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "Could not encode the credential snapshot."
        case .decodeFailed(let underlying):
            let reason = underlying?.localizedDescription ?? "the data is not in the expected format"
            return "Could not decode the saved credentials (\(reason))."
        case .keychainError(let status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

public protocol CredentialStoreProtocol {
    func save(snapshot: CredentialSnapshot, for accountID: UUID) throws
    func loadSnapshot(for accountID: UUID) throws -> CredentialSnapshot?
    func deleteSnapshot(for accountID: UUID) throws
    func hasSnapshot(for accountID: UUID) throws -> Bool
}

public final class KeychainCredentialStore: CredentialStoreProtocol {
    private let service: String
    private let encoder = JSONEncoder.appEncoder
    private let decoder = JSONDecoder.appDecoder

    public init(service: String = "com.johannesberggren.LLMUsageMonitor.credentials") {
        self.service = service
    }

    public func save(snapshot: CredentialSnapshot, for accountID: UUID) throws {
        guard let data = try? encoder.encode(snapshot) else {
            throw CredentialStoreError.encodeFailed
        }

        var addQuery = baseQuery(accountID: accountID)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(accountID: accountID) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.keychainError(updateStatus)
            }
            return
        }

        throw CredentialStoreError.keychainError(addStatus)
    }

    public func loadSnapshot(for accountID: UUID) throws -> CredentialSnapshot? {
        var query = baseQuery(accountID: accountID)
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

    public func deleteSnapshot(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainError(status)
        }
    }

    public func hasSnapshot(for accountID: UUID) throws -> Bool {
        var query = baseQuery(accountID: accountID)
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

    private func baseQuery(accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString
        ]
    }
}
