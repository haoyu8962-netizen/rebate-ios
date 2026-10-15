import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 绑手机页执行器与会话级服务的集成测试（APP-05b 任务书 §2.3、§2.6；APP-13a 共性第 6、8、9、16、18、21、24、25、44 条；G07）：
/// 真实 ApiClient（签名、幂等、未决键）+ 本地假服务。
@MainActor
final class BindPhoneControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.sms: okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
            case Paths.me: okReply(meData(phoneBound: false))
            case Paths.bindPhone: okReply()
            default: okReply()
            }
        }
    }

    private func make() throws -> BindFixture {
        let harness = OAuthHarness()
        try harness.seedSession()
        harness.phone.record(false, generation: harness.client.sessionGeneration)
        let log = BindHooksLog()
        let controller = harness.bindController(log)
        controller.appeared()
        return BindFixture(harness: harness, log: log, controller: controller)
    }

    private func fill(_ controller: BindPhoneController, phone: String = "138 0013 8000", code: String = "123456") {
        controller.setPhone(phone)
        controller.setCode(code)
    }

    /// 发码 purpose=bind（规范化号码），成功按号码倒计时、播报一次脱敏发送对象；倒计时内同号码不再发出。
    func testSendCodeUsesBindPurposeAndCountdown() async throws {
        let fixture = try make()
        let harness = fixture.harness
        let log = fixture.log
        let controller = fixture.controller
        controller.setPhone("+86 138-0013-8000")
        controller.sendCode()
        await waitUntil { !controller.sending }
        let body = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.sms).first).body)
        XCTAssertEqual(body["purpose"] as? String, "bind")
        XCTAssertEqual(body["phone"] as? String, "13800138000")
        XCTAssertEqual(controller.resendRemaining, 60)
        XCTAssertEqual(log.announced, ["login.code.sent_to|phone=138****8000"], "播报一次脱敏号码")
        controller.sendCode()
        harness.advance(seconds: 10)
        controller.sendCode()
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 1, "倒计时内不再发出")
    }

    /// 倒计时真正走完播报一次「可以重新获取」；换号后旧号码的结束不播报，切回也不补播。
    func testCountdownEndAnnouncedOnceBoundToPhone() async throws {
        let fixture = try make()
        let harness = fixture.harness
        let log = fixture.log
        let controller = fixture.controller
        controller.setPhone("13800138000")
        controller.sendCode()
        await waitUntil { !controller.sending }
        log.announced = []
        harness.advance(seconds: 61)
        controller.tick()
        XCTAssertEqual(log.announced, ["bind_phone.can_resend"])
        controller.tick()
        XCTAssertEqual(log.announced.count, 1, "不逐秒播报")

        controller.sendCode()
        await waitUntil { !controller.sending }
        log.announced = []
        controller.setPhone("13900139000")
        harness.advance(seconds: 61)
        controller.tick()
        controller.setPhone("13800138000")
        controller.tick()
        XCTAssertTrue(log.announced.isEmpty, "换号、切回都不误播报")
    }

    /// 绑定成功：bindPhone 带幂等键、不带 step-up token；共享结算推进绑定状态（更新世代）、onBound；持有页面许可时只出栈本实例。
    func testBindSuccessSettlesAndCompletes() async throws {
        let fixture = try make()
        let harness = fixture.harness
        let log = fixture.log
        let controller = fixture.controller
        let epoch = harness.phone.epoch
        fill(controller)
        controller.submit()
        await waitUntil { !controller.submitting }
        let request = try XCTUnwrap(LoginStubProtocol.requests(path: Paths.bindPhone).first)
        XCTAssertEqual(Set(bodyObject(request.body).keys), ["phone", "code"])
        XCTAssertNotNil(request.headers[HeaderNames.idempotencyKey], "写请求带幂等键")
        XCTAssertNil(request.headers[HeaderNames.stepUpToken], "首次绑定不带二次验证")
        XCTAssertEqual(harness.phone.bound(generation: harness.client.sessionGeneration), true)
        XCTAssertEqual(harness.phone.epoch, epoch + 1, "绑定成功推进更新世代")
        XCTAssertEqual(harness.bound.count, 1, "共享结算一次")
        XCTAssertEqual(log.completed.map(\.0), [controller.entryId])
        XCTAssertEqual(harness.router.currentGuardState.session, .phoneBound)
    }

    /// 共性第 12 条：绑定前发出的旧 getMe（phone_bound=false）晚于绑定成功到达，不覆盖绑定结果。
    func testStaleGetMeDoesNotOverrideBindSuccess() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.me ? .hold("me") : okReply()
        }
        let fixture = try make()
        let harness = fixture.harness
        let controller = fixture.controller
        let generation = harness.client.sessionGeneration
        harness.phone.record(false, generation: generation)
        var outcome: PhoneBindingQueryOutcome?
        harness.sync.query { outcome = $0 }
        await waitUntil { LoginStubProtocol.isHeld("me") }
        fill(controller)
        controller.submit()
        await waitUntil { !controller.submitting }
        XCTAssertEqual(harness.phone.bound(generation: generation), true)
        LoginStubProtocol.release("me", with: okReply(meData(phoneBound: false)))
        await waitUntil { outcome != nil }
        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(harness.phone.bound(generation: generation), true, "旧查询不覆盖")
    }

    /// 30411 mergeable → 并号确认弹窗（凭据只在内存）；【并入】锁定契约没有并号接口：不发任何请求、提示暂不可用；【取消】保留输入。
    func testMergeConfirmUnavailableAndCancelKeepsInputs() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone
                ? failReply(30411, data: "{\"reason\":\"mergeable\",\"merge_ticket\":\"ticket-demo\"}") : okReply()
        }
        let fixture = try make()
        let log = fixture.log
        let controller = fixture.controller
        log.provider = "WeChat"
        fill(controller, phone: "13800005678")
        controller.submit()
        await waitUntil { controller.dialog != nil }
        guard case let .merge(ticket, phone, id) = controller.dialog else { return XCTFail("应弹并号确认") }
        XCTAssertEqual(ticket, "ticket-demo")
        XCTAssertEqual(phone, "138****5678")
        XCTAssertEqual(controller.mergeBody(), "error.30411.mergeable|provider_name=WeChat")
        let before = LoginStubProtocol.requests(path: Paths.bindPhone).count
        controller.cancelMerge(dialogId: id)
        XCTAssertNil(controller.dialog)
        XCTAssertEqual(controller.phone, "13800005678", "取消：输入保留")
        XCTAssertEqual(controller.code, "123456")

        controller.submit()
        await waitUntil { controller.dialog != nil }
        let second = try XCTUnwrap(controller.dialog?.id)
        controller.confirmMerge(dialogId: second)
        XCTAssertEqual(controller.toast?.text, BindPhoneKeys.mergeUnavailable)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.bindPhone).count, before + 1, "确认后不另发请求")
        XCTAssertTrue(LoginStubProtocol.requests(path: "/v1/auth/merge").isEmpty, "不伪造并号请求")
        controller.confirmMerge(dialogId: second)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.bindPhone).count, before + 1, "旧弹窗编号无效")
    }

    /// 30411 无 reason 只提示；44001 风控弹窗带申诉入口（统一客服出口）。
    func testOccupiedAndRiskBlocked() async throws {
        LoginStubProtocol.install { request in
            guard request.path == Paths.bindPhone else { return okReply() }
            return bodyObject(request.body)["phone"] as? String == "13800001111" ? failReply(30411) : failReply(44001)
        }
        let fixture = try make()
        let log = fixture.log
        let controller = fixture.controller
        fill(controller, phone: "13800001111")
        controller.submit()
        await waitUntil { controller.notice != nil }
        XCTAssertEqual(controller.notice?.text, "error.30411")
        XCTAssertNil(controller.dialog)

        fill(controller, phone: "13800004444")
        controller.submit()
        await waitUntil { controller.dialog != nil }
        guard case let .risk(title, id) = controller.dialog else { return XCTFail("应弹风控") }
        XCTAssertEqual(title, "error.44001")
        controller.appeal(dialogId: id)
        XCTAssertEqual(log.contacted, 1)
    }

    /// 字段错误（共性第 6 条）：20002 验证码框提示、焦点事件、播报一次、输入保留；20003 清空验证码；本地号码不合法不发请求。
    func testFieldErrors() async throws {
        LoginStubProtocol.install { request in
            guard request.path == Paths.bindPhone else { return okReply() }
            return bodyObject(request.body)["code"] as? String == "200030" ? failReply(20003) : failReply(20002)
        }
        let fixture = try make()
        let log = fixture.log
        let controller = fixture.controller
        fill(controller, code: "111111")
        controller.submit()
        await waitUntil { controller.codeError != nil }
        XCTAssertEqual(controller.codeError, "error.20002")
        XCTAssertEqual(controller.fieldEvent?.field, "code")
        XCTAssertEqual(log.announced, ["error.20002"])
        XCTAssertEqual(controller.code, "111111", "输入保留")
        fill(controller, code: "200030")
        controller.submit()
        await waitUntil { controller.codeError == "error.20003" }
        XCTAssertEqual(controller.code, "", "失效的码清空")

        controller.setPhone("12345")
        controller.sendCode()
        XCTAssertEqual(controller.phoneError, "error.20001.phone_invalid")
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.sms).isEmpty)
    }

    /// 10007：cooling 经 Router 打开 DeleteAccount（发码、绑定两条路径都保留导航动作，共性第 10、16 条）；processing 只提示。
    func testDeletionCoolingNavigatesProcessingToasts() async throws {
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.sms: return failReply(10007, data: "{\"stage\":\"cooling\"}")
            case Paths.bindPhone:
                let processing = bodyObject(request.body)["code"] as? String == "100070"
                return failReply(10007, data: processing ? "{\"stage\":\"processing\"}" : "{\"stage\":\"cooling\"}")
            default: return okReply()
            }
        }
        let fixture = try make()
        let log = fixture.log
        let controller = fixture.controller
        controller.setPhone("13800138000")
        controller.sendCode()
        await waitUntil { log.opened.count == 1 }
        XCTAssertEqual(log.opened, ["DeleteAccount"])
        fill(controller)
        controller.submit()
        await waitUntil { log.opened.count == 2 }
        XCTAssertEqual(log.opened.last, "DeleteAccount")
        fill(controller, code: "100070")
        controller.submit()
        await waitUntil { controller.notice != nil }
        XCTAssertEqual(controller.notice?.text, "error.10007")
        XCTAssertEqual(log.opened.count, 2)
    }

    /// 42901（phoneGate）：按 Retry-After 禁用【绑定】，禁用期内不再发出；发码 42901 只记发码截止。
    func testRateLimitGatesBind() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? failReply(42901, headers: ["Retry-After": "30"]) : okReply()
        }
        let fixture = try make()
        let harness = fixture.harness
        let controller = fixture.controller
        fill(controller)
        controller.submit()
        await waitUntil { !controller.submitting }
        XCTAssertTrue(harness.bind.gate.active)
        XCTAssertFalse(controller.canSubmit)
        controller.submit()
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.bindPhone).count, 1)
    }

    /// G07：结果未知 → 待确认卡（取自本机未决记录）；【确认上一次提交】原键原体重发、成功按绑定成功结算。
    func testUnknownResultShowsPendingCardThenConfirm() async throws {
        let calls = MutableBox(0)
        LoginStubProtocol.install { request in
            guard request.path == Paths.bindPhone else { return okReply() }
            calls.value += 1
            return calls.value == 1 ? .json(status: 502, headers: [:], body: "<html>gateway</html>") : okReply()
        }
        let fixture = try make()
        let harness = fixture.harness
        let log = fixture.log
        let controller = fixture.controller
        fill(controller)
        controller.submit()
        await waitUntil { controller.pending != nil }
        let card = try XCTUnwrap(controller.pending)
        XCTAssertEqual(card.maskedPhone, "138****8000")
        XCTAssertFalse(controller.canSubmit, "待确认时不能新提交")
        let first = try XCTUnwrap(LoginStubProtocol.requests(path: Paths.bindPhone).first)
        controller.confirmPending(key: card.key)
        await waitUntil { log.completed.count == 1 }
        let second = try XCTUnwrap(LoginStubProtocol.requests(path: Paths.bindPhone).last)
        XCTAssertEqual(second.headers[HeaderNames.idempotencyKey], first.headers[HeaderNames.idempotencyKey], "原键")
        XCTAssertEqual(second.body, first.body, "原体")
        XCTAssertNil(second.headers[HeaderNames.stepUpToken], "确认时不预先二次验证")
        XCTAssertEqual(harness.phone.bound(generation: harness.client.sessionGeneration), true)
        await waitUntil { controller.pending == nil }
    }

    /// G07：【放弃上一次提交】二次确认后作废原键；abandoned → 卡片消失、可重新提交（下次用新键）。
    func testAbandonPending() async throws {
        let calls = MutableBox(0)
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.bindPhone:
                calls.value += 1
                return calls.value == 1 ? .json(status: 502, headers: [:], body: "x") : okReply()
            case Paths.abandon: return okReply("{\"outcome\":\"abandoned\",\"original\":null}")
            default: return okReply()
            }
        }
        let fixture = try make()
        let controller = fixture.controller
        fill(controller)
        controller.submit()
        await waitUntil { controller.pending != nil }
        let key = try XCTUnwrap(controller.pending?.key)
        controller.askAbandon(key: key)
        guard case let .abandon(_, id) = controller.dialog else { return XCTFail("应弹放弃确认") }
        controller.confirmAbandon(dialogId: id)
        await waitUntil { controller.pending == nil && !controller.pendingBusy }
        XCTAssertEqual(controller.toast?.text, "pending_confirm.abandoned")
        let abandon = bodyObject(try XCTUnwrap(LoginStubProtocol.requests(path: Paths.abandon).first).body)
        XCTAssertEqual(abandon["action"] as? String, "phone_change")
        fill(controller)
        controller.submit()
        await waitUntil { !controller.submitting }
        let keys = LoginStubProtocol.requests(path: Paths.bindPhone).map { $0.headers[HeaderNames.idempotencyKey] }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1], "放弃后用新键")
    }

    /// 共性第 6、16、45 条：固定身份——会话换代后旧页面的发码、提交一律不发（不能用另一账号的令牌绑定）。
    func testOldOwnerNeverSendsAfterSessionChange() async throws {
        let fixture = try make()
        let harness = fixture.harness
        let controller = fixture.controller
        fill(controller)
        try harness.seedSession(account: "u2")
        controller.sendCode()
        controller.submit()
        await waitUntil { !controller.submitting && !controller.sending }
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.sms).isEmpty)
        XCTAssertTrue(LoginStubProtocol.requests(path: Paths.bindPhone).isEmpty)
    }

    /// 共性第 21、25 条：写请求离页不取消——页面作废后迟到的成功照常做共享结算，但不再导航、不出栈。
    func testWriteSurvivesLeaveAndSettlesWithoutNavigation() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .hold("bind") : okReply()
        }
        let fixture = try make()
        let harness = fixture.harness
        let log = fixture.log
        let controller = fixture.controller
        fill(controller)
        controller.submit()
        await waitUntil { LoginStubProtocol.isHeld("bind") }
        controller.invalidate()
        XCTAssertFalse(LoginStubProtocol.wasStopped("bind"), "离页不取消写请求")
        LoginStubProtocol.release("bind", with: okReply())
        await waitUntil { harness.bound.count == 1 }
        XCTAssertEqual(harness.phone.bound(generation: harness.client.sessionGeneration), true)
        XCTAssertTrue(log.completed.isEmpty, "原页面已离开：不导航")
    }

    /// 共性第 38 条：进页时手机号状态未知 → 查 getMe；查清已绑只出栈本实例、只恢复。
    func testEntryRecheckClosesWhenAlreadyBound() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.me ? okReply(meData(phoneBound: true)) : okReply()
        }
        let harness = OAuthHarness()
        try harness.seedSession()
        let log = BindHooksLog()
        let controller = harness.bindController(log)
        controller.appeared()
        await waitUntil { log.alreadyBound.count == 1 }
        XCTAssertEqual(log.alreadyBound.first?.0, controller.entryId)
        XCTAssertTrue(log.completed.isEmpty, "不算本页完成前置")
    }

    /// 第 1 轮 R1-04（改写原 testDialogDeferredWhileHidden：旧断言「回到页面再弹」与 APP-13a 共性第 23 条相反）：弹窗核对**发起时**
    /// 的页面许可——隐藏期间到达的风控结果丢弃，回到页面也不补弹。
    func testDialogDroppedWhenResultArrivesWhileHidden() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? failReply(44001) : okReply()
        }
        let fixture = try make()
        let log = fixture.log
        let controller = fixture.controller
        fill(controller)
        controller.submit()
        controller.disappeared()
        log.top = false
        await waitUntil { !controller.submitting }
        XCTAssertNil(controller.dialog, "隐藏时不弹")
        log.top = true
        controller.appeared()
        XCTAssertNil(controller.dialog, "原许可已失效：回到页面不补弹")
    }
}

/// 一个绑手机页执行器的测试组合。
@MainActor
struct BindFixture {
    let harness: OAuthHarness
    let log: BindHooksLog
    let controller: BindPhoneController
}
