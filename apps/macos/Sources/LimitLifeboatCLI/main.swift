import Foundation
import LimitLifeboatCore

// The `limit-lifeboat` command-line tool.
//
// The read commands report what the menu-bar app last recorded and how old
// that is; they never contact a provider and never write to the store. Two
// reasons, and both are load-bearing:
//
//   1. A status line redraws on every shell prompt. Anything that made a
//      network call there would burn quota to report on quota.
//   2. Switching needs Claude Code's provider-owned Keychain item, whose ACL
//      trusts specific code signatures. A separate binary cannot write it
//      without its own authorization prompt, and a second writer racing the
//      app is exactly the failure this project exists to avoid.
//
// `refresh` and `switch` therefore do not do the work themselves: they ask the
// running app over its control socket (ControlSocket.swift), and the app runs
// its own refresh and switch workflows. This binary still never reads or
// writes a credential. With the app closed they fail with `app_not_running`.
//
// Exit codes: 0 success, 1 usage error, 2 could not read the store,
// 3 `preflight` found memory critically low, 4 the app is not running,
// 5 the app could not complete `refresh` or `switch`.

let version = "1.1.0"

enum ExitCode: Int32 {
    case success = 0
    case usage = 1
    case unavailable = 2
    case memoryCritical = 3
    case appNotRunning = 4
    case commandFailed = 5
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data("limit-lifeboat: \(message)\n".utf8))
    exit(code.rawValue)
}

let usageText = """
limit-lifeboat \(version) — read the Limit Lifeboat account store, and ask the app to act

USAGE
  limit-lifeboat <command> [options]

READ (from the app's local store; work with the app closed)
  status     Every saved account with its most recent usage reading
  list       Saved accounts, without usage
  active     Only the account each provider's CLI is currently logged into
  history    Saved-account usage history (default the last 7 days)
  sessions   Running Claude Code and Codex sessions, per provider
  statusline One compact line for a shell prompt, tmux, or Claude Code
  preflight  Whether memory has room for another agent session (exit 3 when
             critically low); reads this Mac directly, not the store
  version    Print the version

ACT (asks the running app; exit 4 when it is not running)
  refresh [account-id]  Refresh usage, for one account or all of them
  switch <account-id>   Switch that provider's CLI to the account

OPTIONS
  --json        Machine-readable output (schema \(CLIStatusReport.schemaVersion)), see docs/cli.md
  --schema 1    status/list/active: the exact schema 1 document
  --detail      status/list/active: add each account's issues
  --days N      history: days to include, 1-\(CLIHistoryReport.maximumDays) (default \(CLIHistoryReport.defaultDays))
  -h, --help    Show this help

NOTES
  Readings come from the menu-bar app's local store, so they are as fresh as
  its last refresh. Every reading carries `ageSeconds` — check it before
  trusting a number. This tool never contacts Anthropic or OpenAI and never
  touches a credential: refresh and switch run inside the app, through the
  same workflows as its buttons. Capture, rename and remove stay in the app.
  Memory pressure and room for more sessions are in `preflight --json`.

EXAMPLES
  limit-lifeboat status --json --detail | jq '.accounts[] | {label, issues}'
  limit-lifeboat active --json | jq -r '.accounts[0].reading.mostConstrainedPercent'
  limit-lifeboat history --json --days 3 | jq '.accounts[0].records | length'
  limit-lifeboat sessions --json | jq '.providers[] | {provider, count}'
  limit-lifeboat switch "$(limit-lifeboat list --json | jq -r '.accounts[1].id')"

  # Claude Code statusLine, in ~/.claude/settings.json:
  #   "statusLine": { "type": "command", "command": "limit-lifeboat statusline" }
  # A trailing ! means warning or depleted, ? means the reading is over 30m old.
  # Inside Claude Code it also shows the session's prompt cache ("cache 42m"
  # left, or "cache cold 350K" to re-read) and uses Claude Code's own 5h/7d
  # numbers when the app's reading is stale.

  # Refuse to start another agent when memory is critical:
  #   limit-lifeboat preflight && claude
"""

// MARK: - Arguments

