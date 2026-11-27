import ClientCore
import CouliNetwork
import Foundation
import Generated
@testable import MeCore
import WalletCore
import XCTest

/// FU-IOS-DELETION-REAPPLY-STALE-KEY 写测（独立写测方）：申请注销幂等键在「撤回成功」与「申请被 3xxxx 拒」之后必须换新键
/// （底座与夹具同 App13a1DeleteAccountControllerTests，只经注销页控制器已有公开入口驱动）。
///
/// 依据：编排 D10-2914（三端统一修法）、D10-3450（只做撤回成功两路；已有用例不改，只新增）；服务端事实：申请得 code 0 或任何 3xxxx 时
/// 服务端存应答 30 天、同键原样回放；1xxxx / 5xxxx / 网络未知时记录已删，同键重试正确。
/// - 场景 ①：申请结果未知（超时 / 断连）→ 撤回成功（直接成功、或撤回结果未知后核对读到用户撤回）→ 再申请必须用新键
///   （旧键会拿到旧的「已进冷静期」回放，库里其实已撤回）；
/// - 场景 ②：申请被 30412 / 30416 拒 → 用户处理完 → 再申请必须用新键（旧键会一直拿到旧的拒绝）；
/// - 对照：申请成功 → 撤回成功 → 再申请用新键；申请 5xxxx → 再申请仍同键（只有 1xxxx / 5xxxx / 结果未知持键）。
@MainActor
final class FuIosDeletionReapplyStaleKeyTests: App13a1ControllerTestCase {
    // MARK: - 场景 ① 申请结果未知 → 撤回成功

    /// 申请超时（结果未知）→ 再次进入页面读到冷静期 → 【撤回注销】直接成功 → 页面无待确认卡、再同步也不回来 → 再点【申请注销】：
    /// 请求带新键（≠ 第一次）。
    ///
    /// 防御回归：直接调控制器撤回，绕过 DeletionPresentation 待确认卡优先的显示规则（D10-3452）。本夹具 pendingStatus 固定 .none，
    /// 待确认卡随即消失、只剩内存键；生产里待确认卡在时没有【撤回注销】（真实保证见 FuIosDeletionPendingCardTests）。
    func testDefenceBypassesPendingCardRuleCancelSucceededAfterUnknownApplyNextApplyUsesNewKey() async {
        let fixture = await unknownApplyThenCooling(App13a1Replies.transport)
        fixture.api.on("cancelDeletion", App13a1Replies.ok(App13a1Replies.cancelled))

        cancel(fixture)
        await waitFor("撤回没有成功") {
            fixture.controller.state.toast?.key == DeletionCancelOutcome.withdrawnKey
        }
        await fixture.idle()
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1)

