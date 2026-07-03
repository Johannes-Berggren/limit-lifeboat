import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "ChatGPT/Codex"
        }
    }

    public var commandName: String {
        switch self {
        case .claude:
            return "claude"
        case .codex:
            return "codex"
        }
    }

    public var dashboardURL: URL {
        switch self {
        case .claude:
            return URL(string: "https://claude.ai/settings/usage")!
        case .codex:
            return URL(string: "https://chatgpt.com/codex/settings/usage")!
        }
    }

    public var loginCommand: String {
        "\(commandName) login"
    }
}

public enum RiskLevel: String, Codable, Comparable, Sendable {
    case depleted
    case warning
    case healthy
    case stale
    case unknown

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ level: RiskLevel) -> Int {
        switch level {
        case .depleted:
            return 0
        case .warning:
            return 1
        case .healthy:
            return 2
        case .stale:
            return 3
        case .unknown:
            return 4
        }
    }
}

public enum ParseConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
    case none
}

public struct AccountProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var planLabel: String
    public var webDataStoreID: UUID
    public var isActiveCLI: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        label: String,
        planLabel: String = "",
        webDataStoreID: UUID = UUID(),
        isActiveCLI: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.planLabel = planLabel
        self.webDataStoreID = webDataStoreID
        self.isActiveCLI = isActiveCLI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public extension AccountProfile {
    static func defaultProfiles(now: Date = Date()) -> [AccountProfile] {
        [
            AccountProfile(provider: .claude, label: "Claude 1", createdAt: now, updatedAt: now),
            AccountProfile(provider: .claude, label: "Claude 2", createdAt: now, updatedAt: now),
            AccountProfile(provider: .codex, label: "ChatGPT/Codex 1", createdAt: now, updatedAt: now),
            AccountProfile(provider: .codex, label: "ChatGPT/Codex 2", createdAt: now, updatedAt: now)
        ]
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var provider: Provider
    public var includedRemaining: Double?
    public var includedLimit: Double?
    public var resetDate: Date?
    public var resetDescription: String?
    public var creditStatus: String?
    public var riskLevel: RiskLevel
    public var source: String
    public var lastRefreshed: Date
    public var parseConfidence: ParseConfidence
    public var message: String

    public init(
        accountID: UUID,
        provider: Provider,
        includedRemaining: Double? = nil,
        includedLimit: Double? = nil,
        resetDate: Date? = nil,
        resetDescription: String? = nil,
        creditStatus: String? = nil,
        riskLevel: RiskLevel = .unknown,
        source: String,
        lastRefreshed: Date = Date(),
        parseConfidence: ParseConfidence = .none,
        message: String = ""
    ) {
        self.accountID = accountID
        self.provider = provider
        self.includedRemaining = includedRemaining
        self.includedLimit = includedLimit
        self.resetDate = resetDate
        self.resetDescription = resetDescription
        self.creditStatus = creditStatus
        self.riskLevel = riskLevel
        self.source = source
        self.lastRefreshed = lastRefreshed
        self.parseConfidence = parseConfidence
        self.message = message
    }

    public var remainingFraction: Double? {
        guard let includedRemaining, let includedLimit, includedLimit > 0 else {
            return nil
        }
        return max(0, min(1, includedRemaining / includedLimit))
    }
}

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
