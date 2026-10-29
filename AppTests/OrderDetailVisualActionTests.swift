@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-08v-b 详情按钮分区（G-O06：reason.action 与【查看流水】进状态卡、底栏只留【去提现】；一个描边、两个首实心）与
/// 未知状态（G-O08：不显示写动作，只【刷新】+「查看流水」）。按钮集合 / 顺序 / 去向不变由 OrderDetailVisualRulesTests 与 UI 真点保护。
@MainActor
final class OrderDetailVisualActionTests: OrderVisualTestCase {
    // MARK: - 按钮分区（G-O06）

    /// 卡内按钮：一个时描边次按钮、视觉 40 / 命中 ≥ 44；在状态卡内；没有底栏。
    func testSingleReasonActionIsOutlinedInsideStatusCard() async throws {
        let (_, image) = try await openDetail("detail_blacklist")
        let card = try rect("orderDetail.statusCard")
        let button = try rect("orderDetail.action.appeal")
        assertInside(button, card, "【去申诉】在状态卡内（G-O06）")
        assertNear(button.height, 40, 1, "卡内按钮视觉高 40（命中区不撑高）")
        assertHit(try rect("orderDetail.action.appeal.hit"), covers: button, "【去申诉】")
        XCTAssertNil(host?.probes["orderDetail.bottomBar"], "没有【去提现】时不画底栏")
        let fill = ProductVisualPixels(image).color(at: CGPoint(x: button.minX + 6, y: button.midY))
        XCTAssertFalse(fill.near(ProductVisualPixels.RGB(CouliColor.brandPrimary, dark: false), tolerance: 20),
                       "单个卡内按钮是描边次按钮（\(fill)）")
    }

    /// 两个卡内按钮：首个实心主按钮、第二个描边；顺序保持 reason.action 在前（联系客服、查看流水）；命中区不重叠。
    func testTwoCardButtonsFirstFilledSecondOutlined() async throws {
        let (_, image) = try await openDetail("detail_clawed_two")
        let card = try rect("orderDetail.statusCard")
        let first = try rect("orderDetail.action.contact_cs")
        let second = try rect("orderDetail.action.ledger")
        assertInside(first, card, "联系客服在卡内")
        assertInside(second, card, "查看流水在卡内")
        XCTAssertTrue(first.minX < second.minX || first.maxY <= second.minY + 0.5, "顺序：联系客服在前")
        let pixels = ProductVisualPixels(image)
        let primary = ProductVisualPixels.RGB(CouliColor.brandPrimary, dark: false)
        XCTAssertTrue(pixels.color(at: CGPoint(x: first.minX + 6, y: first.midY)).near(primary, tolerance: 20),
                      "首个实心主按钮")
        XCTAssertFalse(pixels.color(at: CGPoint(x: second.minX + 6, y: second.midY)).near(primary, tolerance: 20),
                       "第二个描边")
        assertDisjoint(try rect("orderDetail.action.contact_cs.hit"), try rect("orderDetail.action.ledger.hit"),
                       "两个按钮命中区不重叠")
        XCTAssertNil(host?.probes["orderDetail.bottomBar"], "无提现不画底栏")
    }

    /// 已结算：【去提现】只在底栏（白底铺满整宽、顶部分隔线、通栏 48），卡内没有；扣回【查看流水】只在卡内。
    func testWithdrawOnlyInBottomBarLedgerOnlyInCard() async throws {
        try await openDetail("detail_settled")
        let bar = try rect("orderDetail.bottomBar")
        let withdraw = try rect("orderDetail.action.withdraw")
        assertInside(withdraw, bar, "【去提现】在底栏")
        XCTAssertFalse(try rect("orderDetail.statusCard").intersects(withdraw), "卡内没有【去提现】")
        assertNear(bar.minX, 0, 0.5, "底栏铺满左缘")
        assertNear(bar.maxX, 390, 0.5, "底栏铺满右缘")
        assertNear(bar.maxY, 844, 0.5, "底栏白底延伸到窗口底（含安全区）")
        assertNear(withdraw.height, 48, 1, "底栏主按钮高 48")
        assertNear(withdraw.width, 358, 1, "通栏（左右 16）")
        XCTAssertGreaterThanOrEqual(bar.maxY - withdraw.maxY, 34 - 0.5, "按钮下方留 max(安全区, 16)")

        try await openDetail("detail_clawed_back")
        assertInside(try rect("orderDetail.action.ledger"), try rect("orderDetail.statusCard"), "【查看流水】在卡内")
        XCTAssertNil(host?.probes["orderDetail.bottomBar"])
    }

    // MARK: - 未知状态（G-O08）

    /// 先正：BLACKLIST 有【去申诉】；再反：未知状态即使下发 CLAIM / REAUTH / APPEAL / CONTACT_CS 也一个写动作都没有，
    /// 只有「请稍后查看」+ 描边【刷新】+ 文字链「查看流水」，都在状态卡内。
    func testUnknownStatusShowsOnlyRefreshAndLedgerLink() async throws {
        try await openDetail("detail_blacklist")
        XCTAssertNotNil(host?.probes["orderDetail.action.appeal"], "前提：已知状态照常出 reason.action 按钮")

        let (_, image) = try await openDetail("detail_unknown")
        for action in ["claim", "reauth", "appeal", "contact_cs", "withdraw", "ledger"] {
            XCTAssertNil(host?.probes["orderDetail.action.\(action)"], "未知状态不显示写动作 \(action)")
        }
        XCTAssertNil(host?.probes["orderDetail.bottomBar"])
        XCTAssertEqual(try record("orderDetail.hint").text, "请稍后查看")
        let card = try rect("orderDetail.statusCard")
        let refresh = try rect("orderDetail.refresh")
        assertInside(refresh, card, "【刷新】在状态卡内")
        XCTAssertEqual(try record("orderDetail.refresh.label").text, "刷新", "草稿键 order_detail.refresh")
        assertHit(try rect("orderDetail.refresh.hit"), covers: refresh, "【刷新】")
        let fill = ProductVisualPixels(image).color(at: CGPoint(x: refresh.minX + 6, y: refresh.midY))
        XCTAssertFalse(fill.near(ProductVisualPixels.RGB(CouliColor.brandPrimary, dark: false), tolerance: 20),
                       "【刷新】描边")
        let link = try rect("orderDetail.ledgerLink")
        assertInside(try rect("orderDetail.ledgerLink.label"), link, "「查看流水」文字链")
        XCTAssertGreaterThanOrEqual(link.height, 43.5, "文字链命中 ≥ 44")
        assertDisjoint(link, try rect("orderDetail.refresh.hit"), "刷新与查看流水命中区不重叠")
    }
}
