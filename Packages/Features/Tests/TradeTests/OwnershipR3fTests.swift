import CouliNetwork
import Foundation
import ProductSearch
@testable import Purchase
@testable import Trade
import TradeJump
import XCTest

/// APP-08 iOS 第六次修复：
/// - NEW-03（S0）：购买派生的商品补齐（价格补齐、30144 重新加载）带这次尝试的固定请求归属交页面执行器；补齐结果合并前再比较来源，
///   来源变了零展示；
/// - NEW-04（S0）：授权管理页换号后返回清空 A 的状态；listUnionBindings、auth-url 的迟到响应零展示、零外跳；
/// - NEW-02（S1）：弹窗按钮回调在渲染时捕获弹窗票据。保留真实页面（PurchaseOverlay）的旧回调，换号并由新点击弹出 B 的弹窗之后再执行：
///   零发送，新弹窗不动；新渲染的回调照常发出。
@MainActor
final class OwnershipR3fTests: XCTestCase {
    private let ownerA = RequestOwnership(account: "user-a", generation: 1, epoch: 0)
    private let ownerB = RequestOwnership(account: "user-b", generation: 2, epoch: 0)

    private struct Texts: SearchTexts {
        func text(_ key: String) -> String {
            key
        }

        func format(_ key: String, _: [String: String]) -> String {
            key
        }
    }

    /// 来源随 `origin` 盒子变（换号 = 改盒子）；请求归属随来源一次给出。
    private func rig(origin: Locked<String>) -> PurchaseHarness {
        let rig = PurchaseHarness()
        let ownerA = ownerA
        let ownerB = ownerB
        rig.controller.jumpOrigin = { origin.get() }
        rig.controller.jumpSource = {
            let now = origin.get()
            return JumpSource(origin: now, request: now.hasPrefix("user-a") ? ownerA : ownerB)
        }
        return rig
    }

    // MARK: - NEW-03 购买派生的补齐

    /// 价格补齐：带 A 尝试的固定归属；换号之后到达的补齐结果不落到页面（零展示）。对照：未换号时照常补齐。
    func testPriceFillCarriesSourceAndDropsAfterSwap() async {
        for swap in [false, true] {
            let origin = Locked("user-a#1#0")
            let rig = rig(origin: origin)
            rig.controller.buy(rig.env.card, spm: nil)
            await eventually { rig.opens().count == 1 }
            rig.replyOpen(0, TradeFixtures.ok(TradeFixtures.open(extra: [
                "price_changed": true, "new_final_price_fen": 4990, "new_link_id": "L2",
            ])))
            await eventually { rig.env.refetches.count == 1 }
            XCTAssertEqual(rig.env.refetchRequests, [ownerA], "补齐带 A 尝试的固定归属")
            if swap {
                origin.set("user-b#2#0")
            }
            let before = rig.env.card
            let merged = rig.env.refetches[0].1(before, TradeFixtures.card(final: 4990))
            if swap {
                XCTAssertTrue(merged["coupon_fen"] is NSNull, "换号后补齐结果零展示")
                XCTAssertTrue(rig.controller.card["coupon_fen"] is NSNull, "执行器也不记下")
            } else {
                XCTAssertEqual(TJSON.fen(merged["coupon_fen"]), 1000, "对照：同身份照常补齐")
            }
        }
    }

    /// 30144 重新加载：带 A 尝试的固定归属；换号之后到达的整卡不替换。对照：未换号时替换。
    func testRefExpiredReloadCarriesSourceAndDropsAfterSwap() async {
        for swap in [false, true] {
            let origin = Locked("user-a#1#0")
            let rig = rig(origin: origin)
            rig.controller.buy(rig.env.card, spm: nil)
            await eventually { rig.opens().count == 1 }
            rig.replyOpen(0, TradeFixtures.fail(30144))
            await eventually { rig.env.refetches.count == 1 }
            XCTAssertEqual(rig.env.refetchRequests, [ownerA], "30144 重新加载带 A 尝试的固定归属")
            if swap {
                origin.set("user-b#2#0")
            }
            let merged = rig.env.refetches[0].1(rig.env.card, TradeFixtures.card(link: "L3"))
            XCTAssertEqual(TJSON.string(merged["link_id"]), swap ? "L1" : "L3", swap ? "换号后零展示" : "对照：照常替换")
        }
    }

    // MARK: - NEW-04 授权管理页

    private struct ManageRig {
        let controller: AuthManageController
        let ports: FakePorts
        let webCode: FakeWebCode
    }

    private func manage(_ api: FakeTradeApi, owned: Locked<Bool>) -> ManageRig {
        let ports = FakePorts()
        let webCode = FakeWebCode()
        let controller = AuthManageController(
            api: api, executor: TradeJumpExecutor(ports: ports, baichuan: UnavailableBaichuan(), sink: FakeSink()),
            ports: ports, webCode: webCode, baichuan: UnavailableBaichuan(), ownership: ownerA,
            stillOwned: { owned.get() }
        )
        return ManageRig(controller: controller, ports: ports, webCode: webCode)
    }

