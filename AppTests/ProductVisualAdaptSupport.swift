@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import XCTest

/// ProductVisualAdaptTests 的辅助（v2：列 / 卡不越屏几何、超长金额候选）。
extension ProductVisualAdaptTests {
    /// 候选：整数位 3…12 × 小数 0 / 1 / 2 位（等宽数字下宽度只随位数变）；只取单行宽超过可用宽、必须退档的。
    static func extremePrices(available: CGFloat) throws -> ExtremePicks {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let size = UIFontMetrics(forTextStyle: .largeTitle).scaledValue(for: CouliTextStyle.display.baseSize,
                                                                        compatibleWith: traits)
        let font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        var half: Int?
        var whole: (fen: Int, fraction: CGFloat)?
        var log: [String] = []
        for digits in 3...12 {
            let integer = Int(String(repeating: "8", count: digits)) ?? 0
            for cents in [0, 50, 88] {
                let fen = integer * 100 + cents
                let text = CouliFormat.money(fen: Int64(fen))
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                let fraction = width - width.rounded(.down)
                log.append("\(text) 宽 \(width)（小数 \(fraction)）")
                guard width > available else { continue }
                if half == nil, fraction >= 0.5 {
                    half = fen
                }
                // 「刚好整数」：本字体在 AX5 下没有恰好整数宽的金额组合（附件日志逐项列出），取超出可用宽的候选里离整数最近的
                // （小数 < 0.1）作取整边界样本；「小数 ≥ 0.5」一类即评审 r1 S1-1 指出旧 ceil + 0.5 判法误判为放得下的那一类
                if fraction < 0.1, whole.map({ $0.fraction > fraction }) ?? true {
                    whole = (fen, fraction)
                }
            }
        }
        return ExtremePicks(
            half: half,
            whole: whole?.fen,
            log: "可用宽 \(available)，字号 \(size)\n" + log.joined(separator: "\n")
        )
    }

    struct ExtremePicks {
        let half: Int?
        let whole: Int?
        let log: String
    }

    /// 内容列与卡片不越出屏幕：窄屏左右各留 16；宽屏限宽 600 且左右留白相等；卡与列同宽；头图在列内；金额段在卡内、不越屏幕留白、不截断。
    func assertOnScreen(_ page: ProductVisualHost, canvas: ProductVisualHost.Canvas, name: String,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let width = canvas.width
        let column = try page.probes.rect("product.content", file: file, line: line)
        let card = try page.probes.rect("product.card", file: file, line: line)
        XCTAssertGreaterThanOrEqual(column.minX, 16 - 0.5, "\(name)：内容列左侧至少留 16", file: file, line: line)
        XCTAssertLessThanOrEqual(column.maxX, width - 16 + 0.5, "\(name)：内容列右侧至少留 16、不越出屏幕",
                                 file: file, line: line)
        if width - 32 <= 600 {
            assertNear(column.minX, 16, 0.5, "\(name)：窄屏内容列左边距 16", file: file, line: line)
            assertNear(width - column.maxX, 16, 0.5, "\(name)：窄屏内容列右边距 16", file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(column.width, 600 + 0.5, "\(name)：宽屏内容列限宽 600", file: file, line: line)
            assertNear(column.minX, width - column.maxX, 1, "\(name)：宽屏内容列左右留白相等（居中）", file: file, line: line)
        }
        assertNear(card.minX, column.minX, 0.5, "\(name)：价格大卡与内容列左齐", file: file, line: line)
        assertNear(card.maxX, column.maxX, 0.5, "\(name)：价格大卡与内容列右齐（没被金额撑宽）", file: file, line: line)
        if let hero = page.probes["product.hero"]?.rect {
            assertInside(hero, column, "\(name)：头图在内容列内", file: file, line: line)
        }
        let parts = page.probes.records.values.filter { $0.role == "amount-part" }
        XCTAssertFalse(parts.isEmpty, "\(name)：金额段要上报", file: file, line: line)
        for part in parts {
            assertInside(part.rect, card, "\(name) \(part.id) 在卡内", file: file, line: line)
            XCTAssertGreaterThanOrEqual(part.rect.minX, 16 - 0.5, "\(name) \(part.id) 不越出屏幕左侧留白",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(part.rect.maxX, width - 16 + 0.5, "\(name) \(part.id) 不越出屏幕右侧留白",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(part.rect.width, part.naturalWidth - 0.5, "\(name) \(part.id) 不截断",
                                        file: file, line: line)
        }
    }
}
