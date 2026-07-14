import CryptoKit
import Darwin
import Foundation

public enum LegacyInstallIdentity {
    public static let bundleIdentifier = "com.johannesberggren.LLMUsageMonitor"
    public static let applicationSupportName = "LLMUsageMonitor"
    public static let credentialService = "com.johannesberggren.LLMUsageMonitor.credentials"

    public static let currentBundleIdentifier = "com.limitlifeboat.app"
    public static let currentApplicationSupportName = "LimitLifeboat"
    public static let currentCredentialService = "com.limitlifeboat.app.credentials"
}

public enum LegacyMigrationPhase: String, Codable, Sendable {
    case copyingFiles
    case filesStaged
    case credentialsMigrated
    case filesCommitted
    case complete
    case skipped
}

public struct LegacyMigrationInspection: Equatable, Sendable {
    public var isComplete: Bool
    public var isInProgress: Bool
    public var canStartFresh: Bool
    public var requiresMigration: Bool
    public var hasDestinationConflict: Bool
    public var profileCount: Int

    public init(
        isComplete: Bool,
        isInProgress: Bool,
        canStartFresh: Bool,
        requiresMigration: Bool,
        hasDestinationConflict: Bool,
        profileCount: Int
    ) {
        self.isComplete = isComplete
        self.isInProgress = isInProgress
        self.canStartFresh = canStartFresh
        self.requiresMigration = requiresMigration
        self.hasDestinationConflict = hasDestinationConflict
        self.profileCount = profileCount
    }
}

public struct LegacyMigrationSummary: Equatable, Sendable {
    public var profileCount: Int
    public var credentialCount: Int
    public var profilesNeedingLogin: Int

    public init(profileCount: Int, credentialCount: Int, profilesNeedingLogin: Int) {
        self.profileCount = profileCount
        self.credentialCount = credentialCount
        self.profilesNeedingLogin = profilesNeedingLogin
    }
}

public enum LegacyMigrationError: Error, LocalizedError, Equatable {
    case applicationSupportUnavailable
    case migrationAlreadyRunning
    case migrationAlreadyStarted
    case destinationConflict(String)
    case invalidLegacyData(String)
    case credentialConflict(UUID)
    case credentialProviderMismatch(UUID)
    case credentialVerificationFailed(UUID)
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Could not resolve Application Support for the migration."
        case .migrationAlreadyRunning:
            return "Another Limit Lifeboat migration is already running."
        case .migrationAlreadyStarted:
            return "This migration has already started and must be resumed instead of replaced with Start Fresh."
        case .destinationConflict(let detail):
            return "Limit Lifeboat found both old and new app data and will not merge them automatically (\(detail))."
        case .invalidLegacyData(let detail):
            return "The old LLM Usage Monitor data could not be validated (\(detail))."
        case .credentialConflict:
            return "A migrated account already has different saved credentials in Limit Lifeboat."
        case .credentialProviderMismatch:
            return "A saved credential snapshot belongs to a different provider than its account."
        case .credentialVerificationFailed:
            return "A saved credential snapshot could not be verified after migration."
        case .fileOperation(let detail):
            return "The migration could not safely copy its files (\(detail))."
        }
    }
}

/// A replay-safe, source-preserving migration from the pre-release
/// LLM Usage Monitor identity to Limit Lifeboat. The journal contains only
/// phases and account UUIDs; credential bytes remain in Keychain.
public final class LegacyInstallMigrator {
    /// These are the legacy files that are safe to adopt. Persistent plaintext
    /// `Backups` are deliberately left in the untouched legacy tree now that
    /// switching uses transaction-local rollback material. Unknown files are
    /// likewise left behind instead of being swept into the new identity.
    private static let knownApplicationSupportItems = [
        "profiles.json",
        "usage-snapshots.json",
        "usage-history.jsonl",
    ]

    public static let allowedDefaultsKeys = [
        "refreshIntervalMinutes",
        "usageAlertsEnabled",
        "autoSwitchEnabled",
        "resetAlertsEnabled",
        "showOrganizationNames",
        "notifiedResetDates",
        "notifiedPaceAlerts",
    ]

    private struct Journal: Codable {
        var phase: LegacyMigrationPhase
        var completedCredentialIDs: Set<UUID>
        var credentialCount: Int
        var profilesNeedingLogin: Int
        var stagedManifest: String?
    }

