import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import LimitLifeboatCore

final class ClaudeRotationRecoveryStoreTests: XCTestCase {
    func testInventoryQueryNeverRequestsSecretData() {
        let query = ClaudeRotationRecoveryKeychainQuery.inventory(
            service: "test.recovery",
            accessMode: .nonInteractive
        )

        XCTAssertEqual(query[kSecAttrService as String] as? String, "test.recovery")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnPersistentRef as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertNil(query[kSecMatchItemList as String])
        XCTAssertTrue(cfEqual(query[kSecMatchLimit as String], kSecMatchLimitAll))
        XCTAssertEqual(
            (query[kSecUseAuthenticationContext as String] as? LAContext)?
                .interactionNotAllowed,
            true
        )
    }

    func testPinnedReadQueryUsesOnePersistentItem() throws {
        let reference = Data("persistent-reference".utf8)
        let query = ClaudeRotationRecoveryKeychainQuery.pinnedRead(
            service: "test.recovery",
            account: "record-id",
            persistentReference: reference,
            accessMode: .nonInteractive
        )

        XCTAssertEqual(query[kSecAttrService as String] as? String, "test.recovery")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "record-id")
        XCTAssertEqual(
            try XCTUnwrap(query[kSecMatchItemList as String] as? [Data]),
            [reference]
        )
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnAttributes as String])
        XCTAssertNil(query[kSecReturnPersistentRef as String])
        XCTAssertTrue(cfEqual(query[kSecMatchLimit as String], kSecMatchLimitOne))
    }

    func testEmptyDisposableKeychainLoadsWithoutInvalidParameterError() throws {
        let disposable = try DisposableKeychainTestSupport()
        let store = makeStore(disposable: disposable)
        let counter = CredentialKeychainIOCounter()

        let records = try CredentialAccess.counting(counter) {
            try store.loadAll(accessMode: .nonInteractive)
        }

        XCTAssertEqual(records, [])
        XCTAssertEqual(
            counter.snapshot,
            CredentialKeychainIOCounts(metadataReads: 1, dataReads: 0, writes: 0)
        )
    }

    func testMultipleRecordsRoundTripInCreationOrderAndCountPinnedReads() throws {
        let disposable = try DisposableKeychainTestSupport()
        let store = makeStore(disposable: disposable)
        let later = makeRecord(createdAt: Date(timeIntervalSince1970: 20), token: "later")
        let earlier = makeRecord(createdAt: Date(timeIntervalSince1970: 10), token: "earlier")
        try store.save(later, accessMode: .nonInteractive)
        try store.save(earlier, accessMode: .nonInteractive)

        let counter = CredentialKeychainIOCounter()
        let records = try CredentialAccess.counting(counter) {
            try store.loadAll(accessMode: .nonInteractive)
        }

        XCTAssertEqual(records, [earlier, later])
        XCTAssertEqual(
            counter.snapshot,
            CredentialKeychainIOCounts(metadataReads: 1, dataReads: 2, writes: 0)
        )
    }

    func testUpdateAndDeletePreserveJournalIdentity() throws {
        let disposable = try DisposableKeychainTestSupport()
        let store = makeStore(disposable: disposable)
        let original = makeRecord(createdAt: Date(timeIntervalSince1970: 10), token: "old")
        var updated = original
        updated.oauthJSON = Data(#"{"accessToken":"new"}"#.utf8)
        updated.freshChainFingerprint = "fresh-new"

        try store.save(original, accessMode: .nonInteractive)
        try store.save(updated, accessMode: .nonInteractive)
        XCTAssertEqual(try store.loadAll(accessMode: .nonInteractive), [updated])

        try store.delete(id: original.id, accessMode: .nonInteractive)
        XCTAssertEqual(try store.loadAll(accessMode: .nonInteractive), [])
        XCTAssertNoThrow(
            try store.delete(id: original.id, accessMode: .nonInteractive)
        )
    }

    func testMalformedAndMismatchedRowsDoNotHideHealthyRecords() throws {
        let disposable = try DisposableKeychainTestSupport()
        let service = "test.recovery.\(UUID().uuidString)"
        let store = KeychainClaudeRotationRecoveryStore(
            service: service,
            keychain: disposable.keychain
        )
        let healthy = makeRecord(createdAt: Date(timeIntervalSince1970: 30), token: "healthy")
        try store.save(healthy, accessMode: .nonInteractive)

        try disposable.addGenericPassword(
            data: Data("not-json".utf8),
            service: service,
            account: UUID().uuidString
        )
        let mismatched = makeRecord(
            createdAt: Date(timeIntervalSince1970: 40),
            token: "mismatch"
        )
        try disposable.addGenericPassword(
            data: try JSONEncoder.appEncoder.encode(mismatched),
            service: service,
            account: UUID().uuidString
        )

        XCTAssertEqual(try store.loadAll(accessMode: .nonInteractive), [healthy])
    }

    func testRecordDeletedBetweenInventoryAndPinnedReadIsBenign() throws {
        let disposable = try DisposableKeychainTestSupport()
        let service = "test.recovery.\(UUID().uuidString)"
        let record = makeRecord(
            createdAt: Date(timeIntervalSince1970: 50),
            token: "deleted-race"
        )
        let writer = KeychainClaudeRotationRecoveryStore(
            service: service,
            keychain: disposable.keychain
        )
        try writer.save(record, accessMode: .nonInteractive)

        var copyCount = 0
        let reader = KeychainClaudeRotationRecoveryStore(
            service: service,
            keychain: disposable.keychain,
            operations: KeychainClaudeRotationRecoveryStoreOperations(
                copyMatching: { query, result in
                    copyCount += 1
                    if copyCount == 2 {
                        let deleteStatus = SecItemDelete([
                            kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: record.id.uuidString,
                            kSecMatchSearchList as String: [disposable.keychain]
                        ] as CFDictionary)
                        XCTAssertEqual(deleteStatus, errSecSuccess)
                    }
                    return SecItemCopyMatching(query, result)
                }
            )
        )
        let counter = CredentialKeychainIOCounter()

        let records = try CredentialAccess.counting(counter) {
            try reader.loadAll(accessMode: .nonInteractive)
        }

        XCTAssertEqual(records, [])
        XCTAssertEqual(copyCount, 2)
        XCTAssertEqual(
            counter.snapshot,
            CredentialKeychainIOCounts(metadataReads: 1, dataReads: 1, writes: 0)
        )
    }

    private func makeStore(
        disposable: DisposableKeychainTestSupport
    ) -> KeychainClaudeRotationRecoveryStore {
        KeychainClaudeRotationRecoveryStore(
            service: "test.recovery.\(UUID().uuidString)",
            keychain: disposable.keychain
        )
    }

    private func makeRecord(
        createdAt: Date,
        token: String
    ) -> ClaudeRotationRecoveryRecord {
        ClaudeRotationRecoveryRecord(
            createdAt: createdAt,
            staleChainFingerprint: "stale-\(token)",
            freshChainFingerprint: "fresh-\(token)",
            oauthJSON: Data(#"{"accessToken":"\#(token)"}"#.utf8),
            pendingDestinations: [.liveClaudeCode],
            phase: .freshGeneration
        )
    }

    private func cfEqual(_ lhs: Any?, _ rhs: CFTypeRef) -> Bool {
        guard let lhs else { return false }
        return CFEqual(lhs as CFTypeRef, rhs)
    }
}
