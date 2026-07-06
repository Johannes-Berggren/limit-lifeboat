import Foundation
import Security

/// Access to other apps' macOS Keychain generic passwords — used to capture
/// and restore Claude Code's token item, which lives in the Keychain rather
/// than in a dotfile. Reading another app's item triggers a one-time macOS
/// permission prompt ("Always Allow" persists the grant).
public protocol SystemKeychainProtocol {
    func readItem(service: String) throws -> (account: String, data: Data)?
    func writeItem(service: String, account: String, data: Data) throws
    func deleteItem(service: String, account: String) throws
}

public enum SystemKeychainError: Error, LocalizedError {
    case readFailed(service: String, status: OSStatus)
    case writeFailed(service: String, status: OSStatus)
    case deleteFailed(service: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let service, let status):
            return "Could not read Keychain item \"\(service)\" (status \(status)). Grant access when macOS asks, ideally with Always Allow."
        case .writeFailed(let service, let status):
            return "Could not write Keychain item \"\(service)\" (status \(status))."
        case .deleteFailed(let service, let status):
            return "Could not delete Keychain item \"\(service)\" (status \(status))."
        }
    }
}

public struct SystemKeychain: SystemKeychainProtocol {
    public init() {}

    public func readItem(service: String) throws -> (account: String, data: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else {
            throw SystemKeychainError.readFailed(service: service, status: status)
        }

        let account = attributes[kSecAttrAccount as String] as? String ?? NSUserName()
        return (account, data)
    }

    public func writeItem(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Update in place so the item keeps its existing access control list
        // (the owning CLI stays able to read it without a new prompt).
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SystemKeychainError.writeFailed(service: service, status: status)
        }
    }

    public func deleteItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SystemKeychainError.deleteFailed(service: service, status: status)
        }
    }
}
