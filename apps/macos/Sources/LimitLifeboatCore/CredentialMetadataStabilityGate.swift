public enum CredentialMetadataStabilityDecision: Equatable, Sendable {
    case wait
    case read
    case fallbackRead
    case reevaluateCachedRead
}

/// Converts noisy metadata polling into one credential-read decision. A
/// provider item must change and then remain unchanged, together with its
/// nonsecret settle signal, across two observations. Once that single read is
/// cached, later settled filesystem metadata can be re-evaluated without
/// reading the secret again.
public struct CredentialMetadataStabilityGate<Item: Equatable, Settle: Equatable> {
    private var lastAttemptedItem: Item
    private var pending: (item: Item, settle: Settle)?
    private var hasCachedRead = false
    private var lastEvaluatedSettle: Settle?
    private var pendingReevaluation: Settle?
    private let initialSettle: Settle?
    private let allowSettledFallbackRead: Bool
    private var fallbackReadUsed = false

    public init(
        lastAttemptedItem: Item,
        initialSettle: Settle? = nil,
        allowSettledFallbackRead: Bool = false
    ) {
        self.lastAttemptedItem = lastAttemptedItem
        self.initialSettle = initialSettle
        self.allowSettledFallbackRead = allowSettledFallbackRead
    }

    public mutating func shouldRead(item: Item, settle: Settle) -> Bool {
        let decision = decision(item: item, settle: settle)
        return decision == .read || decision == .fallbackRead
    }

    /// Discards a fallback whose pinned payload still matched the pre-login
    /// baseline. The one collision fallback is not repeated; a later exact
    /// item metadata generation can still authorize its normal read.
    public mutating func discardFallbackRead() {
        hasCachedRead = false
        lastEvaluatedSettle = nil
        pendingReevaluation = nil
    }

    public mutating func decision(
        item: Item,
        settle: Settle
    ) -> CredentialMetadataStabilityDecision {
        guard item != lastAttemptedItem else {
            pending = nil
            guard hasCachedRead else {
                guard allowSettledFallbackRead,
                      !fallbackReadUsed,
                      initialSettle != settle else {
                    return .wait
                }
                if pendingReevaluation == settle {
                    fallbackReadUsed = true
                    hasCachedRead = true
                    lastEvaluatedSettle = settle
                    pendingReevaluation = nil
                    return .fallbackRead
                }
                pendingReevaluation = settle
                return .wait
            }
            guard lastEvaluatedSettle != settle else {
                pendingReevaluation = nil
                return .wait
            }
            if pendingReevaluation == settle {
                lastEvaluatedSettle = settle
                pendingReevaluation = nil
                return .reevaluateCachedRead
            }
            pendingReevaluation = settle
            return .wait
        }
        pendingReevaluation = nil
        guard let pending else {
            self.pending = (item, settle)
            return .wait
        }
        guard pending.item == item, pending.settle == settle else {
            self.pending = (item, settle)
            return .wait
        }
        lastAttemptedItem = item
        self.pending = nil
        hasCachedRead = true
        lastEvaluatedSettle = settle
        return .read
    }
}