        await reapplyAfterCancel(fixture, "超时 → 撤回直接成功")
    }

    /// 申请断连（结果未知）→ 撤回也断连（结果未知）→ 核对读取读到用户撤回 cancelled → 同一撤回成功结算 → 无待确认卡、再申请带新键。
    ///
    /// 防御回归：直接调控制器撤回，绕过 DeletionPresentation 待确认卡优先的显示规则（D10-3452）。夹具口径同上一条。
    func testDefenceBypassesPendingCardRuleCancelReconciledAfterUnknownApplyNextApplyUsesNewKey() async {
        let disconnect = ApiResult.transportFailure(
            kind: "disconnect", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
        )
        let fixture = await unknownApplyThenCooling(disconnect)
        fixture.api.on("cancelDeletion", App13a1Replies.transport)
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))

        cancel(fixture)
        await waitFor("撤回未知后核对没有按撤回成功结算") {
            fixture.controller.state.toast?.key == DeletionCancelOutcome.withdrawnKey
        }
        await fixture.idle()
        XCTAssertEqual(fixture.api.calls("cancelDeletion").count, 1, "撤回结果未知不自动重发")
        XCTAssertNil(fixture.controller.state.notice, "核对查明已撤回：结果未知提示已清")

        await reapplyAfterCancel(fixture, "断连 → 撤回未知 → 核对已撤回")
    }

    // MARK: - 场景 ② 申请被 3xxxx 拒

    /// 申请得 30412（有进行中的提现）→ 用户处理完回到本页 → 再点【申请注销】：请求带新键。
    func test30412ThenReapplyUsesNewKey() async {
        let fixture = make(source: .other)
        prime(fixture)
        fixture.api.on("requestDeletion", App13a1Replies.fail(30412), App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        ensureChecked(fixture)
        apply(fixture)
        await waitFor("30412 没有落到页面") { fixture.controller.flow.state.error?.key == "error.30412" }
        await fixture.idle()
        XCTAssertTrue(fixture.controller.state.withdrawHint, "前提：30412 给【去提现】")

        // 用户去处理在途提现，回到本页
        reenter(fixture)
        await fixture.idle()
        await applyAgain(fixture, "30412 之后")
        XCTAssertEqual(keys(fixture), ["fu-key-1", "fu-key-2"], "30412 之后再申请必须用新键（旧键会一直拿到旧的拒绝）")
    }

    /// 申请得 30416（负余额）→ 用户处理完、主动【重试】读到 negative_fen = 0 → 再点【申请注销】：请求带新键。
    func test30416ThenReapplyUsesNewKey() async {
        let fixture = make(source: .other)
        prime(fixture)
        fixture.api.on(
            "requestDeletion", App13a1Replies.fail(30416, data: "{\"amount_fen\":567}"),
            App13a1Replies.ok(App13a1Replies.cooling(true))
        )
        await open(fixture)
        ensureChecked(fixture)
        apply(fixture)
        await waitFor("没有进入负余额态") { fixture.controller.view.kind == .negative }
        await fixture.idle()

        // 用户补足余额后主动刷新：资格按新读取恢复（共性第 42 条）
        fixture.api.on("getWalletSummary", App13a1Replies.ok(App13a1Replies.summary(negative: 0)))
        fixture.controller.retry(version: fixture.controller.state.version, owner: fixture.controller.identity.owner)
        await waitFor("主动重试后没有恢复可申请") { fixture.controller.view.kind == .initial }
        await fixture.idle()
        await applyAgain(fixture, "30416 之后")
        XCTAssertEqual(keys(fixture), ["fu-key-1", "fu-key-2"], "30416 之后再申请必须用新键（旧键会一直拿到旧的拒绝）")
    }

    // MARK: - 对照

    /// 对照：申请成功直接进冷静期 → 撤回成功 → 再申请带新键（申请成功已结束键，钉回归）。
    func testApplySuccessThenCancelNextApplyUsesNewKey() async {
        let fixture = make(source: .other)
        prime(fixture)
        fixture.api.on("requestDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        ensureChecked(fixture)
        apply(fixture)
        await waitFor("申请没有成功进冷静期") { fixture.controller.view.kind == .cooling }
        await fixture.idle()
        XCTAssertTrue(fixture.controller.view.showCancel, "前提：冷静期可撤回")

        cancel(fixture)
        await waitFor("撤回没有成功") {
            fixture.controller.state.toast?.key == DeletionCancelOutcome.withdrawnKey
        }
        await fixture.idle()

        await reapplyAfterCancel(fixture, "申请成功 → 撤回成功")
    }

    /// 对照：申请得 5xxxx（服务端记录已删）→ 再点【申请注销】仍用同一个键（只有 1xxxx / 5xxxx / 结果未知持键，不被误改）。
    func test5xxxxThenReapplyReusesKey() async {
        let fixture = make(source: .other)
        prime(fixture)
        fixture.api.on("requestDeletion", App13a1Replies.fail(50401), App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        ensureChecked(fixture)
        apply(fixture)
        await waitFor("5xxxx 没有落到页面") { fixture.controller.flow.state.error?.showTrace6 == true }
        await fixture.idle()
        XCTAssertNil(fixture.controller.flow.state.pending, "5xxxx 不是结果未知：不显示待确认卡")

        await applyAgain(fixture, "5xxxx 之后")
        XCTAssertEqual(keys(fixture), ["fu-key-1", "fu-key-1"], "5xxxx 之后再申请沿用原键")
    }

    // MARK: - 驱动

    /// 键按点击顺序确定（fu-key-1、fu-key-2…），断言只看请求头里的 Idempotency-Key。
    private func prime(_ fixture: App13a1ControllerFixture) {
        let keys = FuReapplyKeys()
        fixture.deps.newKey = { keys.next() }
    }

    private func keys(_ fixture: App13a1ControllerFixture) -> [String?] {
        fixture.api.calls("requestDeletion").map(\.idempotencyKey)
    }

    /// 勾选框保持勾上（`check` 是切换）。
    private func ensureChecked(_ fixture: App13a1ControllerFixture) {
        if !fixture.controller.state.waiver {
            check(fixture)
        }
    }

    /// 离开再回到页面（回前台 / 从别的页回来）：按本机记录重建待确认、重读进度与资金。
    private func reenter(_ fixture: App13a1ControllerFixture) {
        fixture.controller.setVisible(false)
        fixture.controller.setVisible(true)
    }

    /// 申请结果未知（`unknown`：超时 / 断连）→ 再次进入页面先读注销状态：服务端其实已进冷静期（can_cancel = true）。
    private func unknownApplyThenCooling(_ unknown: ApiResult) async -> App13a1ControllerFixture {
        let fixture = make(source: .other)
        prime(fixture)
        fixture.api.on("requestDeletion", unknown, App13a1Replies.ok(App13a1Replies.cooling(true)))
        await open(fixture)
        ensureChecked(fixture)
        apply(fixture)
        await waitFor("第一次申请没有发出") { fixture.api.calls("requestDeletion").count == 1 }
        await fixture.idle()
        XCTAssertEqual(keys(fixture), ["fu-key-1"], "前提：第一次申请带 fu-key-1")
        XCTAssertNil(fixture.controller.flow.state.error, "前提：结果未知不是键结束的错误")

        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(true)))
        reenter(fixture)
        await waitFor("再次进入后没有读到冷静期") { fixture.controller.view.kind == .cooling }
        await fixture.idle()
        XCTAssertTrue(fixture.controller.view.showCancel, "前提：冷静期可撤回")
        return fixture
    }

    /// 撤回成功之后：回到初始态、无待确认卡（离开再回来按本机记录同步也不回来）→ 再点【申请注销】必须带新键。
    private func reapplyAfterCancel(
        _ fixture: App13a1ControllerFixture, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let controller = fixture.controller
        XCTAssertEqual(controller.view.kind, .initial, "\(label)：撤回后回到初始态", file: file, line: line)
        XCTAssertNil(controller.flow.state.pending, "\(label)：撤回后无待确认卡", file: file, line: line)

        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cancelled))
        reenter(fixture)
        await waitFor("\(label)：再次进入后没有回到初始态", file: file, line: line) {
            controller.view.kind == .initial && controller.state.funds != nil
        }
        await fixture.idle()
        XCTAssertNil(controller.flow.state.pending, "\(label)：按本机记录同步后待确认卡不回来", file: file, line: line)
        XCTAssertNotEqual(controller.view.kind, .pendingConfirm, "\(label)：不显示待确认态", file: file, line: line)

        await applyAgain(fixture, label, file: file, line: line)
        XCTAssertEqual(
            keys(fixture), ["fu-key-1", "fu-key-2"],
            "\(label)：撤回成功后再申请必须用新键（旧键会拿到旧的「已进冷静期」回放）", file: file, line: line
        )
    }

    /// 再点一次【申请注销】并等它发出、结算完。
    private func applyAgain(
        _ fixture: App13a1ControllerFixture, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        ensureChecked(fixture)
        XCTAssertTrue(fixture.controller.applyEnabled, "\(label)：前提：【申请注销】可点", file: file, line: line)
        apply(fixture)
        await waitFor("\(label)：再申请没有发出", file: file, line: line) {
            fixture.api.calls("requestDeletion").count == 2
        }
        await fixture.idle()
    }
}

/// 确定的幂等键序列（替换 `WalletDeps.newKey`；写法同 WalletCoreTests 的 App13a1Keys）。
final class FuReapplyKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0

    func next() -> String {
        lock.withLock {
            issued += 1
            return "fu-key-\(issued)"
        }
    }
}
