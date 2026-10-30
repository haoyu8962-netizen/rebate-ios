@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
@testable import Wallet
import WalletCore
import XCTest

/// W56–W62（画板 WithdrawPendingConfirm / Busy / Still、WithdrawBlocked、WithdrawAbandonConfirm）：待确认卡、两个弹窗、轻提示的版式。
/// 回调次数的真点在 `WithdrawVisualUITests`；这里的「执行层」断言都用页面同一份渲染时回调。
@MainActor
final class WithdrawVisualPendingTests: WithdrawVisualTestCase {
    private func openPending(canvas: WithdrawVisualHost.Canvas = .init(),
                             waitFor: String = "pending.alert") async throws -> (WithdrawVisualHost, UIImage) {
        let (host, _) = try await openWithdraw(estimate: "estimated", canvas: canvas)
        try await enterPending()
        let image = await host.stable { $0.flow?.state.pending != nil && $0.probes[waitFor] != nil }
        return try (host, XCTUnwrap(image))
    }

    /// W56：白卡 → 警告提示块（20 图标、标题 14、说明 14、警告令牌底）→ 两等宽按钮（放弃描边 / 确认主）；提现无明细块。
    func testW56CardStructure() async throws {
        let (_, image) = try await openPending()
        let card = try rect("pending.card")
        let alert = try rect("pending.alert")
        try assertInside(alert, card, "提示块在卡内")
        assertNear(alert.minX - card.minX, 16, 1, "卡内边距 16")
        try background(
            image,
            "pending.alert",
            CouliColor.statusWarningBackground,
            minimum: 0.35,
            "警告令牌底（底版是字色 × 0.1 的近似）"
        )
        // 卡外缘是白卡，不是警告色（整卡警告底是 Android 改前的问题）
        let strip = CGRect(x: card.minX + 2, y: card.midY, width: 6, height: 20)
        XCTAssertGreaterThan(
            share(image, in: strip, near: pixel(CouliColor.backgroundSurface, dark: false), tolerance: 4),
            0.9
        )
        try assertNear(rect("pending.icon").width, 20, 1, "图标 20")
        try assertBase("pending.title", 14, "标题 14")
        try assertBase("pending.desc", 14, "说明 14")
        XCTAssertEqual(try text("pending.title"), texts.text("pending_confirm.title"))
        XCTAssertTrue(try text("pending.desc").contains(WithdrawVisualData.money(1000)), "金额取未决记录")
        XCTAssertTrue(try text("pending.desc").contains("138****5678"), "账号取服务端当前绑定脱敏串")
        let abandon = try rect("pending.abandon")
        let confirm = try rect("pending.confirm")
        XCTAssertTrue(sameRow(abandon, confirm), "默认字号同一行")
        assertNear(abandon.width, confirm.width, 1, "两等宽")
        XCTAssertLessThan(abandon.minX, confirm.minX, "放弃在左")
        XCTAssertGreaterThanOrEqual(abandon.height, 47.5)
        XCTAssertGreaterThanOrEqual(alert.maxY, card.minY)
        XCTAssertLessThanOrEqual(alert.maxY, abandon.minY + 0.5, "提示块 → 按钮")
        XCTAssertFalse(has("pending.detail"), "提现待确认无明细块（画板同）")
    }

    /// W57：注释 12 与「查看提现记录 ›」同一行；链接 14 强调色、命中 ≥ 44。
    func testW57NoteAndRecordsLinkSameRow() async throws {
        let (_, image) = try await openPending(waitFor: "pending.records")
        let note = try rect("pending.note")
        let link = try rect("pending.records")
        try assertBase("pending.note", 12, "注释 12（底版 14）")
        try assertBase("pending.records.label", 14, "链接 14")
        XCTAssertTrue(sameRow(note, link), "同一行")
        XCTAssertLessThan(note.maxX, link.minX + 0.5, "注释左、链接右")
        try assertHit("pending.records.hit", covers: "pending.records", "查看提现记录")
        XCTAssertTrue(inkMostly(image, in: link, CouliColor.textLink, not: CouliColor.textPrimary), "强调色")
    }

