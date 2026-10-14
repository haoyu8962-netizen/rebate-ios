import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// CT-LOCK-01（契约 40cfc268，CT-02g/h）：购买 open 被 30102 / 30111 拦下且 `data.reason=sharer_auth_invalid`（生成表
/// retry_kind_by_reason=never）→ 只提示：不弹授权、不登记授权待办、不重放、不进入无返利购买分支。无 reason 的授权流程不变。
/// App 内 `link_landing.invalid` 的专门展示归 APP-13b。
@MainActor
final class CtLock01SharerAuthInvalidPurchaseTests: XCTestCase {
    private let reason: TradeObject = ["reason": "sharer_auth_invalid"]

    private func assertOnlyPrompts(_ rig: PurchaseHarness, code: Int) async {
        await eventually { rig.controller.state.toast != nil }
        XCTAssertEqual(rig.controller.state.toast?.key, "error.\(code)")
        XCTAssertNil(rig.controller.state.dialog, "不弹 AuthSheet / 二选一")
        XCTAssertNil(rig.controller.pendingAuthCode, "没有授权上下文")
        XCTAssertNil(rig.pending.peek(), "不登记授权待办")
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "不重放、不发无返利购买")
        XCTAssertTrue(rig.api.calls(TradeOperations.bindUnion).isEmpty)
        XCTAssertTrue(rig.api.calls(TradeOperations.listUnionBindings).isEmpty)
        XCTAssertTrue(rig.ports.launched.isEmpty, "不执行授权跳转")
        XCTAssertTrue(rig.ports.browsed.isEmpty)
        XCTAssertEqual(rig.webCode.calls, 0)
        XCTAssertTrue(rig.sink.events.isEmpty)
    }

    /// 淘宝 30102：即使带着授权地址也只提示。
    func testTaobaoSharerAuthInvalidOnlyPrompts() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        var data = reason
        data.merge(["auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"]]) { $1 }
        rig.replyOpen(0, TradeFixtures.fail(30102, data))
        await assertOnlyPrompts(rig, code: 30102)
    }

    /// 拼多多 30111：即使带着 auth_jump 也只提示。
    func testPddSharerAuthInvalidOnlyPrompts() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "pdd:x", platform: "pdd"))
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        var data = reason
        data["auth_jump"] = [
            "primary": ["type": "universal_link", "value": "https://auth.test/p"], "fallbacks": [],
            "expire_at": TradeFixtures.future(),
        ]
        rig.replyOpen(0, TradeFixtures.fail(30111, data))
        await assertOnlyPrompts(rig, code: 30111)
    }

    /// 对照：不带 reason 的 30102 照旧弹 AuthSheet、登记待办；关闭后给二选一（含【仍去购买（无返利）】）。
    func testWithoutReasonTheAuthorizationFlowAndNoRebateChoiceAreUnchanged() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30102, [
            "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"],
        ]))
        await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
        XCTAssertEqual(rig.controller.pendingAuthCode, 30102)
        XCTAssertNotNil(rig.pending.peek(), "登记授权待办")
        rig.controller.dismissDialog()
        XCTAssertEqual(rig.controller.state.dialog, .authDeclined(platform: "taobao", failed: false))
        rig.controller.buyWithoutRebate(rig.controller.state.dialogTicket)
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(TradeFixtures.body(rig.opens()[1])["no_rebate"] as? Bool, true)
    }

    /// 对照：不带 reason 的 30111 照旧进授权跳转。
    func testWithoutReasonPddStillRunsTheAuthJump() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "pdd:x", platform: "pdd"))
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        let plan: TradeObject = [
            "primary": ["type": "universal_link", "value": "https://auth.test/p"], "fallbacks": [],
            "expire_at": TradeFixtures.future(),
        ]
        rig.replyOpen(0, TradeFixtures.fail(30111, ["auth_jump": plan]))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.pendingAuthCode, 30111)
        rig.controller.authorize()
        await eventually { rig.ports.launched.count == 1 }
    }
}
