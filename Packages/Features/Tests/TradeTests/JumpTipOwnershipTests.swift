import CouliNetwork
import Foundation
@testable import Trade
import XCTest

/// APP-08 iOS 第三次定向复核 RC-06（S0）：购买流程的确认分支（改价、返利归零、比价、JumpTip、AuthSheet）在任何副作用之前先校验方案、
/// 尝试与固定来源；JumpTip 的已读缓存修改与 markTipRead 排队都在校验之后，已读请求带获取方案时固定的请求归属交网络层，发送前只比较。
@MainActor
final class JumpTipOwnershipTests: XCTestCase {
    /// 当前会话（测试里换账号 = 改这里）。
    private final class Session {
        var account = "user-A"
        var generation: UInt64 = 1

        var request: RequestOwnership {
            RequestOwnership(account: account, generation: generation, epoch: 0)
        }

        var origin: String {
            "\(account)#\(generation)"
        }

        func switchToB() {
            account = "user-B"
            generation += 1
        }
    }

    private func rig(_ session: Session) -> PurchaseHarness {
        let rig = PurchaseHarness(sessionKey: { session.account })
        rig.controller.jumpOrigin = { session.origin }
        rig.controller.jumpSource = { JumpSource(origin: session.origin, request: session.request) }
        rig.ports.installedValue = TradeConstants.installedUnknown
        rig.ports.launchResults = [true]
        rig.api.auto = { call in
            switch call.operationId {
            case TradeOperations.getTips: TradeFixtures.ok(["jump_tip": [String: String]()])
            case TradeOperations.markTipRead: TradeFixtures.ok([:])
            default: nil
            }
        }
        return rig
    }

