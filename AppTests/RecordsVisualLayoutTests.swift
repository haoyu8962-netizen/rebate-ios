@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

private struct Pill {
    let id: String
    let title: String
    let background: Color
    let ink: Color
    let icon: String
}

private struct Field {
    let key: String
    let label: String
    let value: String
}

/// APP-09v-b 提现记录结构 / 几何 / 像素（brief §2.2，W18–W30 的 iOS 对应项；画板 WithdrawRecords-v2、Pending-v2、Paid-v2、Failed-v2）。
/// 测量全部来自生产组件经 `couliLayoutProbe` 上报（交回 §4 测量桥），文字取测量里的显示文字，颜色按截图像素核对令牌。先正后反：
/// 同一用例里先验常态，再验变化态（展开 / 失败分支）。
@MainActor
final class RecordsVisualLayoutTests: RecordsVisualTestCase {
    private var now: Int64 {
        (try? RecordsVisualData.nowMillis()) ?? 0
    }

    private func channel(_ created: String) -> String {
        let millis = WalletClock.epochMillis(created) ?? 0
        let date = CouliFormat.timeListPast(epochMillis: millis, nowEpochMillis: now)
        return texts.format("withdraw_records.channel_line", ["date": date, "account": "支付宝 138****5678"])
    }

    // MARK: - 列表版式（W18–W20）

    /// W18：列表上 8、左右 16（卡片外缘距可视区左右各 16，首个月份标题顶距可视区顶 8）。
    func testW18ListInsets() async throws {
        try await openRecords(waitFor: "records.month.2026-10")
        let viewport = try viewport()
        let title = try rect("records.month.2026-10")
        assertNear(title.minY - viewport.minY, 8, 1, "首个月份标题距列表顶")
        let card = try rect(try record("records.row.PENDING").card)
        assertNear(card.minX - viewport.minX, 16, 0.5, "卡片左距")
        assertNear(viewport.maxX - card.maxX, 16, 0.5, "卡片右距")
    }

    /// W19：月份标题 12 号次文字、左缩进 4（相对卡片左缘），在本月卡片之上（间距 12）。
    func testW19MonthTitle() async throws {
        let (_, image) = try await openRecords(waitFor: "records.month.2026-09")
        for (month, first) in [("2026-10", "PENDING"), ("2026-09", "PAID")] {
            let id = "records.month.\(month)"
            try assertBase(id, 12, "\(month) 月份标题")
            let title = try rect(id)
            let card = try rect(try record("records.row.\(first)").card)
            assertNear(title.minX - card.minX, 4, 1, "\(month) 标题左缩进 4")
            assertNear(card.minY - title.maxY, 12, 2, "\(month) 标题到卡片 12")
            XCTAssertTrue(inkMostly(image, in: title, CouliColor.textSecondary, not: CouliColor.textPrimary),
                          "\(month) 标题次文字色")
        }
        XCTAssertEqual(try text("records.month.2026-10"), texts.format("withdraw_records.month", ["year": "2026",
                                                                                                  "month": "10"]))
    }

    /// W20：一月一张白卡（同月相邻行同一张卡，不同月不同卡）；行间 1 分隔线、行上下 12；行内容左距卡片 16。
    func testW20OneCardPerMonthRowsSeparated() async throws {
        let (_, image) = try await openRecords(waitFor: "records.row.REJECTED")
        let october = try record("records.row.PENDING").card
        let september = try record("records.row.PAID").card
        XCTAssertFalse(october.isEmpty, "行要报所在卡片的测量编号（card 字段）")
        XCTAssertEqual(try record("records.row.FAILED").card, october, "10 月两单同一张卡")
        XCTAssertEqual(try record("records.row.REJECTED").card, september, "9 月两单同一张卡")
        XCTAssertNotEqual(october, september, "不同月不同卡（一记录一卡、全表一卡都不对）")
        for (first, second, card) in [("PENDING", "FAILED", october), ("PAID", "REJECTED", september)] {
            let cardRect = try rect(card)
            let upper = try rect("records.row.\(first)")
            let lower = try rect("records.row.\(second)")
            assertInside(upper, cardRect, "\(first) 在卡内")
            assertInside(lower, cardRect, "\(second) 在卡内")
            let gap = lower.minY - upper.maxY
            XCTAssertTrue((-0.5...1.5).contains(gap), "\(first)/\(second) 行紧接（中间只有 1 分隔线），实际间隙 \(gap)")
            XCTAssertTrue(hasDivider(image, between: upper.maxY - 1, and: lower.minY + 1,
                                     span: (cardRect.minX + 20)...(cardRect.maxX - 20)), "\(first)/\(second) 之间有分隔线")
            for id in [first, second] {
                let row = try rect("records.row.\(id)")
                assertNear(try rect("records.row.\(id).amount").minY - row.minY, 12, 1.5, "\(id) 行上内边距 12")
                assertNear(row.maxY - (try rect("records.row.\(id).line")).maxY, 12, 1.5, "\(id) 行下内边距 12")
                assertNear(try rect("records.row.\(id).amount").minX - cardRect.minX, 16, 1, "\(id) 行内容左距 16")
            }
        }
        // 卡片本身是白底（surface）
        let cardRect = try rect(october)
        XCTAssertGreaterThan(share(image, in: cardRect.insetBy(dx: 4, dy: 4),
                                   near: pixel(CouliColor.backgroundSurface, dark: false), tolerance: 3), 0.6, "白卡")
    }