    /// W58：忙碌 两按钮置灰、不转圈在按钮内，状态行 16 转圈 +「正在处理，请稍候」。
    func testW58Busy() async throws {
        let (host, _) = try await openPending()
        host.server.script.on("POST /v1/withdrawals", .hold)
        host.flowActions?.confirm()
        let shot = await host.stable(motion: true) {
            $0.flow?.state.pendingCardBusy == true && $0.probes["pending.busy"] != nil
        }
        XCTAssertEqual(try text("pending.busy.text"), texts.text("error.40901"))
        try assertNear(rect("pending.busy.spinner").width, 16, 1, "转圈 16")
        try assertBase("pending.busy.text", 14, "14")
        let image = try XCTUnwrap(shot)
        try XCTAssertLessThan(share(image, in: rect("pending.confirm").insetBy(dx: 6, dy: 6),
                                    near: pixel(CouliColor.brandPrimary, dark: false)), 0.1, "置灰，不再是主色实底")
        XCTAssertEqual(host.flow?.state.pendingActionsEnabled, false, "两按钮不可用")
    }

    /// W59 / G-W17：40901 / retry_later / cannot_confirm 是卡内警告提示块。
    func testW59NoticeBlock() async throws {
        let (host, _) = try await openPending()
        host.server.script.fail("POST /v1/withdrawals", 40901)
        host.flowActions?.confirm()
        let shot = await host.stable { $0.flow?.state.pendingNotice != nil && $0.probes["pending.noticeBlock"] != nil }
        let image = try XCTUnwrap(shot)
        try background(image, "pending.noticeBlock", CouliColor.statusWarningBackground, minimum: 0.35, "警告提示块")
        XCTAssertEqual(try text("pending.noticeBlock.text"), host.flow?.state.pendingNotice.map { texts.text($0.key) })
        try assertInside(rect("pending.noticeBlock"), rect("pending.card"), "在卡内")
    }

