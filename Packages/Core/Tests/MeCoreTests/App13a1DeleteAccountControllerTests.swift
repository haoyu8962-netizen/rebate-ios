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
final class App13a1DeleteAccountControllerTests: XCTestCase {
    private var fixtures: [App13a1ControllerFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures {
            fixture.closePanel()
            fixture.controller.leave()
        }
        fixtures = []
        try await super.tearDown()
    }

    private func make(scope: String = DeletionScope.full, source: DeletionSource = .settings,
                      phoneBound: Bool? = true) -> App13a1ControllerFixture {
        let fixture = App13a1ControllerFixture(scope: scope, source: source, phoneBound: phoneBound)
        fixtures.append(fixture)
        return fixture
    }

    /// 进页并等进度与资金都读到。
    private func open(_ fixture: App13a1ControllerFixture) async {
        fixture.controller.start()
        await waitFor("进度与资金没有读到") {
            let state = fixture.controller.state
            return (state.read != nil || state.readFailed) && (state.funds != nil || state.fundsFailed)
        }
        await fixture.idle()
    }

    private func check(_ fixture: App13a1ControllerFixture) {
        let controller = fixture.controller
        controller.toggleWaiver(version: controller.state.version, owner: controller.identity.owner)
    }

    private func apply(_ fixture: App13a1ControllerFixture) {
        let controller = fixture.controller
        controller.apply(version: controller.state.version, owner: controller.identity.owner)
    }

    private func cancel(_ fixture: App13a1ControllerFixture) {
        let controller = fixture.controller
        controller.cancelDeletion(version: controller.state.version, owner: controller.identity.owner)
    }

    // MARK: - 受限会话只调表内接口

