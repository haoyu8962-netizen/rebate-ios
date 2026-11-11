@testable import Couli
import DesignSystem
import Foundation
import Orders
import SwiftUI
import UIKit
import XCTest

/// FU-IOS-NUM-WRAP ①（QA-11 iOS #1：`Orders-font200-w320-light`、`Orders-font200-w390-dark`、
/// `OrderDetailEstimated-v2-font200-w320-light` 订单号被拆成「3741 / 234567890 / 123456」）：列表卡与详情共用的「订单号 + 复制」行
/// （`OrderListNumber`）四档下 19 位单号不在中间断（判据见 `DigitsRunJudge`）。
/// ADAPT-CHECK ①：同一行的【复制】与列表右上「未跟单？去找回」在大字号下要像按钮（判据见 `TextButtonJudge`）。
@MainActor
final class DigitsWrapOrderTests: OrderVisualTestCase {
    private func stressScript() throws -> OrderVisualStub.Script {
        var script = try listScript()
        script.pages["self"] = try .data(OrderVisualData.page("stress"))
        return script
    }

    private func canvas(_ tier: DigitsRunJudge.Tier) -> OrderVisualHost.Canvas {
        OrderVisualHost.Canvas(width: tier.width, height: tier.accessibility ? 2400 : 1200, dark: tier.dark,
                               size: tier.size)
    }

    // MARK: - 订单号

    func testListOrderNumberNeverBreaksAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let (page, _) = try await openList(stressScript(), canvas: canvas(tier),
                                               waitFor: "order.card.STRESS.number", images: [])
            let item = try record("order.card.STRESS.number")
            let card = try rect("order.card.STRESS")
            XCTAssertTrue(item.text.contains("3741234567890123456"), "\(tier.name)：前提——压力卡是 19 位单号（\(item.text)）")
            let problems = DigitsRunJudge.problems(item, container: card, window: page.window, tier: tier)
            XCTAssertEqual(problems, [], "列表 \(tier.name)")
        }
    }

    func testDetailOrderNumberNeverBreaksAllTiers() async throws {
        for tier in DigitsRunJudge.tiers {
            let (page, _) = try await openDetail("detail_estimated", canvas: canvas(tier))
            _ = await page.stable { host, _ in host.probes["orderDetail.product.number"] != nil }
            let item = try record("orderDetail.product.number")
            let card = try rect("orderDetail.product")
            let problems = DigitsRunJudge.problems(item, container: card, window: page.window, tier: tier)
            XCTAssertEqual(problems, [], "详情 \(tier.name)")
        }
    }

    /// v4（D10-1265，本线定非金额也带提示）：列表压力卡 19 位单号横滑的档必须有截断提示，放得下的档（正常档）没有；至少一档横滑。
    func testListOrderNumberScrollHintOnlyWhenScrolling() async throws {
        var scrolledTiers: [String] = []
        for tier in DigitsRunJudge.tiers {
            let (page, image) = try await openList(stressScript(), canvas: canvas(tier),
                                                   waitFor: "order.card.STRESS.number", images: [])
            let id = "order.card.STRESS.number"
            let outcome = try ScrollHintJudge.judge("\(tier.name) 单号", text: rect(id),
                                                    hint: page.probes[id + ".scrollHint"],
                                                    container: rect("order.card.STRESS"),
                                                    shot: ScrollHintJudge.Shot(image: image, window: page.window))
            var problems = outcome.problems
            if outcome.scrolled {
                scrolledTiers.append(tier.name)
            }
            if !tier.accessibility, outcome.scrolled {
                problems.append("\(tier.name)：正常档单号不该横滑")
            }
            XCTAssertEqual(problems, [], "订单号截断提示 \(tier.name)")
        }
        XCTAssertFalse(scrolledTiers.isEmpty, "前提：四档里至少一档单号横滑")
    }

    // MARK: - ADAPT-CHECK ① 光秃文字按钮

    /// 【复制】（列表压力卡、详情）：320 宽 + 200% 与 390 + 200%。命中 ≥ 44；字折行或不在单号那一行（换到下一行）时要有描边或底色。
    func testCopyLooksLikeButtonWhenWrappedAtLargeText() async throws {
        for width: CGFloat in [320, 390] {
            let tier = DigitsRunJudge.Tier(name: "\(Int(width)) + 200%", width: width, size: .accessibility3,
                                           dark: false)
            let (_, list) = try await openList(stressScript(), canvas: canvas(tier),
                                               waitFor: "order.card.STRESS.copy", images: [])
            try assertCopy(prefix: "order.card.STRESS", image: list, name: "列表【复制】\(tier.name)")
            let (detailPage, _) = try await openDetail("detail_estimated", canvas: canvas(tier))
            let detail = await detailPage.stable { host, _ in host.probes["orderDetail.product.copy"] != nil }
            try assertCopy(prefix: "orderDetail.product", image: XCTUnwrap(detail), name: "详情【复制】\(tier.name)")
        }
    }

    /// 列表标题行右上「未跟单？去找回」：200% 下折成多行或掉到标题行之外时要像按钮；命中 ≥ 44。
    func testFindEntryLooksLikeButtonAtLargeText() async throws {
        for width: CGFloat in [320, 390] {
            let tier = DigitsRunJudge.Tier(name: "\(Int(width)) + 200%", width: width, size: .accessibility3,
                                           dark: false)
            let (_, image) = try await openList(listScript(), canvas: canvas(tier), waitFor: "orders.findEntry.label",
                                                images: [])
            let label = try record("orders.findEntry.label")
            let problems = try TextButtonJudge.problems(
                label: label, hit: rect("orders.findEntry"),
                anchorRow: rect("orders.title"), image: image, name: "「未跟单？去找回」\(tier.name)"
            )
            XCTAssertEqual(problems, [])
        }
    }

    private func assertCopy(prefix: String, image: UIImage, name: String, file: StaticString = #filePath,
                            line: UInt = #line) throws {
        let label = try record(prefix + ".copy.label", file: file, line: line)
        let number = try record(prefix + ".number", file: file, line: line)
        // 所属行 = 单号末行（单号整段一行时就是单号框）
        let lineHeight = DigitsRunJudge.lineHeight(number.fontSize)
        let anchor = CGRect(x: number.rect.minX, y: max(number.rect.minY, number.rect.maxY - lineHeight * 1.5),
                            width: number.rect.width, height: min(number.rect.height, lineHeight * 1.5))
        let problems = try TextButtonJudge.problems(
            label: label, hit: rect(prefix + ".copy", file: file, line: line),
            anchorRow: anchor, image: image, name: name
        )
        XCTAssertEqual(problems, [], file: file, line: line)
    }
}
