// swift-tools-version: 6.0
// Core 层（无 UI）。本任务只实现 Config（环境）；其余模块为占位骨架，由后续任务填充。
// 依赖方向：Core → Generated。
import PackageDescription

let placeholderModules = [
    "Network", "Session", "Router", "TradeJump", "BridgeHost",
    "PrivacyGate", "Tracker", "Clipboard", "Push", "SecureStore",
]

let package = Package(
    name: "Core",
    platforms: [.iOS(.v16)],
    products: [.library(name: "Config", targets: ["Config"])]
        + placeholderModules.map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(path: "../Generated"),
    ],
    targets: [
        .target(name: "Config"),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
    ] + placeholderModules.map {
        .target(name: $0, dependencies: [.product(name: "Generated", package: "Generated")])
    },
    swiftLanguageModes: [.v6]
)
