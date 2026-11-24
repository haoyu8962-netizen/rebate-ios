import XCTest

/// APP-09 钱包、提现、提现记录、收款账号、实名、劳务协议与二次验证的界面冒烟与设计稿比对截图（Debug 包 + 本机假服务 DebugFakeWallet）。
/// 截图用例只在设置 TEST_RUNNER_COULI_SHOT_DIR 时跑，写到 NATIVE/APP-09/shots/ios/。全部假数据：样例金额、脱敏账号，表单只填明显的测试值
/// （姓名「测试」、卡号 6222000000000009、登录号 test@example.com），不打印完整号码。
@MainActor
final class WalletShotTests: XCTestCase, WalletUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    // MARK: - 冒烟（verify 每次都跑）

    /// 钱包 → 提现 → 输入金额看到估算 → 提交直接进提现记录，这一单在最前。
    /// FU-IOS-CONTRACT-LOCK-6c97062（D10-2903 / D10-2911）：提现免二次验证，提交不再弹面板；面板冒烟换到改收款账号（下一条）。
    func testWalletWithdrawSmoke() {
        let app = openWithdraw()
        typeAmount(app, "10")
        XCTAssertTrue(element(app, "withdraw.estimate").waitForExistence(timeout: 10), "没有估算")
        element(app, "withdraw.submit").tap()
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15), "提交成功没有进提现记录")
        XCTAssertFalse(element(app, "stepUp.code").exists, "提现不弹二次验证")
    }

    /// 原 testWalletWithdrawSmoke 的二次验证那一段（D10-2911 换宿主）：提现页 → 改收款账号【保存】→ 弹二次验证 → 验证通过回到提现页。
    func testWalletPayoutStepUpSmoke() {
        let app = openWithdraw()
        openPayoutStepUp(app)
        let code = element(app, "stepUp.code")
        code.tap()
        code.typeText("123456")
        tapId(app, "stepUp.submit")
        XCTAssertTrue(element(app, "withdraw.balance").waitForExistence(timeout: 15), "保存成功没有回到提现页")
        XCTAssertFalse(element(app, "stepUp.code").exists, "验证通过后面板收起")
    }

    // MARK: - 截图（设计稿比对）

    func testShotsWallet() throws {
        try requireShots()
        var app = openWallet()
        save(app, "Wallet")
        app.buttons["预估收益说明"].firstMatch.tap()
        pause()
        save(app, "WalletNoteEstimate")
        tapId(app, "wallet.help.ok")
        pause()
        app.buttons["冻结中说明"].firstMatch.tap()
        pause()
        save(app, "WalletNoteFrozen")
        tapId(app, "wallet.help.ok")
        pause()
        app.buttons["暂缓入账说明"].firstMatch.tap()
        pause()
        save(app, "WalletNotePaused")
        tapId(app, "wallet.help.ok")
        pause()
        app.buttons["隐藏金额"].firstMatch.tap()
        pause()
        save(app, "WalletHidden")
        app.terminate()
        for (scene, name) in [("wallet=frozen", "WalletFrozen"), ("wallet=negative", "WalletNegative"),
                              ("wallet=risk", "WalletRiskFrozen"), ("wallet=disabled", "WalletDisabled"),
                              ("wallet=new", "WalletNew")] {
            app = openWallet(scene)
            save(app, name)
            app.terminate()
        }
        // 先在线成功加载一次（写缓存），再断网冷启动：WalletStale
        app = openWallet()
        app.terminate()
        app = openWallet("offline=1")
        XCTAssertTrue(element(app, "wallet.stale").waitForExistence(timeout: 10), "断网冷启动应显示缓存")
        save(app, "WalletStale")
        app.terminate()
        // 风控冻结：钱包【提现】可点（G11 更正），提现页按 rules 30303 account_frozen 提示
        app = openWithdraw("wallet=risk")
        save(app, "WithdrawRiskFrozen")
    }

    func testShotsWithdraw() throws {
        try requireShots()
        var app = openWithdraw()
        save(app, "Withdraw-empty")
        let field = element(app, "withdraw.input")
        field.tap()
        field.typeText("10")
        pause(0.15)
        save(app, "WithdrawCalculating")
        XCTAssertTrue(element(app, "withdraw.estimate").waitForExistence(timeout: 10), "没有估算")
        pause(0.5)
        save(app, "AdaptKeyboardWithdraw")
        dismissKeyboard(app)
        pause()
        save(app, "Withdraw")
        app.buttons["预计到账说明"].firstMatch.tap()
        pause()
        save(app, "WithdrawNoteNet")
        tapId(app, "wallet.help.ok")
        pause()
        tapId(app, "withdraw.submit")
        // D10-2903：提现免二次验证，提交直接进提现记录
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15), "提交成功没有进提现记录")
        pause(1.2)
        save(app, "WithdrawSubmitted-records")
        app.terminate()

        app = openWithdraw("submit=44001")
        typeAmount(app, "10")
        tapId(app, "withdraw.submit")
        XCTAssertTrue(element(app, "risk.dialog").waitForExistence(timeout: 15), "没有风控弹窗")
        pause()
        save(app, "WithdrawBlocked")
        app.terminate()

        app = openWithdraw("rules=negative")
        save(app, "WithdrawBlockedNegative")
        app.terminate()

        // 设计稿 WithdrawStepUp 的两张（原在提现提交后拍）换宿主到改收款账号面板（D10-2911）：同一个半屏组件
        app = openWithdraw()
        openPayoutStepUp(app)
        passStepUp(app, shots: "WithdrawStepUp-host-payout")
        XCTAssertTrue(element(app, "withdraw.balance").waitForExistence(timeout: 15), "保存成功没有回到提现页")
    }

    /// D10-2903：提现免二次验证，三段都是提交后直接进入待确认（不再先过面板）。
    func testShotsWithdrawPending() throws {
        try requireShots()
        var app = openWithdraw("submit=unknown_lost")
        typeAmount(app, "10")
        tapId(app, "withdraw.submit")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        pause(1.2)
        save(app, "WithdrawPendingConfirm")
        tapId(app, "pending.abandon")
        pause()
        save(app, "WithdrawAbandonConfirm")
        app.buttons["确定放弃"].firstMatch.tap()
        pause(1.5)
        save(app, "WithdrawAbandoned")
        app.terminate()

        app = openWithdraw("submit=unknown_lost,abandon=busy")
        typeAmount(app, "10")
        tapId(app, "withdraw.submit")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20))
        tapId(app, "pending.abandon")
        app.buttons["确定放弃"].firstMatch.tap()
        XCTAssertTrue(element(app, "pending.notice").waitForExistence(timeout: 10))
        pause(1.2)
        save(app, "WithdrawPendingStill")
        app.terminate()

        app = openWithdraw("submit=unknown_created")
        typeAmount(app, "10")
        tapId(app, "withdraw.submit")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20))
        tapId(app, "pending.abandon")
        app.buttons["确定放弃"].firstMatch.tap()
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15), "completed 应进提现记录")
        pause(1.2)
        save(app, "WithdrawAbandonCompleted")
    }
}
