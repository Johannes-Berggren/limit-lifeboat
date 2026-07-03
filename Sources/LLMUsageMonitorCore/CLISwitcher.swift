import Foundation

public enum CLISwitcherError: Error, LocalizedError {
    case missingCredentials(String)
    case missingStoredSnapshot(UUID)
    case providerMismatch(expected: Provider, actual: Provider)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let path):
            return "No credential material was found at \(path)."
        case .missingStoredSnapshot(let id):
            return "No saved credential snapshot exists for account \(id.uuidString)."
        case .providerMismatch(let expected, let actual):
            return "Stored snapshot is for \(actual.displayName), not \(expected.displayName)."
        case .invalidJSON(let path):
            return "Could not parse JSON at \(path)."
        }
    }
}

public final class CLISwitcher {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let backupDirectory: URL
    private let credentialStore: CredentialStoreProtocol

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupDirectory: URL,
        credentialStore: CredentialStoreProtocol,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.backupDirectory = backupDirectory
        self.credentialStore = credentialStore
        self.fileManager = fileManager
    }

    public func captureAndStoreSnapshot(for profile: AccountProfile) throws -> CredentialSnapshot {
        let snapshot = try captureSnapshot(provider: profile.provider)
        try credentialStore.save(snapshot: snapshot, for: profile.id)
        return snapshot
    }

    public func captureSnapshot(provider: Provider) throws -> CredentialSnapshot {
        switch provider {
        case .codex:
            return try captureCodexSnapshot()
        case .claude:
            return try captureClaudeSnapshot()
        }
    }

    public func restoreSnapshot(for profile: AccountProfile) throws -> RestoreResult {
        guard let snapshot = try credentialStore.loadSnapshot(for: profile.id) else {
            throw CLISwitcherError.missingStoredSnapshot(profile.id)
        }

        guard snapshot.provider == profile.provider else {
            throw CLISwitcherError.providerMismatch(expected: profile.provider, actual: snapshot.provider)
        }

        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        var touched: [URL] = []
        var backups: [URL] = []

        for item in snapshot.items {
            let destination = resolve(relativePath: item.relativePath)
            if let backup = try backupExistingFile(destination, relativePath: item.relativePath) {
                backups.append(backup)
            }

            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch item.kind {
            case .fullFile:
                try item.contents.write(to: destination, options: [.atomic])
            case .jsonFields:
                try mergeJSONFields(item.contents, into: destination)
            }

            if let posixPermissions = item.posixPermissions {
                try fileManager.setAttributes([.posixPermissions: posixPermissions], ofItemAtPath: destination.path)
            } else {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            touched.append(destination)
        }

        return RestoreResult(touchedPaths: touched, backupURLs: backups)
    }

    public func hasStoredSnapshot(for profile: AccountProfile) throws -> Bool {
        try credentialStore.hasSnapshot(for: profile.id)
    }

    public func validateActiveLogin(provider: Provider) -> Bool {
        switch provider {
        case .codex:
            let authURL = resolve(relativePath: ".codex/auth.json")
            return fileManager.fileExists(atPath: authURL.path) && ((try? Data(contentsOf: authURL).isEmpty) == false)
        case .claude:
            if let fields = try? readClaudeConfigAuthFields(), !fields.isEmpty {
                return true
            }
            let claudeJSONURL = resolve(relativePath: ".claude.json")
            return containsAuthMaterial(in: claudeJSONURL)
        }
    }

    public func hasActiveProcesses(provider: Provider) -> Bool {
        switch provider {
        case .codex:
            return runPgrep(arguments: ["-x", "codex"])
        case .claude:
            return runPgrep(arguments: ["-f", "(^|/)claude( |$)|Claude Code"])
        }
    }

    private func captureCodexSnapshot() throws -> CredentialSnapshot {
        let relativePath = ".codex/auth.json"
        let authURL = resolve(relativePath: relativePath)
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CLISwitcherError.missingCredentials(authURL.path)
        }
        let data = try Data(contentsOf: authURL)
        guard !data.isEmpty else {
            throw CLISwitcherError.missingCredentials(authURL.path)
        }

        return CredentialSnapshot(
            provider: .codex,
            items: [
                CredentialSnapshotItem(
                    relativePath: relativePath,
                    kind: .fullFile,
                    contents: data,
                    posixPermissions: filePermissions(authURL)
                )
            ]
        )
    }

    private func captureClaudeSnapshot() throws -> CredentialSnapshot {
        var items: [CredentialSnapshotItem] = []

        let configRelativePath = "Library/Application Support/Claude/config.json"
        let fields = try readClaudeConfigAuthFields()
        if !fields.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            let configURL = resolve(relativePath: configRelativePath)
            items.append(
                CredentialSnapshotItem(
                    relativePath: configRelativePath,
                    kind: .jsonFields,
                    contents: data,
                    posixPermissions: filePermissions(configURL)
                )
            )
        }

        let claudeJSONRelativePath = ".claude.json"
        let claudeJSONURL = resolve(relativePath: claudeJSONRelativePath)
        if containsAuthMaterial(in: claudeJSONURL) {
            items.append(
                CredentialSnapshotItem(
                    relativePath: claudeJSONRelativePath,
                    kind: .fullFile,
                    contents: try Data(contentsOf: claudeJSONURL),
                    posixPermissions: filePermissions(claudeJSONURL)
                )
            )
        }

        guard !items.isEmpty else {
            throw CLISwitcherError.missingCredentials("Claude OAuth token cache")
        }

        return CredentialSnapshot(provider: .claude, items: items)
    }

    private func readClaudeConfigAuthFields() throws -> [String: Any] {
        let configURL = resolve(relativePath: "Library/Application Support/Claude/config.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(configURL.path)
        }

        let knownAuthKeys = [
            "oauth:tokenCache",
            "oauth:tokenCacheV2"
        ]

        var fields: [String: Any] = [:]
        for key in knownAuthKeys {
            if let value = object[key] {
                fields[key] = value
            }
        }
        return fields
    }

    private func mergeJSONFields(_ fieldsData: Data, into url: URL) throws {
        guard let fields = try JSONSerialization.jsonObject(with: fieldsData) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(url.path)
        }

        var destinationObject: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let destinationData = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: destinationData) as? [String: Any] else {
                throw CLISwitcherError.invalidJSON(url.path)
            }
            destinationObject = parsed
        }

        for (key, value) in fields {
            destinationObject[key] = value
        }

        let data = try JSONSerialization.data(withJSONObject: destinationObject, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    private func containsAuthMaterial(in url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsAuthMaterial(inJSONObject: json)
    }

    private func containsAuthMaterial(inJSONObject value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let lower = key.lowercased()
                if lower.contains("oauth")
                    || lower == "access_token"
                    || lower == "refresh_token"
                    || lower == "id_token"
                    || lower == "session_token" {
                    return true
                }
                if containsAuthMaterial(inJSONObject: nested) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsAuthMaterial(inJSONObject:))
        }
        return false
    }

    private func resolve(relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(homeDirectory) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }

    private func filePermissions(_ url: URL) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.posixPermissions] as? Int
    }

    private func backupExistingFile(_ url: URL, relativePath: String) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let directory = backupDirectory.appendingPathComponent(stamp, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let sanitized = relativePath
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "_")
        let destination = directory.appendingPathComponent(sanitized)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    private func runPgrep(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