    // MARK: - 收起行（W21、W22）

    /// W21：状态胶囊三类——中性 + 钟表（审核中）、警告 + 三角（打款未成功 / 未通过）、成功绿 + 对勾（已到账）；高 22、字 12、
    /// 底色取状态令牌、字不截断；文字取字典。
    func testW21StatusPills() async throws {
        let (_, image) = try await openRecords(waitFor: "records.row.REJECTED.pill")
        let cases = [
            Pill(id: "PENDING", title: "审核中", background: CouliColor.token("status.pending.background"),
                 ink: CouliColor.textSecondary, icon: "clock"),
            Pill(id: "FAILED", title: "打款未成功", background: CouliColor.statusWarningBackground,
                 ink: CouliColor.statusWarningText, icon: "exclamationmark.triangle"),
            Pill(id: "PAID", title: "已到账", background: CouliColor.statusSuccessBackground,
                 ink: CouliColor.statusSuccessText, icon: "checkmark.circle"),
            Pill(id: "REJECTED", title: "未通过", background: CouliColor.statusWarningBackground,
                 ink: CouliColor.statusWarningText, icon: "exclamationmark.triangle"),
        ]
        for pill in cases {
            let (id, title, background, ink, icon) = (pill.id, pill.title, pill.background, pill.ink, pill.icon)
            let pill = try rect("records.row.\(id).pill")
            assertNear(pill.height, 22, 1, "\(id) 胶囊高 22")
            XCTAssertEqual(try text("records.row.\(id).pill.text"), title, "\(id) 胶囊文字")
            try assertBase("records.row.\(id).pill.text", 12, "\(id) 胶囊字号")
            let label = try record("records.row.\(id).pill.text")
            XCTAssertGreaterThanOrEqual(label.rect.width + 0.5, label.naturalWidth, "\(id) 胶囊字不截断")
            XCTAssertGreaterThan(share(image, in: pill.insetBy(dx: 2, dy: 2), near: pixel(background, dark: false),
                                       tolerance: 4), 0.35, "\(id) 胶囊底取状态令牌")
            XCTAssertGreaterThan(count(image, in: label.rect, near: pixel(ink, dark: false)), 10, "\(id) 胶囊字色")
            let iconRect = try rect("records.row.\(id).pill.icon")
            assertNear(iconRect.width, 14, 1, "\(id) 胶囊图标 14")
            let nearest = await nearestIcon(image, in: iconRect,
                                            candidates: ["clock", "checkmark.circle", "exclamationmark.triangle"],
                                            background: background, ink: ink)
            XCTAssertEqual(nearest, icon, "\(id) 胶囊图标")
        }
    }

