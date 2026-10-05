import Foundation

/// Approves Limit Lifeboat's own Codex hook the way Codex's `/hooks` screen
/// does, through the public app-server API: `hooks/list` reports each hook's
/// key and the hash Codex computed for it, and `config/batchWrite` records
/// that hash under `hooks.state`. Codex does the hashing and the config.toml
/// write; only the hook whose command runs our script is ever touched.
///
/// Runs against the user's real CODEX_HOME with an ephemeral credential store,
/// so the session never reads or refreshes the Codex login.
public enum CodexHookTrust {
    public enum Status: Equatable, Sendable {
        case trusted
        case needsApproval
        /// The user turned the hook off in Codex; respected, never re-enabled.
        case disabledInCodex
        case notFound
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case codexNotFound
        case appServerUnavailable
        case rejected(String)

        public var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return "Codex wasn't found, so the hook couldn't be approved for you; Codex will ask about it when it next starts."
            case .appServerUnavailable:
                return "Codex didn't answer, so the hook couldn't be approved for you; Codex will ask about it when it next starts."
            case .rejected(let message):
                return "Codex refused to approve the hook (\(message)); approve it in Codex with /hooks."
            }
        }
    }

    struct Hook: Equatable {
        var key: String
        var currentHash: String
        var trustStatus: String
        var enabled: Bool
    }

    public static func resolveCodexExecutable(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        CLIExecutableResolver(homeDirectory: homeDirectory, fileManager: .default)
            .resolve(command: "codex")
            .map(URL.init(fileURLWithPath:))
    }

    public static func status(
        scriptFileName: String,
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval = 20
    ) throws -> Status {
        guard let hook = try ourHook(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout) else {
            return .notFound
        }
        if !hook.enabled { return .disabledInCodex }
        return hook.trustStatus == "trusted" || hook.trustStatus == "managed" ? .trusted : .needsApproval
    }

    /// Approves our hook if Codex lists it as untrusted or modified. Returns
    /// the resulting status; never touches any other hook.
    @discardableResult
    public static func approve(
        scriptFileName: String,
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval = 20
    ) throws -> Status {
        guard let hook = try ourHook(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout) else {
            return .notFound
        }
        guard hook.enabled else { return .disabledInCodex }
        guard hook.trustStatus == "untrusted" || hook.trustStatus == "modified" else { return .trusted }

        let request: [String: Any] = [
            "method": "config/batchWrite",
            "id": 3,
            "params": [
                "edits": [[
                    "keyPath": "hooks.state",
                    "value": [hook.key: ["trusted_hash": hook.currentHash]],
                    "mergeStrategy": "upsert"
                ]],
                "reloadUserConfig": true
            ]
        ]
        let response = try exchange(request: request, id: 3, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            throw Failure.rejected(error["message"] as? String ?? "unknown error")
        }
        return try status(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
    }

    private static func ourHook(
        scriptFileName: String,
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) throws -> Hook? {
        let request: [String: Any] = [
            "method": "hooks/list",
            "id": 2,
            "params": ["cwds": [FileManager.default.homeDirectoryForCurrentUser.path]]
        ]
        let response = try exchange(request: request, id: 2, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            throw Failure.rejected(error["message"] as? String ?? "unknown error")
        }
        return hook(in: response, scriptFileName: scriptFileName)
    }

    /// Picks our UserPromptSubmit command hook out of a `hooks/list` response.
    static func hook(in response: [String: Any], scriptFileName: String) -> Hook? {
        let entries = (response["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        for entry in entries {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                guard (hook["eventName"] as? String)?.lowercased() == "userpromptsubmit",
                      (hook["handlerType"] as? String) == "command",
                      let command = hook["command"] as? String, command.contains(scriptFileName),
                      let key = hook["key"] as? String,
                      let hash = hook["currentHash"] as? String,
                      let trust = hook["trustStatus"] as? String else { continue }
                return Hook(key: key, currentHash: hash, trustStatus: trust, enabled: hook["enabled"] as? Bool ?? true)
            }
        }
        return nil
    }

    private static func exchange(
        request: [String: Any],
        id: Int,
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let lock = NSLock()
        var buffer = Data()
        var answer: [String: Any]?
        let outcome = CodexAppServerSession.run(
            executableURL: executableURL,
            codexHome: codexHome,
            timeout: timeout,
            credentialStore: "ephemeral",
            requests: [request]
        ) { chunk in
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   (object["id"] as? Int) == id {
                    answer = object
                    return true
                }
            }
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        if let answer { return answer }
        throw outcome == .launchFailed ? Failure.codexNotFound : Failure.appServerUnavailable
    }
}
