@testable import Couli
import CouliNetwork
import Foundation
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09 iOS 第 1 轮评审 R1-07…R1-11：分页同轮详情、打开错误卡、收款账号重读失败、字段错误定位（字段错误播报用真实页面宿主）。
final class WalletReviewR1PageTests: WalletFlowTestCase {
    // MARK: - R1-07 分页插入用同轮详情

    /// R1-07：旧列表已有第二页 W2；刷新期间展开 W2 取得本轮详情（PAID_API + 流水号）；第一页不含 W2；随后分页返回 W2 的审核中摘要 →
    /// 整卡用本轮详情（状态与流水号一致），details 同步。
    func testPagingInsertUsesRoundDetailAndSyncsDetails() async throws {
        let page1 = "{\"items\":[\(WithdrawRecordsTests.item("W1", "PAYING"))],\"next_cursor\":\"p1\"}"
        let page2 = "{\"items\":[\(WithdrawRecordsTests.item("W2", "PENDING_REVIEW"))],\"next_cursor\":null}"
        script.on(
            "GET /v1/withdrawals", .envelope(code: 0, data: page1, headers: [:]),
            .envelope(code: 0, data: page2, headers: [:]), .hold, .envelope(code: 0, data: page2, headers: [:])
        )
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdrawRecords))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil { controller.state.phase == .content && !controller.firstPagePending }
        RecordsActions.make(controller, controller.state).loadMore()
        await waitUntil { controller.state.items.count == 2 }
        XCTAssertTrue(controller.refresh(), "刷新开始")
        await waitUntil("刷新的第一页没有发出") { WalletStubProtocol.heldIds.count == 1 }
        RecordsActions.make(controller, controller.state).toggle("W2")
        await waitUntil("本轮详情没有到位") { controller.state.details["W2"]?.status == "PAID_API" }
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 0, data: page1, headers: [:]))
        await waitUntil { !controller.firstPagePending && controller.state.items.map(\.withdrawalId) == ["W1"] }
        RecordsActions.make(controller, controller.state).loadMore()
        await waitUntil("分页没有回来") { controller.state.items.count == 2 }
        let card = try XCTUnwrap(controller.state.items.last)
        XCTAssertEqual(card.withdrawalId, "W2")
        XCTAssertEqual(card.status, "PAID_API", "整卡用本轮已接受的详情，不被较早的摘要覆盖")
        XCTAssertEqual(controller.state.details["W2"]?.channelOrderId, "fixture-channel-001", "details 同步")
        XCTAssertEqual(controller.state.details["W2"]?.status, card.status, "卡头状态与展开区同一份数据")
    }

    // MARK: - R1-08 / R1-09 打开错误卡

    /// R1-08：提现记录页点失败单的【修改收款账号】→ getMe 50001 → 真实记录页显示统一的打开错误卡（trace6、重试、关闭）。
    func testRecordsPageRendersOpenErrorCard() async throws {
        let failed = WithdrawRecordsTests.item(
            "W6", "FAILED", reason: "PAYEE_ACCOUNT_STATUS_ERROR", failAction: "change_payout_account"
        )
        script.ok("GET /v1/withdrawals", "{\"items\":[\(failed)],\"next_cursor\":null}")
        script.fail("GET /v1/me", 50001)
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.withdrawRecords))
        let controller = try XCTUnwrap(entry.controller as? WithdrawRecordsController)
        controller.load()
        await waitUntil { controller.state.phase == .content }
        RecordsActions.make(controller, controller.state).changeAccount("W6")
        await waitUntil("实名查询失败没有落到记录页") { entry.context.openError != nil }
        let model = try XCTUnwrap(OpenErrorModel.make(entry.context))
        XCTAssertTrue(model.notice.message(WalletDraftTexts()).contains("456789ab".suffix(6)), "5xxxx 带 trace6")
        XCTAssertTrue(model.retryEnabled, "不在禁用期：【重试】可用")
        // 记录页真实界面上的错误卡与【关闭】由 UI 用例 WalletReviewR1UITests 断言
        // 【重试】成功后进收款账号页
        script.ok("GET /v1/me", WalletSamples.me)
        model.retry()
        await waitUntil("重试没有打开收款账号页") { fixture.router.path.last?.route == WalletRoutes.payoutAccount }
    }

    /// R1-09：钱包点【提现】、getMe 返回 42901 → 打开错误卡的【重试】置灰；共享读禁用期到期后同一张卡的【重试】自动恢复，点它重新查询并打开。
    func testOpenErrorRetryRecoversWhenReadGateExpires() async throws {
        script.fail("GET /v1/me", 42901, headers: ["Retry-After": "1"])
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open(WalletRoutes.wallet))
        let wallet = try XCTUnwrap(entry.controller as? WalletController)
        wallet.load()
        await waitUntil { wallet.state.summary != nil }
        WalletActions.make(wallet, wallet.state).withdraw()
        await waitUntil("实名查询的 42901 没有落到钱包页") { entry.context.openError != nil }
        XCTAssertEqual(OpenErrorModel.make(entry.context)?.retryEnabled, false, "禁用期内【重试】置灰")
        script.ok("GET /v1/me", WalletSamples.me)
        await waitUntil("禁用期到期后【重试】没有恢复", timeout: 4) {
            OpenErrorModel.make(entry.context)?.retryEnabled == true
        }
        let model = try XCTUnwrap(OpenErrorModel.make(entry.context))
        model.retry()
        await waitUntil("从按钮重试没有打开提现页") { fixture.router.path.last?.route == WalletRoutes.withdraw }
    }

    // MARK: - R1-10 收款账号重读失败

    /// R1-10：页面显示收款账号 X；回前台重读失败（50001）或被本地限流拦下 → 旧账号展示作废，进可重试的错误态。
    func testPayoutRereadFailureOrGateInvalidatesShownAccount() async throws {
        let fixture = make()
        let controller = try await payout(fixture)
        XCTAssertEqual(controller.state.account?.maskedAccount, "138****5678", "前提：显示账号 X")
        script.fail("GET /v1/me/payout-account", 50001)
        controller.setVisible(false)
        controller.setVisible(true)
        await waitUntil("重读失败没有结算") { controller.state.loadError != nil }
        XCTAssertNil(controller.state.account, "重读失败：旧账号不再标为当前")
        XCTAssertEqual(controller.state.phase, .error, "保留可重试的错误")

        script.ok("GET /v1/me/payout-account", WalletSamples.alipay)
        PayoutActions.make(controller, controller.state, risk: nil).retry()
        await waitUntil("重试没有取回账号") { controller.state.account != nil }
        fixture.gates.read.start(5000)
        controller.setVisible(false)
        controller.setVisible(true)
        XCTAssertNil(controller.state.account, "被本地限流拦下：旧账号同样作废")
        XCTAssertEqual(controller.state.loadError?.key, "error.42901")
        XCTAssertEqual(controller.state.phase, .error)
    }

    // MARK: - R1-11 字段错误定位

    /// R1-11：保存银行卡收到 20001、fields=[payee_name, card_no] → 真实收款账号页按表单顺序把首个错误字段（卡号）的错误提示作为焦点与
    /// 滚动目标，视图出现后播报一次；普通重绘不再播报；下一次 20001 事件再播报一次。
    func testFirstFieldErrorAnnouncedOncePerEvent() async throws {
        let spoken = SpokenLog()
        WalletAnnounceProbe.observe = { spoken.lines.append($0) }
        defer { WalletAnnounceProbe.observe = nil }
        script.ok("GET /v1/me/payout-account", "{}")
        let fixture = make()
        let controller = try await payout(fixture)
        let entry = try XCTUnwrap(fixture.page(WalletRoutes.payoutAccount))
        let owner = controller.owner
        controller.chooseMethod(WalletJSON.bankCard, owner: owner)
        controller.onCardChange("6222000000000009", owner: owner)
        controller.onBankChange("测试银行", owner: owner)
        controller.onPayeeChange("测试", owner: owner)
        let host = HostedPage(entry.screen())
        defer { host.close() }
        await host.pump()
        let fields = "{\"fields\":[\"payee_name\",\"card_no\"]}"
        script.on("PUT /v1/me/payout-account", .envelope(code: 10003, data: "null", headers: [:]),
                  .envelope(code: 20001, data: fields, headers: [:]))
        controller.save(owner: owner)
        try await passStepUp(controller.flow.stepUp)
        await waitUntil { controller.flow.state.fieldErrors.count == 2 }
        let cardError = WalletDraftTexts().text(controller.flow.state.fieldErrorKey ?? "error.20001")
        await host.pump(until: { !spoken.lines.isEmpty })
        XCTAssertEqual(spoken.lines, [cardError], "首个错误字段的提示播报一次")
        XCTAssertEqual(controller.state.form.cardNo, "6222000000000009", "保留输入")
        var cue = FieldErrorCue()
        cue.arm(event: "F1", errors: controller.flow.state.fieldErrors,
                order: FieldErrorCue.payoutOrder(method: WalletJSON.bankCard))
        XCTAssertEqual(cue.target, PayoutAccountForm.cardNo, "按表单顺序：卡号在收款人之前")

        controller.objectWillChange.send()
        await host.pump(rounds: 15)
        XCTAssertEqual(spoken.lines.count, 1, "重绘不重复播报")

        let firstEvent = controller.flow.state.fieldErrorId
        controller.save(owner: owner)
        await waitUntil { controller.flow.state.fieldErrorId > firstEvent }
        await host.pump(until: { spoken.lines.count == 2 })
        XCTAssertEqual(spoken.lines.count, 2, "新的 20001 事件再播报一次")
    }
}

/// 播报记录（测试旁路观察）。
@MainActor
final class SpokenLog {
    var lines: [String] = []
}

/// 真实页面宿主：把页面放进 UIWindow 的 UIHostingController，按最新状态布局（onChange / task 照常执行）。
@MainActor
final class HostedPage {
    let window: UIWindow
    let host: UIHostingController<AnyView>

    init(_ view: AnyView) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        render()
    }

    func render() {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// 布局几轮（让 onChange / task 跑完）。
    func pump(rounds: Int = 5) async {
        for _ in 0..<rounds {
            render()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    func pump(timeout: TimeInterval = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            render()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
