import Darwin
import Foundation
import LimitLifeboatCore
import os

enum ClaudeCodeUsageReaderError: Error, LocalizedError {
    case expectUnavailable
    case cliNotFound
    case timedOut
    case launchFailed(String)
    case noUsageFound

    var errorDescription: String? {
        switch self {
        case .expectUnavailable:
            return "/usr/bin/expect is not available, so Claude Code /usage cannot be automated."
        case .cliNotFound:
            return "The claude command could not be found. Install Claude Code or make sure `claude` is on your PATH."
        case .timedOut:
            return "Claude Code /usage timed out. Retry after confirming Claude Code can start normally in Terminal."
        case .launchFailed(let details):
            return "Claude Code /usage failed: \(details)"
        case .noUsageFound:
            return "Claude Code ran, but its /usage output was not recognized. A Claude Code update may have changed the format."
        }
    }
}

struct ClaudeCodeUsageReader {
    private let parser = ClaudeCodeUsageOutputParser()
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let timeoutSeconds: TimeInterval

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        timeoutSeconds: TimeInterval = 20
    ) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.timeoutSeconds = timeoutSeconds
    }

    func readUsage(oauthToken: String) async throws -> ClaudeCodeUsageReport {
        let output = try await runUsageProbe(oauthToken: oauthToken)
        guard let report = parser.parse(text: output) else {
            // Never log the raw output — the rendered TUI can contain account
            // details. The size alone tells apart "nothing rendered" from
            // "rendered but the format changed".
            AppLog.usage.error("Claude Code /usage output was not recognized (\(output.count, privacy: .public) characters captured)")
            throw ClaudeCodeUsageReaderError.noUsageFound
        }
        return report
    }

    private func runUsageProbe(oauthToken: String) async throws -> String {
        try await ClaudeCodeUsageLaunchGate.run(oauthToken: oauthToken) { oauthToken in
            try await Task.detached(priority: .utility) {
                try runExpectProbe(
                    homeDirectory: homeDirectory,
                    fileManager: fileManager,
                    timeoutSeconds: timeoutSeconds,
                    oauthToken: oauthToken
                )
            }.value
        }
    }
}

private func runExpectProbe(
    homeDirectory: URL,
    fileManager: FileManager,
    timeoutSeconds: TimeInterval,
    oauthToken: String
) throws -> String {
    let expectURL = URL(fileURLWithPath: "/usr/bin/expect")
    guard fileManager.fileExists(atPath: expectURL.path) else {
        throw ClaudeCodeUsageReaderError.expectUnavailable
    }

    let process = Process()
    process.executableURL = expectURL
    process.currentDirectoryURL = trustedClaudeWorkingDirectory(
        homeDirectory: homeDirectory,
        fileManager: fileManager
    )
    let discoveryEnvironment = ClaudeCodeProcessLaunchPolicy.discoveryEnvironment(
        homeDirectory: homeDirectory
    )
    let claudeCommand = try resolveClaudeCommand(
        homeDirectory: homeDirectory,
        fileManager: fileManager,
        environment: discoveryEnvironment
    )
    guard let credentialedEnvironment = ClaudeCodeProcessLaunchPolicy.credentialedEnvironment(
        homeDirectory: homeDirectory,
        oauthToken: oauthToken
    ) else {
        throw ClaudeCodeUsageReaderError.launchFailed("invalid OAuth credential")
    }
    process.environment = credentialedEnvironment
    AppLog.usage.info("Starting the Claude Code /usage probe via \(claudeCommand.executableURL.path, privacy: .public)")
    process.arguments = [
        "-c",
        try expectScript(command: claudeCommand)
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
    } catch {
        throw ClaudeCodeUsageReaderError.launchFailed(error.localizedDescription)
    }

    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        waitGroup.leave()
    }

    if waitGroup.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        AppLog.usage.error("The Claude Code /usage probe timed out after \(Int(timeoutSeconds), privacy: .public)s; killing it and its helper")
        terminate(process)
        throw ClaudeCodeUsageReaderError.timedOut
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: outputData, as: UTF8.self)
    let errorOutput = String(decoding: errorData, as: UTF8.self)

    guard process.terminationStatus == 0 else {
        let stderrSummary = errorOutput.isEmpty
            ? "no stderr"
            : "\(errorData.count) bytes of stderr"
        throw ClaudeCodeUsageReaderError.launchFailed(
            "exit \(process.terminationStatus), \(stderrSummary)"
        )
    }

    return output + "\n" + errorOutput
}

