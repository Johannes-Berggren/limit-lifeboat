import Foundation
import Security

/// A throwaway legacy Keychain scoped explicitly into integration queries.
/// It is never installed as the user's default or added to their search list.
final class DisposableKeychainTestSupport {
    let directory: URL
    let path: String
    let password: String
    let keychain: SecKeychain

    init() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitLifeboat-disposable-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryPath = temporaryDirectory.appendingPathComponent("integration.keychain-db").path
        let temporaryPassword = UUID().uuidString

        var created: SecKeychain?
        let status = temporaryPassword.withCString { passwordPointer in
            SecKeychainCreate(
                temporaryPath,
                UInt32(strlen(passwordPointer)),
                passwordPointer,
                false,
                nil,
                &created
            )
        }
        guard status == errSecSuccess, let created else {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        directory = temporaryDirectory
        path = temporaryPath
        password = temporaryPassword
        keychain = created
    }

    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: directory)
    }

    func addGenericPassword(data: Data, service: String, account: String) throws {
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecUseKeychain as String: keychain
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
