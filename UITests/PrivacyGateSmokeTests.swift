import XCTest

/// 冒烟（APP-02b 验收 2）：全新安装冷启动 → 首启弹窗；不同意 → 二次说明；仍不同意 → 基本模式页；
/// 【开启完整功能】→ 首启弹窗 → 同意 → Tab 外壳；再冷启动不弹。
/// `-CouliPrivacyPreset reset` 在闸门读取前清掉本机隐私决定（等同全新安装）。
/// 设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另把截图写到该目录（设计稿比对用）。
@MainActor
final class PrivacyGateSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + ["-CouliHideDebugInfo", "1"]
        app.launch()
        return app
    }

    func testFirstLaunchFlowToBasicModeThenConsent() {
        let app = launch(["-CouliPrivacyPreset", "reset"])
        let backdrop = app.descendants(matching: .any)["launch.backdrop"]
        XCTAssertTrue(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 30), "首启弹窗没有出现")
        XCTAssertFalse(ShellTabBar.bar(app).exists, "同意前不进 Tab")
        XCTAssertTrue(backdrop.exists)
        for link in ["privacy.link.privacy", "privacy.link.agreement", "privacy.link.collection", "privacy.link.sdk"] {
            XCTAssertTrue(app.descendants(matching: .any)[link].exists, link)
        }
        save(app, "LaunchPrivacy")

        app.buttons["不同意"].tap()
        XCTAssertTrue(app.staticTexts["温馨提示"].waitForExistence(timeout: 10), "二次说明没有出现")
        XCTAssertFalse(app.buttons["退出 App"].exists, "iOS 二次说明不给退出按钮")
        save(app, "LaunchSecondNotice")

        app.buttons["仍不同意"].tap()
        let notice = app.descendants(matching: .any)["basic.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "没有进入基本模式页")
        XCTAssertTrue(ShellTabBar.bar(app).exists)
        XCTAssertTrue(app.buttons["basic.settings"].exists)
        save(app, "BasicMode")

        // 基本模式点需要同意的 Tab：重新弹首启弹窗；不同意 → 仍不同意 回到基本模式。
        app.buttons["我的"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 10))
        app.buttons["不同意"].tap()
        app.buttons["仍不同意"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 10))

        app.buttons["basic.enableFull"].tap()
        XCTAssertTrue(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 10))
        app.buttons["同意"].tap()
        let tabBar = ShellTabBar.bar(app)
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.waitForNonExistence(timeout: 10), "同意后离开基本模式")
        save(app, "HomeGuest")

        // 再冷启动：已同意当前版本，不弹。
        app.terminate()
        let again = launch([])
        XCTAssertTrue(ShellTabBar.bar(again).waitForExistence(timeout: 30))
        XCTAssertFalse(again.staticTexts["个人信息保护提示"].exists)
    }

    func testBasicModeColdStartDoesNotPromptAndSettingsOpens() {
        let app = launch(["-CouliPrivacyPreset", "basic"])
        XCTAssertTrue(app.descendants(matching: .any)["basic.notice"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["个人信息保护提示"].exists, "基本模式冷启动不自动弹")
        app.buttons["basic.settings"].tap()
        let placeholder = app.staticTexts.matching(identifier: "route.placeholder.name")
            .matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
    }

    func testAgreementLinkOpensThroughRouterAndDialogComesBack() {
        let app = launch(["-CouliPrivacyPreset", "reset"])
        XCTAssertTrue(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 30))
        app.descendants(matching: .any)["privacy.link.privacy"].tap()
        let placeholder = app.staticTexts.matching(identifier: "route.placeholder.name")
            .matching(NSPredicate(format: "label == %@", "Agreement")).firstMatch
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 10), "返回后弹窗仍在")
    }

    /// 200% 字号（辅助字号 AX2 ≈ 194%）的首启弹窗：正文滚动、按钮固定可见。
    func testFirstLaunchDialogAtLargeText() {
        let app = launch([
            "-CouliPrivacyPreset", "reset",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ])
        XCTAssertTrue(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 30))
        let agree = app.buttons["同意"]
        XCTAssertTrue(agree.exists)
        XCTAssertTrue(agree.isHittable, "200% 字号下按钮仍可见可点")
        XCTAssertTrue(app.buttons["不同意"].isHittable)
        save(app, "LaunchPrivacy-200pct")
        app.swipeUp()
        save(app, "LaunchPrivacy-200pct-scrolled")
        XCTAssertTrue(agree.isHittable)
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
