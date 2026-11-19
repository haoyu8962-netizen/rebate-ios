import ClientCore
import CouliNetwork
import Foundation
import Generated
@testable import MeCore
import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：撤回注销（cancelDeletion）的执行器用例（底座与夹具同 App13a1DeleteAccountControllerTests）。
///
/// 依据：三端任务书 APP-13a/brief.md §2 第 4 项（撤回去向 G18、10007、42901、5xxxx、结果未知不自动重发）；共性第 14、33 条
/// （撤回未知后核对，查明已撤回走同一成功结算；核对读取失败走统一读取失败、保留核对上下文）；D10-2094 ①（撤回 10007 提示契约 error.10007）。
@MainActor
final class App13a1DeleteAccountCancelTests: App13a1ControllerTestCase {
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

    /// 撤回得到 10007：停在冷静期页，提示契约 error.10007（D10-2094 ①），重取进度。
    func testCancel10007StaysAndRefetches() async {
        let fixture = await coolingPage(source: .settings)
        let readsBefore = fixture.api.calls("getDeletion").count
        fixture.api.on("cancelDeletion", App13a1Replies.fail(10007, data: "{\"stage\":\"cooling\"}"))
        fixture.api.on("getDeletion", App13a1Replies.ok(App13a1Replies.cooling(false)))
        cancel(fixture)
        await waitFor("10007 后没有重取进度") { fixture.api.calls("getDeletion").count > readsBefore }
        await fixture.idle()
        XCTAssertEqual(fixture.controller.view.kind, .cooling)
        // D10-2094 ①：冷静期已过的撤回提示用契约 error.10007（08「注销页·冷静期」、设计说明「其他结果一览 ③」），不用自拟句
        XCTAssertEqual(fixture.controller.state.notice?.key, "error.10007", "撤回 10007：提示契约 error.10007")
        XCTAssertNotEqual(fixture.controller.state.notice?.key, "deletion.cooling.cancel_expired", "不用自拟句")
        XCTAssertFalse(fixture.controller.view.showCancel, "重取到 can_cancel=false：不再显示撤回")
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
}
