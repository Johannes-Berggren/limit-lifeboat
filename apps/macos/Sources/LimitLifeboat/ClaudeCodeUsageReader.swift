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
            return "Claude Code /usage timed out. If macOS showed a keychain dialog for claude, run scripts/fix-keychain-prompts.sh (see Troubleshooting in the README)."
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

    func readUsage(oauthToken: String? = nil) async throws -> ClaudeCodeUsageReport {
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

    private func runUsageProbe(oauthToken: String?) async throws -> String {
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

private func runExpectProbe(
    homeDirectory: URL,
    fileManager: FileManager,
    timeoutSeconds: TimeInterval,
    oauthToken: String?
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
    let environment = environment(homeDirectory: homeDirectory, oauthToken: oauthToken)
    process.environment = environment
    let claudeCommand = try resolveClaudeCommand(
        homeDirectory: homeDirectory,
        fileManager: fileManager,
        environment: environment
    )
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
        throw ClaudeCodeUsageReaderError.launchFailed(
            errorOutput.isEmpty ? "exit \(process.terminationStatus)" : errorOutput
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
    let candidates = [
        homeDirectory.appendingPathComponent(".local/bin/claude"),
        URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        URL(fileURLWithPath: "/usr/local/bin/claude")
    ]

    for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
        let help = commandOutput(executableURL: candidate, arguments: ["--help"], environment: environment)
        return ClaudeCommand(
            executableURL: candidate,
            arguments: supportedArguments(fromHelp: help)
        )
    }

    // None of the well-known install locations hit; fall back to PATH lookup
    // (the environment already carries the fallback directories). A missing
    // executable must fail here as `.cliNotFound` — launching a bare `env
    // claude` would only surface as an unrecognized-output error later.
    let resolved = commandOutput(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["which", "claude"],
        environment: environment
    )
    guard let path = resolved.split(whereSeparator: \.isNewline).first.map(String.init),
          fileManager.isExecutableFile(atPath: path) else {
        throw ClaudeCodeUsageReaderError.cliNotFound
    }
    let executableURL = URL(fileURLWithPath: path)
    let help = commandOutput(executableURL: executableURL, arguments: ["--help"], environment: environment)
    return ClaudeCommand(
        executableURL: executableURL,
        arguments: supportedArguments(fromHelp: help)
    )
}

private func supportedArguments(fromHelp help: String) -> [String] {
    var arguments: [String] = []
    if help.contains("--safe-mode") {
        arguments.append("--safe-mode")
    }
    if help.contains("--ax-screen-reader") {
        arguments.append("--ax-screen-reader")
    }
    if help.contains("--no-chrome") {
        arguments.append("--no-chrome")
    }
    if help.contains("--permission-mode") {
        arguments.append(contentsOf: ["--permission-mode", "default"])
    }
    return arguments
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
catch {exec kill -KILL $child}
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

private func environment(homeDirectory: URL, oauthToken: String?) -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    let fallbackPath = "\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existingPath = values["PATH"], !existingPath.isEmpty {
        values["PATH"] = "\(fallbackPath):\(existingPath)"
    } else {
        values["PATH"] = fallbackPath
    }
    values["NO_COLOR"] = "1"
    values["TERM"] = "xterm-256color"
    if let oauthToken {
        // Lets the spawned CLI authenticate without reading its own keychain
        // item, which pops a SecurityAgent dialog on systems where claude's
        // code signature is not durably authorized for it (see
        // scripts/fix-keychain-prompts.sh).
        values["CLAUDE_CODE_OAUTH_TOKEN"] = oauthToken
    }
    return values
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
