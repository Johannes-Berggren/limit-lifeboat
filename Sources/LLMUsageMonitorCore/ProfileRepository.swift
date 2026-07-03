import Foundation

public enum ProfileRepositoryError: Error, LocalizedError {
    case missingApplicationSupportDirectory

    public var errorDescription: String? {
        switch self {
        case .missingApplicationSupportDirectory:
            return "Could not resolve the Application Support directory."
        }
    }
}

public final class ProfileRepository {
    private let fileManager: FileManager
    public let applicationSupportDirectory: URL
    private let profilesURL: URL
    private let usageSnapshotsURL: URL

    public init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let directory: URL
        if let applicationSupportDirectory {
            directory = applicationSupportDirectory
        } else if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directory = base.appendingPathComponent("LLMUsageMonitor", isDirectory: true)
        } else {
            throw ProfileRepositoryError.missingApplicationSupportDirectory
        }

        self.applicationSupportDirectory = directory
        self.profilesURL = directory.appendingPathComponent("profiles.json")
        self.usageSnapshotsURL = directory.appendingPathComponent("usage-snapshots.json")
    }

    public func loadProfiles() throws -> [AccountProfile] {
        try ensureDirectory()
        guard fileManager.fileExists(atPath: profilesURL.path) else {
            let defaults = AccountProfile.defaultProfiles()
            try saveProfiles(defaults)
            return defaults
        }

        let data = try Data(contentsOf: profilesURL)
        let profiles = try JSONDecoder.appDecoder.decode([AccountProfile].self, from: data)
        let migrated = migratePrimaryProfilesToDefaultStore(profiles)
        if migrated != profiles {
            try saveProfiles(migrated)
        }
        return migrated
    }

    public func saveProfiles(_ profiles: [AccountProfile]) throws {
        try ensureDirectory()
        let data = try JSONEncoder.appEncoder.encode(profiles)
        try data.write(to: profilesURL, options: [.atomic])
    }

    public func loadUsageSnapshots() throws -> [UUID: UsageSnapshot] {
        try ensureDirectory()
        guard fileManager.fileExists(atPath: usageSnapshotsURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: usageSnapshotsURL)
        let snapshots = try JSONDecoder.appDecoder.decode([UsageSnapshot].self, from: data)
        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.accountID, $0) })
    }

    public func saveUsageSnapshots(_ snapshots: [UUID: UsageSnapshot]) throws {
        try ensureDirectory()
        let ordered = snapshots.values.sorted { $0.provider.rawValue + $0.accountID.uuidString < $1.provider.rawValue + $1.accountID.uuidString }
        let data = try JSONEncoder.appEncoder.encode(ordered)
        try data.write(to: usageSnapshotsURL, options: [.atomic])
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
    }

    private func migratePrimaryProfilesToDefaultStore(_ profiles: [AccountProfile]) -> [AccountProfile] {
        var migrated = profiles
        var seenProviders: Set<Provider> = []

        for index in migrated.indices {
            let provider = migrated[index].provider
            if seenProviders.insert(provider).inserted {
                if migrated[index].webDataStoreKind != .appDefault {
                    migrated[index].webDataStoreKind = .appDefault
                    migrated[index].updatedAt = Date()
                }
            } else if migrated[index].webDataStoreKind != .isolated {
                migrated[index].webDataStoreKind = .isolated
                migrated[index].updatedAt = Date()
            }
        }

        return migrated
    }
}

public extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
