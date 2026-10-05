// swift-tools-version: 6.0
// Feature 层：每个功能一个 library target。Feature 之间没有依赖边（互相 import 会编译失败），
// 跨功能跳转只经 Router（路由名）。依赖方向：Features → Core、DesignSystem、Generated。
import PackageDescription

let features: [(name: String, task: String)] = [
    ("Home", "APP-11"), ("Search", "APP-06"), ("Product", "APP-06"),
    ("Agent", "APP-10"), ("Orders", "APP-08"), ("Wallet", "APP-09"),
    ("Me", "APP-12"), ("Auth", "APP-05"), ("Web", "APP-04"),
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
            ]
        )
    },
    swiftLanguageModes: [.v6]
)
