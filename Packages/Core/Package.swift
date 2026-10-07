// swift-tools-version: 6.0
// Core 层（无 UI）。已实现 Config（环境）、Router（入口守卫、深链、pending_action，APP-02a）、
// Privacy（隐私首启闸门、基本模式、撤回同意、onConsented 初始化顺序，APP-02b）
// 与 Update（强更检查、可关闭提示、选店，APP-02c）、SecureStore（Keychain）、Session（令牌）、
// CouliNetwork（请求管线、签名、单飞刷新、ErrorActionMapper、未决键，APP-03a）、
// ClientCore（设备注册 DeviceRegistry、ConfigStore + LKG、Tracker、PermissionRequester，APP-03b）；
// 其余模块为占位骨架，由后续任务填充。依赖方向：Core → Generated。
import PackageDescription

let placeholderModules = [
    "TradeJump", "BridgeHost",
    "Clipboard", "Push",
]

let generated: Target.Dependency = .product(name: "Generated", package: "Generated")

let coreTargets: [Target] = [
    .target(name: "Config"),
    .testTarget(name: "ConfigTests", dependencies: ["Config"]),
    .target(name: "Router", dependencies: ["Config", generated]),
    .testTarget(name: "RouterTests", dependencies: ["Router"]),
    .target(name: "Privacy", dependencies: ["Config", "Session", "SecureStore"]),
    .testTarget(name: "PrivacyTests", dependencies: ["Privacy", "Config", "Session"]),
    .target(name: "Update", dependencies: ["Config"]),
    .testTarget(name: "UpdateTests", dependencies: ["Update", "Config"]),
    .target(name: "SecureStore", dependencies: ["Config"]),
    .target(name: "Session", dependencies: ["Config", "SecureStore"]),
    .target(name: "CouliNetwork", dependencies: ["Session", "SecureStore", "Config", generated]),
    .testTarget(
        name: "NetworkTests",
        dependencies: ["CouliNetwork", "Session", "SecureStore", generated],
        // 业务模块名带项目前缀（CouliNetwork），避免与系统 Network 框架同名：同名时 Xcode 把它放进共享
        // 产物目录，SnapshotTesting 等依赖 `import Network` 会解析到本模块而编译失败。
        // Codex 先写的 NetworkVectorTests.swift 写的是 `@testable import Network`（约定不改测试），
        // 测试 target 用编译器的模块别名把源码里的 Network 映射到 CouliNetwork；只作用于本测试 target。
        swiftSettings: [.unsafeFlags(["-module-alias", "Network=CouliNetwork"])]
    ),
    // APP-03b。模块名带 Client 前缀：不与任何系统框架同名（理由同上）。
    .target(
        name: "ClientCore",
        dependencies: ["CouliNetwork", "Config", "Privacy", "SecureStore", "Session", generated]
    ),
    .testTarget(
        name: "ClientCoreTests",
        dependencies: ["ClientCore", "CouliNetwork", "Config", "Privacy", "SecureStore", "Session", generated]
    ),
]

let placeholderTargets: [Target] = placeholderModules.map {
    .target(name: $0, dependencies: [generated])
}

let coreProducts: [Product] = [
    .library(name: "Config", targets: ["Config"]),
    .library(name: "Router", targets: ["Router"]),
    .library(name: "Privacy", targets: ["Privacy"]),
    .library(name: "Update", targets: ["Update"]),
    .library(name: "SecureStore", targets: ["SecureStore"]),
    .library(name: "Session", targets: ["Session"]),
    .library(name: "CouliNetwork", targets: ["CouliNetwork"]),
    .library(name: "ClientCore", targets: ["ClientCore"]),
]

let placeholderProducts: [Product] = placeholderModules.map { .library(name: $0, targets: [$0]) }

let package = Package(
    name: "Core",
    platforms: [.iOS(.v16)],
    products: coreProducts + placeholderProducts,
    dependencies: [
        .package(path: "../Generated"),
    ],
    targets: coreTargets + placeholderTargets,
    swiftLanguageModes: [.v6]
)
