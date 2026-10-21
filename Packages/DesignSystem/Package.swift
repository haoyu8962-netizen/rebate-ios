// swift-tools-version: 6.0
// 设计系统：令牌映射、格式化与组件模型（纯函数）、SwiftUI 组件（DS-01）；品牌 Logo 资源 Resources/Brand.xcassets（BRAND-01）；
// 平台内置图标 Resources/PlatformIcons（F-X-05a）。
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
            dependencies: [.product(name: "Generated", package: "Generated")],
            // 平台图标的人读说明不进安装包（机器清单 manifest.json 随图入包）。
            exclude: ["Resources/PlatformIcons-README.md"],
            // 品牌 Logo 走资源目录编译；平台内置图标（F-X-05a）按目录原样拷贝，保留原始 PNG 字节（不重压缩），
            // 运行时位置 Bundle.module.resourceURL/PlatformIcons/，来源与 sha256 见其中 manifest.json。
            resources: [
                .process("Resources/Brand.xcassets"),
                .copy("Resources/PlatformIcons"),
            ]
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
