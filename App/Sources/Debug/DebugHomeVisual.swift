#if DEBUG
import Clipboard
import Combine
import DesignSystem
import Foundation
import HomeCore
import Session
import SwiftUI
import UIKit

/// 首页视觉 UI 测试的 Debug 场景入口（APP-11v；只在 Debug / Staging 编译，Release 制品扫描查 `marker`）。
///
/// 启动参数 `-CouliHomeVisual 1` + 环境变量 `COULI_HOME_VISUAL_REQUEST`（UTF-8 JSON 的 Base64：settings / fixture / popup / banner
/// /
/// notice）。只替换真实 App 组装里的会话、首页端口、时钟、图片与系统依赖，界面仍是真实 RootView；不另造预览页。
/// 对外只读的调试元素：`home.visual.ready`（场景名）、`home.visual.canvas`（截图边界）、`home.visual.diagnostics`（实际控制器 /
/// 端口 / 剪贴板 / UIKit 实例读数）、`home.visual.layout`（生产组件上报的原始布局框）、`home.visual.focus`、`home.visual.clock`、
/// `home.visual.width`。Darwin 信号前缀 `com.couli.app.debug.uitest.home-visual.`：login-hold / logout / reader-on /
/// advance-10000 / width-840 / width-390，全部经真实出口执行。
@MainActor
final class DebugHomeVisual: ObservableObject {
    static let marker = "COULI_HOME_VISUAL_UITEST_APP11V_IOS_7a3c5e"
    static let argument = "-CouliHomeVisual"
    static let environmentKey = "COULI_HOME_VISUAL_REQUEST"
    static let signalPrefix = "com.couli.app.debug.uitest.home-visual."

    /// 本次启动的场景（没有 `-CouliHomeVisual` 或请求解不开时为 nil，App 照常）。
    private(set) static var shared: DebugHomeVisual?

    struct Settings: Decodable {
        let name: String
        let page: String
        let scene: String
        let level: String
        let dark: Bool
        let width: Int
        let height: Int
        let category: String
    }

    let settings: Settings
    let port: DebugHomeVisualPort
    let clock = DebugHomeVisualClock()
    private let lkgPage: Data

    @Published var width: CGFloat
    @Published var ready: String?
    @Published var diagnostics = "{}"
    @Published var layout = "[]"
    @Published var focus = ""

    weak var home: AppHome?
    weak var clipboard: AppClipboard?
    weak var login: AppLogin?
    var probes: [String: CouliLayoutProbeRecord] = [:]
    var layoutDirty = false
    /// 最近一次测量变化的时刻：滚动 / 动画进行中不重发整份测量（避免每 0.2 秒重算无障碍值拖慢主线程），停稳 0.3 秒后再发。
    var layoutChangedAt = Date.distantPast
    /// 已找到的系统粘贴控件实例（读数用）。
    weak var pasteControl: UIView?
    /// 最近一次发出的测量记录编号集合。
    var publishedProbeIDs: Set<String> = []
    var revision = 0
    var nativeSignature = ""
    private var poller: Timer?
    var quietTicks = 0
    var lastImages = -1
    var sceneStep = 0
    /// 长信息流测量（场景 long_feed；其余场景为 nil）。
    lazy var longFeed: DebugHomeVisualLongFeed? = settings.scene == "long_feed"
        ? DebugHomeVisualLongFeed(visual: self) : nil

    private init(settings: Settings, page: Data, responses: [String: Data]) {
        self.settings = settings
        lkgPage = page
        port = DebugHomeVisualPort(scene: settings.scene, page: page, responses: responses)
        width = CGFloat(settings.width)
    }

    // MARK: - 启动

