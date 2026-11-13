import Foundation
import XCTest

/// APP-06v 的 UI 测试入口：真实 App（Debug）+ 本机假服务（DebugFakeTrade，`-CouliFakeLoginServer`）。
///
/// 新的 Debug 输入（§2.2，实现方在 App target 的 `#if DEBUG` 里接，Release 不存在）：
/// 环境变量 `COULI_FAKE_PRODUCT_CARDS` = UTF-8 JSON 数组（商品卡对象，原样来自 visualCards）的 Base64。假服务据此：
/// - `GET /v1/products/<product_key>` 原样回数组里 product_key 相同的那张卡（不改任何字段）；
/// - `GET /v1/products/search?q=visual` 按数组顺序回这些卡；
/// - open 仍按卡片 `link_id` 走 DebugFakeTrade 既有场景（`visual-link` 等未知值 = 默认未变方案；b 组把 link_id 换成 `t-503` 等）；
/// - `img.example.test/product-v/…` 图片在本机回答（不连网）。
@MainActor
protocol ProductVisualUITest: XCTestCase {}

extension ProductVisualUITest {
    /// 测试侧开关（不传给 App）：不加 `-CouliFakeTipsRead`，下单须知按首次显示。
    static var tipsUnread: String {
        "-CouliFakeTipsUnread"
    }

    /// visualCards 原卡；`quoted_at` 日期换成当天（与 AppTests 同口径，见 ProductVisualFixture）。
    func visualCard(_ id: String, overrides: [String: Any] = [:]) throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("specs/search-product-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var cards = try XCTUnwrap((root["visualCards"] as? [String: Any])?["cards"] as? [String: Any])
        // v2：iOS 新增卡在 specs/product-visual-extra-cards.json（共用文件不动）
        let extraData = try Data(contentsOf: directory.appendingPathComponent("specs/product-visual-extra-cards.json"))
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: extraData) as? [String: Any])
        cards.merge(extra["cards"] as? [String: Any] ?? [:]) { old, _ in old }
        var card = try XCTUnwrap(cards[id] as? [String: Any], "visualCards / extra 缺 \(id)")
        if let quoted = card["quoted_at"] as? String, quoted.count > 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd"
            card["quoted_at"] = formatter.string(from: Date()) + String(quoted.dropFirst(10))
        }
        card.merge(overrides) { $1 }
        return card
    }

    /// - Parameter hold: v2（评审 r1 S2-4-3）：经 `COULI_FAKE_PRODUCT_HOLD=<product_key>` 让这张卡的 getProduct 挂住不回答
    ///   （搜索结果照常），进详情后停在加载态。
    func launchProduct(_ card: [String: Any], extra: [String] = [], hold: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        let json = try JSONSerialization.data(withJSONObject: [card])
        app.launchEnvironment["COULI_FAKE_PRODUCT_CARDS"] = json.base64EncodedString()
        if hold {
            app.launchEnvironment["COULI_FAKE_PRODUCT_HOLD"] = card["product_key"] as? String ?? ""
        }
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeLoggedIn", "-CouliFakeTradeNoExternal",
        ] + (extra.contains(Self.tipsUnread) ? [] : ["-CouliFakeTipsRead"]) + extra.filter { $0 != Self.tipsUnread }
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        node(app, "home.search").tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "没有进搜索页")
        field.tap()
        field.typeText("visual")
        app.buttons["search.submit"].tap()
        let first = node(app, "search.card.0")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "搜索没有结果")
        // 必须是注入的那一张（不是 DebugFakeSearch 的通用样例卡）：结果恰好 1 张、标题一致
        let title = card["title"] as? String ?? ""
        let only = !node(app, "search.card.1").exists
        // 卡内文字合成整卡一项按钮（FU-IOS-A11Y-04）：按整卡项的读屏名认卡
        let matches = first.label.contains(title) || first.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch.exists
        guard only, matches else {
            // 直接抛错结束本用例：不能拿 DebugFakeSearch 的通用样例卡冒充 visualCards 继续断言
            throw ProductVisualUIError.cardNotInjected(title)
        }
        first.tapCardBody()
        if hold {
            XCTAssertTrue(node(app, "product.loading").waitForExistence(timeout: 10), "没有停在详情加载态")
            return app
        }
        XCTAssertTrue(node(app, "product.buy").waitForExistence(timeout: 10), "没有进详情")
        _ = node(app, "product.image.loaded").waitForExistence(timeout: 5)
        return app
    }

    func node(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// 无障碍树的深度优先顺序（有名称的元素）；只读一次快照。顺序是读屏遍历的近似，实机 VoiceOver 仍须人工核对。
    func readingOrder(_ app: XCUIApplication) throws -> [ProductVisualA11yItem] {
        var items: [ProductVisualA11yItem] = []
        func walk(_ element: XCUIElementSnapshot) {
            if !element.label.isEmpty {
                items.append(ProductVisualA11yItem(type: element.elementType, id: element.identifier,
                                                   label: element.label, frame: element.frame))
            }
            element.children.forEach(walk)
        }
        try walk(app.snapshot())
        return items
    }

    func keep(_ items: [ProductVisualA11yItem], _ name: String) {
        let text = items.enumerated()
            .map { "\($0.offset)\t\($0.element.type.rawValue)\t\($0.element.id)\t\($0.element.label)" }
        let attachment = XCTAttachment(string: text.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

enum ProductVisualUIError: Error, CustomStringConvertible {
    case cardNotInjected(String)

    var description: String {
        switch self {
        case let .cardNotInjected(title):
            "假服务没有按 COULI_FAKE_PRODUCT_CARDS 只回注入的卡「\(title)」（§2.2 Debug 输入未接）"
        }
    }
}

struct ProductVisualA11yItem {
    let type: XCUIElement.ElementType
    let id: String
    let label: String
    let frame: CGRect
}
