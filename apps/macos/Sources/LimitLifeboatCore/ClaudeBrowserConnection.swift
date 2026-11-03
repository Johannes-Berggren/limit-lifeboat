import Foundation

/// Gives Claude Code's Chrome connection a login of its own. Claude Code finds
/// the Chrome extension through the account it is logged in as, and the
/// extension can only be signed in to one account, so switching the CLI
/// otherwise disconnects it. Opt-in: this adds one user-scope MCP server that
/// runs the connection under a separate config directory, and turns off the
/// built-in connection, which would keep following the CLI's account.
public struct ClaudeBrowserConnection {
    public static let serverName = "browser"
    public static let builtInServerName = "claude-in-chrome"
    /// An undocumented Claude Code flag. `checkConnection()` is what notices
    /// if a later release drops it.
    public static let serverFlag = "--claude-in-chrome-mcp"
    public static let configDirectoryName = ".claude-browser"
    public static let configDirectoryKey = "CLAUDE_CONFIG_DIR"
    /// Records that `install` added the rule turning off the built-in
    /// connection. Kept beside the login rather than in preferences, so any
    /// copy of the app can undo it.
    static let addedDenialMarkerName = ".limit-lifeboat-added-built-in-denial"
    /// A constant, as `TerminalCommandLauncher` requires. Never add `--chrome`
    /// to anything run under this directory: it would repoint Chrome's native
    /// host manifest at it.
    public static let loginCommand = "\(configDirectoryKey)=\"$HOME/\(configDirectoryName)\" claude auth login"

    public enum Status: Equatable {
        case notSet
        case installed
        /// Someone else's `browser` server; never replaced.
        case other(String)
    }

