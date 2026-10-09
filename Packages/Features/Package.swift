// swift-tools-version: 6.0
// Feature 层：每个功能一个 library target。Feature 之间没有依赖边（互相 import 会编译失败），
// 跨功能跳转只经 Router（路由名）。依赖方向：Features → Core、DesignSystem、Generated。
import PackageDescription

let features: [(name: String, task: String)] = [
    ("Home", "APP-11"), ("Search", "APP-06"), ("Product", "APP-06"),
    ("Agent", "APP-10"), ("Orders", "APP-08"), ("Wallet", "APP-09"),
    ("Me", "APP-12"), ("Auth", "APP-05"), ("Web", "APP-04"),
    ("Login", "APP-05a"), ("Purchase", "APP-06b"),
]

/// 个别 Feature 额外依赖的 Core 模块（仍只依赖 Core，不依赖其他 Feature）。
/// Web（APP-04）：两类 WebView 容器用 BridgeHost 的协议判定、BridgeHost 分派与第三方页导航判定。
let extraDependencies: [String: [Target.Dependency]] = [
    "Web": [.product(name: "BridgeHost", package: "Core")],
    // Login（APP-05a）：短信登录主链路的纯逻辑（LoginFlow）与执行器（LoginService）经 ApiClient 发码、登录、登出，
    // 读会话作用域；页面在同一 target。模块名不与任何系统框架同名（Login 不是 SDK 里的框架名）。
    "Login": [
        .product(name: "CouliNetwork", package: "Core"),
        .product(name: "Session", package: "Core"),
    ],
    // Search / Product（APP-06a）：搜索与详情的纯逻辑和执行器在 Core 的 ProductSearch（Search 转出它；Product 直接用它，
    // 两个 Feature 之间没有依赖边）。
    "Search": [
        .product(name: "ProductSearch", package: "Core"),
        .product(name: "CouliNetwork", package: "Core"),
        .product(name: "Trade", package: "Core"),
    ],
    "Product": [
        .product(name: "ProductSearch", package: "Core"),
        .product(name: "CouliNetwork", package: "Core"),
        .product(name: "Trade", package: "Core"),
    ],
    // Purchase（APP-06b）：购买浮层（加载层、超时条、确认框、AuthSheet、JumpTip、浏览器提示）与授权管理页。执行器在 Core 的 Trade；
    // 由 App 盖在详情页 / 搜索页之上（Product、Search 不依赖本模块）。
    "Purchase": [
        .product(name: "Trade", package: "Core"),
        .product(name: "ProductSearch", package: "Core"),
    ],
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
    } + [
        // Codex 先写的向量测试（specs/login-vectors.json）与登录集成测试（本地 URLProtocol 假服务）。
        .testTarget(
            name: "LoginTests",
            dependencies: [
                "Login",
                .product(name: "Router", package: "Core"),
                .product(name: "CouliNetwork", package: "Core"),
                .product(name: "Session", package: "Core"),
                .product(name: "Generated", package: "Generated"),
            ]
        ),
        // Codex 先写的向量测试（specs/search-product-vectors.json）与搜索 / 详情集成测试（本地 URLProtocol 假服务）。
        .testTarget(
            name: "SearchTests",
            dependencies: [
                "Search",
                .product(name: "ProductSearch", package: "Core"),
                .product(name: "CouliNetwork", package: "Core"),
                .product(name: "Session", package: "Core"),
                .product(name: "Generated", package: "Generated"),
                .product(name: "DesignSystem", package: "DesignSystem"),
            ]
        ),
        // Codex 先写的向量测试（specs/open-trade-vectors.json，`@testable import Trade`）与购买、外跳、授权、授权管理的执行器测试
        // 与本地假服务（URLProtocol + 真实 ApiClient）集成测试。被测模块 Trade 在 Core（Features 之间没有依赖边）；弹窗文字拼装
        // （PurchaseText，共性第 47 条）在本包的 Purchase。
        .testTarget(
            name: "TradeTests",
            dependencies: [
                "Purchase",
                .product(name: "Trade", package: "Core"),
                .product(name: "TradeJump", package: "Core"),
                .product(name: "ProductSearch", package: "Core"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "CouliNetwork", package: "Core"),
                .product(name: "Session", package: "Core"),
                .product(name: "Generated", package: "Generated"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
