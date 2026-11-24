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

/// APP-13a-2-ios 写测 r3（D10-2090 ① 先例）：换号页 10003 面板的「真点」用例——`StepUpVisualFundsGuardTests.testConsumersAreKnown` 的清单
/// 加 `AppMe+PhoneChange.swift` 之前要有的证据。照 `App13a1DeletionStepUpTapTests` 的写法：真实 App 组合（App13a2Fixture：AppMe +
/// AppWallet + AppLogin 共用 ApiClient，Debug 入口覆盖由夹具打开）→ 生产的设置页路由视图（`MeRouteView` → `SettingsRouteContent`，App 在背景层套
/// `.walletStepUpSheet`）挂进窗口 → 用页面同一份渲染时回调（`SettingsActions` 点手机号行、`PhoneChangeActions` 走两步、`StepUpActions` 在
/// 半屏上发码 / 填码 / 验证）→ 假服务 10003 → 生产代码弹半屏。测试只控制网络答复，不伪造面板状态；不依赖 PhoneChangeScreen 的视图层级，
/// 半屏只按读屏标识 / 探针 `stepUp.title` 与宿主的 presentedViewController 判定。进程内点不到 SwiftUI 按钮，同提现 / 注销真点用例的约定。
///
/// 另一条对照：同一组合里的收款账号页半屏照旧（action=payout_account_change、资金安全标题、原键原体重放 1 次）；提现页升锁 6c97062 起
/// 不再要求二次验证（D10-2903 ① 甲），改钉「只发一次、不出半屏」。
@MainActor
final class App13a2StepUpTapTests: App13a2TestCase {
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

