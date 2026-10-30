import UIKit
import XCTest

/// APP-09v-c 真点（资金写页硬约束）：只用现有 Debug 输入，底版应全绿、实现后必须仍绿——挪位、换主次后，每个按钮真点一次仍恰好一次请求（或零次）。
/// 依赖实现的读屏与新 Debug 载荷用例在 `WithdrawVisualLookUITests`。
@MainActor
final class WithdrawVisualUITests: XCTestCase, WithdrawVisualUITest {
    private let post = "request:POST /v1/withdrawals"
    private let abandon = "request:POST /v1/idempotency-keys/abandon"

    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    /// 【提交】真点恰一次：首发（得到 10003）→ 二次验证 → 原键重放一次；成功后唯一一次替换到 WithdrawRecords {withdrawal_id}。
    func testSubmitRealTapExactlyOnce() throws {
        let app = try launchWithdraw()
        type(app, "10")
        let before = log(app).count
        let submit = node(app, "withdraw.submit")
        XCTAssertTrue(submit.isEnabled, "合法金额可提交")
        submit.tap()
        XCTAssertTrue(node(app, "stepUp.code").waitForExistence(timeout: 10))
        XCTAssertEqual(writes(entries(app, after: before)), [post], "点一次发一次")
        passStepUp(app)
        waitLog(app, beyond: before + 2)
        let after = entries(app, after: before)
        XCTAssertEqual(after.filter { $0 == post }.count, 2, "首发 + 二次验证后重放，共两次")
        let routes = after.filter { $0.hasPrefix("route:") }
        XCTAssertEqual(routes.count, 1, "唯一一次导航：\(routes)")
        XCTAssertTrue(routes.first?.hasPrefix("route:WithdrawRecords?withdrawal_id=") == true, "\(routes)")
        app.terminate()
    }

    /// 空金额【提交】置灰：真点零请求。
    func testDisabledSubmitRealTapInert() throws {
        let app = try launchWithdraw()
        let submit = node(app, "withdraw.submit")
        XCTAssertFalse(submit.isEnabled, "空金额置灰")
        let before = log(app).count
        submit.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(entries(app, after: before), [], "零记录")
        app.terminate()
    }

