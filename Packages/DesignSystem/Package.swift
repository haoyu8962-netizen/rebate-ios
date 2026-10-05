// swift-tools-version: 6.0
// 设计系统：本任务只有令牌映射（Color / Font / Spacing / Radius / 命中区），组件在下一个任务。
// 依赖方向：DesignSystem → Generated。
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    dependencies: [
        .package(path: "../Generated"),
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: [.product(name: "Generated", package: "Generated")]
        ),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ],
    swiftLanguageModes: [.v6]
)
