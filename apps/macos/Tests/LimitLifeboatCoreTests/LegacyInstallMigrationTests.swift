import Foundation
import XCTest
@testable import LimitLifeboatCore

final class LegacyInstallMigrationTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var legacyDefaultsDomain: String!

    override func setUpWithError() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let canonicalTemporaryDirectory = temporaryDirectory.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporaryDirectory.path, isDirectory: true)
            : temporaryDirectory.resolvingSymlinksInPath()
        base = canonicalTemporaryDirectory
            .appendingPathComponent("LimitLifeboatMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)

        defaultsSuite = "com.limitlifeboat.tests.destination.\(UUID().uuidString)"
        legacyDefaultsDomain = "com.limitlifeboat.tests.legacy.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults.removePersistentDomain(forName: legacyDefaultsDomain)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: defaultsSuite)
        defaults?.removePersistentDomain(forName: legacyDefaultsDomain)
        try? FileManager.default.removeItem(at: base)
    }

    func testSuccessfulMigrationPreservesFilesRelationshipsDefaultsAndCredentials() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let credentialProfile = AccountProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            provider: .claude,
            label: "Claude Work",
            webDataStoreID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            createdAt: date,
            updatedAt: date
        )
        let missingCredentialProfile = AccountProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            provider: .codex,
            label: "Codex Personal",
            webDataStoreID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            createdAt: date,
            updatedAt: date
        )
        let profiles = [credentialProfile, missingCredentialProfile]
        let snapshots = profiles.map {
            UsageSnapshot(
                accountID: $0.id,
                provider: $0.provider,
                windows: [
                    UsageWindow(
                        id: "session",
                        kind: .session,
                        label: "Session",
                        usedPercent: $0.provider == .claude ? 42 : 17
                    )
                ],
                source: "migration-test",
                lastRefreshed: date,
                parseConfidence: .high
            )
        }
        let history = profiles.map {
            UsageHistoryRecord(
                timestamp: date,
                accountID: $0.id,
                windows: [UsageWindowReading(id: "session", kind: .session, usedPercent: 25)]
            )
        }
        let backupBytes = Data("provider-owned backup bytes".utf8)
        try writeLegacyTree(
            profiles: profiles,
            snapshots: snapshots,
            history: history,
            backupRelativePath: "Backups/claude/session.json",
            backupData: backupBytes
        )
        let unownedFile = base
            .appendingPathComponent(LegacyInstallIdentity.applicationSupportName, isDirectory: true)
            .appendingPathComponent("third-party-note.txt")
        try Data("not owned by the app".utf8).write(to: unownedFile)

        defaults.setPersistentDomain(
            [
                "refreshIntervalMinutes": 15,
                "usageAlertsEnabled": true,
                "showOrganizationNames": false,
                "notifiedPaceAlerts": ["already-shown"],
                "lastUpdateCheck": date,
                "unknownLegacySetting": "do-not-copy",
            ],
            forName: legacyDefaultsDomain
        )
        defaults.set(30, forKey: "refreshIntervalMinutes")

        let legacySnapshot = makeCredentialSnapshot(provider: .claude, marker: "legacy-claude")
        let oldStore = FakeCredentialStore(snapshots: [credentialProfile.id: legacySnapshot])
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let preflight = try migrator.inspect()
        XCTAssertFalse(preflight.isComplete)
        XCTAssertTrue(preflight.requiresMigration)
        XCTAssertFalse(preflight.hasDestinationConflict)
        XCTAssertEqual(preflight.profileCount, 2)
        XCTAssertTrue(oldStore.allCalls.isEmpty, "Inspection must never access legacy credentials")
        XCTAssertTrue(newStore.allCalls.isEmpty, "Inspection must never access destination credentials")

        let summary = try migrator.migrate()

        XCTAssertEqual(summary, LegacyMigrationSummary(profileCount: 2, credentialCount: 1, profilesNeedingLogin: 1))
        XCTAssertEqual(newStore.snapshots[credentialProfile.id], legacySnapshot)
        XCTAssertNil(newStore.snapshots[missingCredentialProfile.id])
        XCTAssertEqual(oldStore.loadCalls.map(\.mode), [.userInitiated, .userInitiated])
        XCTAssertEqual(newStore.loadCalls.map(\.mode), [.userInitiated, .userInitiated])
        XCTAssertEqual(newStore.saveCalls.map(\.mode), [.userInitiated])

        let destination = migrator.destinationRoot
        XCTAssertEqual(try decode([AccountProfile].self, at: destination.appendingPathComponent("profiles.json")), profiles)
        XCTAssertEqual(try decode([UsageSnapshot].self, at: destination.appendingPathComponent("usage-snapshots.json")), snapshots)
        XCTAssertEqual(try decodeHistory(at: destination.appendingPathComponent("usage-history.jsonl")), history)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("Backups/claude/session.json")),
            backupBytes
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".migration-v1-complete").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("third-party-note.txt").path),
            "Unknown files must stay with the legacy installation instead of being adopted"
        )

        let legacy = migrator.legacyRoot
        XCTAssertEqual(try decode([AccountProfile].self, at: legacy.appendingPathComponent("profiles.json")), profiles)
        XCTAssertEqual(
            try Data(contentsOf: legacy.appendingPathComponent("Backups/claude/session.json")),
            backupBytes,
            "Migration must retain the complete legacy source tree"
        )
        XCTAssertEqual(try Data(contentsOf: unownedFile), Data("not owned by the app".utf8))

        XCTAssertEqual(defaults.integer(forKey: "refreshIntervalMinutes"), 30, "New settings win over legacy values")
        XCTAssertTrue(defaults.bool(forKey: "usageAlertsEnabled"))
        XCTAssertEqual(defaults.object(forKey: "showOrganizationNames") as? Bool, false)
        XCTAssertEqual(defaults.stringArray(forKey: "notifiedPaceAlerts"), ["already-shown"])
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheck"))
        XCTAssertNil(defaults.object(forKey: "unknownLegacySetting"))

        let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((destinationAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let profileAttributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("profiles.json").path
        )
        XCTAssertEqual((profileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingCredentialIsJournaledAsNeedingLoginAndDoesNotWriteDestinationStore() throws {
        let profile = AccountProfile(provider: .codex, label: "No saved credential")
        try writeLegacyTree(profiles: [profile])
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let summary = try migrator.migrate()

        XCTAssertEqual(summary, LegacyMigrationSummary(profileCount: 1, credentialCount: 0, profilesNeedingLogin: 1))
        XCTAssertEqual(oldStore.loadCalls.map(\.accountID), [profile.id])
        XCTAssertEqual(oldStore.loadCalls.map(\.mode), [.userInitiated])
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testDestinationCredentialConflictRetainsSourceAndCanRetryAfterConflictIsResolved() throws {
        let profile = AccountProfile(provider: .claude, label: "Conflicting credential")
        try writeLegacyTree(profiles: [profile])
        let legacySnapshot = makeCredentialSnapshot(provider: .claude, marker: "old")
        let existingSnapshot = makeCredentialSnapshot(provider: .claude, marker: "new-and-different")
        let oldStore = FakeCredentialStore(snapshots: [profile.id: legacySnapshot])
        let newStore = FakeCredentialStore(snapshots: [profile.id: existingSnapshot])
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .credentialConflict(profile.id))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrator.legacyRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))
        XCTAssertEqual(newStore.snapshots[profile.id], existingSnapshot)

        newStore.snapshots.removeValue(forKey: profile.id)
        let summary = try migrator.migrate()

        XCTAssertEqual(
            summary,
            LegacyMigrationSummary(profileCount: 1, credentialCount: 1, profilesNeedingLogin: 0)
        )
        XCTAssertEqual(newStore.snapshots[profile.id], legacySnapshot)
        XCTAssertEqual(oldStore.loadCalls.count, 2, "The conflicted account was not journaled as complete")
        XCTAssertEqual(newStore.saveCalls.count, 1)
    }

    func testProviderMismatchStopsBeforeWritingCredentialOrPromotingFiles() throws {
        let profile = AccountProfile(provider: .claude, label: "Claude")
        try writeLegacyTree(profiles: [profile])
        let oldStore = FakeCredentialStore(
            snapshots: [profile.id: makeCredentialSnapshot(provider: .codex, marker: "wrong-provider")]
        )
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .credentialProviderMismatch(profile.id))
        }

        XCTAssertTrue(newStore.allCalls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrator.legacyRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: migrator.destinationRoot.appendingPathComponent(".migration-v1-complete").path
        ))
    }

    func testCorruptProfilesRetainSourceAndDoNotAccessCredentials() throws {
        let legacyRoot = base.appendingPathComponent(LegacyInstallIdentity.applicationSupportName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let corrupt = Data("{ definitely-not-json".utf8)
        try corrupt.write(to: legacyRoot.appendingPathComponent("profiles.json"))
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()
        XCTAssertTrue(inspection.requiresMigration)
        XCTAssertEqual(inspection.profileCount, 0)
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .invalidLegacyData("profiles.json is unreadable"))
        }

        XCTAssertEqual(try Data(contentsOf: legacyRoot.appendingPathComponent("profiles.json")), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testStartFreshCanAbandonAFileValidationFailureBeforeKeychainAccess() throws {
        let legacyRoot = base.appendingPathComponent(
            LegacyInstallIdentity.applicationSupportName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let corrupt = Data("{ invalid profile data".utf8)
        try corrupt.write(to: legacyRoot.appendingPathComponent("profiles.json"))
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate())
        let inspection = try migrator.inspect()
        XCTAssertTrue(inspection.isInProgress)
        XCTAssertTrue(inspection.canStartFresh)

        try migrator.skipAndStartFresh()

        XCTAssertEqual(try Data(contentsOf: legacyRoot.appendingPathComponent("profiles.json")), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrator.destinationRoot.appendingPathComponent(".migration-v1-skipped").path
        ))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testOrphanedSnapshotAndHistoryRelationshipsAreRejected() throws {
        let profile = AccountProfile(provider: .claude, label: "Valid profile")
        let orphanID = UUID()
        let snapshot = UsageSnapshot(accountID: orphanID, provider: .claude, source: "orphan")
        try writeLegacyTree(profiles: [profile], snapshots: [snapshot])
        let migrator = try makeMigrator(oldStore: FakeCredentialStore(), newStore: FakeCredentialStore())

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("a usage snapshot has no matching profile")
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrator.legacyRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))

        try removeMigrationArtifacts()
        try writeLegacyTree(
            profiles: [profile],
            history: [UsageHistoryRecord(timestamp: Date(), accountID: orphanID, windows: [])]
        )
        let retryMigrator = try makeMigrator(oldStore: FakeCredentialStore(), newStore: FakeCredentialStore())
        XCTAssertThrowsError(try retryMigrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("a usage-history record has no matching profile")
            )
        }
    }

    func testUnreadableSnapshotsAndHistoryAreRejectedBeforeCredentialAccess() throws {
        let profile = AccountProfile(provider: .claude, label: "Valid profile")
        try writeLegacyTree(profiles: [profile])
        let legacyRoot = base.appendingPathComponent(LegacyInstallIdentity.applicationSupportName, isDirectory: true)
        try Data("not-json".utf8).write(to: legacyRoot.appendingPathComponent("usage-snapshots.json"))
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .invalidLegacyData("usage-snapshots.json is unreadable"))
        }
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))

        try removeMigrationArtifacts()
        try writeLegacyTree(profiles: [profile])
        try Data("{ truncated history record".utf8).write(
            to: legacyRoot.appendingPathComponent("usage-history.jsonl")
        )
        let retryOldStore = FakeCredentialStore()
        let retryNewStore = FakeCredentialStore()
        let retryMigrator = try makeMigrator(oldStore: retryOldStore, newStore: retryNewStore)

        XCTAssertThrowsError(try retryMigrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("usage-history.jsonl contains an unreadable record")
            )
        }
        XCTAssertTrue(retryOldStore.allCalls.isEmpty)
        XCTAssertTrue(retryNewStore.allCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retryMigrator.destinationRoot.path))
    }

    func testDuplicateProfileIdentifiersAreRejected() throws {
        let id = UUID()
        try writeLegacyTree(
            profiles: [
                AccountProfile(id: id, provider: .claude, label: "First"),
                AccountProfile(id: id, provider: .claude, label: "Duplicate"),
            ]
        )
        let migrator = try makeMigrator(oldStore: FakeCredentialStore(), newStore: FakeCredentialStore())

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .invalidLegacyData("duplicate profile identifiers"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrator.legacyRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))
    }

    func testDuplicateAndWrongProviderUsageSnapshotsAreRejected() throws {
        let profile = AccountProfile(provider: .claude, label: "Claude")
        let snapshot = UsageSnapshot(accountID: profile.id, provider: .claude, source: "fixture")
        try writeLegacyTree(profiles: [profile], snapshots: [snapshot, snapshot])
        let duplicateMigrator = try makeMigrator(
            oldStore: FakeCredentialStore(),
            newStore: FakeCredentialStore()
        )

        XCTAssertThrowsError(try duplicateMigrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("duplicate usage snapshot identifiers")
            )
        }

        try removeMigrationArtifacts()
        let wrongProvider = UsageSnapshot(
            accountID: profile.id,
            provider: .codex,
            source: "wrong-provider"
        )
        try writeLegacyTree(profiles: [profile], snapshots: [wrongProvider])
        let providerMigrator = try makeMigrator(
            oldStore: FakeCredentialStore(),
            newStore: FakeCredentialStore()
        )

        XCTAssertThrowsError(try providerMigrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("a usage snapshot has the wrong provider")
            )
        }
    }

    func testExistingDestinationIsReportedAsConflictWithoutCredentialAccess() throws {
        let profile = AccountProfile(provider: .claude, label: "Legacy")
        try writeLegacyTree(profiles: [profile])
        let destination = base.appendingPathComponent(LegacyInstallIdentity.currentApplicationSupportName, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("new app data".utf8).write(to: destination.appendingPathComponent("unrelated.json"))
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()

        XCTAssertTrue(inspection.requiresMigration)
        XCTAssertTrue(inspection.hasDestinationConflict)
        XCTAssertEqual(inspection.profileCount, 0, "Inspection must not merge or prefer legacy profiles during a conflict")
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testStartFreshLeavesAllLegacyStateUntouchedAndNeverAccessesCredentials() throws {
        let profile = AccountProfile(provider: .claude, label: "Leave me alone")
        let legacyBytes = Data("legacy backup".utf8)
        try writeLegacyTree(
            profiles: [profile],
            backupRelativePath: "Backups/original.bin",
            backupData: legacyBytes
        )
        defaults.setPersistentDomain(
            ["refreshIntervalMinutes": 10, "lastUpdateCheck": Date()],
            forName: legacyDefaultsDomain
        )
        let oldSnapshot = makeCredentialSnapshot(provider: .claude, marker: "untouched")
        let oldStore = FakeCredentialStore(snapshots: [profile.id: oldSnapshot])
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        try migrator.skipAndStartFresh()

        XCTAssertEqual(oldStore.snapshots[profile.id], oldSnapshot)
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: migrator.legacyRoot.appendingPathComponent("Backups/original.bin")),
            legacyBytes
        )
        XCTAssertNil(defaults.object(forKey: "refreshIntervalMinutes"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrator.destinationRoot.appendingPathComponent(".migration-v1-skipped").path
        ))

        let inspection = try migrator.inspect()
        XCTAssertTrue(inspection.isComplete)
        XCTAssertFalse(inspection.requiresMigration)
        XCTAssertFalse(inspection.hasDestinationConflict)
    }

    func testSymbolicLinkInLegacyTreeIsRejectedWithoutFollowingIt() throws {
        let profile = AccountProfile(provider: .claude, label: "Symlink fixture")
        try writeLegacyTree(profiles: [profile])
        let outside = base.appendingPathComponent("outside-secret")
        try Data("must not be copied".utf8).write(to: outside)
        let link = base
            .appendingPathComponent(LegacyInstallIdentity.applicationSupportName, isDirectory: true)
            .appendingPathComponent("linked-secret")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("symbolic links are not allowed in app data")
            )
        }

        XCTAssertEqual(try Data(contentsOf: outside), Data("must not be copied".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testCredentialFailureResumesAfterLastJournaledAccountWithoutReplayingIt() throws {
        let first = AccountProfile(provider: .claude, label: "First")
        let second = AccountProfile(provider: .codex, label: "Second")
        try writeLegacyTree(profiles: [first, second])
        let firstSnapshot = makeCredentialSnapshot(provider: .claude, marker: "first")
        let secondSnapshot = makeCredentialSnapshot(provider: .codex, marker: "second")
        let oldStore = FakeCredentialStore(snapshots: [first.id: firstSnapshot, second.id: secondSnapshot])
        oldStore.loadFailuresRemaining[second.id] = 1
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(error as? FakeCredentialStore.PlannedError, .load(second.id))
        }
        XCTAssertEqual(newStore.snapshots[first.id], firstSnapshot)
        XCTAssertNil(newStore.snapshots[second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrator.destinationRoot.path))
        XCTAssertTrue(try migrator.inspect().isInProgress)
        XCTAssertFalse(try migrator.inspect().canStartFresh)
        XCTAssertThrowsError(try migrator.skipAndStartFresh()) { error in
            XCTAssertEqual(error as? LegacyMigrationError, .migrationAlreadyStarted)
        }
        XCTAssertEqual(newStore.snapshots[first.id], firstSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrator.legacyRoot.path))

        let summary = try migrator.migrate()

        XCTAssertEqual(summary, LegacyMigrationSummary(profileCount: 2, credentialCount: 2, profilesNeedingLogin: 0))
        XCTAssertEqual(oldStore.loadCalls.filter { $0.accountID == first.id }.count, 1)
        XCTAssertEqual(newStore.saveCalls.filter { $0.accountID == first.id }.count, 1)
        XCTAssertEqual(oldStore.loadCalls.filter { $0.accountID == second.id }.count, 2)
        XCTAssertEqual(newStore.saveCalls.filter { $0.accountID == second.id }.count, 1)
        XCTAssertEqual(newStore.snapshots[second.id], secondSnapshot)
    }

    func testRestartDuringFileCopyDiscardsPartialStageAndStartsAgain() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = AccountProfile(
            provider: .claude,
            label: "Source of truth",
            createdAt: date,
            updatedAt: date
        )
        try writeLegacyTree(profiles: [profile])
        let stage = base.appendingPathComponent(".LimitLifeboatMigration-v1-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data("partial copy".utf8).write(to: stage.appendingPathComponent("profiles.json"))
        try writeJournal(
            phase: .copyingFiles,
            completedCredentialIDs: [],
            credentialCount: 0,
            profilesNeedingLogin: 0
        )
        let migrator = try makeMigrator(
            oldStore: FakeCredentialStore(),
            newStore: FakeCredentialStore()
        )

        let summary = try migrator.migrate()

        XCTAssertEqual(summary.profileCount, 1)
        XCTAssertEqual(
            try decode([AccountProfile].self, at: migrator.destinationRoot.appendingPathComponent("profiles.json")),
            [profile]
        )
    }

    func testRestartAfterCredentialPhasePromotesExistingStageWithoutCredentialAccess() throws {
        let profile = AccountProfile(provider: .claude, label: "Already copied credential")
        let stage = base.appendingPathComponent(".LimitLifeboatMigration-v1-stage", isDirectory: true)
        try writeTree(at: stage, profiles: [profile])
        try writeJournal(
            phase: .credentialsMigrated,
            completedCredentialIDs: [profile.id],
            credentialCount: 1,
            profilesNeedingLogin: 0,
            stagedManifest: try LegacyMigrationContentManifest.digest(at: stage)
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()
        XCTAssertTrue(
            inspection.requiresMigration,
            "A journaled stage must resume even if the legacy source disappeared"
        )
        XCTAssertFalse(inspection.hasDestinationConflict)

        let summary = try migrator.migrate()

        XCTAssertEqual(summary, LegacyMigrationSummary(profileCount: 1, credentialCount: 1, profilesNeedingLogin: 0))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrator.destinationRoot.appendingPathComponent("profiles.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrator.destinationRoot.appendingPathComponent(".migration-v1-complete").path
        ))
    }

    func testRestartAfterAtomicPromotionBeforeJournalAdvanceIsResumable() throws {
        let profile = AccountProfile(provider: .claude, label: "Already promoted")
        let destination = base.appendingPathComponent(
            LegacyInstallIdentity.currentApplicationSupportName,
            isDirectory: true
        )
        try writeTree(at: destination, profiles: [profile])
        try writeJournal(
            phase: .credentialsMigrated,
            completedCredentialIDs: [profile.id],
            credentialCount: 1,
            profilesNeedingLogin: 0,
            stagedManifest: try LegacyMigrationContentManifest.digest(at: destination)
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()
        XCTAssertTrue(inspection.requiresMigration)
        XCTAssertTrue(inspection.isInProgress)
        XCTAssertFalse(inspection.hasDestinationConflict)

        let summary = try migrator.migrate()

        XCTAssertEqual(
            summary,
            LegacyMigrationSummary(profileCount: 1, credentialCount: 1, profilesNeedingLogin: 0)
        )
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".migration-v1-complete").path
        ))
    }

    func testResumedMigrationRejectsAChangedStagingTreeBeforeCredentialAccess() throws {
        let original = AccountProfile(provider: .claude, label: "Validated profile")
        let stage = base.appendingPathComponent(".LimitLifeboatMigration-v1-stage", isDirectory: true)
        try writeTree(at: stage, profiles: [original])
        let manifest = try LegacyMigrationContentManifest.digest(at: stage)
        try writeJournal(
            phase: .filesStaged,
            completedCredentialIDs: [],
            credentialCount: 0,
            profilesNeedingLogin: 0,
            stagedManifest: manifest
        )
        var changed = original
        changed.label = "Changed after validation"
        try JSONEncoder.appEncoder.encode([changed]).write(
            to: stage.appendingPathComponent("profiles.json"),
            options: [.atomic]
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("the staged app data changed after validation")
            )
        }
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testPromotionRecoveryRejectsAnUnrelatedValidDestination() throws {
        let expected = AccountProfile(provider: .claude, label: "Expected profile")
        let stage = base.appendingPathComponent(".LimitLifeboatMigration-v1-stage", isDirectory: true)
        try writeTree(at: stage, profiles: [expected])
        let manifest = try LegacyMigrationContentManifest.digest(at: stage)
        try FileManager.default.removeItem(at: stage)

        let unrelated = AccountProfile(provider: .codex, label: "Unrelated profile")
        let destination = base.appendingPathComponent(
            LegacyInstallIdentity.currentApplicationSupportName,
            isDirectory: true
        )
        try writeTree(at: destination, profiles: [unrelated])
        try writeJournal(
            phase: .credentialsMigrated,
            completedCredentialIDs: [expected.id],
            credentialCount: 1,
            profilesNeedingLogin: 0,
            stagedManifest: manifest
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        XCTAssertFalse(try migrator.inspect().hasDestinationConflict)
        XCTAssertThrowsError(try migrator.migrate()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("the staged app data changed after validation")
            )
        }
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testRestartAfterAtomicPromotionWritesCompletionMarkerLastWithoutCredentialAccess() throws {
        let profile = AccountProfile(provider: .codex, label: "Already promoted")
        let destination = base.appendingPathComponent(LegacyInstallIdentity.currentApplicationSupportName, isDirectory: true)
        try writeTree(at: destination, profiles: [profile])
        defaults.setPersistentDomain(["usageAlertsEnabled": true], forName: legacyDefaultsDomain)
        try writeJournal(
            phase: .filesCommitted,
            completedCredentialIDs: [profile.id],
            credentialCount: 1,
            profilesNeedingLogin: 0,
            stagedManifest: try LegacyMigrationContentManifest.digest(at: destination)
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()
        XCTAssertFalse(inspection.isComplete)
        XCTAssertFalse(inspection.hasDestinationConflict, "A journaled promotion must be treated as resumable")

        let summary = try migrator.migrate()

        XCTAssertEqual(summary, LegacyMigrationSummary(profileCount: 1, credentialCount: 1, profilesNeedingLogin: 0))
        XCTAssertTrue(defaults.bool(forKey: "usageAlertsEnabled"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrator.destinationRoot.appendingPathComponent(".migration-v1-complete").path
        ))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testCompletedMigrationIsIdempotentAndDoesNotReopenCredentialStores() throws {
        let profile = AccountProfile(provider: .claude, label: "Completed")
        try writeLegacyTree(profiles: [profile])
        let snapshot = makeCredentialSnapshot(provider: .claude, marker: "one-time")
        let oldStore = FakeCredentialStore(snapshots: [profile.id: snapshot])
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)
        let first = try migrator.migrate()
        oldStore.clearCalls()
        newStore.clearCalls()

        let second = try migrator.migrate()

        XCTAssertEqual(second, first)
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
        XCTAssertEqual(newStore.snapshots[profile.id], snapshot)
    }

    func testInspectFinalizesCompleteJournalMarkerWithoutCredentialAccess() throws {
        let profile = AccountProfile(provider: .claude, label: "Committed")
        let destination = base.appendingPathComponent(
            LegacyInstallIdentity.currentApplicationSupportName,
            isDirectory: true
        )
        try writeTree(at: destination, profiles: [profile])
        try writeJournal(
            phase: .complete,
            completedCredentialIDs: [profile.id],
            credentialCount: 1,
            profilesNeedingLogin: 0,
            stagedManifest: try LegacyMigrationContentManifest.digest(at: destination)
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()

        XCTAssertTrue(inspection.isComplete)
        XCTAssertFalse(inspection.requiresMigration)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".migration-v1-complete").path
        ))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testInspectRefusesToFinalizeChangedCommittedContent() throws {
        let original = AccountProfile(provider: .claude, label: "Committed")
        let destination = base.appendingPathComponent(
            LegacyInstallIdentity.currentApplicationSupportName,
            isDirectory: true
        )
        try writeTree(at: destination, profiles: [original])
        let manifest = try LegacyMigrationContentManifest.digest(at: destination)
        try writeJournal(
            phase: .complete,
            completedCredentialIDs: [original.id],
            credentialCount: 1,
            profilesNeedingLogin: 0,
            stagedManifest: manifest
        )
        var changed = original
        changed.label = "Changed before final marker"
        try JSONEncoder.appEncoder.encode([changed]).write(
            to: destination.appendingPathComponent("profiles.json"),
            options: [.atomic]
        )
        let migrator = try makeMigrator(
            oldStore: FakeCredentialStore(),
            newStore: FakeCredentialStore()
        )

        XCTAssertThrowsError(try migrator.inspect()) { error in
            XCTAssertEqual(
                error as? LegacyMigrationError,
                .invalidLegacyData("the staged app data changed after validation")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".migration-v1-complete").path
        ))
    }

    func testInspectFinalizesSkippedJournalMarkerWithoutCredentialAccess() throws {
        let destination = base.appendingPathComponent(
            LegacyInstallIdentity.currentApplicationSupportName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try writeJournal(
            phase: .skipped,
            completedCredentialIDs: [],
            credentialCount: 0,
            profilesNeedingLogin: 0
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()

        XCTAssertTrue(inspection.isComplete)
        XCTAssertFalse(inspection.requiresMigration)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".migration-v1-skipped").path
        ))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testInspectFinishesStartFreshWhenDestinationCreationWasInterrupted() throws {
        try writeJournal(
            phase: .skipped,
            completedCredentialIDs: [],
            credentialCount: 0,
            profilesNeedingLogin: 0
        )
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()

        XCTAssertTrue(inspection.isComplete)
        XCTAssertFalse(inspection.requiresMigration)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: migrator.destinationRoot.appendingPathComponent(".migration-v1-skipped").path
        ))
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testInspectWithPreferencesOnlyNeverTouchesCredentials() throws {
        defaults.setPersistentDomain(["usageAlertsEnabled": true], forName: legacyDefaultsDomain)
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let inspection = try migrator.inspect()

        XCTAssertTrue(inspection.requiresMigration)
        XCTAssertEqual(inspection.profileCount, 0)
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    func testCleanInstallCanLaunchRepeatedlyWithoutAMigrationMarker() throws {
        let oldStore = FakeCredentialStore()
        let newStore = FakeCredentialStore()
        let migrator = try makeMigrator(oldStore: oldStore, newStore: newStore)

        let firstLaunch = try migrator.inspect()
        XCTAssertFalse(firstLaunch.requiresMigration)
        XCTAssertFalse(firstLaunch.hasDestinationConflict)

        try FileManager.default.createDirectory(
            at: migrator.destinationRoot,
            withIntermediateDirectories: false
        )
        try JSONEncoder.appEncoder.encode([AccountProfile]()).write(
            to: migrator.destinationRoot.appendingPathComponent("profiles.json")
        )

        let secondLaunch = try migrator.inspect()
        XCTAssertFalse(secondLaunch.requiresMigration)
        XCTAssertFalse(secondLaunch.hasDestinationConflict)
        XCTAssertFalse(secondLaunch.isComplete)
        XCTAssertTrue(oldStore.allCalls.isEmpty)
        XCTAssertTrue(newStore.allCalls.isEmpty)
    }

    private func makeMigrator(
        oldStore: FakeCredentialStore,
        newStore: FakeCredentialStore
    ) throws -> LegacyInstallMigrator {
        try LegacyInstallMigrator(
            applicationSupportBase: base,
            legacyDefaultsDomain: legacyDefaultsDomain,
            destinationDefaults: defaults,
            legacyCredentialStore: oldStore,
            destinationCredentialStore: newStore
        )
    }

    private func writeLegacyTree(
        profiles: [AccountProfile],
        snapshots: [UsageSnapshot]? = nil,
        history: [UsageHistoryRecord]? = nil,
        backupRelativePath: String? = nil,
        backupData: Data? = nil
    ) throws {
        let root = base.appendingPathComponent(LegacyInstallIdentity.applicationSupportName, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try writeTree(
            at: root,
            profiles: profiles,
            snapshots: snapshots,
            history: history,
            backupRelativePath: backupRelativePath,
            backupData: backupData
        )
    }

    private func writeTree(
        at root: URL,
        profiles: [AccountProfile],
        snapshots: [UsageSnapshot]? = nil,
        history: [UsageHistoryRecord]? = nil,
        backupRelativePath: String? = nil,
        backupData: Data? = nil
    ) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.appEncoder.encode(profiles).write(to: root.appendingPathComponent("profiles.json"))
        if let snapshots {
            try JSONEncoder.appEncoder.encode(snapshots).write(
                to: root.appendingPathComponent("usage-snapshots.json")
            )
        }
        if let history {
            var data = Data()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            for record in history {
                data.append(try encoder.encode(record))
                data.append(UInt8(ascii: "\n"))
            }
            try data.write(to: root.appendingPathComponent("usage-history.jsonl"))
        }
        if let backupRelativePath, let backupData {
            let backupURL = root.appendingPathComponent(backupRelativePath)
            try FileManager.default.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try backupData.write(to: backupURL)
        }
    }

    private func makeCredentialSnapshot(provider: Provider, marker: String) -> CredentialSnapshot {
        CredentialSnapshot(
            provider: provider,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            items: [
                CredentialSnapshotItem(
                    relativePath: provider == .claude ? ".claude.json" : ".codex/auth.json",
                    kind: .jsonFields,
                    contents: Data("{\"fixture\":\"\(marker)\"}".utf8),
                    posixPermissions: 0o600
                )
            ]
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder.appDecoder.decode(type, from: Data(contentsOf: url))
    }

    private func decodeHistory(at url: URL) throws -> [UsageHistoryRecord] {
        let data = try Data(contentsOf: url)
        return try data.split(separator: UInt8(ascii: "\n")).map {
            try JSONDecoder.appDecoder.decode(UsageHistoryRecord.self, from: Data($0))
        }
    }

    private func writeJournal(
        phase: LegacyMigrationPhase,
        completedCredentialIDs: [UUID],
        credentialCount: Int,
        profilesNeedingLogin: Int,
        stagedManifest: String? = nil
    ) throws {
        var payload: [String: Any] = [
            "phase": phase.rawValue,
            "completedCredentialIDs": completedCredentialIDs.map(\.uuidString),
            "credentialCount": credentialCount,
            "profilesNeedingLogin": profilesNeedingLogin,
        ]
        if let stagedManifest {
            payload["stagedManifest"] = stagedManifest
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: base.appendingPathComponent(".LimitLifeboatMigration-v1.json"))
    }

    private func removeMigrationArtifacts() throws {
        for name in [
            LegacyInstallIdentity.applicationSupportName,
            LegacyInstallIdentity.currentApplicationSupportName,
            ".LimitLifeboatMigration-v1-stage",
            ".LimitLifeboatMigration-v1.json",
            ".LimitLifeboatMigration-v1.lock",
        ] {
            let url = base.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

}

private final class FakeCredentialStore: CredentialStoreProtocol {
    enum PlannedError: Error, Equatable {
        case load(UUID)
        case save(UUID)
    }

    struct Call: Equatable {
        enum Operation: Equatable {
            case load
            case save
            case delete
            case hasSnapshot
        }

        var operation: Operation
        var accountID: UUID
        var mode: CredentialAccessMode
    }

    var snapshots: [UUID: CredentialSnapshot]
    var loadFailuresRemaining: [UUID: Int] = [:]
    var saveFailuresRemaining: [UUID: Int] = [:]
    private(set) var allCalls: [Call] = []

    init(snapshots: [UUID: CredentialSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    var loadCalls: [Call] { allCalls.filter { $0.operation == .load } }
    var saveCalls: [Call] { allCalls.filter { $0.operation == .save } }

    func clearCalls() {
        allCalls.removeAll()
    }

    func save(
        snapshot: CredentialSnapshot,
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws {
        allCalls.append(Call(operation: .save, accountID: accountID, mode: accessMode))
        if let remaining = saveFailuresRemaining[accountID], remaining > 0 {
            saveFailuresRemaining[accountID] = remaining - 1
            throw PlannedError.save(accountID)
        }
        snapshots[accountID] = snapshot
    }

    func loadSnapshot(
        for accountID: UUID,
        accessMode: CredentialAccessMode
    ) throws -> CredentialSnapshot? {
        allCalls.append(Call(operation: .load, accountID: accountID, mode: accessMode))
        if let remaining = loadFailuresRemaining[accountID], remaining > 0 {
            loadFailuresRemaining[accountID] = remaining - 1
            throw PlannedError.load(accountID)
        }
        return snapshots[accountID]
    }

    func deleteSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws {
        allCalls.append(Call(operation: .delete, accountID: accountID, mode: accessMode))
        snapshots.removeValue(forKey: accountID)
    }

    func hasSnapshot(for accountID: UUID, accessMode: CredentialAccessMode) throws -> Bool {
        allCalls.append(Call(operation: .hasSnapshot, accountID: accountID, mode: accessMode))
        return snapshots[accountID] != nil
    }
}
