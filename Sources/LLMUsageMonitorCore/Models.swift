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
        dashboardURLs[0]
    }

    public var dashboardURLs: [URL] {
        switch self {
        case .claude:
            return [
                URL(string: "https://claude.ai/settings/usage")!
            ]
        case .codex:
            return [
                URL(string: "https://chatgpt.com/codex/settings/usage")!,
                URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
            ]
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

/// The single home for the "how close to the limit is worrying" and "how old
/// is too old" numbers, so every reader and view agrees.
public struct UsageThresholds: Equatable, Sendable {
    public var warningUsedFraction: Double
    public var staleAfter: TimeInterval

    public static let standard = UsageThresholds()

    public init(warningUsedFraction: Double = 0.8, staleAfter: TimeInterval = 30 * 60) {
        self.warningUsedFraction = warningUsedFraction
        self.staleAfter = staleAfter
    }

    public func riskLevel(usedFraction: Double) -> RiskLevel {
        if usedFraction >= 1 {
            return .depleted
        }
        if usedFraction >= warningUsedFraction {
            return .warning
        }
        return .healthy
    }

    public func riskLevel(usedPercent: Double) -> RiskLevel {
        riskLevel(usedFraction: usedPercent / 100)
    }
}

public enum BillingUsageMode: String, Sendable {
    case includedSubscription
    case includedSubscriptionNearLimit
    case overLimitPayAsYouGo
    case payAsYouGoVisible
    case needsLogin
    case unknown
}

public enum WebDataStoreKind: String, Codable, Sendable {
    case appDefault
    case isolated
}

public enum AccountIdentitySource: String, Codable, Sendable {
    case dashboard
    case codexIDToken
    case claudeCodeUsage
    case manual
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public var email: String?
    public var displayName: String?
    public var organization: String?
    public var accountID: String?
    public var source: AccountIdentitySource
    public var updatedAt: Date

    public init(
        email: String? = nil,
        displayName: String? = nil,
        organization: String? = nil,
        accountID: String? = nil,
        source: AccountIdentitySource,
        updatedAt: Date = Date()
    ) {
        self.email = email
        self.displayName = displayName
        self.organization = organization
        self.accountID = accountID
        self.source = source
        self.updatedAt = updatedAt
    }

    public var primaryLabel: String? {
        email ?? displayName ?? accountID
    }

    /// Two identities refer to the same account when their stable identifiers
    /// agree. Organization names are deliberately not compared: two different
    /// accounts can share an organization.
    public func matches(_ other: AccountIdentity) -> Bool {
        if let leftAccountID = accountID,
           let rightAccountID = other.accountID,
           leftAccountID == rightAccountID {
            return true
        }

        if let leftEmail = email?.lowercased(),
           let rightEmail = other.email?.lowercased(),
           leftEmail == rightEmail {
            return true
        }

        return false
    }

    public var isLikelyValid: Bool {
        if email != nil || displayName != nil || accountID != nil {
            return true
        }

        guard let organization else {
            return false
        }

        let lower = organization.lowercased()
        let invalidFragments = [
            "try claude",
            "individual team",
            "team and enterprise",
            "free ",
            "pricing",
            "log in",
            "sign up"
        ]
        return organization.count <= 50 && !invalidFragments.contains(where: lower.contains)
    }
}

public struct AccountProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var planLabel: String
    public var webDataStoreKind: WebDataStoreKind
    public var webDataStoreID: UUID
    public var identity: AccountIdentity?
    public var isActiveCLI: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        label: String,
        planLabel: String = "",
        webDataStoreKind: WebDataStoreKind = .isolated,
        webDataStoreID: UUID = UUID(),
        identity: AccountIdentity? = nil,
        isActiveCLI: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.planLabel = planLabel
        self.webDataStoreKind = webDataStoreKind
        self.webDataStoreID = webDataStoreID
        self.identity = identity
        self.isActiveCLI = isActiveCLI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case planLabel
        case webDataStoreKind
        case webDataStoreID
        case identity
        case isActiveCLI
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.label = try container.decode(String.self, forKey: .label)
        self.planLabel = try container.decode(String.self, forKey: .planLabel)
        self.webDataStoreKind = try container.decodeIfPresent(WebDataStoreKind.self, forKey: .webDataStoreKind) ?? .isolated
        self.webDataStoreID = try container.decode(UUID.self, forKey: .webDataStoreID)
        self.identity = try container.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        self.isActiveCLI = try container.decode(Bool.self, forKey: .isActiveCLI)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encode(planLabel, forKey: .planLabel)
        try container.encode(webDataStoreKind, forKey: .webDataStoreKind)
        try container.encode(webDataStoreID, forKey: .webDataStoreID)
        try container.encodeIfPresent(identity, forKey: .identity)
        try container.encode(isActiveCLI, forKey: .isActiveCLI)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
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

    public var usedFraction: Double? {
        guard let remainingFraction else {
            return nil
        }
        return max(0, min(1, 1 - remainingFraction))
    }

    public func isStale(asOf now: Date = Date(), maxAge: TimeInterval = UsageThresholds.standard.staleAfter) -> Bool {
        now.timeIntervalSince(lastRefreshed) > maxAge
    }

    /// True when the provider's limit window has rolled over since this
    /// snapshot was taken, meaning the account likely has its full quota back.
    public func resetHasElapsed(asOf now: Date = Date()) -> Bool {
        guard let resetDate else {
            return false
        }
        return resetDate < now
    }

    public var billingUsageMode: BillingUsageMode {
        if riskLevel == .stale {
            return .needsLogin
        }

        if payAsYouGoLooksActive {
            return .overLimitPayAsYouGo
        }

        if let usedFraction {
            if usedFraction >= UsageThresholds.standard.warningUsedFraction {
                return .includedSubscriptionNearLimit
            }
            return .includedSubscription
        }

        if hasPayAsYouGoSignal {
            return .payAsYouGoVisible
        }

        return .unknown
    }

    public var hasPayAsYouGoSignal: Bool {
        let text = "\(creditStatus ?? "") \(message)".lowercased()
        return text.contains("pay-as-you-go")
            || text.contains("pay as you go")
            || text.contains("usage credit")
            || text.contains("credits")
            || text.contains("auto top-up")
            || text.contains("auto-reload")
            || text.contains("auto reload")
    }

    public var payAsYouGoLooksActive: Bool {
        guard hasPayAsYouGoSignal else {
            return false
        }

        if riskLevel == .depleted {
            return true
        }

        if let includedRemaining, includedRemaining <= 0 {
            return true
        }

        let text = "\(creditStatus ?? "") \(message)".lowercased()
        return text.contains("rate limit reached")
            || text.contains("included usage appears depleted")
            || text.contains("included usage exhausted")
            || text.contains("limit reached")
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
