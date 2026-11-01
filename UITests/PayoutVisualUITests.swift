import UIKit
import XCTest

/// APP-09v-e 真点（资金写页硬约束）。标 [守卫] 的只用现有 Debug 输入，底版应绿、实现后必须仍绿；其余依赖实现（版式 / 读屏 / 新 Debug 输入）。
@MainActor
final class PayoutVisualUITests: XCTestCase, PayoutVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    private func fillAlipay(_ app: XCUIApplication) {
        fill(app, "payout.field.alipay_logon_id", "13800135678")
        // 键盘升起时底栏上移，盖住收款人框的中心（e3 / e4 现场录屏）；点击会落到底栏上，真人是先滚动，这里先收键盘
        dismissKeyboard(app)
        fill(app, "payout.field.payee_name", "ceshi")
        dismissKeyboard(app)
    }

    /// [守卫] 【保存】点一次 → 首发 10003 → 二次验证 → 原键重放：共 2 次 PUT，成功后不再写。
    func testSaveRealTapOnce() throws {
        let app = try launchPayoutPage("payout=none")
        fillAlipay(app)
        let before = log(app).count
        node(app, "payout.save").tap()
        passStepUp(app)
        XCTAssertTrue(node(app, "payout.page").waitForNonExistence(timeout: 10), "成功后回发起页")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(puts(entries(app, after: before)).count, 2, "首发 + 重放")
        app.terminate()
    }

    /// [守卫] 换方式、输入、空表单保存：零写。
    func testChoosingAndEmptySaveZeroWrites() throws {
        let app = try launchPayoutPage("payout=none")
        let before = log(app).count
        node(app, "payout.method.bank").tap()
        XCTAssertTrue(node(app, "payout.field.card_no").waitForExistence(timeout: 3), "切到银行卡字段")
        node(app, "payout.method.alipay").tap()
        XCTAssertTrue(node(app, "payout.field.alipay_logon_id").waitForExistence(timeout: 3))
        node(app, "payout.save").tap()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(puts(entries(app, after: before)), [], "零写")
        XCTAssertTrue(node(app, "payout.fieldError.alipay_logon_id").exists, "本地校验就地提示")
        app.terminate()
    }

    /// [守卫] 【更换收款账号】零写，只开表单。
    func testChangeOpensFormZeroWrites() throws {
        let app = try launchPayoutPage()
        let before = log(app).count
        node(app, "payout.change").tap()
        XCTAssertTrue(node(app, "payout.method.alipay").waitForExistence(timeout: 3), "打开表单")
        XCTAssertEqual(writes(entries(app, after: before)), [], "零写")
        app.terminate()
    }

    /// W78 / G-W21：次数 0 置灰、读出原因、真点零记录。
    func testExhaustedChangeDisabled() throws {
        let app = try launchPayoutPage(payout: ["account": account("boundExhausted")])
        let change = node(app, "payout.change")
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertFalse(change.isEnabled, "次数 0 置灰")
        let spoken = change.label + " " + (change.value as? String ?? "")
        XCTAssertTrue(spoken.contains("0 次"), "读屏说明原因：\(spoken)")
        let before = log(app).count
        change.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(entries(app, after: before), [], "零记录")
        XCTAssertFalse(node(app, "payout.method.alipay").exists, "不开表单")
        app.terminate()
    }

    /// W80：30307 真实流程落在收款人字段下，首发 + 重放共 2 次，错误后不重发。`save=30307` 是现有开关。
    func testNameErrorUnderFieldRealFlow() throws {
        let app = try launchPayoutPage("payout=none,save=30307")
        fillAlipay(app)
        let before = log(app).count
        node(app, "payout.save").tap()
        passStepUp(app)
        XCTAssertTrue(node(app, "payout.fieldError.payee_name").waitForExistence(timeout: 10), "错误在收款人字段下")
        XCTAssertFalse(node(app, "payout.flowError").exists, "页顶不重复")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(puts(entries(app, after: before)).count, 2, "不重发")
        app.terminate()
    }

    /// W79：30303 次数类：页顶条，保存恰一次流程；W81：40901 按钮恢复、不重发（新 Debug 输入 saveError）。
    func testLimitAndBusyRealFlow() throws {
        for (code, data) in [(30303, ["reason": "payout_account_change_limit"]), (40901, [:])] {
            let failure: [String: Any] = ["code": code, "data": data]
            let app = try launchPayoutPage("payout=none", payout: ["saveError": failure])
            fillAlipay(app)
            let before = log(app).count
            node(app, "payout.save").tap()
            passStepUp(app)
            XCTAssertTrue(node(app, "payout.flowError").waitForExistence(timeout: 10), "\(code)：页顶条")
            Thread.sleep(forTimeInterval: 1.0)
            XCTAssertEqual(puts(entries(app, after: before)).count, 2, "\(code)：不重发")
            XCTAssertTrue(node(app, "payout.save").isEnabled, "\(code)：按钮恢复")
            app.terminate()
        }
    }

    /// [守卫] 44001：【知道了】零写；留在本页。
    func testRiskDialogRealTap() throws {
        let app = try launchPayoutPage("payout=none,save=44001")
        fillAlipay(app)
        node(app, "payout.save").tap()
        passStepUp(app)
        let okay = app.buttons["知道了"].firstMatch
        XCTAssertTrue(okay.waitForExistence(timeout: 10), "44001 弹窗")
        let before = log(app).count
        okay.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(puts(entries(app, after: before)), [], "零写")
        XCTAssertTrue(node(app, "payout.page").exists, "留在本页")
        app.terminate()
    }

    /// [守卫] 待确认：【再想想】零请求、【确定放弃】恰一次；不重发保存。
    func testPendingAbandonRealTap() throws {
        let app = try launchPayoutPage("payout=none,save=unknown_created")
        fillAlipay(app)
        node(app, "payout.save").tap()
        passStepUp(app)
        XCTAssertTrue(node(app, "pending.card").waitForExistence(timeout: 20), "没进待确认")
        Thread.sleep(forTimeInterval: 1.0)
        let before = log(app).count
        node(app, "pending.abandon").tap()
        let rethink = app.buttons["再想想"].firstMatch
        XCTAssertTrue(rethink.waitForExistence(timeout: 5))
        rethink.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(entries(app, after: before), [], "【再想想】零请求")
        node(app, "pending.abandon").tap()
        let confirm = app.buttons["确定放弃"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitLog(app, beyond: before)
        XCTAssertEqual(writes(entries(app, after: before)), ["request:POST /v1/idempotency-keys/abandon"], "恰一次")
        app.terminate()
    }

    // MARK: - 实名

    private func fillReal(_ app: XCUIApplication, id: String = "110101199001011230") {
        fill(app, "realname.field.name", "ceshi")
        fill(app, "realname.field.id_no", id)
        dismissKeyboard(app)
    }

    /// 【提交认证】只开同意；未勾选【同意并继续】置灰；勾选零提交；同意恰一次（新记录项 backend:realname.submit）。
    func testConsentRealTapOnce() throws {
        let app = try launchRealName()
        fillReal(app)
        let before = log(app).count
        node(app, "realname.submit").tap()
        let okay = node(app, "realname.consent.ok")
        XCTAssertTrue(okay.waitForExistence(timeout: 5), "同意半屏")
        XCTAssertFalse(okay.isEnabled, "默认不勾选，置灰")
        let check = node(app, "realname.consent.check")
        XCTAssertFalse(check.isSelected, "默认不勾选")
        check.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(check.isSelected, "读屏读勾选状态")
        XCTAssertEqual(entries(app, after: before).filter { $0.hasPrefix("backend:") }, [], "勾选零提交")
        okay.tap()
        XCTAssertTrue(node(app, "realname.page").waitForNonExistence(timeout: 10), "成功后出栈")
        XCTAssertEqual(entries(app, after: before).filter { $0 == "backend:realname.submit" }.count, 1, "恰一次")
        app.terminate()
    }

    /// [守卫] 【暂不认证】、点遮罩：不提交，内容保留；遮罩不关闭。
    func testConsentDeclineAndScrim() throws {
        let app = try launchRealName()
        fillReal(app)
        node(app, "realname.submit").tap()
        let cancel = node(app, "realname.consent.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(cancel.exists, "点遮罩不关闭")
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(node(app, "realname.page").exists, "留在本页")
        XCTAssertEqual(shown(node(app, "realname.field.id_no")), "110101199001011230", "内容保留")
        app.terminate()
    }

    /// W92：实名失败（末位 1 → 30406）错误条在字段之后读到；W94：勾选行四边真点都切换（命中 ≥ 44、不撑高）。
    func testErrorAfterFieldsInReadingOrder() throws {
        let app = try launchRealName()
        fillReal(app, id: "110101199001011231")
        node(app, "realname.submit").tap()
        let check = node(app, "realname.consent.check")
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.tap()
        node(app, "realname.consent.ok").tap()
        XCTAssertTrue(node(app, "realname.error").waitForExistence(timeout: 8), "错误条")
        let order = try readingOrder(app).map(\.id)
        let field = try XCTUnwrap(order.firstIndex(of: "realname.field.id_no"))
        let error = try XCTUnwrap(order.firstIndex(of: "realname.error.text"))
        XCTAssertLessThan(field, error, "错误条在字段之后")
        app.terminate()
    }

    // MARK: - 劳务

    /// 勾选零请求；签署恰一次（新记录项 backend:labor.sign）；成功出栈。
    func testSignRealTapOnce() throws {
        let app = try launchLabor()
        let before = log(app).count
        let sign = node(app, "labor.sign")
        XCTAssertFalse(sign.isEnabled, "未勾选置灰")
        node(app, "labor.check").tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(sign.isEnabled)
        XCTAssertEqual(entries(app, after: before).filter { $0 == "backend:labor.sign" }, [], "勾选零请求")
        sign.tap()
        XCTAssertTrue(node(app, "labor.page").waitForNonExistence(timeout: 10), "成功后出栈")
        XCTAssertEqual(entries(app, after: before).filter { $0 == "backend:labor.sign" }.count, 1, "恰一次")
        app.terminate()
    }

    /// brief §4.2：勾选框读勾选状态与版本号。
    func testLaborCheckReadsVersion() throws {
        let app = try launchLabor()
        let check = node(app, "labor.check")
        XCTAssertFalse(check.isSelected)
        XCTAssertTrue(check.label.contains("v1"), "读出版本号：\(check.label)")
        check.tap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(check.isSelected)
        app.terminate()
    }

    /// W94 / W100：勾选行上下缘真点都切换（命中区不小于 44、没有和【同意并签署】抢点）。
    func testLaborCheckEdgesRealTap() throws {
        let app = try launchLabor()
        let check = node(app, "labor.check")
        XCTAssertGreaterThanOrEqual(check.frame.height, 44, "读屏框 = 命中区")
        tapEdge(check, .top)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(check.isSelected, "上缘真点")
        tapEdge(check, .bottom)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(check.isSelected, "下缘真点")
        XCTAssertTrue(node(app, "labor.page").exists, "没有误点【同意并签署】")
        app.terminate()
    }

    // MARK: - 读屏

    /// W71：单选读选中态；[守卫] 账号读「星号」、不念完整值。
    func testRadioAndMaskedReadings() throws {
        let app = try launchPayoutPage("payout=none")
        XCTAssertTrue(node(app, "payout.method.alipay").isSelected, "支付宝选中")
        XCTAssertFalse(node(app, "payout.method.bank").isSelected)
        node(app, "payout.method.bank").tap()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(node(app, "payout.method.bank").isSelected, "选中态跟随")
        XCTAssertGreaterThanOrEqual(node(app, "payout.method.bank").frame.height, 44, "单选命中")
        app.terminate()
        let bound = try launchPayoutPage()
        XCTAssertTrue(node(bound, "payout.bound").label.contains("星"), "脱敏读法：\(node(bound, "payout.bound").label)")
        bound.terminate()
    }

    /// 只读记录不带身份证号、卡号（只记方法 + 路径 / 动作名）。
    func testLogHasNoSensitiveInput() throws {
        let app = try launchPayoutPage("payout=none")
        node(app, "payout.method.bank").tap()
        fill(app, "payout.field.card_no", "6222000000000009")
        fill(app, "payout.field.bank_name", "ceshibank")
        fill(app, "payout.field.payee_name", "ceshi")
        dismissKeyboard(app)
        node(app, "payout.save").tap()
        passStepUp(app)
        Thread.sleep(forTimeInterval: 1.5)
        let joined = log(app).joined(separator: " ")
        XCTAssertTrue(joined.contains("PUT /v1/me/payout-account"), "前提：有保存记录")
        XCTAssertFalse(joined.contains("6222000000000009"), "完整卡号进了只读记录")
        XCTAssertFalse(joined.contains("ceshi"), "收款人进了只读记录")
        app.terminate()
    }
}

/// 输入框显示 = 绑定值（c 组金额框的同类问题：`Binding(get:set:)` 的 `set` 被过滤拒绝时绑定值没变，SwiftUI 不写回，被拒字符留在框里）。
/// 资金写页的卡号、身份证号显示与提交不一致不能留。过滤规则本身由 WalletCore 纯规则定（向量 + `PayoutVisualFixtureTests` 守），
/// 这里断言框里显示的就是规则接受后的值。
@MainActor
final class PayoutVisualInputUITests: XCTestCase, PayoutVisualUITest {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// 卡号：字母留不下；删除后对得上；合法空格、连字符照常。先正后反。
    func testCardRejectedCharsDoNotStay() throws {
        let app = try launchPayoutPage("payout=none")
        node(app, "payout.method.bank").tap()
        let field = node(app, "payout.field.card_no")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("6222")
        assertBox(field, "6222", "合法输入")
        field.typeText("x")
        assertBox(field, "6222", "字母不留在框里")
        field.typeText("1")
        assertBox(field, "62221", "拒绝后继续输入对得上")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        assertBox(field, "6222", "删除对得上")
        app.terminate()
    }

    /// 卡号整串粘贴含非法字符：整串被拒，框里保持原值；超 32 位同理。
    func testCardPasteRejectedWhole() throws {
        let app = try launchPayoutPage("payout=none")
        node(app, "payout.method.bank").tap()
        let field = node(app, "payout.field.card_no")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        try paste(app, field, "6222abc")
        assertBox(field, "", "含字母的整串不进框")
        try paste(app, field, String(repeating: "1", count: 33))
        assertBox(field, "", "超长整串不进框")
        app.terminate()
    }

    /// 身份证号：字母留不下，小写 x 显示成大写 X，第 19 位留不下。
    func testIdRejectedCharsDoNotStay() throws {
        let app = try launchRealName()
        let field = node(app, "realname.field.id_no")
        field.tap()
        field.typeText("11010119900101123")
        assertBox(field, "11010119900101123", "合法输入")
        field.typeText("a")
        assertBox(field, "11010119900101123", "字母不留在框里")
        field.typeText("x")
        assertBox(field, "11010119900101123X", "小写 x 显示成提交用的大写")
        field.typeText("1")
        assertBox(field, "11010119900101123X", "第 19 位不留在框里")
        app.terminate()
    }

    /// 超长截断：框里显示截断后的值（`clip`）：收款人 64、登录号 128。
    func testClippedTextShownInBox() throws {
        let app = try launchPayoutPage("payout=none")
        let payee = node(app, "payout.field.payee_name")
        XCTAssertTrue(payee.waitForExistence(timeout: 3))
        payee.tap()
        try paste(app, payee, String(repeating: "a", count: 70))
        assertBox(payee, String(repeating: "a", count: 64), "收款人截到 64")
        app.terminate()
    }
}
