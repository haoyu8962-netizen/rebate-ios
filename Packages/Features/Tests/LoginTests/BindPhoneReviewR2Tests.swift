import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 第 2 轮评审修复（APP-05b ios-review-r2 R2-02、R2-03）的回归测试：发码回调核对发起时的页面许可；同号换码后旧请求的验证码错误
/// 不落到新码上。
@MainActor
final class BindPhoneReviewR2Tests: XCTestCase {
    private func make() throws -> BindFixture {
        let harness = OAuthHarness()
        try harness.seedSession()
        harness.phone.record(false, generation: harness.client.sessionGeneration)
        let log = BindHooksLog()
        let controller = harness.bindController(log)
        controller.appeared()
        return BindFixture(harness: harness, log: log, controller: controller)
    }

    /// 发一次码并挂起在假服务上，页面许可随后失效（拉下通知中心：inactive + disappeared）；`afterReturn` 为假时在失效期间按 `reply`
    /// 放行，为真时先回到页面（新的可见世代）再放行。结束时页面已重新可见。
    private func sendAcrossInactive(_ fixture: BindFixture, phone: String, hold: String,
                                    reply: LoginStubProtocol.Reply, afterReturn: Bool = false) async {
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? .hold(hold) : okReply()
        }
        let controller = fixture.controller
        controller.setPhone(phone)
        controller.sendCode()
        await waitUntil { LoginStubProtocol.isHeld(hold) }
        fixture.log.active = false
        controller.disappeared()
        if !afterReturn {
            await release(controller, hold: hold, reply: reply)
        }
        fixture.log.active = true
        controller.appeared()
        await settleR2()
        if afterReturn {
            await release(controller, hold: hold, reply: reply)
        }
    }

    private func release(_ controller: BindPhoneController, hold: String, reply: LoginStubProtocol.Reply) async {
        LoginStubProtocol.release(hold, with: reply)
        await waitUntil { !controller.sending }
        await settleR2()
    }

    /// 第 2 轮 R2-02：发码后页面许可失效再回来，原请求随后成功——共享倒计时照常（按固定归属结算），但不播报已失效请求的发送对象，
    /// 回来后也不补播；倒计时结束的「可以重新获取」仍按记下的截止时刻播报一次。
    func testSmsSentWhileInactiveSettlesCountdownWithoutAnnouncing() async throws {
        let fixture = try make()
        await sendAcrossInactive(
            fixture, phone: "13800138000", hold: "sms-ok",
            reply: okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}"), afterReturn: true
        )
        let controller = fixture.controller
        XCTAssertEqual(controller.resendRemaining, 60, "共享倒计时照常结算")
        XCTAssertTrue(fixture.log.announced.isEmpty, "失效请求的发码成功不播报、不补播")
        fixture.harness.advance(seconds: 61)
        controller.tick()
        XCTAssertEqual(fixture.log.announced, ["bind_phone.can_resend"], "倒计时结束照常播报一次")

        // 对照：持有许可时成功照常播报
        LoginStubProtocol.install { request in
            request.path == Paths.sms ? okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}") : okReply()
        }
        fixture.log.announced = []
        controller.sendCode()
        await waitUntil { !controller.sending }
        XCTAssertEqual(fixture.log.announced, ["login.code.sent_to|phone=138****8000"])
    }

    /// 第 2 轮 R2-02：20001、50401、42901 在许可失效期间（或回到页面之后）到达——不写字段错误、不显示提示、不播报，回来后也不出现；
    /// 42901 的共享限流照常记下。
    func testSmsErrorsWhileInactiveDropped() async throws {
        let fixture = try make()
        let controller = fixture.controller
        await sendAcrossInactive(fixture, phone: "13800001111", hold: "sms-20001", reply: failReply(20001))
        XCTAssertNil(controller.phoneError, "20001 不写字段错误")
        XCTAssertNil(controller.fieldEvent, "不移焦点")
        await sendAcrossInactive(
            fixture, phone: "13800001112", hold: "sms-20001b", reply: failReply(20001), afterReturn: true
        )
        XCTAssertNil(controller.phoneError, "回到页面后才到的失效请求同样丢弃")

        await sendAcrossInactive(fixture, phone: "13800002222", hold: "sms-50401", reply: failReply(50401))
        XCTAssertNil(controller.notice, "50401 不显示提示")

        await sendAcrossInactive(
            fixture, phone: "13800003333", hold: "sms-42901",
            reply: failReply(42901, headers: ["Retry-After": "30"])
        )
        XCTAssertNil(controller.notice, "42901 不显示提示")
        XCTAssertGreaterThan(controller.resendRemaining, 0, "共享限流照常记下")
        XCTAssertTrue(fixture.log.announced.isEmpty, "全程不播报")
    }

    /// 第 2 轮 R2-02 补充（同鸿蒙 FU-HM-0720 R2-01）：发码在途时页面隐藏、响应返回前已回到页面——旧许可的结果不提示、不播报，但共享
    /// 倒计时 / 42901 截止时间已更新，当前可见且身份有效的本页按共享截止时间重算并启动计时器：按钮先禁用，到期自动恢复，不需要再操作。
    func testReturnedPageRestartsTimerFromSharedDeadline() async throws {
        let fixture = try make()
        let controller = fixture.controller
        let cases = [
            SmsCase(phone: "13800004444", hold: "sms-sent-back", seconds: 61,
                    reply: okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")),
            SmsCase(phone: "13800005555", hold: "sms-429-back", seconds: 31,
                    reply: failReply(42901, headers: ["Retry-After": "30"])),
        ]
        for item in cases {
            let hold = item.hold
            await sendAcrossInactive(fixture, phone: item.phone, hold: hold, reply: item.reply, afterReturn: true)
            XCTAssertGreaterThan(controller.resendRemaining, 0, "\(hold)：按共享截止时间显示倒计时")
            XCTAssertFalse(controller.canSendCode, "\(hold)：倒计时内按钮禁用")
            XCTAssertNil(controller.notice, "\(hold)：不补提示")
            fixture.harness.advance(seconds: item.seconds)
            await waitUntil { controller.canSendCode }
            XCTAssertEqual(controller.resendRemaining, 0, "\(hold)：计时器已启动，到期自动恢复按钮")
            XCTAssertNil(controller.notice)
        }
        XCTAssertFalse(fixture.log.announced.contains { $0.hasPrefix("login.code.sent_to") }, "失效请求的发码成功不播报")
    }

    /// 编排补充（Android FU-AND-0716，共性第 32 条）：待确认【确认上一次提交】的非终结响应（5xxxx、无法确认的 2xxxx、42901）在页面许可
    /// 失效后到达——卡片照常按本机未决记录保留，但「稍后再试 / 暂时无法确认」提示不显示、不播报；42901 的 phoneGate 照常结算。
    func testPendingConfirmNonTerminalNoticesNeedOriginalPermit() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .json(status: 502, headers: [:], body: "x") : okReply()
        }
        let fixture = try make()
        let controller = fixture.controller
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        await waitUntil { controller.pending != nil }
        let key = try XCTUnwrap(controller.pending?.key)
        let replies: [(String, LoginStubProtocol.Reply)] = [
            ("confirm-5", failReply(50001)),
            ("confirm-2", failReply(20002)),
            ("confirm-429", failReply(42901, headers: ["Retry-After": "30"])),
        ]
        for (hold, reply) in replies {
            LoginStubProtocol.install { request in
                request.path == Paths.bindPhone ? .hold(hold) : okReply()
            }
            controller.confirmPending(key: key)
            await waitUntil { LoginStubProtocol.isHeld(hold) }
            fixture.log.active = false
            controller.disappeared()
            fixture.log.active = true
            controller.appeared()
            LoginStubProtocol.release(hold, with: reply)
            await waitUntil { !controller.pendingBusy }
            await settleR2()
            XCTAssertNil(controller.pendingNotice, "\(hold)：失效请求的待确认提示不显示")
            XCTAssertNil(controller.notice, "\(hold)：不显示页内提示")
            XCTAssertEqual(controller.pending?.key, key, "\(hold)：待确认卡按未决记录保留")
        }
        XCTAssertTrue(controller.writeGated, "42901 的 phoneGate 照常结算")
        XCTAssertTrue(fixture.log.announced.isEmpty, "全程不播报")
    }

    /// 第 2 轮 R2-03：同一号码提交验证码 A，未返回时改成 B——A 的 20003 不清空 B、不显示错误；A 的 20002 不显示在 B 上。
    func testSamePhoneCodeChangeDropsStaleCodeErrors() async throws {
        let fixture = try make()
        let controller = fixture.controller
        for (index, code) in [20003, 20002].enumerated() {
            let hold = "bind-\(code)"
            LoginStubProtocol.install { request in
                request.path == Paths.bindPhone ? .hold(hold) : okReply()
            }
            controller.setPhone("13800138000")
            controller.setCode("11111\(index)")
            controller.submit()
            await waitUntil { LoginStubProtocol.isHeld(hold) }
            controller.setCode("22222\(index)")
            LoginStubProtocol.release(hold, with: failReply(code))
            await waitUntil { !controller.submitting }
            await settleR2()
            XCTAssertEqual(controller.code, "22222\(index)", "\(code)：不清新验证码")
            XCTAssertNil(controller.codeError, "\(code)：旧码的错误不显示在新码上")
            XCTAssertNil(controller.fieldEvent, "\(code)：不移焦点")
            XCTAssertTrue(fixture.log.announced.isEmpty, "\(code)：不播报")
        }

        // 对照：验证码没改时 20002 照常显示
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? failReply(20002) : okReply()
        }
        controller.submit()
        await waitUntil { controller.codeError != nil }
        XCTAssertEqual(controller.codeError, "error.20002")
    }
}

private struct SmsCase {
    let phone: String
    let hold: String
    let seconds: Int64
    let reply: LoginStubProtocol.Reply
}

/// 让已排队的主线程任务跑完（没有可等的条件时用）。
@MainActor
private func settleR2() async {
    for _ in 0..<5 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
