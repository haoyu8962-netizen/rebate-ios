import XCTest

/// FU-IOS-BINDPHONE-LAYOUT（D10-1223 第 6 条）验收截图：绑定手机号页与短信登录页 × 四档（正常 / 200% / 320 宽 + 200% / AXXXL）。
/// 只在设置 TEST_RUNNER_COULI_SHOT_DIR 时运行；文件名 `<页>-<档>-<状态>.png`。
@MainActor
final class BindPhoneLayoutShotTests: XCTestCase {
    private static let tiers: [(String, [String])] = [
        ("normal", []),
        ("200", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]),
        ("w320-200", ["-CouliDebugLayoutWidth", "320",
                      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]),
        ("AXXXL", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]),
    ]

    override func setUp() async throws {
        continueAfterFailure = false
        guard let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
    }

    func testShotsBindPhoneFourTiers() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            openLogin(app)
            reveal(app, "login.wechat").tap()
            XCTAssertTrue(app.buttons["同意并继续"].waitForExistence(timeout: 5))
            app.buttons["同意并继续"].tap()
            let bind = app.buttons["去绑定"]
            XCTAssertTrue(bind.waitForExistence(timeout: 10))
            if !bind.isHittable {
                app.swipeUp()
            }
            bind.tap()
            XCTAssertTrue(element(app, "bindPhone.page").waitForExistence(timeout: 10))
            save(app, "BindPhone-\(tier)-empty")
            let phone = app.textFields["bindPhone.phone"]
            phone.tap()
            phone.typeText("13800005678")
            save(app, "BindPhone-\(tier)-keyboard")
            let send = app.buttons["bindPhone.getCode"]
            if !send.isHittable {
                app.swipeUp()
            }
            send.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "秒后重新获取")).firstMatch
                .waitForExistence(timeout: 10))
            app.textFields["bindPhone.code"].tap()
            save(app, "BindPhone-\(tier)-countdown")
            element(app, "bindPhone.title").tap()
            app.swipeUp()
            save(app, "BindPhone-\(tier)-scrolled")
            app.terminate()
        }
    }

    func testShotsLoginFourTiers() {
        for (tier, extra) in Self.tiers {
            let app = launch(extra)
            openLogin(app)
            save(app, "Login-\(tier)-phone-empty")
            let phone = app.textFields["login.phone"]
            phone.tap()
            phone.typeText("13800005678")
            save(app, "Login-\(tier)-phone-keyboard")
            element(app, "login.title").tap()
            app.swipeUp()
            save(app, "Login-\(tier)-phone-scrolled")
            app.swipeDown()
            reveal(app, "login.agreeCheckbox").tap()
            reveal(app, "login.getCode").tap()
            XCTAssertTrue(element(app, "login.codeTitle").waitForExistence(timeout: 10), "没有进验证码步")
            save(app, "Login-\(tier)-code")
            app.terminate()
        }
    }

    // MARK: - 小件

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
                                "-CouliHideDebugInfo", "1"]
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        return app
    }

    private func openLogin(_ app: XCUIApplication) {
        ShellTabBar.tap(app, "订单")
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "游客点订单没有进登录页")
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        var found = target.waitForExistence(timeout: 5)
        let screen = app.windows.firstMatch.frame
        for _ in 0..<6 where !found || !target.isHittable || !screen.contains(target.frame) {
            app.swipeUp()
            found = target.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "没有 \(id)")
        return target
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
