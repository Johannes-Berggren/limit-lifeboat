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
    targets: [
        .target(name: "LimitLifeboatCore"),
        .executableTarget(
            name: "LimitLifeboat",
            dependencies: ["LimitLifeboatCore"]
        ),
        .testTarget(
            name: "LimitLifeboatCoreTests",
            dependencies: ["LimitLifeboatCore"]
        )
    ]
)
