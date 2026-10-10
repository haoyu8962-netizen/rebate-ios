import CouliNetwork
import Foundation
import ProductSearch
@testable import Purchase
@testable import Trade
import TradeJump
import XCTest

/// APP-08 iOS 第七次修复 NEW-02 残余（S1，APP-09 共性第 63 条）：购买浮层上**全部**按钮回调都在渲染时绑定弹窗实例票据
/// （加载层、浏览器提示另有各自的编号）。保留真实页面（PurchaseOverlay）在 A 的弹窗上渲染出的整组回调，关掉弹窗、换号、由 B 的新点击
/// 弹出**同一种**弹窗之后，逐个执行全部旧回调（确认 / JumpTip 确认 / 比价无返利、取消 / 关闭、授权查询【重试】、【去授权】、
/// 【重试】、【仍去购买（无返利）】、【联系客服】、【查看说明】、【看看相似商品】、加载层【取消】、浏览器提示【取消】）：
/// 零请求、零外跳、零页面跳转，B 的弹窗、票据、许可与 JumpTip 已读缓存都不变。对照：新渲染的回调照常生效。
private struct R3gTexts: SearchTexts {
    func text(_ key: String) -> String {
        key
    }

    func format(_ key: String, _: [String: String]) -> String {
        key
    }
}

private final class R3gSession {
    var account = "user-A"
    var generation: UInt64 = 1

    var origin: String {
        "\(account)#\(generation)"
    }

    var request: RequestOwnership {
        RequestOwnership(account: account, generation: generation, epoch: 0)
    }

    func switchToB() {
        account = "user-B"
        generation += 1
    }
}

private enum R3gKind: CaseIterable {
    case authSheet
    case authDeclined
    case authCheckFailed
    case jumpTip
    case confirmPrice
    case compareNoRebate
    case notice50303
}

