import CouliNetwork
import DesignSystem
import Foundation
import ProductSearch
@testable import Trade
import TradeJump
import XCTest

/// APP-06b 共性第 31–38 条（鸿蒙第 2 轮评审所得）。
@MainActor
final class LessonsRound2Tests: XCTestCase {
    /// 第 31 条：30104 恢复要再拉起授权时，用户许可已撤销（进过后台）就不自动再拉起。
    func testTaobaoRecoveryDoesNotRelaunchWithoutUserPermit() async {
        let api = FakeTradeApi()
        let web = FakeWebCode()
        api.auto = { call in
            switch call.operationId {
            case TradeOperations.bindUnion: TradeFixtures.fail(30104)
            case TradeOperations.getUnionAuthUrl:
                TradeFixtures.ok(["auth_url": "https://o.test", "state": "st2", "auth_methods": ["web_code"]])
            default: nil
            }
        }
        let flow = TaobaoAuthFlow(
            calls: TradeCalls(api: api), group: "g", webCode: web, baichuan: UnavailableBaichuan(),
            keyGenerator: { UUID().uuidString }, alive: { true }, installed: { _ in "unknown" },
            relaunchAllowed: { false }
        )
        let outcome = await flow.run(platform: "taobao", initial: [
            "auth_url": "https://o.test", "state": "st1", "auth_methods": ["web_code"],
        ])
        guard case .failed = outcome else { return XCTFail("应按授权失败交用户重试：\(outcome)") }
        XCTAssertEqual(web.calls, 1, "不自动再拉起授权")
    }

    /// 第 32 条：等下单须知期间平台被关闭，外跳前再查平台状态。
    func testPlatformStatusRecheckedAfterTipsWait() async {
        let rig = PurchaseHarness()
        rig.api.auto = nil
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { rig.api.index(of: TradeOperations.getTips) != nil }
        rig.env.statuses["taobao"] = "maintenance"
        rig.api.reply(rig.api.index(of: TradeOperations.getTips) ?? 0, TradeFixtures.ok(["jump_tip": ["taobao": "x"]]))
        await eventually { rig.controller.state.toast != nil }
        XCTAssertEqual(rig.controller.state.toast?.key, "error.50301.maintenance")
        XCTAssertTrue(rig.ports.launched.isEmpty)
    }

