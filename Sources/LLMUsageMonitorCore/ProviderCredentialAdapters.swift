import Foundation

protocol ProviderCredentialAdapter {
    var provider: Provider { get }
    func observe() throws -> LiveCredentialObservation
    func captureSnapshot() throws -> CredentialSnapshot
    func currentIdentity() -> AccountIdentity?
    func validateActiveLogin() -> Bool
}

struct CodexCredentialAdapter: ProviderCredentialAdapter {
    static let ownedKeys = ["auth_mode", "tokens", "OPENAI_API_KEY", "last_refresh"]
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
        return try snapshot(from: data, at: authURL)
    }

    private func snapshot(from data: Data, at authURL: URL) throws -> CredentialSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(authURL.path)
        }
        let fields = Self.ownedKeys.reduce(into: [String: Any]()) { result, key in
            result[key] = object[key]
        }
        let ownedData = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return CredentialSnapshot(
            provider: provider,
            items: [
                CredentialSnapshotItem(
                    relativePath: ".codex/auth.json",
                    kind: .jsonFields,
                    contents: ownedData,
                    posixPermissions: filePermissions(authURL),
                    ownedJSONKeys: Self.ownedKeys
                )
            ]
        )
    }

    func observe() throws -> LiveCredentialObservation {
        let authURL = resolve(".codex/auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            return LiveCredentialObservation(provider: provider, isLoggedIn: false, identity: nil, credentialFingerprint: nil, snapshot: nil)
        }
        let raw = try Data(contentsOf: authURL)
        let snapshot = try snapshot(from: raw, at: authURL)
        let info = CodexIdentityReader.accountInfo(fromAuthJSON: raw)
        let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        let isSubscriptionLogin = object?["tokens"] as? [String: Any] != nil
        return LiveCredentialObservation(
            provider: provider,
            isLoggedIn: isSubscriptionLogin,
            identity: info?.identity,
            credentialFingerprint: isSubscriptionLogin ? CredentialFingerprint.make(for: snapshot) : nil,
            snapshot: isSubscriptionLogin ? snapshot : nil
        )
    }

    func currentIdentity() -> AccountIdentity? {
        (try? observe())?.identity
    }

    func validateActiveLogin() -> Bool {
        (try? observe().isLoggedIn) == true
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
    static let configOwnedKeys = ["oauth:tokenCache", "oauth:tokenCacheV2"]
    static let accountOwnedKeys = ["oauthAccount"]
    let provider = Provider.claude
    let homeDirectory: URL
    let fileManager: FileManager
    let credentialSource: ClaudeCLICredentialSource

    func captureSnapshot() throws -> CredentialSnapshot {
        try makeSnapshot(liveItem: credentialSource.readLiveItemJSON())
    }

    private func makeSnapshot(liveItem: Data?) throws -> CredentialSnapshot {
        var items: [CredentialSnapshotItem] = []
        let credentials = liveItem.flatMap { ClaudeOAuthCredentials.extract(fromKeychainItemJSON: $0) }
        if let credentials {
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
        let configURL = resolve(configRelativePath)
        let claudeJSONRelativePath = ".claude.json"
        let claudeJSONURL = resolve(claudeJSONRelativePath)
        let accountFields = try readOwnedFields(at: claudeJSONURL, keys: Self.accountOwnedKeys) ?? [:]
        guard credentials != nil || !fields.isEmpty || !accountFields.isEmpty else {
            throw CLISwitcherError.missingCredentials("Claude OAuth token cache")
        }
        items.append(
            CredentialSnapshotItem(
                relativePath: configRelativePath,
                kind: .jsonFields,
                contents: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                posixPermissions: filePermissions(configURL),
                ownedJSONKeys: Self.configOwnedKeys,
                onlyIfDestinationExists: !fileManager.fileExists(atPath: configURL.path)
            )
        )
        items.append(
            CredentialSnapshotItem(
                relativePath: claudeJSONRelativePath,
                kind: .jsonFields,
                contents: try JSONSerialization.data(withJSONObject: accountFields, options: [.sortedKeys]),
                posixPermissions: filePermissions(claudeJSONURL),
                ownedJSONKeys: Self.accountOwnedKeys,
                onlyIfDestinationExists: !fileManager.fileExists(atPath: claudeJSONURL.path)
            )
        )
        return CredentialSnapshot(provider: provider, items: items)
    }

    func observe() throws -> LiveCredentialObservation {
        let live = try credentialSource.readLiveItemJSON()
        let snapshot: CredentialSnapshot
        do {
            snapshot = try makeSnapshot(liveItem: live)
        } catch CLISwitcherError.missingCredentials {
            return LiveCredentialObservation(provider: provider, isLoggedIn: false, identity: nil, credentialFingerprint: nil, snapshot: nil)
        }
        let hasOAuth = live.flatMap { ClaudeOAuthCredentials.extract(fromKeychainItemJSON: $0) } != nil
            || !((try? readConfigAuthFields()) ?? [:]).isEmpty
        let claudeJSONURL = resolve(".claude.json")
        let identity = (try? Data(contentsOf: claudeJSONURL)).flatMap {
            ClaudeIdentityReader.identity(fromClaudeJSON: $0)
        }
        return LiveCredentialObservation(
            provider: provider,
            isLoggedIn: hasOAuth,
            identity: identity,
            credentialFingerprint: hasOAuth ? CredentialFingerprint.make(for: snapshot) : nil,
            snapshot: hasOAuth ? snapshot : nil
        )
    }

    func currentIdentity() -> AccountIdentity? {
        (try? observe())?.identity
    }

    func validateActiveLogin() -> Bool {
        (try? observe().isLoggedIn) == true
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
        return Self.configOwnedKeys.reduce(into: [:]) { result, key in
            result[key] = object[key]
        }
    }

    private func readOwnedFields(at url: URL, keys: [String]) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLISwitcherError.invalidJSON(url.path)
        }
        return keys.reduce(into: [:]) { result, key in result[key] = object[key] }
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
