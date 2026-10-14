import XCTest

/// APP-09 前置补办（劳务协议、收款账号、实名）、收款账号页、提现记录与适配的设计稿比对截图（只在设置 TEST_RUNNER_COULI_SHOT_DIR 时跑，写到
/// NATIVE/APP-09/shots/ios/）。全部假数据，表单只填明显的测试值。
@MainActor
final class WalletFlowShotTests: XCTestCase, WalletUITest {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        resetFakeSession()
    }

    func testShotsGuides() throws {
        try requireShots()
        var app = openWithdraw("labor=unsigned")
        typeAmount(app, "5")
        dismissKeyboard(app)
        save(app, "WithdrawGuideLabor")
        tapId(app, "withdraw.guide.button")
        XCTAssertTrue(element(app, "labor.sign").waitForExistence(timeout: 10), "没有进劳务协议")
        pause(1.2)
        save(app, "LaborAgreement")
        tapId(app, "labor.check")
        pause()
        save(app, "LaborAgreement-checked")
        tapId(app, "labor.sign")
        XCTAssertTrue(element(app, "withdraw.balance").waitForExistence(timeout: 10), "签署后没有回到提现页")
        pause(1.5)
        save(app, "WithdrawAfterLabor")
        app.terminate()

        app = openWithdraw("payout=none")
        pause()
        save(app, "WithdrawGuidePayout")
        tapId(app, "withdraw.guide.button")
        XCTAssertTrue(element(app, "payout.save").waitForExistence(timeout: 10), "没有进收款账号")
        pause()
        save(app, "PayoutAccount")
        tapId(app, "payout.method.bank")
        pause()
        save(app, "PayoutAccountBank")
        for (id, text) in [("payout.field.card_no", "6222000000000009"), ("payout.field.bank_name", "测试银行"),
                           ("payout.field.payee_name", "测试")] {
            tapId(app, id)
            element(app, id).typeText(text)
        }
        dismissKeyboard(app)
        pause()
        save(app, "PayoutAccountBank-filled")
        tapId(app, "payout.method.alipay")
        tapId(app, "payout.field.alipay_logon_id")
        element(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapId(app, "payout.save")
        let code = element(app, "stepUp.code")
        XCTAssertTrue(code.waitForExistence(timeout: 10), "首次绑定也要二次验证")
        pause(1.2)
        save(app, "PayoutStepUp")
        code.tap()
        code.typeText("123456")
        tapId(app, "stepUp.submit")
        XCTAssertTrue(element(app, "withdraw.balance").waitForExistence(timeout: 15), "保存后没有回到提现页")
        pause(1.5)
        save(app, "PayoutSaved-backToWithdraw")
        app.terminate()
    }

    func testShotsRealName() throws {
        try requireShots()
        let app = openWallet("realname=none")
        tapButton(app, "提现")
        XCTAssertTrue(element(app, "realname.submit").waitForExistence(timeout: 15), "未实名应进实名页")
        pause()
        save(app, "RealName")
        tapId(app, "realname.field.name")
        element(app, "realname.field.name").typeText("测试")
        tapId(app, "realname.field.id_no")
        element(app, "realname.field.id_no").typeText("00000020000101123x")
        dismissKeyboard(app)
        pause()
        save(app, "RealName-filled")
        tapId(app, "realname.submit")
        XCTAssertTrue(element(app, "realname.consent.ok").waitForExistence(timeout: 10), "没有弹单独同意")
        pause()
        save(app, "RealNameConsent")
        tapId(app, "realname.consent.check")
        pause()
        save(app, "RealNameConsent-checked")
    }

    func testShotsPayout() throws {
        try requireShots()
        var app = openWithdraw()
        tapId(app, "withdraw.payout")
        XCTAssertTrue(element(app, "payout.change").waitForExistence(timeout: 10))
        pause()
        save(app, "PayoutAccountBound")
        app.terminate()
        app = openWithdraw("payout=bank")
        tapId(app, "withdraw.payout")
        XCTAssertTrue(element(app, "payout.change").waitForExistence(timeout: 10))
        pause()
        save(app, "PayoutAccountBoundBank")
        app.terminate()

        app = openWithdraw("save=44001")
        tapId(app, "withdraw.payout")
        tapId(app, "payout.change")
        tapId(app, "payout.field.alipay_logon_id")
        element(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapId(app, "payout.field.payee_name")
        element(app, "payout.field.payee_name").typeText("测试")
        tapId(app, "payout.save")
        passStepUp(app)
        XCTAssertTrue(element(app, "risk.dialog").waitForExistence(timeout: 15), "没有风控弹窗")
        pause()
        save(app, "PayoutAccountBlocked")
        app.terminate()

        app = openWithdraw("save=unknown_created")
        tapId(app, "withdraw.payout")
        tapId(app, "payout.change")
        tapId(app, "payout.field.alipay_logon_id")
        element(app, "payout.field.alipay_logon_id").typeText("test@example.com")
        tapId(app, "payout.field.payee_name")
        element(app, "payout.field.payee_name").typeText("测试")
        tapId(app, "payout.save")
        passStepUp(app)
        XCTAssertTrue(element(app, "pending.card").waitForExistence(timeout: 20), "没有进入待确认")
        pause(1.2)
        save(app, "PayoutAccountPendingConfirm")
        tapId(app, "pending.abandon")
        pause()
        save(app, "PayoutAccountPendingAbandonConfirm")
        app.buttons["确定放弃"].firstMatch.tap()
        pause(2)
        save(app, "PayoutAccountPendingCompleted")
    }

    func testShotsRecords() throws {
        try requireShots()
        var app = openWallet()
        tapButton(app, "提现记录")
        XCTAssertTrue(element(app, "records.list").waitForExistence(timeout: 15))
        pause(1.2)
        save(app, "WithdrawRecords")
        for (id, name) in [("record.W2026101200001", "WithdrawRecordsPending"),
                           ("record.W2026100800003", "WithdrawRecordsFailed"),
                           ("record.W2026092700002", "WithdrawRecordsPaid"),
                           ("record.W2026092500001", "WithdrawRecordsRejected")] {
            tapId(app, id)
            pause(1.5)
            let detail = element(app, id.replacingOccurrences(of: "record.", with: "record.detail."))
            if detail.exists, !detail.isHittable {
                app.swipeUp()
                pause()
            }
            save(app, name)
            if name == "WithdrawRecordsPaid" {
                tapId(app, "record.copy")
                pause(0.4)
                save(app, "WithdrawRecordsPaid-copied")
            }
            tapId(app, id)
            pause()
        }
        app.terminate()
        app = openWallet("records=empty")
        tapButton(app, "提现记录")
        XCTAssertTrue(element(app, "records.empty").waitForExistence(timeout: 15))
        pause()
        save(app, "WithdrawRecordsEmpty")
    }

    func testShotsAdapt() throws {
        try requireShots()
        let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryExtraExtraExtraLarge"]
        let ax = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        let narrow = ["-CouliDebugLayoutWidth", "320"]
        for (extra, suffix) in [(xxxl, "AdaptLargeText130"), (ax, "AdaptLargeText200"), (narrow, "AdaptNarrow"),
                                (narrow + ax, "AdaptNarrowLargeText200")] {
            var app = openWallet("", extra)
            save(app, suffix + "-Wallet")
            app.terminate()
            app = openWithdraw("", extra)
            typeAmount(app, "10")
            pause(1.5)
            dismissKeyboard(app)
            pause()
            save(app, suffix + "-Withdraw")
            if suffix == "AdaptLargeText200" {
                tapId(app, "withdraw.submit")
                let code = element(app, "stepUp.code")
                XCTAssertTrue(code.waitForExistence(timeout: 10))
                pause(1.2)
                save(app, "AdaptShortStepUp-200")
                code.tap()
                pause(1)
                save(app, "AdaptShortStepUp-200-keyboard")
            }
            app.terminate()
        }
    }
}
