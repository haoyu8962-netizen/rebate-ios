@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// W36–W44、W46–W55 版式（画板 Withdraw / Calculating / EstimateFailed / RealName / PageStates / Submitting）。先正后反。
/// 缺测量即红（§4 测量桥）；数值取自画板 HTML（Withdraw.dc.html）与 brief §2.3。
@MainActor
final class WithdrawVisualLayoutTests: WithdrawVisualTestCase {
    /// W36：内容上 8、左右 16、块间 12。
    func testW36ContentInsets() async throws {
        try await openWithdraw()
        let top = try pageViewport().minY
        let balance = try rect("withdraw.balance")
        assertNear(balance.minY - top, 8, 1, "余额卡距导航栏")
        assertNear(balance.minX, 16, 0.5, "左 16")
        assertNear(390 - balance.maxX, 16, 0.5, "右 16")
        try assertNear(rect("withdraw.amountCard").minY - balance.maxY, 12, 1, "块间 12")
        try assertNear(rect("withdraw.payout").minY - rect("withdraw.amountCard").maxY, 12, 1, "块间 12")
    }

    /// W37：余额卡 标签 14 次文字 → 34/700 等宽大数 → 次数 12；卡内 8 / 4。
    func testW37BalanceCard() async throws {
        let (_, image) = try await openWithdraw()
        try assertBase("withdraw.balance.label", 14, "标签")
        try assertBase("withdraw.balance.amount", 34, "大数")
        try assertBase("withdraw.balance.counts", 12, "次数")
        XCTAssertEqual(try text("withdraw.balance.label"), "可提现余额")
        XCTAssertEqual(try text("withdraw.balance.amount"), WithdrawVisualData.money(1234), "只放金额，不带其他字")
        XCTAssertEqual(try text("withdraw.balance.counts"), "今日还可提 1 次，本月还可提 10 次")
        let label = try rect("withdraw.balance.label")
        let amount = try rect("withdraw.balance.amount")
        let counts = try rect("withdraw.balance.counts")
        XCTAssertLessThanOrEqual(label.maxY, amount.minY + 0.5, "标签在大数上")
        XCTAssertLessThanOrEqual(amount.maxY, counts.minY + 0.5, "大数在次数上")
        assertNear(amount.minY - label.maxY, 4, 2.5, "标签到大数 4")
        assertNear(counts.minY - amount.maxY, 8, 2.5, "大数到次数 8")
        XCTAssertTrue(inkMostly(image, in: label, CouliColor.textSecondary, not: CouliColor.textPrimary), "标签次文字")
        XCTAssertTrue(
            inkMostly(image, in: amount, CouliColor.textPrimary, not: CouliColor.brandEmphasis),
            "大数墨棕，不是返利强调色"
        )
    }

    /// W38：金额框视觉 56、「¥」17 次文字、输入 28 等宽；可输入时控件边 + 白底。
    func testW38AmountBox() async throws {
        let (_, image) = try await openWithdraw(amount: "10")
        let box = try rect("withdraw.amount.box")
        assertNear(box.height, 56, 1, "框高 56")
        try assertBase("withdraw.amount.sign", 17, "「¥」17")
        try assertBase("withdraw.amount.input", 28, "输入 28")
        XCTAssertEqual(try text("withdraw.amount.input"), "10")
        try assertInside(rect("withdraw.amount.input"), box, "输入在框内")
        try XCTAssertTrue(
            inkMostly(image, in: rect("withdraw.amount.sign"), CouliColor.textSecondary, not: CouliColor.textPrimary),
            "「¥」次文字（底版是墨棕粗体）"
        )
        try background(image, "withdraw.amount.box", CouliColor.backgroundSurface, "可输入白底")
    }

