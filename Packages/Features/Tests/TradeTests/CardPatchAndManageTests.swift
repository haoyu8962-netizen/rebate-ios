import CouliNetwork
import Foundation
@testable import Trade
import TradeJump
import XCTest

/// 卡片写回（共性第 7、8、16、17、21、22、26 条）、淘宝授权 30104 恢复（第 18 条）、授权管理（第 11、14、23 条）、link_jump 字段。
@MainActor
final class CardPatchAndManageTests: XCTestCase {
    // MARK: - CardPatch

    /// 共性第 8、16 条：返利从无到有 → 临时展示状态（按区间显示），清掉暂无返利、原因与「去购买（无返利）」。
    func testRebateRestoredUsesProvisionalStateAndClearsNoRebate() {
        var card = TradeFixtures.card(rebate: (0, 0), basis: "no_rebate")
        card["cta"] = ["text_key": "btn.buy.no_rebate"]
        card["no_rebate_cause"] = "price_compare"
        let data = TradeFixtures.open(extra: ["new_rebate_min_fen": 100, "new_rebate_max_fen": 200])
        let out = CardPatch.apply(card, data)
        XCTAssertTrue(CardPatch.provisional(out))
        XCTAssertTrue(out["rebate_basis"] is NSNull)
        XCTAssertTrue(out["no_rebate_cause"] is NSNull)
        XCTAssertEqual(TJSON.string(TJSON.object(out["cta"])?["text_key"]), "btn.buy.coupon", "券额已知有券")
        XCTAssertTrue(CardPatch.needsRefetch(card, data))
        // 补齐：区间一致、权威口径 normal → 去掉临时标记
        var fresh = TradeFixtures.card(rebate: (100, 200))
        fresh["disclaimer_keys"] = ["price_basis", "rebate_estimate"]
        let filled = CardPatch.fill(expected: CardPatch.revision(out))(out, fresh)
        XCTAssertFalse(CardPatch.provisional(filled))
        XCTAssertEqual(TJSON.string(filled["rebate_basis"]), "normal")
    }

    /// 共性第 21、22 条：coupon_gone 不等于无券——券额与券前价置未知、去掉「有券」与「领券购买」；补齐确认有新券再同步回来。
    func testCouponGoneSetsCouponUnknownAndFillRestoresNewCoupon() {
        let card = TradeFixtures.card()
        let data = TradeFixtures.open(extra: ["availability": "coupon_gone", "new_final_price_fen": 5178])
        let out = CardPatch.apply(card, data)
        XCTAssertTrue(out["coupon_fen"] is NSNull)
        XCTAssertTrue(out["price_fen"] is NSNull)
        XCTAssertEqual(TJSON.strings(out["benefit_tags"]), [])
        XCTAssertEqual(TJSON.string(TJSON.object(out["cta"])?["text_key"]), "btn.buy")
        var fresh = TradeFixtures.card(final: 5178, coupon: 500)
        fresh["link_id"] = "OTHER"
        let filled = CardPatch.fill(expected: CardPatch.revision(out))(out, fresh)
        XCTAssertEqual(TJSON.fen(filled["coupon_fen"]), 500, "换了新券")
        XCTAssertEqual(TJSON.fen(filled["price_fen"]), 5678)
        XCTAssertEqual(TJSON.strings(filled["benefit_tags"]), ["有券"])
        XCTAssertEqual(TJSON.string(TJSON.object(filled["cta"])?["text_key"]), "btn.buy.coupon")
        XCTAssertEqual(TJSON.string(filled["link_id"]), "L1", "open 确认的 link_id 保留，不被重取的卡覆盖")
    }

    /// 共性第 17、26 条：补齐只填未知字段且核对卡片版本；保留 open 确认的无返利按钮与比价原因。
    func testFillKeepsOpenResultAndRejectsStaleRevision() {
        var card = TradeFixtures.card()
        let data = TradeFixtures.open(extra: [
            "price_changed": true, "new_final_price_fen": 4990, "new_rebate_min_fen": 0, "new_rebate_max_fen": 0,
            "no_rebate_cause": "price_compare",
        ])
        card = CardPatch.bump(CardPatch.apply(card, data))
        let fill = CardPatch.fill(expected: CardPatch.revision(card))
        let fresh = TradeFixtures.card(final: 4990)
        let filled = fill(card, fresh)
        XCTAssertEqual(TJSON.fen(filled["coupon_fen"]), 1000)
        XCTAssertEqual(TJSON.string(TJSON.object(filled["cta"])?["text_key"]), "btn.buy.no_rebate")
        XCTAssertEqual(TJSON.string(filled["no_rebate_cause"]), "price_compare")
        XCTAssertEqual(TJSON.string(filled["rebate_basis"]), "no_rebate")
        // 之后又写进了新的购买结果（版本变了）：旧补齐不得填入
        let newer = CardPatch.bump(card)
        let stale = fill(newer, TradeFixtures.card(final: 4990, coupon: 300))
        XCTAssertTrue(stale["coupon_fen"] is NSNull)
        // 价格对不上：不补
        let mismatch = CardPatch.fill(expected: CardPatch.revision(card))(card, TradeFixtures.card(final: 5000))
        XCTAssertTrue(mismatch["coupon_fen"] is NSNull)
    }

