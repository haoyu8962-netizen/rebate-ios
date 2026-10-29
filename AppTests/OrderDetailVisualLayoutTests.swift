@testable import Couli
import DesignSystem
import Foundation
import OrderCore
import SwiftUI
import UIKit
import XCTest

extension OrderVisualTestCase {
    /// 打开一份详情（details / reasonDetails 原样，或测试内派生），等状态卡与（有图时）商品图稳定。
    @discardableResult
    func openDetail(_ detail: [String: Any], canvas: OrderVisualHost.Canvas = .init(), hidden: Bool = false,
                    file: StaticString = #filePath, line: UInt = #line) async throws -> (OrderVisualHost, UIImage) {
        let id = try XCTUnwrap(detail["order_id"] as? String, file: file, line: line)
        let page = try fresh(OrderVisualStub.Script(details: [id: .data(detail)]))
        page.setHidden(hidden)
        try await page.showDetail(id, canvas)
        let expectImage = detail["image_url"] is String
        let image = await page.stable(file: file, line: line) { host, image in
            guard host.probes["orderDetail.statusCard"] != nil else { return false }
            return !expectImage || host.thumbnailDrawn(image, id: id)
        }
        return try (page, XCTUnwrap(image, "详情没有截到稳定画面", file: file, line: line))
    }

    @discardableResult
    func openDetail(_ name: String, canvas: OrderVisualHost.Canvas = .init(), hidden: Bool = false,
                    file: StaticString = #filePath, line: UInt = #line) async throws -> (OrderVisualHost, UIImage) {
        try await openDetail(OrderVisualData.detail(name), canvas: canvas, hidden: hidden, file: file, line: line)
    }
}

/// APP-08v-b 订单详情的结构 / 几何 / 像素用例（brief §2.4–§2.5；gaps G-O03 / G-O06 / G-O07 / G-O08 / G-O09；
/// Android b 评审 r1 S2-1…S2-4）。资金页口径：金额 null 不补 0、不由别的字段推算、隐藏覆盖新位置、未知状态不显示金额与写动作。
@MainActor
final class OrderDetailVisualLayoutTests: OrderVisualTestCase {
    private let iconCandidates = ["clock", "info.circle", "exclamationmark.triangle", "checkmark.circle"]

