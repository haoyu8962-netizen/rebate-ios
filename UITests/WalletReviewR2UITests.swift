import XCTest

/// APP-09 iOS 第 2 轮评审的界面用例（Debug 包 + 本机假服务 DebugFakeWallet，verify 每次都跑）：
/// - R2-02：先进入待确认，之后 rules / 收款账号读取持续失败（`*_after_submit` / `*_after_save`）；重进页面处于读取失败态时点确认 / 放弃，
///   写操作的明确结局（确认 30301、确认 20903、放弃 completed 原结果 30301；收款账号确认 30307）仍显示在页内，读取失败照常显示；
/// - R2-06：实名提交收到 20001、fields=[id_no] → 身份证号旁的错误提示出现并在屏内，已填内容保留。
/// 每个用例从截图夹具的清场参数开始（干净状态）；收尾再显式清场一次，不把未决记录留给之后的用例。
@MainActor
final class WalletReviewR2UITests: XCTestCase, WalletUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        let app = launch(["-CouliStartTab", "me", walletResetPendingArgument])
        app.terminate()
        resetFakeSession()
    }

    /// R2-02：确认返回 30301（键结束）→ 待确认卡消失，错误条可见，rules 仍是读取失败。
    func testConfirmBusinessErrorVisibleWhileRulesKeepFailing() {
        let app = pendingWithdrawThenRulesDown("submit=unknown_created,outcome=30301,rules=5xxxx_after_submit")
        tapId(app, "pending.confirm")
        assertWriteOutcomeVisible(app, readError: "withdraw.error", flowError: "withdraw.flowError")
    }

    /// R2-02：确认返回 20903（已作废，键结束）→ 同上。
    func testConfirm20903VisibleWhileRulesKeepFailing() {
        let app = pendingWithdrawThenRulesDown("submit=unknown_lost,confirm=20903,rules=5xxxx_after_submit")
        tapId(app, "pending.confirm")
        assertWriteOutcomeVisible(app, readError: "withdraw.error", flowError: "withdraw.flowError")
    }

    /// R2-02：放弃返回 completed、原结果 30301 → 同上。
    func testAbandonCompletedBusinessErrorVisibleWhileRulesKeepFailing() {
        let app = pendingWithdrawThenRulesDown("submit=unknown_created,outcome=30301,rules=5xxxx_after_submit")
        tapId(app, "pending.abandon")
        let ok = app.buttons["确定放弃"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 10), "没有放弃二次确认")
        ok.tap()
        assertWriteOutcomeVisible(app, readError: "withdraw.error", flowError: "withdraw.flowError")
    }

    /// R2-02（收款账号）：保存结果未知 → 之后账号读取持续失败 → 从提现记录点【修改收款账号】进入读取失败的收款账号页 → 确认返回 30307 →
    /// 错误条可见，账号读取失败照常显示。
    func testPayoutConfirmBusinessErrorVisibleWhileReadKeepsFailing() {
        let app = openWithdraw("save=unknown_created,outcome=30307,payout_read=5xxxx_after_save")
        tapId(app, "withdraw.payout")
        tapId(app, "payout.change")
        tapId(app, "payout.field.alipay_logon_id")
        element(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapId(app, "payout.field.payee_name")
        element(app, "payout.field.payee_name").typeText("测试")
        tapId(app, "payout.save")
        passStepUp(app)
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        goBack(app)
        goBack(app)
        tapButton(app, "提现记录")
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15))
        tapId(app, "record.W2026100800003")
        tapId(app, "record.changeAccount")
        XCTAssertTrue(element(app, "payout.error").waitForExistence(timeout: 15), "收款账号读取失败")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 10), "待确认卡独立于账号读取状态")
        tapId(app, "pending.confirm")
        assertWriteOutcomeVisible(app, readError: "payout.error", flowError: "payout.flowError")
    }

    /// R2-06：实名提交收到 20001、fields=[id_no] → 身份证号旁的错误提示出现并滚到屏内（首错的滚动 / 焦点目标），已填内容保留。
    func testRealNameFieldErrorScrolledIntoView() {
        let app = openWallet("realname=none")
        tapButton(app, "提现")
        XCTAssertTrue(element(app, "realname.page").waitForExistence(timeout: 15), "未实名应先进 RealName")
        tapId(app, "realname.field.name")
        element(app, "realname.field.name").typeText("测试")
        tapId(app, "realname.field.id_no")
        element(app, "realname.field.id_no").typeText("000000000000000003")
        dismissKeyboard(app)
        tapId(app, "realname.submit")
        tapId(app, "realname.consent.check")
        tapId(app, "realname.consent.ok")
        let error = element(app, "realname.fieldError.id_no")
        XCTAssertTrue(error.waitForExistence(timeout: 15), "身份证号旁没有错误提示")
        pause(1)
        XCTAssertTrue(error.isHittable, "首个错误字段的提示在屏内")
        XCTAssertEqual(element(app, "realname.field.id_no").value as? String, "000000000000000003", "保留输入")
    }

    // MARK: - 公共步骤

    /// 提交进入待确认 → 返回钱包再进提现页（新实例）：rules 读取失败，待确认卡独立显示。
    private func pendingWithdrawThenRulesDown(_ scene: String) -> XCUIApplication {
        let app = openWithdraw(scene)
        typeAmount(app, "10")
        tapId(app, "withdraw.submit")
        passStepUp(app)
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        goBack(app)
        tapButton(app, "提现")
        XCTAssertTrue(element(app, "withdraw.error").waitForExistence(timeout: 15), "rules 读取失败")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 10), "待确认卡独立于 rules 读取状态")
        return app
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.buttons["返回"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "没有【返回】")
        back.tap()
        pause(1)
    }

    /// 键结束的明确结局：错误条出现、待确认卡消失、读取失败照常显示。
    private func assertWriteOutcomeVisible(_ app: XCUIApplication, readError: String, flowError: String) {
        XCTAssertTrue(element(app, flowError).waitForExistence(timeout: 15), "读取失败时看不到写操作的结局")
        let gone = NSPredicate(format: "exists == false")
        let card = element(app, "pending.card")
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: card)], timeout: 10)
        XCTAssertTrue(element(app, readError).exists, "读取失败照常显示")
    }
}
