import UIKit
import XCTest

/// APP-09v-d 真点（资金写页）：真实 App + 本机假服务 + 真实键盘。
/// 第一段「资金守卫」只用现有 Debug 输入，底版应绿；第二段要交回 §2 的 Debug 输入 / 读屏元素，底版预期红。
///
/// FU-IOS-CONTRACT-LOCK-6c97062（D10-2903 / D10-2911）：提现免二次验证，提交不再弹面板。原先挂在提现上的半屏用例全部换宿主到
/// 改收款账号的面板（假服务对没带改收款令牌的 PUT /v1/me/payout-account 回 10003，DebugFakeWallet+Account `save`）——同一个半屏组件；
/// 换宿主后只把「提现提交 POST /v1/withdrawals」换成「保存 PUT /v1/me/payout-account」，其余断言不变。
@MainActor
final class StepUpVisualUITests: XCTestCase, WithdrawVisualUITest {
    fileprivate let sms = "request:POST /v1/auth/sms-codes"
    fileprivate let verify = "request:POST /v1/auth/step-up"
    fileprivate let put = "request:PUT /v1/me/payout-account"
    fileprivate static let ax3 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

    override func setUp() async throws {
        continueAfterFailure = true
    }

    // MARK: - 到达

    /// 提现页 → 账号行 → 更换 → 填表（支付宝登录号 test@example.com、收款人「测试」），停在【保存】前。
    /// `withdraw` / `extra` 同 `launchWithdraw`（`withdraw.smsResendSec` 对所有发码请求生效，DebugWalletVisual.smsReply）。
    fileprivate func payoutForm(withdraw: [String: Any]? = nil, extra: [String] = []) throws -> XCUIApplication {
        let app = try launchWithdraw(withdraw: withdraw, extra: extra)
        reveal(app, "withdraw.payout")
        node(app, "withdraw.payout").tap()
        tapNode(app, "payout.change")
        tapNode(app, "payout.field.alipay_logon_id")
        node(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapNode(app, "payout.field.payee_name")
        node(app, "payout.field.payee_name").typeText("测试")
        return app
    }

    /// 提现页 → 账号行 → 更换 → 填表 → 【保存】→ 10003 → 半屏。
    fileprivate func panelOnPayout(withdraw: [String: Any]? = nil, extra: [String] = []) throws -> XCUIApplication {
        let app = try payoutForm(withdraw: withdraw, extra: extra)
        tapNode(app, "payout.save")
        XCTAssertTrue(node(app, "stepUp.code").waitForExistence(timeout: 10), "没有弹二次验证")
        Thread.sleep(forTimeInterval: 1.2)
        return app
    }

    private func tapNode(_ app: XCUIApplication, _ id: String) {
        XCTAssertTrue(node(app, id).waitForExistence(timeout: 10), "没有 \(id)")
        reveal(app, id)
        node(app, id).tap()
    }

    private func reveal(_ app: XCUIApplication, _ id: String) {
        for _ in 0..<5 where !node(app, id).isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// 半屏里滚到目标（只在半屏内划，不碰底页；划不动不算错，后面 isHittable 判）。
    fileprivate func revealInSheet(_ app: XCUIApplication, _ id: String) {
        for _ in 0..<5 where !node(app, id).isHittable {
            let code = node(app, "stepUp.code")
            let start = code.exists ? code.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    fileprivate func typeCode(_ app: XCUIApplication, _ text: String) {
        let code = node(app, "stepUp.code")
        code.tap()
        for character in text {
            code.typeText(String(character))
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - 资金守卫（底版应绿）

    /// 原提现用例（D10-2911 换宿主到改收款账号）：真键盘逐位输满 → 零验证、面板还在；真点【验证并提交】→ 恰一次验证 + 一次重放；
    /// 原「唯一一次导航（替换到提现记录）」在改收款上是「出栈回发起页、不新开页面」。
    func testRehostedFullCodeZeroThenExactlyOnceOnPayout() throws {
        let app = try panelOnPayout()
        let before = log(app).count
        typeCode(app, "123456")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify }, [], "输满零验证")
        XCTAssertTrue(node(app, "stepUp.code").exists, "面板还在")
        let submit = node(app, "stepUp.submit")
        revealInSheet(app, "stepUp.submit")
        XCTAssertTrue(submit.isEnabled, "输满可点")
        submit.tap()
        waitLog(app, beyond: before + 1)
        let after = entries(app, after: before)
        XCTAssertEqual(after.filter { $0 == verify }.count, 1, "验证恰一次：\(after)")
        XCTAssertEqual(after.filter { $0 == put }.count, 1, "原键重放恰一次")
        XCTAssertTrue(node(app, "payout.page").waitForNonExistence(timeout: 10), "成功后出栈回发起页")
        XCTAssertEqual(entries(app, after: before).filter { $0.hasPrefix("route:") }, [], "不新开页面")
        app.terminate()
    }

    /// 收款账号：同上；保存重放恰一次。
    func testPayoutFullCodeZeroThenExactlyOnce() throws {
        let app = try panelOnPayout()
        let before = log(app).count
        typeCode(app, "123456")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify }, [], "输满零验证")
        revealInSheet(app, "stepUp.submit")
        node(app, "stepUp.submit").tap()
        waitLog(app, beyond: before + 1)
        let after = entries(app, after: before)
        XCTAssertEqual(after.filter { $0 == verify }.count, 1, "验证恰一次：\(after)")
        XCTAssertEqual(after.filter { $0 == put }.count, 1, "保存重放恰一次")
        app.terminate()
    }

    /// 回车不提交。
    func testReturnKeyDoesNotVerify() throws {
        let app = try panelOnPayout()
        let before = log(app).count
        typeCode(app, "123456")
        node(app, "stepUp.code").typeText("\n")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify }, [], "回车零验证")
        app.terminate()
    }

