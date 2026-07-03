import Darwin
import Foundation
import LLMUsageMonitorCore

enum ClaudeCodeUsageReaderError: Error, LocalizedError {
    case expectUnavailable
    case timedOut
    case launchFailed(String)
    case noUsageFound

    var errorDescription: String? {
        switch self {
        case .expectUnavailable:
            return "/usr/bin/expect is not available, so Claude Code /usage cannot be automated."
        case .timedOut:
            return "Claude Code /usage timed out."
        case .launchFailed(let details):
            return "Claude Code /usage failed: \(details)"
        case .noUsageFound:
            return "Claude Code opened, but /usage output was not recognized."
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

    func readUsage() async throws -> ClaudeCodeUsageReport {
        let output = try await runUsageProbe()
        guard let report = parser.parse(text: output) else {
            throw ClaudeCodeUsageReaderError.noUsageFound
        }
        return report
    }

    private func runUsageProbe() async throws -> String {
        try await Task.detached(priority: .utility) {
            try runExpectProbe(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                timeoutSeconds: timeoutSeconds
            )
        }.value
    }
}

private func runExpectProbe(
    homeDirectory: URL,
    fileManager: FileManager,
    timeoutSeconds: TimeInterval
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
    let environment = environment(homeDirectory: homeDirectory)
    process.environment = environment
    process.arguments = [
        "-c",
        try expectScript(
            command: resolveClaudeCommand(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                environment: environment
            )
        )
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

    return ClaudeCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["claude"]
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

private func environment(homeDirectory: URL) -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    let fallbackPath = "\(homeDirectory.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existingPath = values["PATH"], !existingPath.isEmpty {
        values["PATH"] = "\(fallbackPath):\(existingPath)"
    } else {
        values["PATH"] = fallbackPath
    }
    values["NO_COLOR"] = "1"
    values["TERM"] = "xterm-256color"
    return values
}

private func terminate(_ process: Process) {
    guard process.isRunning else {
        killHelperClaudeProcesses()
        return
    }

    process.terminate()
    usleep(300_000)
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    killHelperClaudeProcesses()
}

private func killHelperClaudeProcesses() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = [
        "-f",
        "claude .*--ax-screen-reader.*--no-chrome.*--permission-mode default"
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}
