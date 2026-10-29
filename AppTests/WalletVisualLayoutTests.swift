@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-a 钱包页结构 / 几何 / 像素（brief §2.1，W1–W17 的 iOS 对应项；Android 测试交回 v1 / v2 与评审 r1 回归点）。
/// 测量全部来自生产组件经 `couliLayoutProbe` 上报（§2 测量桥），文字取测量里的显示文字，颜色按截图像素核对令牌。
@MainActor
final class WalletVisualLayoutTests: WalletVisualTestCase {
    // MARK: - 主卡（W1–W3）

    /// W1：冻结中 / 已提现在主卡底部（主卡框内），白字令牌，标签 14、数值 17；冻结中带问号（视觉 ≤ 16，命中 ≥ 44）。
    func testFrozenAndWithdrawnInsideHeroWhite() async throws {
        let (_, image) = try await openWallet("frozen")
        let hero = try rect("wallet.hero")
        for id in ["wallet.hero.frozen", "wallet.hero.withdrawn"] {
            assertInside(try rect(id), hero, "\(id) 在主卡内（不再另起白卡）")
            try assertBase("\(id).label", 14, "\(id) 标签")
            try assertBase("\(id).value", 17, "\(id) 数值")
        }
        XCTAssertEqual(try text("wallet.hero.frozen.value"), WalletVisualData.money(1000))
        XCTAssertEqual(try text("wallet.hero.withdrawn.value"), WalletVisualData.money(500))
        XCTAssertEqual(try text("wallet.hero.amount"), WalletVisualData.money(234), "主卡大数 = withdrawable_fen")
        XCTAssertTrue(sameRow(try rect("wallet.hero.frozen.value"), try rect("wallet.hero.withdrawn.value")), "两格并排")
        let white = pixel(CouliColor.token("rebate.solid.text"), dark: false)
        XCTAssertGreaterThan(count(image, in: try rect("wallet.hero.frozen.value"), near: white), 20, "冻结中数值白字")
        let help = try rect("wallet.hero.frozen.help")
        XCTAssertLessThanOrEqual(max(help.width, help.height), 16.5, "问号视觉 14（不被命中区撑大）")
        try assertHit("wallet.hero.frozen.help.hit", covers: "wallet.hero.frozen.help", "冻结中问号")
    }

    /// W2 / W12：主卡首行视觉不被 44 命中区撑高（≤ 24），首行到金额行 16 ± 3；眼睛与「提现记录」命中 ≥ 44、互不重叠。
    func testHeroHeaderCompactAndGap16() async throws {
        try await openWallet("normal")
        let row = try rect("wallet.hero.titleRow")
        XCTAssertLessThanOrEqual(row.height, 24, "首行视觉高（14 号一行），不被命中区撑高")
        try assertBase("wallet.hero.title", 14, "可提现余额标签")
        assertNear(try rect("wallet.hero.amount").minY - row.maxY, 16, 3, "首行 → 金额行间距 16")
        try assertHit("wallet.hero.eye.hit", covers: "wallet.hero.eye", "眼睛")
        try assertHit("wallet.hero.records.hit", covers: "wallet.hero.records", "提现记录 ›")
        assertDisjoint(try rect("wallet.hero.eye.hit"), try rect("wallet.hero.records.hit"), "眼睛 / 提现记录命中区")
        assertDisjoint(try rect("wallet.hero.records.hit"), try rect("wallet.hero.withdraw"), "提现记录 / 【提现】")
    }

    /// W3：【提现】最小宽 96、视觉高 48、字 17；与大数同行。
    func testWithdrawButtonMinWidth96Height48() async throws {
        try await openWallet("normal")
        let button = try rect("wallet.hero.withdraw")
        XCTAssertGreaterThanOrEqual(button.width, 95.5, "【提现】最小宽 96")
        assertNear(button.height, 48, 1, "【提现】视觉高")
        try assertBase("wallet.hero.withdraw.label", 17, "【提现】字号")
        XCTAssertTrue(sameRow(button, try rect("wallet.hero.amount")), "与大数同行")
        try assertBase("wallet.hero.amount", 34, "大数")
    }

