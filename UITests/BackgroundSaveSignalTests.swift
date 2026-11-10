import XCTest

/// FU-IOS-0712 第 1 轮修复 R1-05：进后台的「保存完成」信号要等恢复内容与后台标记确认提交。启动参数挂住提交（永不完成）时，测试等不到信号，
/// 在上限内判失败（这里用 XCTExpectFailure 收下这次预期的失败），不会提前放行、也不会提前结束进程。不用固定延时。
@MainActor
final class BackgroundSaveSignalTests: XCTestCase {
    func testHeldCommitNeverSignalsSoTheWaitFailsWithinTheCeilingInsteadOfKillingEarly() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliUITestHoldBackgroundCommit",
        ]
        app.launch()
        XCTAssertTrue(
            ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳"
        )
        let ceiling: TimeInterval = 10
        let started = Date()
        var signalled = true
        XCTExpectFailure("挂住提交：等不到保存完成信号，应在上限内判失败") {
            signalled = UIWait.pressHomeAndWaitForBackgroundSave(app, ceiling: ceiling)
        }
        XCTAssertFalse(signalled, "挂住提交时不发保存完成信号")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), ceiling, "等满上限才判失败，没有提前放行")
        XCTAssertNotEqual(app.state, .notRunning, "测试没有提前结束进程")
        app.terminate()
    }
}
