import CouliNetwork
import Foundation
@testable import Trade
import TradeJump
import XCTest

/// APP-06b 共性第 43–45 条（iOS 第 1 轮评审 I-R1-02 / 03 / 04）。第 42 条（Release 不含模拟开关）由 verify.sh 的 release-scan
/// 检查（Release 不命中、Debug / Staging 自检命中）。
@MainActor
final class LessonsRound3Tests: XCTestCase {
    // MARK: - 第 43 条：比价无返利确认不依赖原返利为正

    private func compareResponse(price: Int = 4678) -> TradeObject {
        TradeFixtures.open(extra: [
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "no_rebate_cause": "price_compare",
            "old_final_price_fen": price, "new_final_price_fen": price,
        ])
    }

    func testCompareNoRebateWhenOriginalRebateUnknown() {
        let response: TradeObject = ["code": 0, "data": compareResponse()]
        let unknown = OpenResponseAction.map(
            response: response, context: ["currentPriceFen": 4678, "currentRebateMaxFen": NSNull()]
        )
        XCTAssertEqual(unknown.actionRaw, OpenActions.compareNoRebate, "原返利未知（游客）也要弹比价无返利确认")
        let missing = OpenResponseAction.map(response: response, context: ["currentPriceFen": 4678])
        XCTAssertEqual(missing.actionRaw, OpenActions.compareNoRebate)
        let alreadyZero = OpenResponseAction.map(
            response: response, context: ["currentPriceFen": 4678, "currentRebateMaxFen": 0]
        )
        XCTAssertEqual(alreadyZero.actionRaw, OpenActions.compareNoRebate, "原返利为 0 也要弹（第 43 条修订，I-R2-01）")
        XCTAssertTrue(alreadyZero.rebateGone)
        let positive = OpenResponseAction.map(
            response: response, context: ["currentPriceFen": 4678, "currentRebateMaxFen": 269]
        )
        XCTAssertEqual(positive.actionRaw, OpenActions.compareNoRebate)
        let zeroConfirmed = OpenResponseAction.map(
            response: response,
            context: ["currentPriceFen": 4678, "currentRebateMaxFen": 0, "noRebateConfirmed": true]
        )
        XCTAssertEqual(zeroConfirmed.actionRaw, OpenActions.jump, "原返利为 0 且本次就是确认过的无返利购买：不再问")
        let confirmed = OpenResponseAction.map(
            response: response,
            context: ["currentPriceFen": 4678, "currentRebateMaxFen": NSNull(), "noRebateConfirmed": true]
        )
        XCTAssertEqual(confirmed.actionRaw, OpenActions.jump, "用户已确认的无返利购买不再问")
        var changed = compareResponse()
        changed["price_changed"] = true
        changed["new_final_price_fen"] = 5000
        let merged = OpenResponseAction.map(
            response: ["code": 0, "data": changed], context: ["currentPriceFen": 4678, "currentRebateMaxFen": NSNull()]
        )
        XCTAssertEqual(merged.actionRaw, OpenActions.confirmPrice)
        XCTAssertTrue(merged.rebateGone, "改价确认里合并无返利说明")
    }