    /// 购买 → 方案到达 → 停在 JumpTip（A 的会话里查过未读）。
    private func atJumpTip(_ rig: PurchaseHarness) async {
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open()))
        await eventually { rig.controller.state.dialog == .jumpTip(platform: "taobao") }
    }

    /// 评审场景：A 停在 JumpTip → 换成 B → 点旧弹窗【知道了，去X】：零 markTipRead、已读缓存不变（不重新绑定到 B）、不外跳，
    /// 提示重新点购买。
    func testConfirmOldJumpTipAfterAccountSwitchSendsNothingAndKeepsCache() async {
        let session = Session()
        let rig = rig(session)
        await atJumpTip(rig)
        let before = rig.controller.tips.cacheSnapshot
        XCTAssertEqual(before.owner, "user-A", "前提：缓存属于 A")
        XCTAssertEqual(before.read, [])

        session.switchToB()
        rig.controller.confirm()
        await settle()

        XCTAssertTrue(rig.api.calls(TradeOperations.markTipRead).isEmpty, "换账号后确认旧 JumpTip：零已读请求")
        XCTAssertEqual(rig.api.calls(TradeOperations.getTips).count, 1, "也不再查询")
        let after = rig.controller.tips.cacheSnapshot
        XCTAssertEqual(after.owner, "user-A", "缓存不重新绑定到 B")
        XCTAssertEqual(after.read, [], "缓存不记已读")
        XCTAssertTrue(rig.ports.launched.isEmpty, "旧方案不执行")
        XCTAssertNil(rig.controller.state.dialog)
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
    }

    /// 确认时仍是 A（校验通过、markTipRead 已排队），首发之前换成 B：零发送。
    func testAccountSwitchAfterConfirmBeforeFirstSendSendsNothing() async {
        let session = Session()
        let rig = rig(session)
        await atJumpTip(rig)
        rig.controller.confirm()
        // 排队的请求任务还没开始（同一主线程回合）就换账号
        session.switchToB()
        await settle()
        XCTAssertTrue(rig.api.calls(TradeOperations.markTipRead).isEmpty, "已排队、未发出的旧已读请求零发送")
    }

    /// 对照：不换账号照常记已读；getTips 与 markTipRead 都带获取方案时固定的请求归属。
    func testSameAccountConfirmSendsMarkReadWithFixedOwnership() async {
        let session = Session()
        let rig = rig(session)
        let fixed = session.request
        await atJumpTip(rig)
        rig.controller.confirm()
        await eventually { rig.api.calls(TradeOperations.markTipRead).count == 1 }
        XCTAssertEqual(rig.api.expected(TradeOperations.markTipRead), [fixed])
        XCTAssertEqual(rig.api.expected(TradeOperations.getTips), [fixed])
        XCTAssertEqual(rig.controller.tips.cacheSnapshot.read, ["taobao"])
        await eventually { rig.ports.launched.count == 1 }
    }

    /// 服务本身也只比较：固定归属的账号不是此刻会话 → 不改缓存、不排队请求。
    func testServiceMarkReadWithForeignOwnershipIsNoop() async {
        let api = FakeTradeApi()
        let tips = JumpTipService(api: api) { "user-B" }
        tips.markRead("taobao", expected: RequestOwnership(account: "user-A", generation: 1, epoch: 0))
        await settle()
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertNil(tips.cacheSnapshot.owner)
        XCTAssertNil(tips.cacheSnapshot.read)
    }

    /// 改价确认同样：换账号后点【继续购买】在发许可、查 JumpTip 之前作废（零 getTips）。
    func testConfirmPriceAfterAccountSwitchSendsNoTipsQuery() async {
        let session = Session()
        let rig = rig(session)
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(
            0,
            TradeFixtures.ok(TradeFixtures.open(extra: ["price_changed": true, "new_final_price_fen": 4990]))
        )
        await eventually { rig.controller.state.dialog != nil }
        session.switchToB()
        rig.controller.confirm()
        await settle()
        XCTAssertTrue(rig.api.calls(TradeOperations.getTips).isEmpty)
        XCTAssertTrue(rig.ports.launched.isEmpty)
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
    }

    /// AuthSheet：换账号后点旧弹窗【去授权】→ 不拉起授权、不发任何授权请求，删本页这次的授权待办，提示重新点购买。
    func testAuthorizeOldAuthSheetAfterAccountSwitchSendsNothing() async {
        let session = Session()
        let rig = rig(session)
        let authData: TradeObject = [
            "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"],
        ]
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30101, authData))
        await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
        XCTAssertNotNil(rig.pending.peek(), "前提：登记了授权待办")
        session.switchToB()
        rig.controller.authorize()
        await settle()
        XCTAssertEqual(rig.webCode.calls, 0, "不拉起授权")
        XCTAssertTrue(rig.api.calls(TradeOperations.bindUnion).isEmpty)
        XCTAssertTrue(rig.api.calls(TradeOperations.getUnionAuthUrl).isEmpty)
        XCTAssertTrue(rig.api.calls(TradeOperations.listUnionBindings).isEmpty)
        XCTAssertEqual(rig.opens().count, 1, "不自动 open")
        XCTAssertNil(rig.pending.peek(), "旧授权待办删除")
        XCTAssertNil(rig.controller.state.dialog)
        XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
    }

    /// 超时条【重试】重放原尝试（原键）：换账号之后不以新会话重放旧尝试，零 open，提示重新点购买；不换账号照常同键重放。
    func testTimeoutRetryAfterAccountSwitchDoesNotReplay() async {
        for swap in [false, true] {
            let session = Session()
            let rig = rig(session)
            rig.controller.buy(rig.env.card, spm: nil)
            await eventually { rig.opens().count == 1 }
            rig.sleeper.fire(OpenPurchaseController.timeoutMillis)
            await eventually { rig.controller.state.phase == .timeout }
            if swap {
                session.switchToB()
            }
            rig.controller.retryAfterTimeout()
            await settle()
            if swap {
                XCTAssertEqual(rig.opens().count, 1, "换账号后不重放旧尝试")
                XCTAssertEqual(rig.controller.state.phase, .idle)
                XCTAssertEqual(rig.controller.state.toast?.key, PurchaseTextKeys.jumpExpired)
            } else {
                XCTAssertEqual(rig.opens().count, 2, "对照：同账号照常重放")
                XCTAssertEqual(rig.opens()[1].idempotencyKey, rig.opens()[0].idempotencyKey)
            }
        }
    }
}
