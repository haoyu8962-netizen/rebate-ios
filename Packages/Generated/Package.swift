// swift-tools-version: 6.0
// 契约生成物包：Sources/Generated 由 tools/codegen/gen.py 生成，禁止手改。
import PackageDescription

let package = Package(
    name: "Generated",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "Generated", targets: ["Generated"]),
    ],
    targets: [
        .target(
            name: "Generated",
            resources: [.copy("Resources/texts.default.json")]
        ),
        .testTarget(
            name: "GeneratedTests",
            dependencies: ["Generated"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
