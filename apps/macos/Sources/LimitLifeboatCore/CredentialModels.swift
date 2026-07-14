import Foundation
import CryptoKit

public struct CredentialSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var capturedAt: Date
    public var items: [CredentialSnapshotItem]

    public init(provider: Provider, capturedAt: Date = Date(), items: [CredentialSnapshotItem]) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.items = items
    }
}

public struct CredentialSnapshotItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fullFile
        case jsonFields
        /// JSON fields merged into a login-keychain generic password instead
        /// of a file; `relativePath` carries a "keychain/<service>" marker.
        /// Older builds cannot decode this case — their `decodeFailed`
        /// recovery clears the snapshot and re-captures.
        case keychainJSONFields
    }

    public var relativePath: String
    public var kind: Kind
    public var contents: Data
    public var posixPermissions: Int?
    /// When present for a JSON item, these are the provider-owned top-level
    /// keys. Restore removes the whole owned set before inserting `contents`,
    /// which both logs an account out honestly and preserves unknown siblings.
    /// Optional for snapshots written by older builds.
    public var ownedJSONKeys: [String]?
    /// Empty removal patches should clean an existing live file without
    /// creating a brand-new `{}` file when the target account never had one.
    public var onlyIfDestinationExists: Bool?

    public init(
        relativePath: String,
        kind: Kind,
        contents: Data,
        posixPermissions: Int?,
        ownedJSONKeys: [String]? = nil,
        onlyIfDestinationExists: Bool = false
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.contents = contents
        self.posixPermissions = posixPermissions
        self.ownedJSONKeys = ownedJSONKeys
        self.onlyIfDestinationExists = onlyIfDestinationExists
    }
}

public struct RestoreResult: Equatable, Sendable {
    public var touchedPaths: [URL]
    /// The observation that was validated while rollback material was still
    /// available. Callers should use this instead of re-reading after commit,
    /// when another process may already have changed the live credentials.
    public var verifiedObservation: LiveCredentialObservation

    public init(touchedPaths: [URL], verifiedObservation: LiveCredentialObservation) {
        self.touchedPaths = touchedPaths
        self.verifiedObservation = verifiedObservation
    }
}

public enum AuthChangeOrigin: String, Equatable, Sendable {
    case launch
    case scheduledRefresh
    case popover
    case wake
    case fileEvent
    case polling
    case login
    case manualCapture
    case manualSwitch
    case automaticSwitch
}

/// One consistent read of a provider's live credential state. The fingerprint
/// is a SHA-256 digest of provider-owned fields only; secret bytes are never
/// logged or persisted outside the encrypted credential snapshot.
public struct LiveCredentialObservation: Equatable, Sendable {
    public var provider: Provider
    public var isLoggedIn: Bool
    public var identity: AccountIdentity?
    public var credentialFingerprint: String?
    public var snapshot: CredentialSnapshot?

    public init(
        provider: Provider,
        isLoggedIn: Bool,
        identity: AccountIdentity?,
        credentialFingerprint: String?,
        snapshot: CredentialSnapshot?
    ) {
        self.provider = provider
        self.isLoggedIn = isLoggedIn
        self.identity = identity
        self.credentialFingerprint = credentialFingerprint
        self.snapshot = snapshot
    }

    public var stabilityKey: String {
        [
            isLoggedIn ? "1" : "0",
            credentialFingerprint ?? "-",
            identity?.accountID ?? "-",
            identity?.organizationID ?? "-",
            identity?.email?.lowercased() ?? "-"
        ].joined(separator: "|")
    }
}

public enum CredentialFingerprint {
    public static func make(for snapshot: CredentialSnapshot) -> String {
        var bytes = Data()
        for item in semanticItems(snapshot).sorted(by: { $0.relativePath < $1.relativePath }) {
            bytes.append(Data(item.relativePath.utf8))
            bytes.append(0)
            bytes.append(Data(item.kind.rawValue.utf8))
            bytes.append(0)
            if let keys = item.ownedJSONKeys {
                bytes.append(Data(keys.sorted().joined(separator: "\u{1f}").utf8))
            }
            bytes.append(0)
            bytes.append(canonicalJSON(item.contents) ?? item.contents)
            bytes.append(0xff)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func semanticItems(_ snapshot: CredentialSnapshot) -> [CredentialSnapshotItem] {
        var items = snapshot.items.map { item -> CredentialSnapshotItem in
            let ownedKeys: [String]?
            switch (snapshot.provider, item.relativePath) {
            case (.codex, ".codex/auth.json"):
                ownedKeys = CodexCredentialAdapter.ownedKeys
            case (.claude, ".claude.json"):
                ownedKeys = ClaudeCredentialAdapter.accountOwnedKeys
            case (.claude, "Library/Application Support/Claude/config.json"):
                ownedKeys = ClaudeCredentialAdapter.configOwnedKeys
            default:
                ownedKeys = item.ownedJSONKeys
            }
            guard let ownedKeys,
                  let object = try? JSONSerialization.jsonObject(with: item.contents) as? [String: Any] else {
                return item
            }
            let fields = ownedKeys.reduce(into: [String: Any]()) { result, key in result[key] = object[key] }
            let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? item.contents
            return CredentialSnapshotItem(
                relativePath: item.relativePath,
                kind: .jsonFields,
                contents: data,
                posixPermissions: nil,
                ownedJSONKeys: ownedKeys
            )
        }
        if snapshot.provider == .claude {
            let required: [(String, [String])] = [
                ("Library/Application Support/Claude/config.json", ClaudeCredentialAdapter.configOwnedKeys),
                (".claude.json", ClaudeCredentialAdapter.accountOwnedKeys)
            ]
            for (path, keys) in required where !items.contains(where: { $0.relativePath == path }) {
                items.append(
                    CredentialSnapshotItem(
                        relativePath: path,
                        kind: .jsonFields,
                        contents: Data("{}".utf8),
                        posixPermissions: nil,
                        ownedJSONKeys: keys
                    )
                )
            }
        }
        return items
    }

    private static func canonicalJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
