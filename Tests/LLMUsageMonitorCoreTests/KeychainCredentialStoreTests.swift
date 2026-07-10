import Security
import XCTest
@testable import LLMUsageMonitorCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testStaleCodeIdentityErrorsTellUserToRelaunch() {
        let expected = "The running copy of LLM Usage Monitor was moved, replaced, or deleted after launch, so macOS can no longer authorize Keychain access. Quit and reopen the app, then try again."

        for status in [errSecCSStaticCodeNotFound, errSecCSStaticCodeChanged] {
            let error = CredentialStoreError.keychainError(status)
            XCTAssertEqual(error.localizedDescription, expected)
        }
    }

    func testOtherKeychainErrorsKeepNumericFallback() {
        let error = CredentialStoreError.keychainError(errSecAuthFailed)

        XCTAssertEqual(
            error.localizedDescription,
            "Keychain operation failed with status \(errSecAuthFailed)."
        )
    }

    func testSaveLoadUpdateAndDeleteSnapshot() throws {
        let store = KeychainCredentialStore(service: "com.johannesberggren.LLMUsageMonitor.tests.\(UUID().uuidString)")
        let accountID = UUID()
        defer { try? store.deleteSnapshot(for: accountID) }

        let first = CredentialSnapshot(provider: .codex, capturedAt: Date(timeIntervalSince1970: 1), items: [
            CredentialSnapshotItem(relativePath: ".codex/auth.json", kind: .fullFile, contents: Data("one".utf8), posixPermissions: 0o600)
        ])
        try store.save(snapshot: first, for: accountID)

        XCTAssertTrue(try store.hasSnapshot(for: accountID))
        XCTAssertEqual(try store.loadSnapshot(for: accountID), first)

        let second = CredentialSnapshot(provider: .codex, capturedAt: Date(timeIntervalSince1970: 2), items: [
            CredentialSnapshotItem(relativePath: ".codex/auth.json", kind: .fullFile, contents: Data("two".utf8), posixPermissions: 0o600)
        ])
        try store.save(snapshot: second, for: accountID)
        XCTAssertEqual(try store.loadSnapshot(for: accountID), second)

        try store.deleteSnapshot(for: accountID)
        XCTAssertFalse(try store.hasSnapshot(for: accountID))
        XCTAssertNil(try store.loadSnapshot(for: accountID))
    }

    func testLoadSnapshotThrowsDecodeFailedForUnreadableData() throws {
        let service = "com.johannesberggren.LLMUsageMonitor.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let accountID = UUID()
        defer { try? store.deleteSnapshot(for: accountID) }

        // Simulate a snapshot written by an older/incompatible build: valid
        // Keychain item, but its bytes are not a current CredentialSnapshot.
        let garbage = Data("not a credential snapshot".utf8)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecValueData as String: garbage,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)

        // The item exists, so hasSnapshot is true — this is why the switch UI
        // reaches loadSnapshot instead of the missing-credentials path.
        XCTAssertTrue(try store.hasSnapshot(for: accountID))

        XCTAssertThrowsError(try store.loadSnapshot(for: accountID)) { error in
            guard let storeError = error as? CredentialStoreError,
                  case .decodeFailed(let underlying) = storeError else {
                return XCTFail("Expected CredentialStoreError.decodeFailed, got \(error)")
            }
            XCTAssertNotNil(underlying, "Decode failure should carry the underlying decoding error")
        }
    }
}