    // MARK: - 主卡下警告条（W4、W5，G-W06）

    /// W4：待抵扣在主卡**外**下方、预估卡之前；两行「待抵扣 ¥5.67」+ error.30302；警告浅底、警告字色、20 图标。
    func testNegativeStripBelowHeroTwoLines() async throws {
        let (page, image) = try await openWallet("negative", waitFor: "wallet.negative")
        let hero = try rect("wallet.hero")
        let strip = try rect("wallet.negative")
        assertDisjoint(strip, hero, "待抵扣条不在主卡里")
        XCTAssertGreaterThanOrEqual(strip.minY, hero.maxY - 0.5, "在主卡下方")
        XCTAssertLessThanOrEqual(strip.maxY, try rect("wallet.estimate").minY + 0.5, "在预估卡之前")
        XCTAssertEqual(try text("wallet.negative.line1"), "待抵扣 " + WalletVisualData.money(567), "首行（G-W06）")
        XCTAssertEqual(try text("wallet.negative.line2"), texts.text("error.30302"), "次行取契约键 error.30302")
        XCTAssertFalse(allTexts.contains { $0.contains("后续返利将优先抵扣") }, "旧句不再出现")
        try assertBase("wallet.negative.line1", 14, "首行")
        let icon = try rect("wallet.negative.icon")
        assertNear(icon.width, 20, 1, "图标 20")
        try assertWarningStrip(image, strip, "待抵扣条")
        XCTAssertFalse(try XCTUnwrap(page.controller).state.withdrawEnabled, "置灰判定不变")
    }

    /// W5：30306 单独一条、在主卡外下方、警告色；只出现一次；【提现】置灰。
    func testFeatureOffStripOutsideHero() async throws {
        let (page, image) = try await openWallet("disabled", waitFor: "wallet.disabledReason")
        let strip = try rect("wallet.disabledReason")
        assertDisjoint(strip, try rect("wallet.hero"), "30306 条不在主卡里")
        XCTAssertGreaterThanOrEqual(strip.minY, try rect("wallet.hero").maxY - 0.5)
        let reason = texts.text("error.30306")
        XCTAssertEqual(try text("wallet.disabledReason.text"), reason)
        XCTAssertEqual(allTexts.filter { $0.contains(reason) }.count, 1, "30306 只出现一次")
        try assertWarningStrip(image, strip, "30306 条")
        XCTAssertFalse(try XCTUnwrap(page.controller).state.withdrawEnabled)
    }

    /// W6 / W7（G-W03）：风控条两行都是警告字色、首行「提现已暂停」不拼原因码与到期时间；20 图标与 › ；整条命中 ≥ 44；在主卡之上。
    func testRiskBarTwoLinesWarningWithChevron() async throws {
        let (_, image) = try await openWallet("risk", waitFor: "wallet.risk")
        let bar = try rect("wallet.risk")
        XCTAssertLessThanOrEqual(bar.maxY, try rect("wallet.hero").minY + 0.5, "在主卡之上")
        XCTAssertEqual(try text("wallet.risk.title"), texts.text(WalletSummaryView.riskPausedKey))
        XCTAssertEqual(try text("wallet.risk.hint"), texts.text("wallet.risk_hint"))
        XCTAssertFalse(allTexts.contains { $0.contains("fixture_unlisted_reason") }, "不显示原因码原文")
        try assertBase("wallet.risk.title", 14, "首行")
        try assertBase("wallet.risk.hint", 14, "次行 14（不是 12）")
        assertNear(try rect("wallet.risk.icon").width, 20, 1, "图标 20")
        assertNear(try rect("wallet.risk.chevron").width, 20, 1.5, "› 20")
        XCTAssertGreaterThanOrEqual(bar.height, 43.5, "整条可点，命中 ≥ 44")
        try assertWarningStrip(image, bar, "风控条")
        let ink = pixel(CouliColor.statusWarningText, dark: false)
        XCTAssertGreaterThan(count(image, in: try rect("wallet.risk.hint"), near: ink), 15, "次行也是警告字色（不是灰）")
        XCTAssertEqual(nonSummaryRequests, [], "不取 getMe（G-W03）、不预取 rules")
    }

