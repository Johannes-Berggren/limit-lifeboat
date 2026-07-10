import Security
import XCTest
@testable import LLMUsageMonitorCore

final class KeychainCredentialStoreTests: XCTestCase {
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

    func testCodeSigningStatusYieldsActionableRelaunchMessage() {
        // -67068 = errSecCSStaticCodeNotFound: the running copy was deleted or
        // rebuilt out from under the process, so the Keychain can't authorize
        // the item. The message must name the cause and the fix, not a bare code.
        let error = CredentialStoreError.keychainError(-67068)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("-67068"), "Keeps the raw status for support")
        XCTAssertTrue(description.localizedCaseInsensitiveContains("relaunch"),
                      "Tells the user to relaunch; was: \(description)")
        XCTAssertTrue(error.isKeychainAccessDenied,
                      "Code-signing failures are recoverable access errors, not a missing item")
    }

    func testOrdinaryKeychainStatusKeepsGenericMessageAndIsNotAccessDenied() {
        let error = CredentialStoreError.keychainError(errSecItemNotFound)
        XCTAssertEqual(error.errorDescription, "Keychain operation failed with status \(errSecItemNotFound).")
        XCTAssertFalse(error.isKeychainAccessDenied)
    }
}
