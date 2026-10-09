import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-06b 共性第 48 条（iOS 第 3 轮评审 I-R3-01）：页面的延迟恢复（授权、登录、补同意）按类型分槽，回前台时逐类分派；普通令牌刷新
/// 通知（App 收到 sessionVersion 变化即调 `resumeAfterLogin`）不得覆盖已排队的授权恢复，各类恢复仍各自正常。
@MainActor
final class LessonsRound5Tests: XCTestCase {
    private let pddPlan: TradeObject = [
        "primary": ["type": "universal_link", "value": "https://auth.test/p"], "fallbacks": [],
        "expire_at": TradeFixtures.future(),
    ]

    /// 拼多多授权回来、查询途中又进后台 → 查询返回 active：授权恢复排队等回前台。
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
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["kind"]), "auth")
        return rig
    }

    func testSessionRefreshDoesNotOverrideQueuedAuthResume() async {
        let rig = await authorizedWhileInBackground()
        // 另一在途请求的普通令牌刷新成功：App 收到 sessionRefreshed → sessionVersion 变化，对各页调 resumeAfterLogin
        rig.controller.resumeAfterLogin()
        rig.controller.resumeAfterLogin()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "后台不执行")
        rig.pendingClock.now += MemoryPurchasePending.ttlMillis - 60000
        rig.controller.onForeground()
        await eventually { rig.opens().count == 2 }
        guard rig.opens().count == 2 else { return XCTFail("授权恢复被覆盖：回前台没有自动 open") }
        XCTAssertEqual(rig.opens()[1].pathParams["link_id"], "LA")
        XCTAssertNotNil(rig.opens()[1].idempotencyKey)
        XCTAssertNotEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey, "授权后是新键")
        XCTAssertNil(rig.pending.peek(), "执行前消费一次")
        rig.controller.resumeAfterLogin()
        rig.controller.onBackground()
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 2, "只执行一次")
    }

    func testLoginResumeStillWorksWithConsentNotificationQueued() async {
        let rig = PurchaseHarness()
        rig.env.isLoggedIn = false
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(10001))
        await eventually { rig.env.opened.last?.0 == "Login" }
        rig.controller.onBackground()
        rig.env.isLoggedIn = true
        rig.controller.resumeAfterLogin()
        rig.controller.resumeAfterConsent()
        await settle()
        XCTAssertEqual(rig.opens().count, 1, "登录页还盖着：等回到前台")
        rig.controller.onForeground()
        await eventually { rig.opens().count == 2 }
        guard rig.opens().count == 2 else { return XCTFail("登录恢复没有执行") }
        XCTAssertEqual(rig.opens()[1].idempotencyKey, "key-1", "登录后沿用原键重放")
        XCTAssertNil(rig.pending.peek(), "只执行一次")
        rig.controller.onBackground()
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 2)
    }

    func testConsentResumeStillWorksWithSessionRefreshQueued() async {
        let rig = PurchaseHarness()
        rig.env.isBasic = true
        rig.controller.buy(rig.env.card, spm: nil)
        await settle()
        XCTAssertEqual(TJSON.string(rig.pending.peek()?["kind"]), "consent")
        rig.controller.onBackground()
        rig.env.isBasic = false
        rig.controller.resumeAfterConsent()
        rig.controller.resumeAfterLogin()
        await settle()
        XCTAssertTrue(rig.opens().isEmpty, "不在前台：等回前台")
        rig.controller.onForeground()
        await eventually { rig.opens().count == 1 }
        guard rig.opens().count == 1 else { return XCTFail("补同意恢复没有执行") }
        XCTAssertEqual(rig.opens()[0].pathParams["link_id"], "L1", "原点击的 link_id")
        XCTAssertNil(rig.pending.peek(), "只执行一次")
        rig.controller.onBackground()
        rig.controller.onForeground()
        await settle()
        XCTAssertEqual(rig.opens().count, 1)
    }
}
