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
        /// A managed policy (requirements.toml / MDM) pins the credential
        /// store, so a session here could load and refresh the real login, or
        /// it allows managed hooks only. Nothing is written; the user or their
        /// admin approves it in Codex.
        case blockedByPolicy
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

    /// What the app last approved: Codex's positional key and the hash it
    /// computed. The hash covers the hook's config, not its position.
    public struct Approval: Codable, Equatable, Sendable {
        public var key: String
        public var hash: String

        public init(key: String, hash: String) {
            self.key = key
            self.hash = hash
        }
    }

    /// Launch-time check. Re-approves only when our hook is unchanged (same
    /// hash) but has moved to a new position — another tool rewrote
    /// hooks.json, which resets trust by key. A hook at the same position
    /// that is untrusted means the user's call in Codex, and is left alone.
    public static func refresh(
        scriptFileName: String,
        executableURL: URL,
        codexHome: URL,
        lastApproved: Approval?,
        timeout: TimeInterval = 20
    ) throws -> (status: Status, approval: Approval?) {
        let (hook, policyBlocks) = try ourHook(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        guard let hook else { return (.notFound, nil) }
        let current = Approval(key: hook.key, hash: hook.currentHash)
        if !hook.enabled { return (.disabledInCodex, nil) }
        if hook.trustStatus == "trusted" || hook.trustStatus == "managed" { return (.trusted, current) }
        if policyBlocks { return (.blockedByPolicy, nil) }
        guard shouldReapprove(current: current, lastApproved: lastApproved), let lastApproved else { return (.needsApproval, nil) }
        // The old position must still hold our approval and must not have been
        // turned off: a user who switched the hook off in /hooks before the
        // shift said no, and the move must not undo that.
        let config = try exchange(
            requests: [["method": "config/read", "id": 5, "params": [:] as [String: Any]]],
            executableURL: executableURL,
            codexHome: codexHome,
            timeout: timeout
        )[5]
        guard priorStateConfirms(lastApproved, in: config) else { return (.needsApproval, nil) }
        try record(current, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        let after = try status(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        return (after, after == .trusted ? current : nil)
    }

    /// `hooks.state[<old key>]` from `config/read` still carries our hash
    /// and no `enabled = false`.
    static func priorStateConfirms(_ approval: Approval, in configResponse: [String: Any]?) -> Bool {
        let config = (configResponse?["result"] as? [String: Any])?["config"] as? [String: Any]
        let state = ((config?["hooks"] as? [String: Any])?["state"] as? [String: Any])?[approval.key] as? [String: Any]
        guard let state, state["trusted_hash"] as? String == approval.hash else { return false }
        return state["enabled"] as? Bool != false
    }

    static func shouldReapprove(current: Approval, lastApproved: Approval?) -> Bool {
        guard let lastApproved else { return false }
        return lastApproved.hash == current.hash && lastApproved.key != current.key
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
        let (hook, policyBlocks) = try ourHook(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        guard let hook else { return .notFound }
        if !hook.enabled { return .disabledInCodex }
        if hook.trustStatus == "trusted" || hook.trustStatus == "managed" { return .trusted }
        return policyBlocks ? .blockedByPolicy : .needsApproval
    }

    /// Approves our hook if Codex lists it as untrusted or modified. Returns
    /// the resulting status; never touches any other hook.
    @discardableResult
    public static func approve(
        scriptFileName: String,
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval = 20
    ) throws -> (status: Status, approval: Approval?) {
        let (hook, policyBlocks) = try ourHook(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        guard let hook else { return (.notFound, nil) }
        let current = Approval(key: hook.key, hash: hook.currentHash)
        guard hook.enabled else { return (.disabledInCodex, nil) }
        guard hook.trustStatus == "untrusted" || hook.trustStatus == "modified" else { return (.trusted, current) }
        guard !policyBlocks else { return (.blockedByPolicy, nil) }

        try record(current, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        let after = try status(scriptFileName: scriptFileName, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        return (after, after == .trusted ? current : nil)
    }

    /// Upserts `hooks.state.<key>.trusted_hash`, exactly as Codex's /hooks does.
    private static func record(_ approval: Approval, executableURL: URL, codexHome: URL, timeout: TimeInterval) throws {
        let request: [String: Any] = [
            "method": "config/batchWrite",
            "id": 3,
            "params": [
                "edits": [[
                    "keyPath": "hooks.state",
                    "value": [approval.key: ["trusted_hash": approval.hash]],
                    "mergeStrategy": "upsert"
                ]],
                "reloadUserConfig": true
            ]
        ]
        let response = try exchange(requests: [request], executableURL: executableURL, codexHome: codexHome, timeout: timeout)[3] ?? [:]
        if let error = response["error"] as? [String: Any] {
            throw Failure.rejected(error["message"] as? String ?? "unknown error")
        }
    }

    private static func ourHook(
        scriptFileName: String,
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) throws -> (hook: Hook?, policyBlocks: Bool) {
        let requests: [[String: Any]] = [
            ["method": "configRequirements/read", "id": 4],
            [
                "method": "hooks/list",
                "id": 2,
                "params": ["cwds": [FileManager.default.homeDirectoryForCurrentUser.path]]
            ]
        ]
        let responses = try exchange(requests: requests, executableURL: executableURL, codexHome: codexHome, timeout: timeout)
        let list = responses[2] ?? [:]
        if let error = list["error"] as? [String: Any] {
            throw Failure.rejected(error["message"] as? String ?? "unknown error")
        }
        return (hook(in: list, scriptFileName: scriptFileName), policyBlocks(responses[4]))
    }

    /// True when managed requirements pin the credential store (the `-c`
    /// ephemeral override would lose to them) or allow managed hooks only.
    static func policyBlocks(_ response: [String: Any]?) -> Bool {
        guard let requirements = (response?["result"] as? [String: Any])?["requirements"] as? [String: Any] else {
            return false
        }
        if let store = requirements["cliAuthCredentialsStore"] as? String, store.lowercased() != "ephemeral" {
            return true
        }
        return requirements["allowManagedHooksOnly"] as? Bool == true
    }

    /// Picks our UserPromptSubmit command hook out of a `hooks/list` response.
    static func hook(in response: [String: Any], scriptFileName: String) -> Hook? {
        let entries = (response["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        for entry in entries {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                // Only the user-level hooks.json we installed into, never a
                // project-level copy of the same command.
                guard (hook["eventName"] as? String)?.lowercased() == "userpromptsubmit",
                      (hook["source"] as? String ?? "user") == "user",
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
        requests: [[String: Any]],
        executableURL: URL,
        codexHome: URL,
        timeout: TimeInterval
    ) throws -> [Int: [String: Any]] {
        let ids = Set(requests.compactMap { $0["id"] as? Int })
        let lock = NSLock()
        var buffer = Data()
        var answers: [Int: [String: Any]] = [:]
        let outcome = CodexAppServerSession.run(
            executableURL: executableURL,
            codexHome: codexHome,
            timeout: timeout,
            credentialStore: "ephemeral",
            requests: requests
        ) { chunk in
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   let id = object["id"] as? Int, ids.contains(id) {
                    answers[id] = object
                    if answers.count == ids.count { return true }
                }
            }
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        if answers.count == ids.count { return answers }
        throw outcome == .launchFailed ? Failure.codexNotFound : Failure.appServerUnavailable
    }
}