    /// W39 / W40：【全部提现】14 强调色、命中 ≥ 44；上限行 12。
    func testW39W40AllAndMaxLine() async throws {
        let (_, image) = try await openWithdraw()
        try assertBase("withdraw.all.label", 14, "【全部提现】14")
        try assertHit("withdraw.all.hit", covers: "withdraw.all", "【全部提现】")
        try XCTAssertTrue(sameRow(rect("withdraw.all"), rect("withdraw.amount.box")), "在金额框右侧")
        try XCTAssertTrue(
            inkMostly(image, in: rect("withdraw.all.label"), CouliColor.textLink, not: CouliColor.textPrimary), "强调色"
        )
        try assertBase("withdraw.max", 12, "上限行 12")
        XCTAssertEqual(try text("withdraw.max"), "本次最多可提 " + WithdrawVisualData.money(1200), "取 max_withdrawable_fen")
        try XCTAssertLessThanOrEqual(rect("withdraw.amount.box").maxY, rect("withdraw.max").minY + 0.5, "框 → 上限行")
    }

    /// W41：胶囊视觉 32（命中 ≥ 44 且包住视觉、不撑高）、14 等宽、只显示下发值、相邻命中区不重叠。
    func testW41QuickChips() async throws {
        let (_, image) = try await openWithdraw()
        XCTAssertEqual(try text("withdraw.quick.500.label"), WithdrawVisualData.money(500))
        XCTAssertEqual(try text("withdraw.quick.1000.label"), WithdrawVisualData.money(1000))
        XCTAssertFalse(has("withdraw.quick.1200"), "只显示下发值")
        for fen in [500, 1000] {
            let id = "withdraw.quick.\(fen)"
            try assertNear(rect(id).height, 32, 0.5, "\(id) 视觉 32")
            try assertHit(id + ".hit", covers: id, id)
            try assertBase(id + ".label", 14, id)
        }
        try assertDisjoint(rect("withdraw.quick.500.hit"), rect("withdraw.quick.1000.hit"), "命中区不重叠")
        try XCTAssertLessThanOrEqual(rect("withdraw.max").maxY, rect("withdraw.quick.500").minY + 0.5, "上限 → 档位")
        // 全圆角 + 浅边：左缘中点是边框色附近，四角是卡片白
        let chip = try rect("withdraw.quick.500")
        let pixels = ProductVisualPixels(image)
        XCTAssertTrue(pixels.color(at: CGPoint(x: chip.minX + 1, y: chip.minY + 1))
            .near(pixel(CouliColor.backgroundSurface, dark: false), tolerance: 12), "全圆角：角上是卡片底")
        let edge = pixels.row(at: chip.midY, from: chip.minX, to: chip.minX + 2)
        XCTAssertTrue(edge.contains { $0.near(pixel(CouliColor.borderSubtle, dark: false), tolerance: 14) }, "浅边框")
    }

    /// W42：有估算时 1 分隔线 + 一条文字（金额 17、问号 14 命中 ≥ 44 不撑高）；金额只取服务端字段。
    func testW42EstimateRow() async throws {
        let (_, image) = try await openWithdraw(amount: "10", estimate: "estimated")
        let divider = try rect("withdraw.divider")
        assertNear(divider.height, 1, 0.5, "分隔线 1")
        XCTAssertTrue(hasDivider(image, between: divider.minY - 1, and: divider.maxY + 1,
                                 span: divider.minX...divider.maxX), "实际画出分隔线")
        XCTAssertTrue(try text("withdraw.estimate").contains(WithdrawVisualData.money(1000)), "预计到账取 est_net_fen")
        try assertBase("withdraw.estimate", 14, "估算句 14")
        try assertBase("withdraw.estimate.net", 17, "到账金额 17")
        try XCTAssertLessThanOrEqual(rect("withdraw.estimate.help").width, 15, "问号视觉 14")
        try assertHit("withdraw.estimate.help.hit", covers: "withdraw.estimate.help", "问号")
        try XCTAssertLessThanOrEqual(rect("withdraw.estimate.row").height, 27, "视觉行高不被命中区撑高")
        try XCTAssertLessThan(rect("withdraw.quick.500").maxY, divider.minY + 0.5, "档位 → 分隔线")
    }

