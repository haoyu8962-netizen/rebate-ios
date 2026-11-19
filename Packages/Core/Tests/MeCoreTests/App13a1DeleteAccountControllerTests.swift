import ClientCore
import CouliNetwork
import Foundation
import Generated
@testable import MeCore
import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：注销页执行器 `DeleteAccountController`（真实 SensitiveFlow / StepUpController + 假 WalletApi 按
/// operationId 脚本回答、记下每个调用）。
///
/// 依据：三端任务书 APP-13a/brief.md
/// - §0 第 4 条「受限会话」：注销页只调 BR-ID-01 表内接口（getDeletion、requestDeletion、cancelDeletion、getMe、getWalletSummary、getConfig、
///   sendSmsCode(step_up + account_deletion)、stepUp(account_deletion)、abandonIdempotencyKey），【去提现】不显示（G12）；
/// - §0「身份固定」「等待后复核」：回调绑定渲染时的版本与固定身份（含作用域），换代后执行零请求；「出栈清理」：读请求在同步出口作废、写请求离页不取消；
/// - §0「trace6」：getDeletion 失败申请与撤回都不可用；
/// - §2 第 3 项（30416 / 30412 / 10007 的页面去向）、第 4 项（撤回去向、10007、42901、5xxxx、结果未知不自动重发）；
/// - 共性第 10、34、42 条（30416 本次金额、自动重读不替换、主动重试才更新资格）、第 14、33 条（撤回未知后核对，查明已撤回走同一成功结算）。
@MainActor
final class App13a1DeleteAccountControllerTests: App13a1ControllerTestCase {
    // MARK: - 受限会话只调表内接口

    /// deletion_only（从强更进入）：进页 → 勾选 → 申请 → 10003 → 面板发码 / 验证 → 原键重放成功 → 回强更页。全程只调受限会话表内接口，
    /// 发码与验证的 action 都是 account_deletion；不显示【去提现】，旧的【去提现】回调也不打开任何页。
    func testRestrictedSessionCallsOnlyTableOperations() async throws {
        let fixture = make(scope: DeletionScope.deletionOnly, source: .forceUpdate)
        fixture.api.on("requestDeletion", App13a1Replies.fail(10003), App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        XCTAssertFalse(fixture.controller.view.showGoWithdraw, "受限会话不显示【去提现】")
        fixture.controller.goWithdraw(
            version: fixture.controller.state.version,
            owner: fixture.controller.identity.owner
        )
        XCTAssertTrue(fixture.ports.opened.isEmpty, "受限会话的【去提现】回调不打开任何页")

        check(fixture)
        apply(fixture)
        try await fixture.passStepUp()
        await waitFor("申请没有成功") { fixture.ports.toForceUpdate == 1 }
        await fixture.idle()

        let allowed: Set = [
            "getDeletion", "requestDeletion", "cancelDeletion", "getMe", "getWalletSummary", "getConfig",
            "sendSmsCode", "stepUp", "abandonIdempotencyKey",
        ]
        let used = fixture.api.calls.map(\.operationId)
        XCTAssertFalse(used.isEmpty)
        for operationId in used {
            XCTAssertTrue(allowed.contains(operationId), "受限会话下发了表外接口 \(operationId)")
            let operation = try XCTUnwrap(ApiOperations.byId(operationId), operationId)
            XCTAssertTrue(operation.sessionScopes.contains("deletion_only"),
                          "\(operation.method) \(operation.pathTemplate) 不接受 deletion_only")
        }
        for sms in fixture.api.calls("sendSmsCode") {
            XCTAssertEqual(fixture.json(sms)["purpose"] as? String, "step_up")
            XCTAssertEqual(fixture.json(sms)["action"] as? String, "account_deletion")
        }
        for verify in fixture.api.calls("stepUp") {
            XCTAssertEqual(fixture.json(verify)["action"] as? String, "account_deletion")
        }
        let keys = fixture.api.calls("requestDeletion").map(\.idempotencyKey)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1, "10003 后沿用原键")
        XCTAssertEqual(fixture.controller.view.kind, .cooling, "成功后进冷静期态")
    }

