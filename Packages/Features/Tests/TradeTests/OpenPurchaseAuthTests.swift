import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// 购买执行器：登录、补同意、授权恢复、禁用状态与平台状态（共性第 4、5、6、9、10、19、20、24、25、27、28 条）。
@MainActor
final class OpenPurchaseAuthTests: XCTestCase {
    // MARK: - 登录（BR-ID-10：1xxxx 沿用原键）

    func testLoginRequiredRegistersPendingAndReplaysOriginalRequestOnceAfterLogin() async {
        let rig = PurchaseHarness()
        rig.env.isLoggedIn = false
        rig.controller.buy(rig.env.card, spm: "ProductDetail.bottom.buy")
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(10001))
        await eventually { rig.env.opened.last?.0 == "Login" }
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["kind"]), "login")
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["idempotency_key"]), "key-1")
        rig.controller.onBackground()
        rig.env.isLoggedIn = true
        rig.controller.resumeAfterLogin()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "登录页还盖着：等回到前台")
        rig.controller.onForeground()
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.opens()[1].idempotencyKey, "key-1", "登录后沿用原键")
        XCTAssertEqual(rig.opens()[1].body, rig.opens()[0].body)
        XCTAssertEqual(rig.opens()[1].pathParams, rig.opens()[0].pathParams)
        XCTAssertNil(rig.pending.peek(), "只执行一次")
        rig.controller.resumeAfterLogin()
        await settle()
        XCTAssertEqual(rig.opens().count, 2)
    }

    /// APP-05b 第 1 轮 R1-01：第三方新号登录后待办暂缓——resumeAfterLogin 不读取、不清除、不重放，记录原样保留；释放后再调一次
    /// 才按原尝试重放一次（原键）。
    func testResumeAfterLoginKeepsPendingWhileHeldThenReplaysOnceAfterRelease() async {
        let rig = PurchaseHarness()
        rig.env.isLoggedIn = false
        rig.controller.buy(rig.env.card, spm: "ProductDetail.bottom.buy")
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(10001))
        await eventually { rig.env.opened.last?.0 == "Login" }
        rig.env.isLoggedIn = true
        rig.pending.held = true
        rig.controller.resumeAfterLogin()
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "暂缓中不重发购买请求")
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["idempotency_key"]), "key-1", "暂缓中记录原样保留")
        rig.pending.held = false
        rig.controller.resumeAfterLogin()
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.opens()[1].idempotencyKey, "key-1", "释放后按原尝试恢复一次")
        XCTAssertNil(rig.pending.peek())
    }

    func testAbandonedLoginClearsPendingOnReturn() async {
        let rig = PurchaseHarness()
        rig.env.isLoggedIn = false
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(10001))
        await eventually { rig.pending.peek() != nil }
        rig.controller.onBackground()
        rig.controller.onForeground()
        XCTAssertNil(rig.pending.peek(), "关掉登录页回来仍是游客：删除登录待办")
    }

    // MARK: - 基本模式（共性第 4、24 条）

    func testBasicModeConsentThenResumeWithOriginalQuoteBaseline() async {
        let rig = PurchaseHarness()
        rig.env.isBasic = true
        let original = rig.env.card
        rig.controller.buy(original, spm: nil)
        await settle()
        XCTAssertTrue(rig.opens().isEmpty, "基本模式不直接调 open")
        XCTAssertEqual(rig.env.consentRequests, 1)
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["kind"]), "consent")
        // 同意期间页面上的卡被别处更新（新 link、返利归零）：恢复仍按原点击的卡与 link_id
        rig.env.card = TradeFixtures.card(link: "L2", rebate: (0, 0), basis: "no_rebate")
        rig.env.isBasic = false
        rig.controller.resumeAfterConsent()
        await eventually { rig.opens().count == 1 }
        XCTAssertEqual(rig.opens()[0].pathParams["link_id"], "L1", "原点击的 link_id")
        rig.replyOpen(
            0,
            TradeFixtures.ok(TradeFixtures.open(extra: ["new_rebate_min_fen": 0, "new_rebate_max_fen": 0]))
        )
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .confirmRebateGone(priceFen: 4678, oldFen: 4678), "以原报价为基准，返利归零先确认")
    }

    // MARK: - 禁用状态按对象绑定（共性第 5、6、27、28 条）

    func testOffShelfBindsToCardOnly() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30141))
        await eventually { TJSON.string(rig.env.card["availability"]) == "off_shelf" }
        rig.controller.buy(rig.env.card, spm: nil)
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "下架的卡不再发 open")
        rig.controller.buy(TradeFixtures.card(link: "L8", key: "tb:other"), spm: nil)
        await eventually { rig.opens().count == 2 }
    }

    func testNotLaunchedMarksPlatformSilentlyAndBlocksLaterOpens() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(50301, ["reason": "not_launched"]))
        await eventually { !rig.env.marked.isEmpty }
        XCTAssertEqual(rig.env.marked.first?.1, "not_launched")
        XCTAssertNil(rig.controller.state.toast, "not_launched 不弹提示")
        rig.controller.buy(rig.env.card, spm: nil)
        await settle()
        XCTAssertEqual(rig.opens().count, 1)

        let mx = PurchaseHarness()
        mx.controller.buy(mx.env.card, spm: nil)
        await eventually { mx.opens().count == 1 }
        mx.replyOpen(0, TradeFixtures.fail(50301, ["reason": "maintenance"]))
        await eventually { mx.controller.state.toast != nil }
        XCTAssertEqual(mx.controller.state.toast?.key, "error.50301.maintenance")
        XCTAssertEqual(mx.controller.state.toast?.traceId, TradeFixtures.trace, "5xxxx 带 trace6")
    }

    /// 共性第 27 条：超时同键重试也经平台状态核对。
    func testTimeoutRetryRechecksPlatformStatus() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.sleeper.fire(8000)
        await eventually { rig.controller.state.phase == .timeout }
        rig.env.statuses["taobao"] = "not_launched"
        rig.controller.retryAfterTimeout()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "平台已关闭：重试不再发 open")
        XCTAssertEqual(rig.controller.state.phase, .idle)
    }

    func testRetryAfterRateLimitDisablesBuy() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(42901, disableMillis: 10000))
        await eventually { rig.controller.state.rateLimited }
        XCTAssertFalse(rig.controller.canTap)
        rig.controller.buy(rig.env.card, spm: nil)
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "限流期间执行层拦下")
    }

    /// 共性第 9 条：30144 按 product_key + item_ref 重取卡（整卡替换，但不覆盖之后写入的购买结果），等用户再点。
    func testRefExpiredRefetchesCardAndWaits() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30144))
        await eventually { rig.env.refetches.count == 1 }
        let merged = rig.env.refetches[0].1(rig.env.card, TradeFixtures.card(link: "L3"))
        XCTAssertEqual(TJSON.string(merged["link_id"]), "L3")
        let stale = rig.env.refetches[0].1(CardPatch.bump(rig.env.card), TradeFixtures.card(link: "L4"))
        XCTAssertEqual(TJSON.string(stale["link_id"]), "L1", "卡片版本已变：不覆盖")
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "不自动再发 open")
    }
}
