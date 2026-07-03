import LLMUsageMonitorCore
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
}
