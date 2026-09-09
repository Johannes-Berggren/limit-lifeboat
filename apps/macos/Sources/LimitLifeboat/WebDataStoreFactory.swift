import LimitLifeboatCore
import WebKit

enum WebDataStoreFactory {
    @MainActor
    static func makeDataStore(for profile: AccountProfile) -> WKWebsiteDataStore {
        switch profile.webDataStoreKind {
        case .appDefault:
            return .default()
        case .isolated:
            return WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
        }
    }

    /// Deletes every isolated store on disk that no current profile claims.
    ///
    /// WebKit requires that "WKWebView using the data store must be released
    /// before removal", and that cannot be established at the moment a profile
    /// is deleted: closing the dashboard window only *starts* the web view's
    /// teardown. Removing a store that was still held ended the process rather
    /// than reporting an error (issue #81), so orphans are collected here
    /// instead, at launch, before any dashboard window can exist. That also
    /// reclaims the stores leaked by versions that removed a profile but left
    /// its store behind.
    @MainActor
    static func removeOrphanedDataStores(keeping profiles: [AccountProfile]) async {
        let identifiers = orphanedDataStoreIdentifiers(
            existing: await WKWebsiteDataStore.allDataStoreIdentifiers,
            profiles: profiles
        )
        for identifier in identifiers {
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
                AppLog.persistence.info(
                    "Removed orphaned web data store \(identifier, privacy: .public)"
                )
            } catch {
                AppLog.persistence.error(
                    "Could not remove orphaned web data store \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// The stores in `existing` that no profile claims. A profile only claims
    /// its identifier while it is `.isolated`: one switched to the shared
    /// default store has stopped using its own, so that store is collectable
    /// too.
    static func orphanedDataStoreIdentifiers(
        existing: [UUID],
        profiles: [AccountProfile]
    ) -> [UUID] {
        let claimed = Set(
            profiles
                .filter { $0.webDataStoreKind == .isolated }
                .map(\.webDataStoreID)
        )
        return existing.filter { !claimed.contains($0) }
    }
}
