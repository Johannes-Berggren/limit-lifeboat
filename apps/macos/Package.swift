// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LimitLifeboat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LimitLifeboatCore", targets: ["LimitLifeboatCore"]),
        .library(name: "LimitLifeboatAppWorkflows", targets: ["LimitLifeboatAppWorkflows"]),
        .executable(name: "LimitLifeboat", targets: ["LimitLifeboat"]),
        .executable(name: "limit-lifeboat", targets: ["LimitLifeboatCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(name: "LimitLifeboatCore"),
        .target(
            name: "LimitLifeboatAppWorkflows",
            dependencies: ["LimitLifeboatCore"]
        ),
        .executableTarget(
            name: "LimitLifeboat",
            dependencies: [
                "LimitLifeboatCore",
                "LimitLifeboatAppWorkflows",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        // The read-only companion CLI. Depends on Core only — it must never
        // pull in AppKit, Sparkle, or the switch path. The target is named
        // LimitLifeboatCLI, and the binary limit-lifeboat, because macOS
        // filesystems are case-insensitive by default: a Sources/limitlifeboat
        // directory silently resolves to Sources/LimitLifeboat and steals the
        // app's sources, and a limitlifeboat product overwrites the app's own
        // LimitLifeboat binary in .build. The hyphen also matches the Homebrew
        // cask name.
        .executableTarget(
            name: "LimitLifeboatCLI",
            dependencies: ["LimitLifeboatCore"]
        ),
        .testTarget(
            name: "LimitLifeboatCoreTests",
            dependencies: ["LimitLifeboatCore"]
        ),
        .testTarget(
            name: "LimitLifeboatAppTests",
            dependencies: [
                "LimitLifeboat",
                "LimitLifeboatAppWorkflows",
                "LimitLifeboatCore"
            ]
        )
    ]
)
