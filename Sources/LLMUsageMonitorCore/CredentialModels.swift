import Foundation

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

    public init(relativePath: String, kind: Kind, contents: Data, posixPermissions: Int?) {
        self.relativePath = relativePath
        self.kind = kind
        self.contents = contents
        self.posixPermissions = posixPermissions
    }
}

public struct RestoreResult: Equatable, Sendable {
    public var touchedPaths: [URL]
    public var backupURLs: [URL]

    public init(touchedPaths: [URL], backupURLs: [URL]) {
        self.touchedPaths = touchedPaths
        self.backupURLs = backupURLs
    }
}
