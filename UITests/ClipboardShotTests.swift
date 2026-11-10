import UIKit
import XCTest

/// 剪贴板识别的设计稿比对截图（APP-07 brief §2.10）：只在设置 TEST_RUNNER_COULI_SHOT_DIR 时运行。样例数据全部是演示链接与邀请码。
@MainActor
final class ClipboardShotTests: XCTestCase {
    private let sampleLink = "【淘宝】全脂纯牛奶 https://e.tb.cn/h.Demo01?tk=Sample 「全脂纯牛奶 250ml」 复制这段话打开"

    override func setUp() async throws {
        continueAfterFailure = false
        guard let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("只在设置 TEST_RUNNER_COULI_SHOT_DIR 时截图")
        }
    }

    private func launch(_ extra: [String] = [], clip: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        // 没给样例时放一段普通文字：上一张截图留下的链接不会在冷启动时自动出提示条
        UIPasteboard.general.string = clip ?? "今天下午三点见"
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1",
        ] + extra
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["COULI_SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// 冷启动后再往系统剪贴板写样例（不触发回前台，不出自动提示条），点首页「去粘贴」卡的系统粘贴控件，等结果出现。
    private func pasteFromHomeCard(_ text: String, expect id: String, _ extra: [String] = []) -> XCUIApplication {
        let app = launch(extra, clip: nil)
        UIPasteboard.general.string = text
        element(app, "clipboard.homeCard.paste").tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 15), id)
        return app
    }

    func testShotsPromptDetailAndAdaptations() {
        var app = launch(clip: sampleLink + " 截图")
        XCTAssertTrue(element(app, "clipboard.prompt").waitForExistence(timeout: 10))
        save(app, "HomeClipboard")
        element(app, "clipboard.prompt.paste").tap()
        XCTAssertTrue(element(app, "product.buy").waitForExistence(timeout: 15))
        save(app, "HomeClipboard-tap-detail")
        for (extra, name) in [
            (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"],
             "AdaptLargeText200HomeClipboard"),
            (["-CouliDebugLayoutWidth", "320"], "AdaptNarrowHomeClipboard"),
        ] {
            app = launch(extra, clip: sampleLink + " " + name)
            XCTAssertTrue(element(app, "clipboard.prompt").waitForExistence(timeout: 10), name)
            save(app, name)
        }
    }

    func testShotsInviteAndLoginCodeInvite() {
        var app = pasteFromHomeCard("好友邀请你一起省钱，邀请码 K7M3QX", expect: "clipboard.invitePrompt")
        save(app, "HomeClipboardInvite")
        element(app, "clipboard.invite.confirm").tap()
        XCTAssertTrue(element(app, "login.page").waitForExistence(timeout: 10))
        let phone = app.textFields["login.phone"]
        phone.tap()
        phone.typeText("13800005678")
        element(app, "login.agreeCheckbox").tap()
        app.buttons["login.getCode"].tap()
        XCTAssertTrue(element(app, "login.codeTitle").waitForExistence(timeout: 10))
        let invite = app.textFields["login.invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 5))
        XCTAssertEqual(invite.value as? String, "K7M3QX", "进入验证码页时预填邀请码")
        XCTAssertTrue(element(app, "login.invitePaste").exists, "邀请码行【粘贴】")
        save(app, "LoginCodeInvite")
        app = pasteFromHomeCard(
            "邀请码 K7M3QX 一起来", expect: "clipboard.invitePrompt",
            ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        )
        save(app, "AdaptLargeText200HomeClipboardInvite")
    }

    func testShotsResultsAndSearchTyping() {
        var app = launch(clip: nil)
        save(app, "Main-pasteCard")
        element(app, "home.search").tap()
        XCTAssertTrue(element(app, "clipboard.searchPaste").waitForExistence(timeout: 10))
        save(app, "SearchTyping")
        app = pasteFromHomeCard("「全脂纯牛奶 250ml」 好喝又便宜", expect: "clipboard.unrecognized")
        save(app, "HomePaste-30132")
        element(app, "clipboard.searchByName").tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 10))
        save(app, "HomePaste-30132-searchByName")
        app = pasteFromHomeCard("https://e.tb.cn/h.Demo02?tk=multi", expect: "clipboard.cardList")
        save(app, "HomeClipboard-multiCards")
        app = pasteFromHomeCard("https://e.tb.cn/h.Demo03?tk=fail", expect: "clipboard.notice")
        save(app, "HomeClipboard-50001")
        app = pasteFromHomeCard("https://e.tb.cn/h.Demo04?tk=busy", expect: "clipboard.notice")
        save(app, "HomeClipboard-42901")
    }
}
