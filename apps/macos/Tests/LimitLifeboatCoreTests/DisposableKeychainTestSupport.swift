import Foundation
import Security
@testable import LimitLifeboatCore

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

    /// Test setup only: creates an item with the same `/usr/bin/security`
    /// identity Claude Code uses. Production never calls the backend without
    /// an already-resolved item and exact pre/post generation checks.
    func addGenericPasswordUsingSecurityTool(
        data: Data,
        service: String,
        account: String,
        label: String? = nil
    ) throws {
        let location = ClaudeKeychainItemLocation(
            serviceName: service,
            accountName: account,
            keychainPath: path,
            persistentReference: Data("test-setup".utf8),
            creationDate: Date(),
            modificationDate: Date(),
            label: label
        )
        try ClaudeSecurityToolCredentialBackend().updateData(
            data,
            at: location,
            accessMode: .userInitiated,
            authorizeAccess: { _ in },
            verifyBefore: { true },
            verifyAfter: { true }
        )
    }
}

/// Disposable legacy Keychains do not expose the protected partition ACL used
/// by the login Keychain. Tests can still exercise exact discovery and the
/// real security-tool data path by overriding only that metadata result.
struct AssumeSecurityToolReadyMetadataClient: ClaudeKeychainSecurityClient {
    let base: SystemClaudeKeychainSecurityClient

    func locateItems(
        serviceName: String,
        accountName: String,
        accessMode: CredentialAccessMode
    ) throws -> [ClaudeKeychainItemLocation] {
        try base.locateItems(
            serviceName: serviceName,
            accountName: accountName,
            accessMode: accessMode
        )
    }

    func securityToolAccessStatus(
        at location: ClaudeKeychainItemLocation
    ) throws -> ClaudeSecurityToolAccessStatus {
        .ready
    }
}
