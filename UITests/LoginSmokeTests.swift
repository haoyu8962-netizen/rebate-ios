import XCTest

/// 冒烟（APP-05a 验收 5.2）：Debug 包 + 本机假服务（`-CouliFakeLoginServer`，URLProtocol 桩，不连任何地址）。
/// 游客点「订单」→ Login → 不勾协议点【获取验证码】→ 确认框 →【同意并继续】→ 发码 → 输入验证码 → 登录成功 → 回到
/// OrderList（pending_action）→ 设置【退出登录】→ 游客，再点「订单」又要登录。顺带核对 A11yHitLogin 的命中区与
/// A11yFocusLogin 的阅读顺序。设置环境变量 TEST_RUNNER_COULI_SHOT_DIR 时另把截图写到该目录，并跑设计稿比对的截图用例。
@MainActor
final class LoginSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], hideDebug: Bool = true, waitShell: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1"]
        if hideDebug {
            app.launchArguments += ["-CouliHideDebugInfo", "1"]
        }
        app.launchArguments += extra
        app.launch()
        if waitShell {
            XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openLoginFromOrders(_ app: XCUIApplication) {
        ShellTabBar.tap(app, "订单")
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "游客点订单没有进登录页")
    }

    private func typePhone(_ app: XCUIApplication, _ phone: String) {
        let field = app.textFields["login.phone"]
        field.tap()
        field.typeText(phone)
    }

    /// 勾选协议后发码，进验证码步。
    private func reachCodeStep(_ app: XCUIApplication, phone: String = "13800005678") {
        typePhone(app, phone)
        element(app, "login.agreeCheckbox").tap()
        app.buttons["login.getCode"].tap()
        XCTAssertTrue(element(app, "login.codeTitle").waitForExistence(timeout: 10), "没有进验证码步")
    }

    private func typeCode(_ app: XCUIApplication, _ code: String) {
        let field = app.textFields["login.code"]
        field.tap()
        // 先清掉已输入的码（验证码错误时保留原输入）。
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + code)
    }

    func testSmokeLoginResumesPendingAndLogout() {
        let app = launch(hideDebug: false)
        openLoginFromOrders(app)
        checkHitTargetsAndOrder(app)
        save(app, "Login")
        typePhone(app, "13800005678")
        app.buttons["login.getCode"].tap()
        // 未勾选：LoginAgreeConfirm，正文里两个协议链接可单独聚焦、命中区不小于 44pt（共性 8）。
        let confirmLink = element(app, "login.confirm.agreement")
        XCTAssertTrue(confirmLink.waitForExistence(timeout: 5), "未勾选时没有弹确认框")
        XCTAssertGreaterThanOrEqual(confirmLink.frame.height - 8, 43.5)
        XCTAssertGreaterThanOrEqual(element(app, "login.confirm.privacy").frame.height - 8, 43.5)
        save(app, "LoginAgreeConfirm")
        app.buttons["同意并继续"].tap()
        XCTAssertTrue(element(app, "login.codeTitle").waitForExistence(timeout: 10), "同意后没有发码进验证码步")
        XCTAssertTrue(element(app, "login.countdown").waitForExistence(timeout: 3), "发码后没有倒计时")
        save(app, "LoginCode-empty")
        typeCode(app, "482913")
        save(app, "LoginCode-filled")
        app.buttons["login.submit"].tap()
        // APP-08 起 OrderList 是真实的订单页（不再是占位页）：以订单页右上常驻的「未跟单？去找回」为准
        XCTAssertTrue(element(app, "orders.findEntry").waitForExistence(timeout: 10), "登录后没有回到原意图 OrderList")
        // 订单页在登录页下面早已存在：等登录页的关闭动画结束再断言（rule-gaps I23，负载高时关闭动画慢）
        XCTAssertTrue(element(app, "login.page").waitForNonExistence(timeout: 10), "登录页已关闭")
        save(app, "Login-success-resumed-pending")

        // 登出：设置占位页（调试面板入口；「我的」是占位页）。
        ShellTabBar.tap(app, "首页")
        app.buttons["root.debugPanelButton"].tap()
        let session = element(app, "debug.login.session")
        for _ in 0..<6 where !session.exists {
            app.swipeUp()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "debug.login.session").label, "session: logged in")
        app.buttons["debug.settings"].tap()
        XCTAssertTrue(app.buttons["settings.logout"].waitForExistence(timeout: 10))
        save(app, "Settings-logged-in")
        app.buttons["settings.logout"].tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "退出登录")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        save(app, "Settings-logout-confirm")
        confirm.tap()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["settings.logout"].waitForExistence(timeout: 2), "退出后不再显示退出登录")
        save(app, "Logout-back-to-guest")
        openLoginFromOrders(app)
        save(app, "Logout-orders-requires-login")
    }

    /// A11yHitLogin（共性 6）：协议复选框单元与两个协议链接各自不小于 44pt，互不重叠；A11yFocusLogin：阅读顺序。
    private func checkHitTargetsAndOrder(_ app: XCUIApplication) {
        // 读屏框含焦点环外扩（focus.offset + focus.width，共 4pt）；命中区按去掉外扩后的框核对。
        let ring: CGFloat = 4
        let box = element(app, "login.agreeCheckbox").frame.insetBy(dx: ring, dy: ring)
        let agreement = element(app, "login.link.agreement").frame.insetBy(dx: ring, dy: ring)
        let privacy = element(app, "login.link.privacy").frame.insetBy(dx: ring, dy: ring)
        for frame in [box, agreement, privacy] {
            XCTAssertGreaterThanOrEqual(frame.height, 43.5, "\(frame)")
            XCTAssertGreaterThanOrEqual(frame.width, 43.5, "\(frame)")
        }
        XCTAssertFalse(box.intersects(agreement.insetBy(dx: 0.5, dy: 0.5)), "\(box) \(agreement)")
        XCTAssertFalse(agreement.intersects(privacy.insetBy(dx: 0.5, dy: 0.5)), "\(agreement) \(privacy)")
        // 读屏顺序：关闭 → 设置 → 标题 → 手机号 → 复选框 → 用户协议 → 隐私政策 → 获取验证码 → 邀请码入口 → 登录遇到问题。
        let order = ["login.close", "login.settings", "login.title", "login.phone", "login.agreeCheckbox",
                     "login.link.agreement", "login.link.privacy", "login.getCode", "login.inviteEntry", "login.help"]
        let frames = order.map { element(app, $0).frame }
        for index in 1..<frames.count {
            let previous = frames[index - 1]
            let current = frames[index]
            let sameRow = abs(previous.midY - current.midY) < 12
            XCTAssertTrue(sameRow ? current.minX > previous.minX : current.minY >= previous.minY - 1,
                          "\(order[index - 1]) 应在 \(order[index]) 之前")
        }
    }

    // MARK: - 设计稿比对截图（只在给了截图目录时运行）

    private func requireShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
    }

    func testShotsCodeErrorsAndDialogs() throws {
        try requireShots()
        let app = launch()
        openLoginFromOrders(app)
        element(app, "login.inviteEntry").tap()
        save(app, "Login-invite-expanded")
        reachCodeStep(app)
        typeCode(app, "200020")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(element(app, "login.codeError").waitForExistence(timeout: 10))
        save(app, "LoginCode-wrong-code")
        typeCode(app, "444444")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["联系客服申诉"].waitForExistence(timeout: 10))
        save(app, "LoginCodeBlocked")
        app.buttons["知道了"].tap()
        typeCode(app, "100070")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["联系客服"].waitForExistence(timeout: 10))
        save(app, "LoginDeletionProcessing")
    }

    func testShotsInviteBoundAndFailed() throws {
        try requireShots()
        var app = launch()
        openLoginFromOrders(app)
        reachCodeStep(app)
        let invite = app.textFields["login.invite"]
        invite.tap()
        invite.typeText("K7M2QX")
        typeCode(app, "482913")
        save(app, "LoginCodeInvite")
        app.buttons["login.submit"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "login.page"))
        waitForExpectations(timeout: 10)
        save(app, "LoginInviteBound")
        app.terminate()
        app = launch()
        openLoginFromOrders(app)
        reachCodeStep(app)
        let again = app.textFields["login.invite"]
        again.tap()
        again.typeText("K0M2QX")
        typeCode(app, "482913")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["去补填"].waitForExistence(timeout: 10))
        save(app, "LoginInviteFailed")
    }

    func testShotsRateLimitAndSessionExpired() throws {
        try requireShots()
        var app = launch()
        openLoginFromOrders(app)
        typePhone(app, "13900000000")
        element(app, "login.agreeCheckbox").tap()
        app.buttons["login.getCode"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["login.getCode"].isEnabled, "42901 按 Retry-After 禁用发码入口")
        save(app, "Login-rate-limited-42901")
        app.terminate()
        app = launch(hideDebug: false)
        app.buttons["root.debugPanelButton"].tap()
        let expired = app.buttons["debug.login.expired"]
        for _ in 0..<6 where !expired.exists {
            app.swipeUp()
        }
        expired.tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10))
        save(app, "LoginSessionExpired")
    }

    func testShotsRestrictedLoginFromForceUpdate() throws {
        try requireShots()
        let app = launch(["-CouliUpdateScenario", "force"], waitShell: false)
        XCTAssertTrue(app.buttons["update.force.deleteAccount"].waitForExistence(timeout: 30))
        app.buttons["update.force.deleteAccount"].tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10))
        save(app, "Login-restricted-from-force-update")
        reachCodeStep(app)
        save(app, "LoginCode-restricted")
        typeCode(app, "104050")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["update.force.deleteAccount"].waitForExistence(timeout: 10), "10405 回到强更页")
        XCTAssertFalse(element(app, "login.page").exists)
        save(app, "Login-restricted-no-account")
        app.terminate()
        let reset = XCUIApplication()
        reset.launchArguments += ["-CouliUpdateReset", "1"]
        reset.launch()
        reset.terminate()
    }

    func testShotsLargeTextNarrowAndKeyboard() throws {
        try requireShots()
        for (size, name) in [("UICTContentSizeCategoryXXXL", "AdaptLargeTextLogin"),
                             ("UICTContentSizeCategoryAccessibilityL", "AdaptLargeText200Login")] {
            let app = launch(["-UIPreferredContentSizeCategoryName", size])
            openLoginFromOrders(app)
            save(app, name)
            typePhone(app, "13800005678")
            app.buttons["login.getCode"].tap()
            XCTAssertTrue(element(app, "login.confirm.agreement").waitForExistence(timeout: 5))
            save(app, name + "AgreeConfirm")
            app.buttons["同意并继续"].tap()
            XCTAssertTrue(element(app, "login.codeTitle").waitForExistence(timeout: 10))
            typeCode(app, "482913")
            save(app, name.replacingOccurrences(of: "Login", with: "LoginCode"))
            app.terminate()
        }
        for (extra, suffix) in [([String](), ""), (["-UIPreferredContentSizeCategoryName",
                                                    "UICTContentSizeCategoryAccessibilityL"], "-200")] {
            let app = launch(["-CouliDebugLayoutWidth", "320"] + extra)
            openLoginFromOrders(app)
            save(app, "AdaptNarrow320\(suffix)-Login")
            typePhone(app, "13800005678")
            app.buttons["login.getCode"].tap()
            XCTAssertTrue(element(app, "login.confirm.agreement").waitForExistence(timeout: 5))
            save(app, "AdaptNarrow320\(suffix)-LoginAgreeConfirm")
            app.buttons["同意并继续"].tap()
            XCTAssertTrue(element(app, "login.codeTitle").waitForExistence(timeout: 10))
            typeCode(app, "482913")
            save(app, "AdaptNarrow320\(suffix)-LoginCode")
            app.terminate()
        }
        let app = launch()
        openLoginFromOrders(app)
        app.textFields["login.phone"].tap()
        save(app, "Login-keyboard")
        reachCodeStep(app)
        app.textFields["login.code"].tap()
        save(app, "AdaptKeyboardLoginCode")
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
