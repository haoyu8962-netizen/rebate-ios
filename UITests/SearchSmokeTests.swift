import XCTest

/// 冒烟（APP-06a 验收 5.2）：Debug 包 + 本机假服务（`-CouliFakeLoginServer`，搜索与详情场景见 DebugFakeSearch）。
/// 首页搜索框 → Search → 输入关键词 → 结果 → 换 Tab、排序、筛选 → 进详情 → 购买（游客进登录，APP-06b）。顺带核对 A11yHitSearch 的命中区。
/// 设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另跑设计稿比对的截图用例，把截图写到该目录。
@MainActor
final class SearchSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1",
        ] + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// 首页搜索框 → Search，输入关键词并搜索，等第一张卡（或给定元素）出现。
    private func search(_ app: XCUIApplication, _ keyword: String, waitFor id: String = "search.card.0") {
        if !app.textFields["search.field"].exists {
            element(app, "home.search").tap()
        }
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "没有进搜索页")
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != "搜商品名，或粘贴商品链接" {
            element(app, "search.clear").tap()
        }
        field.typeText(keyword)
        app.buttons["search.submit"].tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 15), "没有出现 \(id)")
    }

    private func assertHit(_ item: XCUIElement, _ name: String) {
        XCTAssertGreaterThanOrEqual(item.frame.width, 44, "\(name) 宽")
        XCTAssertGreaterThanOrEqual(item.frame.height, 44, "\(name) 高")
    }

    func testSmokeSearchTabsSortFilterDetail() {
        let app = launch()
        search(app, "milk")
        XCTAssertTrue(element(app, "search.tab.jd").exists)
        XCTAssertTrue(element(app, "search.tab.pdd").exists)
        // A11yHitSearch：返回、【搜索】、Tab、排序、筛选胶囊命中区不小于 44pt。
        for id in ["search.back", "search.submit", "search.tab.taobao", "search.sort.relevance", "search.filter.coupon",
                   "search.filter.price"] {
            assertHit(element(app, id), id)
        }
        element(app, "search.tab.jd").tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 10))
        element(app, "search.sort.final_price_asc").tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 10))
        element(app, "search.filter.coupon").tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 10))
        element(app, "search.card.0").tap()
        XCTAssertTrue(element(app, "product.buy").waitForExistence(timeout: 10), "没有进详情")
        // APP-06b：购买走 open 流程；游客 open 得 10001 → 登记购买待办并进登录页（BR-ID-10）。
        element(app, "product.buy").tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "游客购买没有进登录页")
    }

    private func requireShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    private func pause(_ seconds: Double = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// 点卡片标题区域进详情（大字号时卡片下半部可能被每屏底部的口径说明区盖住）。
    private func openCard(_ app: XCUIApplication, _ index: Int) {
        reveal(app, "search.card.\(index)")
        element(app, "search.card.\(index)").staticTexts.firstMatch.tap()
    }

    /// 滚到某张卡可点（先往下找，找不到再往上找：返回列表时保留了滚动位置）。
    private func reveal(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            app.swipeUp()
        }
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            app.swipeDown()
        }
    }

    func testShotsSearchStates() throws {
        try requireShots()
        let app = launch()
        element(app, "home.search").tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 10))
        save(app, "SearchTyping-empty")
        search(app, "milk")
        pause()
        save(app, "Search")
        app.swipeUp()
        pause()
        save(app, "Search-2")
        for _ in 0..<4 {
            app.swipeUp()
        }
        XCTAssertTrue(element(app, "search.end").waitForExistence(timeout: 10))
        pause()
        save(app, "Search-3-end")
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        app.buttons["价格与返利说明"].firstMatch.tap()
        pause()
        save(app, "SearchDisclaimerNote")
        app.buttons["知道了"].tap()
        element(app, "search.tab.jd").tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 10))
        pause()
        save(app, "Search-tab-jd")
        element(app, "search.sort.final_price_asc").tap()
        pause()
        save(app, "Search-sort-price")
        element(app, "search.filter.coupon").tap()
        pause()
        save(app, "Search-filter-coupon")
        element(app, "search.filter.coupon").tap()
        element(app, "search.filter.price").tap()
        XCTAssertTrue(element(app, "search.price.min").waitForExistence(timeout: 5))
        save(app, "SearchFilterPrice")
        element(app, "search.price.min").tap()
        element(app, "search.price.min").typeText("10")
        element(app, "search.price.max").tap()
        element(app, "search.price.max").typeText("20")
        save(app, "SearchFilterPrice-filled")
        element(app, "search.price.confirm").tap()
        pause(1)
        save(app, "SearchFilterPrice-applied")
        app.terminate()
    }

    func testShotsSearchEdgeCases() throws {
        try requireShots()
        let app = launch()
        search(app, "none", waitFor: "search.empty")
        pause()
        save(app, "SearchEmpty")
        app.swipeUp()
        pause()
        save(app, "SearchEmpty-2")
        search(app, "fail", waitFor: "search.error")
        pause()
        save(app, "Search-error-trace6")
        search(app, "pageerr")
        for _ in 0..<5 {
            app.swipeUp()
        }
        XCTAssertTrue(element(app, "search.loadMoreError").waitForExistence(timeout: 10))
        pause()
        save(app, "Search-load-more-error-trace6")
        element(app, "search.tab.jd").tap()
        search(app, "disabled")
        pause(1.5)
        save(app, "Search-search-disabled")
        search(app, "states")
        pause()
        save(app, "Search-states")
        app.swipeUp()
        pause()
        save(app, "Search-states-2")
        app.swipeUp()
        pause()
        save(app, "Search-states-3")
        element(app, "search.tab.pdd").tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 10))
        reveal(app, "search.card.5")
        pause()
        save(app, "Search-pdd-amount-unknown")
        search(app, "slow", waitFor: "search.loading")
        save(app, "Search-loading")
        element(app, "search.tab.taobao").tap()
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 10))
        pause()
        save(app, "Search-slow-tab-switched")
        search(app, "busy", waitFor: "search.error")
        pause()
        save(app, "Search-rate-limited")
        app.terminate()
    }

    func testShotsProductStates() throws {
        try requireShots()
        let app = launch()
        search(app, "milk")
        element(app, "search.card.0").tap()
        XCTAssertTrue(element(app, "product.header").waitForExistence(timeout: 10))
        pause()
        save(app, "Product")
        app.swipeUp()
        pause()
        save(app, "Product-2")
        let names = ["Product-no-rebate", "Product-off-shelf-30141", "Product-ref-expired-30143", "Product-stale",
                     "Product-price-unavailable"]
        for (index, name) in names.enumerated() {
            app.buttons["返回"].firstMatch.tap()
            if index == 0 {
                search(app, "states")
            }
            openCard(app, index)
            XCTAssertTrue(element(app, "product.back").waitForExistence(timeout: 10) || app.buttons["返回"].exists)
            pause(1)
            save(app, name)
        }
        app.terminate()
    }

    func testShotsLargeTextAndNarrow() throws {
        try requireShots()
        let variants: [([String], String)] = [
            (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "AdaptLargeText200"),
            (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], "AdaptLargeTextMax"),
            (["-CouliDebugLayoutWidth", "320"], "AdaptNarrow"),
            (["-CouliDebugLayoutWidth", "320", "-UIPreferredContentSizeCategoryName",
              "UICTContentSizeCategoryAccessibilityL"], "AdaptNarrow320-200"),
        ]
        for (extra, prefix) in variants {
            let app = launch(extra)
            search(app, "milk")
            pause()
            save(app, prefix + "Search")
            app.swipeUp()
            pause()
            save(app, prefix + "Search-2")
            app.swipeDown()
            app.swipeDown()
            reveal(app, "search.card.0")
            element(app, "search.card.0").buttons["价格与返利说明"].firstMatch.tap()
            pause()
            save(app, prefix + "DisclaimerNote")
            app.buttons["知道了"].tap()
            openCard(app, 0)
            XCTAssertTrue(element(app, "product.header").waitForExistence(timeout: 10))
            pause()
            save(app, prefix + "Product")
            app.swipeUp()
            pause()
            save(app, prefix + "Product-2")
            app.terminate()
        }
    }
}
