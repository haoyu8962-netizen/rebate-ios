import XCTest

/// 冒烟：冷启动后看到首屏。
@MainActor
final class LaunchSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testColdLaunchShowsRootScreen() {
        let app = XCUIApplication()
        app.launch()

        let brandMark = app.descendants(matching: .any)["root.brandMark"]
        XCTAssertTrue(brandMark.waitForExistence(timeout: 30), "root screen did not appear")
        // 测试动作跑 Debug：调试信息与面板入口可见。
        XCTAssertTrue(app.descendants(matching: .any)["root.buildConfiguration"].exists)
        let debugButton = app.buttons["root.debugPanelButton"]
        XCTAssertTrue(debugButton.exists)

        debugButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["debug.environment.test"].waitForExistence(timeout: 10))
    }
}
