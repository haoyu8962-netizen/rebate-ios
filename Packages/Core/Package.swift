// swift-tools-version: 6.0
// Core 层（无 UI）。已实现 Config（环境）、Router（入口守卫、深链、pending_action，APP-02a）
// 与 Privacy（隐私首启闸门、基本模式、撤回同意、onConsented 初始化顺序，APP-02b）；
// 其余模块为占位骨架，由后续任务填充。依赖方向：Core → Generated。
import PackageDescription

let placeholderModules = [
    "Network", "Session", "TradeJump", "BridgeHost",
    "Tracker", "Clipboard", "Push", "SecureStore",
]

let package = Package(
    name: "Core",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Config", targets: ["Config"]),
        .library(name: "Router", targets: ["Router"]),
        .library(name: "Privacy", targets: ["Privacy"]),
    ] + placeholderModules.map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(path: "../Generated"),
    ],
    targets: [
        .target(name: "Config"),
        .testTarget(name: "ConfigTests", dependencies: ["Config"]),
        .target(
            name: "Router",
            dependencies: ["Config", .product(name: "Generated", package: "Generated")]
        ),
        .testTarget(name: "RouterTests", dependencies: ["Router"]),
        .target(name: "Privacy", dependencies: ["Config"]),
        .testTarget(name: "PrivacyTests", dependencies: ["Privacy", "Config"]),
    ] + placeholderModules.map {
        .target(name: $0, dependencies: [.product(name: "Generated", package: "Generated")])
    },
    swiftLanguageModes: [.v6]
)
