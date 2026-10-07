// swift-tools-version: 6.0
// Feature 层：每个功能一个 library target。Feature 之间没有依赖边（互相 import 会编译失败），
// 跨功能跳转只经 Router（路由名）。依赖方向：Features → Core、DesignSystem、Generated。
import PackageDescription

let features: [(name: String, task: String)] = [
    ("Home", "APP-11"), ("Search", "APP-06"), ("Product", "APP-06"),
    ("Agent", "APP-10"), ("Orders", "APP-08"), ("Wallet", "APP-09"),
    ("Me", "APP-12"), ("Auth", "APP-05"), ("Web", "APP-04"),
]

/// 个别 Feature 额外依赖的 Core 模块（仍只依赖 Core，不依赖其他 Feature）。
/// Web（APP-04）：两类 WebView 容器用 BridgeHost 的协议判定、BridgeHost 分派与第三方页导航判定。
let extraDependencies: [String: [Target.Dependency]] = [
    "Web": [.product(name: "BridgeHost", package: "Core")],
]

let package = Package(
    name: "Features",
    platforms: [.iOS(.v16)],
    products: features.map { .library(name: $0.name, targets: [$0.name]) },
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../DesignSystem"),
        .package(path: "../Generated"),
    ],
    targets: features.map {
        .target(
            name: $0.name,
            dependencies: [
                .product(name: "Router", package: "Core"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "Generated", package: "Generated"),
            ] + (extraDependencies[$0.name] ?? [])
        )
    },
    swiftLanguageModes: [.v6]
)
