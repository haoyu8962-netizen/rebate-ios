import XCTest

/// APP-05b 冒烟与设计稿比对截图（Debug 包 + 本机假服务 `-CouliFakeLoginServer`，假微信 / Apple 适配器 DebugFakeOAuth，不调任何 SDK、
/// 不连任何地址）：游客点「订单」→ Login 的第三方区 → 未勾协议点微信 → 确认框 → 第三方新号 → LoginBindPhoneGuide →【去绑定】→
/// BindPhone 发码、绑定 → 恢复「订单」。截图用例只在设置 TEST_RUNNER_COULI_SHOT_DIR 时运行（NATIVE/APP-05b/shots/ios/）。
@MainActor
final class OAuthBindPhoneSmokeTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
                                "-CouliHideDebugInfo", "1"]
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(element(app, "shell.tabBar").waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openLogin(_ app: XCUIApplication) {
        element(app, "shell.tabBar").buttons["订单"].firstMatch.tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "游客点订单没有进登录页")
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        var found = target.waitForExistence(timeout: 5)
        let screen = app.windows.firstMatch.frame
        for _ in 0..<4 where !found || !target.isHittable || !screen.contains(target.frame) {
            app.swipeUp()
            found = target.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "没有 \(id)")
        return target
    }

    /// 点微信 → 确认框同意 → 引导出现。
    private func wechatToGuide(_ app: XCUIApplication, shots: Bool = false) {
        openLogin(app)
        let wechat = reveal(app, "login.wechat")
        if shots {
            save(app, "Login-wechat")
        }
        wechat.tap()
        XCTAssertTrue(element(app, "login.confirm.agreement").waitForExistence(timeout: 5), "未勾选时没有弹确认框")
        if shots {
            save(app, "Login-wechat-agree-confirm")
        }
        app.buttons["同意并继续"].tap()
        XCTAssertTrue(app.buttons["去绑定"].waitForExistence(timeout: 10), "第三方新号没有弹绑手机引导")
        XCTAssertTrue(element(app, "login.page").waitForNonExistence(timeout: 10), "登录页已关闭")
    }

    private func type(_ app: XCUIApplication, _ id: String, _ text: String) {
        let field = input(app, id)
        field.tap()
        // 多行输入框点在文字中间时光标不在末尾：有清除按钮（聚焦且非空时出现）就用它清空，再点回输入框
        let clear = element(app, id + "Clear")
        if clear.waitForExistence(timeout: 1) {
            clear.tap()
            field.tap()
        }
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    /// 输入框（手机号是纵向轴的 TextField，放不下时换行完整显示，R1-07；按系统版本可能是 textField 或 textView）。
    private func input(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.textFields[id].exists ? app.textFields[id] : app.textViews[id]
    }

    private func toBindPhone(_ app: XCUIApplication) {
        app.buttons["去绑定"].tap()
        XCTAssertTrue(element(app, "bindPhone.page").waitForExistence(timeout: 10), "没有进绑手机页")
    }

    /// 发码并填码（假服务：验证码 123456 成功）。
    private func fill(_ app: XCUIApplication, phone: String, code: String = "123456") {
        type(app, "bindPhone.phone", phone)
        app.buttons["bindPhone.getCode"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "秒后重新获取")).firstMatch
                .waitForExistence(timeout: 10), "发码后没有倒计时"
        )
        type(app, "bindPhone.code", code)
    }

    // MARK: - 冒烟（verify.sh 每次都跑）

    func testSmokeWechatNewUserBindPhoneResumesOrders() {
        let app = launch()
        wechatToGuide(app)
        toBindPhone(app)
        fill(app, phone: "13800138000")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(element(app, "orders.findEntry").waitForExistence(timeout: 10), "绑定后没有恢复「订单」")
        XCTAssertTrue(element(app, "bindPhone.page").waitForNonExistence(timeout: 10), "绑手机页已出栈")
    }

    /// 第 1 轮 R1-07：320 宽 + 200% 字号，手机号未聚焦时清除按钮不占宽度、号码完整（输入框换行而不是省略）；聚焦且非空时才出现清除按钮。
    func testNarrowLargeTextPhoneClearOnlyWhenFocused() {
        let app = launch(["-CouliDebugLayoutWidth", "320",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        wechatToGuide(app)
        toBindPhone(app)
        type(app, "bindPhone.phone", "13800005678")
        XCTAssertTrue(element(app, "bindPhone.phoneClear").waitForExistence(timeout: 5), "聚焦且非空：显示清除按钮")
        app.textFields["bindPhone.code"].tap()
        XCTAssertTrue(element(app, "bindPhone.phoneClear").waitForNonExistence(timeout: 5), "未聚焦：不显示清除按钮")
        let phone = input(app, "bindPhone.phone")
        XCTAssertEqual(phone.value as? String, "13800005678")
        XCTAssertGreaterThan(phone.frame.height, 0)
    }

    // MARK: - 设计稿比对截图（只在给了截图目录时运行）

    private func requireShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
    }

    func testShotsMainFlow() throws {
        try requireShots()
        let app = launch()
        wechatToGuide(app, shots: true)
        save(app, "LoginBindPhoneGuide")
        toBindPhone(app)
        save(app, "BindPhone-empty")
        input(app, "bindPhone.phone").tap()
        save(app, "BindPhone-keyboard")
        fill(app, phone: "13800005678")
        save(app, "BindPhone")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(app.buttons["并入"].waitForExistence(timeout: 10), "没有弹并号确认")
        save(app, "BindPhoneMerge")
        app.buttons["取消"].tap()
        save(app, "BindPhoneMerge-cancelled")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(app.buttons["并入"].waitForExistence(timeout: 10))
        app.buttons["并入"].tap()
        save(app, "BindPhoneMerge-confirm-unavailable")
        sleep(2)
        fill(app, phone: "13800004444")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(app.buttons["联系客服申诉"].waitForExistence(timeout: 10), "44001 没有申诉入口")
        save(app, "BindPhone-risk-44001")
        app.buttons["知道了"].tap()
        fill(app, phone: "13800138000", code: "111111")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(element(app, "bindPhone.codeError").waitForExistence(timeout: 10))
        save(app, "BindPhone-wrong-code-20002")
        type(app, "bindPhone.code", "123456")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(element(app, "orders.findEntry").waitForExistence(timeout: 10))
        save(app, "BindPhone-done-resumed-pending")
    }

    /// G07：结果未知 → 待确认卡（假服务 13800009999 第一次响应丢失）→【确认上一次提交】→ 已绑定。
    func testShotsPendingConfirm() throws {
        try requireShots()
        let app = launch()
        wechatToGuide(app)
        toBindPhone(app)
        fill(app, phone: "13800009999")
        app.buttons["bindPhone.submit"].tap()
        XCTAssertTrue(element(app, "bindPhone.pending").waitForExistence(timeout: 15), "结果未知没有进待确认")
        save(app, "BindPhone-pending-confirm")
        app.buttons["bindPhone.pending.confirm"].tap()
        XCTAssertTrue(element(app, "orders.findEntry").waitForExistence(timeout: 10))
        save(app, "BindPhone-pending-confirmed")
    }

    /// 引导【暂不】：只恢复（订单只需登录 → 打开）。
    func testShotsGuideSkip() throws {
        try requireShots()
        let app = launch()
        wechatToGuide(app)
        app.buttons["暂不"].tap()
        XCTAssertTrue(element(app, "orders.findEntry").waitForExistence(timeout: 10))
        save(app, "LoginBindPhoneGuide-skip-resumed-pending")
    }

    /// 关掉假微信适配器（同 Release：正式适配器恒不可用）：只剩「通过 Apple 登录」（Release 里 Apple 也按 entitlement 开关隐藏，I01）。
    func testShotsWechatHidden() throws {
        try requireShots()
        let app = launch(["-CouliFakeOAuth", "wechat=hidden"])
        openLogin(app)
        _ = reveal(app, "login.apple")
        XCTAssertFalse(element(app, "login.wechat").exists, "适配器不可用时不显示微信")
        save(app, "Login-adapter-unavailable-no-wechat")
    }

    /// 第三方登录 44001：弹窗带申诉入口，不套用短信注册的专用说明。
    func testShotsLoginRisk() throws {
        try requireShots()
        let app = launch(["-CouliFakeOAuth", "login=risk"])
        openLogin(app)
        element(app, "login.agreeCheckbox").tap()
        reveal(app, "login.wechat").tap()
        XCTAssertTrue(app.buttons["联系客服申诉"].waitForExistence(timeout: 10))
        save(app, "Login-wechat-risk-44001")
    }

    /// 200% 字号与 320 宽：登录页第三方区、引导、绑手机页（含键盘）、并号弹窗。
    func testShotsAdaptations() throws {
        try requireShots()
        let variants: [([String], String)] = [
            (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], "AdaptLargeText200"),
            (["-CouliDebugLayoutWidth", "320"], "AdaptNarrow320"),
        ]
        for (extra, prefix) in variants {
            let app = launch(extra)
            openLogin(app)
            _ = reveal(app, "login.wechat")
            save(app, "\(prefix)Login-wechat")
            element(app, "login.wechat").tap()
            XCTAssertTrue(app.buttons["同意并继续"].waitForExistence(timeout: 5))
            app.buttons["同意并继续"].tap()
            XCTAssertTrue(app.buttons["去绑定"].waitForExistence(timeout: 10))
            save(app, "\(prefix)LoginBindPhoneGuide")
            toBindPhone(app)
            save(app, "\(prefix)BindPhone")
            fill(app, phone: "13800005678")
            save(app, "\(prefix)BindPhone-keyboard")
            app.buttons["bindPhone.submit"].tap()
            XCTAssertTrue(app.buttons["并入"].waitForExistence(timeout: 10))
            save(app, "\(prefix)BindPhoneMerge")
            app.terminate()
        }
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
