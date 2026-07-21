import Security
import XCTest
@testable import LimitLifeboatCore

final class KeychainCredentialStoreTests: XCTestCase {
    func testNestedWorkflowCountersReuseOutermostOwner() {
        var innerOwnsScope = true
        let counts = CredentialAccess.withWorkflowCounter { outer, outerOwnsScope in
            XCTAssertTrue(outerOwnsScope)
            CredentialAccess.recordKeychainMetadataRead()
            CredentialAccess.withWorkflowCounter { inner, ownsScope in
                innerOwnsScope = ownsScope
                XCTAssertTrue(inner === outer)
                CredentialAccess.recordKeychainDataRead()
                CredentialAccess.recordKeychainWrite()
            }
            return outer.snapshot
        }

        XCTAssertFalse(innerOwnsScope)
        XCTAssertEqual(
            counts,
            CredentialKeychainIOCounts(metadataReads: 1, dataReads: 1, writes: 1)
        )
    }

    func testIndependentWorkflowDoesNotAppendToParentCounter() {
        let parentCounts = CredentialAccess.withWorkflowCounter { parent, _ in
            CredentialAccess.recordKeychainDataRead()
            CredentialAccess.independentWorkflow {
                CredentialAccess.recordKeychainWrite()
            }
            return parent.snapshot
        }

        XCTAssertEqual(
            parentCounts,
            CredentialKeychainIOCounts(metadataReads: 0, dataReads: 1, writes: 0)
        )
    }