    /// 第 33 条：同键重放得到相同结果，不作废进行中的补齐。
    func testSameKeyReplayKeepsPendingFill() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.sleeper.fire(8000)
        await eventually { rig.controller.state.phase == .timeout }
        let changed = TradeFixtures.open(extra: [
            "price_changed": true,
            "new_final_price_fen": 4990,
            "new_link_id": "L2",
        ])
        rig.replyOpen(0, TradeFixtures.ok(changed))
        await eventually { rig.env.refetches.count == 1 }
        rig.controller.retryAfterTimeout()
        await eventually { rig.opens().count == 2 }
        rig.replyOpen(1, TradeFixtures.ok(changed))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.env.refetches.count, 1, "相同结果不发新补齐")
        let filled = rig.env.refetches[0].1(rig.env.card, TradeFixtures.card(final: 4990))
        XCTAssertEqual(TJSON.fen(filled["coupon_fen"]), 1000, "进行中的补齐仍落下")
    }

    /// 第 34 条：新券后价已知、券前价 / 券额待补齐：不当价格不可用，照常显示新价并可买，副行不写「无券」。
    func testKnownNewFinalPriceStaysBuyable() {
        let card = CardPatch.apply(TradeFixtures.card(), TradeFixtures.open(extra: [
            "price_changed": true, "new_final_price_fen": 4990,
        ]))
        XCTAssertTrue(card["coupon_fen"] is NSNull)
        XCTAssertFalse(ProductDetailState.priceUnavailable(card))
        XCTAssertFalse(ProductCardMapper.priceUnavailable(card))
        let mapping = ProductCardMapper.map(card, texts: { $0 })
        XCTAssertEqual(mapping.data.buyState, .normal)
        XCTAssertEqual(mapping.data.price.mainAmount, CouliFormat.money(fen: 4990))
        XCTAssertEqual(mapping.data.price.mainLabel, "", "口径未知不带口径词")
        XCTAssertNil(mapping.data.price.subLine, "券额未知：没有副行（不写「无券」）")
        XCTAssertFalse(mapping.data.price.noCoupon)
        let filled = CardPatch.fill(expected: CardPatch.revision(card))(card, TradeFixtures.card(final: 4990))
        XCTAssertFalse(CardPatch.pricePending(filled), "补齐后去掉待补齐标记")
    }

    /// 第 35 条：零返利保持为零时按本次响应更新比价原因。
    func testZeroRebateKeepsUpdatingNoRebateCause() {
        var card = TradeFixtures.card(rebate: (0, 0), basis: "no_rebate")
        card["no_rebate_cause"] = "price_compare"
        let cleared = CardPatch.apply(card, TradeFixtures.open(extra: [
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "no_rebate_cause": "something_new",
        ]))
        XCTAssertTrue(cleared["no_rebate_cause"] is NSNull, "未知值清除原因")
        card["no_rebate_cause"] = NSNull()
        let added = CardPatch.apply(card, TradeFixtures.open(extra: [
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "no_rebate_cause": "price_compare",
        ]))
        XCTAssertEqual(TJSON.string(added["no_rebate_cause"]), "price_compare")
    }

    /// 第 38 条：授权跳转的异步回调晚于回前台通知：回调到达时已在前台、进过后台 → 立即补查授权。
    func testLateLaunchCallbackAfterForegroundQueriesBindings() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "pdd:x", platform: "pdd"))
        rig.ports.launchResults = [true]
        rig.ports.onLaunch = { [weak rig] in
            // 拉起时进后台、回前台都发生在回调到达之前
            rig?.controller.onBackground()
            rig?.controller.onForeground()
        }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        let plan: TradeObject = [
            "primary": ["type": "scheme", "value": "pdd://auth"], "fallbacks": [], "expire_at": TradeFixtures.future(),
        ]
        rig.replyOpen(0, TradeFixtures.fail(30111, ["auth_jump": plan]))
        await eventually { rig.controller.state.dialog != nil }
        rig.controller.authorize()
        await eventually { rig.api.index(of: TradeOperations.listUnionBindings) != nil }
    }

    /// 第 39 条：授权回流查询成功但未授权 → 删除待办，给【仍去购买（无返利）】【重试】。
    func testReturnQueryUnboundClearsPendingAndOffersChoice() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "pdd:x", platform: "pdd"))
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        let plan: TradeObject = [
            "primary": ["type": "scheme", "value": "pdd://auth"], "fallbacks": [], "expire_at": TradeFixtures.future(),
        ]
        rig.replyOpen(0, TradeFixtures.fail(30111, ["auth_jump": plan]))
        await eventually { rig.controller.state.dialog != nil }
        rig.controller.authorize()
        await eventually { rig.controller.state.dialog == nil }
        rig.controller.onBackground()
        rig.controller.onForeground()
        await eventually { rig.api.index(of: TradeOperations.listUnionBindings) != nil }
        rig.api.reply(
            rig.api.index(of: TradeOperations.listUnionBindings) ?? 0,
            TradeFixtures.ok(["items": [["platform": "pdd", "status": "unbound"]]])
        )
        await eventually { rig.controller.state.dialog == .authDeclined(platform: "pdd", failed: false) }
        XCTAssertNil(rig.pending.peek())
        XCTAssertEqual(rig.opens().count, 1, "未授权不自动 open")
    }

    /// 第 40 条：拉起等待期间平台关闭 → 不再执行回退步；已执行的那一步照常上报（不看前台）。
    func testStartPermitAndReportPermitAreSeparate() async {
        let rig = PurchaseHarness()
        rig.ports.launchResults = [false, true]
        rig.ports.onLaunch = { [weak rig] in
            rig?.env.statuses["taobao"] = "maintenance"
            rig?.controller.onBackground()
        }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: [
            ["type": "scheme", "value": "app://a"], ["type": "universal_link", "value": "https://u.test/x"],
        ])))
        await eventually { rig.sink.events.count == 1 }
        await settle()
        XCTAssertEqual(rig.ports.launched.count, 1, "不执行回退步")
        XCTAssertEqual(TJSON.string(rig.sink.events[0]["result"]), "failed", "已执行步骤照常上报")
    }

    /// 第 41 条：游客未知返利 → 登录后重放得到确定结果要写进卡片。
    func testDefiniteRebateFromUnknownIsWrittenToCard() {
        var guest = TradeFixtures.card(basis: "login_required")
        guest["rebate_min_fen"] = NSNull()
        guest["rebate_max_fen"] = NSNull()
        let zero = CardPatch.apply(guest, TradeFixtures.open(extra: ["new_rebate_min_fen": 0, "new_rebate_max_fen": 0]))
        XCTAssertEqual(TJSON.string(zero["rebate_basis"]), "no_rebate")
        XCTAssertEqual(TJSON.fen(zero["rebate_max_fen"]), 0)
        XCTAssertEqual(TJSON.string(TJSON.object(zero["cta"])?["text_key"]), "btn.buy.no_rebate")
        let positive = CardPatch.apply(
            guest,
            TradeFixtures.open(extra: ["new_rebate_min_fen": 100, "new_rebate_max_fen": 200])
        )
        XCTAssertTrue(positive["rebate_basis"] is NSNull, "清掉 login_required")
        XCTAssertTrue(CardPatch.provisional(positive), "先按服务端区间显示")
        var unknown = TradeFixtures.card(basis: "amount_unknown")
        unknown["rebate_max_fen"] = NSNull()
        let kept = CardPatch.apply(unknown, TradeFixtures.open(extra: [
            "new_rebate_min_fen": NSNull(), "new_rebate_max_fen": NSNull(),
        ]))
        XCTAssertEqual(TJSON.string(kept["rebate_basis"]), "amount_unknown")
    }
}
