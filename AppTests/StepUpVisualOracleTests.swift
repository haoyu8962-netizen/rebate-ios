@testable import Couli
import CouliNetwork
import DesignSystem
import Generated
import SwiftUI
import UIKit
import Wallet
@testable import WalletCore
import XCTest

/// 判据自证（底版应绿）：宿主、面板框、真 200%、测量穿过 `.sheet`、描边量具本身可信；否则版式用例的红 / 绿都不算数。
@MainActor
final class StepUpVisualOracleTests: StepUpVisualTestCase {
    /// 生产链路到面板：提交一次（10003）、发码一次、不验证。
    func testProductionPathOpensPanel() async throws {
        try await panelOnWithdraw()
        XCTAssertEqual(submits.count, 1)
        XCTAssertEqual(smsSends.count, 1)
        XCTAssertEqual(smsSends.first?.json["purpose"] as? String, "step_up")
        XCTAssertEqual(smsSends.first?.json["action"] as? String, "withdraw")
        XCTAssertEqual(verifies.count, 0)
        XCTAssertEqual(stepUp?.state?.resendLeftSec, 48, "冻结时钟：倒计时停在 48")
    }

    /// 半屏真的弹出且在窗口内；进程内截图能看到半屏（面板区是面板底色，不是页面）。
    func testSheetIsRealAndDrawn() async throws {
        let host = try await panelOnWithdraw()
        await quietWindow(1.2)
        let frame = try sheetFrame()
        XCTAssertGreaterThan(frame.height, 200)
        assertInside(frame, try XCTUnwrap(host.window).bounds, "半屏在窗口内")
        let image = try XCTUnwrap(host.render())
        let surface = pixel(CouliColor.backgroundSurface, dark: false)
        XCTAssertGreaterThan(share(image, in: frame.insetBy(dx: 30, dy: 30), near: surface, tolerance: 6), 0.5, "看得到半屏")
    }

    /// 环境值 dynamicTypeSize 进不了 `.sheet`（基线事实）；窗口特征才能真放大——本组 200% 用例都走后者。
    func testTraitOverrideReallyEnlargesSheet() async throws {
        try await panelOnWithdraw(canvas: .init(size: .accessibility3))
        await quietWindow(0.8)
        XCTAssertEqual(presentedCategory, .large, "只改环境值时半屏字号不变（若此处变绿以外的值，改 §6 说明）")
        try await panelOnWithdraw(canvas: .init(size: .accessibility3), large: Self.ax3)
        await quietWindow(0.8)
        XCTAssertEqual(presentedCategory, Self.ax3, "窗口特征放大后半屏真 200%")
    }