var positional: [String] = []
var wantsJSON = false
var wantsDetail = false
var days = CLIHistoryReport.defaultDays
var schema = CLIStatusReport.schemaVersion
do {
    var remaining = Array(CommandLine.arguments.dropFirst())[...]
    func value(for flag: String) -> String {
        guard let next = remaining.popFirst() else { fail("\(flag) needs a value. Run --help.", .usage) }
        return next
    }
    while let argument = remaining.popFirst() {
        switch argument {
        case "--json": wantsJSON = true
        case "--detail": wantsDetail = true
        case "-h", "--help":
            print(usageText)
            exit(ExitCode.success.rawValue)
        case "--days":
            guard let parsed = Int(value(for: argument)), (1...CLIHistoryReport.maximumDays).contains(parsed) else {
                fail("--days must be a whole number from 1 to \(CLIHistoryReport.maximumDays).", .usage)
            }
            days = parsed
        case "--schema":
            guard let parsed = Int(value(for: argument)), CLIStatusReport.supportedSchemaVersions.contains(parsed) else {
                fail("--schema must be one of \(CLIStatusReport.supportedSchemaVersions.map(String.init).joined(separator: ", ")).", .usage)
            }
            schema = parsed
        default:
            if argument.hasPrefix("-"), argument.count > 1 {
                fail("unknown option '\(argument)'. Run --help.", .usage)
            }
            positional.append(argument)
        }
    }
}

guard let command = positional.first else {
    print(usageText)
    exit(ExitCode.usage.rawValue)
}
let operands = Array(positional.dropFirst())
let maxOperands = ["refresh": 1, "switch": 1][command] ?? 0
if operands.count > maxOperands {
    fail("unexpected argument '\(operands[maxOperands])'. Run --help.", .usage)
}

func printJSON<T: Encodable>(_ value: T) {
    guard let text = try? CLIReadCommandOutput.encode(value) else {
        fail("could not encode the report.", .unavailable)
    }
    print(text)
}

// MARK: - Commands that need no store

if command == "version" || command == "--version" {
    print(wantsJSON
        ? #"{"version":"\#(version)","schema":\#(CLIStatusReport.schemaVersion),"supportedSchemas":[\#(CLIStatusReport.supportedSchemaVersions.map(String.init).joined(separator: ","))]}"#
        : version)
    exit(ExitCode.success.rawValue)
}

func runningSessions() -> (table: SystemProcessTable, sessions: [AgentSession]) {
    let table = SystemProcessTable()
    let sessions = AgentSessionCensusBuilder().sessions(
        from: table.records(),
        excludingDescendantsOf: ProcessInfo.processInfo.processIdentifier,
        workingDirectory: table.workingDirectory(pid:)
    )
    return (table, sessions)
}

