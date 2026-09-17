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
        // Only an actionable level is published: with no agent running there
        // is nothing to close, so nothing should be held back either.
        switch assessment.isActionable ? assessment.level : .ok {
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
    /// After holding one prompt, every prompt passes for this long, machine
    /// wide. One hold is the warning; repeating it would only get in the way —
    /// a headless retry or relaunch always arrives as a brand-new session.
    public static let holdIntervalSeconds = 3_600
    /// Setting this to `off` in the environment Claude Code runs in (an
    /// orchestrator, a script) disables the hold for those sessions.
    public static let bypassVariable = "LIMIT_LIFEBOAT_MEMORY_GUARD"

    public static func contents(stateFile: URL, heldDirectory: URL) -> String {
        """
        #!/bin/sh
        # Installed by Limit Lifeboat (Settings > Sessions & Memory).
        # Holds the first prompt of a new Claude Code session while memory is
        # critically low, at most once every \(holdIntervalSeconds / 60) minutes across the Mac:
        # the next prompt, from any session, goes through.
        # Running sessions, resumed conversations and subagents are never held.
        # Set \(bypassVariable)=off to skip the hold entirely.
        [ "$\(bypassVariable)" = "off" ] && exit 0
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

        # Check-and-claim must be atomic: an orchestrator starting several
        # sessions at once would otherwise see every one of them held. mkdir
        # either creates the lock or fails, so exactly one run can hold.
        # Anything that cannot be read or written lets the prompt through.
        age() { m=$(/usr/bin/stat -f %m "$1" 2>/dev/null) && echo $((now - m)); }
        /bin/mkdir -p "$HELD_DIR" 2>/dev/null || exit 0
        lock="$HELD_DIR/claiming"
        lock_age=$(age "$lock")
        if [ -n "$lock_age" ] && [ "$lock_age" -gt 60 ]; then
          /bin/rmdir "$lock" 2>/dev/null
        fi
        /bin/mkdir "$lock" 2>/dev/null || exit 0
        marker="$HELD_DIR/last-held"
        held_age=$(age "$marker")
        if [ -n "$held_age" ] && [ "$held_age" -le \(holdIntervalSeconds) ]; then
          /bin/rmdir "$lock"
          exit 0
        fi
        if ! : > "$marker" 2>/dev/null; then
          /bin/rmdir "$lock"
          exit 0
        fi
        /bin/rmdir "$lock"

        message=$(/usr/bin/plutil -extract message raw -o - "$STATE" 2>/dev/null)
        echo "Limit Lifeboat held this new session because memory is critically low. $message Close an idle session first, or submit again to start anyway — nothing else is held for the next hour." >&2
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
        case unexpectedHooksShape

        public var errorDescription: String? {
            switch self {
            case .unexpectedHooksShape:
                return "The hooks in Claude Code settings are not in the shape Limit Lifeboat expects, so they were left unchanged."
            }
        }
    }

    public enum Status: Equatable {
        case notInstalled
        case installed
        /// Installed, but pointing at a different script path (the app moved
        /// or its data directory changed) — every prompt would run a missing
        /// or stale script.
        case needsRepair
    }

    private static let event = "UserPromptSubmit"
    private let file: ClaudeSettingsFile

    public init(settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")) {
        self.file = ClaudeSettingsFile(url: settingsURL)
    }

    public func status(expectedScriptPath: String) -> Status {
        guard let settings = try? file.read(), let entries = try? entries(in: settings) else {
            return .notInstalled
        }
        let commands = entries.flatMap(Self.managedCommands)
        guard !commands.isEmpty else { return .notInstalled }
        let expected = MemoryGuardHookScript.shellQuoted(expectedScriptPath)
        return commands.allSatisfy { $0 == expected } ? .installed : .needsRepair
    }

    public func install(scriptPath: String) throws {
        var settings = try file.read()
        let command = MemoryGuardHookScript.shellQuoted(scriptPath)
        let managed: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": 5]]
        ]
        var entries = try entries(in: settings).filter { Self.managedCommands($0).isEmpty }
        entries.append(managed)
        try setEntries(entries, in: &settings)
        try file.write(settings)
    }

    public func uninstall() throws {
        guard file.exists else { return }
        var settings = try file.read()
        let current = try entries(in: settings)
        let remaining = current.filter { Self.managedCommands($0).isEmpty }
        guard remaining.count != current.count else { return }
        try setEntries(remaining, in: &settings)
        try file.write(settings)
    }

    private static func managedCommands(_ entry: [String: Any]) -> [String] {
        (entry["hooks"] as? [[String: Any]] ?? [])
            .compactMap { $0["command"] as? String }
            .filter { $0.contains(MemoryGuardHookScript.fileName) }
    }

    /// Refuses anything but the documented shape rather than coercing it:
    /// coercing an unexpected-but-valid value to empty would silently drop the
    /// user's own hooks on the next write.
    private func entries(in settings: [String: Any]) throws -> [[String: Any]] {
        guard let rawHooks = settings["hooks"] else { return [] }
        guard let hooks = rawHooks as? [String: Any] else { throw InstallerError.unexpectedHooksShape }
        guard let rawEntries = hooks[Self.event] else { return [] }
        guard let entries = rawEntries as? [[String: Any]] else { throw InstallerError.unexpectedHooksShape }
        return entries
    }

    private func setEntries(_ entries: [[String: Any]], in settings: inout [String: Any]) throws {
        var hooks: [String: Any] = [:]
        if let rawHooks = settings["hooks"] {
            guard let existing = rawHooks as? [String: Any] else { throw InstallerError.unexpectedHooksShape }
            hooks = existing
        }
        hooks[Self.event] = entries.isEmpty ? nil : entries
        settings["hooks"] = hooks.isEmpty ? nil : hooks
    }
}
