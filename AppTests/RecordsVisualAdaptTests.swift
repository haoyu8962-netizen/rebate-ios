@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// APP-09v-b 大字号与窄屏（brief §2.7「记录展开（19 位流水号）」、§4.6；编排 D10-366 口径）：
/// - AX3（≈ 200%）× 390 / 320：收起行金额与胶囊不截断（放不下就换行，胶囊换到金额下方），字号真放大；展开卡大数、明细值、流水号不截断；
/// - 320 × AX3：以固定步长连续滚动，≤ 6 屏看完样例（列表 + 已到账展开），途中每张卡内文字不截断。
@MainActor
final class RecordsVisualAdaptTests: RecordsVisualTestCase {
    private let ax = DynamicTypeSize.accessibility3

    /// 收起行四单 + 已到账展开卡：金额整段、胶囊字整段、副文案 / 明细 / 流水号可换行但不截断；字号 > 1.3 倍。
    private func assertRecordsWhole(_ width: CGFloat, file: StaticString = #filePath, line: UInt = #line) async throws {
        let (page, image) = try await openRecords(expand: ["PAID"], canvas: .init(width: width, height: 1400, size: ax),
                                                  file: file, line: line)
        for id in ["PENDING", "FAILED", "REJECTED"] {
            let prefix = "records.row.\(id)"
            _ = await page.stable(seconds: 3) { _ in true }
            guard let card = records?.probes[prefix]?.card, let cardRect = records?.probes[card]?.rect else {
                XCTFail("\(width)：缺 \(prefix) 或其卡片测量（§4 测量桥）", file: file, line: line)
                continue
            }
            try assertWholeAmount(prefix + ".amount", inside: cardRect, "\(width)×AX3 \(id) 金额", file: file, line: line)
            let pill = try record(prefix + ".pill.text", file: file, line: line)
            XCTAssertGreaterThanOrEqual(pill.rect.width + 0.5, pill.naturalWidth, "\(width)×AX3 \(id) 胶囊字不截断",
                                        file: file, line: line)
            XCTAssertGreaterThan(pill.fontSize, pill.baseFontSize * 1.3, "\(width)×AX3 \(id) 胶囊字真放大", file: file,
                                 line: line)
            assertInside(try rect(prefix + ".pill", file: file, line: line), cardRect, "\(width)×AX3 \(id) 胶囊在卡内",
                         file: file, line: line)
            try assertNotTruncated(prefix + ".line", "\(width)×AX3 \(id) 首句", file: file, line: line)
            try assertNotTruncated(prefix + ".channel", "\(width)×AX3 \(id) 时间账号", file: file, line: line)
        }
        let detail = try rect("records.detail.PAID", file: file, line: line)
        let amount = try record("records.detail.PAID.header.amount", file: file, line: line)
        XCTAssertGreaterThan(amount.fontSize, amount.baseFontSize * 1.3, "\(width)×AX3 大数真放大", file: file, line: line)
        if amount.naturalWidth > detail.width - 32 {
            try await assertWrappedAmount("records.detail.PAID.header.amount", inside: detail, image: image,
                                          background: pixel(CouliColor.backgroundSurface, dark: false),
                                          "\(width)×AX3 大数", file: file, line: line)
        } else {
            try assertWholeAmount("records.detail.PAID.header.amount", inside: detail, "\(width)×AX3 大数", file: file,
                                  line: line)
        }
        for key in ["amount", "net", "payout", "created"] {
            try assertNotTruncated("records.detail.PAID.field.\(key).value", "\(width)×AX3 明细 \(key)", file: file,
                                   line: line)
        }
        try assertNotTruncated("records.detail.PAID.tradeNo.value", "\(width)×AX3 流水号", file: file, line: line)
        XCTAssertEqual(try text("records.detail.PAID.tradeNo.value", file: file, line: line), "20260928200040011100",
                       "流水号完整（不截前缀）", file: file, line: line)
        try assertHit("records.detail.PAID.copy.hit", covers: "records.detail.PAID.copy", "\(width)×AX3 复制", file: file,
                      line: line)
    }

    func testAX3W390NothingTruncated() async throws {
        try await assertRecordsWhole(390)
    }

    func testAX3W320NothingTruncated() async throws {
        try await assertRecordsWhole(320)
    }

    /// 压力值（申请 ¥9999999999.99、32 位流水号）× 320 × AX3：大数不截断不缩字（放不下时整段一行、卡内横滑，D10-1230 判据 1），32 位号完整、复制可点。
    func testAX3W320StressAmountsAndTradeNo() async throws {
        let (_, image) = try await openRecords("stress", expand: ["STRESS"],
                                               canvas: .init(width: 320, height: 1600, size: ax))
        let detail = try rect("records.detail.STRESS")
        try await assertWrappedAmount("records.detail.STRESS.header.amount", inside: detail, image: image,
                                      background: pixel(CouliColor.backgroundSurface, dark: false), "压力大数")
        XCTAssertEqual(try text("records.detail.STRESS.header.amount"), RecordsVisualData.money(999_999_999_999))
        for key in ["amount", "fee", "tax", "net"] {
            try assertNotTruncated("records.detail.STRESS.field.\(key).value", "压力明细 \(key)")
        }
        XCTAssertEqual(try text("records.detail.STRESS.tradeNo.value"), "12345678901234567890123456789012")
        try assertNotTruncated("records.detail.STRESS.tradeNo.value", "32 位流水号")
        try assertHit("records.detail.STRESS.copy.hit", covers: "records.detail.STRESS.copy", "压力复制")
    }

    /// D10-366：320 × AX3（画布 320 × 568，iPhone SE 1 代可视高）以固定步长（可视高 × 0.9）连续滚动，≤ 6 屏看到底部
    /// 「没有更多记录了」；途中出现过的每张收起行金额整段、胶囊不截断。
    func testAX3W320ScrollsThroughWithinSixScreens() async throws {
        let (page, _) = try await openRecords(expand: ["PAID"], canvas: .init(width: 320, height: 568, size: ax))
        let step = try viewport().height * 0.9
        var screens = 1
        var seen: Set<String> = []
        while true {
            _ = await page.stable(seconds: 3) { _ in true }
            for (key, item) in probes(prefix: "records.row.") where key.split(separator: ".").count == 4
                && key.hasSuffix(".amount") {
                seen.insert(key)
                XCTAssertGreaterThanOrEqual(item.rect.width + 0.5, item.naturalWidth, "\(key) 金额整段")
            }
            for (key, item) in probes(prefix: "records.row.") where key.hasSuffix(".pill.text") {
                XCTAssertGreaterThanOrEqual(item.rect.width + 0.5, item.naturalWidth, "\(key) 胶囊不截断")
            }
            if let end = records?.probes["records.end"]?.rect, end.maxY <= (try viewport().maxY) + 0.5 {
                break
            }
            guard screens < 6, page.offset < page.maxOffset - 0.5 else {
                XCTFail("320×AX3：滚了 \(screens) 屏仍没看到「没有更多记录了」（≤ 6 屏，D10-366）")
                return
            }
            page.scroll(to: page.offset + step)
            screens += 1
        }
        XCTAssertLessThanOrEqual(screens, 6)
        XCTAssertGreaterThanOrEqual(seen.count, 3, "途中至少看到三张收起行（PAID 展开、其余收起）")
    }
}
