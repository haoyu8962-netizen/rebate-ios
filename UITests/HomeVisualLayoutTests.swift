import UIKit
import XCTest

/// Debug 探针只能记录实际 Text / 布局的几何，不返回 fits / overflow / columns 等判定。
/// 自然宽度用同一 Text 在无宽度约束下实测；命中区域仍通过 XCUI 四边真实点击复核。
@MainActor
final class HomeVisualLayoutTests: HomeVisualUITestCase {
    struct Probe: Decodable {
        let id: String
        let role: String
        let card: String
        let text: String
        let rect: [Double]
        let naturalWidth: Double
        let fontSize: Double
        let baseFontSize: Double
        var frame: CGRect {
            CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
    }

    func probes() throws -> [Probe] {
        let result = try decode("home.visual.layout", as: [Probe].self)
        XCTAssertFalse(result.isEmpty)
        for item in result {
            XCTAssertEqual(item.rect.count, 4)
            XCTAssertTrue(item.rect.allSatisfy(\.isFinite))
        }
        return result
    }

    func testLongAmountsAtLeast200PercentFitCardAndScrollCardGrows() throws {
        for width in [320, 390] {
            for kind in ["scroll", "grid", "feed"] {
                try launch(.standard(scene: "stress_" + kind, width: width, category: "accessibilityExtraLarge"))
                _ = try reveal("home.product.\(kind).0")
                let layout = try probes()
                let card = try XCTUnwrap(layout.first { $0.id == "home.product.\(kind).0" })
                let money = layout.filter { $0.card == card.id && $0.role == "amount-part" }
                XCTAssertGreaterThanOrEqual(money.count, 5, "必须量主价、券前、券额及返利区间两端，不能只验小金额")
                XCTAssertTrue(money.contains { $0.text.contains("99999.99") })
                XCTAssertTrue(money.contains { $0.text.contains("88888.88") })
                for part in money {
                    XCTAssertGreaterThan(part.baseFontSize, 0)
                    XCTAssertGreaterThanOrEqual(part.fontSize, part.baseFontSize * 2, "没有真正测到 200%：\(part.id)")
                    XCTAssertGreaterThanOrEqual(part.frame.width + 0.5, part.naturalWidth, "金额被截：\(part.text)")
                    XCTAssertTrue(card.frame.insetBy(dx: -0.5, dy: -0.5).contains(part.frame), "金额超出卡内裁切边界")
                }
                if kind == "scroll" {
                    XCTAssertGreaterThan(card.frame.width, 144, "横滑固定 144 会裁长金额")
                    XCTAssertGreaterThan(card.frame.width, money.map(\.naturalWidth).max() ?? 0)
                } else {
                    let cards = layout.filter { $0.role == "product-card" && $0.id.hasPrefix("home.product.\(kind).") }
                        .sorted { $0.frame.minY < $1.frame.minY }
                    XCTAssertGreaterThanOrEqual(cards.count, 2)
                    XCTAssertEqual(cards[0].frame.minX, cards[1].frame.minX, accuracy: 1, "整组应改单列")
                    XCTAssertGreaterThanOrEqual(cards[1].frame.minY, cards[0].frame.maxY)
                }
                let footer = try reveal("home.footer")
                XCTAssertTrue(footer.isHittable, "大字号页底仍可达")
            }
        }
    }

    func testRebateInfoHitAreaDoesNotInflateVisualRowAndFourEdgesWork() throws {
        for kind in ["scroll", "grid", "feed"] {
            try launch(.standard())
            let info = try revealFullyVisible("home.info.\(kind).0")
            assertHit(info)
            let layout = try probes()
            let row = try XCTUnwrap(layout.first { $0.id == "home.rebate.row.\(kind).0" })
            let glyph = try XCTUnwrap(layout.first { $0.id == "home.info.glyph.\(kind).0" })
            XCTAssertLessThanOrEqual(row.frame.height, 22, "18pt 视觉行不能被 44pt 命中区撑高")
            XCTAssertLessThanOrEqual(glyph.frame.width, 16.5)
            XCTAssertLessThanOrEqual(glyph.frame.height, 16.5)
            let others = layout.filter { $0.role == "independent-hit" && $0.id != info.identifier }
            for other in others {
                XCTAssertFalse(info.frame.intersects(other.frame), "扩展区域与 \(other.id) 重叠")
            }
            for edge in [CGVector(dx: 0.03, dy: 0.5), CGVector(dx: 0.97, dy: 0.5),
                         CGVector(dx: 0.5, dy: 0.03), CGVector(dx: 0.5, dy: 0.97)] {
                _ = try revealFullyVisible(info.identifier)
                XCTAssertTrue(element("home.list").frame.contains(info.frame), "四边点击前整块命中区必须在列表内")
                info.coordinate(withNormalizedOffset: edge).tap()
                let content = element("home.info.content.\(kind).0")
                XCTAssertTrue(content.waitForExistence(timeout: 3), "命中区外扩但实际没有收到触摸")
                XCTAssertFalse(element("product.header").exists)
                _ = try revealFullyVisible(info.identifier)
                info.tap()
                XCTAssertFalse(content.exists)
            }
        }
    }

