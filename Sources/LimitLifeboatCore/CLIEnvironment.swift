import Foundation

struct CLIProcessInspector {
    func hasActiveProcesses(provider: Provider) -> Bool {
        switch provider {
        case .codex:
            return runPgrep(arguments: ["-x", "codex"])
        case .claude:
            return runPgrep(arguments: ["-f", "(^|/)claude( |$)|Claude Code"])
        }
    }

    private func runPgrep(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

struct CLIExecutableResolver {
    let homeDirectory: URL
    let fileManager: FileManager

    func resolve(command: String) -> String? {
        if let fromShell = loginShellResolvedPath(command: command) {
            return fromShell
        }
        let candidates = [
            homeDirectory.appendingPathComponent(".npm-global/bin/\(command)").path,
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)"
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func loginShellResolvedPath(command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v \(command)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
        } catch {
            return nil
        }
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }
}