    /// W8 / G-W05：断网条在最前（风控条之前）、紧贴导航栏、断网图标、带「09:30」；【提现】置灰。
    func testStaleBarFirstWithWifiSlash() async throws {
        let (page, image) = try await openStale("risk")
        let stale = try rect("wallet.stale")
        XCTAssertLessThanOrEqual(stale.maxY, try rect("wallet.risk").minY + 0.5, "断网条在风控条之前")
        XCTAssertLessThanOrEqual(stale.minY, 54 + 44 + 12, "紧贴导航栏（安全区 54 + 导航栏 44 + 至多 12）")
        XCTAssertTrue(try text("wallet.stale.text").contains("09:30"), "缓存时刻")
        let icon = try rect("wallet.stale.icon")
        assertNear(icon.width, 20, 1, "图标 20")
        let found = await nearestIcon(image, in: icon,
                                      candidates: ["wifi.slash", "exclamationmark.triangle", "info.circle"],
                                      background: CouliColor.token("status.warning.background"),
                                      ink: CouliColor.statusWarningText)
        XCTAssertEqual(found, "wifi.slash", "断网图标（不是三角 / i）")
        try assertWarningStrip(image, stale, "断网条")
        XCTAssertFalse(try XCTUnwrap(page.controller).state.withdrawEnabled, "旧数据置灰（G-W05 维持）")
    }

    // MARK: - 预估区（W9–W12，G-W04、G-W07）

    /// W9：两列——左钟表 +「预估收益」+ 问号（返利色）、¥56.78（22，返利色）、「其中已收货 ¥34.56」（12）；右「最早预计」（12）+「10 月结算」（22，主文字色）。
    func testEstimateTwoColumns() async throws {
        let (_, image) = try await openWallet("normal", waitFor: "wallet.estimate")
        XCTAssertEqual(try text("wallet.estimate.left.value"), WalletVisualData.money(5678), "estimated_total_fen 原值")
        XCTAssertEqual(try text("wallet.estimate.left.note"), "其中已收货 " + WalletVisualData.money(3456))
        try assertBase("wallet.estimate.left.label", 14, "预估收益标签")
        try assertBase("wallet.estimate.left.value", 22, "预估金额")
        try assertBase("wallet.estimate.left.note", 12, "已收货附注")
        XCTAssertEqual(try text("wallet.estimate.right.label"), texts.text("wallet.earliest_label"))
        let month = try text("wallet.estimate.right.value")
        XCTAssertTrue(month.contains("10") && month.hasSuffix("结算"), "右列「10 月结算」：\(month)")
        try assertBase("wallet.estimate.right.label", 12, "最早预计标签")
        try assertBase("wallet.estimate.right.value", 22, "月份")
        let left = try rect("wallet.estimate.left.value")
        let right = try rect("wallet.estimate.right.value")
        XCTAssertTrue(sameRow(left, right), "两列数值同行对齐")
        XCTAssertLessThan(left.maxX, right.minX, "左预估、右月份")
        XCTAssertEqual(try text("wallet.paused.text"), "其中 " + WalletVisualData.money(456) + " 暂缓入账")
        let rebate = pixel(CouliColor.rebateText, dark: false)
        let primary = pixel(CouliColor.textPrimary, dark: false)
        XCTAssertGreaterThan(count(image, in: left, near: rebate), 30, "预估金额返利色")
        XCTAssertGreaterThan(count(image, in: right, near: primary), 30, "月份主文字色")
        XCTAssertLessThan(count(image, in: right, near: rebate), 5, "月份不用返利色")
        let clock = try rect("wallet.estimate.left.icon")
        let found = await nearestIcon(image, in: clock, candidates: ["clock", "info.circle", "questionmark.circle"],
                                      background: CouliColor.backgroundSurface, ink: CouliColor.rebateText)
        XCTAssertEqual(found, "clock", "标签前钟表")
        try assertHit("wallet.estimate.left.help.hit", covers: "wallet.estimate.left.help", "预估收益问号")
    }