    /// 估算三项都来自服务端，不做加减（independent：10 → 到账 8.76 / 费 0.34 / 税 0.56，故意不满足加减关系）。
    func testW42EstimateIndependent() async throws {
        try await openWithdraw(amount: "10", estimate: "independent")
        let line = try text("withdraw.estimate")
        for fen in [Int64(876), 34, 56] {
            XCTAssertTrue(line.contains(WithdrawVisualData.money(fen)), "\(fen) 取服务端字段：\(line)")
        }
        XCTAssertFalse(line.contains(WithdrawVisualData.money(1000 - 34 - 56)), "不自行相减")
    }

    /// W43：计算中 16 转圈 +「计算中…」，分隔线保留（先有后无的「计算中」不写死）。
    func testW43Calculating() async throws {
        let host = try await freshPage(estimate: "estimated")
        host.server.setEstimateReply(.hold)
        try await host.show()
        _ = await host.stable { $0.controller?.state.phase == .content && $0.probes["withdraw.balance"] != nil }
        host.actions?.amount("10")
        _ = await host
            .stable(motion: true) {
                $0.controller?.state.estimate == .calculating && $0.probes["withdraw.calculating"] != nil
            }
        XCTAssertEqual(try text("withdraw.calculating"), "计算中…")
        try assertNear(rect("withdraw.calculating.spinner").width, 16, 1, "转圈 16")
        XCTAssertTrue(has("withdraw.divider"), "计算中分隔线保留")
        XCTAssertFalse(has("withdraw.estimate"), "不显示上一笔估算")
    }

    /// W44：估算隐藏（不下发 est_*）时分隔线一起隐藏，且不出错误条（WithdrawEstimateFailed）。先正（estimated 有分隔线，见 W42）。
    func testW44EstimateHiddenRemovesDivider() async throws {
        let (host, image) = try await openWithdraw(amount: "10")
        XCTAssertEqual(host.controller?.state.estimate, .hidden, "前提：est_* 为 null")
        XCTAssertFalse(has("withdraw.divider"), "分隔线一起隐藏")
        XCTAssertFalse(has("withdraw.estimate"), "估算行隐藏")
        let card = try rect("withdraw.amountCard")
        XCTAssertFalse(
            hasDivider(image, between: card.minY + 4, and: card.maxY - 4, span: (card.minX + 16)...(card.maxX - 16)),
            "金额卡内没有分隔线像素"
        )
    }

    /// W46：引导框进金额卡、金额框下；警告令牌底 + 20 图标 + 14 警告字色；描边按钮在文字下方，左缘对齐文字（WithdrawRealName）。
    func testW46GuideInsideAmountCard() async throws {
        let (_, image) = try await openWithdraw("blocked_30304", waitFor: "withdraw.guide")
        let guide = try rect("withdraw.guide")
        try assertInside(guide, rect("withdraw.amountCard"), "引导框在金额卡内")
        try XCTAssertLessThanOrEqual(rect("withdraw.amount.box").maxY, guide.minY + 0.5, "在金额框下")
        try background(image, "withdraw.guide", CouliColor.statusWarningBackground, minimum: 0.4, "警告令牌底")
        try assertNear(rect("withdraw.guide.icon").width, 20, 1, "图标 20")
        try assertBase("withdraw.guide.text", 14, "14")
        XCTAssertEqual(try text("withdraw.guide.text"), texts.text("error.30304"))
        let button = try rect("withdraw.guide.button")
        let label = try rect("withdraw.guide.text")
        XCTAssertLessThanOrEqual(label.maxY, button.minY + 0.5, "按钮在文字下方")
        assertNear(button.minX, label.minX, 1.5, "按钮左缘对齐文字")
        XCTAssertGreaterThanOrEqual(button.height, 43.5, "命中 44")
        XCTAssertLessThan(
            share(image, in: button.insetBy(dx: 4, dy: 4), near: pixel(CouliColor.brandPrimary, dark: false)),
            0.2,
            "描边，不是实底"
        )
    }

