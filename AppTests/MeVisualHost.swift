@testable import Couli
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import UIKit
import XCTest

/// 真实 App 组装的「我的」Tab 根（APP-12v）：MeAppFixture（AppNetwork + AppRouting + AppLogin + AppConfig + AppMe，传输层换
/// WalletStubProtocol，
/// 系统能力换 FakeMeSystem）→ Router 切到 Me → 生产的 `MeTabRouteView` → `MeTabScreen`。测试只换网络、测量接收方与画布，不重画页面。
/// 公开版宫格、文案替换走 `useCustomPage`：同一个生产 `MeTabScreen` + 生产执行器，环境与文案包一层（见 `MeVisualEnv`）。
/// 安全区按画板固定 顶 54 / 底 34（与钱包视觉同口径）；时钟固定到 visualMe.clock。
@MainActor
final class MeVisualHost {
    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 1032
        var dark = false
        var size: DynamicTypeSize = .large
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    struct CustomPage {
        let env: MeVisualEnv
        let deps: MeDeps
        let host: MePageHost<MeTabController>
        let scroll: MeScrollMemory
        let texts: MeVisualTexts?
    }

    let fixture: MeAppFixture
    let script: WalletScript
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private(set) var custom: CustomPage?
    private var hidden: [UIWindow] = []

    init(fixture: MeAppFixture, script: WalletScript) {
        self.fixture = fixture
        self.script = script
    }

    /// 此刻页面的生产执行器。
    var controller: MeTabController {
        custom?.host.controller ?? fixture.me.tabHost.controller
    }

    var repo: MeRepository {
        controller.deps.repo
    }

    /// 页面同一份渲染时回调（`MeTabActions.make`，生产 MeTabBody 同一个构造）。
    var actions: MeTabActions {
        MeTabActions.make(controller, repo.state)
    }

    var texts: MeTexts {
        controller.deps.texts
    }

    func useCustomPage(routes: Set<String>?, earnings: Bool?, overrides: [String: String]) {
        let me = fixture.me
        let env = MeVisualEnv(base: me, routes: routes, earnings: earnings)
        let texts = overrides.isEmpty ? nil : MeVisualTexts(base: me.deps.texts, overrides: overrides)
        let deps = MeDeps(api: me.deps.api, env: env, gates: me.gates, texts: texts ?? me.deps.texts, local: me.local,
                          mask: me.mask, nickname: nil, notify: nil)
        let host = MePageHost(MeTabController(deps: deps, identity: env.identity()))
        host.onAppear = { [weak host] in
            host?.controller.refresh()
            host?.controller.checkGuideBar()
        }
        custom = CustomPage(env: env, deps: deps, host: host, scroll: MeScrollMemory(), texts: texts)
    }

    /// 经真实 Router 切到 Me 并挂窗口（包一层的页面不切 Tab：否则 AppMe 自己的 Tab 根也会取一次 Me）。
    func show(_ canvas: Canvas = Canvas()) async {
        if custom == nil {
            _ = fixture.routing.selectTab(.me)
        }
        mount(canvas)
    }

    /// 换画布重挂（视图重建）。
    func remount(_ canvas: Canvas) {
        mount(canvas)
    }

    private func mount(_ canvas: Canvas) {
        close()
        self.canvas = canvas
        let content = if let custom {
            AnyView(MeTabScreen(host: custom.host, mask: fixture.me.mask, scroll: custom.scroll))
        } else {
            AnyView(MeTabRouteView(destination: fixture.router.tabRoot).environmentObject(fixture.me))
        }
        let root = content
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

    /// 页面的滚动视图（生产 ScrollView 的 UIKit 底座）。
    var scroller: UIScrollView? {
        window.flatMap(Self.scrollView(in:))
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView {
            return scroll
        }
        for child in view.subviews {
            if let found = scrollView(in: child) {
                return found
            }
        }
        return nil
    }

    /// F-IOS-63：测量桥 onChange(of: CGRect) 一帧两变会丢后一次，之后框不再变就不重报。分两帧把滚动区挪 1pt 再挪回，让测量按实际框重报一次；
    /// 不改任何判据。
    func refreshProbes() async {
        guard let window, let scroller else { return }
        let origin = scroller.contentOffset
        for offset in [CGPoint(x: origin.x, y: origin.y + 1), origin] {
            scroller.setContentOffset(offset, animated: false)
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 等页面稳定：连续两帧取样指纹相同、且测量记录逐条相同；`ready` 是就绪条件。稳定后让测量重报一次（F-IOS-63）再取最后一帧。
    /// 最多等 `seconds` 秒，没稳定判失败并附最后一帧与已上报测量。
    func stable(seconds: Int = 8, file: StaticString = #filePath, line: UInt = #line,
                until ready: (MeVisualHost) -> Bool) async -> UIImage? {
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
            "页面没有稳定或没就绪（快照 \(repo.state.phase)；已请求 \(WalletStubProtocol.requests.map { "\($0.method) \($0.path)" })；"
                + "已上报测量 \(reported.count) 个\(reported.isEmpty ? "——测量桥未接（交回 §4）" : "：\(reported.prefix(16))")）",
            file: file,
            line: line
        )
        return last
    }
}