    /// 空码、不足 6 位：按钮置灰，真点零请求。
    func testDisabledSubmitInert() throws {
        let app = try panelOnPayout()
        let before = log(app).count
        let submit = node(app, "stepUp.submit")
        revealInSheet(app, "stepUp.submit")
        XCTAssertFalse(submit.isEnabled, "空码置灰")
        submit.tap()
        typeCode(app, "12345")
        revealInSheet(app, "stepUp.submit")
        XCTAssertFalse(submit.isEnabled, "5 位置灰")
        submit.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify }, [], "置灰零请求")
        app.terminate()
    }

    /// 错码：验证一次、不重放、错误出现、留在面板、清空。
    func testWrongCodeRealTap() throws {
        let app = try panelOnPayout()
        let before = log(app).count
        typeCode(app, "000000")
        revealInSheet(app, "stepUp.submit")
        node(app, "stepUp.submit").tap()
        XCTAssertTrue(node(app, "stepUp.error").waitForExistence(timeout: 8), "错误出现")
        let after = entries(app, after: before)
        XCTAssertEqual(after.filter { $0 == verify }.count, 1)
        XCTAssertEqual(after.filter { $0 == put }.count, 0, "错码不重放")
        XCTAssertFalse(node(app, "stepUp.submit").isEnabled, "清空后回到不可用")
        app.terminate()
    }

    /// 下滑、点遮罩都不关闭（真手势）；【×】才关，零写入；留在原页、已填内容还在。
    func testDismissLocked() throws {
        let app = try panelOnPayout()
        let before = log(app).count
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        top.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(node(app, "stepUp.code").exists, "点遮罩不关闭")
        let frame = node(app, "stepUp.sheet").frame
        let grab = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.minY + 14))
        grab.press(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: 0, dy: 500)))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(node(app, "stepUp.code").exists, "从把手位下滑不关闭")
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify || $0 == put }, [], "零写入")
        node(app, "stepUp.close").tap()
        XCTAssertTrue(node(app, "stepUp.code").waitForNonExistence(timeout: 3), "【×】关闭")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify || $0 == put }, [], "关闭零写入")
        // 原「提现金额保留」换宿主后是「收款表单已填内容保留」
        XCTAssertEqual(node(app, "payout.field.alipay_logon_id").value as? String, "test@example.com", "表单保留")
        app.terminate()
    }

    /// 默认字号 + 键盘弹起：真点得到【验证并提交】。
    func testKeyboardKeepsSubmitReachable() throws {
        try assertReachable(extra: [])
    }

    /// 200% + 键盘（AdaptShortStepUp）：滚得到按钮、真点恰一次。
    func testAX3KeyboardKeepsSubmitReachable() throws {
        try assertReachable(extra: Self.ax3)
    }

    private func assertReachable(extra: [String]) throws {
        let app = try panelOnPayout(extra: extra)
        let before = log(app).count
        typeCode(app, "123456")
        revealInSheet(app, "stepUp.submit")
        let submit = node(app, "stepUp.submit")
        XCTAssertTrue(submit.isHittable, "【验证并提交】可达：\(submit.frame)")
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(submit.frame.maxY, app.keyboards.firstMatch.frame.minY + 0.5, "不被键盘挡")
        }
        submit.tap()
        waitLog(app, beyond: before + 1)
        XCTAssertEqual(entries(app, after: before).filter { $0 == verify }.count, 1, "验证恰一次")
        app.terminate()
    }
}

