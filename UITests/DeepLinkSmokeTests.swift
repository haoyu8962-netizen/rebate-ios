import XCTest

/// 冒烟（APP-02a）：Debug 包用测试 scheme 深链打开一个声明了 deeplink 的路由（Search，APP-06a 起是真实页面）
/// 与一个没声明的路由（不打开，停在首页）。设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另把截图写到该目录。
@MainActor
final class DeepLinkSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testDeclaredDeepLinkOpensPlaceholder() throws {
        let app = try launchAndOpen("couli-debug://r/Search?q=paper&platform=jd")
        // APP-06a 起 Search 是真实页面：深链参数 q 填进搜索框。
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Search page did not appear")
        XCTAssertEqual(field.value as? String, "paper")
        save(app, "01-deeplink-search-opens-placeholder")
    }

    func testUndeclaredDeepLinkIsBlockedAndStaysHome() throws {
        let app = try launchAndOpen("couli-debug://r/Wallet")
        let decision = app.staticTexts["root.lastRouteDecision"]
        XCTAssertTrue(decision.waitForExistence(timeout: 15), "route decision not shown")
        XCTAssertTrue(decision.label.contains("entry_not_allowed"), decision.label)
        XCTAssertFalse(placeholder(app, "Wallet").exists)
        XCTAssertTrue(placeholder(app, "Home").exists, "停在首页 Tab")
        XCTAssertTrue(app.descendants(matching: .any)["shell.tabBar"].exists)
        save(app, "02-deeplink-wallet-blocked-stays-home")
    }

    func testUnknownRouteShowsUpgradePrompt() throws {
        let app = try launchAndOpen("couli-debug://r/NoSuchRoute")
        XCTAssertTrue(app.descendants(matching: .any)["route.upgradePrompt"].waitForExistence(timeout: 15))
        save(app, "03-deeplink-unknown-route-upgrade-prompt")
    }

    private func placeholder(_ app: XCUIApplication, _ route: String) -> XCUIElement {
        app.staticTexts.matching(identifier: "route.placeholder.name")
            .matching(NSPredicate(format: "label == %@", route)).firstMatch
    }

    private func launchAndOpen(_ link: String) throws -> XCUIApplication {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("XCUIDevice.system.open needs iOS 16.4")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["shell.tabBar"].waitForExistence(timeout: 30))
        let url = try XCTUnwrap(URL(string: link))
        XCUIDevice.shared.system.open(url)
        // 系统可能先问「在 … 中打开？」。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["打开", "Open"])).firstMatch
        if confirm.waitForExistence(timeout: 5) {
            confirm.tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        return app
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
