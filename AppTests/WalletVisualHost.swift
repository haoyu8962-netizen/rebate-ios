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

/// 真实 App 组装的钱包页（APP-09v-a）：WalletAppFixture（已登录 user-a，AppNetwork + AppRouting + AppLogin + AppWallet，传输层换成
/// WalletStubProtocol）→ Router 打开 Wallet → 生产的 `WalletRouteView`（AppWallet.entry → WalletScreen）。测试只换网络、测量接收方与画布，
/// 不重画页面。显示时钟靠摘要响应头 Date 走生产校准（`ApiClient.calibratedNowMillis`），固定到 visualWallet.clock。
/// 安全区按画板固定 顶 54 / 底 34（与商品详情、订单视觉同口径）。
@MainActor
final class WalletVisualHost {
    struct Canvas {
        var width: CGFloat = 390
        var height: CGFloat = 844
        var dark = false
        var size: DynamicTypeSize = .large
        var top: CGFloat = 54
        var bottom: CGFloat = 34
    }

    let fixture: WalletAppFixture
    let script: WalletScript
    let probes = ProductVisualProbes()
    private(set) var window: UIWindow?
    private(set) var canvas = Canvas()
    private(set) var destination: RouteDestination?
    /// 收益看板入口画板专用（见 `WalletVisualEarningsEnv`）：包一层的环境与由它建的生产执行器 / 页面外壳。
    private(set) var earningsEnv: WalletVisualEarningsEnv?
    private(set) var earningsController: WalletController?
    private var earningsDeps: WalletDeps?
    private var earningsContext: WalletPageContext?
    private var hidden: [UIWindow] = []

    init(suiteName: String, defaults: UserDefaults, script: WalletScript) {
        self.script = script
        fixture = WalletAppFixture.make(suiteName: suiteName, defaults: defaults)
    }

    var wallet: AppWallet {
        fixture.wallet
    }

    /// 本页的生产执行器（路由页面或收益入口页面）。
    var controller: WalletController? {
        if let earningsController {
            return earningsController
        }
        guard let destination else { return nil }
        return wallet.pages[destination.id]?.controller as? WalletController
    }

    /// 金额隐藏开关（设备级偏好，本组合自己的偏好套件，与订单页同一份）。
    func setHidden(_ value: Bool) {
        wallet.mask.set(value)
    }

    /// 经真实 Router 打开 Wallet 并挂窗口。
    func showWallet(_ canvas: Canvas = Canvas()) async throws {
        if destination == nil {
            fixture.router.open(RouteRequest(route: WalletRoutes.wallet, from: .inApp))
            destination = try XCTUnwrap(fixture.router.path.last, "Router 没有推入 Wallet")
        }
        await mount(canvas)
    }

    /// 收益看板入口（WalletEarningsEntry）：生产 WalletController + WalletScreen，环境只改收益开关两项。
    func showWalletWithEarnings(_ canvas: Canvas = Canvas()) async {
        if earningsController == nil {
            let env = WalletVisualEarningsEnv(base: wallet)
            let deps = WalletDeps(api: wallet.api, env: env, gates: wallet.gates, cache: wallet.cache,
                                  mask: wallet.mask, realname: nil, labor: nil)
            earningsEnv = env
            earningsDeps = deps
            earningsController = WalletController(deps: deps)
            earningsContext = WalletPageContext(texts: deps.texts, readGate: wallet.gates.read)
        }
        await mount(canvas)
    }

    /// 换画布重挂当前页面（执行器一个导航实例一份，重挂不重建）。
    func remount(_ canvas: Canvas) async {
        await mount(canvas)
    }

    private func mount(_ canvas: Canvas) async {
        close()
        self.canvas = canvas
        let content = if let earningsController, let earningsContext {
            AnyView(WalletScreen(controller: earningsController, mask: wallet.mask, context: earningsContext))
        } else if let destination {
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
        // 挂在 App 宿主的窗口场景上（不挂场景的独立 UIWindow 里 SwiftUI 不提交新一帧，APP-06v 宿主问题 1）
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

    /// 等页面稳定：连续两帧取样指纹相同、且测量记录逐条相同（APP-06v-b 测试 v2「两帧一致」）；`ready` 是就绪条件（某测量已上报、
    /// 执行器到了某阶段）。最多等 `seconds` 秒，没稳定判失败并附最后一帧与已上报测量。
    func stable(seconds: Int = 10, file: StaticString = #filePath, line: UInt = #line,
                until ready: (WalletVisualHost) -> Bool) async -> UIImage? {
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
            if ok, print == previous, records == previousRecords {
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
        XCTFail("页面没有稳定或没就绪（执行器 \(phase)；已请求 \(WalletStubProtocol.requests.map { "\($0.method) \($0.path)" })；"
            + "已上报测量 \(reported.count) 个\(reported.isEmpty ? "——§2 测量桥未接" : "：\(reported.prefix(16))")）",
            file: file, line: line)
        return last
    }

    /// 断网 + 缓存（WalletStale）：先按 09:30 的 Date 取一次成功（生产写缓存路径），再改成断网、关掉页面重开（新导航实例）；
    /// 生产按传输层失败读缓存，显示「今天 09:30」的提示条，【提现】置灰。显示时钟随后用一次带 10:32 Date 的普通读请求校准回来。
    func prepareStale(summary name: String, _ canvas: Canvas = Canvas(), file: StaticString = #filePath,
                      line: UInt = #line) async throws {
        try WalletVisualScript.summary(script, name, at: WalletVisualData.cachedAtMillis())
        try await showWallet(canvas)
        _ = await stable(file: file, line: line) { $0.controller?.state.phase == .content }
        close()
        if let destination {
            fixture.router.close(destination)
        }
        destination = nil
        // 显示时钟回到 10:32（任何带 Date 的响应都会校准；这里用一次不涉及钱包的配置读取）
        let now = try WalletVisualData.nowMillis()
        script.on(
            "GET /v1/me",
            .envelope(code: 0, data: WalletSamples.me, headers: ["Date": WalletVisualData.httpDate(now)])
        )
        _ = await fixture.network.client.send(ApiCall(operationId: "getMe"))
        WalletVisualScript.offline(script)
        try await showWallet(canvas)
    }
}
