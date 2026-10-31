@testable import Couli
import CouliNetwork
import Darwin
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// APP-09v-d 二次验证半屏用例的公共底座（四页共用件，资金相关）。到达方式只走生产链路：真实提现页 / 收款账号页 → 真实提交 → 假服务 10003 →
/// 生产代码开半屏并发码；测试只控制网络答复、时钟与画布，不伪造面板状态。
///
/// 四个 iOS 事实（2026-10-31 探针实测，iOS 26 模拟器）：
/// - `.sheet` 进程内真的画进宿主窗口，`drawHierarchy` 截得到；
/// - 面板是系统浮动样式（左右各留 8），所以版式一律**相对面板框**算，不写死屏幕 x = 16；
/// - 部分高度档（medium）系统把半屏整体缩放 `屏上宽 / 布局宽`（390 窗口 374 / 390，`UIDropShadowView` 变换），测量拿到的是屏上窗口坐标，large 档为 1。
///   **令牌（尺寸、间距、描边）除以 `sheetScale` 换回半屏逻辑点再比，容差不变**；**命中区是手指碰的尺寸，一律按屏上比 ≥ 44，不换算**；
/// - **`\.dynamicTypeSize` 环境值进不了 `.sheet`**（AX3 画布里半屏仍是默认字号，正是 APP-09v §9 第 8 条「200% 没真放大」），要放大必须改窗口特征
///   `traitOverrides`（`enlarge`），面板才是真 200%。
@MainActor
class StepUpVisualTestCase: WithdrawVisualTestCase {
    /// 冻结时钟：倒计时停在假服务给的秒数（画板 48 秒），两帧一致。
    static let frozenMillis: Int64 = 1_760_000_000_000

    static let need = WalletStubProtocol.Reply.envelope(code: 10003, data: "null", headers: [:])

    static func smsOk(_ seconds: Int64 = 48) -> WalletStubProtocol.Reply {
        .envelope(code: 0, data: "{\"resend_after_sec\":\(seconds),\"expires_in_sec\":300}", headers: [:])
    }

    static func stepOk(_ token: String = "fixture-verified-token") -> WalletStubProtocol.Reply {
        .envelope(
            code: 0, data: "{\"step_up_token\":\"\(token)\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}", headers: [:]
        )
    }

    static let wrongCode = WalletStubProtocol.Reply.envelope(code: 20002, data: "null", headers: [:])
    static let serverDown = WalletStubProtocol.Reply.envelope(code: 50001, data: "null", headers: [:])

    /// AX3（画板 AdaptLargeText 的 200% 档，与 c 组 `DynamicTypeSize.accessibility3` 同档）。
    static let ax3 = UIContentSizeCategory.accessibilityExtraLarge

    var stepUp: StepUpController? {
        page?.flow?.stepUp
    }

    // MARK: - 到达

    private func enlarge(_ host: WithdrawVisualHost, _ category: UIContentSizeCategory?) {
        guard let category, #available(iOS 17.0, *) else { return }
        host.window?.traitOverrides.preferredContentSizeCategory = category
    }

    /// 发码结果已落定：倒计时由 `countdown` 的任务下一拍才写，phase == .ready 而 resendLeftSec 还是 0 的那一拍不算（d3 实测判错过）。
    static func landed(_ state: StepUpUiState) -> Bool {
        state.phase == .noPhone || (state.phase == .ready && (state.resendLeftSec > 0 || state.error != nil))
    }