    func testAmountUnknownNullIsNotZero() {
        var card = TradeFixtures.card(basis: "amount_unknown")
        card["final_price_fen"] = NSNull()
        let data = TradeFixtures.open(extra: [
            "old_final_price_fen": NSNull(), "new_final_price_fen": NSNull(), "new_rebate_min_fen": NSNull(),
            "new_rebate_max_fen": NSNull(),
        ])
        let out = CardPatch.apply(card, data)
        XCTAssertEqual(TJSON.string(out["rebate_basis"]), "amount_unknown")
        XCTAssertFalse(CardPatch.needsRefetch(card, data))
    }

    // MARK: - 30104 恢复（共性第 18 条）

    func testTaobaoFlowRecoversFrom30104ByReason() async throws {
        let api = FakeTradeApi()
        let web = FakeWebCode()
        var keys = 0
        let flow = TaobaoAuthFlow(
            calls: TradeCalls(api: api), group: "g", webCode: web, baichuan: UnavailableBaichuan(),
            keyGenerator: {
                keys += 1
                return "bind-\(keys)"
            },
            alive: { true }, installed: { _ in "unknown" }
        )
        var binds = 0
        api.auto = { call in
            switch call.operationId {
            case TradeOperations.bindUnion:
                binds += 1
                return binds == 1 ? TradeFixtures.fail(30104, ["reason": "credential_invalid"])
                    : TradeFixtures.ok(["status": "active"])
            case TradeOperations.getUnionAuthUrl:
                return TradeFixtures.ok(["auth_url": "https://o.test", "state": "st2", "auth_methods": ["web_code"]])
            default:
                return nil
            }
        }
        // credential_invalid：web_code 失效后新列表里没有别的本端可执行方式 → 授权失败
        let failed = await flow.run(platform: "taobao", initial: [
            "auth_url": "https://o.test", "state": "st1", "auth_methods": ["web_code"],
        ])
        guard case .failed = failed else { return XCTFail("应为授权失败：\(failed)") }

        binds = 0
        api.auto = { call in
            switch call.operationId {
            case TradeOperations.bindUnion:
                binds += 1
                return binds == 1 ? TradeFixtures.fail(30104, ["reason": "method_not_allowed"])
                    : TradeFixtures.ok(["status": "active"])
            case TradeOperations.getUnionAuthUrl:
                return TradeFixtures.ok(["auth_url": "https://o.test", "state": "st3", "auth_methods": ["web_code"]])
            default:
                return nil
            }
        }
        let bound = await flow.run(platform: "taobao", initial: [
            "auth_url": "https://o.test", "state": "st1", "auth_methods": ["web_code"],
        ])
        guard case .bound = bound else { return XCTFail("应为绑定成功：\(bound)") }
        let bindCalls = api.calls(TradeOperations.bindUnion)
        XCTAssertEqual(Set(bindCalls.compactMap(\.idempotencyKey)).count, bindCalls.count, "每次绑定尝试新键")
        XCTAssertEqual(TradeFixtures.body(try XCTUnwrap(bindCalls.last))["state"] as? String, "st3", "用新 state")
    }

    // MARK: - 授权管理（共性第 11、14、23 条，BR-ID-17 细则）