    /// W22：收起行——金额 17/600、时间 · 渠道 + 脱敏账号 12 次文字、副文案只显示首句 14 主文字（其余句不画）；右侧 20 箭头朝下，
    /// 展开后朝上（翻转）。
    func testW22CollapsedRowFirstSentenceAndArrow() async throws {
        let (page, image) = try await openRecords(waitFor: "records.row.PENDING.line")
        try assertBase("records.row.PENDING.amount", 17, "金额")
        XCTAssertTrue(try text("records.row.PENDING.amount").contains(RecordsVisualData.money(1000)), "金额取 amount_fen")
        try assertBase("records.row.PENDING.channel", 12, "时间账号行")
        XCTAssertEqual(try text("records.row.PENDING.channel"), channel("2026-10-12T10:00:00+08:00"))
        try assertBase("records.row.PENDING.line", 14, "副文案首句")
        XCTAssertEqual(try text("records.row.PENDING.line"), try appSla(), "收起只显示首句（时效句，取 App 生效配置）")
        let frozen = "\(RecordsVisualData.money(1000)) 已冻结"
        XCTAssertFalse(probes(prefix: "records.row.PENDING").values.contains { $0.text.contains(frozen) },
                       "收起行不画第二句「已冻结」（只在展开与读屏，G-W08）")
        XCTAssertEqual(try text("records.row.FAILED.line"),
                       "收款支付宝账号状态异常；\(RecordsVisualData.money(800)) 已退回可提现余额，可修改收款账号后重新提现",
                       "失败首句保留分号（G-W08 只切展示）")
        XCTAssertTrue(inkMostly(image, in: try rect("records.row.PENDING.line"), CouliColor.textPrimary,
                                not: CouliColor.textSecondary), "首句主文字色")
        let arrow = try rect("records.row.PENDING.arrow")
        assertNear(arrow.width, 20, 1, "箭头 20")
        XCTAssertGreaterThan(arrow.minX, try rect("records.row.PENDING.pill").maxX - 0.5, "箭头在胶囊右侧")
        let down = await nearestIcon(image, in: arrow, candidates: ["chevron.down", "chevron.up"],
                                     background: CouliColor.backgroundSurface, ink: CouliColor.textSecondary)
        XCTAssertEqual(down, "chevron.down", "收起朝下")
        try page.toggle("PENDING")
        let expanded = await page.stable { $0.probes["records.detail.PENDING.header.arrow"] != nil }
        let flipped = try XCTUnwrap(expanded)
        let up = await nearestIcon(flipped, in: try rect("records.detail.PENDING.header.arrow"),
                                   candidates: ["chevron.down", "chevron.up"], background: CouliColor.backgroundSurface,
                                   ink: CouliColor.textSecondary)
        XCTAssertEqual(up, "chevron.up", "展开朝上")
    }

    // MARK: - 展开卡（W23–W29）

    /// W23：展开项单独成卡（与同月其余收起行的卡分开），卡头「申请金额」12 + 金额 28/700 等宽 + 胶囊 + 朝上箭头；展开时不再保留收起行。
    func testW23ExpandedCardSeparateHeader() async throws {
        try await openRecords(expand: ["PENDING"])
        let detail = try rect("records.detail.PENDING")
        XCTAssertNil(records?.probes["records.row.PENDING"], "展开后不再同时画收起行")
        let rest = try rect(try record("records.row.FAILED").card)
        assertDisjoint(detail, rest, "展开卡与同月其余记录的卡分开")
        XCTAssertEqual(try text("records.detail.PENDING.header.label"), texts.text("withdraw_detail.amount"))
        try assertBase("records.detail.PENDING.header.label", 12, "「申请金额」")
        try assertBase("records.detail.PENDING.header.amount", 28, "申请金额大数")
        XCTAssertEqual(try text("records.detail.PENDING.header.amount"), RecordsVisualData.money(1000))
        try assertWholeAmount("records.detail.PENDING.header.amount", inside: detail, "申请金额大数")
        XCTAssertEqual(try text("records.detail.PENDING.header.pill.text"), "审核中")
        assertInside(try rect("records.detail.PENDING.header.arrow"), detail, "朝上箭头在卡内")
        assertNear(try rect("records.detail.PENDING.header.label").minX - detail.minX, 16, 1, "卡内边距 16")
    }

