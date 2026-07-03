// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMUsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LLMUsageMonitorCore", targets: ["LLMUsageMonitorCore"]),
        .executable(name: "LLMUsageMonitor", targets: ["LLMUsageMonitor"])
    ],
    targets: [
        .target(name: "LLMUsageMonitorCore"),
        .executableTarget(
            name: "LLMUsageMonitor",
            dependencies: ["LLMUsageMonitorCore"]
        ),
        .testTarget(
            name: "LLMUsageMonitorCoreTests",
            dependencies: ["LLMUsageMonitorCore"]
        )
    ]
)
