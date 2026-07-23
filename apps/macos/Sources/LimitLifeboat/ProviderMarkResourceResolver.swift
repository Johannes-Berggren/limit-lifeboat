import AppKit
import Foundation

/// Locates SwiftPM's provider-mark resource bundle without relying on the
/// generated resource accessor, which terminates the process when a manually
/// assembled app cannot find the bundle.
struct ProviderMarkResourceResolver {
    static let resourceBundleName = "LimitLifeboat_LimitLifeboat.bundle"

    private let resourceBundleURLs: [URL]

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) {
        let parentURLs = [
            resourceURL,
            bundleURL,
            executableURL?.deletingLastPathComponent()
        ].compactMap { $0 }

        var seenPaths = Set<String>()
        self.resourceBundleURLs = parentURLs.compactMap { parentURL in
            let candidate = parentURL
                .appendingPathComponent(Self.resourceBundleName, isDirectory: true)
                .standardizedFileURL
            return seenPaths.insert(candidate.path).inserted ? candidate : nil
        }
    }

    func image(named resourceName: String) -> NSImage? {
        for resourceBundleURL in resourceBundleURLs {
            let imageURL = resourceBundleURL
                .appendingPathComponent("ProviderMarks", isDirectory: true)
                .appendingPathComponent(resourceName)
                .appendingPathExtension("pdf")

            guard FileManager.default.isReadableFile(atPath: imageURL.path),
                  let image = NSImage(contentsOf: imageURL),
                  image.isValid else {
                continue
            }
            return image
        }
        return nil
    }
}