    /// W10（G-W07）：入账核对中放右列「结算进度 / 入账核对中」（22），不再是单独一行，不造月份。
    func testOverdueRightColumn() async throws {
        try await openWallet("overdue", waitFor: "wallet.estimate")
        XCTAssertEqual(try text("wallet.estimate.right.label"), "结算进度", "草稿 wallet.settle_progress（G-W07）")
        XCTAssertEqual(try text("wallet.estimate.right.value"), texts.text("wallet.overdue"))
        try assertBase("wallet.estimate.right.value", 22, "入账核对中")
        XCTAssertTrue(sameRow(try rect("wallet.estimate.left.value"), try rect("wallet.estimate.right.value")))
        XCTAssertFalse(allTexts.contains { $0.hasSuffix("结算") }, "没有月份就不造月份")
        XCTAssertNil(host?.probes["wallet.overdue"], "旧的单独一行不再出现")
    }

    /// W11（G-W04 维持）：已收货为 0 照常显示 ¥0；没有月份、不逾期时只有左列，不造「核对中」或月份；暂缓为 0 不出暂缓条。
    func testReceivedZeroKeptNoRightColumn() async throws {
        try await openWallet("received_zero", waitFor: "wallet.estimate")
        XCTAssertEqual(try text("wallet.estimate.left.note"), "其中已收货 " + WalletVisualData.money(0))
        XCTAssertNil(host?.probes["wallet.estimate.right"], "无月份、不逾期：没有右列")
        XCTAssertNil(host?.probes["wallet.paused"], "暂缓为 0 不出条")
        try await openWallet("no_month", waitFor: "wallet.estimate")
        XCTAssertNil(host?.probes["wallet.estimate.right"], "next_credit_period=null：没有右列")
        XCTAssertNotNil(host?.probes["wallet.paused"], "暂缓 > 0 照常")
    }

    /// W12：带问号的标签行视觉不被命中区撑高（≤ 24）；暂缓条高 = 文字 + 上下 8（± 3）；三个问号命中 ≥ 44、互不重叠、不压邻控件。
    func testHelpRowsCompact() async throws {
        try await openWallet("normal", waitFor: "wallet.paused")
        for id in ["wallet.estimate.left.labelRow", "wallet.hero.frozen.labelRow"] {
            XCTAssertLessThanOrEqual(try rect(id).height, 24, "\(id) 视觉行高")
        }
        let paused = try rect("wallet.paused")
        let pausedText = try rect("wallet.paused.text")
        assertNear(paused.height, pausedText.height + 16, 3, "暂缓条高 = 文字 + 上下 8")
        try assertHit("wallet.paused.help.hit", covers: "wallet.paused.help", "暂缓问号")
        let hits = try ["wallet.hero.frozen.help.hit", "wallet.estimate.left.help.hit", "wallet.paused.help.hit",
                        "wallet.hero.withdraw", "wallet.hero.records.hit", "wallet.hero.eye.hit"].map { try rect($0) }
        for (index, lhs) in hits.enumerated() {
            for rhs in hits[(index + 1)...] {
                assertDisjoint(lhs, rhs, "命中区不重叠")
            }
        }
    }

    // MARK: - 入口（W13、W14）

