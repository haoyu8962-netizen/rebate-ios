@testable import Couli
import CouliNetwork
import Foundation
import Login
import Router
import Session
import XCTest

/// FU-IOS-PHONE-BINDING-COLDSTART（D10-2675 / D10-2676 方案 B）：冷启动后 PhoneBindingStore 对当前 full 会话为「未知」，从「我的」页 / push
/// 打开 auth=realname 的 Withdraw 时守卫判 require_bind_phone → 推 BindPhone → 自查已绑出栈，Withdraw 不登记待办 → 用户无反馈。修复：会话
/// 就绪时（启动协调之前、会话状态同步之后）无待办也同步一次 phone_bound，每个会话世代最多一次，失败不重试、不记 phoneQueryFailed。
///
/// 用例名后缀 `Coldstart<n>` 对应任务书「测试」第 n 条；第 4、6 条（现状本来就不发）并进第 4 条的会红用例。
final class PhoneBindingColdStartSyncTests: PhoneBindingColdStartSyncTestCase {
    // MARK: - [COLDSTART#1] 冷启动同步 phone_bound:true → 「我的」页打开 Withdraw 进实名前置

    func testColdStartSyncThenInAppWithdrawGoesToRealNameColdstart1() async {
        let name = "[COLDSTART#1]"
        let fixture = coldStart(Self.boundTrue)
        await waitQueriesSettled(fixture, 1, "\(name) 冷启动没有恰好发起一次 phone_bound 同步")
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 回包 phone_bound:true 写回存储。\(describe(fixture))")
        XCTAssertEqual(meHttp, 1, "\(name) 恰好一次 GET /v1/me。\(describe(fixture))")
        XCTAssertEqual(fixture.routing.guardState.session, .phoneBound, "\(name) 守卫会话。\(describe(fixture))")

        let history = PhoneBindingColdStartRouteHistory(fixture.router)
        fixture.router.open(RouteRequest(route: "Withdraw", from: .inApp))
        await quietWindow(0.6)
        XCTAssertEqual(fixture.router.lastDecision?.kind, .requireRealname,
                       "\(name) 守卫结论是实名前置。\(describe(fixture, history))")
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.realName,
                       "\(name) 栈顶 RealName。\(describe(fixture, history))")
        XCTAssertFalse(history.seen.contains(RoutePolicy.bindPhone),
                       "\(name) 栈里从不出现 BindPhone。\(describe(fixture, history))")
        XCTAssertEqual(queries(fixture), 1, "\(name) 打开之后不再查。\(describe(fixture, history))")
        XCTAssertEqual(meHttp, 1, "\(name) 打开之后不再发 GET /v1/me。\(describe(fixture, history))")
    }

    // MARK: - [COLDSTART#2] 同上，push 来源打开 Withdraw

    /// Withdraw 的 routes.json entry 只有 in_app、push（没有 deeplink，深链一律 entry_not_allowed），这里走热推送：回查到 Withdraw。
    func testColdStartSyncThenPushWithdrawGoesToRealNameColdstart2() async {
        let name = "[COLDSTART#2]"
        let fixture = coldStart(Self.boundTrue)
        await waitQueriesSettled(fixture, 1, "\(name) 冷启动没有恰好发起一次 phone_bound 同步")
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 回包写回已绑。\(describe(fixture))")
        await waitUntil("\(name) 前提：强更检查没有结论") { updateSettled(fixture) }

        let history = PhoneBindingColdStartRouteHistory(fixture.router)
        let landing = PushLanding { _ in .found(route: "Withdraw", params: [:]) }
        let task = fixture.routing.handlePush(messageId: "m-withdraw", coldStart: false, using: landing)
        XCTAssertNotNil(task, "\(name) 前提：热推送进入回查。\(describe(fixture, history))")
        await task?.value
        await quietWindow(0.6)
        XCTAssertEqual(fixture.router.path.last?.route, RoutePolicy.realName,
                       "\(name) push 打开 Withdraw 进 RealName。\(describe(fixture, history))")
        XCTAssertFalse(history.seen.contains(RoutePolicy.bindPhone),
                       "\(name) 栈里从不出现 BindPhone。\(describe(fixture, history))")
        XCTAssertEqual(queries(fixture), 1, "\(name) 只同步一次。\(describe(fixture, history))")
        XCTAssertEqual(meHttp, 1, "\(name) 恰好一次 GET /v1/me。\(describe(fixture, history))")
    }

    // MARK: - [COLDSTART#3] phone_bound:false → 存储记 false → Withdraw 进 BindPhone 并留住

    func testColdStartSyncFalseKeepsBindPhoneColdstart3() async throws {
        let name = "[COLDSTART#3]"
        let fixture = coldStart(Self.boundFalse)
        await waitQueriesSettled(fixture, 1, "\(name) 冷启动没有恰好发起一次 phone_bound 同步")
        XCTAssertEqual(phoneBound(fixture), false, "\(name) 打开前存储已记 false。\(describe(fixture))")

        fixture.router.open(RouteRequest(route: "Withdraw", from: .inApp))
        XCTAssertEqual(fixture.router.lastDecision?.kind, .requireBindPhone, "\(name) 守卫结论。\(describe(fixture))")
        let top = try XCTUnwrap(fixture.router.path.last, "\(name) 栈为空。\(describe(fixture))")
        XCTAssertEqual(top.route, RoutePolicy.bindPhone, "\(name) 进 BindPhone。\(describe(fixture))")
        // 照 BindPhoneView.onAppear：进页自查（已知未绑 → 不查、不出栈）
        fixture.login.bindEntry(for: top).controller.appeared()
        await quietWindow()
        XCTAssertEqual(fixture.router.path.last?.id, top.id, "\(name) BindPhone 留在栈顶。\(describe(fixture))")
        XCTAssertEqual(phoneBound(fixture), false, "\(name) 存储仍为 false。\(describe(fixture))")
        XCTAssertEqual(meHttp, 1, "\(name) 自查不再发 GET /v1/me。\(describe(fixture))")
    }

    // MARK: - [COLDSTART#4]（并 #6）前提不满足不发；前提满足后同一世代只同步一次

    /// 隐私未同意（基本模式）：启动协调与会话同步都不发。
    /// 游客：不发；之后登录成 full（手机号未知）→ 会话同步时同步一次。
    /// deletion_only：不发；之后刷新成 full（onSessionStateChanged，不走启动协调）→ 同步一次。
    /// [COLDSTART#6] 42901 读取截止期内（与「我的」共用 MeGates.read，同 CouliApp 接线）：deletion_only 刷新成 full 时也不发。
    func testPreconditionsGateSyncThenSyncOnceWhenMetColdstart4() async throws {
        await assertBasicModeNeverSyncs()
        try await assertGuestThenLoginSyncsOnce()
        try await assertRestrictedThenFullSyncsOnce()
        try await assertReadGateBlocksSync()
    }

    private func assertBasicModeNeverSyncs() async {
        let name = "[COLDSTART#4·隐私未同意]"
        let fixture = coldStart(Self.boundTrue, decision: "basic_mode")
        fixture.routing.launchConditionsChanged()
        fixture.routing.sessionStateChanged(resumePending: false)
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 0, "\(name) 不发起同步。\(describe(fixture))")
        XCTAssertEqual(meHttp, 0, "\(name) 不发 GET /v1/me。\(describe(fixture))")
    }

    private func assertGuestThenLoginSyncsOnce() async throws {
        let name = "[COLDSTART#4·游客]"
        let fixture = coldStart(Self.boundTrue, account: nil)
        fixture.routing.launchConditionsChanged()
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 0, "\(name) 游客不发起同步。\(describe(fixture))")
        try signIn(fixture, as: "user-a")
        fixture.routing.sessionStateChanged(resumePending: true)
        await waitQueriesSettled(fixture, 1, "\(name) 登录成 full 后没有恰好同步一次")
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 新会话写回已绑。\(describe(fixture))")
        fixture.routing.launchConditionsChanged()
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 1, "\(name) 查清后不再查。\(describe(fixture))")
    }

    private func assertRestrictedThenFullSyncsOnce() async throws {
        let name = "[COLDSTART#4·deletion_only]"
        let fixture = coldStart(Self.boundTrue, scope: SessionScope.deletionOnly)
        fixture.routing.launchConditionsChanged()
        fixture.routing.sessionStateChanged(resumePending: false)
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 0, "\(name) 受限会话不发起同步。\(describe(fixture))")
        XCTAssertEqual(fixture.client.isolatedSessionScope, SessionScope.deletionOnly, "\(name) 前提：仍是受限会话")
        try fixture.tokens.save(access: "at-r", refresh: "rt-r", scope: SessionScope.full, account: "user-a")
        fixture.routing.sessionStateChanged(resumePending: false)
        await waitQueriesSettled(fixture, 1, "\(name) 刷新成 full 后会话同步没有恰好同步一次")
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 写回已绑。\(describe(fixture))")
    }

    private func assertReadGateBlocksSync() async throws {
        let name = "[COLDSTART#6·42901 读取截止期]"
        WalletStubProtocol.reset()
        script.install()
        let fixture = coldStart(Self.boundTrue, scope: SessionScope.deletionOnly)
        fixture.login.phoneSync.readGate = fixture.me.gates.read
        fixture.me.gates.read.start(60000)
        try fixture.tokens.save(access: "at-g", refresh: "rt-g", scope: SessionScope.full, account: "user-a")
        fixture.routing.sessionStateChanged(resumePending: false)
        fixture.routing.launchConditionsChanged()
        await quietWindow(0.6)
        XCTAssertEqual(meHttp, 0, "\(name) 截止期内不发 GET /v1/me。\(describe(fixture))")
        XCTAssertEqual(queries(fixture), 0, "\(name) 截止期内不发起查询。\(describe(fixture))")
        XCTAssertNil(phoneBound(fixture), "\(name) 仍未知。\(describe(fixture))")
    }

    // MARK: - [COLDSTART#5] 查询失败：同会话不再自动发；之后出现手机号级待办时 ensure 仍查一次

    /// 断连（GET 由 ApiClient 自动重发 1 次 HTTP，逻辑上是一次查询）：之后多次启动协调 / 会话同步都不再发。
    func testDisconnectFailureNotRetriedInSameSessionColdstart5() async {
        let name = "[COLDSTART#5·断连]"
        let fixture = coldStart(.disconnect)
        await waitQueriesSettled(fixture, 1, "\(name) 冷启动没有恰好发起一次 phone_bound 同步")
        await quietWindow(0.8)
        let http = meHttp
        XCTAssertGreaterThan(http, 0, "\(name) 前提：发过 GET /v1/me。\(describe(fixture))")
        XCTAssertNil(phoneBound(fixture), "\(name) 失败后仍未知。\(describe(fixture))")
        for _ in 0..<3 {
            fixture.routing.launchConditionsChanged()
        }
        fixture.routing.sessionStateChanged(resumePending: false)
        fixture.routing.sessionStateChanged(resumePending: false)
        fixture.routing.sessionStateChanged(resumePending: true)
        await quietWindow()
        XCTAssertEqual(queries(fixture), 1, "\(name) 同会话不再自动查（最多一次）。\(describe(fixture))")
        XCTAssertEqual(meHttp, http, "\(name) 不再发 GET /v1/me。\(describe(fixture))")
    }

    /// 50001：之后多次启动协调都不再发；随后出现手机号级待办（InviteShare）→ 下一次启动协调里 ensurePhoneBindingKnown 仍查一次
    /// （失败不记 phoneQueryFailed），查清已绑后按守卫恢复待办（原行为）。中间不做会话同步（它会清 phoneQueryFailed，掩盖错写）。
    func testServerFailureLeavesEnsureBehaviorColdstart5() async {
        let name = "[COLDSTART#5·50001]"
        let fixture = coldStart(Self.serverError)
        await waitQueriesSettled(fixture, 1, "\(name) 冷启动没有恰好发起一次 phone_bound 同步")
        XCTAssertEqual(meHttp, 1, "\(name) 恰好一次 GET /v1/me。\(describe(fixture))")
        XCTAssertNil(phoneBound(fixture), "\(name) 失败后仍未知。\(describe(fixture))")
        await waitUntil("\(name) 前提：强更检查没有结论") { updateSettled(fixture) }
        for _ in 0..<3 {
            fixture.routing.launchConditionsChanged()
        }
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 1, "\(name) 无待办时不再自动查。\(describe(fixture))")
        XCTAssertEqual(meHttp, 1, "\(name) 不再发 GET /v1/me。\(describe(fixture))")

        script.on("GET /v1/me", Self.boundTrue)
        savePendingRoute("InviteShare")
        fixture.routing.launchConditionsChanged()
        await waitQueriesSettled(fixture, 2, "\(name) 有手机号级待办时 ensurePhoneBindingKnown 没有再查一次")
        await waitUntil("\(name) 查清已绑后待办没有恢复。\(describe(fixture))") {
            fixture.router.path.last?.route == "InviteShare"
        }
        XCTAssertFalse(fixture.router.hasPendingAction, "\(name) 待办执行后删除。\(describe(fixture))")
        XCTAssertEqual(meHttp, 2, "\(name) 共两次 GET /v1/me。\(describe(fixture))")
    }

    // MARK: - [COLDSTART#7] 会话换代中途回包不写新会话；新世代可再同步一次

    func testSwitchAccountMidSyncDropsLateReplyColdstart7() async throws {
        let name = "[COLDSTART#7·换号]"
        let fixture = coldStart(.hold)
        await waitUntil("\(name) 冷启动同步没有发出并挂起。\(describe(fixture))") {
            queries(fixture) == 1 && heldMe.count == 1
        }
        let heldA = try XCTUnwrap(heldMe.first)
        let generationA = fixture.client.sessionGeneration

        try signIn(fixture, as: "user-b")
        fixture.routing.sessionStateChanged(resumePending: false)
        let generationB = fixture.client.sessionGeneration
        XCTAssertNotEqual(generationB, generationA, "\(name) 前提：会话世代推进")
        await waitUntil("\(name) 新世代没有再同步一次。\(describe(fixture))") {
            queries(fixture) == 2 && heldMe.count == 2
        }
        let heldB = try XCTUnwrap(heldMe.last)

        release(heldA, with: Self.boundTrue)
        await quietWindow(0.6)
        XCTAssertNil(fixture.login.phone.bound(generation: generationB), "\(name) 旧会话回包不写新会话。\(describe(fixture))")
        XCTAssertEqual(fixture.routing.guardState.session, .loggedIn, "\(name) 守卫仍按未绑。\(describe(fixture))")

        release(heldB, with: Self.boundFalse)
        await waitQueriesSettled(fixture, 2, "\(name) 新世代的同步没有结算")
        XCTAssertEqual(
            fixture.login.phone.bound(generation: generationB),
            false,
            "\(name) 新世代按自己的回包。\(describe(fixture))"
        )
        fixture.routing.launchConditionsChanged()
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 2, "\(name) 每个世代最多一次。\(describe(fixture))")
    }

    func testSignOutMidSyncThenRelogSyncsAgainColdstart7() async throws {
        let name = "[COLDSTART#7·登出再登录]"
        let fixture = coldStart(.hold)
        await waitUntil("\(name) 冷启动同步没有发出并挂起。\(describe(fixture))") {
            queries(fixture) == 1 && heldMe.count == 1
        }
        let heldA = try XCTUnwrap(heldMe.first)

        fixture.client.signOut()
        fixture.routing.sessionStateChanged(resumePending: false)
        let guestGeneration = fixture.client.sessionGeneration
        release(heldA, with: Self.boundTrue)
        await quietWindow(0.6)
        XCTAssertEqual(queries(fixture), 1, "\(name) 游客不再查。\(describe(fixture))")
        XCTAssertNil(fixture.login.phone.bound(generation: guestGeneration), "\(name) 迟到回包不写。\(describe(fixture))")
        XCTAssertEqual(fixture.routing.guardState.session, .guest, "\(name) 守卫按游客。\(describe(fixture))")

        try signIn(fixture, as: "user-a")
        fixture.routing.sessionStateChanged(resumePending: true)
        await waitQueriesSettled(fixture, 2, "\(name) 重新登录的新世代没有再同步一次")
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 新世代写回已绑。\(describe(fixture))")
    }

    // MARK: - [COLDSTART#8] 同步在途时出现手机号级待办 → 回包已绑后待办被恢复

    func testPendingArrivingDuringSyncResumesAfterBoundColdstart8() async throws {
        let name = "[COLDSTART#8]"
        let fixture = coldStart(.hold)
        await waitUntil("\(name) 冷启动同步没有发出并挂起。\(describe(fixture))") {
            queries(fixture) == 1 && heldMe.count == 1
        }
        let held = try XCTUnwrap(heldMe.first)
        await waitUntil("\(name) 前提：强更检查没有结论") { updateSettled(fixture) }

        savePendingRoute("InviteShare")
        fixture.routing.launchConditionsChanged()
        await settle()
        XCTAssertEqual(queries(fixture), 1, "\(name) 同步在途时 ensure 不另发。\(describe(fixture))")
        XCTAssertTrue(fixture.router.hasPendingAction, "\(name) 未知时待办保留。\(describe(fixture))")
        XCTAssertFalse(fixture.router.path.contains { $0.route == RoutePolicy.bindPhone },
                       "\(name) 不自动拉起绑手机页。\(describe(fixture))")
        XCTAssertNil(fixture.routing.scheduledLaunchRetryAt, "\(name) 前提：没有别的超时协调会代为恢复。\(describe(fixture))")

        release(held, with: Self.boundTrue)
        await waitUntil("\(name) 回包已绑后待办没有恢复（应由同步回包调 launchConditionsChanged）。\(describe(fixture))") {
            fixture.router.path.last?.route == "InviteShare"
        }
        XCTAssertFalse(fixture.router.hasPendingAction, "\(name) 待办执行后删除。\(describe(fixture))")
        XCTAssertEqual(phoneBound(fixture), true, "\(name) 写回已绑。\(describe(fixture))")
        XCTAssertEqual(queries(fixture), 1, "\(name) 全程一次查询。\(describe(fixture))")
    }
}