    /// 第 43 条修订（I-R2-01）：卡片原返利为 0（原因 null）→ 本次返回零返利 + price_compare：仍弹比价确认，不直接外跳（下单须知已读）。
    func testZeroRebateCardWithNewPriceCompareCauseShowsConfirm() async {
        var zero = TradeFixtures.card(rebate: (0, 0), basis: "no_rebate")
        zero["no_rebate_cause"] = NSNull()
        let rig = PurchaseHarness(card: zero)
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        XCTAssertEqual(rig.opens().first?.body?.contains("no_rebate"), false, "普通点击：不带 no_rebate（即 false）")
        rig.replyOpen(0, TradeFixtures.ok(compareResponse()))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .compareNoRebate)
        XCTAssertEqual(TJSON.string(rig.env.card["no_rebate_cause"]), "price_compare")
        await settle()
        XCTAssertTrue(rig.ports.launched.isEmpty, "未确认前不外跳")
    }

    /// 游客点购买 → 10001 → 登录 → 重放返回 price_compare 零返利：弹比价确认，不直接外跳（下单须知已读）。
    func testGuestLoginReplayPriceCompareShowsConfirm() async {
        var guest = TradeFixtures.card(key: "pdd:tissue", platform: "pdd", basis: "login_required")
        guest["rebate_min_fen"] = NSNull()
        guest["rebate_max_fen"] = NSNull()
        guest["est_net_price_fen"] = NSNull()
        let rig = PurchaseHarness(card: guest)
        rig.ports.launchResults = [true]
        rig.env.isLoggedIn = false
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(10001))
        await eventually { rig.env.opened.last?.0 == "Login" }
        rig.env.isLoggedIn = true
        rig.controller.resumeAfterLogin()
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey, "登录后沿用原键重放")
        rig.replyOpen(1, TradeFixtures.ok(compareResponse()))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .compareNoRebate)
        XCTAssertTrue(rig.ports.launched.isEmpty, "未确认前不外跳")
        XCTAssertEqual(TJSON.string(rig.env.card["rebate_basis"]), "no_rebate", "卡片写成零返利")
        XCTAssertEqual(TJSON.string(rig.env.card["no_rebate_cause"]), "price_compare")
        rig.controller.confirm()
        await eventually { rig.ports.launched.count == 1 }
    }

    // MARK: - 第 44 条：购买待办按发起页面与尝试归属

    private let pddPlan: TradeObject = [
        "primary": ["type": "universal_link", "value": "https://auth.test/p"], "fallbacks": [],
        "expire_at": TradeFixtures.future(),
    ]

    /// 第二个发起页（与 `rig` 共用同一份待办记录）。
    @MainActor
    private final class SecondPage {
        let api = FakeTradeApi()
        let ports = FakePorts()
        let env: FakeEnv
        let controller: OpenPurchaseController

        init(sharing pending: PurchasePending, card: TradeObject) {
            env = FakeEnv(card: card)
            let executor = TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: FakeSink())
            var generated = 0
            controller = OpenPurchaseController(
                api: api, executor: executor, ports: ports, env: env, pending: pending, counter: AuthSheetCounter(),
                tips: JumpTipService(api: api) { "user-1" }, webCode: FakeWebCode(), baichuan: UnavailableBaichuan(),
                keyGenerator: {
                    generated += 1
                    return "b-key-\(generated)"
                }
            )
            api.auto = { call in
                call.operationId == TradeOperations.getTips
                    ? TradeFixtures.ok(["jump_tip": ["taobao": "x", "jd": "x", "pdd": "x"]]) : nil
            }
        }

        func opens() -> [ApiCall] {
            api.calls(TradeOperations.openLink)
        }
    }

    /// 页面 A 从拼多多授权回来、查询还没返回 → 页面 B 购买收到 30111，登记自己的授权待办。返回 A 被盖住（不在前台）、B 在前台。
    private struct Interleaved {
        let rig: PurchaseHarness
        let pageB: SecondPage
        let queryA: Int
    }

    private func interleave() async -> Interleaved {
        let rig = PurchaseHarness(card: TradeFixtures.card(link: "LA", key: "pdd:a", platform: "pdd"))
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30111, ["auth_jump": pddPlan]))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LA")
        rig.controller.authorize()
        await eventually { rig.ports.launched.count == 1 }
        await eventually { rig.controller.state.dialog == nil }
        rig.controller.onBackground()
        rig.controller.onForeground()
        await eventually { rig.api.index(of: TradeOperations.listUnionBindings) != nil }
        let queryA = rig.api.index(of: TradeOperations.listUnionBindings) ?? 0
        // 用户打开详情页 B（A 仍在导航栈中，被盖住）
        rig.controller.onBackground()
        let pageB = SecondPage(
            sharing: rig.pending, card: TradeFixtures.card(link: "LB", key: "pdd:b", platform: "pdd")
        )
        pageB.ports.launchResults = [true]
        pageB.controller.buy(pageB.env.card, spm: nil)
        await eventually { pageB.opens().count == 1 }
        pageB.api.reply(
            pageB.api.index(of: TradeOperations.openLink) ?? 0, TradeFixtures.fail(30111, ["auth_jump": pddPlan])
        )
        await eventually { pageB.controller.state.dialog != nil }
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LB", "B 登记了自己的授权待办")
        return Interleaved(rig: rig, pageB: pageB, queryA: queryA)
    }

    /// B 授权完成后仍能自动执行一次 open（BR-ID-10 / 22）。
    private func assertPageBResumes(_ rig: PurchaseHarness, _ pageB: SecondPage) async {
        pageB.controller.authorize()
        await eventually { pageB.ports.launched.count == 1 }
        await eventually { pageB.controller.state.dialog == nil }
        pageB.controller.onBackground()
        pageB.controller.onForeground()
        await eventually { pageB.api.index(of: TradeOperations.listUnionBindings) != nil }
        pageB.api.reply(
            pageB.api.index(of: TradeOperations.listUnionBindings) ?? 0,
            TradeFixtures.ok(["items": [["platform": "pdd", "status": "active"]]])
        )
        await eventually { pageB.opens().count == 2 }
        XCTAssertEqual(pageB.opens().last?.pathParams["link_id"], "LB")
        XCTAssertNil(rig.pending.peek(), "B 消费了自己的待办")
    }

    func testLateUnauthorizedQueryOfOldPageKeepsNewPagePending() async {
        let run = await interleave()
        let (rig, pageB) = (run.rig, run.pageB)
        rig.api.reply(run.queryA, TradeFixtures.ok(["items": [["platform": "pdd", "status": "unbound"]]]))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .authDeclined(platform: "pdd", failed: false))
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LB", "旧页面的未授权结果不删新页面的待办")
        await assertPageBResumes(rig, pageB)
    }

    func testLateAuthorizedQueryOfOldPageKeepsNewPagePending() async {
        let run = await interleave()
        let (rig, pageB) = (run.rig, run.pageB)
        rig.api.reply(run.queryA, TradeFixtures.ok(["items": [["platform": "pdd", "status": "active"]]]))
        await settle()
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "A 的待办已被 B 覆盖：A 不自动执行")
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LB", "旧页面的已授权结果不删、不消费新页面的待办")
        await assertPageBResumes(rig, pageB)
    }

    func testLeavingOldPageKeepsNewPagePending() async {
        let run = await interleave()
        let (rig, pageB) = (run.rig, run.pageB)
        rig.controller.leave()
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LB", "旧页面出栈只删自己的待办")
        await assertPageBResumes(rig, pageB)
    }

    // MARK: - 第 45 条：返利归零弹窗的价格文案

    func testRebateGoneBodyFollowsActualPrices() {
        XCTAssertEqual(RebateGoneBody.pick(newFen: 2990, oldFen: 2990), .unchanged(priceFen: 2990))
        XCTAssertEqual(RebateGoneBody.pick(newFen: 3080, oldFen: 2990), .changed(priceFen: 3080), "涨 90 分未达阈值也不是「没有变化」")
        XCTAssertEqual(RebateGoneBody.pick(newFen: 3080, oldFen: nil), .changed(priceFen: 3080))
        XCTAssertEqual(RebateGoneBody.pick(newFen: nil, oldFen: 2990), .noPrice)
    }

    /// 原价 2990、返利上限 229 → 新价 3080、返利 0、price_changed=false：弹返利归零，带新旧价格；新价口径未补齐（券额未知）。
    func testBelowThresholdRebateGoneCarriesBothPricesAndPlainLabel() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(final: 2990, rebate: (100, 229)))
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: [
            "old_final_price_fen": 2990, "new_final_price_fen": 3080, "new_link_id": "L1b",
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0,
        ])))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .confirmRebateGone(priceFen: 3080, oldFen: 2990))
        XCTAssertFalse(RebateGoneBody.newPriceLabelKnown(rig.controller.state.card), "新价券额未补齐：用 now_plain")
        XCTAssertTrue(rig.ports.launched.isEmpty)
    }
}

