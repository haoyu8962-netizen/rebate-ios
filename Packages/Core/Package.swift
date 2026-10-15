// swift-tools-version: 6.0
// Core 层（无 UI）。已实现 Config（环境）、Router（入口守卫、深链、pending_action，APP-02a）、
// Privacy（隐私首启闸门、基本模式、撤回同意、onConsented 初始化顺序，APP-02b）
// 与 Update（强更检查、可关闭提示、选店，APP-02c）、SecureStore（Keychain）、Session（令牌）、
// CouliNetwork（请求管线、签名、单飞刷新、ErrorActionMapper、未决键，APP-03a）、
// ClientCore（设备注册 DeviceRegistry、ConfigStore + LKG、Tracker、PermissionRequester，APP-03b）、
// BridgeHost（桥协议、BridgeHost、第三方页导航判定，APP-04）、ProductSearch（搜索与商品详情，APP-06a）、
// TradeJump（联盟 SDK 适配层：接口 + 不可用实现，APP-06b）与 Trade（open 购买、跳转方案执行、授权、授权管理，APP-06b）、
// Clipboard（剪贴板识别，APP-07）、OrderCore（订单与待跟单卡，APP-08）、WalletCore（钱包与提现，APP-09）、
// MeCore（「我的」、设置、隐私中心、关于、封禁说明与申诉、客服出口，APP-12）与 Push（推送令牌上报，APP-12）；
// 其余模块为占位骨架，由后续任务填充。依赖方向：Core → Generated。
import PackageDescription

