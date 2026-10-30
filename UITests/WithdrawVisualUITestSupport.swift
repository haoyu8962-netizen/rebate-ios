import Foundation
import UIKit
import XCTest

/// APP-09v-c 的 UI 测试入口：真实 App（Debug）+ 本机假服务（`-CouliFakeLoginServer`、`-CouliFakeWallet …`）+ a 组
/// `COULI_FAKE_WALLET_VISUAL`
/// （带 `summary` 才打开只读记录 `debug.wallet.log`）。**资金守卫不需要新 Debug 输入**，在底版上应为绿。
///
/// 可选键 `withdraw`（交回 §4，实现方在 App target 的 `#if DEBUG` 里接，Release 不存在；只走环境变量，不写 App 标准偏好）：
/// `{"rules": <WithdrawRules 报文>, "helpLinks": {"withdraw_rules": {"route": "Help", "params": {"article_id": "…"}}}}`：
/// - `rules`：`GET /v1/withdrawals/rules` 回它（优先于 DebugFakeWallet 的通用样例）；
/// - `helpLinks`：假服务 `GET /v1/config` 的 `help_links` 并入它（生产不变）。
@MainActor
protocol WithdrawVisualUITest: WalletVisualUITest {}

extension WithdrawVisualUITest {
    func visualWithdraw() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo().appendingPathComponent("specs/wallet-vectors.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["visualWithdraw"] as? [String: Any], "缺 visualWithdraw")
    }

    func helpLinks() -> [String: Any] {
        ["withdraw_rules": ["route": "Help", "params": ["article_id": "withdraw-rules-fixture"]]]
    }

    /// 冷启动 → 「我的」→【钱包】→【提现】。`fake` 是 DebugFakeWallet 开关；`withdraw` 是上面的可选载荷。
    func launchWithdraw(_ fake: String = "", withdraw: [String: Any]? = nil,
                        extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        var payload: [String: Any] = try ["summary": summary("normal")]
        if let withdraw {
            payload["withdraw"] = withdraw
        }
        app.launchEnvironment["COULI_FAKE_WALLET_VISUAL"] = try JSONSerialization.data(withJSONObject: payload)
            .base64EncodedString()
        app.launchArguments += [
            "-CouliPrivacyPreset", "consented", "-CouliFakeLoginServer", "-CouliUpdateReset", "1",
            "-CouliHideDebugInfo", "1", "-CouliFakeTradeLoggedIn", "-CouliFakeTradeNoExternal",
            "-CouliStartTab", "me", "-CouliFakeWalletResetPending",
        ] + extra
        if !fake.isEmpty {
            app.launchArguments += ["-CouliFakeWallet", fake]
        }
        app.launch()
        XCTAssertTrue(node(app, "shell.tabBar").waitForExistence(timeout: 30), "没有进入 Tab 外壳")
        let entry = node(app, "me.wallet")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "「我的」页没有【钱包】入口")
        entry.tap()
        let button = app.buttons["提现"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "钱包页没有【提现】")
        button.tap()
        XCTAssertTrue(node(app, "withdraw.page").waitForExistence(timeout: 15), "没有进提现页")
        try requireLog(app)
        let ready = node(app, "withdraw.balance").waitForExistence(timeout: 10)
            || node(app, "pending.card").waitForExistence(timeout: 2)
        XCTAssertTrue(ready, "提现页 rules 没到位")
        Thread.sleep(forTimeInterval: 1.0)
        return app
    }

    /// 输入金额（真实键盘）并收起键盘。
    func type(_ app: XCUIApplication, _ text: String) {
        let field = node(app, "withdraw.input")
        field.tap()
        field.typeText(text)
        Thread.sleep(forTimeInterval: 1.0)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        start.press(forDuration: 0.05, thenDragTo: end)
        Thread.sleep(forTimeInterval: 0.5)
    }

    func entries(_ app: XCUIApplication, after count: Int) -> [String] {
        Array(log(app).dropFirst(count))
    }

    /// 记录里的写请求（提交、保存、发码以外的放弃 / 确认都算）。
    func writes(_ items: [String]) -> [String] {
        items.filter {
            $0.hasPrefix("request:POST /v1/withdrawals") || $0.hasPrefix("request:PUT")
                || $0.hasPrefix("request:POST /v1/idempotency-keys")
        }
    }

    func passStepUp(_ app: XCUIApplication) {
        let code = node(app, "stepUp.code")
        XCTAssertTrue(code.waitForExistence(timeout: 10), "没有弹二次验证")
        Thread.sleep(forTimeInterval: 1.0)
        code.tap()
        code.typeText("123456")
        Thread.sleep(forTimeInterval: 0.5)
        let submit = node(app, "stepUp.submit")
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "没有【验证并提交】")
        submit.tap()
    }

    /// 输入 → 【提交】 → 二次验证 → 结果未知 → 待确认卡（`fake` 取 submit=unknown_lost / unknown_created）。
    func enterPending(_ app: XCUIApplication) {
        type(app, "10")
        node(app, "withdraw.submit").tap()
        passStepUp(app)
        XCTAssertTrue(node(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        Thread.sleep(forTimeInterval: 1.0)
    }
}