    private let fileManager: FileManager
    private let applicationSupportBase: URL
    public let legacyRoot: URL
    public let destinationRoot: URL
    private let stageRoot: URL
    private let journalURL: URL
    private let lockURL: URL
    private let completionMarkerURL: URL
    private let skippedMarkerURL: URL
    private let legacyDefaultsDomain: String
    private let destinationDefaults: UserDefaults
    private let legacyCredentialStore: CredentialStoreProtocol
    private let destinationCredentialStore: CredentialStoreProtocol

    public init(
        applicationSupportBase: URL? = nil,
        fileManager: FileManager = .default,
        legacyDefaultsDomain: String = LegacyInstallIdentity.bundleIdentifier,
        destinationDefaults: UserDefaults = .standard,
        legacyCredentialStore: CredentialStoreProtocol,
        destinationCredentialStore: CredentialStoreProtocol
    ) throws {
        guard let base = applicationSupportBase
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LegacyMigrationError.applicationSupportUnavailable
        }
        self.fileManager = fileManager
        self.applicationSupportBase = base
        self.legacyRoot = base.appendingPathComponent(
            LegacyInstallIdentity.applicationSupportName,
            isDirectory: true
        )
        self.destinationRoot = base.appendingPathComponent(
            LegacyInstallIdentity.currentApplicationSupportName,
            isDirectory: true
        )
        self.stageRoot = base.appendingPathComponent(".LimitLifeboatMigration-v1-stage", isDirectory: true)
        self.journalURL = base.appendingPathComponent(".LimitLifeboatMigration-v1.json")
        self.lockURL = base.appendingPathComponent(".LimitLifeboatMigration-v1.lock")
        self.completionMarkerURL = self.destinationRoot.appendingPathComponent(".migration-v1-complete")
        self.skippedMarkerURL = self.destinationRoot.appendingPathComponent(".migration-v1-skipped")
        self.legacyDefaultsDomain = legacyDefaultsDomain
        self.destinationDefaults = destinationDefaults
        self.legacyCredentialStore = legacyCredentialStore
        self.destinationCredentialStore = destinationCredentialStore
    }

    public func inspect() throws -> LegacyMigrationInspection {
        let journal = try loadJournal()
        try finishPendingMarkerIfNeeded(journal)
        let complete = fileManager.fileExists(atPath: completionMarkerURL.path)
            || fileManager.fileExists(atPath: skippedMarkerURL.path)
        let legacyDefaults = destinationDefaults.persistentDomain(forName: legacyDefaultsDomain) ?? [:]
        let hasLegacyRoot = fileManager.fileExists(atPath: legacyRoot.path)
        let requiresMigration = !complete
            && (hasLegacyRoot || !legacyDefaults.isEmpty || journal != nil)
        // Moving the staged folder into place is atomic, but the process can
        // stop before the following journal write. A destination paired with
        // credentialsMigrated is therefore a valid resumable state, not an
        // unrelated-data conflict.
        let resumableDestination = journal.map {
            $0.phase == .credentialsMigrated
                || $0.phase == .filesCommitted
                || $0.phase == .complete
        } ?? false
        let hasDestination = fileManager.fileExists(atPath: destinationRoot.path)
        let conflict = requiresMigration && hasDestination && !resumableDestination
        // Counting profiles is presentation-only. Corrupt legacy metadata must
        // not prevent the user from choosing Start Fresh; the actual migration
        // performs strict validation after consent.
        let profiles = (try? profilesForInspection(journal: journal)) ?? []
        return LegacyMigrationInspection(
            isComplete: complete,
            isInProgress: !complete && journal != nil,
            canStartFresh: journal == nil || journal?.phase == .copyingFiles,
            requiresMigration: requiresMigration,
            hasDestinationConflict: conflict,
            profileCount: profiles.count
        )
    }

    public func migrate() throws -> LegacyMigrationSummary {
        try withMigrationLock {
            if fileManager.fileExists(atPath: completionMarkerURL.path) {
                let profiles = try loadProfiles(at: destinationRoot)
                let journal = try loadJournal()
                return LegacyMigrationSummary(
                    profileCount: profiles.count,
                    credentialCount: journal?.credentialCount ?? 0,
                    profilesNeedingLogin: journal?.profilesNeedingLogin ?? 0
                )
            }

            var journal = try loadJournal() ?? Journal(
                phase: .copyingFiles,
                completedCredentialIDs: [],
                credentialCount: 0,
                profilesNeedingLogin: 0,
                stagedManifest: nil
            )

            if journal.phase == .copyingFiles {
                try writeJournal(journal)
                journal.stagedManifest = try stageLegacyFiles()
                journal.phase = .filesStaged
                try writeJournal(journal)
            }

            if journal.phase == .skipped {
                try finishPendingMarkerIfNeeded(journal)
                return LegacyMigrationSummary(
                    profileCount: 0,
                    credentialCount: 0,
                    profilesNeedingLogin: 0
                )
            }

            let hasStage = fileManager.fileExists(atPath: stageRoot.path)
            let hasDestination = fileManager.fileExists(atPath: destinationRoot.path)
            let profileRoot: URL
            switch journal.phase {
            case .filesStaged:
                guard hasStage else {
                    throw LegacyMigrationError.fileOperation("the staged app data folder is missing")
                }
                guard !hasDestination else {
                    throw LegacyMigrationError.destinationConflict(
                        "a destination folder appeared before staged credentials were migrated"
                    )
                }
                profileRoot = stageRoot
            case .credentialsMigrated:
                if hasStage && hasDestination {
                    throw LegacyMigrationError.destinationConflict(
                        "both the staging and destination folders exist"
                    )
                }
                guard hasStage || hasDestination else {
                    throw LegacyMigrationError.fileOperation(
                        "both the staging and destination folders are missing"
                    )
                }
                profileRoot = hasStage ? stageRoot : destinationRoot
            case .filesCommitted, .complete:
                guard hasDestination else {
                    throw LegacyMigrationError.fileOperation("the committed destination folder is missing")
                }
                guard !hasStage else {
                    throw LegacyMigrationError.destinationConflict(
                        "a staging folder remains after the destination was committed"
                    )
                }
                profileRoot = destinationRoot
            case .copyingFiles:
                throw LegacyMigrationError.fileOperation("file staging did not reach a committed journal phase")
            case .skipped:
                preconditionFailure("the skipped phase returns before profile validation")
            }
            try verifyStagedManifest(journal, at: profileRoot)
            let profiles = try validateRoot(profileRoot)

            if journal.phase == .filesStaged {
                for profile in profiles where !journal.completedCredentialIDs.contains(profile.id) {
                    let oldSnapshot = try legacyCredentialStore.loadSnapshot(
                        for: profile.id,
                        accessMode: .userInitiated
                    )
                    guard let oldSnapshot else {
                        journal.profilesNeedingLogin += 1
                        journal.completedCredentialIDs.insert(profile.id)
                        try writeJournal(journal)
                        continue
                    }
                    guard oldSnapshot.provider == profile.provider else {
                        throw LegacyMigrationError.credentialProviderMismatch(profile.id)
                    }
                    if let existing = try destinationCredentialStore.loadSnapshot(
                        for: profile.id,
                        accessMode: .userInitiated
                    ), existing != oldSnapshot {
                        throw LegacyMigrationError.credentialConflict(profile.id)
                    }
                    try destinationCredentialStore.save(
                        snapshot: oldSnapshot,
                        for: profile.id,
                        accessMode: .userInitiated
                    )
                    guard try destinationCredentialStore.loadSnapshot(
                        for: profile.id,
                        accessMode: .userInitiated
                    ) == oldSnapshot else {
                        throw LegacyMigrationError.credentialVerificationFailed(profile.id)
                    }
                    journal.credentialCount += 1
                    journal.completedCredentialIDs.insert(profile.id)
                    try writeJournal(journal)
                }
                journal.phase = .credentialsMigrated
                try writeJournal(journal)
            }

            if journal.phase == .credentialsMigrated {
                if fileManager.fileExists(atPath: destinationRoot.path) {
                    guard !fileManager.fileExists(atPath: stageRoot.path) else {
                        throw LegacyMigrationError.destinationConflict("both the staging and destination folders exist")
                    }
                    _ = try validateRoot(destinationRoot)
                } else {
                    guard fileManager.fileExists(atPath: stageRoot.path) else {
                        throw LegacyMigrationError.fileOperation("the validated staging folder is missing")
                    }
                    try fileManager.moveItem(at: stageRoot, to: destinationRoot)
                }
                journal.phase = .filesCommitted
                try writeJournal(journal)
            }

            if journal.phase == .filesCommitted {
                try migrateDefaults()
                journal.phase = .complete
                try writeJournal(journal)
            }

            // The marker is the commit record observed by app startup and is
            // therefore always written after every other migration artifact.
            // If a crash lands after the journal update, the next retry only
            // needs to recreate this marker.
            if journal.phase == .complete,
               !fileManager.fileExists(atPath: completionMarkerURL.path) {
                try writeMarker(completionMarkerURL)
            }

            return LegacyMigrationSummary(
                profileCount: profiles.count,
                credentialCount: journal.credentialCount,
                profilesNeedingLogin: journal.profilesNeedingLogin
            )
        }
    }

    /// Starts with a pristine Limit Lifeboat store while deliberately leaving
    /// every legacy file, preference, and Keychain item untouched.
    public func skipAndStartFresh() throws {
        try withMigrationLock {
            if fileManager.fileExists(atPath: skippedMarkerURL.path) {
                return
            }
            if let journal = try loadJournal() {
                if journal.phase == .skipped {
                    try finishPendingMarkerIfNeeded(journal)
                    return
                }
                guard journal.phase == .copyingFiles else {
                    throw LegacyMigrationError.migrationAlreadyStarted
                }
                guard !fileManager.fileExists(atPath: destinationRoot.path) else {
                    throw LegacyMigrationError.destinationConflict(
                        "a destination folder appeared while file staging was incomplete"
                    )
                }
                if fileManager.fileExists(atPath: stageRoot.path) {
                    try fileManager.removeItem(at: stageRoot)
                }
            }
            guard !fileManager.fileExists(atPath: destinationRoot.path) else {
                throw LegacyMigrationError.destinationConflict("the new Application Support folder is not empty")
            }
            // Record the user's choice before creating the new store. If the
            // process stops between these writes, inspection can safely
            // finish the empty destination without touching legacy state.
            try writeJournal(
                Journal(
                    phase: .skipped,
                    completedCredentialIDs: [],
                    credentialCount: 0,
                    profilesNeedingLogin: 0,
                    stagedManifest: nil
                )
            )
            try fileManager.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try writeMarker(skippedMarkerURL)
        }
    }

    private func stageLegacyFiles() throws -> String {
        if fileManager.fileExists(atPath: stageRoot.path) {
            try fileManager.removeItem(at: stageRoot)
        }
        if fileManager.fileExists(atPath: legacyRoot.path) {
            try rejectSymbolicLinks(in: legacyRoot)
            try fileManager.createDirectory(
                at: stageRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            for item in Self.knownApplicationSupportItems {
                let source = legacyRoot.appendingPathComponent(item)
                guard fileManager.fileExists(atPath: source.path) else {
                    continue
                }
                try validateCopyableTree(source)
                try fileManager.copyItem(
                    at: source,
                    to: stageRoot.appendingPathComponent(item)
                )
            }
            try rejectSymbolicLinks(in: stageRoot)
            try tightenPermissions(in: stageRoot)
            _ = try validateRoot(stageRoot)
            try compareKnownTrees(source: legacyRoot, copy: stageRoot)
        } else {
            try fileManager.createDirectory(
                at: stageRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return try LegacyMigrationContentManifest.digest(at: stageRoot, fileManager: fileManager)
    }

    @discardableResult
    private func validateRoot(_ root: URL) throws -> [AccountProfile] {
        let profiles = try loadProfiles(at: root)
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw LegacyMigrationError.invalidLegacyData("duplicate profile identifiers")
        }
        let profileIDs = Set(profiles.map(\.id))

        let snapshotsURL = root.appendingPathComponent("usage-snapshots.json")
        if fileManager.fileExists(atPath: snapshotsURL.path) {
            do {
                let snapshots = try JSONDecoder.appDecoder.decode(
                    [UsageSnapshot].self,
                    from: Data(contentsOf: snapshotsURL)
                )
                guard Set(snapshots.map(\.accountID)).count == snapshots.count else {
                    throw LegacyMigrationError.invalidLegacyData("duplicate usage snapshot identifiers")
                }
                guard snapshots.allSatisfy({ profileIDs.contains($0.accountID) }) else {
                    throw LegacyMigrationError.invalidLegacyData("a usage snapshot has no matching profile")
                }
                let providers = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.provider) })
                guard snapshots.allSatisfy({ providers[$0.accountID] == $0.provider }) else {
                    throw LegacyMigrationError.invalidLegacyData("a usage snapshot has the wrong provider")
                }
            } catch let error as LegacyMigrationError {
                throw error
            } catch {
                throw LegacyMigrationError.invalidLegacyData("usage-snapshots.json is unreadable")
            }
        }

        let historyURL = root.appendingPathComponent("usage-history.jsonl")
        if fileManager.fileExists(atPath: historyURL.path) {
            let data = try Data(contentsOf: historyURL)
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let record = try? JSONDecoder.appDecoder.decode(
                    UsageHistoryRecord.self,
                    from: Data(line)
                ) else {
                    throw LegacyMigrationError.invalidLegacyData("usage-history.jsonl contains an unreadable record")
                }
                guard profileIDs.contains(record.accountID) else {
                    throw LegacyMigrationError.invalidLegacyData("a usage-history record has no matching profile")
                }
            }
        }
        return profiles
    }

    private func loadProfiles(at root: URL) throws -> [AccountProfile] {
        let url = root.appendingPathComponent("profiles.json")
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        do {
            return try JSONDecoder.appDecoder.decode([AccountProfile].self, from: Data(contentsOf: url))
        } catch {
            throw LegacyMigrationError.invalidLegacyData("profiles.json is unreadable")
        }
    }

    private func profilesForInspection(journal: Journal?) throws -> [AccountProfile] {
        if journal != nil, fileManager.fileExists(atPath: stageRoot.path) {
            return try loadProfiles(at: stageRoot)
        }
        if fileManager.fileExists(atPath: destinationRoot.path) {
            return try loadProfiles(at: destinationRoot)
        }
        if fileManager.fileExists(atPath: legacyRoot.path) {
            return try loadProfiles(at: legacyRoot)
        }
        return []
    }

    private func migrateDefaults() throws {
        let legacy = destinationDefaults.persistentDomain(forName: legacyDefaultsDomain) ?? [:]
        for key in Self.allowedDefaultsKeys where destinationDefaults.object(forKey: key) == nil {
            if let value = legacy[key] {
                destinationDefaults.set(value, forKey: key)
            }
        }
        guard destinationDefaults.synchronize() else {
            throw LegacyMigrationError.fileOperation("the migrated preferences could not be saved")
        }
    }

    private func rejectSymbolicLinks(in root: URL) throws {
        if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw LegacyMigrationError.invalidLegacyData("symbolic links are not allowed in app data")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw LegacyMigrationError.fileOperation("the legacy folder could not be enumerated")
        }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw LegacyMigrationError.invalidLegacyData("symbolic links are not allowed in app data")
            }
        }
    }

    private func validateCopyableTree(_ root: URL) throws {
        try rejectSymbolicLinks(in: root)
        let rootValues = try root.resourceValues(
            forKeys: [.isRegularFileKey, .isDirectoryKey]
        )
        guard rootValues.isRegularFile == true || rootValues.isDirectory == true else {
            throw LegacyMigrationError.invalidLegacyData("app data contains an unsupported file type")
        }
        guard rootValues.isDirectory == true else {
            return
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else {
            throw LegacyMigrationError.fileOperation("an app data folder could not be enumerated")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey]
            )
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw LegacyMigrationError.invalidLegacyData("app data contains an unsupported file type")
            }
        }
    }

    private func tightenPermissions(in root: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: nil
        ) else {
            return
        }
        for case let url as URL in enumerator {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try fileManager.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private func compareKnownTrees(source: URL, copy: URL) throws {
        for item in Self.knownApplicationSupportItems {
            let sourceItem = source.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: sourceItem.path) else {
                continue
            }
            let copiedItem = copy.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: copiedItem.path) else {
                throw LegacyMigrationError.fileOperation("a staged app data item is missing")
            }
            let sourceValues = try sourceItem.resourceValues(forKeys: [.isRegularFileKey])
            if sourceValues.isRegularFile == true {
                guard try Data(contentsOf: sourceItem) == Data(contentsOf: copiedItem) else {
                    throw LegacyMigrationError.fileOperation("a staged file did not match its source")
                }
                continue
            }

            let sourceFiles = try regularFiles(in: sourceItem)
            let copiedFiles = try regularFiles(in: copiedItem)
            guard Set(sourceFiles.keys) == Set(copiedFiles.keys) else {
                throw LegacyMigrationError.fileOperation("the staged file list does not match the source")
            }
            for relativePath in sourceFiles.keys {
                guard let sourceURL = sourceFiles[relativePath], let copyURL = copiedFiles[relativePath],
                      try Data(contentsOf: sourceURL) == Data(contentsOf: copyURL) else {
                    throw LegacyMigrationError.fileOperation("a staged file did not match its source")
                }
            }
        }
    }

    private func regularFiles(in root: URL) throws -> [String: URL] {
        var result: [String: URL] = [:]
        let canonicalRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalPrefix = canonicalRootPath.hasSuffix("/")
            ? canonicalRootPath
            : canonicalRootPath + "/"
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return result
        }
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalPath.hasPrefix(canonicalPrefix) else {
                throw LegacyMigrationError.fileOperation("an app data file resolved outside its folder")
            }
            result[String(canonicalPath.dropFirst(canonicalPrefix.count))] = url
        }
        return result
    }

    private func loadJournal() throws -> Journal? {
        guard fileManager.fileExists(atPath: journalURL.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        } catch {
            throw LegacyMigrationError.invalidLegacyData("the migration journal is unreadable")
        }
    }

    private func verifyStagedManifest(_ journal: Journal, at root: URL) throws {
        guard let expectedManifest = journal.stagedManifest else {
            throw LegacyMigrationError.invalidLegacyData(
                "the migration journal has no staged-content manifest"
            )
        }
        let actualManifest = try LegacyMigrationContentManifest.digest(
            at: root,
            fileManager: fileManager
        )
        guard actualManifest == expectedManifest else {
            throw LegacyMigrationError.invalidLegacyData(
                "the staged app data changed after validation"
            )
        }
    }

    /// A crash can occur after the journal commit but before the final marker
    /// rename. Completing that last idempotent write requires no Keychain
    /// access and honors the choice the user already made.
    private func finishPendingMarkerIfNeeded(_ journal: Journal?) throws {
        guard let journal else {
            return
        }
        switch journal.phase {
        case .complete where !fileManager.fileExists(atPath: completionMarkerURL.path):
            guard fileManager.fileExists(atPath: destinationRoot.path) else {
                throw LegacyMigrationError.fileOperation("the committed destination folder is missing")
            }
            guard !fileManager.fileExists(atPath: stageRoot.path) else {
                throw LegacyMigrationError.destinationConflict(
                    "a staging folder remains after the destination was committed"
                )
            }
            try verifyStagedManifest(journal, at: destinationRoot)
            _ = try validateRoot(destinationRoot)
            try writeMarker(completionMarkerURL)
        case .skipped where !fileManager.fileExists(atPath: skippedMarkerURL.path):
            if !fileManager.fileExists(atPath: destinationRoot.path) {
                try fileManager.createDirectory(
                    at: destinationRoot,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let contents = try fileManager.contentsOfDirectory(
                at: destinationRoot,
                includingPropertiesForKeys: nil
            )
            guard contents.isEmpty else {
                throw LegacyMigrationError.destinationConflict(
                    "the Start Fresh folder changed before its completion marker was written"
                )
            }
            try writeMarker(skippedMarkerURL)
        default:
            break
        }
    }

    private func writeJournal(_ journal: Journal) throws {
        try fileManager.createDirectory(
            at: applicationSupportBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try data.write(to: journalURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func writeMarker(_ url: URL) throws {
        try Data("1\n".utf8).write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func withMigrationLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(
            at: applicationSupportBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LegacyMigrationError.fileOperation("the migration lock could not be created")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw LegacyMigrationError.migrationAlreadyRunning
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

/// Binds every validated staging entry (including names, types, empty
/// directories, and file bytes) to the migration journal. This distinguishes
/// an atomically promoted stage from unrelated data that happens to be valid.
enum LegacyMigrationContentManifest {
    static func digest(at root: URL, fileManager: FileManager = .default) throws -> String {
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw LegacyMigrationError.invalidLegacyData(
                "the staged app data root is not a regular directory"
            )
        }

        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var entries: [(path: String, url: URL, isDirectory: Bool)] = []
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LegacyMigrationError.fileOperation("the staged app data could not be enumerated")
        }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw LegacyMigrationError.invalidLegacyData(
                    "the staged app data contains an unsupported file type"
                )
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else {
                throw LegacyMigrationError.fileOperation(
                    "a staged app data item resolved outside its folder"
                )
            }
            entries.append((
                path: String(path.dropFirst(prefix.count)),
                url: url,
                isDirectory: values.isDirectory == true
            ))
        }
        if enumerationError != nil {
            throw LegacyMigrationError.fileOperation("the staged app data could not be fully enumerated")
        }

        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let kind = entry.isDirectory ? "directory" : "file"
            hasher.update(data: Data("\(kind)\0\(entry.path)\0".utf8))
            if !entry.isDirectory {
                let fileDigest = SHA256.hash(data: try Data(contentsOf: entry.url))
                hasher.update(data: Data(fileDigest))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
