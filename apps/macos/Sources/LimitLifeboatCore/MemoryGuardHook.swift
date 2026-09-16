import Foundation

/// The Memory Guard reading the app publishes for the Claude Code hook (and
/// anything else) to read without linking against the app.
public struct MemoryGuardState: Codable, Equatable, Sendable {
    public let level: String
    /// Whole epoch seconds, so the shell hook can compare it with `date +%s`.
    public let updatedAt: Int
    public let sessionCount: Int
    public let sessionFootprintBytes: UInt64
    public let availableBytes: UInt64
    public let message: String

    public init(assessment: MemoryGuardAssessment, now: Date) {
        switch assessment.level {
        case .ok:
            level = "ok"
        case .caution:
            level = "caution"
        case .critical:
            level = "critical"
        }
        updatedAt = Int(now.timeIntervalSince1970)
        sessionCount = assessment.sessionCount
        sessionFootprintBytes = assessment.sessionFootprintBytes
        availableBytes = assessment.availableBytes
        let sessions = assessment.sessionCount == 1 ? "1 agent session uses" : "\(assessment.sessionCount) agent sessions use"
        var message = "\(sessions) \(MemoryFormatting.bytes(assessment.sessionFootprintBytes)), \(MemoryFormatting.bytes(assessment.availableBytes)) free."
        if let idle = assessment.heaviestIdleSession {
            message += " Heaviest idle: \(idle.projectName) (\(MemoryFormatting.bytes(idle.footprintBytes)))."
        }
        self.message = message
    }

    public static let fileName = "memory-guard.json"

    public func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

public enum MemoryGuardHookScript {
    public static let fileName = "limit-lifeboat-memory-guard.sh"
    /// Seconds after which the published state is treated as absent — the app
    /// is not running, and old data must never block anyone.
    public static let staleAfterSeconds = 300
    /// A held session starts anyway when the prompt is resubmitted within this.
    public static let overrideWindowSeconds = 600

    public static func contents(stateFile: URL, heldDirectory: URL) -> String {
        """
        #!/bin/sh
        # Installed by Limit Lifeboat (Settings > Sessions & Memory).
        # Holds the first prompt of a new Claude Code session while memory is
        # critically low. Submitting again within \(overrideWindowSeconds / 60) minutes starts it anyway.
        # Running sessions, resumed conversations and subagents are never held.
        STATE=\(shellQuoted(stateFile.path))
        HELD_DIR=\(shellQuoted(heldDirectory.path))
        input=$(cat)
        field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

        [ -f "$STATE" ] || exit 0
        [ "$(/usr/bin/plutil -extract level raw -o - "$STATE" 2>/dev/null)" = "critical" ] || exit 0
        updated=$(/usr/bin/plutil -extract updatedAt raw -o - "$STATE" 2>/dev/null)
        now=$(/bin/date +%s)
        case "$updated" in ''|*[!0-9]*) exit 0 ;; esac
        [ $((now - updated)) -le \(staleAfterSeconds) ] || exit 0

        [ "$(field hook_event_name)" = "UserPromptSubmit" ] || exit 0
        [ -z "$(field agent_id)" ] || exit 0
        transcript=$(field transcript_path)
        if [ -n "$transcript" ] && [ -f "$transcript" ] && /usr/bin/grep -q '"type":"assistant"' "$transcript"; then
          exit 0
        fi

        session=$(field session_id | /usr/bin/tr -cd 'A-Za-z0-9-')
        marker="$HELD_DIR/held-${session:-unknown}"
        if [ -f "$marker" ] && [ $((now - $(/usr/bin/stat -f %m "$marker"))) -le \(overrideWindowSeconds) ]; then
          /bin/rm -f "$marker"
          exit 0
        fi
        /bin/mkdir -p "$HELD_DIR" && : > "$marker"

        message=$(/usr/bin/plutil -extract message raw -o - "$STATE" 2>/dev/null)
        echo "Limit Lifeboat held this new session because memory is critically low. $message Close an idle session first, or submit again to start anyway." >&2
        exit 2
        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Adds or removes the Memory Guard `UserPromptSubmit` hook in Claude Code's
/// user settings, leaving every other setting and hook untouched.
public struct ClaudeHookInstaller {
    public enum InstallerError: LocalizedError, Equatable {
        case unreadableSettings(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableSettings(let detail):
                return "Claude Code settings could not be read as JSON, so they were left unchanged. \(detail)"
            }
        }
    }

    private static let event = "UserPromptSubmit"
    private let settingsURL: URL
    private let fileManager: FileManager

    public init(
        settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"),
        fileManager: FileManager = .default
    ) {
        // Dotfile setups often symlink settings.json; write the real file.
        self.settingsURL = settingsURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    public func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return entries(in: settings).contains(where: Self.isManaged)
    }

    public func install(scriptPath: String) throws {
        var settings = try readSettings()
        let command = MemoryGuardHookScript.shellQuoted(scriptPath)
        let managed: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": 5]]
        ]
        var entries = entries(in: settings).filter { !Self.isManaged($0) }
        entries.append(managed)
        setEntries(entries, in: &settings)
        try writeSettings(settings)
    }

    public func uninstall() throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        var settings = try readSettings()
        let current = entries(in: settings)
        let remaining = current.filter { !Self.isManaged($0) }
        guard remaining.count != current.count else { return }
        setEntries(remaining, in: &settings)
        try writeSettings(settings)
    }

    private static func isManaged(_ entry: [String: Any]) -> Bool {
        let hooks = entry["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { ($0["command"] as? String)?.contains(MemoryGuardHookScript.fileName) == true }
    }

    private func entries(in settings: [String: Any]) -> [[String: Any]] {
        (settings["hooks"] as? [String: Any])?[Self.event] as? [[String: Any]] ?? []
    }

    private func setEntries(_ entries: [[String: Any]], in settings: inout [String: Any]) {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        hooks[Self.event] = entries.isEmpty ? nil : entries
        settings["hooks"] = hooks.isEmpty ? nil : hooks
    }

    private func readSettings() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return [:]
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallerError.unreadableSettings("The top level is not an object.")
            }
            return object
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.unreadableSettings(error.localizedDescription)
        }
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("limit-lifeboat-backup")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
    }
}