let placeholderModules: [String] = []

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
    // APP-04：桥协议（信封、级别、白名单、事件）、BridgeHost 分派与第三方页导航判定。纯逻辑，不依赖 WebKit；
    // 容器（WKWebView）在 Features/Web。
    .target(name: "BridgeHost", dependencies: [generated]),
    .testTarget(name: "BridgeHostTests", dependencies: ["BridgeHost"]),
    // APP-06a：搜索与商品详情的纯逻辑（SearchQuery、SearchTabs、SearchPager、SearchResultState、SearchSession、
    // ProductDetailState）与执行器（SearchController、ProductDetailController）。Search 功能模块转出它，Product 功能
    // 模块直接用它（Feature 之间不互相依赖）。模块名不与任何系统框架同名。
    .target(name: "ProductSearch", dependencies: ["CouliNetwork", generated]),
    // APP-06b：联盟 SDK 适配层（百川接口 + 不可用实现；不引入任何 SDK）。
    .target(name: "TradeJump", dependencies: [generated]),
    // APP-06b：open
    // 购买的纯逻辑（OpenAttempt、OpenResponseAction、OpenErrorAction、JumpPlanRunner、LinkJumpEvents、AuthMethodPicker，
    // 向量
    // specs/open-trade-vectors.json）与执行器（OpenPurchaseController、TradeJumpExecutor、TaobaoAuthFlow、AuthManageController）。
    // Product / Search / Purchase 功能模块都用它（Feature 之间不互相依赖）。测试在 Features/Tests/TradeTests（Codex 先写的位置）。
    .target(name: "Trade", dependencies: ["CouliNetwork", "TradeJump", generated]),
    // APP-07：剪贴板识别的纯逻辑（读取判定、分类、邀请码抽取、自写记录与提示记录、parse 结果映射，向量
    // specs/clipboard-vectors.json）与执行端口（ClipboardWatcher、ClipboardWriter、ParseInputService）。不读 UIPasteboard：
    // 系统剪贴板经 App 给的 SystemClipboard 端口。
    .target(name: "Clipboard", dependencies: ["CouliNetwork"]),
    .testTarget(name: "ClipboardTests", dependencies: ["Clipboard", "CouliNetwork"]),
    // APP-08：订单列表与详情、待跟单卡的纯逻辑（查询参数、显示规则、错误 → 动作、待跟单卡、断网缓存策略，向量 specs/order-vectors.json）
    // 与执行器（OrderListController、PendingTrackService、OrderSessionHub、OrderCacheStore 等）。
    // 金额隐藏偏好 AmountMaskStore 已挪到 ClientCore（APP-09 G24），这里保留同名 typealias。
    // Orders 功能模块用它；待跟单卡也给商品详情 / 搜索页用。Router 只用参数校验与 JSONValue。
    .target(name: "OrderCore", dependencies: ["CouliNetwork", "Router", "ClientCore", generated]),
    .testTarget(name: "OrderCoreTests", dependencies: ["OrderCore", "CouliNetwork", "Session", generated]),
    // APP-09：钱包、提现、收款账号、实名、劳务协议与二次验证的纯逻辑（显示规则、金额输入、估算归属、block 引导、结局表、step-up token、
    // 提现单文案、收款账号表单与脱敏摘要、实名表单、断网缓存，向量 specs/wallet-vectors.json）与执行器（WalletController、
    // WithdrawController、SensitiveFlow、StepUpController、PayoutAccountController、WithdrawRecordsController、实名与劳务协议）。
    // 金额隐藏偏好是 ClientCore 的 AmountMaskStore（G24：从 OrderCore 挪来，存储与键不变）；缓存的待清理标记复用 OrderCore 的端口。
    // 「我的」、设置页以后也用本模块。
    .target(name: "WalletCore", dependencies: ["CouliNetwork", "Router", "ClientCore", "OrderCore", generated]),
    .testTarget(
        name: "WalletCoreTests",
        dependencies: ["WalletCore", "CouliNetwork", "OrderCore", "Session", generated]
    ),
    // APP-12：「我的」、设置、隐私中心、关于、封禁说明与申诉、统一客服出口的纯逻辑（Me 解析、显示规则、设置条目、隐私中心分节、个性化、
    // 撤回同意、昵称、RiskNotice、申诉、客服决策、诊断信息、10006 落点、推送上报策略，向量 specs/me-vectors.json）与执行器（Me 快照、
    // 各页执行器、撤回 / 退出交给 App 的协调器）。时间文本不依赖 DesignSystem（Core 无 UI）：按 CouliFormat 同一写法在本模块实现，
    // 向量测试逐字比对（鸿蒙 H02 同口径）。复用 APP-09 的 WalletCore（WithdrawalText、错误分类、FieldErrorCue）。
    .target(
        name: "MeCore",
        dependencies: ["CouliNetwork", "ClientCore", "Config", "WalletCore", generated]
    ),
    // Codex 先写的向量测试（`@testable import MeCore`，另 import DesignSystem 比对恢复时间写法）与执行器测试。
    .testTarget(
        name: "MeCoreTests",
        dependencies: [
            "MeCore", "CouliNetwork", "Session", generated,
            .product(name: "DesignSystem", package: "DesignSystem"),
        ],
        // Codex 的测试在 XCTContext.runActivity 的闭包里用非 Sendable 的 [String: Any]（实现前测试，未按 Swift 6 严格并发写）；
        // 测试不改，只把本测试 target 的语言模式降到 Swift 5（生产 target 仍是 Swift 6）。rule-gaps I 段登记。
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // APP-12：推送令牌上报（PushTokenSource 接口、Release 无令牌实现、会话级上报执行器、登录 / 冷启动区分）。不接入任何推送 SDK（G17）。
    .target(name: "Push", dependencies: ["MeCore", "CouliNetwork", generated]),
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
    .library(name: "BridgeHost", targets: ["BridgeHost"]),
    .library(name: "ProductSearch", targets: ["ProductSearch"]),
    .library(name: "TradeJump", targets: ["TradeJump"]),
    .library(name: "Trade", targets: ["Trade"]),
    .library(name: "Clipboard", targets: ["Clipboard"]),
    .library(name: "OrderCore", targets: ["OrderCore"]),
    .library(name: "WalletCore", targets: ["WalletCore"]),
    .library(name: "MeCore", targets: ["MeCore"]),
    .library(name: "Push", targets: ["Push"]),
]

let placeholderProducts: [Product] = placeholderModules.map { .library(name: $0, targets: [$0]) }

let package = Package(
    name: "Core",
    platforms: [.iOS(.v16)],
    products: coreProducts + placeholderProducts,
    dependencies: [
        .package(path: "../Generated"),
        // 只给 MeCoreTests（Codex 向量测试比对 CouliFormat.timeListFuture）；Core 的生产 target 不依赖 DesignSystem。
        .package(path: "../DesignSystem"),
    ],
    targets: coreTargets + placeholderTargets,
    swiftLanguageModes: [.v6]
)
