// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LimitLifeboat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LimitLifeboatCore", targets: ["LimitLifeboatCore"]),
        .executable(name: "LimitLifeboat", targets: ["LimitLifeboat"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(name: "LimitLifeboatCore"),
        .executableTarget(
            name: "LimitLifeboat",
            dependencies: [
                "LimitLifeboatCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "LimitLifeboatCoreTests",
            dependencies: ["LimitLifeboatCore"]
        )
    ]
)
