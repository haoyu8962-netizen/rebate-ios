import XCTest

/// 冒烟：已同意隐私政策的冷启动直接进 Tab 外壳（首启弹窗流程见 PrivacyGateSmokeTests）。
@MainActor
final class LaunchSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testColdLaunchShowsRootScreen() {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented"]
        app.launch()

        let tabBar = ShellTabBar.bar(app)
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "tab shell did not appear")
        XCTAssertFalse(app.descendants(matching: .any)["launch.backdrop"].exists)
        // 测试动作跑 Debug：调试信息与面板入口可见。
        XCTAssertTrue(app.descendants(matching: .any)["root.buildConfiguration"].exists)
        let debugButton = app.buttons["root.debugPanelButton"]
        XCTAssertTrue(debugButton.exists)

        debugButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["debug.environment.test"].waitForExistence(timeout: 10))
    }
}
