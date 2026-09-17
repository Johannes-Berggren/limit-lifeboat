import Foundation

/// Claude Code's user settings file, read and written as plain JSON. Writes
/// keep a one-step backup and never touch a file that does not parse.
public struct ClaudeSettingsFile {
    public enum SettingsError: LocalizedError, Equatable {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "Claude Code settings could not be read as JSON, so they were left unchanged. \(detail)"
            }
        }
    }

    public let url: URL
    private let fileManager: FileManager

    public init(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        fileManager: FileManager = .default
    ) {
        // Dotfile setups often symlink settings.json; write the real file.
        self.url = url.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    public var exists: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func read() throws -> [String: Any] {
        guard exists else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return [:]
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SettingsError.unreadable(error.localizedDescription)
        }
        guard let settings = object as? [String: Any] else {
            throw SettingsError.unreadable("The top level is not an object.")
        }
        return settings
    }

    /// Note: keys come out sorted — JSONSerialization cannot keep the
    /// original order, and sorted is at least stable across writes.
    public func write(_ settings: [String: Any]) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists {
            let backup = url.appendingPathExtension("limit-lifeboat-backup")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}
