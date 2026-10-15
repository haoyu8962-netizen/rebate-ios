import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 第 3 轮评审窄修（APP-05b ios-review-r3 R3-01、R3-02）的回归测试：绑定成功 / 进页查明已绑在「成功先到」与「页面先恢复」两种顺序下
/// 都只退出本实例一次；发码在途编辑号码后共享倒计时照常重启计时器。
@MainActor
final class BindPhoneReviewR3Tests: XCTestCase {
    private func make(phoneKnown: Bool = true) throws -> BindFixture {
        let harness = OAuthHarness()
        try harness.seedSession()
        if phoneKnown {
            harness.phone.record(false, generation: harness.client.sessionGeneration)
        }
        let log = BindHooksLog()
        let controller = harness.bindController(log)
        controller.appeared()
        return BindFixture(harness: harness, log: log, controller: controller)
    }

    /// 拉下通知中心：场景 inactive + 页面不可见。
    private func hide(_ fixture: BindFixture) {
        fixture.log.active = false
        fixture.controller.disappeared()
    }

    private func show(_ fixture: BindFixture) {
        fixture.log.active = true
        fixture.controller.appeared()
    }

    /// 提交绑定并挂起在假服务上，随后页面隐藏；`restoreFirst` 为真时先回到页面再放行成功，为假时在隐藏期间放行。
    private func bindAcrossHidden(_ fixture: BindFixture, hold: String, restoreFirst: Bool) async {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .hold(hold) : okReply()
        }
        let controller = fixture.controller
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        await waitUntil { LoginStubProtocol.isHeld(hold) }
        hide(fixture)
        if restoreFirst {
            show(fixture)
        }
        LoginStubProtocol.release(hold, with: okReply())
        await waitUntil { !controller.submitting }
        await settleR3()
    }

    /// R3-01（页面先恢复）：提交 → 拉下通知中心 → 响应前回到页面 → 绑定成功：结果到达时当场按完成前置退出本实例一次，不等下一次
    /// appeared；随后的共享通知、再次出现都不重复退出。
    func testBindDoneAfterPageRestoredExitsImmediately() async throws {
        let fixture = try make()
        await bindAcrossHidden(fixture, hold: "bind-restored", restoreFirst: true)
        let controller = fixture.controller
        XCTAssertEqual(fixture.log.completed.map(\.0), [controller.entryId], "结果到达时当场退出一次")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "共享通知不再按只恢复重复退出")
        show(fixture)
        XCTAssertEqual(fixture.log.completed.count, 1, "再次出现不重复退出")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty)
    }

    /// R3-01（成功先到）：隐藏期间绑定成功 → 不退出，延后；回到页面时按完成前置退出一次；共享通知不抢先按只恢复退出。
    /// 延后记录绑原身份：同账号重新登录（登录世代变了）后回到页面不消费。
    func testBindDoneWhileHiddenDeferredToReturnAndBoundToOwner() async throws {
        let fixture = try make()
        await bindAcrossHidden(fixture, hold: "bind-hidden", restoreFirst: false)
        XCTAssertTrue(fixture.log.completed.isEmpty, "隐藏时不退出")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "共享通知不抢先退出")
        show(fixture)
        XCTAssertEqual(fixture.log.completed.map(\.0), [fixture.controller.entryId], "回到页面退出一次")
        show(fixture)
        XCTAssertEqual(fixture.log.completed.count, 1)

        // 延后记录绑原身份：隐藏期间成功 → 同账号重新登录（世代推进，App 尚未重建本页）→ 回到页面：不按旧身份退出
        let other = try make()
        await bindAcrossHidden(other, hold: "bind-hidden-relogin", restoreFirst: false)
        try other.harness.seedSession()
        show(other)
        XCTAssertTrue(other.log.completed.isEmpty, "身份已变：延后的成功不消费")
        XCTAssertTrue(other.log.alreadyBound.isEmpty)
    }

    /// R3-01（进页查询）：手机号状态未知 → 进页 getMe 挂起 → 隐藏 → 回到页面（本次 appeared 已执行）→ 查明已绑：当场只恢复退出一次；
    /// 对照：隐藏期间查明已绑 → 回到页面退出一次。都不算完成前置。
    func testPhoneQueryBoundExitsInBothOrders() async throws {
        for restoreFirst in [true, false] {
            let hold = "me-\(restoreFirst)"
            LoginStubProtocol.install { request in
                request.path == Paths.me ? .hold(hold) : okReply()
            }
            let fixture = try make(phoneKnown: false)
            await waitUntil { LoginStubProtocol.isHeld(hold) }
            hide(fixture)
            if restoreFirst {
                show(fixture)
            }
            LoginStubProtocol.release(hold, with: okReply(meData(phoneBound: true)))
            let harness = fixture.harness
            await waitUntil { harness.phone.bound(generation: harness.client.sessionGeneration) == true }
            await settleR3()
            if restoreFirst {
                XCTAssertEqual(fixture.log.alreadyBound.map(\.0), [fixture.controller.entryId], "页面先恢复：当场退出一次")
            } else {
                XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "仍隐藏：延后")
            }
            show(fixture)
            XCTAssertEqual(fixture.log.alreadyBound.map(\.0), [fixture.controller.entryId], "\(hold)：只退出一次")
            XCTAssertTrue(fixture.log.completed.isEmpty, "\(hold)：只恢复，不算完成前置")
            XCTAssertEqual(LoginStubProtocol.requests(path: Paths.me).count, 1, "\(hold)：不重复查询")
        }
    }

    /// R3-02：没有倒计时时向 A 发码 → 响应前清空再粘回 A / 改成 +86 等价格式 → 成功或 42901：旧表单的发送对象播报、提示、字段错误
    /// 都丢弃，但按当前规范化号码刷新计时器——按钮先禁用，到期自动恢复，不需要再改号或切页。
    func testSmsInFlightPhoneEditStillRestartsTimer() async throws {
        let fixture = try make()
        let controller = fixture.controller
        let cases = [
            EditCase(phone: "13800006661", edits: ["", "13800006661"], hold: "sms-clear-repaste", seconds: 61,
                     reply: okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")),
            EditCase(phone: "13800006662", edits: ["+86 138 0000 6662"], hold: "sms-plus86", seconds: 61,
                     reply: okReply("{\"resend_after_sec\":60,\"expires_in_sec\":300}")),
            EditCase(phone: "13800006663", edits: ["", "13800006663"], hold: "sms-42901", seconds: 31,
                     reply: failReply(42901, headers: ["Retry-After": "30"])),
        ]
        for item in cases {
            let hold = item.hold
            LoginStubProtocol.install { request in
                request.path == Paths.sms ? .hold(hold) : okReply()
            }
            controller.setPhone(item.phone)
            controller.sendCode()
            await waitUntil { LoginStubProtocol.isHeld(hold) }
            for edit in item.edits {
                controller.setPhone(edit)
            }
            LoginStubProtocol.release(hold, with: item.reply)
            await waitUntil { !controller.sending }
            await settleR3()
            XCTAssertGreaterThan(controller.resendRemaining, 0, "\(hold)：按共享截止时间显示倒计时")
            XCTAssertFalse(controller.canSendCode, "\(hold)：倒计时内按钮禁用")
            XCTAssertNil(controller.notice, "\(hold)：旧表单的提示丢弃")
            XCTAssertNil(controller.phoneError, "\(hold)：不写字段错误")
            fixture.harness.advance(seconds: item.seconds)
            await waitUntil { controller.canSendCode }
            XCTAssertEqual(controller.resendRemaining, 0, "\(hold)：计时器已启动，到期自动恢复")
        }
        XCTAssertFalse(fixture.log.announced.contains { $0.hasPrefix("login.code.sent_to") }, "旧表单的发送对象不播报")
    }

    /// 编排补充（鸿蒙同类，APP-05b 共性 35）：验证码修订号绑定实际发送的提交。同号码提交 A → 在途改成 B → A 得 50001（首次提交、从未
    /// 结果未知：键不用了，本机未决记录删除）→ 再点【绑定】：iOS 不复用原键 / 原请求体，按当前输入 B 生成新键新请求体，修订号也随这次
    /// 提交捕获，二者一致。这次请求在途再改成 C → 迟到 20003 / 20002 不落到 C、不清 C；对照：未改码时 20002 显示在 B 上（B 才是实际发送的码）。
    func testCodeRevisionBoundToActuallySentSubmission() async throws {
        let fixture = try make()
        let controller = fixture.controller
        for code in [20003, 20002] {
            LoginStubProtocol.install { request in
                request.path == Paths.bindPhone ? .hold("first-\(code)") : okReply()
            }
            controller.setPhone("13800138000")
            controller.setCode("111111")
            controller.submit()
            await waitUntil { LoginStubProtocol.isHeld("first-\(code)") }
            controller.setCode("222222")
            LoginStubProtocol.release("first-\(code)", with: failReply(50001))
            await waitUntil { !controller.submitting }
            await settleR3()
            XCTAssertNil(controller.pending, "\(code)：首次提交的 50001 不进待确认")
            XCTAssertEqual(controller.code, "222222")
            let first = try XCTUnwrap(LoginStubProtocol.requests(path: Paths.bindPhone).last)
            XCTAssertEqual(bodyObject(first.body)["code"] as? String, "111111")

            LoginStubProtocol.install { request in
                request.path == Paths.bindPhone ? .hold("retry-\(code)") : okReply()
            }
            controller.submit()
            await waitUntil { LoginStubProtocol.isHeld("retry-\(code)") }
            let retry = try XCTUnwrap(LoginStubProtocol.requests(path: Paths.bindPhone).last)
            XCTAssertNotEqual(retry.headers[HeaderNames.idempotencyKey], first.headers[HeaderNames.idempotencyKey],
                              "\(code)：重试是新键，不复用原键")
            XCTAssertEqual(bodyObject(retry.body)["code"] as? String, "222222", "\(code)：重发的是当前输入 B，不是原请求体 A")
            controller.setCode("333333")
            LoginStubProtocol.release("retry-\(code)", with: failReply(code))
            await waitUntil { !controller.submitting }
            await settleR3()
            XCTAssertEqual(controller.code, "333333", "\(code)：不清 C")
            XCTAssertNil(controller.codeError, "\(code)：B 的错误不显示在 C 上")
            XCTAssertNil(controller.fieldEvent, "\(code)：不移焦点")
        }
        XCTAssertFalse(fixture.log.announced.contains { $0.hasPrefix("error.2000") }, "全程不播报旧提交的字段错误")

        // 对照：实际发送的就是当前输入时，20002 照常显示
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? failReply(20002) : okReply()
        }
        controller.submit()
        await waitUntil { controller.codeError != nil }
        let last = try XCTUnwrap(LoginStubProtocol.requests(path: Paths.bindPhone).last)
        XCTAssertEqual(bodyObject(last.body)["code"] as? String, "333333")
        XCTAssertEqual(controller.codeError, "error.20002")
    }
}

private struct EditCase {
    let phone: String
    let edits: [String]
    let hold: String
    let seconds: Int64
    let reply: LoginStubProtocol.Reply
}

/// 让已排队的主线程任务跑完（没有可等的条件时用）。
@MainActor
private func settleR3() async {
    for _ in 0..<5 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