    /// 读启动请求；网络组装之前调用（会员身份在这里写入本机假会话，与 `-CouliFakeTradeLoggedIn` 同一做法）。
    static func bootstrap(arguments: [String] = ProcessInfo.processInfo.arguments,
                          environment: [String: String] = ProcessInfo.processInfo.environment) {
        _ = marker
        guard shared == nil, let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
              arguments[index + 1] == "1", let raw = environment[environmentKey],
              let data = Data(base64Encoded: raw),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let settingsObject = root["settings"],
              let settingsData = try? JSONSerialization.data(withJSONObject: settingsObject),
              let settings = try? JSONDecoder().decode(Settings.self, from: settingsData),
              var fixture = root["fixture"] as? [String: Any]
        else { return }
        let items = fixture.removeValue(forKey: "sectionItems") as? [String: Any] ?? [:]
        if settings.scene == "banner_notice" {
            // 既有 golden 区块放进测试页（版本不变）：轮播在金刚区下、公告在最前
            var sections = fixture["sections"] as? [[String: Any]] ?? []
            let notice = (root["notice"] as? [String: Any])?["sections"] as? [[String: Any]] ?? []
            let banner = (root["banner"] as? [String: Any])?["sections"] as? [[String: Any]] ?? []
            sections.insert(contentsOf: banner, at: min(1, sections.count))
            sections.insert(contentsOf: notice, at: 0)
            fixture["sections"] = sections
        }
        guard let page = try? JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]) else { return }
        let responses = items.compactMapValues { try? JSONSerialization.data(withJSONObject: $0) }
        let visual = DebugHomeVisual(settings: settings, page: page, responses: responses)
        shared = visual
        DebugHomeVisualNetworkGuard.install()
        if settings.level == "member" {
            let tokens = SecureSessionTokens.production()
            try? tokens.save(access: "debug-at-visual", refresh: "debug-rt-visual", scope: "full",
                             account: "debug-visual-member", loginEpoch: SessionLoginEpoch.make())
        }
        visual.applyTraits()
    }

    /// 首页端口（首页读本机数据之前先按 `-CouliHomeTestReset` 清空）。
    func makePort() -> HomeContractPort? {
        DebugHomeUITestSupport.resetIfRequested()
        return settings.scene == "bundled" ? nil : port
    }

    /// 包内默认：「最后防线」场景下不可解（无 LKG、网络失败、包内默认也坏）。
    var bundled: @MainActor @Sendable () -> Data? {
        if settings.scene == "invalid" {
            return { nil }
        }
        return { HomeBundled.data() }
    }

    /// 已登录的假账号按短信登录账号处理（守卫按已绑手机，与 `-CouliFakeTradeLoggedIn` 同一出口）。
    func seed(_ login: AppLogin) {
        self.login = login
        if settings.level == "member" {
            login.phone.record(true, generation: login.client.sessionGeneration)
        }
    }

    /// 布局测量接收方（生产组件经环境值上报原始几何）。
    lazy var probe = CouliLayoutProbe(
        report: { [weak self] record in self?.store(record) },
        remove: { [weak self] id in self?.drop(id) }
    )

    /// 首页与剪贴板就绪：LKG 场景按同一身份预写真实 HomeLkgStore；登记信号；开始轮询读数。
    func attach(home: AppHome, clipboard: AppClipboard) {
        self.home = home
        self.clipboard = clipboard
        if settings.scene == "lkg", let scope = home.controller.identity.lkgScope {
            home.storage.lkg.write(scope, lkgPage, ticket: home.storage.lkg.ticket())
        }
        listen()
        poller = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated { DebugHomeVisual.shared?.poll() }
        }
    }

    /// 字号与深浅色同时作用于 UIKit 特征与 SwiftUI 环境（系统粘贴控件、UIFontMetrics 与 SwiftUI 都按同一档）。
    private func applyTraits() {
        guard #available(iOS 17.0, *) else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.traitOverrides.preferredContentSizeCategory = contentSizeCategory
            scene.traitOverrides.userInterfaceStyle = settings.dark ? .dark : .light
        }
    }

    func sceneAppeared() {
        applyTraits()
        applyWindowFrame()
    }

    /// 真实布局约束：把 App 的窗口设成请求的宽高（左上角对齐屏幕；宽于屏幕时超出右侧）。同一个 RootView 实例随之重新布局。
    func applyWindowFrame() {
        let frame = CGRect(x: 0, y: 0, width: width, height: CGFloat(settings.height))
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if let window = scene.keyWindow ?? scene.windows.first, window.frame != frame {
                window.frame = frame
            }
        }
    }

    var contentSizeCategory: UIContentSizeCategory {
        UIContentSizeCategory(rawValue: "UICTContentSizeCategory" + Self.categorySuffix(settings.category))
    }

    var dynamicTypeSize: DynamicTypeSize {
        DynamicTypeSize(contentSizeCategory) ?? .large
    }

    private static func categorySuffix(_ name: String) -> String {
        [
            "extraSmall": "XS", "small": "S", "medium": "M", "extraLarge": "XL", "extraExtraLarge": "XXL",
            "extraExtraExtraLarge": "XXXL", "accessibilityMedium": "AccessibilityM",
            "accessibilityLarge": "AccessibilityL", "accessibilityExtraLarge": "AccessibilityXL",
            "accessibilityExtraExtraLarge": "AccessibilityXXL",
            "accessibilityExtraExtraExtraLarge": "AccessibilityXXXL",
        ][name] ?? "L"
    }
}

#endif
