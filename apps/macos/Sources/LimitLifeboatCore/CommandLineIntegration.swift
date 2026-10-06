import Foundation

/// Links the bundled `limit-lifeboat` tool into `~/.local/bin`. A symlink, not
/// a copy, so Sparkle updates to the app update the command too. Never
/// replaces a file it did not create.
public struct CommandLineToolInstaller {
    public enum Status: Equatable {
        case notInstalled
        case installed
        /// Something else already lives at the link path (a self-built copy,
        /// another app's link); left alone.
        case occupied
    }

    public enum InstallerError: LocalizedError, Equatable {
        case occupied(String)
        case temporaryLocation

        public var errorDescription: String? {
            switch self {
            case .occupied(let path):
                return "\(path) already exists and wasn't installed by Limit Lifeboat, so it was left alone. Remove it to use the bundled command."
            case .temporaryLocation:
                return "Limit Lifeboat is running from a disk image or a temporary location, so a link to it would break. Move the app to Applications, open it from there, and try again."
            }
        }
    }

    public static let commandName = "limit-lifeboat"

    public let linkURL: URL
    private let fileManager: FileManager

    public init(
        linkURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/\(CommandLineToolInstaller.commandName)"),
        fileManager: FileManager = .default
    ) {
        self.linkURL = linkURL
        self.fileManager = fileManager
    }

    /// `Contents/Helpers/limit-lifeboat` inside the running app, when present.
    public static func bundledTool(in bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(commandName)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public func status(bundledTool: URL) -> Status {
        guard let destination = linkDestination() else {
            return fileManager.fileExists(atPath: linkURL.path) ? .occupied : .notInstalled
        }
        if destination == bundledTool.standardizedFileURL.path { return .installed }
        return isOurs(destination) ? .notInstalled : .occupied
    }

    public func install(bundledTool: URL) throws {
        guard !Self.isTemporaryLocation(bundledTool) else { throw InstallerError.temporaryLocation }
        switch status(bundledTool: bundledTool) {
        case .installed:
            return
        case .occupied:
            throw InstallerError.occupied(linkURL.path)
        case .notInstalled:
            try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A link to an older or moved copy of this app is ours to replace.
            if linkDestination() != nil {
                try fileManager.removeItem(at: linkURL)
            }
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: bundledTool)
        }
    }

    public func uninstall() throws {
        guard let destination = linkDestination(), isOurs(destination) else { return }
        try fileManager.removeItem(at: linkURL)
    }

    /// At launch: if our link points at another copy of the app (it was moved
    /// or updated in place elsewhere), point it at this one. The user opted in
    /// already; a stale link would leave Claude Code's status line blank.
    /// Never creates a link that doesn't exist, never touches others' files.
    @discardableResult
    public func repointIfMoved(bundledTool: URL) -> Bool {
        guard !Self.isTemporaryLocation(bundledTool),
              let destination = linkDestination(),
              isOurs(destination),
              destination != bundledTool.standardizedFileURL.path else { return false }
        do {
            try fileManager.removeItem(at: linkURL)
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: bundledTool)
            return true
        } catch {
            return false
        }
    }

    /// A mounted disk image (read-only) or Gatekeeper's App Translocation:
    /// both vanish. Apps kept on a writable external drive are fine.
    static func isTemporaryLocation(_ url: URL) -> Bool {
        if url.standardizedFileURL.path.contains("/AppTranslocation/") { return true }
        let readOnly = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        return readOnly == true
    }

    /// The symlink's target, or nil when there is no symlink at the path.
    private func linkDestination() -> String? {
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else { return nil }
        let resolved = raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : linkURL.deletingLastPathComponent().appendingPathComponent(raw)
        return resolved.standardizedFileURL.path
    }

    /// A link into any Limit Lifeboat app bundle's Helpers directory.
    private func isOurs(_ destination: String) -> Bool {
        destination.hasSuffix(".app/Contents/Helpers/\(Self.commandName)")
            && destination.contains("Limit Lifeboat")
    }
}

/// Points Claude Code's `statusLine` at `limit-lifeboat statusline`. Only
/// ever sets it when none is configured, and only ever removes its own.
public struct ClaudeStatusLineInstaller {
    public enum Status: Equatable {
        case notSet
        case installed
        /// The user already has their own status line; never overwritten.
        case other(String)
    }

    public enum InstallerError: LocalizedError, Equatable {
        case otherStatusLine(String)

        public var errorDescription: String? {
            switch self {
            case .otherStatusLine(let command):
                return "Claude Code already has a status line (\(command)), so it was left unchanged. Add `limit-lifeboat statusline` to it yourself, or remove it first."
            }
        }
    }

    private let file: ClaudeSettingsFile

    public init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) {
        self.file = ClaudeSettingsFile(url: settingsURL)
    }

    public static func command(toolPath: String) -> String {
        "\(MemoryGuardHookScript.shellQuoted(toolPath)) statusline"
    }

    public func status() -> Status {
        guard let settings = try? file.read(),
              let statusLine = settings["statusLine"] as? [String: Any] else {
            return .notSet
        }
        let command = statusLine["command"] as? String ?? ""
        return Self.isOurs(command) ? .installed : .other(command)
    }

    public func install(toolPath: String) throws {
        var settings = try file.read()
        if let existing = settings["statusLine"] as? [String: Any] {
            let command = existing["command"] as? String ?? ""
            guard Self.isOurs(command) else { throw InstallerError.otherStatusLine(command) }
        }
        settings["statusLine"] = ["type": "command", "command": Self.command(toolPath: toolPath)]
        try file.write(settings)
    }

    public func uninstall() throws {
        guard file.exists else { return }
        var settings = try file.read()
        guard let existing = settings["statusLine"] as? [String: Any],
              Self.isOurs(existing["command"] as? String ?? "") else { return }
        settings["statusLine"] = nil
        try file.write(settings)
    }

    /// Exactly what this installer writes, or the README's hand-written
    /// form; never a longer command that merely mentions the tool.
    static func isOurs(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed == "\(CommandLineToolInstaller.commandName) statusline" { return true }
        guard trimmed.hasSuffix("' statusline"), trimmed.hasPrefix("'") else { return false }
        let path = String(trimmed.dropFirst().dropLast("' statusline".count))
        return !path.contains("'") && path.hasSuffix("/\(CommandLineToolInstaller.commandName)")
    }
}
