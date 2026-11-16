@testable import Couli
import Foundation
import Me
import MeCore
import SwiftUI
import XCTest

/// FU-IOS-PERSONALIZATION-CONSENT-ROLLBACK 续（评审 r2 S2-A）：跨页面时开关值不过期、回滚写「切换前本机生效的值」。
/// - 回滚写 `toggle.previous`（切换前 `!deps.local.personalizationOffNow`），不是 `!toggle.on`，也不是本页可能过期的状态；
/// - 一条同意记录结束（`MePersonalizationSync.settled` 加一）后，挂着的其他隐私中心页面经 `.onChange` 调 `syncPersonalization()`
///   按本机生效值重读开关。
/// 「另一个页面」是同身份另建的生产 `PrivacyCenterController`（同 `deps`，即同一个应用级同步状态）。搭建见 `FuIosPersonalizationConsentTestCase`。
@MainActor
final class FuIosPersonalizationCrossPageTests: FuIosPersonalizationConsentTestCase {
    private func otherPage(_ fixture: MeAppFixture, like page: PrivacyCenterController) -> PrivacyCenterController {
        PrivacyCenterController(deps: fixture.me.deps, identity: page.identity, page: nil, forceUpdate: false)
    }

    private func fail(_ id: Int) {
        WalletStubProtocol.release(id, with: .envelope(code: 50001, data: "null", headers: [:]))
    }

    /// 本机「开、时刻 1」→ P1 切「关」在途 → 另建 P2（按本机显示「关」）→ P1 失败，本机回滚「开、1」→ P2 调 `syncPersonalization()` 后为「开」；
    /// 随后 P2 切「关」再失败 → 回滚到「开」、时刻写回 1。删掉 `syncPersonalization()` 里的重读会红（P2 停在「关」）；回滚时刻不写
    /// `toggle.previousAt` 会红。
    func testSyncThenToggleFromOtherPageRollsBackToEffectiveValue() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        fixture.local.setPersonalization(true, now: 1)
        let page1 = try center(fixture)
        toggle(page1, false)
        await waitUntil("P1 请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        let page2 = otherPage(fixture, like: page1)
        XCTAssertFalse(page2.state.personalizationOn, "P2 按本机显示「关」")
        fail(try XCTUnwrap(WalletStubProtocol.heldIds.first))
        await waitUntil("P1 失败没提示") { self.revertedToast(page1) }
        XCTAssertTrue(fixture.local.personalizationOn, "本机回滚「开」")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1)
        page2.syncPersonalization()
        XCTAssertTrue(page2.state.personalizationOn, "P2 同步后为「开」")

        toggle(page2, false)
        await waitUntil("P2 请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        fail(try XCTUnwrap(WalletStubProtocol.heldIds.first))
        await waitUntil("P2 失败没提示") { self.revertedToast(page2) }
        assertValue(fixture, page2, true, "P2 失败回滚到「开」")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1, "时刻写回切换前的 1")
    }

    /// P2 状态过期（不调 sync）时切换，仍以本机生效值为 previous：本机「开、1」→ P1 切「关」在途 → 另建 P2（显示「关」）→ P1 失败，本机回滚
    /// 「开」，P2 仍显示「关」→ P2 切「开」（与本机生效值相同）→ 失败 → 回滚写本机原生效值「开」、时刻 1。
    /// previous 若取 `!toggle.on` 或本页状态（都是「关」）会红：本机会被写成「关」——用户从没在这台设备上确认过的值。
    func testStalePageToggleUsesEffectiveValueAsPrevious() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        fixture.local.setPersonalization(true, now: 1)
        let page1 = try center(fixture)
        toggle(page1, false)
        await waitUntil("P1 请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        let page2 = otherPage(fixture, like: page1)
        fail(try XCTUnwrap(WalletStubProtocol.heldIds.first))
        await waitUntil("P1 失败没提示") { self.revertedToast(page1) }
        XCTAssertTrue(fixture.local.personalizationOn, "本机回滚「开」")
        XCTAssertFalse(page2.state.personalizationOn, "前提：P2 不调 sync，状态过期为「关」")

        toggle(page2, true)
        await waitUntil("P2 请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        fail(try XCTUnwrap(WalletStubProtocol.heldIds.first))
        await waitUntil("P2 失败没提示") { self.revertedToast(page2) }
        assertValue(fixture, page2, true, "回滚到本机原生效值「开」")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1, "时刻写回切换前的 1")
        await assertNextRequestsHeader(fixture, nil, "回滚到「开」")
    }

    /// 界面层：B 页面（生产 `PrivacyCenterScreen`）挂在无障碍画布上；A 在途时另建 B，B 的个性化行读作「已关闭」；A 失败回滚后，不手动调
    /// sync，B 那一行的读屏值自动变为「已打开」（`settled` → `.onChange` → `syncPersonalization()`）。
    /// 删掉 PrivacyCenterBody 的 `.onChange(of: personalizationSync.settled)`，或 `end()` 里的 `settled += 1`，会红。
    func testOtherPageFollowsRollbackOnScreen() async throws {
        try A11yTree.enable(self)
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        fixture.local.setPersonalization(true, now: 1)
        let pageA = try center(fixture)
        toggle(pageA, false)
        await waitUntil("A 的请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        let pageB = otherPage(fixture, like: pageA)
        let canvas = A11yCanvas(AnyView(NavigationStack { PrivacyCenterScreen(host: MePageHost(pageB)) }),
                                height: 1600)
        defer { canvas.close() }
        let id = "privacy.personalization"
        let onText = pageB.deps.texts.text("me.switch.on")
        let offText = pageB.deps.texts.text("me.switch.off")
        func reads(_ text: String) -> ([A11yNode]) -> Bool {
            { nodes in nodes.contains { $0.id == id && $0.isElement && $0.value.hasSuffix(text) } }
        }
        let off = await canvas.wait(until: reads(offText))
        XCTAssertTrue(off, "A 在途时 B 读作「已关闭」：\n\(A11yTree.dump(A11yTree.nodes(canvas.root)))")

        fail(try XCTUnwrap(WalletStubProtocol.heldIds.first))
        await waitUntil("A 失败没提示") { self.revertedToast(pageA) }
        XCTAssertTrue(fixture.local.personalizationOn, "本机回滚「开」")
        let on = await canvas.wait(until: reads(onText))
        XCTAssertTrue(on, "B 自动跟随回滚读作「已打开」：\n\(A11yTree.dump(A11yTree.nodes(canvas.root)))")
        XCTAssertTrue(pageB.state.personalizationOn, "B 的页面状态也跟随")
    }
}
