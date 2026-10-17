import CouliNetwork
import Foundation
@testable import Login
import Router
import Session
import XCTest

/// FU-IOS-0712 第 0 项（F-IOS-12，APP-05b 定向复核 RC-01）：exitNow 统一核对 visibleNow（存活、可见、栈顶、前台）。
/// appeared 在 inactive / 非栈顶时被调用不退出、延后记录与原退出方式保留；恢复后按原方式退出一次。recheckBound 同口径。
@MainActor
final class FollowupIos0712BindExitTests: XCTestCase {
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

    /// 隐藏期间提交绑定并放行成功（成功先到，延后记录 prerequisiteDone）。
    private func bindWhileHidden(_ fixture: BindFixture, hold: String) async {
        LoginStubProtocol.install { request in
            request.path == Paths.bindPhone ? .hold(hold) : okReply()
        }
        let controller = fixture.controller
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        await waitUntil { LoginStubProtocol.isHeld(hold) }
        fixture.log.active = false
        controller.disappeared()
        LoginStubProtocol.release(hold, with: okReply())
        await waitUntil { !controller.submitting }
        let harness = fixture.harness
        await waitUntil { harness.phone.bound(generation: harness.client.sessionGeneration) == true }
        XCTAssertNotNil(controller.deferredExit, "隐藏时成功到达：记下延后")
    }

    /// inactive（scenePhase 还没回到 active）时 appeared 被调用：不退出、延后记录保留原方式（完成前置）；回到前台后退出一次。
    func testInactiveAppearedKeepsDeferredExitAndRestoreExitsOnceWithOriginalKind() async throws {
        let fixture = try make()
        await bindWhileHidden(fixture, hold: "fios12-inactive")
        let controller = fixture.controller
        controller.appeared()
        XCTAssertTrue(fixture.log.completed.isEmpty, "inactive 时 appeared 不退出")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "recheckBound 也不按只恢复退出")
        XCTAssertEqual(controller.deferredExit?.kind, .prerequisiteDone, "延后记录与原退出方式保留")
        XCTAssertFalse(controller.exited)

