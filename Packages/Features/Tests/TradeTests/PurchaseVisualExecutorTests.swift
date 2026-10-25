import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-06v-b 执行器层回归（D10-128 全部按推荐）：G-D07 下架不出轻提示、G-D09 50303「稍后再试」只关弹窗、G-D11 未安装淘宝的复制提示键。
/// 只断言执行器发出的状态与请求次数（open / 外跳 / 复制）；按钮接线由 UI 测试 PurchaseVisualUITests 真点。
@MainActor
final class PurchaseVisualExecutorTests: XCTestCase {
    // MARK: - G-D07：30141 / availability=off_shelf 不出轻提示，不外跳，按钮由映射置灰

    func testOpen30141MarksCardOffShelfWithoutToastOrJump() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30141))
        await eventually { TJSON.string(rig.env.card["availability"]) == "off_shelf" }
        await settle()
        XCTAssertNil(rig.controller.state.toast, "G-D07：下架不出「商品已下架」轻提示（改由卡片状态 polite 播报）")
        XCTAssertNil(rig.controller.state.dialog, "不弹窗")
        XCTAssertTrue(rig.ports.launched.isEmpty && rig.ports.browsed.isEmpty && rig.ports.copied.isEmpty, "不外跳")
        rig.controller.buy(rig.env.card, spm: nil)
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "下架的卡再点不发 open")
    }

    func testOpenSuccessOffShelfWithoutToastOrJump() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: ["availability": "off_shelf"])))
        await eventually { TJSON.string(rig.env.card["availability"]) == "off_shelf" }
        await settle()
        XCTAssertNil(rig.controller.state.toast, "G-D07：成功响应 availability=off_shelf 同样不出轻提示")
        XCTAssertTrue(rig.ports.launched.isEmpty && rig.ports.browsed.isEmpty && rig.ports.copied.isEmpty, "不外跳")
        XCTAssertTrue(rig.sink.events.isEmpty, "没有外跳就没有 link_jump")
    }

    // MARK: - G-D09：50303 主按钮「稍后再试」= 只关弹窗；再点购买才发新一次 open（新键）

    func test50303DismissSendsNothingAndNextBuyIsNewOpenWithNewKey() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(50303))
        await eventually { rig.controller.state.dialog != nil }
        guard case let .notice(_, _, noRebate, contact, _) = rig.controller.state.dialog else {
            return XCTFail("50303 应弹带按钮的提示，实际 \(String(describing: rig.controller.state.dialog))")
        }
        XCTAssertTrue(noRebate, "次按钮【仍去购买（无返利）】")
        XCTAssertFalse(contact, "50303 没有【联系客服】")
        rig.controller.dismissDialog()
        await settle()
        XCTAssertNil(rig.controller.state.dialog, "「稍后再试」关弹窗、留在详情页")
        XCTAssertEqual(rig.opens().count, 1, "关弹窗不发 open（不是立即重试）")
        XCTAssertEqual(rig.controller.state.phase, .idle, "不进加载层")
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        XCTAssertNotEqual(rig.opens()[0].idempotencyKey, rig.opens()[1].idempotencyKey, "再点购买是新一次尝试（新键）")
    }

    // MARK: - G-D10：比价无返利确认是居中弹窗（b v2，评审 r1 S2-7：Core 的 isSheet 与实际容器一致）

    func testCompareNoRebateIsCenteredDialogNotSheet() {
        XCTAssertFalse(PurchaseDialog.compareNoRebate.isSheet, "比价无返利确认按定稿是居中弹窗（G-D10）")
        XCTAssertTrue(PurchaseDialog.authSheet(platform: "taobao", busy: false).isSheet, "授权仍是半屏")
        XCTAssertTrue(PurchaseDialog.jumpTip(platform: "taobao").isSheet, "下单须知仍是半屏（G-D15）")
    }

    // MARK: - G-D11：未安装淘宝且口令已复制 → 新草稿键「已复制淘口令」；其余路径不出复制提示

    private static let schemeThenCopy: [TradeObject] = [
        ["type": "scheme", "value": "app://x"], ["type": "copy_tpwd", "value": "￥tpwd￥"],
    ]

    func testTaobaoNotInstalledCopiedUsesTpwdCopiedKeyAndKeepsJumpedOut() async {
        let rig = PurchaseHarness()
        rig.ports.installedValue = TradeConstants.installedFalse
        rig.ports.launchResults = [false]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: Self.schemeThenCopy)))
        await eventually { rig.controller.state.notInstalled }
        XCTAssertEqual(rig.ports.copied, ["￥tpwd￥"], "复制由服务端口令步骤执行，恰好一次")
        XCTAssertEqual(rig.controller.state.toast?.key, "trade.not_installed.tpwd_copied",
                       "G-D11：轻提示换新草稿键「已复制淘口令」（时机不变）")
        XCTAssertEqual(rig.opens().count, 1)
    }

    func testNotInstalledWithoutCopyStepHasNoCopiedToast() async {
        let rig = PurchaseHarness()
        rig.ports.installedValue = TradeConstants.installedFalse
        rig.ports.launchResults = [false]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: [["type": "scheme", "value": "app://x"]])))
        await eventually { rig.controller.state.notInstalled }
        await settle()
        XCTAssertTrue(rig.ports.copied.isEmpty, "没有口令步骤就不复制")
        XCTAssertNotEqual(rig.controller.state.toast?.key, "trade.not_installed.tpwd_copied", "没复制不能说「已复制淘口令」")
    }
}