    /// 打开提现页并点【提交】→ 10003 → 面板就绪（不要求任何新测量：资金守卫不能把「测量桥未接」混进来）。
    @discardableResult
    func panelOnWithdraw(canvas: WithdrawVisualHost.Canvas = .init(), large: UIContentSizeCategory? = nil,
                         sms: WalletStubProtocol.Reply? = nil, phone: Bool = true, file: StaticString = #filePath,
                         line: UInt = #line) async throws -> WithdrawVisualHost {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated", canvas: canvas,
                                               needProbes: false, file: file, line: line)
        host.wallet.clock = { Self.frozenMillis }
        if !phone {
            host.wallet.phoneProvider = { _ in nil }
        }
        host.server.script.on("POST /v1/withdrawals", Self.need, .envelope(
            code: 0, data: WalletSamples.withdrawal("W-step"), headers: [:]
        ))
        host.server.script.on("POST /v1/auth/sms-codes", sms ?? Self.smsOk())
        enlarge(host, large)
        host.actions?.submit()
        await waitUntil("二次验证面板没有打开", timeout: 8, file: file, line: line) {
            guard let state = host.flow?.stepUp.state else { return false }
            return Self.landed(state)
        }
        return host
    }

    /// 打开收款账号页（未绑定）、填表单、点【保存】→ 10003 → 面板就绪。
    @discardableResult
    func panelOnPayout(canvas: WithdrawVisualHost.Canvas = .init(), file: StaticString = #filePath,
                       line: UInt = #line) async throws -> WithdrawVisualHost {
        let host = try await freshPage(payout: "empty")
        host.server.script.on("PUT /v1/me/payout-account", Self.need, .envelope(
            code: 0, data: WalletSamples.alipay, headers: [:]
        ))
        host.server.script.on("POST /v1/auth/sms-codes", Self.smsOk())
        try await host.show(WalletRoutes.payoutAccount, canvas)
        _ = await host.stable(file: file, line: line) { $0.payout.map { $0.state.phase != .loading } ?? false }
        host.wallet.clock = { Self.frozenMillis }
        let controller = try XCTUnwrap(host.payout, file: file, line: line)
        func actions() -> PayoutActions {
            PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
        }
        actions().logon("13800135678")
        actions().payee("测试三")
        actions().save()
        await waitUntil("收款账号页没有打开面板", timeout: 8, file: file, line: line) {
            controller.flow.stepUp.state.map(Self.landed) ?? false
        }
        return host
    }

    /// 面板就绪后等稳定（要求新测量：`stepUp.title` 已上报）。
    @discardableResult
    func settled(_ host: WithdrawVisualHost, waitFor: String = "stepUp.title", motion: Bool = false,
                 file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        let image = await host.stable(motion: motion, file: file, line: line) { $0.probes[waitFor] != nil }
        return try XCTUnwrap(image, "半屏没有稳定画面", file: file, line: line)
    }

    /// 提现页到面板 + 输入 `code` + 等稳定。
    @discardableResult
    func openSheet(code: String = "", canvas: WithdrawVisualHost.Canvas = .init(),
                   large: UIContentSizeCategory? = nil, sms: WalletStubProtocol.Reply? = nil,
                   waitFor: String = "stepUp.title", file: StaticString = #filePath,
                   line: UInt = #line) async throws -> (WithdrawVisualHost, UIImage) {
        let host = try await panelOnWithdraw(canvas: canvas, large: large, sms: sms, file: file, line: line)
        if !code.isEmpty {
            try enterCode(code, file: file, line: line)
        }
        return try await (host, settled(host, waitFor: waitFor, file: file, line: line))
    }

    /// 渲染时的面板回调（与 `StepUpSheetBody` 同一份 `StepUpActions.make`）。
    func panelActions(file: StaticString = #filePath, line: UInt = #line) throws -> StepUpActions {
        let controller = try XCTUnwrap(stepUp, file: file, line: line)
        let state = try XCTUnwrap(controller.state, "面板不在", file: file, line: line)
        return StepUpActions.make(controller, state)
    }

    func enterCode(_ code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try panelActions(file: file, line: line).code(code)
    }

    // MARK: - 面板框

    /// 系统半屏的实际框（窗口坐标）。
    func sheetFrame(file: StaticString = #filePath, line: UInt = #line) throws -> CGRect {
        let host = try XCTUnwrap(page?.window?.rootViewController, file: file, line: line)
        let view = try XCTUnwrap(host.presentedViewController?.view, "半屏没有弹出", file: file, line: line)
        return view.convert(view.bounds, to: nil)
    }

    /// 系统半屏的缩放（屏上框宽 ÷ 布局宽）；large 档为 1。
    func sheetScale(in window: UIWindow?) -> CGFloat {
        guard let view = window?.rootViewController?.presentedViewController?.view, view.bounds.width > 0 else {
            return 1
        }
        return view.convert(view.bounds, to: nil).width / view.bounds.width
    }

    var sheetScale: CGFloat {
        sheetScale(in: page?.window)
    }

    /// 屏上窗口坐标的长度 → 半屏逻辑点（只给令牌比较用，命中区不用它）。
    func logical(_ value: CGFloat) -> CGFloat {
        value / sheetScale
    }

    /// 半屏里的那个真实输入框。
    func sheetField(in window: UIWindow? = nil) -> UITextField? {
        let root = (window ?? page?.window)?.rootViewController?.presentedViewController?.view
        func find(_ view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap(find).first
        }
        return root.flatMap(find)
    }

    /// 系统此刻是否允许用手势收起 `presented`（下滑、点遮罩共用的闸门：`isModalInPresentation` 与展示控制器代理）。
    func gestureDismissAllowed(_ presented: UIViewController) -> Bool {
        let controller = presented.presentationController
        guard !presented.isModalInPresentation, let controller else { return false }
        return controller.delegate?.presentationControllerShouldDismiss?(controller) ?? true
    }

    /// SwiftUI 只在无障碍自动化打开时才构造无障碍树。进程内用例里没有 VoiceOver，这里按 AccessibilitySnapshot 的做法打开（只在测试进程，私有符号取不到就抛），
    /// 用例结束自动恢复。必须在页面挂上之前调用。
    func enableAccessibilityTree() throws {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let handle = try XCTUnwrap(dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW), "libAccessibility")
        typealias Getter = @convention(c) () -> Int32
        typealias Setter = @convention(c) (Int32) -> Void
        let getter = try XCTUnwrap(dlsym(handle, "_AXSAutomationEnabled"))
        let setter = try XCTUnwrap(dlsym(handle, "_AXSSetAutomationEnabled"))
        let set = unsafeBitCast(setter, to: Setter.self)
        let old = unsafeBitCast(getter, to: Getter.self)()
        set(1)
        addTeardownBlock { set(old) }
    }

    /// 系统回车：SwiftUI `.onSubmit` 走文本框代理的 shouldReturn / editingDidEndOnExit 两路，都发。
    func pressReturn(_ field: UITextField) {
        _ = field.delegate?.textFieldShouldReturn?(field)
        field.sendActions(for: .editingDidEndOnExit)
    }

    /// 模拟 VoiceOver 擦除：从 `start` 沿无障碍容器逐级调 `accessibilityPerformEscape`，有人接住返回 true。
    func performEscape(from start: NSObject) -> Bool {
        var current: NSObject? = start
        while let item = current {
            if item.accessibilityPerformEscape() {
                return true
            }
            let container = NSSelectorFromString("accessibilityContainer")
            let answer = item.responds(to: container) ? item.perform(container) : nil
            let parent = answer?.takeUnretainedValue() as? NSObject
            current = parent ?? (item as? UIView)?.superview
        }
        return false
    }

    /// 在无障碍树里按标识找元素（SwiftUI 的元素不是 UIView，要走 accessibilityElements）。
    func accessibilityNode(_ identifier: String, under root: NSObject) -> NSObject? {
        let key = NSSelectorFromString("accessibilityIdentifier")
        if root.responds(to: key), root.value(forKey: "accessibilityIdentifier") as? String == identifier {
            return root
        }
        var children = (root.accessibilityElements as? [NSObject]) ?? []
        if children.isEmpty, root.accessibilityElementCount() != NSNotFound {
            let count = max(root.accessibilityElementCount(), 0)
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        children += (root as? UIView)?.subviews ?? []
        return children.lazy.compactMap { self.accessibilityNode(identifier, under: $0) }.first
    }

    var presentedCategory: UIContentSizeCategory? {
        page?.window?.rootViewController?.presentedViewController?.traitCollection.preferredContentSizeCategory
    }

    // MARK: - 请求计数

    var smsSends: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/sms-codes")
    }

    var verifies: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("POST", "/v1/auth/step-up")
    }

    var saves: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests("PUT", "/v1/me/payout-account")
    }

    // MARK: - 像素

    /// 描边宽（点）：从格子左缘外 1.5pt 沿中线向内，数与面板底色不同的连续像素。
    func strokeWidth(_ image: UIImage, cell: CGRect, surface: ProductVisualPixels.RGB) -> CGFloat {
        let pixels = ProductVisualPixels(image)
        let scale = pixels.scale
        let row = Int(cell.midY * scale)
        var column = Int((cell.minX - 1.5) * scale)
        let end = Int(cell.midX * scale)
        var ink = 0
        while column < end {
            if pixels.color(px: column, row).near(surface, tolerance: 24) {
                if ink > 0 {
                    break
                }
            } else {
                ink += 1
            }
            column += 1
        }
        return CGFloat(ink) / scale
    }
}

