import XCTest

/// APP-12「我的」类页面的冒烟与设计稿比对截图（Debug 包 + 本机假服务 DebugFakeMe / DebugFakeWallet）。截图用例只在设置
/// TEST_RUNNER_COULI_SHOT_DIR 时运行（截到该目录，NATIVE/APP-12/shots/ios/）；冒烟用例 verify.sh 每次都跑。
@MainActor
final class MeShotTests: XCTestCase, TradeUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// `startTab` 为 false 时停在首页再点「我的」Tab（撤回同意后回到基本模式首页的截图：启动参数 `-CouliStartTab` 会在外壳重现时再切一次 Tab）。
    func me(_ fakeMe: String = "", _ extra: [String] = [], guest: Bool = false, startTab: Bool = true)
        -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
                    "-CouliHideDebugInfo", "1", "-CouliFakeWalletResetPending"]
        if startTab {
            args += ["-CouliStartTab", "me"]
        }
        if !guest {
            args.append("-CouliFakeTradeLoggedIn")
        }
        if !fakeMe.isEmpty {
            args += ["-CouliFakeMe", fakeMe]
        }
        app.launchArguments += args + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        if !startTab {
            ShellTabBar.tap(app, "我的")
        }
        return app
    }

    func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) {
        let target = element(app, id)
        // 宫格是 LazyVGrid：屏幕外的格子滚到附近才建出来
        var found = target.waitForExistence(timeout: timeout)
        for _ in 0..<5 where !found || !target.isHittable {
            app.swipeUp()
            found = target.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(found, "没有 \(id)")
        target.tap()
    }

    // MARK: - 冒烟（verify.sh 每次都跑）

    /// 「我的」已登录 → 设置（三组 + 退出登录）→ 隐私中心（系统权限一节、撤回同意）→ 返回；游客「我的」只有帮助中心与设置。
    func testSmokeMeSettingsPrivacy() {
        let app = me()
        XCTAssertTrue(element(app, "me.nickname").waitForExistence(timeout: 15), "没有昵称")
        XCTAssertTrue(element(app, "me.inviteCode").exists)
        tap(app, "me.settings")
        XCTAssertTrue(element(app, "settings.logout").waitForExistence(timeout: 10))
        tap(app, "settings.row.privacy_center")
        XCTAssertTrue(element(app, "privacy.permissions").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "privacy.withdraw").exists)
        app.terminate()

        let guest = me(guest: true)
        XCTAssertTrue(element(guest, "me.guest").waitForExistence(timeout: 15))
        XCTAssertFalse(element(guest, "me.bell").exists, "游客没有铃铛")
        XCTAssertFalse(element(guest, "me.wallet").exists, "游客没有钱包格")
        guest.terminate()
        resetFakeSession()
    }

    // MARK: - 截图（设计稿比对）

    func testShotsMe() throws {
        try requireShots()
        var app = me()
        XCTAssertTrue(element(app, "me.nickname").waitForExistence(timeout: 15))
        pause()
        save(app, "Me")
        app.terminate()
        app = me("guide=1")
        XCTAssertTrue(element(app, "me.guideBar").waitForExistence(timeout: 15))
        let eye = app.buttons["隐藏金额"].firstMatch
        XCTAssertTrue(eye.waitForExistence(timeout: 10))
        eye.tap()
        pause()
        save(app, "MeHidden")
        app.terminate()
        app = me("me=minor")
        XCTAssertTrue(element(app, "me.nickname").waitForExistence(timeout: 15))
        pause()
        save(app, "MeMinor")
        app.terminate()
        app = me(guest: true)
        XCTAssertTrue(element(app, "me.guest").waitForExistence(timeout: 15))
        pause()
        save(app, "MeGuest")
        app.terminate()
        for (size, name) in [("UICTContentSizeCategoryAccessibilityL", "Me-130"),
                             ("UICTContentSizeCategoryAccessibilityXXXL", "Me-200")] {
            app = me("", ["-UIPreferredContentSizeCategoryName", size])
            XCTAssertTrue(element(app, "me.nickname").waitForExistence(timeout: 15))
            pause()
            save(app, name)
            app.terminate()
        }
        app = me("", ["-CouliDebugLayoutWidth", "320"])
        XCTAssertTrue(element(app, "me.nickname").waitForExistence(timeout: 15))
        pause()
        save(app, "Me-320")
        // App 只支持竖屏（Info.plist UISupportedInterfaceOrientations 仅 Portrait），不截横屏 / 大屏
        app.terminate()
        resetFakeSession()
    }

    func testShotsSettings() throws {
        try requireShots()
        var app = me()
        tap(app, "me.settings")
        XCTAssertTrue(element(app, "settings.logout").waitForExistence(timeout: 10))
        pause()
        save(app, "Settings")
        tap(app, "settings.row.agreement")
        pause()
        save(app, "SettingsAgreementSheet")
        element(app, "settings.agreement.privacy").tap()
        pause()
        app.navigationBars.buttons.firstMatch.tap()
        tap(app, "settings.row.clear_cache")
        pause()
        save(app, "SettingsClearCache")
        app.buttons["清除"].tap()
        pause(0.5)
        save(app, "SettingsCacheCleared")
        tap(app, "settings.logout")
        pause()
        save(app, "SettingsLogoutConfirm")
        app.buttons["取消"].tap()
        nicknameShots(app)
        tap(app, "settings.row.notify")
        XCTAssertTrue(element(app, "notify.page").waitForExistence(timeout: 10))
        pause(1)
        save(app, "NotifySettingsOn")
        app.terminate()
        for (size, name) in [("UICTContentSizeCategoryAccessibilityXXXL", "Settings-200")] {
            app = me("", ["-UIPreferredContentSizeCategoryName", size])
            tap(app, "me.settings")
            XCTAssertTrue(element(app, "settings.page").waitForExistence(timeout: 10))
            pause()
            save(app, name)
            app.terminate()
        }
        app = me(guest: true)
        tap(app, "me.settings")
        XCTAssertTrue(element(app, "settings.guestFooter").waitForExistence(timeout: 10))
        pause()
        save(app, "SettingsGuest")
        app.terminate()
        resetFakeSession()
    }

    func testShotsPrivacyAndAbout() throws {
        try requireShots()
        var app = me(startTab: false)
        tap(app, "me.settings")
        tap(app, "settings.row.privacy_center")
        XCTAssertTrue(element(app, "privacy.withdraw").waitForExistence(timeout: 10))
        pause()
        save(app, "PrivacyCenter")
        tap(app, "privacy.withdraw")
        pause()
        save(app, "PrivacyCenterWithdraw")
        app.buttons["确认撤回"].tap()
        XCTAssertTrue(element(app, "basic.notice").waitForExistence(timeout: 15), "撤回后进入基本模式")
        XCTAssertFalse(app.staticTexts["个人信息保护提示"].waitForExistence(timeout: 2), "撤回后不自动弹首启弹窗")
        pause()
        save(app, "BasicMode")
        app.buttons["basic.settings"].tap()
        XCTAssertTrue(element(app, "settings.enableFull").waitForExistence(timeout: 10))
        pause()
        save(app, "SettingsBasic")
        tap(app, "settings.row.privacy_center")
        XCTAssertTrue(element(app, "privacy.enableFull").waitForExistence(timeout: 10))
        pause()
        save(app, "PrivacyCenterBasic")
        app.terminate()
        app = me("", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        tap(app, "me.settings")
        tap(app, "settings.row.privacy_center")
        XCTAssertTrue(element(app, "privacy.page").waitForExistence(timeout: 10))
        pause()
        save(app, "PrivacyCenter-200")
        app.terminate()
        app = me()
        tap(app, "me.settings")
        tap(app, "settings.row.about")
        XCTAssertTrue(element(app, "about.copy").waitForExistence(timeout: 10))
        pause()
        save(app, "About")
        app.terminate()
        resetFakeSession()
    }

    func testShotsRiskAndAppeal() throws {
        try requireShots()
        // 冻结：钱包「提现已暂停」提示条点进来（WalletRiskFrozen 的落点）
        var app = me("me=frozen", ["-CouliFakeWallet", "wallet=risk"])
        tap(app, "me.wallet")
        tap(app, "wallet.risk")
        XCTAssertTrue(element(app, "risk.primary").waitForExistence(timeout: 15))
        pause()
        save(app, "RiskNoticeFrozen")
        tap(app, "risk.primary")
        XCTAssertTrue(element(app, "appeal.input").waitForExistence(timeout: 15))
        pause()
        save(app, "AppealFrozen")
        element(app, "appeal.input").tap()
        element(app, "appeal.input").typeText("ceshi shensu")
        tap(app, "appeal.submit")
        XCTAssertTrue(element(app, "appeal.progress").waitForExistence(timeout: 15))
        pause()
        save(app, "AppealProgressFrozen")
        app.terminate()
        app = me("me=frozen_appealing,appeals=processing", ["-CouliFakeWallet", "wallet=risk"])
        tap(app, "me.wallet")
        tap(app, "wallet.risk")
        XCTAssertTrue(element(app, "risk.primary").waitForExistence(timeout: 15))
        pause()
        save(app, "RiskNoticeFrozenAppealing")
        app.terminate()
        app = me("me=frozen,appeals=revoked", ["-CouliFakeWallet", "wallet=risk"])
        tap(app, "me.wallet")
        tap(app, "wallet.risk")
        tap(app, "risk.primary")
        XCTAssertTrue(element(app, "appeal.result.lifted").waitForExistence(timeout: 15))
        pause()
        save(app, "AppealResultLiftedFrozen")
        app.terminate()
        app = me("me=frozen", ["-CouliFakeWallet", "wallet=risk", "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"])
        tap(app, "me.wallet")
        tap(app, "wallet.risk")
        XCTAssertTrue(element(app, "risk.page").waitForExistence(timeout: 15))
        pause()
        save(app, "RiskNoticeFrozen-200")
        app.terminate()
        resetFakeSession()
    }
}