    /// 换号后返回：A 的授权状态清空，页面作废、之后零发送。
    func testManageSwapThenReturnClearsOldState() async {
        let api = FakeTradeApi()
        api.auto = { call in
            call.operationId == TradeOperations.listUnionBindings
                ? TradeFixtures.ok(["items": [["platform": "taobao", "status": "active"]]]) : nil
        }
        let owned = Locked(true)
        let controller = manage(api, owned: owned).controller
        controller.load()
        await eventually { controller.state.phase == .content }
        XCTAssertEqual(controller.state.rows.first?.authorized, true, "前提：显示着 A 的授权状态")
        owned.set(false)
        controller.onBackground()
        controller.onForeground()
        XCTAssertTrue(controller.state.rows.isEmpty, "换号后返回：A 的授权状态被清除")
        XCTAssertEqual(controller.state.phase, .error)
        XCTAssertTrue(controller.revoked)
        let sent = api.calls.count
        controller.load()
        controller.authorize("taobao")
        await settle()
        XCTAssertEqual(api.calls.count, sent, "作废后零发送")
    }

    /// listUnionBindings 已发出、换号后才返回：零展示（页面不写入 A 的结果）。
    func testLateListBindingsAfterSwapShowsNothing() async {
        let api = FakeTradeApi()
        let owned = Locked(true)
        let controller = manage(api, owned: owned).controller
        controller.load()
        await eventually { api.calls(TradeOperations.listUnionBindings).count == 1 }
        owned.set(false)
        api.reply(
            api.index(of: TradeOperations.listUnionBindings) ?? 0,
            TradeFixtures.ok(["items": [["platform": "taobao", "status": "active"]]])
        )
        await settle()
        XCTAssertTrue(controller.state.rows.isEmpty, "迟到响应零展示")
        XCTAssertNotEqual(controller.state.phase, .content)
    }

    /// auth-url 已发出、换号后才返回成功：零外跳（淘宝不拉起 web_code 授权，拼多多不执行授权跳转）。
    func testLateAuthUrlAfterSwapNoJump() async {
        for platform in ["taobao", "pdd"] {
            let api = FakeTradeApi()
            api.auto = { call in
                call.operationId == TradeOperations.listUnionBindings
                    ? TradeFixtures.ok(["items": [["platform": platform, "status": "unbound"]]]) : nil
            }
            let owned = Locked(true)
            let manageRig = manage(api, owned: owned)
            let (controller, ports, webCode) = (manageRig.controller, manageRig.ports, manageRig.webCode)
            controller.load()
            await eventually { controller.state.phase == .content }
            controller.authorize(platform)
            await eventually { api.calls(TradeOperations.getUnionAuthUrl).count == 1 }
            owned.set(false)
            let data: TradeObject = platform == "taobao"
                ? ["auth_url": "https://o.test", "state": "s", "auth_methods": ["web_code"]]
                : ["auth_jump": [
                    "primary": ["type": "universal_link", "value": "https://auth.test/p"], "fallbacks": [],
                    "expire_at": TradeFixtures.future(),
                ]]
            api.reply(api.index(of: TradeOperations.getUnionAuthUrl) ?? 0, TradeFixtures.ok(data))
            await settle()
            XCTAssertEqual(webCode.calls, 0, "\(platform)：迟到 auth-url 零授权拉起")
            XCTAssertTrue(ports.launched.isEmpty && ports.browsed.isEmpty, "\(platform)：迟到 auth-url 零外跳")
            XCTAssertTrue(api.calls(TradeOperations.bindUnion).isEmpty, "\(platform)：零绑定")
            XCTAssertTrue(controller.state.rows.isEmpty, "\(platform)：A 的状态已清除")
        }
    }

    // MARK: - NEW-02 弹窗票据

    /// 保留真实页面的旧弹窗回调：A 的二选一弹窗渲染时取得回调；关掉、换号、由新点击弹出 B 的 50303 弹窗后再执行旧回调——零发送，
    /// B 的弹窗不动。对照：B 弹窗新渲染的回调照常发出新 open。
    func testOldRenderedDialogCallbacksAfterNewDialogSendNothing() async {
        let origin = Locked("user-a#1#0")
        let rig = rig(origin: origin)
        rig.api.auto = { call in
            call.operationId == TradeOperations.getTips
                ? TradeFixtures.ok(["jump_tip": ["taobao": "x"]]) : nil
        }
        let overlay = PurchaseOverlay(controller: rig.controller, texts: Texts())
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 1 }
        rig.replyOpen(0, TradeFixtures.fail(30101, [
            "auth_url": "https://oauth.test/a?state=st1", "state": "st1", "auth_methods": ["web_code"],
        ]))
        await eventually { rig.controller.state.dialog == .authSheet(platform: "taobao", busy: false) }
        rig.controller.dismissDialog()
        XCTAssertEqual(rig.controller.state.dialog, .authDeclined(platform: "taobao", failed: false))
        // A 弹窗渲染时的回调（真实页面的回调工厂）
        let oldActions = overlay.overlayActions()
        rig.controller.dismissDialog()
        // 换号，新点击弹出 B 的 50303 弹窗
        origin.set("user-b#2#0")
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually { rig.opens().count == 2 }
        rig.replyOpen(1, TradeFixtures.fail(50303))
        await eventually {
            if case .notice(_, _, true, _, true) = rig.controller.state.dialog {
                return true
            }
            return false
        }
        let shown = rig.controller.state.dialog
        oldActions.retry()
        oldActions.noRebate()
        await settle()
        XCTAssertEqual(rig.opens().count, 2, "旧回调在新弹窗出现后执行：零发送")
        XCTAssertEqual(rig.controller.state.dialog, shown, "旧回调不操作新弹窗")
        // 对照：新渲染的回调照常发出（沿用 B 弹窗的固定来源）
        overlay.overlayActions().retry()
        await eventually { rig.opens().count == 3 }
    }
}