private struct ClaudeCommand {
    var executableURL: URL
    var arguments: [String]
}

private func resolveClaudeCommand(
    homeDirectory: URL,
    fileManager: FileManager,
    environment: [String: String]
) throws -> ClaudeCommand {
    for candidate in ClaudeCodeProcessLaunchPolicy.executableCandidates(
        homeDirectory: homeDirectory,
        environment: environment
    ) where fileManager.isExecutableFile(atPath: candidate.path) {
        // Discovery is filesystem-only. In particular, do not run `which` or
        // `claude --help` in an environment that could ever carry a token.
        return ClaudeCommand(executableURL: candidate, arguments: [])
    }
    throw ClaudeCodeUsageReaderError.cliNotFound
}

private func commandOutput(executableURL: URL, arguments: [String], environment: [String: String]) -> String {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: outputData + errorData, as: UTF8.self)
    } catch {
        return ""
    }
}

private func trustedClaudeWorkingDirectory(homeDirectory: URL, fileManager: FileManager) -> URL {
    let claudeJSONURL = homeDirectory.appendingPathComponent(".claude.json")
    guard let data = try? Data(contentsOf: claudeJSONURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let projects = object["projects"] as? [String: Any] else {
        return homeDirectory
    }

    let trustedProjects = projects.compactMap { path, value -> (url: URL, lastStartTime: Double)? in
        guard let dictionary = value as? [String: Any],
              dictionary["hasTrustDialogAccepted"] as? Bool == true else {
            return nil
        }

        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return (url, number(dictionary["lastStartTime"]) ?? 0)
    }

    return trustedProjects
        .max { left, right in left.lastStartTime < right.lastStartTime }?
        .url ?? homeDirectory
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? String {
        return Double(value)
    }
    return nil
}

private func expectScript(command: ClaudeCommand) throws -> String {
    let commandList = ([command.executableURL.path] + command.arguments)
        .map(tclQuotedString)
        .joined(separator: " ")

    return #"""
set timeout 6
log_user 1
set command [list \#(commandList)]
eval spawn -noecho $command
set child [exp_pid]
# Only the Claude child needs the credential. Remove it from Expect's own
# environment before any later helper command can be executed.
catch {unset env(CLAUDE_CODE_OAUTH_TOKEN)}
expect {
    -re {\$} {}
    -re {Try|Type /help|What do you want} {}
    -re {Do you trust|trust the files|Yes, proceed} {}
    timeout {}
    eof {}
}
send -- "/usage\r"
set timeout 10
expect {
    -re {does not include|Approximate} {}
    timeout {}
    eof {}
}
set timeout 2
expect {
    -re {.} { exp_continue }
    timeout {}
    eof {}
}
catch {exec /bin/kill -KILL $child}
after 200
exit 0
"""#
}

private func tclQuotedString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
    return "\"\(escaped)\""
}

/// Kills a timed-out expect probe and the claude helper it spawned. The
/// helper is found by walking the live process tree under the probe's PID
/// (collected before the parent dies and its children are reparented), so
/// only processes this probe started are ever touched — a claude session the
/// user is running themselves is never a candidate.
private func terminate(_ process: Process) {
    let descendants = descendantProcessIDs(of: process.processIdentifier)
    if process.isRunning {
        process.terminate()
        usleep(300_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    for pid in descendants {
        kill(pid, SIGKILL)
    }
}

private func descendantProcessIDs(of pid: pid_t) -> [pid_t] {
    var result: [pid_t] = []
    var frontier: [pid_t] = [pid]
    while let current = frontier.popLast() {
        let output = commandOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-P", String(current)],
            environment: ProcessInfo.processInfo.environment
        )
        let children = output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        result.append(contentsOf: children)
        frontier.append(contentsOf: children)
    }
    return result
}
