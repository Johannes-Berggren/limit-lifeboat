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
    process.currentDirectoryURL = homeDirectory
    process.environment = environment()
    process.arguments = ["-c", expectScript]

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

private let expectScript = #"""
set timeout 6
log_user 1
spawn -noecho /usr/bin/env claude --safe-mode --ax-screen-reader --no-chrome --permission-mode default
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

private func environment() -> [String: String] {
    var values = ProcessInfo.processInfo.environment
    let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
        "claude --safe-mode --ax-screen-reader --no-chrome --permission-mode default"
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
}