    /// W24：状态块——审核中：主句 17 主文字 +「¥10 已冻结」12 次文字；失败：原因 17 与退回句 14 分两行（只在分号处切，文本不改）。
    func testW24StatusBlockLines() async throws {
        let (_, image) = try await openRecords(expand: ["PENDING", "FAILED"])
        XCTAssertEqual(try text("records.detail.PENDING.status.0"), try appSla(), "审核中主句 = 配置时效句")
        try assertBase("records.detail.PENDING.status.0", 17, "审核中主句")
        XCTAssertEqual(try text("records.detail.PENDING.status.1"), "\(RecordsVisualData.money(1000)) 已冻结")
        try assertBase("records.detail.PENDING.status.1", 12, "冻结附句")
        XCTAssertTrue(inkMostly(image, in: try rect("records.detail.PENDING.status.1"), CouliColor.textSecondary,
                                not: CouliColor.textPrimary), "附句次文字色")
        XCTAssertEqual(try text("records.detail.FAILED.status.0"), "收款支付宝账号状态异常")
        try assertBase("records.detail.FAILED.status.0", 17, "失败原因")
        XCTAssertEqual(try text("records.detail.FAILED.status.1"),
                       "\(RecordsVisualData.money(800)) 已退回可提现余额，可修改收款账号后重新提现")
        try assertBase("records.detail.FAILED.status.1", 14, "退回句")
        XCTAssertGreaterThanOrEqual(try rect("records.detail.FAILED.status.1").minY,
                                    try rect("records.detail.FAILED.status.0").maxY - 0.5, "原因与退回句分两行")
        XCTAssertTrue(inkMostly(image, in: try rect("records.detail.FAILED.status.0"), CouliColor.textPrimary,
                                not: CouliColor.textSecondary), "原因主文字色")
    }

    /// W25：状态块 / 明细 / 客服行之间各一条分隔线。
    func testW25Dividers() async throws {
        let (_, image) = try await openRecords(expand: ["PENDING"])
        let detail = try rect("records.detail.PENDING")
        let span = (detail.minX + 20)...(detail.maxX - 20)
        let status = try rect("records.detail.PENDING.status.1")
        let fields = try rect("records.detail.PENDING.fields")
        let service = try rect("records.detail.PENDING.service")
        XCTAssertTrue(hasDivider(image, between: status.maxY, and: fields.minY, span: span), "状态块 / 明细之间分隔线")
        XCTAssertTrue(hasDivider(image, between: fields.maxY, and: service.minY, span: span), "明细 / 客服之间分隔线")
    }

    /// W26：明细字段表——标签不伸缩、值右对齐（贴卡内右缘）、等宽、行距 8；手续费 / 代扣个税为 0 不写；到账行按状态取标签。
    func testW26FieldTable() async throws {
        try await openRecords(expand: ["PAID"])
        let detail = try rect("records.detail.PAID")
        let prefix = "records.detail.PAID.field."
        XCTAssertNil(records?.probes[prefix + "fee.value"], "手续费 0 不写")
        XCTAssertNil(records?.probes[prefix + "tax.value"], "代扣个税 0 不写")
        XCTAssertFalse(recordTexts.contains(texts.text("withdraw_detail.fee")), "不出「手续费」行")
        let expected = [
            Field(key: "amount", label: texts.text("withdraw_detail.amount"), value: RecordsVisualData.money(500)),
            Field(key: "net", label: texts.text("withdraw_detail.net_label.actual"),
                  value: RecordsVisualData.money(500)),
            Field(key: "payout", label: texts.text("withdraw_detail.payout"), value: "支付宝 138****5678"),
            Field(key: "created", label: texts.text("withdraw_detail.created"),
                  value: CouliFormat
                      .timeMinute(epochMillis: WalletClock.epochMillis("2026-09-27T15:20:00+08:00") ?? 0)),
        ]
        var previous: CGRect?
        for field in expected {
            let (key, label, value) = (field.key, field.label, field.value)
            XCTAssertEqual(try text(prefix + key + ".label"), label, key)
            XCTAssertEqual(try text(prefix + key + ".value"), value, key)
            let labelRecord = try record(prefix + key + ".label")
            XCTAssertGreaterThanOrEqual(labelRecord.rect.width + 0.5, labelRecord.naturalWidth, "\(key) 标签不被压缩")
            let valueRect = try rect(prefix + key + ".value")
            assertNear(detail.maxX - valueRect.maxX, 16, 1, "\(key) 值右对齐")
            let row = labelRecord.rect.union(valueRect)
            if let previous {
                assertNear(row.minY - previous.maxY, 8, 1.5, "\(key) 行距 8")
            }
            previous = row
        }
    }

