import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// 绑手机第 1 轮评审修复（APP-05b ios-review-r1 R1-03、R1-04、R1-05、R1-08、R1-09）的回归测试：phoneGate 接页面观察且按归属隔离、
/// 写请求弹窗核对发起时的页面许可、在途换号核对表单、页面重新有效时先查共享已绑状态。从 BindPhoneControllerTests 拆出（文件长度）。
@MainActor
final class BindPhoneReviewR1Tests: XCTestCase {
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

    /// 第 1 轮 R1-04：点提交后页面隐藏再回来（可见世代已变），原请求的 30411 mergeable 不弹并号框、不保留并号凭据；之后再出现也不补弹。
    func testStaleMergeableNotPresentedAfterVisibilityChanged() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .hold("bind") : okReply()
        }
        let fixture = try make()
        let controller = fixture.controller
        fill(controller, phone: "13800005678")
        controller.submit()
        await waitUntil { LoginStubProtocol.isHeld("bind") }
        controller.disappeared()
        controller.appeared()
        LoginStubProtocol.release(
            "bind", with: failReply(30411, data: "{\"reason\":\"mergeable\",\"merge_ticket\":\"ticket-old\"}")
        )
        await waitUntil { !controller.submitting }
        await settle()
        XCTAssertNil(controller.dialog, "失效请求的并号结果不弹")
        controller.disappeared()
        controller.appeared()
        XCTAssertNil(controller.dialog, "不补弹旧并号凭据")
    }

    /// 第 1 轮 R1-05：绑定在途改号——A 的 20003 不清 B 的验证码、不显示字段错误；A 的 30411 mergeable 不在 B 的表单上弹。
    func testInFlightPhoneChangeDropsStaleFieldErrorAndMerge() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .hold("bind-a") : okReply()
        }
        let fixture = try make()
        let controller = fixture.controller
        fill(controller, phone: "13800001234")
        controller.submit()
        await waitUntil { LoginStubProtocol.isHeld("bind-a") }
        controller.setPhone("13900005678")
        controller.setCode("654321")
        LoginStubProtocol.release("bind-a", with: failReply(20003))
        await waitUntil { !controller.submitting }
        XCTAssertEqual(controller.code, "654321", "旧号码的 20003 不清新验证码")
        XCTAssertNil(controller.codeError)

        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .hold("bind-b") : okReply()
        }
        controller.submit()
        await waitUntil { LoginStubProtocol.isHeld("bind-b") }
        controller.setPhone("13700001111")
        LoginStubProtocol.release(
            "bind-b", with: failReply(30411, data: "{\"reason\":\"mergeable\",\"merge_ticket\":\"ticket-b\"}")
        )
        await waitUntil { !controller.submitting }
        await settle()
        XCTAssertNil(controller.dialog, "换号后不弹旧号码的并号确认")
    }

    /// 第 1 轮 R1-03：42901 的 phoneGate 开始与结束都驱动页面（不靠短信计时器）；待确认的确认 / 放弃与【绑定】同一禁用状态。
    func testPhoneGateDrivesPageAndPendingButtons() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? failReply(42901, headers: ["Retry-After": "1"]) : okReply()
        }
        let fixture = try make()
        let controller = fixture.controller
        fill(controller)
        controller.submit()
        await waitUntil { !controller.submitting }
        XCTAssertTrue(controller.writeGated, "限流开始发布到页面")
        XCTAssertFalse(controller.canSubmit)
        await waitUntil { !controller.writeGated }
        XCTAssertTrue(controller.canSubmit, "限流到期【绑定】恢复可点")

        let calls = MutableBox(0)
        LoginStubProtocol.install { request in
            guard request.path == Paths.bindPhone else { return okReply() }
            calls.value += 1
            return .json(status: 502, headers: [:], body: "x")
        }
        controller.submit()
        await waitUntil { controller.pending != nil }
        let key = try XCTUnwrap(controller.pending?.key)
        XCTAssertTrue(controller.pendingActionsEnabled)
        fixture.harness.bind.startGate(controller.owner, millis: 30000)
        XCTAssertTrue(controller.writeGated)
        XCTAssertFalse(controller.pendingActionsEnabled, "确认 / 放弃按限流置灰")
        controller.confirmPending(key: key)
        controller.askAbandon(key: key)
        XCTAssertNil(controller.dialog, "限流中不弹放弃确认")
        await settle()
        XCTAssertEqual(calls.value, 1, "限流中不发确认")
    }

    /// 第 1 轮 R1-08：进页 getMe 在 inactive 期间返回已绑（当时没有许可）→ 回到 active 时先查共享已绑状态，只退出本实例、只恢复。
    func testBoundLearnedWhileInactiveHandledOnReturn() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.me ? .hold("me") : okReply()
        }
        let harness = OAuthHarness()
        try harness.seedSession()
        let log = BindHooksLog()
        let controller = harness.bindController(log)
        controller.appeared()
        await waitUntil { LoginStubProtocol.isHeld("me") }
        log.active = false
        controller.disappeared()
        LoginStubProtocol.release("me", with: okReply(meData(phoneBound: true)))
        await waitUntil { harness.phone.bound(generation: harness.client.sessionGeneration) == true }
        await settle()
        XCTAssertTrue(log.alreadyBound.isEmpty, "inactive 时不导航")
        log.active = true
        controller.appeared()
        XCTAssertEqual(log.alreadyBound.map(\.0), [controller.entryId], "回到前台补处理：只退出本实例")
        XCTAssertTrue(log.completed.isEmpty, "按只恢复，不算完成前置")
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.me).count, 1, "不重复首次查询")
    }

    /// 第 1 轮 R1-09：账号 A 的绑定限流（Retry-After 30）在换成账号 B 后不拦 B；旧归属的禁用期在同步出口清掉。
    func testPhoneGateIsolatedPerSession() async throws {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? failReply(42901, headers: ["Retry-After": "30"]) : okReply()
        }
        let fixture = try make()
        let harness = fixture.harness
        fill(fixture.controller)
        fixture.controller.submit()
        await waitUntil { !fixture.controller.submitting }
        XCTAssertTrue(harness.bind.writeGated(fixture.controller.owner))
        fixture.controller.invalidate()

        try harness.seedSession(account: "u2")
        LoginStubProtocol.install { _ in okReply() }
        let log = BindHooksLog()
        let next = harness.bindController(log)
        next.appeared()
        XCTAssertFalse(next.writeGated, "限流按固定归属隔离")
        fill(next)
        XCTAssertTrue(next.canSubmit, "B 不被 A 的截止时间拦")
        harness.bind.ownershipChanged()
        XCTAssertFalse(harness.bind.gate.blocked, "同步出口清掉旧会话的禁用期")
        next.submit()
        await waitUntil { !next.submitting }
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.bindPhone).count, 1, "B 的绑定发出")
    }
}

/// 让已排队的主线程任务跑完（没有可等的条件时用）。
@MainActor
private func settle() async {
    for _ in 0..<5 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