    /// W46 反面：纯提示码没有按钮（30301、30302、30306）；引导按钮只出现在该出的码上。
    func testW46NoticeOnlyCodesHaveNoButton() async throws {
        for name in ["blocked_30301", "blocked_30302", "blocked_30306", "blocked_account_frozen"] {
            try await openWithdraw(name, waitFor: "withdraw.guide.text")
            XCTAssertFalse(has("withdraw.guide.button"), "\(name)：纯提示无按钮")
            XCTAssertFalse(has("withdraw.guide.rules"), "\(name)：非 30309 不出规则按钮")
        }
        for name in ["blocked_30305", "blocked_10004"] {
            try await openWithdraw(name, waitFor: "withdraw.guide.button")
        }
    }

    /// W47 / G-W14：不能提现隐藏账号行、时效条、不可撤销句；正常空金额全在（不用 submitEnabled 判断的对照）。
    func testW47BlockedHidesThreeBlocks() async throws {
        try await openWithdraw()
        for id in ["withdraw.payout", "withdraw.sla", "withdraw.irrevocable"] {
            XCTAssertTrue(has(id), "正常空金额保留 \(id)")
        }
        for name in try WithdrawVisualData.pageStates() {
            try await openWithdraw(name, waitFor: "withdraw.guide.text")
            for id in ["withdraw.payout", "withdraw.sla", "withdraw.irrevocable"] {
                XCTAssertFalse(has(id), "\(name)：\(id) 隐藏")
            }
            XCTAssertTrue(has("withdraw.balance"), "\(name)：余额卡仍在")
        }
    }

    /// W48 / G-W15：30309 有配置才出【查看提现规则】，回调去向 = 页底规则链接；没配置不出。
    func testW48Code30309RulesButton() async throws {
        try await openWithdraw("blocked_30309", waitFor: "withdraw.guide.rules")
        try assertInside(rect("withdraw.guide.rules"), rect("withdraw.amountCard"), "按钮在金额卡内")
        XCTAssertEqual(try text("withdraw.guide.rules.label"), "查看提现规则")
        try await openWithdraw("blocked_30309", help: false, waitFor: "withdraw.guide.text")
        XCTAssertFalse(has("withdraw.guide.rules"), "无配置不出")
    }

    /// W51：收款账号行 白卡、左标签、账号靠右 + 20 ›、高 ≥ 44。
    func testW51PayoutRow() async throws {
        let (_, image) = try await openWithdraw()
        let row = try rect("withdraw.payout")
        XCTAssertGreaterThanOrEqual(row.height, 43.5)
        XCTAssertLessThanOrEqual(row.height, 62, "视觉 44 + 内边距 4 级，不撑成大块")
        XCTAssertEqual(try text("withdraw.payout.value"), "支付宝 138****5678")
        let value = try rect("withdraw.payout.value")
        let chevron = try rect("withdraw.payout.chevron")
        assertNear(chevron.width, 20, 1, "› 20")
        XCTAssertLessThanOrEqual(value.maxX, chevron.minX + 0.5)
        XCTAssertLessThanOrEqual(chevron.minX - value.maxX, 6, "账号贴着箭头（靠右），不是靠左")
        try XCTAssertLessThan(rect("withdraw.payout.label").minX, value.minX, "标签在左")
        try background(image, "withdraw.payout", CouliColor.backgroundSurface, "白卡")
    }

