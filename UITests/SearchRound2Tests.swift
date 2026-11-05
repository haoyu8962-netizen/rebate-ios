import XCTest

/// APP-06a 第 2 轮（Debug 包 + 本机假服务）：进程被系统回收后恢复搜索页（共性 20）、【问问 AI】进 AgentChat（共性 23）、
/// 商品图（共性 22）。设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另跑截图用例（窄屏 / 200% 缓存降级详情、常驻说明区、
/// 无可搜索平台、图片占位）。
@MainActor
final class SearchRound2Tests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private let baseArguments = [
        "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
        "-CouliHideDebugInfo", "1",
    ]

    private func launch(_ extra: [String] = [], waitForShell: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += baseArguments + extra
        app.launch()
        if waitForShell {
            XCTAssertTrue(element(app, "shell.tabBar").waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

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
        // F-IOS-06：上限 30 秒（只用来判失败）；waitForExistence 本身就是条件等待
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 30), "没有出现 \(id)")
    }

    /// 换平台 / 排序之后：等新条件的结果真正就位（选中态已变、首屏加载结束、首卡在），不拿换条件之前就在的旧卡片当完成信号（F-IOS-02）。
    private func waitForResults(
        _ app: XCUIApplication,
        selected id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        UIWait.until("\(id) 的结果就位", file: file, line: line) {
            element(app, id).isSelected && !element(app, "search.loading").exists && element(app, "search.card.0")
                .exists
        }
    }

    private func pause(_ seconds: Double = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private var shotDir: String? {
        let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"]
        return dir?.isEmpty == false ? dir : nil
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotDir {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    // MARK: - 共性 20：进程被系统回收后恢复

    /// 搜索、换 Tab 与排序、翻到第二页并滚下去、打开价格面板填了没提交的最低价 → 切到后台 → 进程在后台被结束 →
    /// 重新启动：搜索页恢复，关键词、平台、排序、价格面板草稿都在，结果按条件重新加载后回到原来的滚动位置。
    func testProcessDeathInBackgroundRestoresSearchPage() {
        let app = launch()
        search(app, "milk")
        element(app, "search.tab.jd").tap()
        waitForResults(app, selected: "search.tab.jd")
        XCTAssertTrue(element(app, "search.card.0").exists)
        element(app, "search.sort.final_price_asc").tap()
        waitForResults(app, selected: "search.sort.final_price_asc")
        XCTAssertTrue(element(app, "search.card.0").exists)
        for _ in 0..<3 {
            app.swipeUp()
        }
        XCTAssertTrue(element(app, "search.card.3").waitForExistence(timeout: 30), "翻到第二页")
        // 等滚动停下、首卡移出可点区域（替代固定 0.6 秒）
        UIWait.until("列表滚下去") { !element(app, "search.card.0").isHittable }
        XCTAssertFalse(element(app, "search.card.0").isHittable, "已经滚下去")
        save(app, "Restore-1-before-kill-list")
        element(app, "search.filter.price").tap()
        XCTAssertTrue(element(app, "search.price.min").waitForExistence(timeout: 5))
        element(app, "search.price.min").tap()
        element(app, "search.price.min").typeText("10")
        UIWait.until("草稿已输入") { element(app, "search.price.min").value as? String == "10" }
        save(app, "Restore-2-before-kill-draft")
        // 等进后台的同步保存执行完（App 发出的显式信号）再结束进程，替代固定 2 秒（F-IOS-02 偶发「价格面板与草稿恢复」失败的原因）
        UIWait.pressHomeAndWaitForBackgroundSave(app)
        app.terminate()

        let restored = launch(waitForShell: false)
        XCTAssertTrue(element(restored, "search.price.min").waitForExistence(timeout: 30), "价格面板与草稿恢复")
        XCTAssertEqual(element(restored, "search.price.min").value as? String, "10")
        pause()
        save(restored, "Restore-3-after-relaunch-draft")
        element(restored, "search.price.reset").tap()
        restored.buttons["关闭"].firstMatch.tap()
        XCTAssertEqual(restored.textFields["search.field"].value as? String, "milk")
        XCTAssertTrue(element(restored, "search.tab.jd").isSelected, "平台恢复")
        XCTAssertTrue(element(restored, "search.sort.final_price_asc").isSelected, "排序恢复")
        XCTAssertTrue(element(restored, "search.card.3").waitForExistence(timeout: 30), "结果按条件重新加载到锚点")
        // 等锚点对齐完成（首卡移出可点区域）再断言，替代固定 1 秒
        UIWait.until("回到锚点") { !element(restored, "search.card.0").isHittable }
        XCTAssertFalse(element(restored, "search.card.0").isHittable, "回到原来的滚动位置，不是列表顶部")
        save(restored, "Restore-4-after-relaunch-list")
        // 返回首页（出栈）后保存内容删除：再次在后台结束也不会恢复。
        restored.buttons["search.back"].firstMatch.tap()
        XCTAssertTrue(element(restored, "home.search").waitForExistence(timeout: 30))
        UIWait.pressHomeAndWaitForBackgroundSave(restored)
        restored.terminate()
        let fresh = launch()
        XCTAssertFalse(fresh.textFields["search.field"].waitForExistence(timeout: 3), "出栈后不再恢复")
        fresh.terminate()
    }

    // MARK: - 共性 23：【问问 AI】进 AgentChat

    func testAskAIOpensAgentChatTab() {
        let app = launch()
        search(app, "milk")
        element(app, "search.card.0").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "product.askAI").waitForExistence(timeout: 10))
        element(app, "product.askAI").tap()
        XCTAssertTrue(element(app, "shell.tabBar").waitForExistence(timeout: 5), "回到 Tab 外壳（AgentChat 是 Tab 根）")
        XCTAssertFalse(element(app, "product.askAI").exists, "离开详情页")
        XCTAssertFalse(element(app, "home.search").exists, "切到了 AI 助手 Tab，不在首页")
        pause()
        save(app, "Product-ask-ai-agentchat")
        app.terminate()
    }

    // MARK: - 共性 22：商品图

    func testProductImageLoadsFromContractField() {
        let app = launch()
        search(app, "milk")
        element(app, "search.card.0").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "product.image.loaded").waitForExistence(timeout: 10), "详情头图按 image 加载")
        app.buttons["返回"].firstMatch.tap()
        search(app, "states")
        element(app, "search.card.0").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "product.image.failed").waitForExistence(timeout: 10), "图片 404：占位")
        app.terminate()
    }

    // MARK: - 截图（设计稿比对第 2 轮）

    func testShotsRound2() throws {
        guard shotDir != nil else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
        var app = launch()
        search(app, "milk")
        pause(1.5)
        save(app, "Search-images")
        save(app, "Search-footer-top")
        app.swipeUp()
        pause(1)
        save(app, "Search-footer-scrolled")
        app.swipeDown()
        app.swipeDown()
        element(app, "search.card.0").staticTexts.firstMatch.tap()
        XCTAssertTrue(element(app, "product.image.loaded").waitForExistence(timeout: 10))
        pause()
        save(app, "Product-image")
        app.buttons["返回"].firstMatch.tap()
        search(app, "states")
        pause(1.5)
        save(app, "Search-states-image-placeholders")
        app.terminate()

        app = launch(["-CouliFakeSearchAllOff"])
        element(app, "home.search").tap()
        XCTAssertTrue(element(app, "search.unavailable").waitForExistence(timeout: 15), "没关键词也立即无可搜索平台")
        pause()
        save(app, "Search-unavailable-on-open")
        app.terminate()
        try shotsStaleDetailNarrowAndLargeText()
    }

    /// 缓存降级详情：320pt、200% 字号下取价处提示按宽度换行，不越界（共性 24）；同时截常驻说明区。
    private func shotsStaleDetailNarrowAndLargeText() throws {
        let variants: [([String], String)] = [
            (["-CouliDebugLayoutWidth", "320", "-UIPreferredContentSizeCategoryName",
              "UICTContentSizeCategoryAccessibilityL"], "AdaptNarrow320-200"),
            (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "AdaptLargeText200"),
            (["-CouliDebugLayoutWidth", "320"], "AdaptNarrow320"),
        ]
        for (extra, prefix) in variants {
            let app = launch(extra)
            search(app, "states")
            pause()
            save(app, prefix + "Search-footer")
            let card = element(app, "search.card.3")
            for _ in 0..<8 where !(card.exists && card.isHittable) {
                app.swipeUp()
            }
            card.staticTexts.firstMatch.tap()
            XCTAssertTrue(element(app, "product.header").waitForExistence(timeout: 10), "没有进详情")
            let fetched = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "以下单页为准")).firstMatch
            XCTAssertTrue(fetched.waitForExistence(timeout: 10), "缓存降级提示")
            for _ in 0..<6 where !fetched.isHittable {
                app.swipeUp()
            }
            pause()
            save(app, prefix + "Product-stale")
            XCTAssertLessThanOrEqual(fetched.frame.maxX, app.windows.firstMatch.frame.maxX + 0.5, "提示不越界")
            app.terminate()
        }
    }
}
