import XCTest

/// APP-09 iOS 第 1 轮评审的界面用例（Debug 包 + 本机假服务 DebugFakeWallet，verify 每次都跑）：
/// - R1-01：默认启动参数（不带清场参数）下杀进程重启，未决记录仍在、待确认恢复、没有可用的【提交】（不能生成新键）；
/// - R1-03：rules / 收款账号读取失败时，待确认卡独立显示，【确认上一笔】【放弃上一笔】可用；
/// - R1-08：提现记录页点【修改收款账号】实名查询失败 → 统一的打开错误卡（重试、关闭）；
/// - R1-11：保存收到 20001 字段错误 → 首个错误字段的提示出现在屏内（滚动目标）。
/// 只有第一次启动带截图夹具的清场参数（从干净状态开始）；收尾再显式清场一次，不把未决记录留给之后的用例。
@MainActor
final class WalletReviewR1UITests: XCTestCase, WalletUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        let app = launch(["-CouliStartTab", "me", walletResetPendingArgument])
        app.terminate()
        resetFakeSession()
    }

    /// R1-01 + R1-03（提现）：结果未知 → 杀进程 → 默认参数冷启动，rules 读取失败 → 读取错误与待确认卡同时显示，确认 / 放弃可用、没有【提交】。
    func testUnknownSurvivesKillAndPendingCardIndependentOfRulesFailure() {
        var app = openWithdraw("submit=unknown_lost")
        typeAmount(app, "10")
        tapId(app, "withdraw.submit")
        passStepUp(app)
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        app.terminate()

        app = openWallet("submit=unknown_lost,rules=5xxxx", keepPending: true)
        tapButton(app, "提现")
        XCTAssertTrue(element(app, "withdraw.error").waitForExistence(timeout: 15), "rules 读取失败")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 10),
                      "默认参数冷启动后未决记录仍在，待确认卡独立于 rules 读取状态")
        XCTAssertTrue(element(app, "pending.confirm").isEnabled, "【确认上一笔】可用")
        XCTAssertTrue(element(app, "pending.abandon").isEnabled, "【放弃上一笔】可用")
        XCTAssertFalse(element(app, "withdraw.submit").exists, "不能生成新键：没有可用的【提交】")
    }

    /// R1-03（收款账号）+ R1-08：已有结果未知的保存键 → 冷启动后从提现记录点【修改收款账号】：实名查询失败时记录页显示打开错误卡；
    /// 查询恢复后进收款账号页，账号读取失败时待确认卡仍显示、确认 / 放弃可用。
    func testRecordsOpenErrorCardAndPayoutPendingIndependentOfReadFailure() {
        var app = openWithdraw("save=unknown_created")
        tapId(app, "withdraw.payout")
        tapId(app, "payout.change")
        tapId(app, "payout.field.alipay_logon_id")
        element(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapId(app, "payout.field.payee_name")
        element(app, "payout.field.payee_name").typeText("测试")
        tapId(app, "payout.save")
        passStepUp(app)
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        app.terminate()

        app = openWallet("payout_read=5xxxx,me=5xxxx", keepPending: true)
        tapButton(app, "提现记录")
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15))
        tapId(app, "record.W2026100800003")
        tapId(app, "record.changeAccount")
        XCTAssertTrue(element(app, "wallet.openError").waitForExistence(timeout: 10), "记录页没有打开错误卡")
        XCTAssertTrue(element(app, "wallet.openError.close").exists, "打开错误卡带【关闭】")
        tapId(app, "wallet.openError.close")
        XCTAssertFalse(element(app, "wallet.openError").waitForExistence(timeout: 2), "【关闭】收起错误卡")
        app.terminate()

        app = openWallet("payout_read=5xxxx", keepPending: true)
        tapButton(app, "提现记录")
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15))
        tapId(app, "record.W2026100800003")
        tapId(app, "record.changeAccount")
        XCTAssertTrue(element(app, "payout.error").waitForExistence(timeout: 15), "收款账号读取失败")
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 10), "待确认卡独立于账号读取状态")
        XCTAssertTrue(element(app, "pending.confirm").isEnabled)
        XCTAssertTrue(element(app, "pending.abandon").isEnabled)
    }

    /// R1-11：保存银行卡收到 20001、fields=[card_no] → 卡号旁的错误提示出现并滚到屏内（首错的滚动 / 焦点目标），已填内容保留。
    func testFieldErrorScrolledIntoView() {
        let app = openWithdraw()
        tapId(app, "withdraw.payout")
        tapId(app, "payout.change")
        tapId(app, "payout.method.bank")
        tapId(app, "payout.field.card_no")
        element(app, "payout.field.card_no").typeText("6222")
        tapId(app, "payout.field.bank_name")
        element(app, "payout.field.bank_name").typeText("测试银行")
        tapId(app, "payout.field.payee_name")
        element(app, "payout.field.payee_name").typeText("测试")
        tapId(app, "payout.save")
        passStepUp(app)
        let error = element(app, "payout.fieldError.card_no")
        XCTAssertTrue(error.waitForExistence(timeout: 15), "卡号旁没有错误提示")
        pause(1)
        XCTAssertTrue(error.isHittable, "首个错误字段的提示在屏内")
        XCTAssertEqual(element(app, "payout.field.card_no").value as? String, "6222", "保留输入")
    }
}