    public enum ConnectionError: LocalizedError, Equatable {
        case otherServer(String)
        case claudeNotFound
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .otherServer(let command):
                return "Claude Code already has an MCP server named \"\(ClaudeBrowserConnection.serverName)\" (\(command)), so it was left unchanged. Remove or rename it first."
            case .claudeNotFound:
                return "Claude Code could not be found, so nothing was changed."
            case .commandFailed(let detail):
                return "Claude Code could not change its MCP servers. \(detail)"
            }
        }
    }

    public enum Health: Equatable, Sendable {
        case connected(browsers: Int)
        case noBrowser
        /// The server did not answer, which may mean a Claude Code update
        /// removed `serverFlag`.
        case unavailable
    }

    public let homeDirectory: URL
    private let settingsFile: ClaudeSettingsFile
    private let processEnvironment: [String: String]
    private let fileManager: FileManager

    public var configDirectory: URL {
        homeDirectory.appendingPathComponent(Self.configDirectoryName)
    }

    private var addedDenialMarker: URL {
        configDirectory.appendingPathComponent(Self.addedDenialMarkerName)
    }

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.settingsFile = ClaudeSettingsFile(
            url: homeDirectory.appendingPathComponent(".claude/settings.json"),
            fileManager: fileManager
        )
        self.processEnvironment = processEnvironment
        self.fileManager = fileManager
    }

    /// Who the connection's own login belongs to. Read from its config file,
    /// so this never touches the Keychain.
    public func signedInIdentity() -> AccountIdentity? {
        ClaudeIdentityReader(homeDirectory: configDirectory, fileManager: fileManager).readIdentity()
    }

    public func status() -> Status {
        guard let data = try? Data(contentsOf: homeDirectory.appendingPathComponent(".claude.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any],
              let server = servers[Self.serverName] as? [String: Any] else {
            return .notSet
        }
        let args = server["args"] as? [String] ?? []
        let env = server["env"] as? [String: String] ?? [:]
        if args.contains(Self.serverFlag), env[Self.configDirectoryKey] == configDirectory.path {
            return .installed
        }
        return .other(server["command"] as? String ?? server["url"] as? String ?? "unknown")
    }

    /// Goes through `claude mcp`, not a direct write: running sessions rewrite
    /// `~/.claude.json` all the time and Claude Code owns its locking.
    public func install() throws {
        var settings = try settingsFile.read()
        switch status() {
        case .other(let command):
            throw ConnectionError.otherServer(command)
        case .installed:
            break
        case .notSet:
            let claude = try claudeExecutable()
            let server: [String: Any] = [
                "type": "stdio",
                "command": claude.path,
                "args": [Self.serverFlag],
                "env": [Self.configDirectoryKey: configDirectory.path]
            ]
            let json = try JSONSerialization.data(withJSONObject: server, options: [.sortedKeys, .withoutEscapingSlashes])
            try runClaude(claude, ["mcp", "add-json", Self.serverName, String(decoding: json, as: UTF8.self), "--scope", "user"])
        }

        var denied = settings["deniedMcpServers"] as? [[String: Any]] ?? []
        // A rule the user set themselves gets no marker, so `uninstall` keeps it.
        guard !denied.contains(where: Self.isBuiltInDenial) else { return }
        denied.append(["serverName": Self.builtInServerName])
        settings["deniedMcpServers"] = denied
        do {
            try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try Data().write(to: addedDenialMarker)
            try settingsFile.write(settings)
        } catch {
            // Half installed would leave two Chrome connections in every session.
            try? fileManager.removeItem(at: addedDenialMarker)
            try? runClaude(claudeExecutable(), ["mcp", "remove", Self.serverName, "--scope", "user"])
            throw error
        }
    }

    /// Removes only what `install` added. The login itself stays, so turning
    /// this back on doesn't need another sign-in.
    public func uninstall() throws {
        var settings = try settingsFile.read()
        if status() == .installed {
            try runClaude(claudeExecutable(), ["mcp", "remove", Self.serverName, "--scope", "user"])
        }
        guard fileManager.fileExists(atPath: addedDenialMarker.path) else { return }
        if var denied = settings["deniedMcpServers"] as? [[String: Any]],
           denied.contains(where: Self.isBuiltInDenial) {
            denied.removeAll(where: Self.isBuiltInDenial)
            settings["deniedMcpServers"] = denied.isEmpty ? nil : denied
            try settingsFile.write(settings)
        }
        try? fileManager.removeItem(at: addedDenialMarker)
    }

    /// Starts the server the way a session would and asks it for its browsers.
    /// Blocking, and only ever on request: it contacts Anthropic's relay.
    public func checkConnection(timeout: TimeInterval = 45) -> Health {
        guard let claude = try? claudeExecutable() else { return .unavailable }
        var environment = commandEnvironment()
        environment[Self.configDirectoryKey] = configDirectory.path

        let process = Process()
        process.executableURL = claude
        process.arguments = [Self.serverFlag]
        process.environment = environment
        process.currentDirectoryURL = homeDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // The server may exit before reading; that must not kill the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let responses = JSONRPCResponses()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                responses.close()
            } else {
                responses.append(data)
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        do {
            try process.run()
        } catch {
            return .unavailable
        }

        let deadline = Date().addingTimeInterval(timeout)
        func send(_ line: String) {
            try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"limit-lifeboat","version":"1"}}}"#)
        guard responses.wait(forID: 1, until: deadline)?["result"] != nil else { return .unavailable }
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_connected_browsers","arguments":{}}}"#)
        guard let response = responses.wait(forID: 2, until: deadline),
              let result = response["result"] as? [String: Any] else { return .unavailable }
        return Self.health(fromToolResult: result)
    }

    /// The tool answers with a JSON array of browsers; anything else is the
    /// extension-not-connected explanation.
    static func health(fromToolResult result: [String: Any]) -> Health {
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let browsers = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              !browsers.isEmpty else {
            return .noBrowser
        }
        return .connected(browsers: browsers.count)
    }

    private static func isBuiltInDenial(_ entry: [String: Any]) -> Bool {
        entry.count == 1 && entry["serverName"] as? String == builtInServerName
    }

    private func commandEnvironment() -> [String: String] {
        var environment = ClaudeCodeProcessLaunchPolicy.discoveryEnvironment(
            homeDirectory: homeDirectory,
            processEnvironment: processEnvironment
        )
        environment.removeValue(forKey: Self.configDirectoryKey)
        return environment
    }

    private func claudeExecutable() throws -> URL {
        let candidates = ClaudeCodeProcessLaunchPolicy.executableCandidates(
            homeDirectory: homeDirectory,
            environment: commandEnvironment()
        )
        guard let claude = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            throw ConnectionError.claudeNotFound
        }
        return claude
    }

    private func runClaude(_ claude: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        process.environment = commandEnvironment()
        process.currentDirectoryURL = homeDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw ConnectionError.commandFailed(error.localizedDescription)
        }
        let timeout = DispatchWorkItem { [process] in process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else {
            throw ConnectionError.commandFailed(
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

/// Collects a stdio MCP server's newline-delimited responses by request id.
private final class JSONRPCResponses: @unchecked Sendable {
    private let condition = NSCondition()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var closed = false

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let id = object["id"] as? Int {
                responses[id] = object
            }
        }
        condition.broadcast()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(forID id: Int, until deadline: Date) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, !closed {
            guard condition.wait(until: deadline) else { break }
        }
        return responses[id]
    }
}