    /// W27：交易流水号两行（标签 / 号码）+ 右侧 16 复制图标 +「复制」14 链接色；复制视觉不被命中区撑高，命中 ≥ 44 且包住视觉。
    func testW27TradeNoAndCopy() async throws {
        let (_, image) = try await openRecords(expand: ["PAID"])
        let prefix = "records.detail.PAID."
        XCTAssertEqual(try text(prefix + "tradeNo.label"), texts.text("withdraw_detail.trade_no"))
        XCTAssertEqual(try text(prefix + "tradeNo.value"), "20260928200040011100")
        XCTAssertGreaterThanOrEqual(try rect(prefix + "tradeNo.value").minY,
                                    try rect(prefix + "tradeNo.label").maxY - 0.5, "标签 / 号码两行")
        XCTAssertEqual(try text(prefix + "copy.label"), texts.text("withdraw_detail.copy"))
        try assertBase(prefix + "copy.label", 14, "「复制」")
        assertNear(try rect(prefix + "copy.icon").width, 16, 1, "复制图标 16")
        let copy = try rect(prefix + "copy")
        XCTAssertLessThanOrEqual(copy.height, 30, "复制视觉高不被 44 命中区撑大")
        XCTAssertGreaterThan(copy.minX, try rect(prefix + "tradeNo.value").minX, "复制在号码右侧")
        try assertHit(prefix + "copy.hit", covers: prefix + "copy", "复制")
        XCTAssertGreaterThan(count(image, in: try rect(prefix + "copy.label"), near: pixel(CouliColor.textLink,
                                                                                           dark: false)), 10, "链接色")
    }

    /// W28：账号类失败的【修改收款账号】——在状态块内（退回句之后、明细之前），通栏描边，最小高 44（命中 ≥ 44）；不是品牌实底。
    func testW28ChangeAccountInStatusBlock() async throws {
        let (_, image) = try await openRecords(expand: ["FAILED"])
        let prefix = "records.detail.FAILED."
        let detail = try rect("records.detail.FAILED")
        let button = try rect(prefix + "changeAccount")
        XCTAssertGreaterThanOrEqual(button.minY, try rect(prefix + "status.1").maxY - 0.5, "在退回句之后")
        XCTAssertLessThanOrEqual(button.maxY, try rect(prefix + "fields").minY + 0.5, "在明细之前（G-W08）")
        assertNear(button.width, detail.width - 32, 1, "通栏")
        XCTAssertGreaterThanOrEqual(button.height, 43.5, "最小高 44")
        try assertHit(prefix + "changeAccount.hit", covers: prefix + "changeAccount", "修改收款账号")
        XCTAssertLessThan(
            share(image, in: button.insetBy(dx: 8, dy: 8), near: pixel(CouliColor.brandPrimary, dark: false),
                  tolerance: 12),
            0.2,
            "描边次按钮，不是品牌实底"
        )
    }
}

/// W29 / W30（类体长度上限，放扩展里）。
extension RecordsVisualLayoutTests {
    /// W29：客服行在明细之后；「联系客服」14 链接色，视觉不撑高、命中 ≥ 44。
    func testW29ServiceRow() async throws {
        let (_, image) = try await openRecords(expand: ["PENDING"])
        let prefix = "records.detail.PENDING."
        XCTAssertGreaterThanOrEqual(try rect(prefix + "service").minY, try rect(prefix + "fields").maxY - 0.5,
                                    "客服行在明细之后")
        try assertBase(prefix + "service.link.label", 14, "「联系客服」")
        XCTAssertEqual(try text(prefix + "service.link.label"), texts.text("withdraw_detail.cs"))
        XCTAssertLessThanOrEqual(try rect(prefix + "service.link").height, 30, "链接视觉高不被命中区撑大")
        try assertHit(prefix + "service.link.hit", covers: prefix + "service.link", "联系客服")
        XCTAssertGreaterThan(count(image, in: try rect(prefix + "service.link.label"),
                                   near: pixel(CouliColor.textLink, dark: false)), 10, "链接色")
    }

    /// W30：底部「没有更多记录了」居中。
    func testW30EndCentered() async throws {
        let (_, image) = try await openRecords(waitFor: "records.end")
        XCTAssertEqual(try text("records.end"), texts.text("withdraw_records.end"))
        let end = try rect("records.end")
        // 按墨迹判居中（文字框可能是通栏）：字形左右端的中点 ≈ 可视区中线
        let pixels = ProductVisualPixels(image)
        let band = CGRect(x: try viewport().minX, y: end.minY, width: try viewport().width, height: end.height)
        let canvas = pixel(CouliColor.backgroundCanvas, dark: false)
        let left = try XCTUnwrap(inkLeft(pixels, in: band, background: canvas), "「没有更多」没有画出来")
        let right = try XCTUnwrap(inkRight(pixels, in: band, background: canvas))
        assertNear((left + right) / 2, try viewport().midX, 2, "「没有更多记录了」居中")
    }
}
