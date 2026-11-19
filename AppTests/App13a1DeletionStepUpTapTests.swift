@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-13a-1-ios 写测 r2（D10-2090 ①）：注销页的「真点」用例——`StepUpVisualFundsGuardTests.testConsumersAreKnown` 注释要求的「注销落地时补真点
/// 用例再改这里」。到达方式只走生产链路（照 `StepUpVisualTestCase.panelOnWithdraw` / `panelOnPayout` 的写法）：真实 App 组装（WalletAppFixture）→
/// 生产的 `DeleteAccountRouteView`（AppWallet.entry → DeleteAccountScreen + DeleteAccountController + SensitiveFlow，App 套上
/// `.walletStepUpSheet`）
/// 挂进窗口 → 用页面**同一份**渲染时回调（`DeleteAccountActions.make`）勾选、点【申请注销】→ 假服务 10003 → 生产代码开半屏并发码。
/// 测试只控制网络答复，不伪造面板状态。进程内点不到 SwiftUI 按钮，同提现 / 改收款真点用例的约定。
///
/// DeleteAccount 的 since.ios 仍是 null（Router 守卫挡着，D10-1562），目的地直接放进导航栈（下面是 Settings），不经守卫。
///
/// 依据：本单任务书 §1「二次验证」（复用 StepUpController，action=account_deletion；面板标题 / 说明随 action 变）、共性第 3 条。
@MainActor
final class App13a1DeletionStepUpTapTests: WalletFlowTestCase {
    private var window: UIWindow?
    private var hidden: [UIWindow] = []
    private let probes = ProductVisualProbes()

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
        super.tearDown()
    }

    private func mount(_ fixture: WalletAppFixture, _ destination: RouteDestination) {
        let root = DeleteAccountRouteView(destination: destination)
            .environmentObject(fixture.wallet)
            .environment(\.couliLayoutProbe, probes.probe)
        let host = UIHostingController(rootView: root)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        frame.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        frame.rootViewController = host
        frame.windowLevel = .alert + 1
        hidden = (scene?.windows ?? []).filter { $0 !== frame && !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        frame.makeKeyAndVisible()
        host.view.frame = frame.bounds
        host.view.layoutIfNeeded()
        window = frame
    }

    /// 勾选 → 【申请注销】→ 10003 → 二次验证半屏：面板 action = account_deletion（发码同 action），标题与说明是注销用的
    /// （step_up.title.account_deletion、step_up.summary.deletion），不是提现 / 改收款的「资金安全」标题 error.10003。
    func testApplyTapOpensDeletionStepUpSheet() async throws {
        script.ok("GET /v1/me/deletion", "null")
        script.on(
            "POST /v1/me/deletion", .envelope(code: 10003, data: "null", headers: [:]),
            .envelope(code: 0, data: "{}", headers: [:])
        )
        script.on("POST /v1/auth/sms-codes", .envelope(
            code: 0, data: "{\"resend_after_sec\":48,\"expires_in_sec\":300}", headers: [:]
        ))
        let fixture = make()
        let destination = RouteDestination(route: DeleteAccountController.route)
        fixture.router.path = [RouteDestination(route: "Settings"), destination]
        mount(fixture, destination)

        await waitUntil("注销页执行器没有建立") { fixture.wallet.pages[destination.id] != nil }
        let host = try XCTUnwrap(fixture.wallet.pages[destination.id]?
            .controller as? MePageHost<DeleteAccountController>)
        let controller = host.controller
        await waitUntil("注销页没有进入可申请的初始态", timeout: 8) {
            controller.view.kind == .initial && controller.view.applyEnabledWhenChecked
        }

        // 页面同一份渲染时回调：勾选、再按新渲染取【申请注销】
        DeleteAccountActions.make(controller, controller.state, controller.flow.state).toggleWaiver()
        XCTAssertTrue(controller.state.waiver, "勾选生效")
        DeleteAccountActions.make(controller, controller.state, controller.flow.state).apply()

        let stepUp = controller.flow.stepUp
        await waitUntil("二次验证半屏没有打开", timeout: 8) {
            guard let state = stepUp.state else { return false }
            return state.phase == .ready && state.resendLeftSec > 0
        }
        addTeardownBlock { @MainActor in
            if let state = stepUp.state {
                stepUp.close(instance: state.instance)
            }
        }
        let state = try XCTUnwrap(stepUp.state)
        XCTAssertEqual(state.action, "account_deletion", "半屏 action = account_deletion")
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/me/deletion").count, 1, "点【申请注销】发出 1 次，得到 10003")
        let sms = try XCTUnwrap(WalletStubProtocol.requests("POST", "/v1/auth/sms-codes").last, "半屏发码")
        XCTAssertEqual(sms.json["purpose"] as? String, "step_up")
        XCTAssertEqual(sms.json["action"] as? String, "account_deletion", "发码 action = account_deletion")

        // 半屏真的弹出来、画出来（.sheet 进程内画进宿主窗口）
        await waitUntil("半屏没有呈现", timeout: 8) { self.window?.rootViewController?.presentedViewController != nil }
        await waitUntil("半屏标题没有上报", timeout: 8) { self.probes["stepUp.title"] != nil }
        await waitUntil("半屏说明没有上报", timeout: 8) { self.probes["stepUp.summary"] != nil }

        let texts = AccountDraftTexts()
        let title = try XCTUnwrap(probes["stepUp.title"]?.text)
        XCTAssertEqual(title, texts.text("step_up.title.account_deletion"), "标题是注销用的")
        XCTAssertNotEqual(title, WalletDraftTexts().text("error.10003"), "不是提现 / 改收款的资金安全标题")
        let summary = try XCTUnwrap(probes["stepUp.summary"]?.text)
        XCTAssertEqual(summary, texts.text("step_up.summary.deletion"), "说明是注销用的")
        XCTAssertFalse(summary.isEmpty)
    }
}
