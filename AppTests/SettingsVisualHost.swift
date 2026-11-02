@testable import Couli
import DesignSystem
import Me
import MeCore
import SwiftUI
import UIKit
import XCTest

/// 真实 App 组装的设置页（APP-12w）：MeAppFixture → 经真实 Router 打开 Settings → 生产的 `SettingsScreen`，外面套生产同样的 `NavigationStack`。
/// 公开版（注入 DeleteAccount，G-S05）、Release 无开关（G-S13）、挂住保存走 `useCustomPage`：同一个生产页面 + 生产执行器，环境 / 后端包一层。
/// 半屏、确认框是 DS 的页内覆盖层（`ModalOverlayModifier`），不是系统 `.sheet`：`dynamicTypeSize` 环境进得去，也没有 iOS 26 半屏 374/390 缩放，
/// 进程内直接测；系统 `.sheet` 的那两条坑在本组不涉及（交回 §0）。安全区 顶 54 / 底 34；时钟固定到 visualSettings.clock。
@MainActor
final class SettingsVisualHost {
    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 1100
        var dark = false
        var size: DynamicTypeSize = .large
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    struct CustomPage {
        let env: MeVisualEnv
        let deps: MeDeps
        let host: MePageHost<SettingsController>
    }

    let fixture: MeAppFixture
    let script: WalletScript
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private(set) var custom: CustomPage?
    private var entry: MePageEntry?
    private var hidden: [UIWindow] = []

    init(fixture: MeAppFixture, script: WalletScript) {
        self.fixture = fixture
        self.script = script
    }

    /// 此刻页面的生产执行器（身份变了 App 换新的，每次现取）。
    var controller: SettingsController? {
        custom?.host.controller ?? entry?.controller() as? SettingsController
    }

    func useRoute() {
        entry = fixture.open("Settings")
    }

    func useCustomPage(routes: Set<String>?, nickname: NicknameBackend?, notify: NotifyBackend?,
                       overrides: [String: String] = [:]) {
        let me = fixture.me
        let env = MeVisualEnv(base: me, routes: routes, earnings: nil)
        let texts = overrides.isEmpty ? me.deps.texts : MeVisualTexts(base: me.deps.texts, overrides: overrides)
        let deps = MeDeps(api: me.deps.api, env: env, gates: me.gates, texts: texts, local: me.local,
                          mask: me.mask, nickname: nickname, notify: notify)
        let host = MePageHost(SettingsController(deps: deps, identity: env.identity(), page: nil))
        host.onAppear = { [weak host] in host?.controller.refresh() }
        custom = CustomPage(env: env, deps: deps, host: host)
    }

    func mount(_ canvas: Canvas) {
        let screen = if let custom {
            AnyView(SettingsScreen(host: custom.host))
        } else {
            entry?.screen() ?? AnyView(EmptyView())
        }
        mountScreen(screen, canvas: canvas)
    }

    /// 挂任意页面（共用件回归：隐私中心、关于）。
    func mountScreen(_ screen: AnyView, canvas: Canvas) {
        close()
        self.canvas = canvas
        let root = NavigationStack { screen }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: canvas.top) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: canvas.bottom) }
            .environment(\.couliLayoutProbe, probes.probe)
            .environment(\.colorScheme, canvas.dark ? .dark : .light)
            .environment(\.dynamicTypeSize, canvas.size)
        let host = UIHostingController(rootView: root)
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        frame.frame = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        frame.overrideUserInterfaceStyle = canvas.dark ? .dark : .light
        frame.rootViewController = host
        frame.windowLevel = .alert + 1
        hidden = (scene?.windows ?? []).filter { $0 !== frame && !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        frame.makeKeyAndVisible()
        host.view.frame = frame.bounds
        host.view.layoutIfNeeded()
        window = frame
    }

    func close() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
    }

    func render() -> UIImage? {
        window.map(ProductVisualRender.image)
    }

    /// 系统导航栏下沿（内容上边距从这里算：导航栏高度归系统，不进判据）。
    var navigationBottom: CGFloat? {
        guard let window, let bar = Self.first(UINavigationBar.self, in: window) else { return nil }
        return bar.convert(bar.bounds, to: window).maxY
    }

    private static func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
        if let found = view as? View {
            return found
        }
        for child in view.subviews {
            if let found = first(type, in: child) {
                return found
            }
        }
        return nil
    }

    /// F-IOS-63：测量桥一帧两变会丢后一次。页面内容靠滚动区挪 1pt 重报；覆盖层（半屏、确认框）不在滚动区里，靠窗口高度变 1pt 再还原重报。不改任何判据。
    private func refreshProbes() async {
        guard let window else { return }
        let bounds = window.frame
        var grown = bounds
        grown.size.height += 2
        window.frame = grown
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        window.frame = bounds
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        guard let scroller = Self.first(UIScrollView.self, in: window) else { return }
        let origin = scroller.contentOffset
        for offset in [CGPoint(x: origin.x, y: origin.y + 1), origin] {
            scroller.setContentOffset(offset, animated: false)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 等页面稳定：连续两帧取样指纹相同、测量记录逐条相同；稳定后让测量重报一次再取最后一帧。
    func stable(seconds: Int = 8, file: StaticString = #filePath, line: UInt = #line,
                until ready: (SettingsVisualHost) -> Bool) async -> UIImage? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        var last: UIImage?
        var previous: [ProductVisualPixels.RGB]?
        var previousRecords: [String: CouliLayoutProbeRecord]?
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            if window?.isKeyWindow == false {
                window?.makeKeyAndVisible()
            }
            window?.rootViewController?.view.setNeedsLayout()
            window?.layoutIfNeeded()
            await Task.yield()
            guard let image = render() else { continue }
            last = image
            let done = ready(self)
            let print = ProductVisualPixels(image).fingerprint()
            let records = probes.records
            if done, print == previous, records == previousRecords {
                await refreshProbes()
                return render() ?? image
            }
            previous = done ? print : nil
            previousRecords = done ? records : nil
        }
        if let last {
            XCTContext.runActivity(named: "最后一帧") { $0.add(XCTAttachment(image: last)) }
        }
        let reported = probes.records.keys.sorted()
        XCTFail(
            "设置页没有稳定或没就绪（已请求 \(WalletStubProtocol.requests.map { "\($0.method) \($0.path)" })；"
                + "已上报测量 \(reported.count) 个\(reported.isEmpty ? "——测量桥未接（交回 §4）" : "：\(reported.prefix(16))")）",
            file: file, line: line
        )
        return last
    }
}