/// 换手机号、注销在 iOS 还**没有页面**（G-W 见交回 §0）：`bindPhone` 走登录组件不接本半屏，`DeleteAccount` since.ios=null、`requestDeletion` planned。
/// 这里用生产 `StepUpController` + 生产 `walletStepUpSheet` 挂一个空底页，action 取契约的 `phone_change` / `account_deletion`，
/// 回归「同一个件换 action 后版式与资金判据不变」。不是真点，真点等页面落地（`testConsumersAreKnown` 届时变红提醒）。
@MainActor
final class StepUpAloneHost {
    let controller: StepUpController
    let window: UIWindow
    private(set) var tokens: [String] = []
    private(set) var closed = 0

    init(deps: WalletDeps, owner: WalletOwner, action: String, probes: ProductVisualProbes,
         canvas: WithdrawVisualHost.Canvas = .init()) {
        let controller = StepUpController(deps: deps, alive: { true })
        self.controller = controller
        let root = Color.clear
            .walletStepUpSheet(controller, texts: WalletDraftTexts(), smsBlocked: false, verifyBlocked: false)
            .environment(\.couliLayoutProbe, probes.probe)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        window.overrideUserInterfaceStyle = canvas.dark ? .dark : .light
        window.backgroundColor = UIColor(CouliColor.backgroundCanvas)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        controller.open(action: action, owner: owner, onToken: { [weak self] in self?.tokens.append($0) },
                        onClosed: { [weak self] in self?.closed += 1 })
    }

    var actions: StepUpActions? {
        controller.state.map { StepUpActions.make(controller, $0) }
    }

    func render() -> UIImage {
        ProductVisualRender.image(window)
    }

    func close() {
        controller.state.flatMap { state in Optional(StepUpActions.make(controller, state).close()) }
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