    /// W52：时效 INFO 条 + 不可撤销句 12 次文字缩进 4。
    func testW52SlaAndIrrevocable() async throws {
        let (_, image) = try await openWithdraw(sla: "预计几分钟内到账")
        XCTAssertEqual(try text("withdraw.sla.text"), "预计几分钟内到账", "按配置取值")
        try assertBase("withdraw.sla.text", 14, "14")
        try assertNear(rect("withdraw.sla.icon").width, 20, 1, "图标 20")
        try background(image, "withdraw.sla", CouliColor.backgroundMuted, minimum: 0.4, "INFO 底")
        try assertBase("withdraw.irrevocable", 12, "12（底版 14）")
        XCTAssertEqual(try text("withdraw.irrevocable"), texts.text("withdraw.irrevocable"))
        try assertNear(rect("withdraw.irrevocable").minX, rect("withdraw.sla").minX + 4, 1, "缩进 4")
        try XCTAssertLessThanOrEqual(rect("withdraw.sla").maxY, rect("withdraw.irrevocable").minY + 0.5, "时效 → 不可撤销")
    }

    /// W53：底栏无底色；【提交】通栏 ≥ 48；「提现规则」视觉 21、命中 ≥ 44、不压【提交】；没配置不出（G26）。
    func testW53BottomBar() async throws {
        let (_, image) = try await openWithdraw()
        let bar = try rect("withdraw.bottom")
        let submit = try rect("withdraw.submit")
        assertNear(submit.width, 358, 1, "通栏")
        XCTAssertGreaterThanOrEqual(submit.height, 47.5)
        // 底栏左边距内的像素：无底色 = 画布色（不是卡片白）
        let probe = CGRect(x: bar.minX + 2, y: bar.minY + 2, width: 10, height: max(bar.height - 4, 4))
        XCTAssertGreaterThan(
            share(image, in: probe, near: pixel(CouliColor.backgroundCanvas, dark: false), tolerance: 4),
            0.9,
            "底栏透出画布色（底版是卡片白）"
        )
        let link = try rect("withdraw.rulesLink")
        XCTAssertLessThanOrEqual(link.height, 22, "视觉 21（底版 44）")
        try assertHit("withdraw.rulesLink.hit", covers: "withdraw.rulesLink", "规则链接")
        try assertDisjoint(rect("withdraw.rulesLink.hit"), submit, "命中区不压【提交】")
        try assertBase("withdraw.rulesLink.label", 14, "14")
        XCTAssertTrue(inkMostly(image, in: link, CouliColor.textLink, not: CouliColor.textPrimary), "链接色")
        try await openWithdraw(help: false)
        XCTAssertFalse(has("withdraw.rulesLink"), "没配置不出")
        XCTAssertTrue(has("withdraw.submit"), "【提交】仍在")
    }

    /// W54：提交中按钮 loading「提交中…」；金额框灰底浅边、档位灰底次文字、【全部提现】次文字（WithdrawSubmitting）。
    func testW54Submitting() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated")
        host.server.script.on("POST /v1/withdrawals", .hold)
        host.actions?.submit()
        let image = await host
            .stable(motion: true) { $0.flow?.state.phase == .submitting && $0.probes["withdraw.submit.label"] != nil }
        let shot = try XCTUnwrap(image)
        XCTAssertEqual(try text("withdraw.submit.label"), "提交中…")
        try background(shot, "withdraw.amount.box", CouliColor.backgroundMuted, "金额框灰底")
        try background(shot, "withdraw.quick.500", CouliColor.backgroundMuted, minimum: 0.4, "档位灰底")
        try XCTAssertTrue(
            inkMostly(
                shot,
                in: rect("withdraw.quick.500.label"),
                CouliColor.textSecondary,
                not: CouliColor.textPrimary
            ),
            "档位次文字"
        )
        try XCTAssertTrue(
            inkMostly(shot, in: rect("withdraw.all.label"), CouliColor.textSecondary, not: CouliColor.textLink),
            "全部提现次文字"
        )
        XCTAssertEqual(submits.count, 1, "恰一次")
    }
}