    private func mount(_ root: some View) {
        let content = NavigationStack { root }.environment(\.couliLayoutProbe, probes.probe)
        let host = UIHostingController(rootView: AnyView(content))
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

    private func closeOnTeardown(_ stepUp: StepUpController) {
        addTeardownBlock { @MainActor in
            if let state = stepUp.state {
                stepUp.close(instance: state.instance)
            }
        }
    }

    /// 半屏打开后的页面与半屏执行器。
    private struct OpenedSheet {
        let controller: PhoneChangeController
        let stepUp: StepUpController
    }

    /// 设置页（生产路由视图）挂进窗口 → 手机号行 → 第 1 步 → 第 2 步【提交】→ 10003 → 等半屏就绪。
    private func openSheet(_ fixture: App13a2Fixture) async throws -> OpenedSheet {
        let settings = try await settings(fixture)
        let destination = try XCTUnwrap(fixture.router.path.last { $0.route == "Settings" })
        mount(MeRouteView(destination: destination).environmentObject(fixture.me))
        await settle()

        // 页面同一份渲染时回调：点手机号行进子页，走第 1 步、填第 2 步、点【提交】
        SettingsActions.make(settings, settings.state).row(try phoneRow(settings))
        let controller = try XCTUnwrap(settings.phoneChange, "点手机号行没有建换号子页")
        await passStep1(controller)
        fillStep2(controller)
        await submit(controller)

        let stepUp = try XCTUnwrap(controller.stepUp, "换号子页没有 10003 面板")
        closeOnTeardown(stepUp)
        await waitUntil("二次验证半屏没有打开", timeout: 8) { stepUp.state?.phase == .ready }
        return OpenedSheet(controller: controller, stepUp: stepUp)
    }

    /// 设置页（生产路由视图）→ 手机号行 → 第 1 步 → 第 2 步【提交】→ 10003 → 二次验证半屏真的弹出（action=phone_change）→ 半屏上
    /// 重新获取验证码、填码、【验证并提交】→ 同一个键、同一份请求体、带新 token 重放 1 次 → Done。标题断言见 testPanelTitleIsPhoneChangeDraft。
    func testSubmit10003OpensRealSheetAndReplaysToDone() async throws {
        script.on(Self.bindWrite, Self.code(10003), Self.code(0, "{}"))
        // 倒计时 1 秒：第 1 步与半屏共用同一份「账号 + action」发码截止时间（共性第 31 条），半屏打开时可能沿用倒计时不再发
        script.on(Self.smsSend, Self.code(0, "{\"resend_after_sec\":1,\"expires_in_sec\":300}"))
        let fixture = fixture()
        let opened = try await openSheet(fixture)
        let (controller, stepUp) = (opened.controller, opened.stepUp)
        XCTAssertEqual(stepUp.state?.action, "phone_change", "半屏 action = phone_change")
        XCTAssertEqual(binds.count, 1, "【提交】发出 1 次，得到 10003")

        // 半屏真的弹出来、画出来（.sheet 进程内画进宿主窗口）
        await waitUntil("半屏没有呈现", timeout: 8) { self.window?.rootViewController?.presentedViewController != nil }
        await waitUntil("半屏标题没有上报", timeout: 8) { self.probes["stepUp.title"] != nil }

        // 半屏上真点：倒计时（1 秒）结束后【重新获取】→ 发码 1 次；填码；【验证并提交】
        await waitUntil("半屏倒计时没有结束", timeout: 8) { stepUp.state?.resendLeftSec == 0 }
        let sentBefore = stepSms.count
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).resend()
        await waitUntil("半屏【重新获取】没有发码") { self.stepSms.count == sentBefore + 1 }
        XCTAssertEqual(stepSms.last?.body, Self.oldBody, "半屏发码 action = phone_change，不带 phone")
        await waitUntil("重新获取没有回来") { stepUp.state?.phase == .ready }
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).code("112233")
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).verify()

        await waitUntil("验证后没有重放", timeout: 8) { self.binds.count == 2 }
        let verify = try XCTUnwrap(sent(Self.stepUpVerify).last)
        XCTAssertEqual(verify.json["action"] as? String, "phone_change")
        XCTAssertEqual(verify.json["code"] as? String, "112233")
        XCTAssertNil(verify.json["summary"], "phone_change 不绑摘要")
        let (first, replay) = (binds[0], binds[1])
        XCTAssertEqual(replay.header("Idempotency-Key"), first.header("Idempotency-Key"), "同一个键")
        XCTAssertEqual(replay.body, first.body, "同一份请求体")
        XCTAssertEqual(replay.header("X-Step-Up-Token"), Self.panelToken, "带半屏拿到的新 token")
        await waitUntil("重放成功没有进 Done", timeout: 8) { controller.state.step == .done }
        XCTAssertEqual(controller.state.doneMaskedPhone, Self.newMasked)
        await quietWindow(0.6)
        XCTAssertEqual(binds.count, 2, "只重放 1 次")
        XCTAssertNil(stepUp.state, "拿到 token 后半屏收起")
    }

    /// 换号半屏的标题是换号草稿键（brief §3 / §11 第 9 项），不是提现 / 改收款的资金安全标题。面板按 action 换标题已由
    /// FU-IOS-PHONECHANGE-STEPUP-TITLE（D10-2281）补上（StepUpSheet.titleKey 加 phone_change 分支），原先的预期失败包装随之摘掉。
    func testPanelTitleIsPhoneChangeDraft() async throws {
        script.on(Self.bindWrite, Self.code(10003))
        let fixture = fixture()
        let opened = try await openSheet(fixture)
        XCTAssertEqual(opened.stepUp.state?.action, "phone_change", "前提：换号半屏")
        await waitUntil("半屏没有呈现", timeout: 8) { self.window?.rootViewController?.presentedViewController != nil }
        await waitUntil("半屏标题没有上报", timeout: 8) { self.probes["stepUp.title"] != nil }
        let title = probes["stepUp.title"]?.text ?? ""
        XCTAssertEqual(title, AccountDraftTexts().text("step_up.title.phone_change"), "标题是换号用的（brief §3 草稿键）")
        XCTAssertNotEqual(title, WalletDraftTexts().text("error.10003"), "不是提现 / 改收款的资金安全标题")
    }

    /// 对照（升锁 6c97062，D10-2903 ① 甲：提现不再要求二次验证）：同一组合里提现页（生产路由视图 WalletRouteView）提交 → 只发一次、首次那把键、
    /// 不带 token，不发码、不验证，不出半屏，落地提现记录。原「半屏 action=withdraw、资金安全标题、发码体、原键原体重放带 token」挪到改收款：
    /// testPayoutSheetUnchanged；「提现验证不带 summary」挪不过去（改收款必须带 summary，已另有用例钉住）。
    func testWithdrawSubmitsOnceWithoutSheet() async throws {
        let fixture = fixture()
        fixture.wallet.realnameChanged()
        await waitUntil("实名状态没取到") { fixture.wallet.realnameVerified() }
        fixture.router.open(RouteRequest(route: WalletRoutes.withdraw, from: .inApp))
        let destination = try XCTUnwrap(fixture.router.path.last { $0.route == WalletRoutes.withdraw }, "提现页没有打开")
        mount(WalletRouteView(destination: destination).environmentObject(fixture.wallet))
        let controller = try XCTUnwrap(fixture.wallet.entry(for: destination)?.controller as? WithdrawController)
        controller.start()
        await waitUntil("rules 没有到位") { controller.state.phase == .content }
        WithdrawActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id).amount("10")
        await waitUntil("估算没有回来") {
            if case .shown = controller.state.estimate {
                return true
            }
            return controller.state.estimate == .hidden
        }
        let stepUp = controller.flow.stepUp
        closeOnTeardown(stepUp)
        WithdrawActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id).submit()

        let posts = { WalletStubProtocol.requests("POST", "/v1/withdrawals") }
        await waitUntil("提现没有落地", timeout: 8) {
            fixture.router.path.last?.route == WalletRoutes.withdrawRecords
        }
        await quietWindow(0.6)
        XCTAssertNil(window?.rootViewController?.presentedViewController, "不出半屏")
        XCTAssertNil(stepUp.state, "不出面板")
        XCTAssertTrue(sent(Self.smsSend).isEmpty, "不发码")
        XCTAssertTrue(sent(Self.stepUpVerify).isEmpty, "不验证")
        XCTAssertEqual(posts().count, 1, "只发一次")
        XCTAssertNotNil(posts().first?.header("Idempotency-Key"))
        XCTAssertNil(posts().first?.header("X-Step-Up-Token"))
    }

    /// 对照（零变化，由提现挪来）：同一组合里收款账号页（生产路由视图 WalletRouteView）保存 10003 → 半屏 action=payout_account_change、
    /// 资金安全标题（error.10003）、发码体只有 action + purpose；验证后原键原体重放 1 次、带 token。
    func testPayoutSheetUnchanged() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", Self.code(10003), Self.code(0, WalletSamples.alipay))
        let fixture = fixture()
        fixture.wallet.realnameChanged()
        await waitUntil("实名状态没取到") { fixture.wallet.realnameVerified() }
        fixture.router.open(RouteRequest(route: WalletRoutes.payoutAccount, from: .inApp))
        let destination = try XCTUnwrap(
            fixture.router.path.last { $0.route == WalletRoutes.payoutAccount }, "收款账号页没有打开"
        )
        mount(WalletRouteView(destination: destination).environmentObject(fixture.wallet))
        let controller = try XCTUnwrap(fixture.wallet.entry(for: destination)?.controller as? PayoutAccountController)
        controller.start()
        await waitUntil("收款账号没有到位") { controller.state.phase != .loading }
        let actions = { PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id) }
        actions().logon("zhangsan@example.com")
        actions().payee("测试三")
        actions().save()

        let stepUp = controller.flow.stepUp
        closeOnTeardown(stepUp)
        await waitUntil("改收款半屏没有打开", timeout: 8) { stepUp.state?.phase == .ready }
        XCTAssertEqual(stepUp.state?.action, "payout_account_change", "(零变化) action = payout_account_change")
        let sms = try XCTUnwrap(sent(Self.smsSend).last)
        XCTAssertEqual(sms.body, "{\"action\":\"payout_account_change\",\"purpose\":\"step_up\"}", "(零变化) 发码体")
        await waitUntil("改收款半屏没有呈现", timeout: 8) {
            self.window?.rootViewController?.presentedViewController != nil
        }
        await waitUntil("改收款半屏标题没有上报", timeout: 8) { self.probes["stepUp.title"] != nil }
        XCTAssertEqual(probes["stepUp.title"]?.text, WalletDraftTexts().text("error.10003"), "(零变化) 资金安全标题")

        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).code("123456")
        StepUpActions.make(stepUp, try XCTUnwrap(stepUp.state)).verify()
        let saves = { WalletStubProtocol.requests("PUT", "/v1/me/payout-account") }
        await waitUntil("改收款没有重放", timeout: 8) { saves().count == 2 }
        XCTAssertEqual(saves()[1].header("Idempotency-Key"), saves()[0].header("Idempotency-Key"), "(零变化) 原键")
        XCTAssertEqual(saves()[1].body, saves()[0].body, "(零变化) 原体")
        XCTAssertNotNil(saves()[1].header("X-Step-Up-Token"), "(零变化) 带 token")
    }
}
