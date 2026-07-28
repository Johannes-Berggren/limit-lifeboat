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
// Exit codes: 0 success, 1 usage error, 2 could not read the store.

let version = "1.0.0"

enum ExitCode: Int32 {
    case success = 0
    case usage = 1
    case unavailable = 2
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
    // Deliberately does not read stdin, even though Claude Code pipes its
    // session JSON in. Draining it would block until EOF, and a status line
    // gets invoked from shell prompts, tmux, and bar widgets that hand over an
    // inherited descriptor nobody ever closes — one hung read there freezes the
    // user's prompt. The payload has nothing this needs anyway: the missing
    // piece is the cross-account view, which it does not carry. Claude Code
    // tolerates an unread stdin.
    print(CLIStatusLine.text(for: report))
    exit(ExitCode.success.rawValue)
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