/// 第二段：要交回 §2 的 Debug 输入 / 读屏元素。
extension StepUpVisualUITests {
    /// 发码次数（要 `isWalletPath` 记 sms-codes，交回 §2）：开面板恰一次；关闭后倒计时内重开不再发。
    /// 原提现用例（D10-2911 换宿主到改收款账号）：关闭后再点【保存】，假服务照样回 10003（从没拿到令牌）→ 重开面板。
    func testRehostedSmsCountAcrossReopenOnPayout() throws {
        let app = try payoutForm()
        let before = log(app).count
        tapNode(app, "payout.save")
        XCTAssertTrue(node(app, "stepUp.code").waitForExistence(timeout: 10))
        waitLog(app, beyond: before + 1)
        XCTAssertEqual(entries(app, after: before).filter { $0 == sms }.count, 1, "开面板发码恰一次")
        node(app, "stepUp.close").tap()
        XCTAssertTrue(node(app, "stepUp.code").waitForNonExistence(timeout: 3))
        tapNode(app, "payout.save")
        XCTAssertTrue(node(app, "stepUp.code").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(entries(app, after: before).filter { $0 == sms }.count, 1, "倒计时内重开不再发")
        app.terminate()
    }

    func testPayoutSmsCount() throws {
        let app = try panelOnPayout()
        XCTAssertEqual(log(app).filter { $0 == sms }.count, 1, "收款账号开面板发码恰一次")
        app.terminate()
    }

    /// 【重新获取】四边真点（Android r1 S2-1：命中区被中段滚动裁掉）：边内 1pt 各恰一次发码；不验证、不提交。要 `withdraw.smsResendSec` 把倒计时缩到 2 秒。
    func testResendEdgesRealTap() throws {
        let app = try panelOnPayout(withdraw: ["smsResendSec": 2])
        for edge in [UIRectEdge.top, .bottom, .left, .right] {
            let resend = node(app, "stepUp.resend")
            guard resend.waitForExistence(timeout: 6) else {
                throw WalletVisualUIError.notInjected("withdraw.smsResendSec")
            }
            // XCUI 的框就是屏上尺寸（已含系统半屏缩放）：命中区按屏上比，不换算
            XCTAssertGreaterThanOrEqual(resend.frame.height, 43.5, "命中高")
            XCTAssertGreaterThanOrEqual(resend.frame.width, 43.5, "命中宽")
            XCTAssertGreaterThanOrEqual(node(app, "stepUp.close").frame.height, 43.5, "【×】命中高（屏上）")
            let before = log(app).count
            tapEdge(resend, edge)
            waitLog(app, beyond: before, timeout: 3)
            let after = entries(app, after: before)
            XCTAssertEqual(after.filter { $0 == sms }.count, 1, "\(edge)：恰一次：\(after)")
            XCTAssertEqual(after.filter { $0 == verify || $0 == put }, [], "\(edge)：不误触")
        }
        app.terminate()
    }

    /// W66 读屏：一个输入框，读「已输入 n 位，共 6 位」；格子不单独可读；把手不可读。
    func testCodeSpokenAndCellsHidden() throws {
        let app = try panelOnPayout()
        XCTAssertTrue(node(app, "stepUp.code").label.contains("已输入 0 位，共 6 位"), node(app, "stepUp.code").label)
        typeCode(app, "38")
        XCTAssertTrue(node(app, "stepUp.code").label.contains("已输入 2 位，共 6 位"), node(app, "stepUp.code").label)
        let items = try sheetItems(app)
        keep(items, "stepup-spoken")
        XCTAssertEqual(items.filter { $0.id == "stepUp.code" }.count, 1, "先正：半屏子树里有输入框")
        XCTAssertEqual(items.filter { $0.label == "3" || $0.label == "8" }.map(\.label), [], "格子不单独可读")
        XCTAssertEqual(node(app, "stepUp.sheet").descendants(matching: .textField).count, 1, "整串一个输入框")
        XCTAssertFalse(node(app, "stepUp.handle").exists, "把手纯装饰，不进读屏树")
        app.terminate()
    }

    /// 只取半屏子树：app 全树里有数字键盘的按键「3」「8」（v1 误判，交回 v2 T2）。
    private func sheetItems(_ app: XCUIApplication) throws -> [WalletA11yItem] {
        var items: [WalletA11yItem] = []
        func walk(_ element: XCUIElementSnapshot) {
            if !element.label.isEmpty {
                items.append(WalletA11yItem(id: element.identifier, label: element.label, frame: element.frame))
            }
            element.children.forEach(walk)
        }
        try walk(node(app, "stepUp.sheet").snapshot())
        return items
    }

    /// 读屏顺序（A11yFocusStepUp、brief §4.2）：标题 → 说明 → 验证码 → 错误 → 倒计时 → 提交；【×】在验证码之前。
    func testReadingOrder() throws {
        let app = try panelOnPayout()
        typeCode(app, "000000")
        revealInSheet(app, "stepUp.submit")
        node(app, "stepUp.submit").tap()
        XCTAssertTrue(node(app, "stepUp.error").waitForExistence(timeout: 8))
        let items = try readingOrder(app)
        keep(items, "stepup-order")
        let ids = items.map(\.id)
        let wanted = ["stepUp.title", "stepUp.sent", "stepUp.code", "stepUp.error", "stepUp.countdown", "stepUp.submit"]
        let positions = wanted.map { ids.firstIndex(of: $0) ?? -1 }
        XCTAssertFalse(positions.contains(-1), "读屏树缺元素：\(zip(wanted, positions).filter { $0.1 < 0 })")
        XCTAssertEqual(positions, positions.sorted(), "顺序：\(zip(wanted, positions).map { "\($0.0)=\($0.1)" })")
        let close = ids.firstIndex(of: "stepUp.close") ?? Int.max
        XCTAssertLessThan(close, positions[2], "【×】在验证码之前")
        app.terminate()
    }

    /// 真机字号下半屏真放大（UI 进程的 200% 是系统级，不靠测试特征）：倒计时文字行高超过默认。
    func testAX3RealEnlarged() throws {
        let app = try panelOnPayout(extra: Self.ax3)
        let countdown = node(app, "stepUp.countdown")
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertTrue(countdown.label.hasSuffix("秒后可重新获取"), countdown.label)
        XCTAssertGreaterThan(countdown.frame.height, 28, "真放大：\(countdown.frame)")
        app.terminate()
    }
}
