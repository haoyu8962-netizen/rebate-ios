// TODO(N-16) 待法务定稿，不得提审：本文件全部文字都是设计稿上的草稿（契约 texts.default.json 还没有键，
// contracts/README：privacy.first_launch.* 等待法务，规划/06 Q-F14）。提审前（QA-07）必须换成文案字典的键，
// 并删除本文件。只允许 App 外壳（首启弹窗、二次说明、基本模式页、Tab 栏）引用；Feature 目录不得出现中文。
//
// 来源：design-hifi/project/LaunchPrivacy.dc.html、LaunchSecondNotice.dc.html、BasicMode.dc.html、HomeGuest.dc.html（逐字）。

/// 外壳草稿文字（集中一处）。
enum ShellDraftTexts {
    // MARK: 首启弹窗（LaunchPrivacy）

    /// TODO(N-16) 待法务定稿，不得提审。
    static let launchTitle = "个人信息保护提示"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let launchIntro = "欢迎使用凑狸。使用前请阅读以下说明："
    /// TODO(N-16) 待法务定稿，不得提审。
    static let launchPoints = [
        "同意后，我们会收集设备信息、手机号等，用于登录、查找商品、记录订单和发放返利；不同用途收集哪些信息，见《个人信息收集清单》。",
        "App 接入了推送、联盟、崩溃统计、微信等第三方 SDK，它们只在你同意后才会启动，详见《第三方 SDK 共享清单》。",
        "你可以随时在「设置 → 隐私中心」查看清单、撤回同意，或注销账号。",
    ]

    // MARK: 协议链接（首启弹窗、二次说明）

    /// TODO(N-16) 待法务定稿，不得提审。
    static let linkPrivacyPolicy = "《隐私政策》"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let linkUserAgreement = "《用户协议》"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let linkCollectionList = "《个人信息收集清单》"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let linkSdkList = "《第三方 SDK 共享清单》"

    // MARK: 二次说明（LaunchSecondNotice）

    /// TODO(N-16) 待法务定稿，不得提审。
    static let secondTitle = "温馨提示"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let secondBody = "不同意的话，只能用基本模式浏览首页、搜索和商品详情，不能登录，也拿不到返利。之后随时可以点【开启完整功能】重新选择。"

    // MARK: 基本模式页（BasicMode）

    /// 搜索框提示（基本模式不能识别链接，所以不是「搜索商品或粘贴链接」）。TODO(N-16) 待法务定稿，不得提审。
    static let basicSearchPlaceholder = "搜索商品"
    /// 【设置】入口的读屏名称。TODO(N-16) 待法务定稿，不得提审。
    static let settingsLabel = "设置"

    // MARK: Tab 栏

    /// TODO(N-16) 待法务定稿，不得提审。
    static let tabHome = "首页"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let tabAgent = "AI 助手"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let tabOrders = "订单"
    /// TODO(N-16) 待法务定稿，不得提审。
    static let tabMe = "我的"
}