@MainActor
final class DialogTicketR3gTests: XCTestCase {
    private let authData: TradeObject = [
        "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"],
    ]

    private func rig(_ session: R3gSession, kind: R3gKind) -> PurchaseHarness {
        let card = kind == .compareNoRebate ? TradeFixtures.card(key: "pdd:x", platform: "pdd") : TradeFixtures.card()
        let rig = PurchaseHarness(card: card, sessionKey: { session.account })
        rig.controller.jumpOrigin = { session.origin }
        rig.controller.jumpSource = { JumpSource(origin: session.origin, request: session.request) }
        rig.ports.launchResults = [true, true, true]
        rig.api.auto = { call in
            switch call.operationId {
            // 空表 = 未读：方案到达后弹 JumpTip（只有 jumpTip 这一类走到方案执行）
            case TradeOperations.getTips: TradeFixtures.ok(["jump_tip": [String: String]()])
            case TradeOperations.markTipRead: TradeFixtures.ok([:])
            // 绑定服务端故障 → 授权结果查不到（authCheckFailed，afterBind）
            case TradeOperations.bindUnion: TradeFixtures.fail(50001)
            case TradeOperations.listUnionBindings: TradeFixtures.fail(50001)
            default: nil
            }
        }
        return rig
    }

    /// 由一次新点击走到 `kind` 弹窗（当前会话的来源）。
    private func reach(_ kind: R3gKind, _ rig: PurchaseHarness) async {
        let index = rig.opens().count
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually("\(kind)：open 发出") { rig.opens().count == index + 1 }
        switch kind {
        case .authSheet, .authDeclined, .authCheckFailed:
            rig.replyOpen(index, TradeFixtures.fail(30101, authData))
            await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
            if kind == .authDeclined {
                rig.controller.dismissDialog()
            } else if kind == .authCheckFailed {
                rig.controller.authorize()
                await eventually("\(kind)：停在授权结果查不到") {
                    if case .authCheckFailed = rig.controller.state.dialog {
                        return true
                    }
                    return false
                }
            }
        case .jumpTip:
            rig.replyOpen(index, TradeFixtures.ok(TradeFixtures.open()))
            await eventually("\(kind)：停在 JumpTip") { rig.controller.state.dialog == .jumpTip(platform: "taobao") }
        case .confirmPrice:
            rig.replyOpen(index, TradeFixtures.ok(TradeFixtures.open(extra: [
                "price_changed": true, "new_final_price_fen": 4990,
            ])))
            await eventually("\(kind)：停在改价确认") {
                if case .confirmPrice = rig.controller.state.dialog {
                    return true
                }
                return false
            }
        case .compareNoRebate:
            rig.replyOpen(index, TradeFixtures.ok(TradeFixtures.open(extra: [
                "new_rebate_min_fen": 0, "new_rebate_max_fen": 0, "no_rebate_cause": "price_compare",
            ])))
            await eventually("\(kind)：停在比价") { rig.controller.state.dialog == .compareNoRebate }
        case .notice50303:
            rig.replyOpen(index, TradeFixtures.fail(50303))
            await eventually("\(kind)：停在 50303 提示") {
                if case .notice = rig.controller.state.dialog {
                    return true
                }
                return false
            }
        }
    }

    /// 可观察的全部效果：请求、外跳、页面跳转、弹窗与票据、阶段、提示、许可、JumpTip 已读缓存、待办。
    private struct Effects: Equatable {
        let calls: [String]
        let launched: Int
        let browsed: Int
        let copied: Int
        let opened: [String]
        let dialog: String
        let ticket: PurchaseDialogTicket?
        let phase: String
        let toast: String?
        let permitted: Bool
        let tipsRead: [String]
        let pending: Bool
    }

    private func effects(_ rig: PurchaseHarness) -> Effects {
        let state = rig.controller.state
        return Effects(
            calls: rig.api.calls.map(\.operationId),
            launched: rig.ports.launched.count,
            browsed: rig.ports.browsed.count,
            copied: rig.ports.copied.count,
            opened: rig.env.opened.map(\.0),
            dialog: String(describing: state.dialog),
            ticket: state.dialogTicket,
            phase: String(describing: state.phase),
            toast: state.toast?.key,
            permitted: rig.controller.permit != nil,
            tipsRead: (rig.controller.tips.cacheSnapshot.read ?? []).sorted(),
            pending: rig.pending.peek() != nil
        )
    }

    private func runAll(_ actions: PurchaseDialogActions) {
        actions.recheck()
        actions.confirm()
        actions.authorize()
        actions.retry()
        actions.noRebate()
        actions.contact()
        actions.explain()
        actions.similar()
        actions.cancelLoading()
        actions.cancelBrowser()
        actions.dismiss()
    }

    /// 每一类弹窗：A 渲染的整组旧回调在 B 的同类新弹窗出现之后执行——零效果。
    func testEveryOldCallbackAfterSameKindReplacementHasNoEffect() async {
        for kind in R3gKind.allCases {
            let session = R3gSession()
            let rig = rig(session, kind: kind)
            let overlay = PurchaseOverlay(controller: rig.controller, texts: R3gTexts())
            await reach(kind, rig)
            let old = overlay.overlayActions()
            // 关掉 A 的弹窗（新渲染的回调），换号，由 B 的新点击弹出同一种弹窗
            while rig.controller.state.dialog != nil {
                overlay.overlayActions().dismiss()
            }
            await settle()
            session.switchToB()
            await reach(kind, rig)
            await settle()
            let before = effects(rig)

            runAll(old)
            await settle()

            XCTAssertEqual(effects(rig), before, "\(kind)：旧回调在 B 的新弹窗出现后执行，零效果")
        }
    }

    /// 评审场景：A 的授权查询失败弹窗【重试】回调保留到 B 的同类弹窗出现之后执行——零 listUnionBindings，B 的弹窗不动。
    /// 对照：B 弹窗新渲染的【重试】照常重新查询（带 B 的固定归属）。
    func testOldRecheckAfterNewAuthCheckFailedSendsNoQuery() async {
        let session = R3gSession()
        let rig = rig(session, kind: .authCheckFailed)
        let overlay = PurchaseOverlay(controller: rig.controller, texts: R3gTexts())
        await reach(.authCheckFailed, rig)
        let oldRecheck = overlay.overlayActions().recheck
        overlay.overlayActions().dismiss()
        session.switchToB()
        await reach(.authCheckFailed, rig)
        let shown = rig.controller.state.dialog
        let queries = rig.api.calls(TradeOperations.listUnionBindings).count

        oldRecheck()
        await settle()
        XCTAssertEqual(rig.api.calls(TradeOperations.listUnionBindings).count, queries, "旧【重试】零查询")
        XCTAssertEqual(rig.controller.state.dialog, shown, "旧【重试】不动 B 的弹窗")

        overlay.overlayActions().recheck()
        await eventually { rig.api.calls(TradeOperations.listUnionBindings).count == queries + 1 }
        XCTAssertEqual(rig.api.expected(TradeOperations.listUnionBindings).last, session.request, "新回调带 B 的固定归属")
    }

    /// JumpTip：A 的【知道了，去X】回调在 B 的 JumpTip 出现后执行——零已读、零外跳、已读缓存不变。对照：新回调记已读并外跳。
    func testOldJumpTipConfirmAfterNewJumpTipHasNoEffect() async {
        let session = R3gSession()
        let rig = rig(session, kind: .jumpTip)
        let overlay = PurchaseOverlay(controller: rig.controller, texts: R3gTexts())
        await reach(.jumpTip, rig)
        let oldConfirm = overlay.overlayActions().confirm
        overlay.overlayActions().dismiss()
        session.switchToB()
        await reach(.jumpTip, rig)

        oldConfirm()
        await settle()
        XCTAssertTrue(rig.api.calls(TradeOperations.markTipRead).isEmpty, "旧确认：零已读请求")
        XCTAssertTrue(rig.ports.launched.isEmpty, "旧确认：零外跳")
        XCTAssertEqual(rig.controller.state.dialog, .jumpTip(platform: "taobao"), "B 的 JumpTip 不动")

        overlay.overlayActions().confirm()
        await eventually { rig.ports.launched.count == 1 }
        XCTAssertEqual(rig.api.calls(TradeOperations.markTipRead).count, 1)
    }

    /// AuthSheet：A 的【去授权】回调在 B 的 AuthSheet 出现后执行——零授权、B 的弹窗仍可点。对照：新回调照常拉起授权。
    func testOldAuthorizeAfterNewAuthSheetHasNoEffect() async {
        let session = R3gSession()
        let rig = rig(session, kind: .authSheet)
        let overlay = PurchaseOverlay(controller: rig.controller, texts: R3gTexts())
        await reach(.authSheet, rig)
        let oldAuthorize = overlay.overlayActions().authorize
        overlay.overlayActions().dismiss()
        overlay.overlayActions().dismiss()
        session.switchToB()
        await reach(.authSheet, rig)

        oldAuthorize()
        await settle()
        XCTAssertEqual(rig.webCode.calls, 0, "旧【去授权】：零授权")
        XCTAssertEqual(rig.controller.state.dialog, .authSheet(platform: "taobao", busy: false))

        overlay.overlayActions().authorize()
        await eventually { rig.webCode.calls == 1 }
    }

    /// 加载层：A 的加载层【取消】回调在 B 的新加载开始后执行——B 的加载不受影响。对照：新回调照常取消。
    func testOldLoadingCancelAfterNewLoadingHasNoEffect() async {
        let session = R3gSession()
        let rig = rig(session, kind: .notice50303)
        let overlay = PurchaseOverlay(controller: rig.controller, texts: R3gTexts())
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        XCTAssertEqual(rig.controller.state.phase, .loading)
        let oldCancel = overlay.overlayActions().cancelLoading
        rig.replyOpen(0, TradeFixtures.fail(50303))
        await eventually { rig.controller.state.dialog != nil }
        overlay.overlayActions().dismiss()
        session.switchToB()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        XCTAssertEqual(rig.controller.state.phase, .loading)

        oldCancel()
        XCTAssertEqual(rig.controller.state.phase, .loading, "旧【取消】不取消 B 的加载")
        XCTAssertNotNil(rig.controller.permit)

        overlay.overlayActions().cancelLoading()
        XCTAssertEqual(rig.controller.state.phase, .idle)
    }

    /// 超时条（详情 / 搜索页底，渲染时捕获加载编号）：A 的超时条【重试】回调在 B 的新超时出现后执行——零 open。对照：新回调照常重放。
    func testOldTimeoutRetryAfterNewTimeoutSendsNothing() async {
        let session = R3gSession()
        let rig = rig(session, kind: .notice50303)
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.sleeper.fire(OpenPurchaseController.timeoutMillis)
        await eventually { rig.controller.state.phase == .timeout }
        let oldTicket = rig.controller.state.loadingTicket
        session.switchToB()
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        rig.sleeper.fire(OpenPurchaseController.timeoutMillis)
        await eventually { rig.controller.state.phase == .timeout && rig.controller.state.loadingTicket != oldTicket }

        rig.controller.retryAfterTimeout(oldTicket)
        await settle()
        XCTAssertEqual(rig.opens().count, 2, "旧超时条【重试】：零 open")
        XCTAssertEqual(rig.controller.state.phase, .timeout)

        rig.controller.retryAfterTimeout(rig.controller.state.loadingTicket)
        await eventually { rig.opens().count == 3 }
    }
}