    /// deletion_only（从强更进入）：进页 → 勾选 → 申请 → 10003 → 面板发码 / 验证 → 原键重放成功 → 回强更页。全程只调受限会话表内接口，
    /// 发码与验证的 action 都是 account_deletion；不显示【去提现】，旧的【去提现】回调也不打开任何页。
    func testRestrictedSessionCallsOnlyTableOperations() async throws {
        let fixture = make(scope: DeletionScope.deletionOnly, source: .forceUpdate)
        fixture.api.on("requestDeletion", App13a1Replies.fail(10003), App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        XCTAssertFalse(fixture.controller.view.showGoWithdraw, "受限会话不显示【去提现】")
        fixture.controller.goWithdraw(version: fixture.controller.state.version, owner: fixture.controller.identity.owner)
        XCTAssertTrue(fixture.ports.opened.isEmpty, "受限会话的【去提现】回调不打开任何页")

        check(fixture)
        apply(fixture)
        try await fixture.passStepUp()
        await waitFor("申请没有成功") { fixture.ports.toForceUpdate == 1 }
        await fixture.idle()

        let allowed: Set<String> = [
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
        fixture.controller.goWithdraw(version: fixture.controller.state.version, owner: fixture.controller.identity.owner)
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
        fixture.controller.goWithdraw(version: fixture.controller.state.version, owner: fixture.controller.identity.owner)
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

    // MARK: - 撤回注销

    private func coolingPage(source: DeletionSource) async -> App13a1ControllerFixture {
        let fixture = make(source: source)
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        XCTAssertTrue(fixture.controller.view.showCancel, "前提：冷静期可撤回")
        return fixture
    }

    /// 从设置进入：撤回成功 → 出栈回 Settings 的唯一导航实例（轻提示在设置页）。
    func testCancelFromSettingsReturnsToSettings() async {
        let fixture = await coolingPage(source: .settings)
        fixture.api.on("cancelDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        cancel(fixture)
        await waitFor("没有回到设置") { fixture.ports.toSettings == 1 }
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1)
        XCTAssertNil(fixture.controller.state.toast, "已出栈回设置：轻提示在设置页，不在本页")
    }

    /// 从设置进入但下面不是 Settings（没能出栈）：本页给同一轻提示。
    func testCancelFromSettingsWithoutSettingsBelowToastsHere() async {
        let fixture = await coolingPage(source: .settings)
        fixture.ports.settingsResult = false
        fixture.api.on("cancelDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        cancel(fixture)
        await waitFor("没有轻提示") { fixture.controller.state.toast != nil }
        XCTAssertEqual(fixture.controller.state.toast?.key, DeletionCancelOutcome.withdrawnKey)
    }

    /// 从强更进入：撤回成功 → 回强更页。
    func testCancelFromForceUpdateReturnsToForceUpdate() async {
        let fixture = await coolingPage(source: .forceUpdate)
        fixture.api.on("cancelDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        cancel(fixture)
        await waitFor("没有回强更页") { fixture.ports.toForceUpdate == 1 }
    }

    /// 其他来源：撤回成功 → 本页切初始态并轻提示。
    func testCancelFromOtherSourceToastsAndShowsInitial() async {
        let fixture = await coolingPage(source: .other)
        fixture.api.on("cancelDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        cancel(fixture)
        await waitFor("没有轻提示") { fixture.controller.state.toast != nil }
        await fixture.idle()
        XCTAssertEqual(fixture.controller.state.toast?.key, DeletionCancelOutcome.withdrawnKey)
        XCTAssertEqual(fixture.controller.view.kind, .initial)
        XCTAssertEqual(fixture.ports.toSettings + fixture.ports.toForceUpdate, 0)
    }

    /// 撤回得到 10007：停在冷静期页，提示撤回已不可用，重取进度。
    func testCancel10007StaysAndRefetches() async {
        let fixture = await coolingPage(source: .settings)
        let readsBefore = fixture.api.calls("getDeletion").count
        fixture.api.on("cancelDeletion", App13a1Replies.fail(10007, data: "{\"stage\":\"cooling\"}"))
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(false)))
        cancel(fixture)
        await waitFor("10007 后没有重取进度") { fixture.api.calls("getDeletion").count > readsBefore }
        await fixture.idle()
        XCTAssertEqual(fixture.controller.view.kind, .cooling)
        XCTAssertNotNil(fixture.controller.state.notice)
        XCTAssertNotEqual(fixture.controller.state.notice?.key, DeletionCancelOutcome.withdrawnKey)
        XCTAssertEqual(fixture.ports.toSettings, 0)
    }

    /// 撤回得到 42901：按 Retry-After 禁用撤回；禁用期内再点不发。
    func testCancel42901DisablesCancel() async {
        let fixture = await coolingPage(source: .settings)
        fixture.api.on("cancelDeletion", App13a1Replies.fail(42901, disable: 60_000))
        cancel(fixture)
        await waitFor("42901 没有结算") { fixture.controller.cancelGate.active }
        await fixture.idle()
        cancel(fixture)
        await fixture.idle()
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1, "禁用期内再点不发")
    }

    /// 撤回得到 5xxxx：统一错误 + trace6，停在本页。
    func testCancel5xxxxShowsTrace6() async {
        let fixture = await coolingPage(source: .settings)
        fixture.api.on("cancelDeletion", App13a1Replies.fail(50401))
        cancel(fixture)
        await waitFor("5xxxx 没有落到页面") { fixture.controller.state.notice != nil }
        XCTAssertEqual(fixture.controller.state.notice?.showTrace6, true)
        XCTAssertEqual(fixture.ports.toSettings, 0)
        XCTAssertEqual(fixture.controller.view.kind, .cooling)
    }

    /// 撤回无响应、核对读取查明已撤回（user）：走同一套撤回成功结算（回 Settings）；不自动重发撤回（共性第 14 条）。
    func testCancelUnknownReconciledAsCancelledUsesSameSuccess() async {
        let fixture = await coolingPage(source: .settings)
        fixture.api.on("cancelDeletion", App13a1Replies.transport)
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        cancel(fixture)
        await waitFor("核对后没有按撤回成功结算") { fixture.ports.toSettings == 1 }
        await fixture.idle()
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1, "结果未知不自动重发")
    }

    /// 撤回无响应、核对读取仍在冷静期：只留人工重试（撤回按钮仍在），不自动重发；用户再点才发第二次。
    func testCancelUnknownStillCoolingKeepsManualRetryOnly() async {
        let fixture = await coolingPage(source: .settings)
        fixture.api.on("cancelDeletion", App13a1Replies.transport, App13a1Replies.ok(App13a1Replies.cancelled))
        cancel(fixture)
        await waitFor("没有核对读取") { fixture.api.calls("getDeletion").count >= 2 }
        await fixture.idle()
        await quiet()
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1, "仍在冷静期：不自动重发")
        XCTAssertEqual(fixture.controller.view.kind, .cooling)
        XCTAssertTrue(fixture.controller.view.showCancel, "保留人工重试")
        XCTAssertNotNil(fixture.controller.state.notice, "提示暂时没有收到结果")
        XCTAssertEqual(fixture.ports.toSettings, 0)

        cancel(fixture)
        await waitFor("人工重试没有发出") { fixture.api.calls("cancelDeletion").count == 2 }
    }

    /// 撤回无响应、核对读取失败：按统一读取失败处理（错误 + 重试）；保留核对上下文，【重试】查明已撤回后走撤回成功结算（共性第 33 条）。
    func testCancelUnknownReconcileReadFailureThenRetrySucceeds() async {
        let fixture = await coolingPage(source: .settings)
        fixture.api.on("cancelDeletion", App13a1Replies.transport)
        fixture.api.on("getDeletion", App13a1Replies.fail(50001))
        cancel(fixture)
        await waitFor("核对读取失败没有落到页面") { fixture.controller.state.readFailed }
        await fixture.idle()
        XCTAssertEqual(fixture.controller.view.kind, .loadFailed, "核对读取失败不静默吞掉")
        XCTAssertEqual(fixture.ports.toSettings, 0)

        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        fixture.controller.retry(version: fixture.controller.state.version, owner: fixture.controller.identity.owner)
        await waitFor("重试查明已撤回后没有走成功结算") { fixture.ports.toSettings == 1 }
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1, "核对不重发撤回")
    }

