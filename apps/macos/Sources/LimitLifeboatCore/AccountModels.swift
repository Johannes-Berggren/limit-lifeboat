import Foundation

public enum AccountProfileOrdering {
    /// Keeps repository order stable within each group while lifting the
    /// active terminal account above inactive accounts.
    public static func activeFirst(_ profiles: [AccountProfile]) -> [AccountProfile] {
        profiles.filter(\.isActiveCLI) + profiles.filter { !$0.isActiveCLI }
    }

    /// Keeps the active CLI account at the top and, when one exists, places
    /// the advised handoff target directly after it. All other accounts retain
    /// repository order so routine refreshes never shuffle the list.
    public static func activeThenRecommended(
        _ profiles: [AccountProfile],
        recommendedID: UUID?
    ) -> [AccountProfile] {
        let active = profiles.filter(\.isActiveCLI)
        let inactive = profiles.filter { !$0.isActiveCLI }
        guard let recommendedID,
              let recommended = inactive.first(where: { $0.id == recommendedID }) else {
            return active + inactive
        }
        return active + [recommended] + inactive.filter { $0.id != recommendedID }
    }
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public var email: String?
    public var displayName: String?
    public var organization: String?
    public var organizationID: String?
    public var accountID: String?
    public var source: AccountIdentitySource
    public var updatedAt: Date

    public init(
        email: String? = nil,
        displayName: String? = nil,
        organization: String? = nil,
        organizationID: String? = nil,
        accountID: String? = nil,
        source: AccountIdentitySource,
        updatedAt: Date = Date()
    ) {
        self.email = email
        self.displayName = displayName
        self.organization = organization
        self.organizationID = organizationID
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
           let rightAccountID = other.accountID {
            guard leftAccountID == rightAccountID else {
                return false
            }
            if let leftOrganizationID = organizationID,
               let rightOrganizationID = other.organizationID {
                return leftOrganizationID == rightOrganizationID
            }
            if let leftOrganization = organization?.lowercased(),
               let rightOrganization = other.organization?.lowercased(),
               leftOrganization != rightOrganization {
                return false
            }
            return true
        }

        if let leftOrganizationID = organizationID,
           let rightOrganizationID = other.organizationID,
           leftOrganizationID != rightOrganizationID {
            return false
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
    /// Human plan tier ("Max 20x", "Pro") from the provider's profile
    /// endpoint; nil until fetched, and in profiles.json written before the
    /// field existed.
    public var planLabel: String?
    public var webDataStoreKind: WebDataStoreKind
    public var webDataStoreID: UUID
    public var identity: AccountIdentity?
    public var isActiveCLI: Bool
    /// Per-account, explicit permission to spend an earned Codex rate-limit
    /// reset when this account is active and reaches a hard Codex limit.
    public var autoUseCodexRateLimitResets: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        label: String,
        planLabel: String? = nil,
        webDataStoreKind: WebDataStoreKind = .isolated,
        webDataStoreID: UUID = UUID(),
        identity: AccountIdentity? = nil,
        isActiveCLI: Bool = false,
        autoUseCodexRateLimitResets: Bool = false,
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
        self.autoUseCodexRateLimitResets = autoUseCodexRateLimitResets
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
        case autoUseCodexRateLimitResets
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.provider = try container.decode(Provider.self, forKey: .provider)
        self.label = try container.decode(String.self, forKey: .label)
        // Absent in profiles.json written before plan labels existed; one
        // interim build persisted an empty-string default, which must decode
        // as "unknown" or the plan-tier fetch never runs for those profiles.
        let decodedPlanLabel = try container.decodeIfPresent(String.self, forKey: .planLabel)
        self.planLabel = (decodedPlanLabel?.isEmpty == true) ? nil : decodedPlanLabel
        self.webDataStoreKind = try container.decodeIfPresent(WebDataStoreKind.self, forKey: .webDataStoreKind) ?? .isolated
        self.webDataStoreID = try container.decode(UUID.self, forKey: .webDataStoreID)
        self.identity = try container.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        self.isActiveCLI = try container.decode(Bool.self, forKey: .isActiveCLI)
        self.autoUseCodexRateLimitResets = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoUseCodexRateLimitResets
        ) ?? false
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(planLabel, forKey: .planLabel)
        try container.encode(webDataStoreKind, forKey: .webDataStoreKind)
        try container.encode(webDataStoreID, forKey: .webDataStoreID)
        try container.encodeIfPresent(identity, forKey: .identity)
        try container.encode(isActiveCLI, forKey: .isActiveCLI)
        try container.encode(autoUseCodexRateLimitResets, forKey: .autoUseCodexRateLimitResets)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
