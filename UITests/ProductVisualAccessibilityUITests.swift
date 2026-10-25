import XCTest

/// APP-06v-a 读屏顺序、读屏名、命中区与 200% 可达（brief §4.2–4.4）。真实 App + 注入的 visualCards 卡（见 ProductVisualUITestSupport）。
/// 无障碍树顺序是读屏遍历的近似；交回另附实机 VoiceOver 记录（实现方补）。
@MainActor
final class ProductVisualAccessibilityUITests: XCTestCase, ProductVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// §4.2：返回 → 标题 → 头图 → 价格 → 券前 → 预估返（含「以结算为准」整句）→ 预估返后、取价 → 优惠标签 → 来源 + 标题（一项）
    /// → 店铺 → 说明区 → 问问 AI → 主按钮；固定底栏排在内容之后。
    func testReadingOrderFollowsArtboard() throws {
        let app = try launchProduct(visualCard("tb_coupon_range"))
        let items = try readingOrder(app)
        keep(items, "product-reading-order")
        let steps: [(String, (ProductVisualA11yItem) -> Bool)] = [
            ("返回", { $0.type == .button && $0.label == "返回" }),
            ("导航标题", { $0.label == "商品详情" }),
            ("头图", { $0.type == .image && $0.label.hasPrefix("商品图片，") }),
            ("价格", { $0.label.contains("46.78") }),
            ("券前", { $0.label.contains("56.78") }),
            ("预估返", { $0.label.contains("预估返") && $0.label.contains("1.23") }),
            ("预估返后", { $0.label.contains("45.55") }),
            ("取价", { $0.label.contains("取价") }),
            ("优惠标签", { $0.label == "有券" }),
            ("来源 + 标题", { $0.label.contains("全脂纯牛奶") && !$0.label.hasPrefix("商品图片") }),
            ("店铺", { $0.label.contains("乳品生活旗舰店") }),
            ("说明区", { $0.label.contains("确认收货后随联盟月度结算入账") }),
            ("问问 AI", { $0.type == .button && $0.label.contains("问问 AI") }),
            ("主按钮", { $0.id == "product.buy" }),
        ]
        var previous = -1
        var previousName = ""
        for (name, match) in steps {
            let index = try XCTUnwrap(items.firstIndex(where: match), "读屏树里找不到「\(name)」")
            // 价格与券前、预估返后与取价允许合并为一项（同一元素）；其余必须严格在后
            let mergeable = (previousName == "价格" && name == "券前") || (previousName == "预估返后" && name == "取价")
            if mergeable {
                XCTAssertGreaterThanOrEqual(index, previous, "「\(name)」不能读在「\(previousName)」之前")
            } else {
                XCTAssertGreaterThan(index, previous, "「\(name)」应在「\(previousName)」之后")
            }
            previous = index
            previousName = name
        }
        let rebate = try XCTUnwrap(items.first { $0.label.contains("预估返") && $0.label.contains("1.23") })
        XCTAssertTrue(rebate.label.contains("以结算为准"), "区间返利读完整句（含「以结算为准」）：\(rebate.label)")
        let title = try XCTUnwrap(items.first { $0.label.contains("全脂纯牛奶") && !$0.label.hasPrefix("商品图片") })
        XCTAssertTrue(title.label.hasPrefix("淘宝"), "来源在前、与标题合为一项：\(title.label)")
    }

    /// §2.2：头图一项「商品图片，{商品名}」、图片角色；推广角标原文读在图名之前（G-D04）。
    func testHeroIsOneImageAndAdLabelIsReadBeforeIt() throws {
        var app = try launchProduct(visualCard("tb_coupon_range"))
        var items = try readingOrder(app)
        let heroes = items.filter { $0.label.hasPrefix("商品图片，") || $0.label.contains("商品图片，") }
        XCTAssertEqual(heroes.count, 1, "头图只读一次")
        XCTAssertEqual(heroes.first?.type, .image, "头图是图片角色")
        XCTAssertEqual(heroes.first?.label, "商品图片，全脂纯牛奶 250ml × 24 盒 整箱装 早餐奶 学生奶")
        app.terminate()

        app = try launchProduct(visualCard("ad_label"))
        items = try readingOrder(app)
        keep(items, "product-ad-label-order")
        let hero = try XCTUnwrap(items.firstIndex { $0.label.contains("商品图片，") })
        let adIndex = try XCTUnwrap(items.firstIndex { $0.label.contains("广告 · 平台原文") }, "角标原文要可读")
        XCTAssertLessThanOrEqual(adIndex, hero, "角标读在头图名之前")
        if adIndex == hero, let ad = items[hero].label.range(of: "广告 · 平台原文"),
           let name = items[hero].label.range(of: "商品图片，") {
            XCTAssertLessThan(ad.lowerBound, name.lowerBound, "合并为一项时角标在前")
        }
        XCTAssertEqual(items.filter { $0.label.contains("广告 · 平台原文") }.count, 1, "角标只读一次")
    }

    /// §2.3：下架卡读「商品已下架，{平台} {标题}」；不读任何金额；购买按钮不可用（G-D06 置灰、不出现【搜相似商品】）。
    func testOffShelfCardReadsStatusAndNoAmounts() throws {
        let app = try launchProduct(visualCard("tb_off_shelf"))
        let items = try readingOrder(app)
        keep(items, "product-off-shelf-order")
        let card = try XCTUnwrap(items.first { $0.label.contains("商品已下架") }, "下架卡要读出「商品已下架」")
        XCTAssertTrue(card.label.contains("淘宝") && card.label.contains("全脂纯牛奶"), "读「商品已下架，淘宝 标题」：\(card.label)")
        for amount in ["46.78", "56.78", "1.23", "2.34", "45.55", "有券"] {
            XCTAssertFalse(items.contains { $0.label.contains(amount) && $0.id != "product.buy" },
                           "下架不读「\(amount)」")
        }
        XCTAssertFalse(node(app, "product.buy").isEnabled, "下架购买按钮置灰")
        XCTAssertFalse(app.buttons["搜相似商品"].exists, "【搜相似商品】等 APP-SIM")
    }

    /// §4.3：返回、问问 AI、主按钮、【看看相似商品】命中区 ≥ 44pt、互不重叠；相似商品的上下扩展边真能点到（原卡平台 + 原样标题去搜索）。
    func testHitTargetsAre44AndSimilarExtendedEdgesWork() throws {
        for edge in [CGFloat(0.06), 0.94] {
            let app = try launchProduct(visualCard("pdd_price_compare"), extra: ["-CouliFakePlatformStatus", "pdd=on"])
            let targets = ["返回": app.buttons["返回"].firstMatch, "问问 AI": node(app, "product.askAI"),
                           "主按钮": node(app, "product.buy"), "看看相似商品": node(app, "product.similar")]
            for (name, element) in targets {
                XCTAssertTrue(element.exists, "缺「\(name)」")
                XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.01, "「\(name)」命中宽 ≥ 44")
                XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.01, "「\(name)」命中高 ≥ 44")
            }
            let frames = targets.map { ($0.key, $0.value.frame) }
            for (lhs, lhsFrame) in frames {
                for (rhs, rhsFrame) in frames where lhs < rhs {
                    XCTAssertFalse(lhsFrame.insetBy(dx: 0.5, dy: 0.5).intersects(rhsFrame.insetBy(dx: 0.5, dy: 0.5)),
                                   "「\(lhs)」与「\(rhs)」命中区重叠")
                }
            }
            let similar = node(app, "product.similar")
            similar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: edge)).tap()
            let field = app.textFields["search.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 10), "点【看看相似商品】边缘（\(edge)）没有去搜索")
            XCTAssertEqual(field.value as? String, "云朵柔 抽纸 3 层 × 120 抽 24 包 家用整箱", "原样标题去搜索")
            app.terminate()
        }
    }

    /// §4.4：≥200%（AX3）× 320 宽：页面能滚到底（说明区可见）、主按钮始终在屏内且可点（点了进入购买流程）。
    func testLargeTextNarrowScreenScrollsToBottomAndBuyStaysTappable() throws {
        let app = try launchProduct(visualCard("jd_no_coupon_single"), extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-CouliDebugLayoutWidth", "320",
        ])
        let disclaimer = node(app, "product.disclaimer")
        for _ in 0..<12 where !(disclaimer.exists && disclaimer.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(disclaimer.exists && disclaimer.isHittable, "200% 下滚不到说明区")
        let buy = node(app, "product.buy")
        XCTAssertTrue(buy.isHittable, "主按钮被遮住")
        XCTAssertTrue(app.frame.contains(buy.frame), "主按钮在屏幕内")
        XCTAssertTrue(buy.label.contains("2.34"), "按钮读名保留完整金额：\(buy.label)")
        buy.tap()
        XCTAssertTrue(node(app, "purchase.opening").waitForExistence(timeout: 5), "200% 下主按钮点不动")
    }
}