    // MARK: - 读取失败

    /// getDeletion 5xxxx：整页错误（trace6），勾选、申请、撤回都不可用——不当成「从未申请」，冷静期用户不能再点一次申请。
    func testDeletionReadFailureDisablesApplyAndCancel() async {
        let fixture = make()
        fixture.api.on("getDeletion", App13a1Replies.fail(50001))
        await open(fixture)
        XCTAssertEqual(fixture.controller.view.kind, .loadFailed)
        XCTAssertEqual(fixture.controller.state.readError?.showTrace6, true, "5xxxx 附 trace6")

        check(fixture)
        XCTAssertFalse(fixture.controller.state.waiver, "读取失败：勾选不可用")
        apply(fixture)
        cancel(fixture)
        await fixture.idle()
        XCTAssertTrue(fixture.api.calls("requestDeletion").isEmpty, "读取失败：不发申请")
        XCTAssertTrue(fixture.api.calls("cancelDeletion").isEmpty, "读取失败：不发撤回")
        XCTAssertFalse(fixture.controller.applyEnabled)
    }

    /// getDeletion 坏数据（不认识的 status）：同读取失败。
    func testDeletionBadDataIsLoadFailure() async {
        let fixture = make()
        fixture.api.on("getDeletion", App13a1Replies.ok("{\"status\":\"archived\"}"))
        await open(fixture)
        XCTAssertEqual(fixture.controller.view.kind, .loadFailed)
        check(fixture)
        apply(fixture)
        await fixture.idle()
        XCTAssertTrue(fixture.api.calls("requestDeletion").isEmpty)
    }

    // MARK: - 30416

    /// 申请得到 30416(amount_fen=567)：负余额态取本次金额；之后自动重读钱包得到 negative_fen=200 也不替换 567、资格不变；
    /// 用户点【重试】（主动刷新）读到 negative_fen=0 后才恢复可申请（共性第 10、34、42 条）。
    func test30416AmountSurvivesAutomaticReloadAndExplicitRetryUpdatesEligibility() async {
        let fixture = make()
        fixture.api.on("requestDeletion", App13a1Replies.fail(30416, data: "{\"amount_fen\":567}"))
        await open(fixture)
        XCTAssertEqual(fixture.controller.view.kind, .initial)
        // 申请之后的自动重读：negative_fen = 200
        fixture.api.on("getWalletSummary", App13a1Replies.ok(App13a1Replies.summary(negative: 200)))

        check(fixture)
        apply(fixture)
        await waitFor("没有进入负余额态") { fixture.controller.view.kind == .negative }
        await fixture.idle()
        XCTAssertEqual(fixture.controller.view.negativeFen, 567, "提示金额取本次 30416 的 amount_fen")
        XCTAssertTrue(fixture.controller.view.negativeFromSubmit)
        XCTAssertGreaterThan(fixture.api.calls("getWalletSummary").count, 1, "30416 后重读了钱包")
        XCTAssertEqual(fixture.controller.view.negativeFen, 567, "自动重读的 negative_fen 不替换本次金额")
        XCTAssertFalse(fixture.controller.view.applyEnabledWhenChecked, "资格不因自动重读改变")
        XCTAssertTrue(fixture.controller.view.showContactService)

        // 用户主动【重试】：回正
        fixture.api.on("getWalletSummary", App13a1Replies.ok(App13a1Replies.summary(negative: 0)))
        fixture.controller.retry(version: fixture.controller.state.version, owner: fixture.controller.identity.owner)
        await waitFor("主动重试后没有恢复可申请") { fixture.controller.view.kind == .initial }
        XCTAssertTrue(fixture.controller.view.applyEnabledWhenChecked, "主动刷新后按新读取更新资格")
    }

