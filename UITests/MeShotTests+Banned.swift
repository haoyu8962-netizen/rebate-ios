import XCTest

/// MeShotTests 的分段（封禁版、昵称子页与客服半屏截图）。
extension MeShotTests {
    func testShotsBanned() throws {
        try requireShots()
        var app: XCUIApplication
        for (state, name) in [("me=banned", "RiskNoticeBanned"), ("me=appealing,appeals=processing",
                                                                  "RiskNoticeBannedAppealing"),
                              ("me=banned,appeals=upheld", "RiskNoticeBannedUpheld")] {
            app = me(state)
            tap(app, "me.wallet")
            XCTAssertTrue(element(app, "risk.primary").waitForExistence(timeout: 15), "10006 没落到 RiskNotice")
            pause(1)
            save(app, name)
            if name == "RiskNoticeBannedUpheld" {
                tap(app, "risk.primary")
                XCTAssertTrue(element(app, "appeal.result.upheld").waitForExistence(timeout: 15))
                pause()
                save(app, "AppealResultUpheld")
            }
            if name == "RiskNoticeBannedAppealing" {
                tap(app, "risk.primary")
                XCTAssertTrue(element(app, "appeal.progress").waitForExistence(timeout: 15))
                pause()
                save(app, "AppealProgress")
            }
            app.terminate()
        }
        resetFakeSession()
    }

    /// R1-08（冒烟，verify 每次跑）：申诉维持结果页有时间线（已提交 / 处理中 / 处理结果）与原申诉内容；当前状态仍按本次 getMe.risk。
    func testSmokeUpheldTimelineAndContent() {
        let app = me("me=banned,appeals=upheld")
        tap(app, "me.wallet")
        XCTAssertTrue(element(app, "risk.primary").waitForExistence(timeout: 15), "10006 没落到 RiskNotice")
        tap(app, "risk.primary")
        XCTAssertTrue(element(app, "appeal.result.upheld").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "appeal.timeline").waitForExistence(timeout: 5), "没有时间线")
        XCTAssertTrue(element(app, "appeal.timeline.result").exists, "没有处理结果一行")
        XCTAssertTrue(element(app, "appeal.content").waitForExistence(timeout: 5), "没有原申诉内容")
        app.terminate()
        resetFakeSession()
    }

    func nicknameShots(_ app: XCUIApplication) {
        tap(app, "settings.row.nickname")
        XCTAssertTrue(element(app, "nickname.input").waitForExistence(timeout: 10))
        pause()
        save(app, "SettingsNickname")
        element(app, "nickname.clear").tap()
        element(app, "nickname.input").tap()
        element(app, "nickname.input").typeText("mingan")
        element(app, "nickname.save").tap()
        XCTAssertTrue(element(app, "nickname.error").waitForExistence(timeout: 10))
        pause()
        save(app, "SettingsNicknameSensitive")
        element(app, "nickname.clear").tap()
        element(app, "nickname.input").typeText("xiaoli")
        element(app, "nickname.save").tap()
        XCTAssertTrue(element(app, "settings.logout").waitForExistence(timeout: 10))
        pause(0.3)
        save(app, "SettingsNicknameSaved")
    }

    func testShotsCustomerService() throws {
        try requireShots()
        for (state, name, extra) in [("", "CsHandoff", [String]()), ("wechat=no", "CsWechatMissing", []),
                                     ("cs_open=fail", "CsOpenFailed", []),
                                     ("wechat=no", "CsWechatMissing-200",
                                      [
                                          "-UIPreferredContentSizeCategoryName",
                                          "UICTContentSizeCategoryAccessibilityXXXL",
                                      ])] {
            let app = me(state, extra)
            tap(app, "me.grid.cs")
            XCTAssertTrue(element(app, "cs.title").waitForExistence(timeout: 10))
            if name == "CsOpenFailed" {
                tap(app, "cs.openWechat")
                XCTAssertTrue(element(app, "cs.retry").waitForExistence(timeout: 10))
            }
            if name == "CsWechatMissing" {
                pause()
                save(app, name)
                tap(app, "cs.copyLink")
                XCTAssertTrue(element(app, "cs.toast").waitForExistence(timeout: 5))
                pause(0.3)
                save(app, "CsCopyLinkDone")
            } else {
                pause()
                save(app, name)
            }
            app.terminate()
        }
        resetFakeSession()
    }
}
