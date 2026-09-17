import Foundation

public enum ModelNaming {
    /// "claude-opus-5" → "Opus 5", "claude-haiku-4-5-20251001" → "Haiku 4.5",
    /// and the older order "claude-3-5-haiku-20241022" → "Haiku 3.5". Names
    /// that are not Claude model IDs are returned unchanged.
    public static func short(_ model: String) -> String {
        var components = model.split(separator: "-").map(String.init)
        guard components.first == "claude" else { return model }
        components.removeFirst()
        // Snapshot dates carry no meaning for a person.
        components.removeAll { $0.count >= 8 && $0.allSatisfy(\.isNumber) }
        guard let family = components.first(where: { $0.contains(where: \.isLetter) }) else {
            return model
        }
        let version = components.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}
