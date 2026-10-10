import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-08 iOS 第 3 轮后第二次定向复核 RC-06：来源（会话、环境、slot 世代）在**发起获取跳转方案**时固定，随这次获取、ReadyJump 与完成
/// 事件传递；响应结算、确认、等待结束与外跳前只比较。来源变了就作废旧方案（不外跳、不交付完成事件），继续购买需重新点购买取新方案。
@MainActor
final class JumpOriginStaleTests: XCTestCase {
    private final class Origin {
        var value = "origin-A"
        var delivered: [String?] = []
    }

    private func rig() -> (PurchaseHarness, Origin) {
        let rig = PurchaseHarness()
        let origin = Origin()
        rig.controller.jumpOrigin = { origin.value }
        rig.controller.onJumpedOut = { _, value in origin.delivered.append(value) }
        rig.ports.installedValue = TradeConstants.installedUnknown
        rig.ports.launchResults = [true]
        return (rig, origin)
    }

    private static let priceChanged = TradeFixtures.open(extra: ["price_changed": true, "new_final_price_fen": 4990])

    /// 停在改价确认 → 来源变了 → 点【继续购买】：不外跳、不交付，提示重新点购买；再点购买取新方案（新来源）照常外跳。
    func testConfirmAfterOriginChangeDropsPlanAndRebuyWorks() async {
        let (rig, origin) = rig()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(Self.priceChanged))
        await eventually { rig.controller.state.dialog != nil }
        origin.value = "origin-B"
        rig.controller.confirm()
        await settle()
        XCTAssertNil(rig.controller.state.dialog)
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
        XCTAssertTrue(rig.ports.launched.isEmpty, "旧方案不执行")
        XCTAssertTrue(rig.sink.events.isEmpty, "没有 link_jump 上报")
        XCTAssertTrue(origin.delivered.isEmpty, "不交付完成事件")
        XCTAssertEqual(rig.opens().count, 1, "不自动重发旧尝试")

        // 继续购买：重新点购买取新方案
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        rig.replyOpen(1, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { !origin.delivered.isEmpty }
        XCTAssertEqual(origin.delivered, ["origin-B"], "新方案带新来源")
        XCTAssertEqual(rig.ports.launched.count, 1)
    }

    /// JumpTip 停留期间来源变了：点【知道了，去X】也不执行旧方案。
    func testJumpTipConfirmAfterOriginChangeDropsPlan() async {
        let (rig, origin) = rig()
        rig.api.auto = { call in
            call.operationId == TradeOperations.getTips ? TradeFixtures.ok(["jump_tip": [String: String]()]) : nil
        }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { rig.controller.state.dialog == .jumpTip(platform: "taobao") }
        origin.value = "origin-B"
        rig.controller.confirm()
        await settle()
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
        XCTAssertTrue(rig.ports.launched.isEmpty)
        XCTAssertTrue(origin.delivered.isEmpty)
    }

    /// 获取方案期间（open 在途）来源变了：响应结算时作废，不弹确认、不外跳。
    func testOriginChangeWhileFetchingPlanDropsResponse() async {
        let (rig, origin) = rig()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        origin.value = "origin-B"
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await settle()
        XCTAssertNil(rig.controller.state.dialog)
        XCTAssertEqual(rig.controller.state.phase, .idle)
        XCTAssertTrue(rig.ports.launched.isEmpty)
        XCTAssertTrue(origin.delivered.isEmpty)
    }
}