    // MARK: - 工具

    private func waitFor(_ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath,
                         line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail(message, file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 观察窗：「不该发生」的断言等满再判。
    private func quiet(_ seconds: TimeInterval = 0.5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - 夹具

/// 回答样例（契约 Deletion / 钱包摘要形状；金额是测试值）。
enum App13a1Replies {
    static func cooling(_ canCancel: Bool) -> String {
        "{\"status\":\"cooling\",\"apply_at\":\"2026-10-02T09:30:00+08:00\",\"cooling_until\":\"2026-10-09T09:30:00+08:00\","
            + "\"can_cancel\":\(canCancel),\"cancelled_at\":null,\"cancel_reason\":null,\"processed_at\":null}"
    }

    static let cancelled = "{\"status\":\"cancelled\",\"apply_at\":\"2026-10-02T09:30:00+08:00\","
        + "\"cooling_until\":\"2026-10-09T09:30:00+08:00\",\"can_cancel\":false,"
        + "\"cancelled_at\":\"2026-10-03T10:00:00+08:00\",\"cancel_reason\":\"user\",\"processed_at\":null}"

    static func summary(negative: Int64) -> String {
        "{\"available_fen\":1000,\"withdrawable_fen\":1000,\"negative_fen\":\(negative),\"frozen_fen\":0,"
            + "\"estimated_total_fen\":1019,\"estimated_fen\":269,\"pending_credit_fen\":750,"
            + "\"pending_credit_paused_fen\":0,\"next_credit_period\":\"2026-11\",\"credit_overdue\":false,"
            + "\"withdrawn_fen\":0,\"risk_paused_reason\":null,\"withdraw_enabled\":true}"
    }

    static let stepUpToken = "controller-step-up-token"

    static func ok(_ json: String) -> ApiResult {
        .success(data: Data(json.utf8), traceId: "trace-0123456789ab", idempotencyKey: nil)
    }

    static func fail(_ code: Int, data: String? = nil, disable: Int64? = nil) -> ApiResult {
        let kind: ErrorEffectKind = code == 10003 ? .stepUp : .genericError
        return .failure(
            code: code, msg: "", data: data.map { Data($0.utf8) }, traceId: "trace-0123456789ab",
            effect: ErrorEffect(code: code, kind: kind, disableMillis: disable), idempotencyKey: nil
        )
    }

    static let transport = ApiResult.transportFailure(
        kind: "timeout", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
    )
}

/// 假 WalletApi：按 operationId 排队回答（用完重复最后一个），可挂起某个 operation 直到 `release`。记下每个调用。
final class App13a1FakeApi: WalletApi, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ApiCall] = []
    private var replies: [String: [ApiResult]] = [:]
    private var holding: Set<String> = []
    private var waiting: [String: [CheckedContinuation<ApiResult, Never>]] = [:]

    var calls: [ApiCall] {
        lock.withLock { recorded }
    }

    func calls(_ operationId: String) -> [ApiCall] {
        calls.filter { $0.operationId == operationId }
    }

    func on(_ operationId: String, _ results: ApiResult...) {
        lock.withLock { replies[operationId] = results }
    }

    func hold(_ operationId: String) {
        lock.withLock { _ = holding.insert(operationId) }
    }

    func heldCount(_ operationId: String) -> Int {
        lock.withLock { waiting[operationId]?.count ?? 0 }
    }

    func release(_ operationId: String, _ result: ApiResult) {
        let continuations: [CheckedContinuation<ApiResult, Never>] = lock.withLock {
            holding.remove(operationId)
            return waiting.removeValue(forKey: operationId) ?? []
        }
        continuations.forEach { $0.resume(returning: result) }
    }

    private func reply(_ operationId: String) -> ApiResult {
        if var queue = replies[operationId], !queue.isEmpty {
            let first = queue.removeFirst()
            replies[operationId] = queue.isEmpty ? [first] : queue
            return first
        }
        switch operationId {
        case "getDeletion": return App13a1Replies.ok("null")
        case "getWalletSummary": return App13a1Replies.ok(App13a1Replies.summary(negative: 0))
        case "getMe": return App13a1Replies.ok("{\"user_id\":\"user-a\",\"phone_bound\":true}")
        case "sendSmsCode": return App13a1Replies.ok("{\"resend_after_sec\":60,\"expires_in_sec\":300}")
        case "stepUp":
            return App13a1Replies.ok(
                "{\"step_up_token\":\"\(App13a1Replies.stepUpToken)\",\"expire_at\":\"2099-01-01T00:05:00+08:00\"}"
            )
        case "requestDeletion": return App13a1Replies.ok(App13a1Replies.cooling(true))
        case "cancelDeletion": return App13a1Replies.ok(App13a1Replies.cancelled)
        default: return App13a1Replies.ok("{}")
        }
    }

    func send(
        _ call: ApiCall, isValid _: @escaping @Sendable () -> Bool, sendAllowed _: @escaping @Sendable () -> Bool,
        expected _: RequestOwnership?
    ) async -> ApiResult {
        let (held, result): (Bool, ApiResult?) = lock.withLock {
            recorded.append(call)
            if holding.contains(call.operationId) {
                return (true, nil)
            }
            return (false, reply(call.operationId))
        }
        if held {
            return await withCheckedContinuation { continuation in
                lock.withLock { waiting[call.operationId, default: []].append(continuation) }
            }
        }
        return result ?? App13a1Replies.ok("{}")
    }

    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult {
        lock.withLock {
            recorded.append(ApiCall(operationId: operationId, idempotencyKey: target.key, stepUpToken: stepUpToken))
            return reply(operationId)
        }
    }

    func abandonPending(operationId _: String, target _: PendingTarget) async -> ApiResult {
        lock.withLock {
            recorded.append(ApiCall(operationId: "abandonIdempotencyKey"))
            return .abandoned(idempotencyKey: "abandoned")
        }
    }

    func pendingStatus(operationId _: String) async -> PendingLookup {
        .none
    }

    func restorePending() async {}
}

/// 可控身份的钱包环境：`current = false` 模拟会话已换代。
@MainActor
final class App13a1ControllerEnv: WalletEnv {
    let owner = WalletOwner(
        account: "user-a", key: "user-a#1#0#0", request: RequestOwnership(account: "user-a", generation: 1, epoch: 0),
        loginEpoch: "login-a"
    )
    var current = true
    var bound: Bool?
    var now: Int64 = 1_790_904_600_000

    func currentOwner() -> WalletOwner {
        owner
    }

    func isCurrent(_ owner: WalletOwner) -> Bool {
        current && owner == self.owner
    }

    func configText(_: String) -> String? {
        nil
    }

    func helpLinks() -> [String: Any]? {
        nil
    }

    func earningsFlag() -> Bool? {
        nil
    }

    var appVersion: String {
        "1.2.0"
    }

    var earningsSince: String? {
        nil
    }

    func open(_: String, params _: [String: String], from _: UUID?) {}

    func replace(page _: UUID, route _: String, params _: [String: String]) -> Bool {
        false
    }

    func close(page _: UUID) -> Bool {
        false
    }

    func payoutSaved(page _: UUID) -> Bool {
        false
    }

    func copy(_: String) -> Bool {
        false
    }

    func contactService(from _: String) {}

    func stepUpPhone(account _: String) -> String? {
        "13800005678"
    }

    func stepUpPhoneBound(_: WalletOwner) -> Bool? {
        bound
    }

    func markWalletDirty(_: WalletOwner) {}

    func realnameChanged() {}

    func sensitiveOverlay(_: Bool) {}

    func nowMillis() -> Int64 {
        now
    }

    func displayNowMillis() -> Int64 {
        now
    }
}

/// App 出口替身：记下导航、客服、去向与强更标签通知；`scope` 是此刻的会话作用域。
@MainActor
final class App13a1FakePorts: DeleteAccountPorts {
    var scope: String
    var opened: [String] = []
    var contacted = 0
    var meReadGate: RetryAfterGate?
    var toForceUpdate = 0
    var toSettings = 0
    var settingsResult = true
    var changed = 0

    init(scope: String) {
        self.scope = scope
    }

    func sessionScope() -> String {
        scope
    }

    func open(_ route: String, from _: UUID) {
        opened.append(route)
    }

    func contactService() {
        contacted += 1
    }

    func returnToForceUpdate(page _: UUID) {
        toForceUpdate += 1
    }

    func returnToSettings(page _: UUID) -> Bool {
        toSettings += 1
        return settingsResult
    }

    func deletionChanged(_: WalletOwner) {
        changed += 1
    }
}

@MainActor
final class App13a1ControllerFixture {
    let api = App13a1FakeApi()
    let env = App13a1ControllerEnv()
    let ports: App13a1FakePorts
    let deps: WalletDeps
    let controller: DeleteAccountController

    init(scope: String, source: DeletionSource, phoneBound: Bool?) {
        env.bound = phoneBound
        ports = App13a1FakePorts(scope: scope)
        deps = WalletDeps(
            api: api, env: env, gates: WalletGates(), cache: nil, mask: AmountMaskStore(), realname: nil, labor: nil
        )
        controller = DeleteAccountController(
            deps: deps, identity: DeletionIdentity(owner: env.owner, scope: scope, source: source), page: UUID(),
            ports: ports
        )
        controller.setVisible(true)
    }

    func json(_ call: ApiCall) -> [String: Any] {
        guard let body = call.body, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
            return [:]
        }
        return object as? [String: Any] ?? [:]
    }

    func idle() async {
        for _ in 0..<8 {
            await controller.flow.stepUp.whenIdle()
            await controller.flow.whenIdle()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func passStepUp(file: StaticString = #filePath, line: UInt = #line) async throws {
        let stepUp = controller.flow.stepUp
        let deadline = Date().addingTimeInterval(5)
        while stepUp.state?.phase != .ready {
            if Date() > deadline {
                XCTFail("二次验证面板没有就绪", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let state = try XCTUnwrap(stepUp.state, file: file, line: line)
        XCTAssertEqual(state.action, "account_deletion", "面板 action = account_deletion", file: file, line: line)
        stepUp.onCodeChange("123456", instance: state.instance)
        stepUp.verify(instance: state.instance)
    }

    func closePanel() {
        if let state = controller.flow.stepUp.state {
            controller.flow.stepUp.close(instance: state.instance)
        }
    }
}