// MARK: - 第 46 条：授权后的延迟恢复执行前再核待办有效期与归属（I-R2-02）

extension LessonsRound3Tests {
    /// 拼多多授权回来、查询途中又进后台 → 查询返回 active：不在前台，等回前台再自动 open；此时待办不删、只重新计时。
    private func authorizedWhileInBackground() async -> PurchaseHarness {
        let rig = PurchaseHarness(card: TradeFixtures.card(link: "LA", key: "pdd:a", platform: "pdd"))
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30111, ["auth_jump": pddPlan]))
        await eventually { rig.controller.state.dialog != nil }
        rig.controller.authorize()
        await eventually { rig.ports.launched.count == 1 }
        await eventually { rig.controller.state.dialog == nil }
        rig.controller.onBackground()
        rig.controller.onForeground()
        await eventually { rig.api.index(of: TradeOperations.listUnionBindings) != nil }
        let query = rig.api.index(of: TradeOperations.listUnionBindings) ?? 0
        rig.controller.onBackground()
        rig.api.reply(query, TradeFixtures.ok(["items": [["platform": "pdd", "status": "active"]]]))
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "不在前台：等回前台再执行")
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LA", "延迟恢复期间待办保留到执行前")
        return rig
    }

    func testDeferredResumeWithinValidityOpensOnce() async {
        let rig = await authorizedWhileInBackground()
        rig.pendingClock.now += MemoryPurchasePending.ttlMillis - 60000
        rig.controller.onForeground()
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.opens().last?.pathParams["link_id"], "LA")
        XCTAssertNil(rig.pending.peek(), "执行前消费一次")
        rig.controller.onBackground()
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 2, "只执行一次")
    }

    func testDeferredResumeAfterValidityDoesNotOpen() async {
        let rig = await authorizedWhileInBackground()
        rig.pendingClock.now += MemoryPurchasePending.ttlMillis + 1
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "授权完成超过 10 分钟才回前台：不自动 open（BR-ID-10）")
        XCTAssertNil(rig.pending.peek(), "过期待办已清理")
        XCTAssertEqual(rig.ports.launched.count, 1, "只有授权跳转那一次")
        XCTAssertNil(rig.controller.state.dialog)
    }

    func testDeferredResumeAbandonedWhenOtherPageRegistersNewPending() async {
        let rig = await authorizedWhileInBackground()
        let pageB = SecondPage(
            sharing: rig.pending, card: TradeFixtures.card(link: "LB", key: "pdd:b", platform: "pdd")
        )
        pageB.ports.launchResults = [true]
        pageB.controller.buy(pageB.env.card, spm: nil)
        await eventually { pageB.opens().count == 1 }
        pageB.api.reply(
            pageB.api.index(of: TradeOperations.openLink) ?? 0, TradeFixtures.fail(30111, ["auth_jump": pddPlan])
        )
        await eventually { pageB.controller.state.dialog != nil }
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LB", "B 登记的新待办取代了 A 的")
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "A 的待办已被取代：放弃延迟恢复")
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["link_id"]), "LB", "不删别的页面的待办")
        await assertPageBResumes(rig, pageB)
    }
}
