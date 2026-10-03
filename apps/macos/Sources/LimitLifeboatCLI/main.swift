import Foundation
import LimitLifeboatCore

// The `limit-lifeboat` command-line tool.
//
// Read-only by design. It reports what the menu-bar app last recorded and how
// old that is; it never contacts a provider and never writes to the store.
// Two reasons, and both are load-bearing:
//
//   1. A status line redraws on every shell prompt. Anything that made a
//      network call there would burn quota to report on quota.
//   2. Switching needs Claude Code's provider-owned Keychain item, whose ACL
//      trusts specific code signatures. A separate binary cannot write it
//      without its own authorization prompt, and a second writer racing the
//      app is exactly the failure this project exists to avoid. Switching
//      stays in the app until there is a real IPC path to it.
//
// Exit codes: 0 success, 1 usage error, 2 could not read the store,
// 3 `preflight` found memory critically low.

let version = "1.0.0"

enum ExitCode: Int32 {
    case success = 0
    case usage = 1
    case unavailable = 2
    case memoryCritical = 3
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("limit-lifeboat: \(message)\n".utf8))
    exit(code.rawValue)
}

let usageText = """
limit-lifeboat \(version) — read the Limit Lifeboat account store

USAGE
  limit-lifeboat <command> [--json]

COMMANDS
  status     Every saved account with its most recent usage reading
  list       Saved accounts, without usage
  active     Only the account each provider's CLI is currently logged into
  statusline One compact line for a shell prompt, tmux, or Claude Code
  preflight  Whether memory has room for another agent session (exit 3 when
             critically low); reads this Mac directly, not the store
  version    Print the version

OPTIONS
  --json     Machine-readable output (schema \(CLIStatusReport.schemaVersion))
  -h, --help Show this help

NOTES
  Readings come from the menu-bar app's local store, so they are as fresh as
  its last refresh. Every reading carries `ageSeconds` — check it before
  trusting a number. This tool never contacts Anthropic or OpenAI, and never
  switches accounts; use the app for that.

EXAMPLES
  limit-lifeboat status
  limit-lifeboat status --json | jq '.accounts[] | select(.isActive)'
  limit-lifeboat active --json | jq -r '.accounts[0].reading.mostConstrainedPercent'

  # Claude Code statusLine, in ~/.claude/settings.json:
  #   "statusLine": { "type": "command", "command": "limit-lifeboat statusline" }
  # A trailing ! means warning or depleted, ? means the reading is over 30m old.
  # Inside Claude Code it also shows the session's prompt cache ("cache 42m"
  # left, or "cache cold 350K" to re-read) and uses Claude Code's own 5h/7d
  # numbers when the app's reading is stale.

  # Refuse to start another agent when memory is critical:
  #   limit-lifeboat preflight && claude
"""

var arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }

if arguments.contains("-h") || arguments.contains("--help") {
    print(usageText)
    exit(ExitCode.success.rawValue)
}

guard let command = arguments.first else {
    print(usageText)
    exit(ExitCode.usage.rawValue)
}

if arguments.count > 1 {
    fail("unexpected argument '\(arguments[1])'. Run --help.", .usage)
}