    /// 30416 不带 amount_fen：负余额态，金额为空（页面用不带金额的兜底句），不拿 negative_fen 补。
    func test30416WithoutAmountUsesFallback() async {
        let fixture = make()
        fixture.api.on("requestDeletion", App13a1Replies.fail(30416, data: "{}"))
        await open(fixture)
        fixture.api.on("getWalletSummary", App13a1Replies.ok(App13a1Replies.summary(negative: 200)))
        check(fixture)
        apply(fixture)
        await waitFor("没有进入负余额态") { fixture.controller.view.kind == .negative }
        await fixture.idle()
        XCTAssertNil(fixture.controller.view.negativeFen, "缺金额走兜底句")
        XCTAssertTrue(fixture.controller.view.negativeFromSubmit)
    }

    // MARK: - 30412

    /// 30412（full、从设置进入）：错误条 + 【去提现】，勾选保留（G14）；【去提现】经 Router 打开 Withdraw。
    func test30412OffersWithdrawInFullSession() async {
        let fixture = make(scope: DeletionScope.full, source: .settings)
        fixture.api.on("requestDeletion", App13a1Replies.fail(30412))
        await open(fixture)
        check(fixture)
        apply(fixture)
        await waitFor("30412 没有落到页面") { fixture.controller.flow.state.error?.key == "error.30412" }
        await fixture.idle()
        XCTAssertTrue(fixture.controller.state.withdrawHint)
        XCTAssertTrue(fixture.controller.view.showGoWithdraw)
        XCTAssertTrue(fixture.controller.state.waiver, "30412：勾选保留（G14）")
        fixture.controller.goWithdraw(
            version: fixture.controller.state.version,
            owner: fixture.controller.identity.owner
        )
        XCTAssertEqual(fixture.ports.opened, [DeleteAccountController.withdrawRoute])
    }

    /// 30412（deletion_only）：只提示，不给【去提现】。
    func test30412NoWithdrawInRestrictedSession() async {
        let fixture = make(scope: DeletionScope.deletionOnly, source: .forceUpdate)
        fixture.api.on("requestDeletion", App13a1Replies.fail(30412))
        await open(fixture)
        check(fixture)
        apply(fixture)
        await waitFor("30412 没有落到页面") { fixture.controller.flow.state.error?.key == "error.30412" }
        await fixture.idle()
        XCTAssertFalse(fixture.controller.view.showGoWithdraw)
        fixture.controller.goWithdraw(
            version: fixture.controller.state.version,
            owner: fixture.controller.identity.owner
        )
        XCTAssertTrue(fixture.ports.opened.isEmpty)
    }

    // MARK: - 10007

    /// 申请得到 10007(stage=cooling)：停在本页、重取 getDeletion，落到冷静期态（G27）。
    func test10007OnApplyRefetchesProgressAndShowsCooling() async {
        let fixture = make()
        fixture.api.on("requestDeletion", App13a1Replies.fail(10007, data: "{\"stage\":\"cooling\"}"))
        await open(fixture)
        let readsBefore = fixture.api.calls("getDeletion").count
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        check(fixture)
        apply(fixture)
        await waitFor("10007 后没有落到冷静期") { fixture.controller.view.kind == .cooling }
        XCTAssertGreaterThan(fixture.api.calls("getDeletion").count, readsBefore, "10007 后重取进度")
        XCTAssertTrue(fixture.ports.opened.isEmpty, "不导航")
    }

    // MARK: - 成功