    /// W13：列数 = 入口数（2），整行等分、无空列；卡内边距 8。
    func testEntriesTwoColumnsPadding8() async throws {
        try await openWallet("normal", waitFor: "wallet.entries")
        let card = try rect("wallet.entries")
        let orders = try rect("wallet.entry.OrderList")
        let ledger = try rect("wallet.entry.Ledger")
        XCTAssertTrue(sameRow(orders, ledger))
        assertNear(orders.width, ledger.width, 1, "等分")
        assertNear(orders.minX - card.minX, 8, 1, "左内边距 8")
        assertNear(card.maxX - ledger.maxX, 8, 1, "右内边距 8")
        assertNear(orders.minY - card.minY, 8, 1, "上内边距 8")
        XCTAssertNil(host?.probes["wallet.entry.Earnings"], "生产 since=null：没有收益入口")
    }

    /// W13 / W14：收益入口打开时三列等分；收益看板用柱状图（不是折线 trend）。
    func testEarningsEntryThreeColumnsBarChart() async throws {
        let (_, image) = try await openWallet("normal", earnings: true, waitFor: "wallet.entry.Earnings")
        let ids = ["wallet.entry.OrderList", "wallet.entry.Ledger", "wallet.entry.Earnings"]
        let cells = try ids.map { try rect($0) }
        for cell in cells.dropFirst() {
            XCTAssertTrue(sameRow(cells[0], cell))
            assertNear(cell.width, cells[0].width, 1, "三列等分")
        }
        let icon = try rect("wallet.entry.Earnings.icon")
        let found = await nearestIcon(image, in: icon, candidates: ["chart.bar", "chart.line.uptrend.xyaxis"],
                                      background: CouliColor.backgroundSurface, ink: CouliColor.textPrimary)
        XCTAssertEqual(found, "chart.bar", "收益看板柱状图（W14）")
    }

    // MARK: - 金额隐藏（W17）

    /// W17：主卡大数、冻结中 / 已提现、预估、已收货、暂缓一律「****」，月份照常；画面上任何位置都不出现原值。
    func testHiddenMasksEveryAmountKeepsMonth() async throws {
        try await openWallet("normal", hidden: true, waitFor: "wallet.paused")
        let mask = MaskableAmount.mask
        for id in ["wallet.hero.amount", "wallet.hero.frozen.value", "wallet.hero.withdrawn.value",
                   "wallet.estimate.left.value"] {
            XCTAssertEqual(try text(id), mask, "\(id) 隐藏")
        }
        XCTAssertEqual(try text("wallet.estimate.left.note"), "其中已收货 " + mask)
        XCTAssertEqual(try text("wallet.paused.text"), "其中 " + mask + " 暂缓入账")
        XCTAssertTrue(try text("wallet.estimate.right.value").hasSuffix("结算"), "月份照常")
        for fen: Int64 in [1234, 500, 5678, 3456, 456] {
            let shown = WalletVisualData.money(fen)
            XCTAssertFalse(allTexts.contains { $0.contains(shown) }, "隐藏后不出现 \(shown)")
        }
        try await openWallet("negative", hidden: true, waitFor: "wallet.negative")
        XCTAssertEqual(try text("wallet.negative.line1"), "待抵扣 " + mask, "待抵扣新位置也遮罩")
    }

    // MARK: - 工具

    /// 警告提示条：底色是警告浅底（不是警告字色 10% 叠加的近似色以外的颜色），条内有警告字色墨迹。
    private func assertWarningStrip(_ image: UIImage, _ strip: CGRect, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let background = pixel(CouliColor.token("status.warning.background"), dark: false)
        let corner = CGRect(x: strip.minX + 6, y: strip.maxY - 6, width: 6, height: 3)
        XCTAssertGreaterThan(share(image, in: corner, near: background, tolerance: 6), 0.8,
                             "\(message)：警告浅底 status.warning.background", file: file, line: line)
        XCTAssertGreaterThan(count(image, in: strip, near: pixel(CouliColor.statusWarningText, dark: false)), 40,
                             "\(message)：警告字色", file: file, line: line)
    }
}