    private func manage(_ api: FakeTradeApi) -> (AuthManageController, FakePorts) {
        let ports = FakePorts()
        let controller = AuthManageController(
            api: api, executor: TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: FakeSink()),
            ports: ports, webCode: FakeWebCode(), baichuan: UnavailableBaichuan()
        )
        return (controller, ports)
    }

    func testAuthManageRowsAndBlocked30153() async {
        let api = FakeTradeApi()
        api.auto = { call in
            switch call.operationId {
            case TradeOperations.listUnionBindings:
                TradeFixtures.ok(["items": [
                    ["platform": "taobao", "status": "active"],
                    ["platform": "jd", "status": "unbound"],
                ]])
            case TradeOperations.getUnionAuthUrl: TradeFixtures.fail(30153)
            default: nil
            }
        }
        let (controller, _) = manage(api)
        XCTAssertTrue(api.calls.isEmpty, "进入页面前不发请求、不自动授权")
        controller.load()
        await eventually { controller.state.phase == .content }
        XCTAssertEqual(controller.state.rows.map(\.platform), ["taobao", "pdd"], "只列淘宝、拼多多")
        XCTAssertEqual(controller.state.rows.map(\.authorized), [true, false])
        XCTAssertTrue(api.calls(TradeOperations.getUnionAuthUrl).isEmpty, "不自动发起授权")
        controller.authorize("pdd")
        await eventually { controller.state.rows.last?.blocked == true }
        XCTAssertFalse(controller.state.rows.last?.canAuthorize ?? true)
        XCTAssertTrue(api.calls(TradeOperations.openLink).isEmpty, "授权管理不重放 open")
    }

    func testAuthManageErrorKeysByActualCode() async {
        struct Case {
            let result: ApiResult
            let key: String
            let trace: String?
        }
        let transport = ApiResult.transportFailure(
            kind: "disconnect", httpStatus: nil, idempotencyKey: nil, pendingKeyUnknown: false
        )
        let cases = [
            Case(result: TradeFixtures.fail(42901, disableMillis: 10000), key: "error.42901", trace: nil),
            Case(result: TradeFixtures.fail(50301), key: "error.50301", trace: TradeFixtures.trace),
            Case(result: transport, key: "buy.timeout", trace: nil),
        ]
        for item in cases {
            let (result, key, trace) = (item.result, item.key, item.trace)
            let api = FakeTradeApi()
            api.auto = { _ in result }
            let (controller, _) = manage(api)
            controller.load()
            await eventually { controller.state.phase == .error }
            XCTAssertEqual(controller.state.errorKey, key)
            XCTAssertEqual(controller.state.errorTraceId, trace)
            if key == "error.42901" {
                XCTAssertTrue(controller.state.rateLimited)
                controller.load()
                XCTAssertEqual(api.calls.count, 1, "42901 期间执行层拦下")
            }
        }
    }

    func testAuthManageTaobaoBindRefreshesWithoutOpen() async {
        let api = FakeTradeApi()
        var active = false
        api.auto = { call in
            switch call.operationId {
            case TradeOperations.listUnionBindings:
                return TradeFixtures.ok(["items": [["platform": "taobao", "status": active ? "active" : "unbound"]]])
            case TradeOperations.getUnionAuthUrl:
                return TradeFixtures.ok(["auth_url": "https://o.test", "state": "s", "auth_methods": ["web_code"]])
            case TradeOperations.bindUnion:
                active = true
                return TradeFixtures.ok(["status": "active"])
            default:
                return nil
            }
        }
        let (controller, _) = manage(api)
        controller.load()
        await eventually { controller.state.phase == .content }
        controller.authorize("taobao")
        await eventually { controller.state.rows.first?.authorized == true }
        XCTAssertTrue(api.calls(TradeOperations.openLink).isEmpty)
    }

    // MARK: - link_jump 与启动初始化

    func testStartupInitFailureReportsStartupEvent() {
        let sink = FakeSink()
        let executor = TradeJumpExecutor(ports: FakePorts(), baichuan: UnavailableBaichuan(), sink: sink)
        executor.reportStartupInitFailed()
        XCTAssertEqual(sink.events.count, 1)
        let event = sink.events[0]
        XCTAssertEqual(TJSON.string(event["phase"]), "startup")
        XCTAssertEqual(TJSON.string(event["result"]), "sdk_init_failed")
        XCTAssertNil(event["attempt_id"])
    }

    func testAuthSheetCounterResetsAfterLongBackground() {
        var now: Int64 = 0
        let counter = AuthSheetCounter { now }
        XCTAssertTrue(counter.tryAutoPop("taobao"))
        XCTAssertTrue(counter.tryAutoPop("taobao"))
        XCTAssertFalse(counter.tryAutoPop("taobao"))
        XCTAssertTrue(counter.tryAutoPop("pdd"), "按平台计")
        counter.onBackground()
        now = 1_799_999
        counter.onForeground()
        XCTAssertFalse(counter.tryAutoPop("taobao"))
        counter.onBackground()
        now += AuthSheetCounter.resetAfterMillis
        counter.onForeground()
        XCTAssertTrue(counter.tryAutoPop("taobao"))
    }

    func testPlatformOverrideYieldsToLaterConfig() {
        var issued: UInt64 = 3
        var applied: UInt64 = 3
        let overrides = PlatformStatusOverrides(issuedMark: { issued }, appliedMark: { applied })
        overrides.mark("taobao", status: "not_launched")
        XCTAssertEqual(overrides.status("taobao"), "not_launched")
        issued = 4
        XCTAssertEqual(overrides.status("taobao"), "not_launched", "之前或同一次在途拉取不覆盖")
        applied = 4
        XCTAssertNil(overrides.status("taobao"), "之后发出并生效的配置覆盖")
    }
}