    /// W60 / G-W16：44001 标题居中；【联系客服申诉】主（右）、【知道了】次（左）。
    func testW60RiskDialogSlots() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
        host.server.script.fail("POST /v1/withdrawals", 44001, data: "{\"risk_msg_code\":\"fixture_unlisted_reason\"}")
        host.actions?.submit()
        let shot = await host.stable { $0.flow?.state.riskDialog != nil && $0.probes["flow.dialog.primary"] != nil }
        try assertDialog(XCTUnwrap(shot), primary: "联系客服申诉", secondary: "知道了")
        XCTAssertEqual(try text("flow.dialog.title"), texts.text("error.44001"))
    }

    /// W61 / G-W16：放弃确认 标题居中；灰底明细（标签左值右）；【再想想】主（右）、【确定放弃】次（左）。
    func testW61AbandonDialogSlotsAndDetail() async throws {
        let (host, _) = try await openPending()
        host.flowActions?.askAbandon()
        let shot = await host
            .stable { $0.flow?.state.abandonConfirmKey != nil && $0.probes["flow.dialog.primary"] != nil }
        let image = try XCTUnwrap(shot)
        try assertDialog(image, primary: "再想想", secondary: "确定放弃")
        try background(image, "abandon.detail", CouliColor.backgroundMuted, minimum: 0.4, "灰底明细块")
        XCTAssertEqual(try text("abandon.detail.0.label"), texts.text("pending_confirm.withdraw.amount_label"))
        XCTAssertEqual(try text("abandon.detail.0.value"), WithdrawVisualData.money(1000))
        XCTAssertEqual(try text("abandon.detail.1.label"), texts.text("pending_confirm.payout_label"))
        XCTAssertEqual(try text("abandon.detail.1.value"), "支付宝 138****5678")
        try XCTAssertLessThan(rect("abandon.detail.0.label").maxX, rect("abandon.detail.0.value").minX + 0.5, "标签左值右")
        XCTAssertEqual(abandons.count, 0, "打开弹窗零请求")
    }

    private func assertDialog(_ image: UIImage, primary: String, secondary: String, file: StaticString = #filePath,
                              line: UInt = #line) throws {
        let panel = try rect("flow.dialog.panel", file: file, line: line)
        let title = try rect("flow.dialog.title", file: file, line: line)
        let left = try XCTUnwrap(
            inkLeft(
                ProductVisualPixels(image),
                in: title,
                background: pixel(CouliColor.backgroundSurface, dark: false)
            ),
            file: file,
            line: line
        )
        let right = try XCTUnwrap(
            inkRight(
                ProductVisualPixels(image),
                in: title,
                background: pixel(CouliColor.backgroundSurface, dark: false)
            ),
            file: file,
            line: line
        )
        assertNear((left + right) / 2, panel.midX, 3, "标题居中", file: file, line: line)
        XCTAssertEqual(try text("flow.dialog.primary", file: file, line: line), primary, file: file, line: line)
        XCTAssertEqual(try text("flow.dialog.secondary", file: file, line: line), secondary, file: file, line: line)
        let primaryFrame = try rect("flow.dialog.primary", file: file, line: line)
        let secondaryFrame = try rect("flow.dialog.secondary", file: file, line: line)
        XCTAssertTrue(sameRow(primaryFrame, secondaryFrame), "默认字号同一行", file: file, line: line)
        XCTAssertLessThan(secondaryFrame.minX, primaryFrame.minX, "主按钮在右", file: file, line: line)
        XCTAssertGreaterThan(
            share(image, in: primaryFrame.insetBy(dx: 4, dy: 8).divided(atDistance: 8, from: .minXEdge).slice,
                  near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 12),
            0.8,
            "\(primary) 是主按钮实底",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            share(image, in: secondaryFrame.insetBy(dx: 4, dy: 8).divided(atDistance: 8, from: .minXEdge).slice,
                  near: pixel(CouliColor.brandPrimary, dark: false), tolerance: 12),
            0.1,
            "\(secondary) 不是实底",
            file: file,
            line: line
        )
    }

    /// 遮罩令牌（Android r1 S2-1 提前覆盖）：弹窗外左上角像素 = 画布色叠 overlay.scrim。不依赖测量桥；浅、深各一次。
    func testScrimTokenOverCanvas() async throws {
        for dark in [false, true] {
            let (host, _) = try await openWithdraw(
                amount: "10",
                estimate: "estimated",
                canvas: .init(dark: dark),
                needProbes: false
            )
            host.server.script.fail("POST /v1/withdrawals", 44001)
            host.actions?.submit()
            let shot = await host.stable { $0.flow?.state.riskDialog != nil }
            let image = try XCTUnwrap(shot)
            let canvas = pixel(CouliColor.backgroundCanvas, dark: dark)
            let scrim = pixel(dark ? .black : CouliColor.textPrimary, dark: dark)
            let alpha = dark ? 0x8C / 255.0 : 0.4
            func mix(_ under: Int, _ over: Int) -> Int {
                Int((Double(under) * (1 - alpha) + Double(over) * alpha).rounded())
            }
            let expected = ProductVisualPixels.RGB(
                red: mix(canvas.red, scrim.red), green: mix(canvas.green, scrim.green), blue: mix(
                    canvas.blue,
                    scrim.blue
                )
            )
            let actual = ProductVisualPixels(image).color(at: CGPoint(x: 6, y: 20))
            XCTAssertTrue(actual.near(expected, tolerance: 3), "dark=\(dark)：遮罩 \(actual) ≠ 令牌合成 \(expected)")
        }
    }

    /// W62：已放弃 对勾绿；已经处理完成 信息图标次文字色（`Notice.toast` 的图标映射；位置不变，G-W18）。
    func testW62ToastIconMapping() {
        let done = Notice(SensitiveOutcome.abandonedKey, id: 1).toast(texts)
        XCTAssertEqual(done.icon, .success, "已放弃保持对勾绿")
        let completed = Notice(SensitiveOutcome.alreadyDoneKey, id: 2).toast(texts)
        XCTAssertEqual(completed.icon, .info, "已经处理完成：信息图标（底版是成功勾）")
        XCTAssertEqual(completed.text, texts.text(SensitiveOutcome.alreadyDoneKey), "文字不变")
    }

    /// 放弃恰一次请求、不重发提交（执行层回归；真点在 UI 测试）。
    func testW62AbandonOnceAndNoResubmit() async throws {
        let (host, _) = try await openWithdraw(estimate: "estimated", needProbes: false)
        try await enterPending()
        host.flowActions?.askAbandon()
        await waitUntil { host.flow?.state.abandonConfirmKey != nil }
        host.flowActions?.abandon()
        await waitUntil("没有回到可编辑") { host.flow?.state.pending == nil && host.flow?.state.phase == .editing }
        XCTAssertEqual(abandons.count, 1)
        XCTAssertEqual(submits.count, 1, "放弃不重发提交")
    }
}