        fixture.log.active = true
        controller.appeared()
        XCTAssertEqual(fixture.log.completed.map(\.0), [controller.entryId], "恢复后按完成前置退出一次")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty)
        XCTAssertNil(controller.deferredExit)
        controller.appeared()
        XCTAssertEqual(fixture.log.completed.count, 1, "不重复退出")
    }

    /// 非栈顶时 appeared（页面上面还盖着别的页，前台）：不退出；回到栈顶后按原方式退出一次。
    func testNotTopAppearedKeepsDeferredExitUntilTop() async throws {
        let fixture = try make()
        await bindWhileHidden(fixture, hold: "fios12-not-top")
        let controller = fixture.controller
        fixture.log.active = true
        fixture.log.top = false
        controller.appeared()
        XCTAssertTrue(fixture.log.completed.isEmpty, "非栈顶不退出")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty)
        XCTAssertEqual(controller.deferredExit?.kind, .prerequisiteDone)

        controller.disappeared()
        fixture.log.top = true
        controller.appeared()
        XCTAssertEqual(fixture.log.completed.map(\.0), [controller.entryId], "回到栈顶退出一次")
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "仍是完成前置，不是只恢复")
    }

    /// recheckBound 旁路：共享状态已绑（别处查明 / 绑定），页面在 inactive / 非栈顶时 appeared → 不退出、不再发 getMe，记下只恢复；
    /// 恢复后只恢复退出一次。
    func testRecheckBoundWithoutPermissionDefersResumeOnly() throws {
        for blocker in ["inactive", "not-top"] {
            LoginStubProtocol.install { _ in okReply() }
            let fixture = try make()
            let controller = fixture.controller
            let harness = fixture.harness
            fixture.log.active = false
            controller.disappeared()
            harness.phone.record(true, generation: harness.client.sessionGeneration)
            if blocker == "inactive" {
                fixture.log.active = false
            } else {
                fixture.log.active = true
                fixture.log.top = false
            }
            controller.appeared()
            XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "\(blocker)：没有许可不退出")
            XCTAssertEqual(controller.deferredExit?.kind, .resumeOnly, "\(blocker)：记下只恢复")
            XCTAssertEqual(LoginStubProtocol.requests(path: Paths.me).count, 0, "\(blocker)：共享已绑不再查询")

            controller.disappeared()
            fixture.log.active = true
            fixture.log.top = true
            controller.appeared()
            XCTAssertEqual(fixture.log.alreadyBound.map(\.0), [controller.entryId], "\(blocker)：恢复后只恢复退出一次")
            XCTAssertTrue(fixture.log.completed.isEmpty, "\(blocker)：不算完成前置")
            controller.appeared()
            XCTAssertEqual(fixture.log.alreadyBound.count, 1, "\(blocker)：不重复")
        }
    }

    /// 进页查询在隐藏期间查明已绑（延后只恢复）→ inactive 时 appeared 不退出 → 回到前台退出一次。
    func testQueryBoundWhileHiddenThenInactiveAppearedDoesNotExit() async throws {
        let hold = "fios12-me"
        LoginStubProtocol.install { request in
            request.path == Paths.me ? .hold(hold) : okReply()
        }
        let fixture = try make(phoneKnown: false)
        let controller = fixture.controller
        let harness = fixture.harness
        await waitUntil { LoginStubProtocol.isHeld(hold) }
        fixture.log.active = false
        controller.disappeared()
        LoginStubProtocol.release(hold, with: okReply(meData(phoneBound: true)))
        await waitUntil { harness.phone.bound(generation: harness.client.sessionGeneration) == true }
        await waitUntil { controller.deferredExit != nil }
        controller.appeared()
        XCTAssertTrue(fixture.log.alreadyBound.isEmpty, "inactive 时不退出")
        XCTAssertEqual(controller.deferredExit?.kind, .resumeOnly)

        fixture.log.active = true
        controller.appeared()
        XCTAssertEqual(fixture.log.alreadyBound.map(\.0), [controller.entryId])
        XCTAssertTrue(fixture.log.completed.isEmpty)
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.me).count, 1, "不重复查询")
    }

    // MARK: - 编排追加（鸿蒙 FU-HM-0722 R3-02 同类，APP-13a 共性 49）

    /// 绑定提交 / 发码在途 → 同账号、同登录世代、同会话世代把作用域刷新成 deletion_only → 旧请求迟到 42901：网络结算照常（请求只发一次、
    /// 回调到达），但限流不写进新作用域的闸门——写入前按发起时完整身份（账号 + 登录世代 + 作废世代 + 作用域）复核。
    func testLate42901AfterSameSessionScopeChangeDoesNotGateTheNewScope() async throws {
        let fixture = try make()
        let harness = fixture.harness
        let controller = fixture.controller
        let fullOwner = harness.bind.identity()
        LoginStubProtocol.install { request in
            switch request.path {
            case Paths.bindPhone: .hold("scope-bind")
            case Paths.sms: .hold("scope-sms")
            default: okReply()
            }
        }
        controller.setPhone("13800138000")
        controller.setCode("123456")
        controller.submit()
        var smsResult: BindSmsResult?
        harness.bind.sendCode(fullOwner, phone: "13800138001") { smsResult = $0 }
        await waitUntil { LoginStubProtocol.isHeld("scope-bind") && LoginStubProtocol.isHeld("scope-sms") }

        // 同一次登录、同一会话世代里作用域变了（刷新得 deletion_only）
        let generation = harness.client.sessionGeneration
        let epoch = try XCTUnwrap(harness.tokens.loginEpoch)
        try harness.tokens.save(
            access: "at-0", refresh: "rt-0", scope: Session.SessionScope.deletionOnly, account: "u1", loginEpoch: epoch
        )
        let restricted = harness.bind.identity()
        XCTAssertEqual(harness.client.sessionGeneration, generation, "前提：会话世代没变")
        XCTAssertEqual(restricted.request, fullOwner.request, "前提：请求归属（账号 + 世代）相同")
        XCTAssertNotEqual(restricted, fullOwner, "前提：作用域变了")

        let limited = failReply(42901, headers: ["Retry-After": "60"])
        LoginStubProtocol.release("scope-bind", with: limited)
        LoginStubProtocol.release("scope-sms", with: limited)
        await waitUntil { !controller.submitting && smsResult != nil }
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.bindPhone).count, 1, "已发请求只发一次")
        XCTAssertEqual(LoginStubProtocol.requests(path: Paths.sms).count, 1)
        XCTAssertEqual(smsResult, .silent, "旧身份的发码结果不交给页面")
        XCTAssertFalse(harness.bind.gate.active, "旧作用域的 42901 不写 phoneGate")
        XCTAssertFalse(harness.bind.writeGated(restricted), "新作用域不被限流")
        XCTAssertFalse(harness.bind.smsRateLimited(restricted, phone: "13800138001", now: harness.clock.value),
                       "新作用域的发码不被旧响应限流")
    }

    // MARK: - 第 4 项（F-X-09）：绑手机写请求的非强更 10405

    /// refresh_only 的 10405：首次提交按统一错误 + trace6（可再提交）；确认 / 放弃保留待确认「稍后再试」+ trace6；force_update 照旧静默
    /// （网络层已进强更分流）。
    func testNonForced10405OnBindWritesShowsUnifiedErrorAndForcedStaysSilent() {
        func result(_ kind: ErrorEffectKind) -> ApiResult {
            .failure(code: 10405, msg: "", data: Data("{}".utf8), traceId: "trace-0000-a1b2c3",
                     effect: ErrorEffect(code: 10405, kind: kind), idempotencyKey: "k")
        }
        XCTAssertEqual(
            BindOutcomes.map(result(.refreshOnly), phase: .submit, gated: false).0,
            .notice(textKey: "error.50001", trace6: "a1b2c3")
        )
        for phase in [BindOutcomes.Phase.confirm, .abandon] {
            XCTAssertEqual(
                BindOutcomes.map(result(.refreshOnly), phase: phase, gated: false).0,
                .pending(noticeKey: SensitiveTexts.retryLater, trace6: "a1b2c3")
            )
        }
        for phase in [BindOutcomes.Phase.submit, .confirm, .abandon] {
            XCTAssertEqual(BindOutcomes.map(result(.forceUpdate), phase: phase, gated: false).0, .silent)
        }
    }
}