    func testSaveUpdatesExistingItemWithoutTryingAdd() throws {
        var calls: [String] = []
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { _, _ in
                    calls.append("update")
                    return errSecSuccess
                },
                add: { _ in
                    calls.append("add")
                    return errSecSuccess
                }
            )
        )

        try store.save(snapshot: testSnapshot(), for: UUID())

        XCTAssertEqual(calls, ["update"])
    }

    func testSaveAddsOnlyAfterUpdateReportsNotFound() throws {
        var calls: [String] = []
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { _, _ in
                    calls.append("update")
                    return errSecItemNotFound
                },
                add: { _ in
                    calls.append("add")
                    return errSecSuccess
                }
            )
        )

        try store.save(snapshot: testSnapshot(), for: UUID())

        XCTAssertEqual(calls, ["update", "add"])
    }

    func testInsertIfAbsentUsesOneAtomicAdd() throws {
        var calls: [String] = []
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { _, _ in
                    calls.append("update")
                    return errSecSuccess
                },
                add: { _ in
                    calls.append("add")
                    return errSecSuccess
                }
            )
        )
        let counter = CredentialKeychainIOCounter()

        let inserted = try CredentialAccess.counting(counter) {
            try store.insertSnapshotIfAbsent(
                testSnapshot(),
                for: UUID(),
                accessMode: .nonInteractive
            )
        }

        XCTAssertTrue(inserted)
        XCTAssertEqual(calls, ["add"])
        XCTAssertEqual(
            counter.snapshot,
            CredentialKeychainIOCounts(metadataReads: 0, dataReads: 0, writes: 1)
        )
    }

    func testInsertIfAbsentReportsDuplicateWithoutOverwriting() throws {
        var calls: [String] = []
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { _, _ in
                    calls.append("update")
                    return errSecSuccess
                },
                add: { _ in
                    calls.append("add")
                    return errSecDuplicateItem
                }
            )
        )

        XCTAssertFalse(
            try store.insertSnapshotIfAbsent(
                testSnapshot(),
                for: UUID(),
                accessMode: .nonInteractive
            )
        )
        XCTAssertEqual(calls, ["add"])
    }

    func testRevisionCASMatchesOpaqueAttributeWithoutReadingSecretData() throws {
        let expected = CredentialStoreRevision(rawValue: Data("expected-revision".utf8))
        var capturedQuery: [String: Any] = [:]
        var capturedAttributes: [String: Any] = [:]
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { query, attributes in
                    capturedQuery = query as NSDictionary as? [String: Any] ?? [:]
                    capturedAttributes = attributes as NSDictionary as? [String: Any] ?? [:]
                    return errSecSuccess
                },
                add: { _ in XCTFail("CAS must never add a missing item"); return errSecSuccess }
            )
        )
        let counter = CredentialKeychainIOCounter()

        let newRevision = try CredentialAccess.counting(counter) {
            try store.replaceSnapshot(
                testSnapshot(),
                for: UUID(),
                ifRevisionMatches: expected,
                accessMode: .nonInteractive
            )
        }

        XCTAssertNotNil(newRevision)
        XCTAssertEqual(capturedQuery[kSecAttrGeneric as String] as? Data, expected.rawValue)
        XCTAssertNotNil(capturedAttributes[kSecValueData as String] as? Data)
        XCTAssertEqual(
            capturedAttributes[kSecAttrGeneric as String] as? Data,
            newRevision?.rawValue
        )
        XCTAssertNotEqual(newRevision, expected)
        XCTAssertEqual(
            counter.snapshot,
            CredentialKeychainIOCounts(metadataReads: 0, dataReads: 0, writes: 1)
        )
    }

    func testRevisionCASReportsConflictWithoutAdding() throws {
        var addCalled = false
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { _, _ in errSecItemNotFound },
                add: { _ in addCalled = true; return errSecSuccess }
            )
        )

        XCTAssertNil(
            try store.replaceSnapshot(
                testSnapshot(),
                for: UUID(),
                ifRevisionMatches: CredentialStoreRevision(rawValue: Data("stale".utf8)),
                accessMode: .nonInteractive
            )
        )
        XCTAssertFalse(addCalled)
    }

    func testCredentialWorkflowCounterTracksWritesWithoutIdentifiers() throws {
        let counter = CredentialKeychainIOCounter()
        let store = KeychainCredentialStore(
            service: "unused",
            operations: KeychainCredentialStoreOperations(
                update: { _, _ in errSecItemNotFound },
                add: { _ in errSecSuccess }
            )
        )

        try CredentialAccess.counting(counter) {
            try store.save(snapshot: testSnapshot(), for: UUID())
        }

        XCTAssertEqual(
            counter.snapshot,
            CredentialKeychainIOCounts(metadataReads: 0, dataReads: 0, writes: 2)
        )
    }

    func testCredentialAccessDefaultsToNonInteractiveContext() {
        XCTAssertEqual(CredentialAccess.currentMode, .nonInteractive)
        XCTAssertTrue(
            CredentialAccess.authenticationContext(for: .nonInteractive).interactionNotAllowed
        )
    }

    func testUserInitiatedCredentialAccessReusesInteractiveContext() {
        CredentialAccess.userInitiated(reason: "test credentials") {
            let first = CredentialAccess.authenticationContext(for: .userInitiated)
            let second = CredentialAccess.authenticationContext(for: .userInitiated)

            XCTAssertEqual(CredentialAccess.currentMode, .userInitiated)
            XCTAssertFalse(first.interactionNotAllowed)
            XCTAssertTrue(first === second)
            XCTAssertEqual(first.localizedReason, "test credentials")
        }
        XCTAssertEqual(CredentialAccess.currentMode, .nonInteractive)
    }

    func testNonInteractivePollOverridesInheritedUserInitiatedContext() async {
        let observedModes = await CredentialAccess.userInitiated(reason: "login button") {
            let inheritedMode = CredentialAccess.currentMode
            let watcher = Task {
                await CredentialAccess.nonInteractive {
                    CredentialAccess.currentMode
                }
            }
            let watcherMode = await watcher.value
            return [inheritedMode, watcherMode, CredentialAccess.currentMode]
        }

        XCTAssertEqual(observedModes, [.userInitiated, .nonInteractive, .userInitiated])
        XCTAssertEqual(CredentialAccess.currentMode, .nonInteractive)
    }

    func testStaleCodeIdentityErrorsTellUserToRelaunch() {
        for status in [errSecCSStaticCodeNotFound, errSecCSStaticCodeChanged] {
            let error = CredentialStoreError.keychainError(status)
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("\(status)"), "Keeps the raw status for support")
            XCTAssertTrue(description.localizedCaseInsensitiveContains("relaunch"))
            XCTAssertTrue(error.isKeychainAccessDenied)
        }
    }

    func testSaveLoadUpdateAndDeleteSnapshot() throws {
        let disposable = try DisposableKeychainTestSupport()
        let store = KeychainCredentialStore(
            service: "com.limitlifeboat.app.tests.\(UUID().uuidString)",
            keychain: disposable.keychain
        )
        let accountID = UUID()

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

    func testDisposableKeychainRevisionCASPreservesNewerGeneration() throws {
        let disposable = try DisposableKeychainTestSupport()
        let store = KeychainCredentialStore(
            service: "com.limitlifeboat.app.tests.\(UUID().uuidString)",
            keychain: disposable.keychain
        )
        let accountID = UUID()
        let first = CredentialSnapshot(
            provider: .codex,
            capturedAt: Date(timeIntervalSince1970: 1),
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .fullFile,
                    contents: Data("one".utf8),
                    posixPermissions: 0o600
                )
            ]
        )
        let second = CredentialSnapshot(
            provider: .codex,
            capturedAt: Date(timeIntervalSince1970: 2),
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .fullFile,
                    contents: Data("two".utf8),
                    posixPermissions: 0o600
                )
            ]
        )
        let staleOverwrite = CredentialSnapshot(
            provider: .codex,
            capturedAt: Date(timeIntervalSince1970: 3),
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .fullFile,
                    contents: Data("stale".utf8),
                    posixPermissions: 0o600
                )
            ]
        )

        try store.save(snapshot: first, for: accountID)
        let loaded = try XCTUnwrap(store.loadVersionedSnapshot(for: accountID))
        let firstRevision = try XCTUnwrap(loaded.revision)
        let secondRevision = try XCTUnwrap(
            store.replaceSnapshot(
                second,
                for: accountID,
                ifRevisionMatches: firstRevision
            )
        )
        XCTAssertNotEqual(secondRevision, firstRevision)

        XCTAssertNil(
            try store.replaceSnapshot(
                staleOverwrite,
                for: accountID,
                ifRevisionMatches: firstRevision
            )
        )
        XCTAssertEqual(try store.loadSnapshot(for: accountID), second)
    }

    func testDisposableKeychainInsertIfAbsentPreservesExistingSnapshot() throws {
        let disposable = try DisposableKeychainTestSupport()
        let store = KeychainCredentialStore(
            service: "com.limitlifeboat.app.tests.\(UUID().uuidString)",
            keychain: disposable.keychain
        )
        let accountID = UUID()
        let first = CredentialSnapshot(
            provider: .codex,
            capturedAt: Date(timeIntervalSince1970: 1),
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .fullFile,
                    contents: Data("first".utf8),
                    posixPermissions: 0o600
                )
            ]
        )
        let conflicting = CredentialSnapshot(
            provider: .codex,
            capturedAt: Date(timeIntervalSince1970: 2),
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .fullFile,
                    contents: Data("conflicting".utf8),
                    posixPermissions: 0o600
                )
            ]
        )

        XCTAssertTrue(try store.insertSnapshotIfAbsent(first, for: accountID))
        XCTAssertFalse(
            try store.insertSnapshotIfAbsent(conflicting, for: accountID)
        )
        XCTAssertEqual(try store.loadSnapshot(for: accountID), first)
    }

    func testLoadSnapshotThrowsDecodeFailedForUnreadableData() throws {
        let disposable = try DisposableKeychainTestSupport()
        let service = "com.limitlifeboat.app.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service, keychain: disposable.keychain)
        let accountID = UUID()

        // Simulate a snapshot written by an older/incompatible build: valid
        // Keychain item, but its bytes are not a current CredentialSnapshot.
        let garbage = Data("not a credential snapshot".utf8)
        try disposable.addGenericPassword(
            data: garbage,
            service: service,
            account: accountID.uuidString
        )

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

    func testIntegrityFailureIsAnActionableAccessDenial() {
        let expected = RunningExecutableIntegrityError.unavailable(path: "/tmp/missing/LimitLifeboat")
        let store = KeychainCredentialStore(
            service: "unused",
            validateAccess: { throw expected }
        )

        XCTAssertThrowsError(try store.hasSnapshot(for: UUID())) { error in
            guard let storeError = error as? CredentialStoreError,
                  case .credentialAccessUnavailable(let underlying) = storeError else {
                return XCTFail("Expected credentialAccessUnavailable, got \(error)")
            }
            XCTAssertEqual(underlying as? RunningExecutableIntegrityError, expected)
            XCTAssertTrue(storeError.isKeychainAccessDenied)
            XCTAssertTrue(storeError.localizedDescription.contains("relaunch"))
        }
    }

    func testOrdinaryKeychainStatusKeepsGenericMessageAndIsNotAccessDenied() {
        let error = CredentialStoreError.keychainError(errSecItemNotFound)

        XCTAssertEqual(error.localizedDescription, "Keychain operation failed with status \(errSecItemNotFound).")
        XCTAssertFalse(error.isKeychainAccessDenied)
    }

    private func testSnapshot() -> CredentialSnapshot {
        CredentialSnapshot(
            provider: .codex,
            capturedAt: Date(timeIntervalSince1970: 1),
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .fullFile,
                    contents: Data("test".utf8),
                    posixPermissions: 0o600
                )
            ]
        )
    }
}
