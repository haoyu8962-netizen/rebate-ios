@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// §2.7 状态矩阵的页面级状态：待确认卡在三种 phase 都显示（共性第 2、67、76 条，brief §9 第 6 条）、加载 / 读取失败、深色令牌、840 限宽。
@MainActor
final class WithdrawVisualStateTests: WithdrawVisualTestCase {
    /// 前一个组合进入待确认（本机未决记录留在同一后端），新组合冷启动进页，rules 按 `first` 回答。
    private func coldStartPending(first: WalletStubProtocol.Reply?,
                                  needProbes: Bool) async throws -> WithdrawVisualHost {
        try await openWithdraw(estimate: "estimated", needProbes: false)
        try await enterPending()
        let host = try await freshPage(estimate: "estimated")
        host.server.setFirst(first)
        try await host.show()
        // 待确认记录由 refreshPending 异步读回；rules 挂起时页面有转圈，不比像素
        _ = await host.stable(motion: true) {
            $0.flow?.state.pending != nil && (!needProbes || $0.probes["pending.alert"] != nil)
        }
        return host
    }

    /// 守卫（底版绿）：rules 加载中 / 读取失败时待确认卡的按钮照常可用（只看执行层，不等测量）。
    func testPendingUsableWhileRulesLoadingOrFailed() async throws {
        let loading = try await coldStartPending(first: .hold, needProbes: false)
        XCTAssertEqual(loading.controller?.state.phase, .loading)
        XCTAssertEqual(loading.flow?.state.pendingActionsEnabled, true, "加载中确认 / 放弃可用")
        let failed = try await coldStartPending(
            first: .envelope(code: 50001, data: "null", headers: [:]),
            needProbes: false
        )
        await waitUntil("没有进读取失败") { failed.controller?.state.phase == .error }
        XCTAssertEqual(failed.flow?.state.pendingActionsEnabled, true, "读取失败确认 / 放弃可用")
    }

    /// 视觉：三种 phase 都有同一张卡（提示块 + 两按钮）。
    func testPendingCardInAllPhases() async throws {
        let content = try await coldStartPending(first: nil, needProbes: true)
        _ = content
        XCTAssertTrue(has("pending.alert"))
        XCTAssertTrue(has("pending.abandon"))
        _ = try await coldStartPending(first: .hold, needProbes: true)
        XCTAssertTrue(has("pending.alert"), "加载中")
        _ = try await coldStartPending(first: .envelope(code: 50001, data: "null", headers: [:]), needProbes: true)
        XCTAssertTrue(has("pending.confirm"), "读取失败")
    }

    /// 无稿：提现页读取失败（ErrorState、不显示 ¥0）、重试只多一次 rules。
    func testReadErrorNotZeroFilledRetryOnce() async throws {
        let host = try await freshPage()
        host.server.setFirst(.envelope(code: 50001, data: "null", headers: [:]))
        try await host.show()
        await waitUntil("没有进读取失败") { host.controller?.state.phase == .error }
        XCTAssertNil(host.controller?.state.rules, "金额 null 不补 0")
        XCTAssertFalse(pageTexts.contains { $0.contains(WithdrawVisualData.money(0)) }, "不显示 ¥0")
        host.server.setFirst(nil)
        let before = WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count
        host.actions?.retry()
        await waitUntil("重试没有恢复") { host.controller?.state.phase == .content }
        XCTAssertEqual(WalletStubProtocol.requests("GET", "/v1/withdrawals/rules").count, before + 1, "重试只多一次 rules")
    }

    /// W55 深色令牌（WithdrawDark）：画布、白卡面、链接色、底栏透出画布色。
    func testW55DarkTokens() async throws {
        let (_, image) = try await openWithdraw(
            amount: "10",
            estimate: "estimated",
            canvas: .init(height: 1119, dark: true)
        )
        try background(image, "withdraw.balance", CouliColor.backgroundSurface, dark: true, "卡片深色面")
        try XCTAssertGreaterThan(
            count(image, in: rect("withdraw.all.label"), near: pixel(CouliColor.textLink, dark: true), tolerance: 30),
            10,
            "【全部提现】深色链接色"
        )
        let bar = try rect("withdraw.bottom")
        let strip = CGRect(x: bar.minX + 2, y: bar.minY + 2, width: 10, height: max(bar.height - 4, 4))
        XCTAssertGreaterThan(
            share(image, in: strip, near: pixel(CouliColor.backgroundCanvas, dark: true), tolerance: 4),
            0.9,
            "底栏无底色"
        )
        try background(image, "withdraw.sla", CouliColor.backgroundMuted, dark: true, minimum: 0.4, "INFO 深色底")
    }

    /// 深色下警告提示块、禁用框走令牌（待确认卡）。
    func testW56DarkPendingTokens() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", canvas: .init(height: 1119, dark: true))
        try await enterPending()
        let image = await host.stable { $0.flow?.state.pending != nil && $0.probes["pending.alert"] != nil }
        let shot = try XCTUnwrap(image)
        try background(shot, "pending.alert", CouliColor.statusWarningBackground, dark: true, minimum: 0.35, "深色警告底")
        try background(shot, "withdraw.amount.box", CouliColor.backgroundMuted, dark: true, "待确认时框禁用灰底")
    }

    /// 840：内容限宽 600 居中；卡内 568；【提交】568；底栏铺满。
    func testW840ContentWidth() async throws {
        try await openWithdraw(canvas: .init(width: 840, height: 1000))
        let card = try rect("withdraw.balance")
        assertNear(card.width, 568, 1, "内容 600 − 边距 32")
        assertNear(card.midX, 420, 1, "居中")
        try assertNear(rect("withdraw.submit").width, 568, 1, "【提交】同宽")
        try assertNear(rect("withdraw.bottom").width, 840, 1, "底栏铺满")
    }
}
