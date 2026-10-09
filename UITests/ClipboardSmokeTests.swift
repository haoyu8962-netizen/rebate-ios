import UIKit
import XCTest

/// 剪贴板识别冒烟（APP-07 brief §2.11、§3 iOS）：Debug 包 + 本机假服务（`-CouliFakeLoginServer`，parse 在本机回答）+ 计数
/// （`-CouliClipboardDiagnostics`：探测、parse 请求、App 写系统剪贴板的次数，不含内容）。测试进程往系统剪贴板写样例数据，模拟别的 App
/// 复制（演示链接与邀请码，没有个人信息）。断言：命中出提示条、点击前 0 次请求、点系统粘贴控件后恰好 1 次并打开详情、全程 App 写入次数为 0、
/// 系统剪贴板 changeCount 前后不变、从不出现系统「允许粘贴」弹窗；内容没变不再提示；敏感页（Login）回前台不读、返回首页不补出；游客粘贴
/// 邀请内容出邀请提示条、确认后进登录页且不发请求。设置 TEST_RUNNER_COULI_SHOT_DIR 时另跑截图用例。
@MainActor
final class ClipboardSmokeTests: XCTestCase {
    private let sampleLink = "【淘宝】全脂纯牛奶 https://e.tb.cn/h.Demo01?tk=Sample 「全脂纯牛奶 250ml」 复制这段话打开"

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = [], clip: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        if let clip {
            UIPasteboard.general.string = clip
        }
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliClipboardDiagnostics",
        ] + extra
        app.launch()
        XCTAssertTrue(element(app, "shell.tabBar").waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func diagnostics(_ app: XCUIApplication) -> String {
        let label = element(app, "clipboard.debug")
        XCTAssertTrue(label.waitForExistence(timeout: 5), "没有剪贴板计数")
        return label.label
    }

    /// 系统「允许粘贴」弹窗一次都不出（brief §3 iOS）：App 内与 springboard 上都没有。
    private func assertNoPasteAlert(_ app: XCUIApplication, _ step: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [app, springboard] {
            XCTAssertEqual(owner.alerts.count, 0, "\(step)：出现了系统弹窗")
            for title in ["允许粘贴", "Allow Paste", "不允许粘贴", "Don’t Allow Paste"] {
                XCTAssertFalse(owner.buttons[title].exists, "\(step)：出现了系统粘贴授权弹窗")
            }
        }
    }

    private func backgroundAndReturn(_ app: XCUIApplication, clip: String? = nil) {
        XCUIDevice.shared.press(.home)
        if let clip {
            UIPasteboard.general.string = clip
        }
        sleep(1)
        app.activate()
        XCTAssertTrue(element(app, "shell.tabBar").waitForExistence(timeout: 10) || element(app, "login.page").exists)
    }

    func testPromptThenTapUploadsOnceWithoutWritesOrPasteAlert() {
        let app = launch(clip: sampleLink)
        let changeCount = UIPasteboard.general.changeCount
        XCTAssertTrue(element(app, "clipboard.prompt").waitForExistence(timeout: 10), "命中链接没有出提示条")
        assertNoPasteAlert(app, "出提示条")
        XCTAssertTrue(diagnostics(app).contains("parse=0"), "点击前不发请求：\(diagnostics(app))")
        // 点提示条里的系统粘贴控件（UIPasteControl）：用户点了才交回正文，不出系统「允许粘贴」弹窗
        element(app, "clipboard.prompt.paste").tap()
        XCTAssertTrue(element(app, "product.buy").waitForExistence(timeout: 15), "点击后没有打开详情")
        assertNoPasteAlert(app, "点系统粘贴控件")
        let counts = diagnostics(app)
        XCTAssertTrue(counts.contains("parse=1"), "点击后恰好 1 次请求：\(counts)")
        XCTAssertTrue(counts.contains("writes=0"), "全程不写系统剪贴板：\(counts)")
        XCTAssertEqual(UIPasteboard.general.changeCount, changeCount, "系统剪贴板前后不变（e）")
    }

    func testSameContentNotPromptedAgainAndRefocusDoesNotRead() {
        let app = launch(clip: sampleLink + " 第二次")
        let prompt = element(app, "clipboard.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        element(app, "clipboard.prompt.close").tap()
        backgroundAndReturn(app)
        sleep(1)
        XCTAssertFalse(prompt.exists, "剪贴板内容没变：不再提示（c）")
        XCTAssertTrue(diagnostics(app).contains("detect=1"), "没变化不再探测：\(diagnostics(app))")
        assertNoPasteAlert(app, "回前台")
    }

    func testSensitiveLoginPageDoesNotReadAndNoCatchUp() {
        let app = launch(clip: nil)
        element(app, "shell.tabBar").buttons["订单"].firstMatch.tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "没有进登录页")
        let before = diagnostics(app)
        backgroundAndReturn(app, clip: sampleLink + " 登录页")
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 5))
        XCTAssertEqual(diagnostics(app), before, "停在 Login 回前台不读（d）")
        element(app, "login.close").tap()
        sleep(1)
        XCTAssertFalse(element(app, "clipboard.prompt").exists, "返回首页不补出")
        XCTAssertEqual(diagnostics(app), before)
        assertNoPasteAlert(app, "敏感页")
    }

    func testGuestInviteFromHomeCardPrefillsLoginWithoutRequest() {
        let invite = "好友邀请你一起省钱，邀请码 K7M3QX"
        let app = launch(clip: invite)
        sleep(1)
        XCTAssertFalse(element(app, "clipboard.prompt").exists, "只有纯邀请码、没有链接时不自动提示（G07）")
        element(app, "clipboard.homeCard.paste").tap()
        XCTAssertTrue(element(app, "clipboard.invitePrompt").waitForExistence(timeout: 10), "游客粘贴邀请内容没有出邀请提示条")
        XCTAssertTrue(app.buttons["粘贴并绑定邀请人"].exists, "邀请条按钮读屏名")
        element(app, "clipboard.invite.confirm").tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10), "确认后没有进登录页")
        XCTAssertTrue(diagnostics(app).contains("parse=0"), "游客只预填不上传：\(diagnostics(app))")
        assertNoPasteAlert(app, "邀请")
    }
}
