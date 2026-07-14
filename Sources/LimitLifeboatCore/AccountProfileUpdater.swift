import Foundation

public struct AccountProfileEnrichment: Equatable, Sendable {
    public var planLabel: String?
    public var identity: AccountIdentity?

    public init(planLabel: String? = nil, identity: AccountIdentity? = nil) {
        self.planLabel = planLabel
        self.identity = identity
    }
}

/// Pure profile mutation rules shared by Claude and Codex enrichment paths.
public enum AccountProfileUpdater {
    public struct ActivationChange: Equatable, Sendable {
        public var changed: Bool
        public var activatedID: UUID?
        public var deactivatedIDs: [UUID]

        public init(changed: Bool, activatedID: UUID?, deactivatedIDs: [UUID]) {
            self.changed = changed
            self.activatedID = activatedID
            self.deactivatedIDs = deactivatedIDs
        }
    }

    /// Enforces the one-active-profile-per-provider invariant. Passing nil
    /// deactivates the provider without touching accounts from the other one.
    @discardableResult
    public static func setActiveCLI(
        profiles: inout [AccountProfile],
        provider: Provider,
        profileID: UUID?,
        now: Date = Date()
    ) -> ActivationChange {
        var changed = false
        var activatedID: UUID?
        var deactivatedIDs: [UUID] = []
        for index in profiles.indices where profiles[index].provider == provider {
            let shouldBeActive = profiles[index].id == profileID
            guard profiles[index].isActiveCLI != shouldBeActive else {
                continue
            }
            profiles[index].isActiveCLI = shouldBeActive
            profiles[index].updatedAt = now
            changed = true
            if shouldBeActive {
                activatedID = profiles[index].id
            } else {
                deactivatedIDs.append(profiles[index].id)
            }
        }
        return ActivationChange(changed: changed, activatedID: activatedID, deactivatedIDs: deactivatedIDs)
    }

    @discardableResult
    public static func enrich(
        profiles: inout [AccountProfile],
        profileID: UUID,
        enrichment: AccountProfileEnrichment,
        now: Date = Date()
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return false
        }

        var changed = false
        if let plan = enrichment.planLabel, profiles[index].planLabel != plan {
            profiles[index].planLabel = plan
            changed = true
        }
        if let identity = enrichment.identity {
            let merged = mergeIdentity(existing: profiles[index].identity, new: identity)
            if profiles[index].identity != merged {
                profiles[index].identity = merged
                changed = true
            }
        }
        if changed {
            profiles[index].updatedAt = now
        }
        return changed
    }

    public static func mergeIdentity(existing: AccountIdentity?, new: AccountIdentity) -> AccountIdentity {
        guard let existing else {
            return new
        }
        return AccountIdentity(
            email: new.email ?? existing.email,
            displayName: new.displayName ?? existing.displayName,
            organization: new.organization ?? existing.organization,
            organizationID: new.organizationID ?? existing.organizationID,
            accountID: new.accountID ?? existing.accountID,
            source: new.source,
            updatedAt: new.updatedAt
        )
    }
}
