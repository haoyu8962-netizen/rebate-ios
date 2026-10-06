import XCTest

/// 冒烟（APP-02c 验收 2）：调试假数据切「强制更新」→ 强更页、侧滑不能离开、从强更页进隐私政策与受限登录占位页、
/// 返回回到强更页；「商店都不可用」→ Unavailable 与【重试】；「建议更新」→ 可关闭提示，【暂不更新】后同一版本不再弹；
/// 调试面板切「强制更新」→ 从首页直接进入强更页。
/// `-CouliUpdateReset 1` 在 Gate 读取之前清掉本机调试强更记录；`-CouliUpdateScenario <场景>` 指定假数据。
/// 设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另把截图写到该目录（设计稿比对用）。
@MainActor
final class UpdateSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// 清掉本用例留下的调试强更记录与场景（本机记着的 below_min 会让其他 UI 测试冷启动就停在强更页）。
    override func tearDown() async throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliUpdateReset", "1"]
        app.launch()
        app.terminate()
    }

    private func launch(_ scenario: String?, reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliHideDebugInfo", "1"]
        if let scenario {
            app.launchArguments += ["-CouliUpdateScenario", scenario]
        }
        if reset {
            app.launchArguments += ["-CouliUpdateReset", "1"]
        }
        app.launchArguments += extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testForceUpdateCannotBeLeftAndSecondaryEntriesReturn() {
        let app = launch("force")
        let page = element(app, "update.force")
        XCTAssertTrue(element(app, "update.force.goStore").waitForExistence(timeout: 30), "没有进入强更页")
        XCTAssertFalse(element(app, "shell.tabBar").isHittable, "强更页盖住 Tab 外壳")
        save(app, "ForceUpdate")

        // 从左边缘侧滑：不能离开强更页（没有返回按钮，导航栈被拉回）。
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(element(app, "update.force.goStore").waitForExistence(timeout: 5))
        XCTAssertTrue(page.exists)
        save(app, "ForceUpdate-after-swipe")

        app.buttons["update.force.privacy"].tap()
        let name = app.staticTexts.matching(identifier: "route.placeholder.name").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.label, "PrivacyCenter")
        XCTAssertEqual(app.staticTexts["route.placeholder.restricted"].label, "from force update", "带强更来源标记")
        save(app, "ForceUpdate-privacy-policy")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "update.force.goStore").waitForExistence(timeout: 10), "返回回到强更页")

        app.buttons["update.force.deleteAccount"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.label, "Login")
        XCTAssertEqual(app.staticTexts["route.placeholder.restricted"].label, "restricted login", "受限登录")
        save(app, "ForceUpdate-restricted-login")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, "update.force.goStore").waitForExistence(timeout: 10), "返回回到强更页")

        // 商店对照表全为 null：【去更新】→ 暂时无法更新与【重试】，不给下载地址。
        app.buttons["update.force.goStore"].tap()
        XCTAssertTrue(element(app, "update.force.unavailable").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["update.force.retry"].exists)
        save(app, "ForceUpdateUnavailable-force")
    }

    func testStoresUnavailableShowsRetry() {
        let app = launch("stores_unavailable")
        XCTAssertTrue(element(app, "update.force.unavailable").waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["update.force.retry"].exists)
        XCTAssertFalse(app.buttons["update.force.goStore"].exists)
        save(app, "ForceUpdateUnavailable")
        app.buttons["update.force.retry"].tap()
        XCTAssertTrue(element(app, "update.force.unavailable").waitForExistence(timeout: 10), "重试后仍不可用")
        XCTAssertTrue(app.buttons["update.force.retry"].waitForExistence(timeout: 10))
    }

    func testForceUpdateAtLargeText() {
        let app = launch(
            "stores_unavailable",
            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        )
        XCTAssertTrue(element(app, "update.force.unavailable").waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["update.force.retry"].isHittable, "200% 字号主按钮仍可见可点")
        XCTAssertTrue(app.buttons["update.force.privacy"].isHittable)
        save(app, "ForceUpdate-font200")
        app.swipeUp()
        save(app, "ForceUpdate-font200-scrolled")
    }

    func testRecommendPromptDismissedForSameVersion() {
        let app = launch("recommend")
        let later = app.buttons["暂不更新"]
        XCTAssertTrue(later.waitForExistence(timeout: 30), "没有弹可关闭更新提示")
        XCTAssertTrue(app.buttons["去更新"].exists)
        save(app, "MainUpdatePrompt")
        later.tap()
        XCTAssertTrue(later.waitForNonExistence(timeout: 10))

        // 冷启动（不清记录）：同一 latest 不再弹。
        app.terminate()
        let again = launch("recommend", reset: false)
        XCTAssertTrue(element(again, "shell.tabBar").waitForExistence(timeout: 30))
        XCTAssertFalse(again.buttons["暂不更新"].waitForExistence(timeout: 3), "同一版本不再弹")
        save(again, "MainUpdatePrompt-after-later")
    }

    func testDebugPanelSwitchToForceFromHome() {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliUpdateReset", "1"]
        app.launch()
        let panelButton = app.buttons["root.debugPanelButton"]
        XCTAssertTrue(panelButton.waitForExistence(timeout: 30))
        panelButton.tap()
        let normal = app.buttons["debug.update.normal"]
        XCTAssertTrue(normal.waitForExistence(timeout: 10))
        normal.tap()
        let force = app.buttons["debug.update.force"]
        force.tap()
        // 下拉关闭调试面板（抓导航栏下拉，列表本身会吃掉下拉手势）。
        let grabber = app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(element(app, "update.force.goStore").waitForExistence(timeout: 10), "切强制更新后进入强更页")
        save(app, "ForceUpdate-from-debug-panel")
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
}
