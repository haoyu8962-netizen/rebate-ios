@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 真实 App 组装的提现页 / 收款账号页（APP-09v-c）：WalletAppFixture（已登录 user-a，AppNetwork + AppRouting + AppLogin + AppWallet，传输层换成
/// WalletStubProtocol）→ 真实 Router 打开路由 → 生产的 `WalletRouteView`（AppWallet.entry → WithdrawScreen + WithdrawController +
/// SensitiveFlow）。
/// 测试只换网络、测量接收方与画布，不重画页面。安全区按画板固定 顶 54 / 底 34。
/// 进程内点不到 SwiftUI 按钮：操作走与页面**同一份**渲染时回调（`WithdrawActions.make` / `FlowActions.make`）；真实点击计数在 UITests。
@MainActor
final class WithdrawVisualHost {
    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 844
        var dark = false
        var size: DynamicTypeSize = .large
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    let fixture: WalletAppFixture
    let server: WithdrawVisualServer
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private(set) var destination: RouteDestination?
    private var hidden: [UIWindow] = []

    init(suiteName: String, defaults: UserDefaults, server: WithdrawVisualServer, pending: MemoryPendingKeyBackend) {
        self.server = server
        fixture = WalletAppFixture.make(suiteName: suiteName, defaults: defaults, pending: pending)
    }

    var wallet: AppWallet {
        fixture.wallet
    }

    var controller: WithdrawController? {
        destination.flatMap { wallet.pages[$0.id]?.controller as? WithdrawController }
    }

    var payout: PayoutAccountController? {
        destination.flatMap { wallet.pages[$0.id]?.controller as? PayoutAccountController }
    }

    var flow: SensitiveFlow? {
        controller?.flow ?? payout?.flow
    }

    /// 配置走生产路径：假服务回 `GET /v1/config`，`AppConfig` 拉到后 `AppWallet.helpLinks / configText` 才有值。
    func configure(help: Bool, sla: String?) async throws {
        try server.script.ok("GET /v1/config", WithdrawVisualData.config(help: help, sla: sla))
        fixture.wallet.config.startIfSettled(.settled)
        await waitUntil("配置没有拉到") { self.fixture.wallet.helpLinks() != nil }
        if help {
            await waitUntil("help_links.withdraw_rules 没有生效") {
                self.fixture.wallet.helpLinks()?["withdraw_rules"] != nil
            }
        }
    }

    /// 经真实 Router 打开路由并挂窗口（资金页守卫要先查过实名）。
    func show(_ route: String = WalletRoutes.withdraw, _ canvas: Canvas = Canvas()) async throws {
        wallet.realnameChanged()
        await waitUntil("实名状态没取到") { self.wallet.realnameVerified() }
        fixture.router.open(RouteRequest(route: route, from: .inApp))
        destination = try XCTUnwrap(fixture.router.path.last, "Router 没有推入 \(route)")
        XCTAssertEqual(destination?.route, route, "资金页守卫没有放行")
        mount(canvas)
    }

    /// 换画布重挂当前页面（执行器一个导航实例一份，重挂不重建）。
    func remount(_ canvas: Canvas) {
        mount(canvas)
    }

    private func mount(_ canvas: Canvas) {
        close()
        self.canvas = canvas
        let content = if let destination {
            AnyView(WalletRouteView(destination: destination).environmentObject(wallet))
        } else {
            AnyView(EmptyView())
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

    /// 等页面稳定：连续两帧像素指纹相同、测量记录逐条相同，且就绪条件成立；没稳定判失败并附最后一帧、执行器阶段、已发请求与已上报测量。
    /// `motion` = 画面里有转圈（提交中、计算中、忙碌、加载中）：转圈帧帧不同，只比测量记录，不比像素。
    func stable(seconds: Int = 10, motion: Bool = false, file: StaticString = #filePath, line: UInt = #line,
                until ready: (WithdrawVisualHost) -> Bool) async -> UIImage? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        var last: UIImage?
        var previous: [ProductVisualPixels.RGB]?
        var previousRecords: [String: CouliLayoutProbeRecord]?
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            if window?.isKeyWindow == false {
                window?.makeKeyAndVisible()
            }
            window?.rootViewController?.view.setNeedsLayout()
            window?.layoutIfNeeded()
            await Task.yield()
            guard let image = render() else { continue }
            last = image
            let ok = ready(self)
            let print = ProductVisualPixels(image).fingerprint()
            let records = probes.records
            if ok, motion || print == previous, records == previousRecords {
                return image
            }
            previous = ok ? print : nil
            previousRecords = ok ? records : nil
        }
        if let last {
            XCTContext.runActivity(named: "最后一帧") { $0.add(XCTAttachment(image: last)) }
        }
        let reported = probes.records.keys.sorted()
        let phase = controller.map { "\($0.state.phase)" } ?? "无执行器"
        XCTFail(
            "页面没有稳定或没就绪（执行器 \(phase)；已请求 \(WalletStubProtocol.requests.map { "\($0.method) \($0.path)" })；"
                + "已上报测量 \(reported.count) 个\(reported.isEmpty ? "——§4 测量桥未接" : "：\(reported.prefix(24))")）",
            file: file,
            line: line
        )
        return last
    }

    // MARK: - 操作（与页面同一份渲染时回调）

    var actions: WithdrawActions? {
        controller.map { WithdrawActions.make($0, $0.state, risk: $0.flow.state.riskDialog?.id) }
    }

    var flowActions: FlowActions? {
        flow.map { FlowActions.make($0, $0.state) }
    }

    // MARK: - 滚动

    /// 内容滚动视图：竖向、面积最大的那个。
    var scroller: UIScrollView? {
        guard let window else { return nil }
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.window != nil,
               scroll.bounds.height > 100 {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    var viewport: CGRect? {
        scroller.map { $0.convert($0.bounds, to: nil) }
    }
}
