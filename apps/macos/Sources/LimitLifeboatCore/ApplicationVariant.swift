import Foundation

public enum ApplicationVariantError: Error, LocalizedError, Equatable {
    case invalidConfiguration(variant: String?, bundleIdentifier: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let variant, let bundleIdentifier):
            return "The app bundle has an invalid runtime configuration "
                + "(variant: \(variant ?? "missing"), bundle: \(bundleIdentifier ?? "missing")). "
                + "Rebuild or reinstall Limit Lifeboat."
        }
    }
}

/// Selects one complete app-owned namespace. Development builds deliberately
/// start empty so they cannot read, migrate, update, or register login items on
/// behalf of the installed distribution app.
public enum ApplicationVariant: String, CaseIterable, Sendable {
    public static let infoDictionaryKey = "LimitLifeboatAppVariant"

    case development
    case distribution

    public var bundleIdentifier: String {
        switch self {
        case .development:
            return "com.limitlifeboat.app.dev"
        case .distribution:
            return "com.limitlifeboat.app"
        }
    }

    public var displayName: String {
        switch self {
        case .development:
            return "Limit Lifeboat Dev"
        case .distribution:
            return "Limit Lifeboat"
        }
    }

    public var credentialService: String {
        switch self {
        case .development:
            return "com.limitlifeboat.app.dev.credentials"
        case .distribution:
            return "com.limitlifeboat.app.credentials"
        }
    }

    public var applicationSupportDirectoryName: String {
        switch self {
        case .development:
            return "LimitLifeboat-Dev"
        case .distribution:
            return "LimitLifeboat"
        }
    }

    public var supportsUpdates: Bool {
        self == .distribution
    }

    public var supportsLaunchAtLogin: Bool {
        self == .distribution
    }

    public var allowsLegacyMigration: Bool {
        self == .distribution
    }

    /// Unbundled tools and tests are development builds. A real app bundle,
    /// however, must declare a matching known variant and bundle identifier;
    /// a mismatch fails closed rather than touching either credential store.
    public static func resolve(
        declaredVariant: String?,
        bundleIdentifier: String?
    ) throws -> ApplicationVariant {
        if declaredVariant == nil, bundleIdentifier == nil {
            return .development
        }

        guard let declaredVariant,
              let variant = ApplicationVariant(rawValue: declaredVariant),
              bundleIdentifier == variant.bundleIdentifier else {
            throw ApplicationVariantError.invalidConfiguration(
                variant: declaredVariant,
                bundleIdentifier: bundleIdentifier
            )
        }
        return variant
    }

    public static func resolve(bundle: Bundle = .main) throws -> ApplicationVariant {
        try resolve(
            declaredVariant: bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String,
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    /// Safe default for feature gates reached from code that cannot throw.
    /// Invalid or unbundled configurations receive development restrictions.
    public static var current: ApplicationVariant {
        (try? resolve()) ?? .development
    }
}
