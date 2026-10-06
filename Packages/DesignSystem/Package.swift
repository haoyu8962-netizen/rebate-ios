// swift-tools-version: 6.0
// 设计系统：令牌映射、格式化与组件模型（纯函数）、SwiftUI 组件（DS-01）。
// 依赖方向：DesignSystem → Generated。快照测试库只给测试 target（精确版本）。
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    dependencies: [
        .package(path: "../Generated"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: [.product(name: "Generated", package: "Generated")]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: [
                "DesignSystem",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