    /// G-W16：【再想想】零请求；【确定放弃】恰一次 abandon、不发提交；已放弃轻提示。
    func testRethinkZeroAndAbandonOnce() throws {
        let app = try launchWithdraw("submit=unknown_lost")
        enterPending(app)
        let before = log(app).count
        node(app, "pending.abandon").tap()
        let rethink = app.buttons["再想想"].firstMatch
        XCTAssertTrue(rethink.waitForExistence(timeout: 5), "放弃二次确认")
        XCTAssertEqual(entries(app, after: before), [], "打开弹窗零请求")
        rethink.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(entries(app, after: before), [], "【再想想】零请求")
        XCTAssertTrue(node(app, "pending.card").exists, "仍待确认")
        node(app, "pending.abandon").tap()
        let confirm = app.buttons["确定放弃"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(writes(entries(app, after: before)), [abandon], "恰一次 abandon，不发提交")
        XCTAssertTrue(node(app, "pending.card").waitForNonExistence(timeout: 5), "待确认解除")
        app.terminate()
    }

    /// 【确认上一笔】恰一次；成功唯一一次导航；不发 abandon。
    func testConfirmRealTapOnce() throws {
        let app = try launchWithdraw("submit=unknown_created")
        enterPending(app)
        let before = log(app).count
        node(app, "pending.confirm").tap()
        waitLog(app, beyond: before)
        let after = entries(app, after: before)
        XCTAssertEqual(writes(after), [post], "确认恰一次：\(after)")
        XCTAssertEqual(after.filter { $0.hasPrefix("route:WithdrawRecords") }.count, 1)
        app.terminate()
    }

    /// 44001：【知道了】零请求、零客服、留本页；再提交后【联系客服申诉】恰一次客服出口，不再提交。
    func testRiskDialogRealTap() throws {
        let app = try launchWithdraw("submit=44001")
        type(app, "10")
        node(app, "withdraw.submit").tap()
        passStepUp(app)
        let ok = app.buttons["知道了"].firstMatch
        XCTAssertTrue(ok.waitForExistence(timeout: 15), "44001 弹窗")
        XCTAssertTrue(app.buttons["联系客服申诉"].firstMatch.exists)
        let before = log(app).count
        ok.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(entries(app, after: before), [], "【知道了】零记录")
        XCTAssertTrue(node(app, "withdraw.submit").exists, "留在提现页")
        node(app, "withdraw.submit").tap()
        let appeal = app.buttons["联系客服申诉"].firstMatch
        XCTAssertTrue(appeal.waitForExistence(timeout: 15))
        let second = log(app).count
        appeal.tap()
        waitLog(app, beyond: second)
        let after = entries(app, after: second)
        XCTAssertEqual(after.filter { $0.hasPrefix("contact:") }, ["contact:Withdraw"], "恰一次客服出口")
        XCTAssertEqual(writes(after), [], "申诉不提交")
        app.terminate()
    }

    /// 返回语义（G-W16，iOS 无返回键）：点遮罩不写、不放弃；两个弹窗都留到用户选（DS `couliDialog` 遮罩不关闭）。
    func testScrimTapWritesNothing() throws {
        let app = try launchWithdraw("submit=unknown_lost")
        enterPending(app)
        node(app, "pending.abandon").tap()
        XCTAssertTrue(app.buttons["再想想"].firstMatch.waitForExistence(timeout: 5))
        let before = log(app).count
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.1)).tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(entries(app, after: before), [], "点遮罩零请求")
        XCTAssertTrue(node(app, "pending.card").exists || app.buttons["再想想"].exists, "没有放弃")
        app.terminate()
    }

    /// 档位、【全部提现】：真点只填值、不写、不导航；档位无选中语义（W41）。
    func testQuickAndAllRealTapFillOnly() throws {
        let app = try launchWithdraw()
        let before = log(app).count
        let chip = node(app, "withdraw.quick.500")
        chip.tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(node(app, "withdraw.input").value as? String, "5")
        XCTAssertFalse(chip.isSelected, "不带选中语义")
        node(app, "withdraw.all").tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(node(app, "withdraw.input").value as? String, "12", "只填 max")
        let after = entries(app, after: before)
        XCTAssertEqual(writes(after), [], "零写请求")
        XCTAssertFalse(after.contains { $0.hasPrefix("route:") }, "不导航")
        app.terminate()
    }

    /// 收款账号行、待确认「查看提现记录」、前置引导：真点恰一次、空参数、零写。
    func testExitsRealTapOnce() throws {
        let app = try launchWithdraw()
        var before = log(app).count
        node(app, "withdraw.payout").tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(entries(app, after: before).filter { $0.hasPrefix("route:") }, ["route:PayoutAccount"])
        XCTAssertEqual(writes(entries(app, after: before)), [])
        app.terminate()

        let guide = try launchWithdraw("payout=none")
        before = log(guide).count
        node(guide, "withdraw.guide.button").tap()
        waitLog(guide, beyond: before)
        XCTAssertEqual(entries(guide, after: before).filter { $0.hasPrefix("route:") }, ["route:PayoutAccount"])
        XCTAssertEqual(writes(entries(guide, after: before)), [])
        guide.terminate()

        let pending = try launchWithdraw("submit=unknown_lost")
        enterPending(pending)
        before = log(pending).count
        node(pending, "pending.records").tap()
        waitLog(pending, beyond: before)
        XCTAssertEqual(entries(pending, after: before).filter { $0.hasPrefix("route:") }, ["route:WithdrawRecords"])
        XCTAssertEqual(writes(entries(pending, after: before)), [])
        pending.terminate()
    }

    /// AdaptKeyboardWithdraw：键盘弹起时【提交】贴键盘上方、可点。
    func testKeyboardKeepsSubmitReachable() throws {
        let app = try launchWithdraw()
        let field = node(app, "withdraw.input")
        field.tap()
        field.typeText("10")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.0)
        let submit = node(app, "withdraw.submit")
        XCTAssertLessThanOrEqual(submit.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "【提交】在键盘之上")
        XCTAssertTrue(submit.isHittable)
        app.terminate()
    }
}
