@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Login
import Me
import MeCore
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// FU-IOS-PHONECHANGE-STEPUP-TITLE 写测（任务书 brief.md §1、§4；D10-2281 ②：换号入口 Release 放开的前置之一）：换号流程里提交 / 确认得到 10003
/// 弹的二次验证半屏（action = phone_change）标题取 `step_up.title.phone_change`、说明行 `stepUp.summary` 显示契约键
/// `step_up.summary.phone_change`（{phone} = 打开面板那一刻固定的脱敏新号；没有号码不显示说明行）；提现、改收款半屏零变化。
/// 写法照 `App13a2StepUpTapTests`：真实 App 组合（App13a2Fixture）→ 生产的设置页路由视图挂进窗口 → 页面同一份渲染时回调 → 假服务 10003 → 生产代码
/// 弹半屏；半屏只按探针 `stepUp.title` / `stepUp.summary` 与宿主的 presentedViewController 判定，测试不伪造面板状态。
/// 注销面板的标题与说明行（零变化）已由 `App13a1DeletionStepUpTapTests.testDelete10003OpensRealSheet…` 覆盖，这里不重复。
@MainActor
final class FuIosPhoneChangeStepUpTitleTests: App13a2TestCase {
    private var window: UIWindow?
    private var hidden: [UIWindow] = []
    private let probes = ProductVisualProbes()

