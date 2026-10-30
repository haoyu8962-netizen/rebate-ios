@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// 收款账号页同件回归（brief §9 第 10 条：待确认卡、44001 / 放弃弹窗、错误条是两页共用件，c 改了不得破坏 PayoutAccount）。
/// 收款账号自身的版式、30307 / 30308 下移、G-W21 属 e 组。
@MainActor
final class WithdrawVisualPayoutSharedTests: WithdrawVisualTestCase {
    private func payoutActions(_ host: WithdrawVisualHost) throws -> PayoutActions {
        let controller = try XCTUnwrap(host.payout)
        return PayoutActions.make(controller, controller.state, risk: controller.flow.state.riskDialog?.id)
    }

    /// 未绑定、填好表单、保存（结果由 `reply` 决定）。
    private func save(_ reply: WalletStubProtocol.Reply) async throws -> WithdrawVisualHost {
        let host = try await freshPage(payout: "empty")
        host.server.script.on("PUT /v1/me/payout-account", reply)
        try await host.show(WalletRoutes.payoutAccount)
        _ = await host.stable { $0.payout.map { $0.state.phase != .loading } ?? false }
        host.wallet.deps.tokens.put(action: "payout_account_change", account: "user-a", token: "t", expireAtMs: .max)
        try payoutActions(host).logon("13800135678")
        try payoutActions(host).payee("测试三")
        try payoutActions(host).save()
        return host
    }

    /// 待确认卡：警告提示块 + 灰底明细（账号 / 收款人 / 时间）+ 两按钮 + 注释；没有「查看提现记录」。
    func testPendingCardSharedParts() async throws {
        let host = try await save(.disconnect)
        await waitUntil("没进待确认") { host.flow?.state.pending != nil }
        let shot = await host.stable { $0.flow?.state.pending != nil && $0.probes["pending.alert"] != nil }
        let image = try XCTUnwrap(shot)
        try background(image, "pending.alert", CouliColor.statusWarningBackground, minimum: 0.35, "警告令牌底")
        try background(image, "pending.detail", CouliColor.backgroundMuted, minimum: 0.4, "灰底明细")
        XCTAssertFalse(has("pending.records"), "收款账号页没有提现记录入口（W57）")
        XCTAssertFalse(pageTexts.contains { $0.contains("13800135678") }, "不显示完整账号")
        XCTAssertTrue(sameRowProbe("pending.abandon", "pending.confirm"), "两按钮同一行")
    }

    private func sameRowProbe(_ first: String, _ second: String) -> Bool {
        guard let lhs = page?.probes[first]?.rect, let rhs = page?.probes[second]?.rect else { return false }
        return sameRow(lhs, rhs)
    }

    /// 44001 / 放弃弹窗同槽位（G-W16）。
    func testDialogsSharedSlots() async throws {
        let host = try await save(.envelope(code: 44001, data: "null", headers: [:]))
        _ = await host.stable { $0.flow?.state.riskDialog != nil && $0.probes["flow.dialog.primary"] != nil }
        XCTAssertEqual(try text("flow.dialog.primary"), "联系客服申诉")
        XCTAssertEqual(try text("flow.dialog.secondary"), "知道了")
        let pending = try await save(.disconnect)
        await waitUntil { pending.flow?.state.pending != nil }
        pending.flowActions?.askAbandon()
        _ = await pending.stable { $0.flow?.state.abandonConfirmKey != nil && $0.probes["flow.dialog.primary"] != nil }
        XCTAssertEqual(try text("flow.dialog.primary"), "再想想")
        XCTAssertEqual(try text("flow.dialog.secondary"), "确定放弃")
        XCTAssertEqual(try text("abandon.note"), texts.text("pending_confirm.payout_account.abandon_note"), "附注不变")
    }

    /// 守卫（底版绿）：放弃 / 取消计数。
    func testPayoutAbandonCounts() async throws {
        let host = try await save(.disconnect)
        await waitUntil { host.flow?.state.pending != nil }
        host.flowActions?.askAbandon()
        await waitUntil { host.flow?.state.abandonConfirmKey != nil }
        host.flowActions?.cancelAbandon()
        await quietWindow(0.3)
        XCTAssertEqual(abandons.count, 0, "【再想想】零请求")
        host.flowActions?.askAbandon()
        await waitUntil { host.flow?.state.abandonConfirmKey != nil }
        host.flowActions?.abandon()
        await waitUntil { host.flow?.state.pending == nil }
        XCTAssertEqual(abandons.count, 1, "【确定放弃】恰一次")
        XCTAssertEqual(abandons.first?.json["action"] as? String, "payout_account_change")
    }

    /// 字段错误共用件（W50 / W82）：收款账号 20001 字段错误样式带 16 图标、字 14，读屏与定位不动。
    func testPayoutFieldErrorSharedStyle() async throws {
        let host = try await save(.envelope(code: 20001, data: "{\"fields\":[\"alipay_logon_id\"]}", headers: [:]))
        _ = await host
            .stable {
                !($0.flow?.state.fieldErrors.isEmpty ?? true) && $0
                    .probes["payout.fieldError.alipay_logon_id.text"] != nil
            }
        try assertBase("payout.fieldError.alipay_logon_id.text", 14, "字段错误 14")
        try assertNear(rect("payout.fieldError.alipay_logon_id.icon").width, 16, 1, "图标 16")
    }
}
