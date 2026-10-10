import CouliNetwork
import Foundation
import ProductSearch
@testable import Purchase
@testable import Trade
import TradeJump
import XCTest

/// APP-08 iOS 第八次修复 NEW-02（S1）：浏览器提示的旧【取消】回调在真实场景下验收（r3g 的整组旧回调测试没有进入浏览器提示，
/// 捕获的提示编号为 nil，等于空跑）。实际进入 A 的「将通过浏览器打开」提示，保存 PurchaseOverlay 渲染出的【取消】回调；
/// A 结束、换号、进入 B 的新提示之后执行旧回调——B 的提示、等待与到点后的外跳都不受影响。对照：新渲染的【取消】照常取消。
private struct R3hTexts: SearchTexts {
    func text(_ key: String) -> String {
        key
    }

    func format(_ key: String, _: [String: String]) -> String {
        key
    }
}

private final class R3hSession {
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

@MainActor
final class BrowserCancelTicketR3hTests: XCTestCase {
    private static let browserA = "https://u.test/a"
    private static let browserB = "https://u.test/b"

    /// 京东卡片、h5 方案：方案到达后经「将通过浏览器打开」提示再打开系统浏览器（已读 JumpTip，不弹 JumpTip）。
    private func browserRig(_ session: R3hSession) -> PurchaseHarness {
        let card = TradeFixtures.card(key: "jd:cup", platform: "jd")
        let rig = PurchaseHarness(card: card, sessionKey: { session.account })
        rig.controller.jumpOrigin = { session.origin }
        rig.controller.jumpSource = { JumpSource(origin: session.origin, request: session.request) }
        rig.api.auto = { call in
            call.operationId == TradeOperations.getTips ? TradeFixtures.ok(["jump_tip": ["jd": "x"]]) : nil
        }
        return rig
    }

    /// 由一次新点击走到浏览器提示（open 回 h5 方案），返回这次提示的编号。
    private func reachBrowserNotice(_ rig: PurchaseHarness, url: String) async -> UInt64? {
        let index = rig.opens().count
        rig.controller.buy(rig.env.card, spm: nil)
        await eventually("open 发出") { rig.opens().count == index + 1 }
        let previous = rig.controller.state.browserTicket
        rig.replyOpen(index, TradeFixtures.ok(TradeFixtures.open(steps: [["type": "h5", "value": url]])))
        await eventually("停在浏览器提示") {
            rig.controller.state.browserNotice && rig.controller.state.browserTicket != previous
        }
        return rig.controller.state.browserTicket
    }

    /// 评审场景：实际进入 A 的浏览器提示，保存页面（PurchaseOverlay）渲染出的【取消】回调；A 的提示结束（等待到点、打开浏览器），
    /// 换号，进入 B 的新提示后执行旧回调——B 的提示与等待不受影响，到点照常打开 B 的浏览器。
    func testOldBrowserCancelAfterNewBrowserNoticeHasNoEffect() async {
        let session = R3hSession()
        let rig = browserRig(session)
        let overlay = PurchaseOverlay(controller: rig.controller, texts: R3hTexts())
        let ticketA = await reachBrowserNotice(rig, url: Self.browserA)
        XCTAssertNotNil(ticketA, "前提：A 的浏览器提示已出现")
        let oldCancel = overlay.overlayActions().cancelBrowser
        // 结束 A：提示等待到点，打开 A 的浏览器
        rig.sleeper.fire(OpenPurchaseController.browserNoticeMillis)
        await eventually("A 打开浏览器") { rig.ports.browsed == [Self.browserA] }
        await eventually { !rig.controller.state.browserNotice }
        await settle()

        session.switchToB()
        let ticketB = await reachBrowserNotice(rig, url: Self.browserB)
        XCTAssertNotEqual(ticketB, ticketA, "前提：B 是新的一次提示")
        XCTAssertGreaterThan(rig.sleeper.waitingCount, 0, "前提：B 的提示正在等待")

        oldCancel()
        await settle()
        XCTAssertTrue(rig.controller.state.browserNotice, "旧【取消】不取消 B 的提示")
        XCTAssertEqual(rig.controller.state.browserTicket, ticketB)
        XCTAssertEqual(rig.ports.browsed, [Self.browserA], "旧【取消】之后 B 仍在等待，未提前外跳")

        // B 的等待到点：照常打开 B 的浏览器
        rig.sleeper.fire(OpenPurchaseController.browserNoticeMillis)
        await eventually("B 照常打开浏览器") { rig.ports.browsed == [Self.browserA, Self.browserB] }
        XCTAssertFalse(rig.controller.state.browserNotice)
    }

    /// 对照：B 的提示上新渲染的【取消】照常取消——提示收起，到点也不打开浏览器。
    func testNewBrowserCancelCancelsCurrentNotice() async {
        let session = R3hSession()
        let rig = browserRig(session)
        let overlay = PurchaseOverlay(controller: rig.controller, texts: R3hTexts())
        _ = await reachBrowserNotice(rig, url: Self.browserA)
        overlay.overlayActions().cancelBrowser()
        await eventually("提示收起") { !rig.controller.state.browserNotice }
        rig.sleeper.fire(OpenPurchaseController.browserNoticeMillis)
        await settle()
        XCTAssertTrue(rig.ports.browsed.isEmpty, "新回调取消后不打开浏览器")

        session.switchToB()
        _ = await reachBrowserNotice(rig, url: Self.browserB)
        overlay.overlayActions().cancelBrowser()
        await eventually("B 的提示收起") { !rig.controller.state.browserNotice }
        rig.sleeper.fire(OpenPurchaseController.browserNoticeMillis)
        await settle()
        XCTAssertTrue(rig.ports.browsed.isEmpty, "B 上新渲染的【取消】同样生效")
    }
}