    /// 从设置进入的申请成功：切冷静期，不离页、不清会话（G19），通知强更标签重取。
    func testApplySuccessFromSettingsStaysOnPage() async {
        let fixture = make(source: .settings)
        fixture.api.on("requestDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        check(fixture)
        apply(fixture)
        await waitFor("没有进入冷静期") { fixture.controller.view.kind == .cooling }
        await fixture.idle()
        XCTAssertEqual(fixture.ports.toForceUpdate, 0)
        XCTAssertEqual(fixture.ports.toSettings, 0)
        XCTAssertGreaterThanOrEqual(fixture.ports.changed, 1, "进度变了：通知强更标签")
        XCTAssertFalse(fixture.controller.state.waiver, "成功后勾选清空")
    }

    /// 未绑手机：点【申请注销】只提示 BR-ID-08 原句，不发请求（G10）。
    func testNoPhoneShowsHintWithoutRequest() async {
        let fixture = make(phoneBound: false)
        fixture.api.on("getMe", App13a1Replies.ok("{\"phone_bound\":false}"))
        await open(fixture)
        check(fixture)
        apply(fixture)
        await fixture.idle()
        XCTAssertTrue(fixture.api.calls("requestDeletion").isEmpty)
        XCTAssertEqual(fixture.controller.state.notice?.key, DeleteAccountController.noPhoneKey)
    }

    // MARK: - 身份固定

    /// 受限 → full 后执行旧回调（勾选、申请、撤回、重试、去提现）：零请求、页面数据不变（作用域属于固定身份）。
    func testOldCallbacksAfterScopeChangeSendNothing() async {
        let fixture = make(scope: DeletionScope.deletionOnly, source: .forceUpdate)
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        let version = fixture.controller.state.version
        let owner = fixture.controller.identity.owner
        let before = fixture.api.calls.count

        fixture.ports.scope = DeletionScope.full
        fixture.controller.toggleWaiver(version: version, owner: owner)
        fixture.controller.apply(version: version, owner: owner)
        fixture.controller.cancelDeletion(version: version, owner: owner)
        fixture.controller.retry(version: version, owner: owner)
        fixture.controller.goWithdraw(version: version, owner: owner)
        await fixture.idle()
        XCTAssertEqual(fixture.api.calls.count, before, "作用域已变：旧回调零请求")
        XCTAssertFalse(fixture.controller.state.waiver)
        XCTAssertFalse(fixture.controller.state.cancelling)
        XCTAssertTrue(fixture.ports.opened.isEmpty)
    }

    /// 会话换代（换账号）后执行旧回调：零请求。
    func testOldCallbacksAfterSessionChangeSendNothing() async {
        let fixture = make()
        await open(fixture)
        let version = fixture.controller.state.version
        let owner = fixture.controller.identity.owner
        fixture.controller.toggleWaiver(version: version, owner: owner)
        let checkedVersion = fixture.controller.state.version
        let before = fixture.api.calls.count

        fixture.env.current = false
        fixture.controller.apply(version: checkedVersion, owner: owner)
        fixture.controller.retry(version: checkedVersion, owner: owner)
        await fixture.idle()
        XCTAssertEqual(fixture.api.calls.count, before, "会话已换：旧回调零请求")
    }

    // MARK: - 离页

    /// 进度读取在途时离页：迟到结果不改页面（读请求在同步出口作废）。
    func testLeaveDropsLateRead() async {
        let fixture = make()
        fixture.api.hold("getDeletion")
        fixture.controller.start()
        await waitFor("进度读取没有发出") { fixture.api.heldCount("getDeletion") == 1 }
        fixture.controller.leave()
        let snapshot = fixture.controller.state
        fixture.api.release("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await fixture.idle()
        XCTAssertEqual(fixture.controller.state, snapshot, "离页后迟到的读取不改页面")
        XCTAssertNil(fixture.controller.state.read)
    }

    /// 撤回在途时离页：写请求不取消（照常发出、照常结算强更标签），迟到结果不改已离开的页面。
    func testLeaveDuringCancelKeepsWriteButNotPage() async {
        let fixture = make()
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        fixture.api.hold("cancelDeletion")
        cancel(fixture)
        await waitFor("撤回没有发出") { fixture.api.heldCount("cancelDeletion") == 1 }
        fixture.controller.leave()
        let snapshot = fixture.controller.state
        fixture.api.release("cancelDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        await fixture.idle()
        XCTAssertEqual(fixture.controller.state, snapshot, "离页后撤回结果不改页面")
        XCTAssertEqual(fixture.ports.toSettings, 0, "离页后不再导航")
        XCTAssertGreaterThanOrEqual(fixture.ports.changed, 1, "写请求照常结算：强更标签重取")
    }
}
