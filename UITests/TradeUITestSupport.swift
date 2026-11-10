import XCTest

/// APP-06b 购买界面测试的公共操作（Debug 包 + 本机假服务 DebugFakeTrade）。
@MainActor
protocol TradeUITest: XCTestCase {}

extension TradeUITest {
    /// 收尾：冷启动一次只开假服务（会清掉本机会话），不把 `-CouliFakeTradeLoggedIn` 的假登录留给之后不走假服务的用例
    /// （如 UpdateSmokeTests 按游客走强更页的注销入口）。
    func resetFakeSession() {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1"]
        app.launch()
        _ = ShellTabBar.bar(app).waitForExistence(timeout: 30)
        app.terminate()
    }

    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeLoggedIn", "-CouliFakeTradeNoExternal",
        ] + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        return app
    }

    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func search(_ app: XCUIApplication, _ keyword: String) {
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
        XCTAssertTrue(element(app, "search.card.0").waitForExistence(timeout: 15), "没有结果")
    }

    /// 搜一个场景（如 tb:t-price）并进它的详情。
    func product(_ app: XCUIApplication, _ key: String) {
        search(app, key)
        element(app, "search.card.0").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "product.buy").waitForExistence(timeout: 10), "没有进详情")
    }

    /// 列表卡的购买按钮（卡内除口径 i 以外的按钮）。
    func cardBuy(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        let card = element(app, "search.card.\(index)")
        for _ in 0..<4 where !card.isHittable {
            app.swipeUp()
        }
        let buttons = card.buttons.matching(NSPredicate(format: "NOT (label CONTAINS %@)", "说明"))
        return buttons.element(boundBy: max(0, buttons.count - 1))
    }

    func requireShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
    }

    func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    func pause(_ seconds: Double = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: - 冒烟（verify.sh 每次都跑）
}