    /// 测量接收方穿过 `.sheet`，且上报的是窗口坐标（否则 `stepUp.*` 永远缺测量 / 位置全错）。
    func testProbeCrossesSheetInWindowCoordinates() async throws {
        let probes = ProductVisualProbes()
        let root = Color.clear
            .sheet(isPresented: .constant(true)) {
                Color.red.frame(width: 100, height: 40).couliProbe("oracle.sheet", role: "oracle")
            }
            .environment(\.couliLayoutProbe, probes.probe)
        let host = UIHostingController(rootView: root)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
        }
        await waitUntil("测量没有穿过 .sheet") { probes["oracle.sheet"] != nil }
        await quietWindow(0.8)
        let view = try XCTUnwrap(host.presentedViewController?.view)
        assertInside(try probes.rect("oracle.sheet"), view.convert(view.bounds, to: nil), "窗口坐标")
    }

    /// 描边量具：1 / 2 点描边都量得准。
    func testStrokeRuler() async {
        for width in [CGFloat(1), 2] {
            let image = await ProductVisualRender.standalone(
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black, lineWidth: width)
                    .frame(width: 50, height: 56).background(Color.white)
                    .frame(width: 100, height: 100).background(Color.white),
                size: CGSize(width: 100, height: 100)
            ).0
            let measured = strokeWidth(image, cell: CGRect(x: 25, y: 22, width: 50, height: 56),
                                       surface: .init(red: 255, green: 255, blue: 255))
            assertNear(measured, width, 0.4, "量具")
        }
    }

    /// 半屏缩放量具：medium 档屏上窄于布局（390 窗口 374 / 390），large 档为 1；屏上测量 ÷ 缩放 = 布局值。
    func testSheetScaleRuler() async throws {
        try await panelOnWithdraw()
        await quietWindow(1.2)
        assertNear(sheetScale, 374.0 / 390.0, 0.002, "medium 档系统缩放")
        assertNear(logical(374), 390, 0.5, "换算")
        try await panelOnWithdraw(large: Self.ax3)
        await quietWindow(1.2)
        assertNear(sheetScale, 1, 0.001, "large 档不缩放")
    }

    /// 手势收起判据能分辨 interactiveDismissDisabled 开 / 关（否则 `testGestureDismissLockedByUIKit` 证明不了什么）。
    func testGestureDismissJudge() async throws {
        for locked in [false, true] {
            let root = Color.clear.sheet(isPresented: .constant(true)) {
                Color.red.interactiveDismissDisabled(locked)
            }
            let (window, host) = try mount(root)
            defer { unmount(window, host) }
            await waitUntil("半屏没弹出") { host.presentedViewController != nil }
            await quietWindow(0.8)
            let presented = try XCTUnwrap(host.presentedViewController)
            XCTAssertEqual(gestureDismissAllowed(presented), !locked, "locked=\(locked)")
        }
    }

    /// 回车探针：对真实 UITextField 发系统回车，带 `.onSubmit` 的 SwiftUI 框确实触发（否则 `testReturnNeverVerifies` 证明不了什么）。
    func testReturnProbeFiresOnSubmit() async throws {
        let box = Counter()
        let (window, host) = try mount(TextField("", text: .constant("1")).onSubmit { box.value += 1 })
        defer { unmount(window, host) }
        func find(_ view: UIView) -> UITextField? {
            (view as? UITextField) ?? view.subviews.lazy.compactMap(find).first
        }
        await waitUntil("没有 UITextField") { find(host.view) != nil }
        let field = try XCTUnwrap(find(host.view))
        pressReturn(field)
        await waitUntil("回车探针没有触发 onSubmit", timeout: 2) { box.value >= 1 }
    }

    /// 擦除探针：沿无障碍容器发 escape，SwiftUI 的 `.accessibilityAction(.escape)` 确实接住（否则 `testEscapeClosesThroughExit` 证明不了什么）。
    func testEscapeProbeReachesSwiftUIAction() async throws {
        try enableAccessibilityTree()
        let box = Counter()
        let root = VStack { Text(verbatim: "内层").accessibilityIdentifier("oracle.inner") }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("oracle.root")
            .accessibilityAction(.escape) { box.value += 1 }
        let (window, host) = try mount(root)
        defer { unmount(window, host) }
        await quietWindow(0.5)
        let inner = try XCTUnwrap(accessibilityNode("oracle.inner", under: host.view), "无障碍树里找不到元素")
        XCTAssertTrue(performEscape(from: inner), "没人接住擦除")
        XCTAssertEqual(box.value, 1)
    }

    private final class Counter {
        var value = 0
    }

    private func mount(_ view: some View) throws -> (UIWindow, UIViewController) {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host)
    }

    private func unmount(_ window: UIWindow, _ host: UIViewController) {
        host.dismiss(animated: false)
        window.isHidden = true
    }

    /// 四个 action 与契约一致（换手机号、注销的半屏回归用的就是这两个值）。
    func testActionsMatchContract() {
        XCTAssertEqual(ApiOperations.all["createWithdrawal"]?.stepUp, "withdraw")
        XCTAssertEqual(ApiOperations.all["savePayoutAccount"]?.stepUp, "payout_account_change")
        XCTAssertEqual(ApiOperations.all["bindPhone"]?.stepUp, "phone_change")
        XCTAssertEqual(ApiOperations.all["requestDeletion"]?.stepUp, "account_deletion")
    }
}
