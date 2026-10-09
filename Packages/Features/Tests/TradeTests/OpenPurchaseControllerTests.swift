import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// 购买执行器（APP-06b）：幂等键、超时、迟到响应、确认框、外跳与 link_jump。共性清单（NATIVE/APP-06b/cross-platform-lessons.md）
/// 的编号写在每个用例的说明里。
@MainActor
final class OpenPurchaseControllerTests: XCTestCase {
    // MARK: - 超时与同键重试（TRADE-22，共性第 1、2 条）

    func testTimeoutIsEightSecondsAndRetryReplaysOriginalRequestWithSameKey() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: "ProductDetail.bottom.buy")
        await eventually { rig.opens().count == 1 }
        XCTAssertEqual(rig.controller.state.phase, .loading)
        XCTAssertEqual(rig.sleeper.requested, [OpenPurchaseController.timeoutMillis])
        XCTAssertEqual(OpenPurchaseController.timeoutMillis, 8000)
        rig.sleeper.fire(8000)
        await eventually { rig.controller.state.phase == .timeout }
        rig.controller.retryAfterTimeout()
        await eventually { rig.opens().count == 2 }
        let (first, second) = (rig.opens()[0], rig.opens()[1])
        XCTAssertEqual(first.idempotencyKey, "key-1")
        XCTAssertEqual(second.idempotencyKey, first.idempotencyKey, "超时重试沿用原键")
        XCTAssertEqual(second.pathParams, first.pathParams, "同一路径（原 link_id）")
        XCTAssertEqual(second.body, first.body, "同一请求体")
        // 旧请求作废：它的归属已失效
        XCTAssertFalse(rig.api.isValid(rig.api.index(of: TradeOperations.openLink, nth: 0) ?? 0))
    }

    /// 共性第 1 条（S0）：超时后迟到的响应更新了展示卡片（返利归零、新 link），同键重试的结果仍以点击时的原报价为基准要求确认；
    /// 共性第 2 条：重试仍打原路径。
    func testLateResponseAfterTimeoutCannotEraseRebateGoneConfirmation() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.sleeper.fire(8000)
        await eventually { rig.controller.state.phase == .timeout }
        let gone = TradeFixtures.open(extra: [
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "new_link_id": "L2",
        ])
        rig.replyOpen(0, TradeFixtures.ok(gone))
        await eventually { TJSON.string(rig.env.card["link_id"]) == "L2" }
        XCTAssertNil(rig.controller.state.dialog, "迟到响应不弹确认")
        XCTAssertTrue(rig.ports.launched.isEmpty)
        XCTAssertEqual(TJSON.fen(rig.env.card["rebate_max_fen"]), 0, "迟到响应更新卡片")
        rig.controller.retryAfterTimeout()
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.opens()[1].pathParams["link_id"], "L1", "重试完整重放原请求，不改到迟到响应的新 link")
        rig.replyOpen(1, TradeFixtures.ok(gone))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(rig.controller.state.dialog, .confirmRebateGone(priceFen: 4678, oldFen: 4678), "原基准判断返利归零，仍须确认")
        XCTAssertTrue(rig.ports.launched.isEmpty)
    }

    // MARK: - 取消、离页、后台后的迟到响应（03 §4.5）

    func testCancelledLoadingLateResponseOnlyUpdatesCard() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.controller.cancelLoading()
        XCTAssertEqual(rig.controller.state.phase, .idle)
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: ["new_link_id": "L9"])))
        await eventually { TJSON.string(rig.env.card["link_id"]) == "L9" }
        await settle()
        XCTAssertTrue(rig.ports.launched.isEmpty, "取消后不外跳")
        XCTAssertTrue(rig.sink.events.isEmpty, "不上报 link_jump")
        XCTAssertNil(rig.controller.state.dialog)
    }

    func testBackgroundLateResponseOnlyUpdatesCardAndLeaveDiscards() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.controller.onBackground()
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: ["new_link_id": "L5"])))
        await eventually { TJSON.string(rig.env.card["link_id"]) == "L5" }
        rig.controller.onForeground()
        await settle()
        XCTAssertTrue(rig.ports.launched.isEmpty, "后台期间到达的响应不外跳，回前台也不补执行")

        let other = PurchaseHarness()
        other.controller.buy(other.env.card, spm: nil)
        await eventually { other.opens().count == 1 }
        other.controller.leave()
        XCTAssertEqual(other.controller.inFlightOpens, 0, "出栈即作废并取消在途请求")
        other.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await settle()
        XCTAssertTrue(other.ports.launched.isEmpty)
    }

    /// 共性第 3 条：等下单须知已读状态期间进入后台，作废续执行许可。
    func testBackgroundWhileWaitingForTipsStopsJump() async {
        let rig = PurchaseHarness()
        rig.api.auto = nil
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { rig.api.index(of: TradeOperations.getTips) != nil }
        rig.controller.onBackground()
        rig.api.reply(rig.api.index(of: TradeOperations.getTips) ?? 0, TradeFixtures.ok(["jump_tip": [:]]))
        await settle()
        XCTAssertNil(rig.controller.state.dialog, "不弹须知")
        XCTAssertTrue(rig.ports.launched.isEmpty, "不外跳")
    }

    // MARK: - 确认框与外跳

    func testPriceChangedConfirmThenJumpReportsEveryStepWithSameAttemptAndReplacedLink() async {
        let rig = PurchaseHarness()
        rig.ports.launchResults = [false, true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        let data = TradeFixtures.open(
            attempt: "A7",
            steps: [["type": "scheme", "value": "app://a"], ["type": "universal_link", "value": "https://x.test/u"]],
            extra: ["price_changed": true, "new_final_price_fen": 4990, "new_link_id": "L2"]
        )
        rig.replyOpen(0, TradeFixtures.ok(data))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(
            rig.controller.state.dialog, .confirmPrice(oldFen: 4678, newFen: 4990, rebateGone: false, coupon: false)
        )
        XCTAssertEqual(TJSON.string(rig.env.card["link_id"]), "L2", "无论确认还是取消都先替换卡片")
        XCTAssertNil(TJSON.fen(rig.env.card["coupon_fen"]), "响应没有券额：置未知，不反推（共性第 7 条）")
        XCTAssertNil(TJSON.fen(rig.env.card["price_fen"]))
        XCTAssertEqual(rig.env.refetches.count, 1, "按 product_key + item_ref 重取补齐")
        rig.controller.confirm()
        await eventually { rig.sink.events.count == 2 }
        XCTAssertEqual(rig.ports.launched.map(\.0), ["scheme", "universal_link"], "按 primary、fallbacks 顺序")
        for event in rig.sink.events {
            XCTAssertEqual(TJSON.string(event["attempt_id"]), "A7")
            XCTAssertEqual(TJSON.string(event["link_id"]), "L2")
            XCTAssertEqual(TJSON.string(event["phase"]), "purchase")
            XCTAssertNil(event["value"], "步骤 value 不上报")
        }
        XCTAssertEqual(rig.sink.events.map { TJSON.string($0["result"]) }, ["failed", "launched"])
    }

    func testCancelPriceChangeShowsToastAndDoesNotJump() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: [
            "price_changed": true, "new_final_price_fen": 4990, "new_rebate_min_fen": 0, "new_rebate_max_fen": 0,
        ])))
        await eventually { rig.controller.state.dialog != nil }
        XCTAssertEqual(
            rig.controller.state.dialog, .confirmPrice(oldFen: 4678, newFen: 4990, rebateGone: true, coupon: false)
        )
        rig.controller.dismissDialog()
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.cancelledPriceRebate)
        XCTAssertEqual(TJSON.string(TJSON.object(rig.env.card["cta"])?["text_key"]), "btn.buy.no_rebate")
        await settle()
        XCTAssertTrue(rig.ports.launched.isEmpty)
    }

    func testCompareNoRebateSheetAndRequoteNotice() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "pdd:x", platform: "pdd"))
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: [
            "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "no_rebate_cause": "price_compare",
        ])))
        await eventually { rig.controller.state.dialog == .compareNoRebate }
        XCTAssertEqual(TJSON.string(rig.env.card["no_rebate_cause"]), "price_compare")
        // 【看看相似商品】：同平台、原样标题（BR-PRICE-08）
        rig.controller.similar()
        XCTAssertEqual(rig.env.opened.last?.0, "Search")
        XCTAssertEqual(rig.env.opened.last?.1, ["q": "milk title", "platform": "pdd"])
        XCTAssertNil(rig.controller.state.dialog)

        let rx = PurchaseHarness()
        rx.ports.launchResults = [true]
        rx.controller.buy(rx.env.card, spm: nil)
        await eventually { rx.opens().count == 1 }
        rx.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: ["requote_failed": true])))
        await eventually { rx.ports.launched.count == 1 }
        XCTAssertEqual(rx.controller.state.toast?.key, PurchaseTextKeys.requote, "复核失败照常外跳并提示")
    }

    /// 共性第 15 条：详情首次进入、没点过购买也能用当前商品构造【看看相似商品】参数。
    func testSimilarUsesGivenProductWithoutPurchase() {
        let rig = PurchaseHarness()
        var product = TradeFixtures.card(key: "jd:cup", platform: "jd")
        product["title"] = String(repeating: "长", count: 80)
        rig.controller.similar(product)
        XCTAssertEqual(rig.env.opened.last?.1["platform"], "jd")
        XCTAssertEqual(rig.env.opened.last?.1["q"]?.count, 60, "标题截前 60 字")
    }

    /// 共性第 12 条：跳转方案过了 expire_at → 不外跳、不上报、提示重新购买。
    func testExpiredPlanStopsWithoutReporting() async {
        let rig = PurchaseHarness()
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(expireAt: "2020-01-01T00:00:00+08:00")))
        await eventually { rig.controller.state.toast != nil }
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
        XCTAssertTrue(rig.ports.launched.isEmpty)
        XCTAssertTrue(rig.sink.events.isEmpty)
    }

    /// 共性第 13 条：installed=unknown 全部失败 → 通用跳转失败；明确 false → 安装提示。
    func testUnknownInstallStateIsNotTreatedAsNotInstalled() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { rig.controller.state.toast != nil }
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpFailed)
        XCTAssertFalse(rig.controller.state.notInstalled)
        XCTAssertEqual(TJSON.string(TradeFixtures.body(rig.opens()[0])["installed"]), "unknown")

        let fx = PurchaseHarness()
        fx.ports.installedValue = TradeConstants.installedFalse
        fx.controller.buy(fx.env.card, spm: nil)
        await eventually { fx.opens().count == 1 }
        fx.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { fx.controller.state.notInstalled }
        XCTAssertEqual(TJSON.string(fx.sink.events.first?["installed"]), "false")
    }

    func testSdkOnlyPlanShowsSdkFailedAndBrowserNoticeCanCancel() async {
        let rig = PurchaseHarness()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: [["type": "sdk", "value": "https://s.test"]])))
        await eventually { rig.controller.state.dialog == .sdkFailed }
        XCTAssertEqual(TJSON.string(rig.sink.events.first?["result"]), "sdk_init_failed")
        XCTAssertEqual(rig.baichuan.initAttempts, 1, "sdk 步骤前重试初始化 1 次")

        let bx = PurchaseHarness(card: TradeFixtures.card(key: "jd:cup", platform: "jd"))
        bx.controller.buy(bx.env.card, spm: nil)
        await eventually { bx.opens().count == 1 }
        bx.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: [["type": "h5", "value": "https://u.test/x"]])))
        await eventually { bx.controller.state.browserNotice }
        XCTAssertTrue(bx.sleeper.requested.contains(OpenPurchaseController.browserNoticeMillis))
        bx.controller.cancelBrowser()
        await eventually { !bx.controller.state.browserNotice }
        await settle()
        XCTAssertTrue(bx.ports.browsed.isEmpty, "取消后不打开浏览器")
        XCTAssertTrue(bx.sink.events.isEmpty, "取消的步骤不上报")
    }

    func testBrowserStepOpensSystemBrowserAfterNotice() async {
        let rig = PurchaseHarness(card: TradeFixtures.card(key: "jd:cup", platform: "jd"))
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(steps: [["type": "h5", "value": "https://u.test/x"]])))
        await eventually { rig.controller.state.browserNotice }
        rig.sleeper.fire(OpenPurchaseController.browserNoticeMillis)
        await eventually { rig.ports.browsed == ["https://u.test/x"] }
        XCTAssertEqual(TJSON.string(rig.sink.events.first?["step"]), "h5")
        XCTAssertEqual(TJSON.string(rig.sink.events.first?["result"]), "launched")
    }

    func testJumpTipShownWhenUnreadAndMarkedReadOnContinue() async {
        let rig = PurchaseHarness()
        rig.api.auto = { call in
            switch call.operationId {
            case TradeOperations.getTips: TradeFixtures.ok(["jump_tip": ["jd": "x"]])
            case TradeOperations.markTipRead: TradeFixtures.ok([:])
            default: nil
            }
        }
        rig.ports.launchResults = [true]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { rig.controller.state.dialog == .jumpTip(platform: "taobao") }
        XCTAssertTrue(rig.ports.launched.isEmpty)
        rig.controller.confirm()
        await eventually { rig.ports.launched.count == 1 }
        await eventually { !rig.api.calls(TradeOperations.markTipRead).isEmpty }
        XCTAssertEqual(
            TradeFixtures.body(rig.api.calls(TradeOperations.markTipRead)[0])["platform"] as? String,
            "taobao"
        )
    }
}