if command == "version" || command == "--version" {
    print(wantsJSON ? #"{"version":"\#(version)","schema":\#(CLIStatusReport.schemaVersion)}"# : version)
    exit(ExitCode.success.rawValue)
}

if command == "preflight" {
    // Local and cheap (one process-table scan), so it is safe in a launcher
    // script. Its own lineage is skipped only as far as its descendants go.
    let table = SystemProcessTable()
    let sessions = AgentSessionCensusBuilder().sessions(
        from: table.records(),
        excludingDescendantsOf: ProcessInfo.processInfo.processIdentifier,
        workingDirectory: table.workingDirectory(pid:)
    )
    guard let memory = SystemMemoryReader().read() else {
        fail("could not read system memory statistics.", .unavailable)
    }
    // Same transcript pairing as the app, so "heaviest idle" names a session
    // that is actually idle rather than merely old.
    let lastActivity = ClaudeTranscriptReader().activities(for: sessions).mapValues(\.lastActivityAt)
    let assessment = MemoryGuardPolicy().assess(memory: memory, sessions: sessions, lastActivity: lastActivity, now: Date())
    let state = MemoryGuardState(assessment: assessment, now: Date())
    if wantsJSON {
        guard let data = try? JSONEncoder.appEncoder.encode(state), let text = String(data: data, encoding: .utf8) else {
            fail("could not encode the report.", .unavailable)
        }
        print(text)
    } else {
        let headline: String
        switch assessment.isActionable ? assessment.level : .ok {
        case .ok:
            headline = "Memory OK"
        case .caution:
            headline = "Memory tight"
        case .critical:
            headline = "Memory critical"
        }
        let room = assessment.estimatedAdditionalSessions.map { " Room for about \($0) more." } ?? ""
        print("\(headline): \(state.message)\(room)")
    }
    exit(assessment.isActionable && assessment.level == .critical ? ExitCode.memoryCritical.rawValue : ExitCode.success.rawValue)
}

guard ["status", "list", "active", "statusline"].contains(command) else {
    fail("unknown command '\(command)'. Run --help.", .usage)
}

let repository: ProfileRepository
do {
    repository = try ProfileRepository()
} catch {
    fail("could not locate the account store: \(error.localizedDescription)", .unavailable)
}

let report: CLIStatusReport
do {
    report = CLIStatusReportBuilder.report(
        profiles: try repository.readProfiles(),
        snapshots: command == "list" ? [:] : try repository.readUsageSnapshots()
    )
} catch {
    fail("could not read the account store: \(error.localizedDescription)", .unavailable)
}

if command == "statusline" {
    let claude = readStatusLineStdin().flatMap(ClaudeStatusLineInput.parse)
    print(CLIStatusLine.text(for: report, claude: claude))
    exit(ExitCode.success.rawValue)
}

/// Claude Code pipes its session JSON (prompt-cache state, 5h/7d limits) to a
/// status line. But this command also runs from shell prompts, tmux, and bar
/// widgets that hand over a terminal or an inherited descriptor nobody ever
/// closes, and one blocking read there freezes the user's prompt. So: never a
/// terminal, only a pipe or a file, and never longer than 150ms in total.
func readStatusLineStdin() -> Data? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    var info = stat()
    guard fstat(STDIN_FILENO, &info) == 0 else { return nil }
    let type = info.st_mode & S_IFMT
    guard type == S_IFIFO || type == S_IFREG else { return nil }

    let deadline = Date().addingTimeInterval(0.15)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while data.count < 1_048_576 {
        let remaining = Int32(deadline.timeIntervalSinceNow * 1_000)
        guard remaining > 0 else { break }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, remaining) > 0 else { break }
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}

let accounts = command == "active" ? report.accounts.filter(\.isActive) : report.accounts

if wantsJSON {
    let encoder = JSONEncoder.appEncoder
    let filtered = CLIStatusReport(generatedAt: report.generatedAt, accounts: accounts)
    guard let data = try? encoder.encode(filtered), let text = String(data: data, encoding: .utf8) else {
        fail("could not encode the report.", .unavailable)
    }
    print(text)
    exit(ExitCode.success.rawValue)
}

guard !accounts.isEmpty else {
    // Not an error: a fresh install with no accounts yet is a normal state, and
    // a status line calling this on every prompt should not see a failure.
    print(
        report.accounts.isEmpty
            ? "No accounts saved yet. Log in with `claude` or `codex login`, then open Limit Lifeboat."
            : "No account is currently active."
    )
    exit(ExitCode.success.rawValue)
}

for account in accounts {
    let marker = account.isActive ? "*" : " "
    let identity = account.email ?? account.organization ?? account.plan ?? ""
    let name = identity.isEmpty ? account.label : "\(account.label) (\(identity))"
    print("\(marker) [\(account.provider)] \(name)")

    guard command != "list" else { continue }

    guard let reading = account.reading else {
        print("      no reading yet")
        continue
    }

    for window in reading.windows {
        let resets = window.resetsAt.map { " · \(UsageResetTiming.compactText(resetDate: $0, resetDescription: nil) ?? "")" } ?? ""
        print("      \(window.label): \(window.usedPercent)% used [\(window.risk)]\(resets)")
    }
    if let extra = reading.extraUsage {
        print("      \(extra)")
    }
    print("      updated \(DurationPhrase.short(TimeInterval(reading.ageSeconds))) ago via \(reading.source)")
}

exit(ExitCode.success.rawValue)
