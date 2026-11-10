import Foundation
import UIKit
import XCTest

/// APP-09v-e 的 UI 测试入口：真实 App（Debug）+ 本机假服务 + `COULI_FAKE_WALLET_VISUAL`（带 `summary` 才打开只读记录 `debug.wallet.log`）。
///
/// 新可选键（交回 §2，实现方在 App target 的 `#if DEBUG` 里接，Release 不存在；只走环境变量）：
/// `payout: {"account": <PayoutAccount 报文>, "saveError": {"code": <Int>, "data": {…}}}`：
/// - `account`：`GET /v1/me/payout-account` 回它（先于 `-CouliFakeWallet payout=…`）；
/// - `saveError`：`PUT /v1/me/payout-account` 过了 step-up 后回这个错误（覆盖 30303 / 30308 / 40901，`save=` 开关只有 30307 / 44001）。
///
/// 新记录项（同一 `debug.wallet.log`，实名 / 劳务不走网络管线，靠 FakeRealName / FakeLabor 记）：
/// `backend:realname.submit`、`backend:labor.current`、`backend:labor.sign`。**只记动作名，不记入参**。
@MainActor
protocol PayoutVisualUITest: WithdrawVisualUITest {}

extension PayoutVisualUITest {
    func visualPayout() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["visualPayout"] as? [String: Any], "缺 visualPayout")
    }

    func account(_ name: String) throws -> [String: Any] {
        let all = try XCTUnwrap(visualPayout()["payout"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [String: Any], name)
    }

    /// 冷启动 → 「我的」→【钱包】→ 点【提现】（实名未过时守卫直接落到实名页）。
    func launchThroughWallet(_ fake: String = "", payout: [String: Any]? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        var payload: [String: Any] = try ["summary": summary("normal")]
        if let payout {
            payload["payout"] = payout
        }
        app.launchEnvironment["COULI_FAKE_WALLET_VISUAL"] = try JSONSerialization.data(withJSONObject: payload)
            .base64EncodedString()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeLoggedIn", "-CouliFakeTradeNoExternal",
            "-CouliStartTab", "me", "-CouliFakeWalletResetPending",
        ]
        if !fake.isEmpty {
            app.launchArguments += ["-CouliFakeWallet", fake]
        }
        app.launch()
        XCTAssertTrue(ShellTabBar.bar(app).waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        let entry = node(app, "me.wallet")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "「我的」页没有【钱包】入口")
        entry.tap()
        let button = app.buttons["提现"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "钱包页没有【提现】")
        button.tap()
        return app
    }

    /// 进收款账号页：可提现时走账号行，未绑定时走引导按钮。
    func launchPayoutPage(_ fake: String = "", payout: [String: Any]? = nil) throws -> XCUIApplication {
        let app = try launchThroughWallet(fake, payout: payout)
        XCTAssertTrue(node(app, "withdraw.page").waitForExistence(timeout: 15), "没有进提现页")
        try requireLog(app)
        let row = node(app, "withdraw.payout")
        let guide = node(app, "withdraw.guide.button")
        XCTAssertTrue(row.waitForExistence(timeout: 8) || guide.waitForExistence(timeout: 2), "没有去收款账号的入口")
        (row.exists ? row : guide).tap()
        XCTAssertTrue(node(app, "payout.page").waitForExistence(timeout: 15), "没有进收款账号页")
        Thread.sleep(forTimeInterval: 1.0)
        return app
    }

    func launchRealName(_ fake: String = "realname=none") throws -> XCUIApplication {
        let app = try launchThroughWallet(fake)
        XCTAssertTrue(node(app, "realname.page").waitForExistence(timeout: 15), "没有进实名页")
        try requireLog(app)
        Thread.sleep(forTimeInterval: 1.0)
        return app
    }

    func launchLabor() throws -> XCUIApplication {
        let app = try launchThroughWallet("labor=unsigned")
        XCTAssertTrue(node(app, "withdraw.page").waitForExistence(timeout: 15), "没有进提现页")
        try requireLog(app)
        let guide = node(app, "withdraw.guide.button")
        XCTAssertTrue(guide.waitForExistence(timeout: 8), "没有去签署的引导")
        guide.tap()
        XCTAssertTrue(node(app, "labor.page").waitForExistence(timeout: 15), "没有进劳务页")
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    func fill(_ app: XCUIApplication, _ id: String, _ text: String) {
        let field = node(app, id)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "缺输入框 \(id)")
        field.tap()
        field.typeText(text)
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// 收起键盘（下拉内容区，页面 `.scrollDismissesKeyboard(.interactively)`）。
    func dismissKeyboard(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.5)
    }

    func puts(_ items: [String]) -> [String] {
        items.filter { $0 == "request:PUT /v1/me/payout-account" }
    }

    /// 框内文字。空框的 `value` 是占位符（金额框没有占位符，这里有），按空串算。
    func shown(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// 等框内文字到 `expected`（绑定回写异步），再多看一会儿，防止先对后错（c v3 同写法）。
    func assertBox(_ field: XCUIElement, _ expected: String, _ message: String, file: StaticString = #filePath,
                   line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, shown(field) != expected {
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(shown(field), expected, message, file: file, line: line)
    }

    /// 真实长按菜单粘贴（一次进一整串）。菜单没出来算失败，不跳过。
    func paste(_ app: XCUIApplication, _ field: XCUIElement, _ text: String, file: StaticString = #filePath,
               line: UInt = #line) throws {
        UIPasteboard.general.string = text
        field.press(forDuration: 1.2)
        Thread.sleep(forTimeInterval: 0.8)
        let item = app.menuItems.allElementsBoundByIndex.first { $0.label.contains("Paste") || $0.label.contains("粘贴") }
        try XCTUnwrap(item, "长按没有出现粘贴菜单", file: file, line: line).tap()
        Thread.sleep(forTimeInterval: 0.8)
    }
}
