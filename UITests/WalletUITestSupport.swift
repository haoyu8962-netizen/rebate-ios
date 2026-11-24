import XCTest

/// APP-09 钱包界面测试的公共操作（Debug 包 + 本机假服务 DebugFakeWallet）。假服务默认保留未决记录（iOS R1-01）：截图与冒烟夹具在这里显式
/// 带清场参数 `-CouliFakeWalletResetPending`（清假账号的未决记录与金额草稿，rule-gaps I15）；冷启动恢复用例传 `keepPending: true` 不带它。
@MainActor
protocol WalletUITest: TradeUITest {}

extension WalletUITest {
    /// 冷启动到「我的」占位页，点【钱包】进钱包页。`wallet` 是假服务开关（如 "wallet=frozen,payout=none"）。
    func openWallet(_ wallet: String = "", _ extra: [String] = [], keepPending: Bool = false) -> XCUIApplication {
        var args = ["-CouliStartTab", "me"] + extra
        if !keepPending {
            args.append(walletResetPendingArgument)
        }
        if !wallet.isEmpty {
            args += ["-CouliFakeWallet", wallet]
        }
        let app = launch(args)
        let entry = element(app, "me.wallet")
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "「我的」页没有【钱包】入口")
        entry.tap()
        let opened = element(app, "wallet.content").waitForExistence(timeout: 15)
            || element(app, "wallet.error").waitForExistence(timeout: 2)
        if !opened {
            save(app, "debug-openWallet")
            print(app.debugDescription)
        }
        XCTAssertTrue(opened, "没有进钱包页")
        pause(1.2)
        return app
    }

    func tapButton(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "没有【\(label)】")
        button.tap()
    }

    /// 钱包 →【提现】→ 提现页（rules 到位）。
    /// 截图夹具的清场参数（与 DebugFakeWallet.resetPendingArgument 同值）。
    var walletResetPendingArgument: String {
        "-CouliFakeWalletResetPending"
    }

    func openWithdraw(_ wallet: String = "", _ extra: [String] = [], keepPending: Bool = false) -> XCUIApplication {
        let app = openWallet(wallet, extra, keepPending: keepPending)
        tapButton(app, "提现")
        XCTAssertTrue(element(app, "withdraw.balance").waitForExistence(timeout: 15)
            || element(app, "withdraw.guide").waitForExistence(timeout: 2)
            || element(app, "pending.card").waitForExistence(timeout: 2), "没有进提现页")
        pause(1.2)
        return app
    }

    func typeAmount(_ app: XCUIApplication, _ text: String) {
        let field = element(app, "withdraw.input")
        field.tap()
        field.typeText(text)
    }

    func tapId(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "没有 \(id)")
        for _ in 0..<4 where !target.isHittable {
            app.swipeUp()
        }
        target.tap()
    }

    /// 收起键盘：从内容区往下拖到屏幕底（页面的 ScrollView 是 scrollDismissesKeyboard(.interactively)）。
    func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        start.press(forDuration: 0.05, thenDragTo: end)
        pause()
    }

    /// 二次验证面板：等面板、输 123456、点【验证并提交】。`shots` 给定时在输码前后各存一张（`<shots>`、`<shots>-filled`）。
    /// FU-IOS-CONTRACT-LOCK-6c97062（D10-2903 / D10-2911）：提现不再弹面板，只有改收款账号（以及换号、注销）还会走到这里。
    func passStepUp(_ app: XCUIApplication, shots: String? = nil) {
        let code = element(app, "stepUp.code")
        XCTAssertTrue(code.waitForExistence(timeout: 10), "没有弹二次验证")
        pause(1.2)
        if let shots {
            save(app, shots)
        }
        code.tap()
        code.typeText("123456")
        pause(0.5)
        if let shots {
            save(app, shots + "-filled")
        }
        tapId(app, "stepUp.submit")
    }

    /// 提现页 → 账号行 →【更换】→ 填支付宝登录号与收款人 →【保存】→ 假服务回 10003（没带改收款令牌，DebugFakeWallet+Account
    /// `save`）→ 等二次验证面板。D10-2911：提现不再出面板，面板相关的冒烟与截图换到这里。
    func openPayoutStepUp(_ app: XCUIApplication) {
        tapId(app, "withdraw.payout")
        tapId(app, "payout.change")
        tapId(app, "payout.field.alipay_logon_id")
        element(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapId(app, "payout.field.payee_name")
        element(app, "payout.field.payee_name").typeText("测试")
        tapId(app, "payout.save")
        XCTAssertTrue(element(app, "stepUp.code").waitForExistence(timeout: 10), "改收款【保存】没有弹二次验证")
    }
}