    /// 待确认卡用的另一个号码（与第 2 步缺省新号不同，确认说明行取的是卡上的号）。
    private static let pendingPhone = "13700005678"
    private static let pendingKey = "pc-fu-title-key-0001"

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
        super.tearDown()
    }

    // MARK: - 辅助（照抄 App13a2StepUpTapTests 的私有辅助，不改原文件）

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

    /// 设置页（生产路由视图）挂进窗口 → 点手机号行进换号子页。
    private func openPage(_ fixture: App13a2Fixture) async throws -> PhoneChangeController {
        let settings = try await settings(fixture)
        let destination = try XCTUnwrap(fixture.router.path.last { $0.route == "Settings" })
        mount(MeRouteView(destination: destination).environmentObject(fixture.me))
        await settle()
        SettingsActions.make(settings, settings.state).row(try phoneRow(settings))
        return try XCTUnwrap(settings.phoneChange, "点手机号行没有建换号子页")
    }

    /// 等半屏就绪、真的呈现、标题探针上报。
    private func waitSheet(_ stepUp: StepUpController, _ label: String) async {
        await waitUntil("\(label)半屏没有打开", timeout: 8) { stepUp.state?.phase == .ready }
        await waitUntil("\(label)半屏没有呈现", timeout: 8) {
            self.window?.rootViewController?.presentedViewController != nil
        }
        await waitUntil("\(label)半屏标题没有上报", timeout: 8) { self.probes["stepUp.title"] != nil }
    }

    /// 第 1 步 → 第 2 步填新号【提交】→ 10003 → 等半屏就绪。
    private func openSubmitSheet(_ fixture: App13a2Fixture) async throws -> (PhoneChangeController, StepUpController) {
        let controller = try await openPage(fixture)
        await passStep1(controller)
        fillStep2(controller)
        await submit(controller)
        let stepUp = try XCTUnwrap(controller.stepUp, "换号子页没有 10003 面板")
        closeOnTeardown(stepUp)
        await waitSheet(stepUp, "换号")
        XCTAssertEqual(stepUp.state?.action, "phone_change", "前提：换号半屏")
        return (controller, stepUp)
    }

    /// 预置一条结果未知的 bindPhone 未决记录（摘要 `summary` 原样写入）→ 进子页直接显示待确认卡 →【确认上一次提交】→ 10003 → 等半屏就绪。
    private func openConfirmSheet(summary: String) async throws -> (PhoneChangeController, StepUpController) {
        try backend.write(PendingKeyRecord(
            key: Self.pendingKey, operationId: BindPhoneService.operationId,
            body: "{\"code\":\"654321\",\"phone\":\"\(Self.pendingPhone)\"}", account: Self.account, summary: summary,
            stateRaw: PendingKeyStore.unknown, everUnknown: true, createdAtMillis: 1_763_600_000_000
        ))
        script.on(Self.bindWrite, Self.code(10003))
        let fixture = fixture()
        let controller = try await openPage(fixture)
        await waitUntil("没有按本机记录进待确认") { controller.state.step == .pending && controller.state.pending != nil }
        act(controller).confirmPending()
        await waitUntil("确认没有发出") { self.binds.count == 1 }
        let stepUp = try XCTUnwrap(controller.stepUp, "换号子页没有 10003 面板")
        closeOnTeardown(stepUp)
        await waitSheet(stepUp, "确认")
        XCTAssertEqual(stepUp.state?.action, "phone_change", "前提：换号半屏")
        return (controller, stepUp)
    }

    private var texts: AccountDraftTexts {
        AccountDraftTexts()
    }

    /// 契约键 `step_up.summary.phone_change` 代入脱敏号后的整句。
    private func summary(_ masked: String) -> String {
        texts.format("step_up.summary.phone_change", ["phone": masked])
    }

    /// 半屏里此刻显示的全部文字。
    private var sheetTexts: [String] {
        probes.records.filter { $0.key.hasPrefix("stepUp.") }.values.map(\.text)
    }

    /// 换号半屏标题是换号草稿键、不是资金安全标题。
    private func assertPhoneChangeTitle(file: StaticString = #filePath, line: UInt = #line) {
        let title = probes["stepUp.title"]?.text ?? ""
        XCTAssertEqual(title, texts.text("step_up.title.phone_change"), "标题是换号用的（brief §1-1）", file: file, line: line)
        XCTAssertNotEqual(title, WalletDraftTexts().text("error.10003"), "不是提现 / 改收款的资金安全标题", file: file, line: line)
    }

    // MARK: - 用例

    /// §4-1：第 2 步【提交】得 10003 → 半屏标题 = AccountDraftTexts 的 `step_up.title.phone_change`，≠ `error.10003`。
    func testSubmit10003TitleIsPhoneChangeDraft() async throws {
        script.on(Self.bindWrite, Self.code(10003))
        _ = try await openSubmitSheet(fixture())
        assertPhoneChangeTitle()
    }

    /// §4-2：提交 10003 → 说明行 = 「更换手机号 · 新手机号 <提交时脱敏号>」（契约键代入，不出现 {phone} 字面）；面板打开后再改第 2 步新号输入框，
    /// 说明行仍是提交时那个号（共性第 17 条：展示用实际发送的固定摘要）。
    func testSubmit10003SummaryShowsSubmittedPhoneAndIgnoresLaterInput() async throws {
        script.on(Self.bindWrite, Self.code(10003))
        let (controller, _) = try await openSubmitSheet(fixture())
        await waitUntil("半屏说明行没有上报", timeout: 8) { self.probes["stepUp.summary"] != nil }
        let expected = summary(Self.newMasked)
        XCTAssertEqual(probes["stepUp.summary"]?.text, expected, "说明行是提交时的脱敏新号")
        XCTAssertTrue(expected.contains(Self.newMasked), "前提：文案表代入了号码")
        XCTAssertFalse(sheetTexts.contains { $0.contains("{phone}") }, "不出现 {phone} 字面")

        // 面板打开后改输入框（页面同一份渲染时回调）：说明行不跟着变
        let later = "13600002468"
        act(controller).newPhone(later)
        XCTAssertEqual(controller.state.newPhone, later, "前提：输入框确实改了")
        await settle()
        await quietWindow(0.5)
        XCTAssertEqual(probes["stepUp.summary"]?.text, expected, "提交后改输入框，说明行仍是提交时那个号")
        XCTAssertFalse(probes["stepUp.summary"]?.text.contains(MePhone.masked(later)) ?? false, "不显示改后的号码")
    }

    /// §4-3：待确认卡【确认上一次提交】得 10003 → 半屏标题是换号草稿键；说明行用待确认卡上的脱敏号（不是第 2 步缺省新号）。
    func testConfirm10003SummaryUsesPendingCardPhone() async throws {
        let masked = MePhone.masked(Self.pendingPhone)
        let (controller, _) = try await openConfirmSheet(summary: "{\"phone\":\"\(masked)\"}")
        XCTAssertEqual(controller.state.pending?.maskedPhone, masked, "前提：卡片是预置记录的号码")
        assertPhoneChangeTitle()
        await waitUntil("半屏说明行没有上报", timeout: 8) { self.probes["stepUp.summary"] != nil }
        XCTAssertEqual(probes["stepUp.summary"]?.text, summary(masked), "说明行是待确认卡的脱敏号")
        XCTAssertNotEqual(masked, Self.newMasked, "前提：与第 2 步缺省新号不同")
    }

    /// §4-4：待确认卡没有号码（记录摘要里没有 phone）→ 确认得 10003 → 半屏标题是换号草稿键、没有 `stepUp.summary`，也不出现 {phone} 字面或半截句。
    func testConfirm10003WithoutPhoneHasNoSummary() async throws {
        let (controller, _) = try await openConfirmSheet(summary: "{}")
        XCTAssertNil(controller.state.pending?.maskedPhone, "前提：卡片没有号码")
        assertPhoneChangeTitle()
        await quietWindow(0.5)
        XCTAssertNil(probes["stepUp.summary"], "没有号码不显示说明行")
        XCTAssertFalse(sheetTexts.contains { $0.contains("{phone}") }, "不出现 {phone} 字面")
        let half = summary("")
        XCTAssertFalse(sheetTexts.contains(half), "不出现半截句")
    }

    /// §4-6（零变化）：同一组合里提现页提交 10003 → 半屏 action=withdraw、标题仍 `error.10003`、没有 `stepUp.summary`。
    func testWithdrawSheetTitleAndNoSummaryUnchanged() async throws {
        script.on("POST /v1/withdrawals", Self.code(10003))
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
        WithdrawActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id).submit()
        let stepUp = controller.flow.stepUp
        closeOnTeardown(stepUp)
        await waitSheet(stepUp, "提现")
        XCTAssertEqual(stepUp.state?.action, "withdraw", "(零变化) action = withdraw")
        XCTAssertEqual(probes["stepUp.title"]?.text, WalletDraftTexts().text("error.10003"), "(零变化) 资金安全标题")
        await quietWindow(0.5)
        XCTAssertNil(probes["stepUp.summary"], "(零变化) 提现半屏没有说明行")
    }

    /// §4-6（零变化）：同一组合里收款账号页（未绑定）填支付宝【保存】得 10003 → 半屏 action=payout_account_change、标题仍 `error.10003`、
    /// 没有 `stepUp.summary`。
    func testPayoutSheetTitleAndNoSummaryUnchanged() async throws {
        script.ok("GET /v1/me/payout-account", "{}")
        script.on("PUT /v1/me/payout-account", Self.code(10003))
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
        func actions() -> PayoutActions {
            PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
        }
        actions().logon("zhangsan@example.com")
        actions().payee("测试三")
        actions().save()
        let stepUp = controller.flow.stepUp
        closeOnTeardown(stepUp)
        await waitSheet(stepUp, "改收款")
        XCTAssertEqual(stepUp.state?.action, "payout_account_change", "(零变化) action = payout_account_change")
        XCTAssertEqual(probes["stepUp.title"]?.text, WalletDraftTexts().text("error.10003"), "(零变化) 资金安全标题")
        await quietWindow(0.5)
        XCTAssertNil(probes["stepUp.summary"], "(零变化) 改收款半屏没有说明行")
    }
}