    private func color(_ rgb: ProductVisualPixels.RGB) -> Color {
        Color(uiColor: UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                               blue: CGFloat(rgb.blue) / 255, alpha: 1))
    }

    // MARK: - 状态卡标题行

    /// 标题行：状态图标 20 + 标题 17（heading）；图标按状态（预估类钟表、已结算对勾、失效 / 未知 i、扣回三角）；
    /// 已结算标题与图标为成功色（像素）。
    func testStatusTitleIconPerStatusAndSuccessTone() async throws {
        let cases: [(String, String)] = [
            ("detail_estimated", "clock"), ("detail_settled", "checkmark.circle"),
            ("detail_part_clawed", "checkmark.circle"), ("detail_no_rebate", "info.circle"),
            ("detail_unknown", "info.circle"), ("detail_clawed_back", "exclamationmark.triangle"),
            ("detail_price_compare_no_rebate", "info.circle"), ("detail_presale", "clock"),
        ]
        for (name, expected) in cases {
            let (_, image) = try await openDetail(name)
            try assertFont("orderDetail.status.title", base: 17, "\(name) 状态标题")
            let icon = try rect("orderDetail.status.icon")
            assertNear(icon.width, 20, 1, "\(name) 状态图标 20")
            XCTAssertTrue(sameRow(icon, try rect("orderDetail.status.title")), "\(name) 图标与标题同一行")
            let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
            let success = expected == "checkmark.circle"
            let nearest = await nearestIcon(
                image,
                in: icon,
                candidates: iconCandidates,
                background: color(surface),
                dark: false
            )
            XCTAssertEqual(nearest, expected, "\(name) 状态图标")
            if success {
                let title = try rect("orderDetail.status.title")
                let tone = ProductVisualPixels.RGB(CouliColor.statusSuccessText, dark: false)
                XCTAssertGreaterThan(count(ProductVisualPixels(image), in: title, near: tone, tolerance: 30), 20,
                                     "\(name) 已结算标题为成功色")
            }
        }
    }

    // MARK: - 金额（G-O07 + 资金红线）

    /// 详情左返利（28）、右实付（22）；列表不变（另有列表用例）。
    func testDetailAmountsRebateLeft28PaidRight22() async throws {
        try await openDetail("detail_estimated")
        let rebate = try record("orderDetail.amount.rebate")
        let paid = try record("orderDetail.amount.paid")
        XCTAssertEqual(rebate.text, OrderVisualData.money(450), "WAITING 预估返")
        XCTAssertEqual(paid.text, OrderVisualData.money(3990), "实付")
        XCTAssertLessThan(rebate.rect.minX, paid.rect.minX, "详情横排：左返利、右实付（G-O07）")
        assertNear(rebate.baseFontSize, 28, 0.5, "返利 28")
        assertNear(paid.baseFontSize, 22, 0.5, "实付 22")
        assertInside(rebate.rect, try rect("orderDetail.statusCard"), "金额在状态卡内")
    }

    /// 已结算实返取 actual、扣回「-¥8」墨棕（不染返利色）、INVALID 返利 ¥0 墨棕；预售只一格「已付定金」；NO_REBATE 只实付；
    /// 未知状态只实付（est / actual / clawback 哨兵都不显示）；null 不补 0。
    func testDetailMoneyComesOnlyFromItsOwnFields() async throws {
        var (_, image) = try await openDetail("detail_settled")
        XCTAssertEqual(try record("orderDetail.amount.rebate").text, OrderVisualData.money(320), "已结算显示实返 actual_fen")

        (_, image) = try await openDetail("detail_clawed_back")
        let claw = try record("orderDetail.amount.rebate")
        XCTAssertEqual(claw.text, CouliFormat.moneySigned(fen: -800), "扣回「-¥8」")
        let rebateTone = ProductVisualPixels.RGB(CouliColor.rebateText, dark: false)
        XCTAssertEqual(count(ProductVisualPixels(image), in: claw.rect, near: rebateTone, tolerance: 24), 0,
                       "扣回金额墨棕，不用返利强调色")

        (_, image) = try await openDetail("detail_no_rebate")
        let zero = try record("orderDetail.amount.rebate")
        XCTAssertEqual(zero.text, OrderVisualData.money(0), "INVALID「返利 ¥0」")
        XCTAssertEqual(count(ProductVisualPixels(image), in: zero.rect, near: rebateTone, tolerance: 24), 0,
                       "INVALID ¥0 墨棕")

        try await openDetail("detail_presale")
        XCTAssertNil(host?.probes["orderDetail.amount.rebate"], "预售只一格")
        XCTAssertEqual(try record("orderDetail.amount.paid").text, OrderVisualData.money(3000), "已付定金")

        try await openDetail("detail_price_compare_no_rebate")
        XCTAssertNil(host?.probes["orderDetail.amount.rebate"], "NO_REBATE 只实付一格")

        try await openDetail("detail_unknown")
        XCTAssertNil(host?.probes["orderDetail.amount.rebate"], "未知状态不显示返利 / 实返 / 扣回")
        XCTAssertEqual(try record("orderDetail.amount.paid").text, OrderVisualData.money(1990), "未知状态只显示实付")
        let texts = host?.probes.records.values.map(\.text) ?? []
        for sentinel: Int64 in [987_654, 88765, 77765] {
            XCTAssertFalse(texts.contains { $0.contains(OrderVisualData.money(sentinel)) }, "哨兵 \(sentinel) 不得出现")
        }

        try await openDetail("detail_null_money")
        let paidText = host?.probes["orderDetail.amount.paid"]?.text ?? ""
        XCTAssertFalse(paidText.contains("¥0"), "pay_amount_fen=null 不补 0（\(paidText)）")
        let rebateText = host?.probes["orderDetail.amount.rebate"]?.text ?? ""
        XCTAssertFalse(rebateText.contains(OrderVisualData.money(450)), "actual=null 不用 est 代替（\(rebateText)）")
    }

    /// 金额隐藏：返利 / 扣回为「****」，状态标题里「部分扣回 {z}」的 z 同样遮罩；实付不隐藏。先正后反。
    func testHiddenMasksRebateAndTitleAmount() async throws {
        try await openDetail("detail_part_clawed")
        XCTAssertTrue(try record("orderDetail.status.title").text.contains(OrderVisualData.money(400)),
                      "前提：未隐藏时标题带扣回金额")
        try await openDetail("detail_part_clawed", hidden: true)
        XCTAssertEqual(try record("orderDetail.amount.rebate").text, "****")
        XCTAssertFalse(try record("orderDetail.status.title").text.contains(OrderVisualData.money(400)), "标题里的 z 遮罩")
        XCTAssertEqual(try record("orderDetail.amount.paid").text, OrderVisualData.money(15900), "实付不隐藏")
    }

    // MARK: - 提示

    /// WAITING「预计 10 月结算」是紧跟金额的灰胶囊（高 22、次要底）；PAID 入账句是一行文字、没有胶囊。
    func testWaitingCreditPillAndPaidHintLine() async throws {
        let (_, image) = try await openDetail("detail_estimated")
        let pill = try rect("orderDetail.creditPill")
        assertNear(pill.height, 22, 1, "月份胶囊高 22")
        XCTAssertGreaterThanOrEqual(pill.minY, try rect("orderDetail.amount.rebate").maxY - 0.5, "胶囊紧跟金额")
        XCTAssertTrue(try record("orderDetail.creditPill.label").text.contains("10 月"), "预计 10 月结算")
        let fill = ProductVisualPixels(image).color(at: CGPoint(x: pill.maxX - 4, y: pill.midY))
        XCTAssertTrue(fill.near(ProductVisualPixels.RGB(CouliColor.backgroundMuted, dark: false), tolerance: 6),
                      "胶囊次要底（\(fill)）")

        try await openDetail("detail_price_compare_risk")
        XCTAssertNil(host?.probes["orderDetail.creditPill"], "PAID 没有月份胶囊")
        XCTAssertEqual(try record("orderDetail.hint").text, "确认收货后随联盟月度结算入账")
    }

    // MARK: - 原因区进状态卡（O24、G-O03）

    /// INVALID：分隔线下「为什么没返利？」14（heading）→ 原因标题 → 说明，都在状态卡内（不再是独立卡），在金额之后。
    func testReasonMovesIntoStatusCardAfterDivider() async throws {
        try await openDetail("detail_no_rebate")
        let card = try rect("orderDetail.statusCard")
        let reason = try rect("orderDetail.reason")
        assertInside(reason, card, "原因区在状态卡内")
        let divider = try rect("orderDetail.divider")
        assertInside(divider, card, "分隔线在状态卡内")
        XCTAssertGreaterThanOrEqual(divider.minY, try rect("orderDetail.amount.rebate").maxY - 0.5, "分隔线在金额下")
        XCTAssertGreaterThanOrEqual(reason.minY, divider.maxY - 0.5, "原因区在分隔线下")
        let heading = try record("orderDetail.reason.heading")
        XCTAssertEqual(heading.text, "为什么没返利？")
        assertNear(heading.baseFontSize, 14, 0.5, "heading 14")
        XCTAssertFalse(try record("orderDetail.reason.title").text.isEmpty, "原因标题")
        XCTAssertFalse(try record("orderDetail.reason.desc").text.isEmpty, "原因说明")
    }

    /// 扣回：没有「为什么没返利？」，标题一行 +「说明；已从余额扣除」一行。
    func testClawedBackReasonHasNoHeadingAndMentionsDeduction() async throws {
        try await openDetail("detail_clawed_back")
        XCTAssertNil(host?.probes["orderDetail.reason.heading"], "扣回不带「为什么没返利？」")
        XCTAssertTrue(try record("orderDetail.reason.desc").text.contains("已从余额扣除"))
    }

    /// PUNISH 只标题（G-O03；Android b r1 S2-4）：②（INVALID）不画代拟说明；⑧（扣回）保留「已从余额扣除」、不带代拟说明。
    func testPunishShowsTitleOnly() async throws {
        try await openDetail("detail_reason_02")
        XCTAssertFalse(try record("orderDetail.reason.title").text.isEmpty, "前提：PUNISH 标题在")
        let desc = host?.probes["orderDetail.reason.desc"]?.text ?? ""
        XCTAssertFalse(desc.contains("如有疑问可联系客服"), "PUNISH 不画代拟说明（\(desc)）")
        try await openDetail("detail_reason_08")
        let clawed = try record("orderDetail.reason.desc").text
        XCTAssertTrue(clawed.contains("已从余额扣除"), "扣回态保留「已从余额扣除」")
        XCTAssertFalse(clawed.contains("如有疑问可联系客服"), "扣回 PUNISH 不带代拟说明")
    }

    /// 差额 / 比价行：只显示原因标题（不由 est − actual 推「比预估少 ¥x」，G-O03）+「查看说明 ›」（配置了才有）命中 ≥ 44。
    func testDiffRowShowsReasonTitleOnlyWithHelpLink() async throws {
        try await openDetail("detail_settled")
        let diff = try record("orderDetail.diff")
        assertInside(diff.rect, try rect("orderDetail.statusCard"), "差额行在状态卡内")
        XCTAssertFalse(diff.text.contains("比预估少"), "差额金额无字段，不推算（\(diff.text)）")
        XCTAssertFalse(diff.text.contains(OrderVisualData.money(130)), "不显示 est − actual")
        assertHit(try rect("orderDetail.viewHelp"), covers: try rect("orderDetail.viewHelp.label"), "查看说明")
        try await openDetail("detail_price_compare_risk")
        XCTAssertNil(host?.probes["orderDetail.viewHelp"], "PAID 非比价不出「查看说明」，不画风险句（G-O03）")
    }

    // MARK: - 申诉中块（O26、G-O09、Android b r1 S2-1）

    func testAppealPendingBlockInsideCardWithoutInventedTime() async throws {
        try await openDetail("detail_appeal_pending")
        let card = try rect("orderDetail.statusCard")
        let appeal = try rect("orderDetail.appeal")
        assertInside(appeal, card, "申诉中块在状态卡内")
        XCTAssertGreaterThanOrEqual(appeal.minY, try rect("orderDetail.reason").maxY - 0.5, "在原因区下")
        XCTAssertEqual(try record("orderDetail.appeal.pill").text, "申诉中")
        XCTAssertEqual(try record("orderDetail.appeal.desc").text, "结果会通过站内信通知你", "不臆造提交时间（G-O03）")
        assertHit(try rect("orderDetail.appealProgress"), covers: try rect("orderDetail.appealProgress.label"),
                  "查看申诉进度")
        XCTAssertNil(host?.probes["orderDetail.action.appeal"], "fixture reason_action=[] → 没有【去申诉】")
        XCTAssertNil(host?.probes["orderDetail.reason.desc"], "INVALID + BLACKLIST + 申诉中：原因区只标题（画板）")
    }

    /// 只有画板明确的 INVALID + BLACKLIST + 申诉中省略说明；REFUND 申诉中仍保留原说明（不把单张画板推成通用规则）。
    func testAppealPendingKeepsDescriptionForOtherReasons() async throws {
        let refund = try OrderVisualData.change(OrderVisualData.detail("detail_no_rebate"), ["appeal_pending": true])
        try await openDetail(refund)
        XCTAssertNotNil(host?.probes["orderDetail.appeal"], "前提：申诉中块在")
        XCTAssertFalse((host?.probes["orderDetail.reason.desc"]?.text ?? "").isEmpty, "REFUND 申诉中保留原说明")
        try await openDetail("detail_blacklist")
        XCTAssertFalse((host?.probes["orderDetail.reason.desc"]?.text ?? "").isEmpty, "BLACKLIST 非申诉中保留说明")
    }

    /// G-O09：服务端在申诉中仍下发 APPEAL 时客户端不自行过滤（按钮只来自 reason.action）。
    func testAppealPendingDoesNotFilterServerAppealAction() async throws {
        let detail = try OrderVisualData.change(OrderVisualData.detail("detail_appeal_pending"),
                                                ["reason_action": ["APPEAL"]])
        try await openDetail(detail)
        XCTAssertNotNil(host?.probes["orderDetail.appeal"])
        XCTAssertNotNil(host?.probes["orderDetail.action.appeal"], "服务端下发 APPEAL 照常出【去申诉】")
    }

    // MARK: - 商品卡 / 时间线 / 问问 AI

    /// 商品卡：「查看商品 ›」命中 ≥ 44；标题 14 不省略；单号在右列、【复制】紧跟单号墨迹。分享其他商品：无查看商品、无复制。
    func testProductCardViewProductAndCopy() async throws {
        let (_, image) = try await openDetail("detail_estimated")
        assertHit(try rect("orderDetail.viewProduct"), covers: try rect("orderDetail.viewProduct.label"), "查看商品")
        try assertFont("orderDetail.product.title", base: 14, "商品标题")
        let picture = try rect("orderDetail.product.image")
        let number = try rect("orderDetail.product.number")
        let label = try rect("orderDetail.product.copy.label")
        XCTAssertGreaterThanOrEqual(number.minX, picture.maxX + 8, "单号在右列")
        assertHit(try rect("orderDetail.product.copy"), covers: label, "复制")
        let band = CGRect(x: number.minX, y: number.minY, width: max(0, label.minX - number.minX - 0.5),
                          height: number.height)
        let surface = ProductVisualPixels.RGB(CouliColor.backgroundSurface, dark: false)
        let ink = try XCTUnwrap(inkRight(ProductVisualPixels(image), in: band, background: surface))
        XCTAssertLessThanOrEqual(label.minX - ink, 16, "复制紧跟单号文字")

        try await openDetail("detail_share")
        XCTAssertNil(host?.probes["orderDetail.viewProduct"], "其他商品没有「查看商品」")
        XCTAssertNil(host?.probes["orderDetail.product.copy"], "分享单没有复制")
    }

    /// 时间线：每节点一个点（已发生 / 未发生）+ 节点间竖线；【问问 AI】整行卡在时间线之后、与内容同宽、≥ 44、文字 17。
    func testTimelineThenAskAIRow() async throws {
        try await openDetail("detail_estimated")
        let timeline = try rect("orderDetail.timeline")
        for index in 0..<4 {
            let dot = try rect("orderDetail.timeline.dot.\(index)")
            assertNear(dot.width, 8, 1.5, "节点 \(index) 点 8")
            assertInside(dot, timeline, "节点 \(index) 在时间线卡内")
        }
        for index in 0..<3 {
            let rail = try rect("orderDetail.timeline.line.\(index)")
            XCTAssertLessThanOrEqual(rail.width, 1.5, "节点间 1 竖线")
            XCTAssertGreaterThanOrEqual(rail.minY, try rect("orderDetail.timeline.dot.\(index)").midY - 1)
        }
        let ask = try rect("orderDetail.askAI")
        XCTAssertGreaterThanOrEqual(ask.minY, timeline.maxY - 0.5, "问问 AI 在时间线之后（不在商品卡下）")
        assertNear(ask.width, timeline.width, 1, "整行卡与时间线卡同宽")
        XCTAssertGreaterThanOrEqual(ask.height, 43.5, "整行一个目标 ≥ 44")
        try assertFont("orderDetail.askAI.label", base: 17, "问问 AI 文字")
        let icon = try rect("orderDetail.askAI.icon")
        assertNear(icon.width, 32, 1, "32 方块图标底")
    }
}
