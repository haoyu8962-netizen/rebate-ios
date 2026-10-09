import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// 购买执行器的授权恢复（BR-ID-10 / 17 / 18 / 22；共性第 10、19、20、25 条）。
@MainActor
final class OpenPurchaseAuthFlowTests: XCTestCase {
    private let authData: TradeObject = [
        "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["sdk_token", "web_code"],
    ]

    // MARK: - 授权（BR-ID-10 / 17 / 18 / 22）

    func testTaobaoAuthorizationAutoOpensOnceWithNewKey() async {
        let rig = PurchaseHarness()
        rig.api.auto = { call in
            switch call.operationId {
            case TradeOperations.getTips: TradeFixtures.ok(["jump_tip": ["taobao": "x"]])
            case TradeOperations.bindUnion: TradeFixtures.ok(["platform": "taobao", "status": "active"])
            default: nil
            }
        }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30101, authData))
        await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
        XCTAssertEqual(rig.controller.pendingAuthCode, 30101)
        rig.controller.authorize()
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.webCode.calls, 1, "sdk_token 不可用：取下发顺序里本端能执行的 web_code")
        let bind = rig.api.calls(TradeOperations.bindUnion)[0]
        XCTAssertEqual(TradeFixtures.body(bind)["auth_method"] as? String, "web_code")
        XCTAssertNotNil(bind.idempotencyKey)
        XCTAssertEqual(rig.opens()[1].idempotencyKey, "key-3", "授权后重发是新请求、新键（key-2 给了绑定）")
        XCTAssertNotEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey)
        XCTAssertEqual(rig.opens()[1].pathParams["link_id"], "L1")
        XCTAssertNil(rig.pending.peek())
    }

    func testDeclinedAuthOffersRetryAndNoRebate() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30101, authData))
        await eventually { rig.controller.state.dialog != nil }
        rig.controller.dismissDialog()
        XCTAssertEqual(rig.controller.state.dialog, .authDeclined(platform: "taobao", failed: false))
        XCTAssertNil(rig.pending.peek(), "关闭授权：删除待办")
        rig.controller.buyWithoutRebate()
        await eventually { rig.opens().count == 2 }
        let body = TradeFixtures.body(rig.opens()[1])
        XCTAssertEqual(body["no_rebate"] as? Bool, true)
        XCTAssertEqual(body["no_rebate_reason"] as? String, "auth_declined")
        XCTAssertNotEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey)
    }

    func testUnavailableAuthOnlyNotifies() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30101, ["reason": "auth_unavailable"]))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .authUnavailable(textKey: "error.30101.auth_unavailable"))
    }

    /// 共性第 10 条：自动弹出上限只限制自动弹出；用户在二选一里主动【重试】不受限。
    func testAutoPopLimitDoesNotBlockUserRetry() async {
        let rig = PurchaseHarness()
        for round in 0..<3 {
            rig.controller.buy(rig.env.card, spm: nil)
            await eventually { rig.opens().count == round + 1 }
            rig.replyOpen(round, TradeFixtures.fail(30101, authData))
            await eventually { rig.controller.state.dialog != nil }
            if round < 2 {
                XCTAssertEqual(rig.controller.state.dialog, .authSheet(platform: "taobao", busy: false))
                rig.controller.dismissDialog()
                rig.controller.dismissDialog()
            }
        }
        XCTAssertEqual(rig.controller.state.dialog, .authDeclined(platform: "taobao", failed: false), "第 3 次直接二选一")
        rig.controller.retryPurchase()
        await eventually { rig.opens().count == 4 }
        rig.replyOpen(3, TradeFixtures.fail(30101, authData))
        await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
    }

    /// 拼多多 30111：执行 auth_jump（不上报 link_jump）；回前台服务端确认已授权 → 自动执行一次 open（新键）。
    func testPddAuthJumpThenServerConfirmsAndReopensWithNewKey() async {
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
        rig.controller.authorize()
        await eventually { rig.ports.launched.count == 1 }
        await eventually { rig.controller.state.dialog == nil }
        XCTAssertTrue(rig.sink.events.isEmpty, "auth_jump 不上报 link_jump")
        rig.controller.onBackground()
        rig.controller.onForeground()
        await eventually { rig.api.index(of: TradeOperations.listUnionBindings) != nil }
        rig.api.reply(
            rig.api.index(of: TradeOperations.listUnionBindings) ?? 0,
            TradeFixtures.ok(["items": [["platform": "pdd", "status": "active"]]])
        )
        await eventually { rig.opens().count == 2 }
        XCTAssertNotEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey)
    }

    /// 共性第 25 条：授权跳转进后台后不再执行下一步。
    func testAuthJumpStopsWhenAppGoesToBackground() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "pdd:x", platform: "pdd"))
        rig.ports.launchResults = [false, true]
        rig.ports.onLaunch = { [weak rig] in rig?.controller.onBackground() }
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        let plan: TradeObject = [
            "primary": ["type": "scheme", "value": "pdd://auth"],
            "fallbacks": [["type": "h5", "value": "https://auth.test/p"]], "expire_at": TradeFixtures.future(),
        ]
        rig.replyOpen(0, TradeFixtures.fail(30111, ["auth_jump": plan]))
        await eventually { rig.controller.state.dialog != nil }
        rig.controller.authorize()
        await eventually { rig.ports.launched.count == 1 }
        await settle()
        XCTAssertTrue(rig.ports.browsed.isEmpty, "进后台后不再打开浏览器")
    }

    /// 共性第 19 条：授权回流查询 42901 / 5xxxx 不当成用户未授权；42901 禁用【重试】。
    func testBindingsQueryFailureIsNotTreatedAsDeclined() async {
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
            rig.api.index(of: TradeOperations.listUnionBindings) ?? 0, TradeFixtures.fail(42901, disableMillis: 10000)
        )
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(
            rig.controller.state.dialog,
            .authCheckFailed(platform: "pdd", textKey: "error.42901", traceId: nil, afterBind: false)
        )
        XCTAssertTrue(rig.controller.state.rateLimited)
        XCTAssertNotNil(rig.pending.peek(), "不清待办")
        rig.controller.recheckAuth()
        await settle()
        XCTAssertEqual(rig.api.calls(TradeOperations.listUnionBindings).count, 1, "限流期间执行层拦下重试")
    }

    /// 共性第 20 条（S0）：旧的授权回流查询在新点击之后到达，只丢弃，不关新尝试的确认窗、不自动 open。
    func testStaleBindingsQueryCannotResumeSupersededPurchase() async {
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
        let query = rig.api.index(of: TradeOperations.listUnionBindings) ?? 0
        // 用户在查询返回前又点了一次购买，新响应要求返利归零确认
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        XCTAssertFalse(rig.api.isValid(query), "新点击先作废旧查询的归属")
        rig.replyOpen(1, TradeFixtures.ok(TradeFixtures.open(extra: [
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "no_rebate_cause": "price_compare",
        ])))
        await eventually { rig.controller.state.dialog == .compareNoRebate }
        rig.api.reply(query, TradeFixtures.ok(["items": [["platform": "pdd", "status": "active"]]]))
        await settle()
        XCTAssertEqual(rig.controller.state.dialog, .compareNoRebate, "旧查询不得关掉新尝试的确认窗")
        XCTAssertEqual(rig.opens().count, 2, "旧查询不得自动 open")
        XCTAssertTrue(rig.ports.launched.count == 1, "只有授权跳转那一次")
    }
}
