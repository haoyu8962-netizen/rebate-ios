@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// APP-08v-b 详情适配（brief §2.6、§4.5、§4.6；Android b 评审 r1 S2-2）：200%（AX3）压力值、两按钮换行、申诉进度与卡内按钮命中区、
/// 840 底栏铺满。
@MainActor
final class OrderDetailVisualAdaptTests: OrderVisualTestCase {
    /// 200% × 390 / 320：¥99999.99 / ¥88888.88 不缩不裁、纵排返利在上；状态卡与内容列左右 16。
    func testFont200StressAmountsStayWholeAndStackRebateFirst() async throws {
        for width: CGFloat in [390, 320] {
            try await openDetail("detail_stress", canvas: .init(width: width, height: 1200, size: .accessibility3))
            let card = try rect("orderDetail.statusCard")
            let content = try rect("orderDetail.content")
            assertNear(card.minX, content.minX + 16, 1, "\(width)：状态卡左边距 16")
            assertNear(card.maxX, content.maxX - 16, 1, "\(width)：状态卡右边距 16（没被金额撑宽）")
            try assertWholeAmount("orderDetail.amount.rebate", inside: card, "\(width)：预估返 ¥99999.99")
            try assertWholeAmount("orderDetail.amount.paid", inside: card, "\(width)：实付 ¥88888.88")
            let rebate = try record("orderDetail.amount.rebate")
            let paid = try record("orderDetail.amount.paid")
            XCTAssertEqual(rebate.text, OrderVisualData.money(9_999_999))
            XCTAssertGreaterThan(rebate.fontSize, rebate.baseFontSize, "\(width)：真 200%")
            XCTAssertLessThanOrEqual(rebate.rect.maxY, paid.rect.minY + 0.5, "\(width)：纵排返利在上")
            assertInside(try rect("orderDetail.product.number"), try rect("orderDetail.product"),
                         "\(width)：19 位单号完整在商品卡内")
        }
    }

    /// 200% × 320 两个卡内按钮：换行不截字（按钮字实际宽 ≥ 自然宽）、命中区 ≥ 44 且不重叠、都在状态卡内。
    func testFont200TwoCardButtonsWrapWithoutTruncation() async throws {
        try await openDetail("detail_clawed_two", canvas: .init(width: 320, height: 1400, size: .accessibility3))
        let card = try rect("orderDetail.statusCard")
        for action in ["contact_cs", "ledger"] {
            let label = try record("orderDetail.action.\(action).label")
            XCTAssertGreaterThanOrEqual(label.rect.width + 0.5, label.naturalWidth, "\(action) 按钮字不截断")
            assertInside(try rect("orderDetail.action.\(action)"), card, "\(action) 在状态卡内")
            XCTAssertGreaterThanOrEqual(try rect("orderDetail.action.\(action).hit").height, 43.5)
        }
        assertDisjoint(try rect("orderDetail.action.contact_cs.hit"), try rect("orderDetail.action.ledger.hit"),
                       "换行后命中区不重叠")
    }

    /// Android b r1 S2-2：申诉中 + 服务端下发 CONTACT_CS 时，「查看申诉进度」与下方按钮各自 ≥ 44 且不重叠（由容器留扩展空间，
    /// 视觉高不变）。
    func testAppealProgressAndActionButtonHitTargetsDoNotOverlap() async throws {
        let detail = try OrderVisualData.change(OrderVisualData.detail("detail_appeal_pending"),
                                                ["reason_action": ["CONTACT_CS"]])
        for size in [DynamicTypeSize.large, .accessibility3] {
            try await openDetail(detail, canvas: .init(height: 1100, size: size))
            let progress = try rect("orderDetail.appealProgress")
            let button = try rect("orderDetail.action.contact_cs.hit")
            XCTAssertGreaterThanOrEqual(progress.height, 43.5, "进度链接命中 ≥ 44")
            XCTAssertGreaterThanOrEqual(button.height, 43.5, "按钮命中 ≥ 44")
            assertDisjoint(progress, button, "申诉进度与【联系客服】命中区不重叠（\(size)）")
            if size == .large {
                assertNear(try rect("orderDetail.action.contact_cs").height, 40, 1, "按钮视觉高仍 40")
            }
        }
    }

    /// 840：内容 600 居中；底栏白底铺满 840、按钮 568 居中。
    func testWideSettledBottomBarSpansWindowContentCentered() async throws {
        try await openDetail("detail_settled", canvas: .init(width: 840, height: 900))
        let content = try rect("orderDetail.content")
        assertNear(content.width, 600, 1, "内容限宽 600")
        assertNear(content.midX, 420, 1, "内容居中")
        let bar = try rect("orderDetail.bottomBar")
        assertNear(bar.width, 840, 0.5, "底栏白底铺满 840")
        let withdraw = try rect("orderDetail.action.withdraw")
        assertNear(withdraw.width, 568, 1, "按钮 = 600 − 2 × 16")
        assertNear(withdraw.midX, 420, 1, "按钮居中")
    }
}