    func testNormalGridHasTwoColumnsAndLargeScreenAlignsBasicToo() throws {
        try launch()
        _ = try reveal("home.product.grid.0")
        let normal = try probes().filter { $0.role == "product-card" && $0.id.hasPrefix("home.product.grid.") }
        XCTAssertEqual(normal.count, 2)
        XCTAssertEqual(normal[0].frame.minY, normal[1].frame.minY, accuracy: 1)
        XCTAssertGreaterThan(abs(normal[0].frame.minX - normal[1].frame.minX), 100)
        // 调试窗口按请求做真实 840pt 布局；不以缩放图片代替布局。App 宿主快照另验这一档整页。
        for level in ["member", "basic"] {
            try launch(.standard(level: level, width: 840))
            let layout = try probes()
            let columns = try ["home.column.search", "home.column.native", "home.column.sdui"].map { id in
                try XCTUnwrap(layout.first { $0.id == id })
            }
            for column in columns {
                XCTAssertEqual(column.frame.width, 600, accuracy: 1)
                XCTAssertEqual(column.frame.midX, 420, accuracy: 1)
            }
            let cells = layout.filter { $0.role == "icon-cell" }.sorted { $0.frame.minY < $1.frame.minY }
            XCTAssertEqual(cells.count, 10)
            let top = try XCTUnwrap(cells.first?.frame.minY)
            XCTAssertEqual(cells.filter { abs($0.frame.minY - top) < 1 }.count, 5)
        }
    }

    func testLargeTextNativeButtonsFitAndRemainReachable() throws {
        for width in [320, 390] {
            try launch(.standard(width: width, category: "accessibilityExtraLarge"))
            for id in ["home.guest.login", "clipboard.homeCard.paste", "home.askAI"] {
                assertHit(try reveal(id))
            }
            let labels = try probes().filter { $0.role == "button-label" }
            XCTAssertFalse(labels.isEmpty)
            for label in labels {
                XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.naturalWidth, "按钮字被裁：\(label.text)")
            }
        }
    }

    /// S2-3；规划 origin/main:规划/03_前端架构.md §10.4。本测试走实际字号至少 200% 的口径。
    /// 字号来自正在显示的 Text，不能拿外围 dynamicTypeSize 或未套封顶修饰符的 UIFontMetrics 代替。
    func testSearchAndAskAIFontsScaleAtLeast200PercentAtMaximumAccessibilitySize() throws {
        for width in [320, 390] {
            for level in ["guest", "basic"] {
                let search = level == "basic" ? "basic.search" : "home.search"
                let identifiers = level == "basic" ? [search] : [search, "home.askAI"]
                try launch(.standard(level: level, width: width))
                let normal = try fontLabels(identifiers)
                try launch(.standard(level: level, width: width, category: "accessibilityExtraExtraExtraLarge"))
                let enlarged = try fontLabels(identifiers)
                for id in identifiers {
                    let baseline = try XCTUnwrap(normal[id])
                    let actual = try XCTUnwrap(enlarged[id])
                    XCTAssertGreaterThan(baseline.fontSize, 0)
                    XCTAssertGreaterThan(actual.baseFontSize, 0)
                    XCTAssertEqual(baseline.fontSize, baseline.baseFontSize, accuracy: 0.01)
                    XCTAssertEqual(actual.baseFontSize, baseline.baseFontSize, accuracy: 0.01)
                    XCTAssertGreaterThanOrEqual(actual.fontSize / baseline.fontSize, 2, "\(id) 实际放大不足 200%")
                    XCTAssertGreaterThanOrEqual(actual.fontSize / actual.baseFontSize, 2)
                    XCTAssertEqual(actual.text, baseline.text, "不得以删短文字换取大字号通过")
                    assertHit(element(id))
                    XCTAssertTrue(element(id).frame.insetBy(dx: -1, dy: -1).contains(actual.frame))
                }
            }
        }
    }

    private func fontLabels(_ identifiers: [String]) throws -> [String: Probe] {
        UIWait.until("实际搜索文字与问 AI 的字号测量已上报", ceiling: 5) {
            guard let layout = try? self.probes() else { return false }
            return identifiers.allSatisfy { id in
                layout.contains { $0.id == id + ".label" && $0.fontSize > 0 && $0.baseFontSize > 0 }
            }
        }
        let layout = try probes()
        return try Dictionary(uniqueKeysWithValues: identifiers.map { id in
            let label = try XCTUnwrap(layout.first { $0.id == id + ".label" }, "缺真实文字字号探针：\(id).label")
            XCTAssertEqual(label.role, id == "home.askAI" ? "button-label" : "search-label")
            XCTAssertFalse(label.text.isEmpty)
            XCTAssertTrue(label.fontSize.isFinite && label.baseFontSize.isFinite)
            return (id, label)
        })
    }
}