if command == "preflight" {
    // Local and cheap (one process-table scan), so it is safe in a launcher
    // script. Its own lineage is skipped only as far as its descendants go.
    let sessions = runningSessions().sessions
    guard let memory = SystemMemoryReader().read() else {
        fail("could not read system memory statistics.", .unavailable)
    }
    // Same transcript pairing as the app, so "heaviest idle" names a session
    // that is actually idle rather than merely old.
    let lastActivity = ClaudeTranscriptReader().activities(for: sessions).mapValues(\.lastActivityAt)
    let assessment = MemoryGuardPolicy().assess(memory: memory, sessions: sessions, lastActivity: lastActivity, now: Date())
    let state = MemoryGuardState(assessment: assessment, now: Date())
    if wantsJSON {
        printJSON(state)
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

guard ["status", "list", "active", "statusline", "history", "sessions", "refresh", "switch"].contains(command) else {
    fail("unknown command '\(command)'. Run --help.", .usage)
}

let repository: ProfileRepository
do {
    repository = try ProfileRepository(applicationSupportDirectoryName: enclosingAppStoreName() ?? "LimitLifeboat")
} catch {
    fail("could not locate the account store: \(error.localizedDescription)", .unavailable)
}
let storeDirectory = repository.applicationSupportDirectory
let socketURL = ControlSocketClient.socketURL(applicationSupportDirectory: storeDirectory)

// MARK: - refresh / switch (through the app)

if command == "refresh" || command == "switch" {
    let accountID = operands.first
    if command == "switch", accountID == nil {
        fail("switch needs an account id. Find it with `limit-lifeboat list --json`.", .usage)
    }
    if let accountID, UUID(uuidString: accountID) == nil {
        fail("'\(accountID)' is not an account id. Find it with `limit-lifeboat list --json`.", .usage)
    }
    let request = ControlRequest(id: UUID().uuidString, command: command, accountId: accountID)
    // A full refresh or a Claude switch with its preflight can take a while.
    let outcome = ControlSocketClient.send(request, to: socketURL, timeout: 180)
    let response: ControlResponse
    switch outcome {
    case .success(let answer): response = answer
    case .failure(let error): response = .failure(error, id: request.id)
    }

    if wantsJSON {
        printJSON(CLIControlOutput(response: response))
    } else if let result = response.result, response.ok {
        print(CLIControlOutput.text(for: result))
    } else if let error = response.error {
        FileHandle.standardError.write(Data("limit-lifeboat: \(error.message)\n".utf8))
    }
    if response.ok { exit(ExitCode.success.rawValue) }
    exit(response.error?.code == ControlError.appNotRunning.code ? ExitCode.appNotRunning.rawValue : ExitCode.commandFailed.rawValue)
}

// MARK: - sessions

if command == "sessions" {
    let sessions = runningSessions().sessions
    let report = CLISessionsReportBuilder.report(
        sessions: sessions,
        activities: ClaudeTranscriptReader().activities(for: sessions),
        parked: CLISessionsReportBuilder.readParked(applicationSupportDirectory: storeDirectory)
    )
    if wantsJSON {
        printJSON(report)
    } else {
        for group in report.providers {
            print("[\(group.provider)] \(group.count) session\(group.count == 1 ? "" : "s"), \(MemoryFormatting.bytes(group.memoryBytes))")
            for session in group.sessions {
                var details = [MemoryFormatting.bytes(session.memoryBytes)]
                if let model = session.model { details.append(ModelNaming.short(model)) }
                if let tokens = session.contextTokens, tokens > 0 { details.append("\(MemoryFormatting.tokens(tokens)) context") }
                if let idle = session.idleSeconds { details.append("idle \(DurationPhrase.short(TimeInterval(idle)))") }
                if let parked = session.parked { details.append("parked (\(parked.reason))") }
                print("  \(session.pid) \(session.project) · \(details.joined(separator: " · "))")
            }
        }
    }
    exit(ExitCode.success.rawValue)
}

// MARK: - Store-backed reads

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
    let claude = StatusLineStdinReader.read(fd: STDIN_FILENO).flatMap(ClaudeStatusLineInput.parse)
    print(CLIStatusLine.text(for: report, claude: claude))
    exit(ExitCode.success.rawValue)
}

if command == "history" {
    let now = Date()
    let records: [UUID: [UsageHistoryRecord]]
    do {
        records = try CLIHistoryReportBuilder.readRecords(
            applicationSupportDirectory: storeDirectory,
            since: now.addingTimeInterval(-TimeInterval(days) * 86_400)
        )
    } catch {
        fail("could not read usage history: \(error.localizedDescription)", .unavailable)
    }
    let history = CLIHistoryReportBuilder.report(accounts: report.accounts, records: records, days: days, now: now)
    if wantsJSON {
        printJSON(history)
    } else {
        for account in history.accounts {
            let peak = account.records.flatMap(\.windows).map(\.usedPercent).max().map { ", peak \($0)%" } ?? ""
            print("[\(account.provider)] \(account.label): \(account.records.count) reading\(account.records.count == 1 ? "" : "s") in \(days)d\(peak)")
        }
    }
    exit(ExitCode.success.rawValue)
}

// status, list and active. Every path out of here prints something: 1.1.18
// lost this block and the three commands exited 0 with no output at all.
guard let readCommand = CLIReadCommand(rawValue: command) else {
    fail("unknown command '\(command)'. Run --help.", .usage)
}
let shown = wantsDetail
    ? CLIStatusReportBuilder.detailed(
        report,
        issueSnapshot: AccountIssueStore(applicationSupportDirectory: storeDirectory).read(),
        appRunning: ControlSocketClient.isListening(at: socketURL)
    )
    : report
do {
    print(try CLIReadCommandOutput.render(readCommand, report: shown, json: wantsJSON, schema: schema))
} catch {
    fail("could not encode the report.", .unavailable)
}
exit(ExitCode.success.rawValue)

/// When run from inside an app bundle (directly or through the
/// ~/.local/bin link), read that app's own store, so a development build's
/// bundled tool reports the development app rather than the release one.
func enclosingAppStoreName() -> String? {
    // argv[0] is a bare name when run from PATH; the loader's path is not.
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents",
          let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) else { return nil }
    return info["LimitLifeboatApplicationSupportDirectoryName"] as? String
}
