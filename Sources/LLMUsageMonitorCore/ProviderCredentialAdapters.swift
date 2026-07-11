import Foundation

protocol ProviderCredentialAdapter {
    var provider: Provider { get }
    func captureSnapshot() throws -> CredentialSnapshot
    func currentIdentity() -> AccountIdentity?
    func validateActiveLogin() -> Bool
}

struct CodexCredentialAdapter: ProviderCredentialAdapter {
    let provider = Provider.codex
    let homeDirectory: URL
    let fileManager: FileManager

    func captureSnapshot() throws -> CredentialSnapshot {
        let relativePath = ".codex/auth.json"
        let authURL = resolve(relativePath)
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CLISwitcherError.missingCredentials(authURL.path)
        }
        let data = try Data(contentsOf: authURL)
        guard !data.isEmpty else {
            throw CLISwitcherError.missingCredentials(authURL.path)
        }
        return CredentialSnapshot(
            provider: provider,
            items: [
                CredentialSnapshotItem(
                    relativePath: relativePath,
                    kind: .fullFile,
                    contents: data,
                    posixPermissions: filePermissions(authURL)
                )
            ]
        )
    }

    func currentIdentity() -> AccountIdentity? {
        CodexIdentityReader(homeDirectory: homeDirectory, fileManager: fileManager).readIdentity()
    }

    func validateActiveLogin() -> Bool {
        let authURL = resolve(".codex/auth.json")
        return fileManager.fileExists(atPath: authURL.path)
            && ((try? Data(contentsOf: authURL).isEmpty) == false)
    }

    private func resolve(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(homeDirectory) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func filePermissions(_ url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }
}

struct ClaudeCredentialAdapter: ProviderCredentialAdapter {
    let provider = Provider.claude
    let homeDirectory: URL
    let fileManager: FileManager
    let credentialSource: ClaudeCLICredentialSource

    func captureSnapshot() throws -> CredentialSnapshot {
        var items: [CredentialSnapshotItem] = []
        if let liveItem = try credentialSource.readLiveItemJSON(),
           let credentials = ClaudeOAuthCredentials.extract(fromKeychainItemJSON: liveItem) {
            items.append(
                CredentialSnapshotItem(
                    relativePath: CLISwitcher.claudeKeychainItemPath,
                    kind: .keychainJSONFields,
                    contents: credentials.rawClaudeAiOauth,
                    posixPermissions: nil
                )
            )
        }

        let configRelativePath = "Library/Application Support/Claude/config.json"
        let fields = try readConfigAuthFields()
        if !fields.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            let configURL = resolve(configRelativePath)
            items.append(
                CredentialSnapshotItem(
                    relativePath: configRelativePath,
                    kind: .jsonFields,
                    contents: data,
                    posixPermissions: filePermissions(configURL)
                )
            )
        }

        let claudeJSONRelativePath = ".claude.json"
        let claudeJSONURL = resolve(claudeJSONRelativePath)
        if containsAuthMaterial(in: claudeJSONURL) {
            items.append(
                CredentialSnapshotItem(
                    relativePath: claudeJSONRelativePath,
                    kind: .fullFile,
                    contents: try Data(contentsOf: claudeJSONURL),
                    posixPermissions: filePermissions(claudeJSONURL)
                )
            )
        }
        guard !items.isEmpty else {
            throw CLISwitcherError.missingCredentials("Claude OAuth token cache")
        }
        return CredentialSnapshot(provider: provider, items: items)
    }

    func currentIdentity() -> AccountIdentity? {
        ClaudeIdentityReader(homeDirectory: homeDirectory, fileManager: fileManager).readIdentity()
    }

    func validateActiveLogin() -> Bool {
        if let item = try? credentialSource.readLiveItemJSON(),
           ClaudeOAuthCredentials.extract(fromKeychainItemJSON: item) != nil {
            return true
        }
        if let fields = try? readConfigAuthFields(), !fields.isEmpty {
            return true
        }
        return containsAuthMaterial(in: resolve(".claude.json"))
    }

    private func readConfigAuthFields() throws -> [String: Any] {
        let configURL = resolve("Library/Application Support/Claude/config.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(configURL.path)
        }
        let knownAuthKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]
        return knownAuthKeys.reduce(into: [:]) { result, key in
            result[key] = object[key]
        }
    }

    private func containsAuthMaterial(in url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsAuthMaterial(in: json)
    }

    private func containsAuthMaterial(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, nested in
                let lower = key.lowercased()
                return lower.contains("oauth")
                    || lower == "access_token"
                    || lower == "refresh_token"
                    || lower == "id_token"
                    || lower == "session_token"
                    || containsAuthMaterial(in: nested)
            }
        }
        if let array = value as? [Any] {
            return array.contains(where: containsAuthMaterial(in:))
        }
        return false
    }

    private func resolve(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(homeDirectory) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func filePermissions(_ url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }
}
