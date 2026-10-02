import Foundation

/// Which agent sessions are parked, published for the park hook. The hook
/// finds its own session by walking up its parent processes to a parked pid,
/// so it never depends on matching transcripts to processes.
public struct SessionParkState: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// Parked by hand; stays parked until resumed.
        case manual
        /// Parked to stretch a quota; resumes on its own at `releaseAt`.
        case shortfall
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        /// Process start time, so a reused pid never inherits a park.
        public var startedAt: Date
        public var project: String
        public var reason: Reason
        public var parkedAt: Date
        /// When the quota this park protects comes back.
        public var releaseAt: Date?
        /// The account whose quota this park protects; switching away from
        /// it makes the park pointless.
        public var profileID: UUID?

        public init(
            pid: Int32,
            startedAt: Date,
            project: String,
            reason: Reason,
            parkedAt: Date,
            releaseAt: Date? = nil,
            profileID: UUID? = nil
        ) {
            self.pid = pid
            self.startedAt = startedAt
            self.project = project
            self.reason = reason
            self.parkedAt = parkedAt
            self.releaseAt = releaseAt
            self.profileID = profileID
        }
    }

    /// Whole epoch seconds: the app's heartbeat. Older than
    /// `SessionParkHookScript.staleAfterSeconds` releases everyone, so a
    /// quit or crashed app never leaves a session stuck.
    public var updatedAt: Int
    /// " 123 456 " — the parked pids, space-delimited for a shell `case`.
    public var pids: String
    public var parked: [Entry]

    public init(parked: [Entry], now: Date) {
        self.updatedAt = Int(now.timeIntervalSince1970)
        self.parked = parked
        self.pids = " " + parked.map { String($0.pid) }.joined(separator: " ") + " "
    }

    public static let fileName = "session-park.json"

    /// With nothing parked the file is removed instead: the hook's first
    /// check is whether it exists, so every tool call in every session stays
    /// a single `test -f` until something is actually parked.
    public func write(to url: URL) throws {
        guard !parked.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum SessionParkHookScript {
    public static let fileName = "limit-lifeboat-park.sh"
    public static let staleAfterSeconds = 300
    /// Claude Code lets a tool run once its hook times out, so the hook gives
    /// up first and denies the call with a "wait and retry" reason; the retry
    /// parks again. No maximum timeout is documented; three hours outlasts
    /// most of a session window.
    public static let timeoutSeconds = 3 * 3600
    public static let deadlineSeconds = timeoutSeconds - 60
    public static let pollSeconds = 5
    public static let bypassVariable = "LIMIT_LIFEBOAT_PARK"

    public static let hook = ClaudeHookInstaller.Hook(
        event: "PreToolUse",
        scriptFileName: fileName,
        timeoutSeconds: timeoutSeconds,
        matcher: "*"
    )

    static let denyReason = "Limit Lifeboat parked this session to save quota for higher-priority work. It resumes when the user releases it or the limit resets. Do not work around this: wait, then retry the same tool call."

    public static func contents(
        stateFile: URL,
        waitingDirectory: URL,
        pollSeconds: Int = pollSeconds,
        deadlineSeconds: Int = deadlineSeconds
    ) -> String {
        let deny = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"\#(denyReason)"}}"#
        return """
        #!/bin/sh
        # Installed by Limit Lifeboat. Parks a Claude Code session at its next
        # tool call while Limit Lifeboat has it parked to save quota, and lets
        # it continue the moment it is resumed. Sessions that are not parked
        # pass straight through. Anything unreadable, or an app that stopped
        # updating its state, lets the session continue.
        # Set \(bypassVariable)=off to never park.
        [ "$\(bypassVariable)" = "off" ] && exit 0
        STATE=\(MemoryGuardHookScript.shellQuoted(stateFile.path))
        WAITING=\(MemoryGuardHookScript.shellQuoted(waitingDirectory.path))
        cat > /dev/null
        [ -f "$STATE" ] || exit 0

        load() {
          pids=$(/usr/bin/plutil -extract pids raw -o - "$STATE" 2>/dev/null)
          updated=$(/usr/bin/plutil -extract updatedAt raw -o - "$STATE" 2>/dev/null)
          case "$updated" in ''|*[!0-9]*) return 1 ;; esac
          [ $(($(/bin/date +%s) - updated)) -le \(staleAfterSeconds) ]
        }
        load || exit 0
        case "$pids" in *[0-9]*) ;; *) exit 0 ;; esac

        # Which session is this? The agent process is an ancestor of the hook.
        owner=""
        p=$PPID
        i=0
        while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$i" -lt 16 ]; do
          case "$pids" in *" $p "*) owner=$p; break ;; esac
          p=$(/bin/ps -o ppid= -p "$p" 2>/dev/null | /usr/bin/tr -d ' ')
          i=$((i + 1))
        done
        [ -n "$owner" ] || exit 0

        /bin/mkdir -p "$WAITING" 2>/dev/null
        marker="$WAITING/$owner"
        : > "$marker" 2>/dev/null
        trap '/bin/rm -f "$marker"' EXIT
        trap 'exit 0' TERM INT HUP
        started=$(/bin/date +%s)
        while :; do
          /bin/sleep \(pollSeconds)
          load || exit 0
          case "$pids" in *" $owner "*) ;; *) exit 0 ;; esac
          if [ $(($(/bin/date +%s) - started)) -ge \(deadlineSeconds) ]; then
            printf '%s\\n' \(MemoryGuardHookScript.shellQuoted(deny))
            exit 0
          fi
        done
        """
    }
}
