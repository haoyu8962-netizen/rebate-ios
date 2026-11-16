@testable import Couli
import Foundation
import Me
import MeCore
import SwiftUI
import XCTest

/// FU-IOS-PERSONALIZATION-CONSENT-ROLLBACK 续（D10-1830）：同意记录在途时再切换不受理；回滚判据是本机切换时刻仍是这次写的那个；
/// 离开本页后结果才失败时 member 仍回滚、不提示，游客不回滚、不提示；在途期间应用级 `deps.personalization.pending` 为真、个性化行在无障碍树里
/// 标不可用，结果回来恢复（D10-1831 ①）。搭建见 `FuIosPersonalizationConsentTestCase`。
@MainActor
final class FuIosPersonalizationInFlightTests: FuIosPersonalizationConsentTestCase {
    // MARK: - ③ 在途不受理（应用级，全 App 一次一条）

    /// ③ 同意记录在途时再切换不受理（state、本机值与切换时刻、请求数都不变）；在途那条失败后回滚到切换前的值与时刻（预置时刻 1），
    /// 之后再切换可受理。删掉 guard 里的 `!deps.personalization.pending` 会红（第二次被受理、多一条请求）；删掉 Task 里
    /// `deps.personalization.end()` 会红（失败后仍在途、再切换不受理）。
    func testInFlightToggleIgnoredThenRollbackAndAcceptAgain() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        fixture.local.setPersonalization(true, now: 1)
        let controller = try center(fixture)
        toggle(controller, false)
        await waitUntil("请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        let switchedAt = fixture.local.personalizationChangedAt
        XCTAssertTrue(controller.deps.personalization.pending, "在途")
        toggle(controller, true)
        toggle(controller, true)
        await settle()
        assertValue(fixture, controller, false, "在途时连点不受理")
        XCTAssertEqual(fixture.local.personalizationChangedAt, switchedAt, "在途时切换时刻不变")
        XCTAssertEqual(requests("POST", "/v1/consents").count, 1, "在途时零新请求")
        XCTAssertEqual(fixture.api.calls(PrivacyCenterController.recordConsent), 1)

        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 50001, data: "null", headers: [:]))
        await waitUntil("失败没提示") { self.revertedToast(controller) }
        assertValue(fixture, controller, true, "在途那条失败后回滚到切换前")
        XCTAssertFalse(controller.deps.personalization.pending, "失败回来不再在途")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1, "切换时刻写回切换前的值")

        toggle(controller, false)
        await waitUntil("失败后再切换没受理") { self.requests("POST", "/v1/consents").count == 2 }
        assertValue(fixture, controller, false, "再切换可受理")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
    }

    /// ③ 全 App 一次只一条在途（D10-1838）：A 页请求在途时，同身份另一个隐私中心执行器 B 也不受理（本机值、请求数不变），B 的页面上
    /// 个性化行读屏元素标不可用；A 结束后 B 可切换、行恢复可用。删掉 guard 里的 `!deps.personalization.pending`（或改回按执行器的在途标志）
    /// 会红。
    func testInFlightLockIsAppWide() async throws {
        try A11yTree.enable(self)
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        let pageA = try center(fixture)
        toggle(pageA, false)
        await waitUntil("A 的请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        let pageB = PrivacyCenterController(
            deps: fixture.me.deps,
            identity: pageA.identity,
            page: nil,
            forceUpdate: false
        )
        let hostB = MePageHost(pageB)
        let canvas = A11yCanvas(AnyView(NavigationStack { PrivacyCenterScreen(host: hostB) }), height: 1600)
        defer { canvas.close() }
        let id = "privacy.personalization"
        func row(_ nodes: [A11yNode], enabled: Bool) -> Bool {
            nodes.contains { $0.id == id && $0.isElement && $0.traits.contains(.notEnabled) != enabled }
        }
        XCTAssertFalse(pageB.state.personalizationOn, "B 按本机值")
        XCTAssertTrue(pageB.deps.personalization.pending, "B 看到应用级在途")
        toggle(pageB, true)
        await settle()
        assertValue(fixture, pageB, false, "A 在途时 B 不受理")
        XCTAssertEqual(requests("POST", "/v1/consents").count, 1, "B 零新请求")
        let disabled = await canvas.wait { row($0, enabled: false) }
        XCTAssertTrue(disabled, "A 在途时 B 的个性化行不可用：\n\(A11yTree.dump(A11yTree.nodes(canvas.root)))")

        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("A 没结算") { !fixture.me.deps.personalization.pending }
        let usable = await canvas.wait { row($0, enabled: true) }
        XCTAssertTrue(usable, "A 结束后 B 的个性化行可用：\n\(A11yTree.dump(A11yTree.nodes(canvas.root)))")
        toggle(pageB, true)
        await waitUntil("A 结束后 B 没受理") { self.requests("POST", "/v1/consents").count == 2 }
        assertValue(fixture, pageB, true, "B 可切换")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("B 没结算") { !fixture.me.deps.personalization.pending }
    }

    /// 应用级在途状态无残留：在途中换账号（a）或退出登录（b），请求结束后 `pending` 复位，换身份后重建的隐私中心执行器可切换。
    /// 删掉 Task 里的 `deps.personalization.end()`（或把它挪到 `check(identity) != .stale` 之后）会红。
    func testAppStateResetsAcrossIdentityChange() async throws {
        for logout in [false, true] {
            let tag = logout ? "退出登录" : "换账号"
            let fixture = fresh()
            script.on("POST /v1/consents", .hold)
            let controller = try center(fixture)
            toggle(controller, false)
            await waitUntil("\(tag)：请求没发出") { WalletStubProtocol.heldIds.count == 1 }
            if logout {
                fixture.client.signOut()
                fixture.routing.sessionStateChanged(resumePending: false)
            } else {
                try fixture.switchAccount(to: "user-b")
            }
            if let held = WalletStubProtocol.heldIds.first {
                WalletStubProtocol.release(held, with: .envelope(code: 50001, data: "null", headers: [:]))
            }
            await waitUntil("\(tag)：在途没复位") { !fixture.me.deps.personalization.pending }
            let next = try fixture.controller("PrivacyCenter", as: PrivacyCenterController.self)
            XCTAssertFalse(next === controller, "\(tag)：执行器已按新身份重建")
            XCTAssertEqual(next.identity.level, logout ? MeLevel.guest : MeLevel.member, tag)
            let before = requests("POST", "/v1/consents").count
            toggle(next, !next.state.personalizationOn)
            await waitUntil("\(tag)：新身份切换没受理") { self.requests("POST", "/v1/consents").count == before + 1 }
            XCTAssertTrue(fixture.me.deps.personalization.pending, "\(tag)：新请求在途")
            if let held = WalletStubProtocol.heldIds.first {
                WalletStubProtocol.release(held, with: .envelope(code: 0, data: "{}", headers: [:]))
            }
            await waitUntil("\(tag)：新请求没结算") { !fixture.me.deps.personalization.pending }
        }
    }

    // MARK: - 离开本页后结果才失败

    /// 离页（`leave()`）后失败：member 本机值与切换时刻仍回滚、网络头恢复（之后的请求带 off），不提示，也不自动再发。
    /// Task 若恢复 `guard let self, alive`（或改回弱引用）会红；删掉 `if notify, !left` 里的 `!left` 会红（离页后还提示）。
    func testMemberFailureAfterLeaveRollsBackSilently() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        fixture.local.setPersonalization(false, now: 1)
        let controller = try center(fixture)
        toggle(controller, true)
        await waitUntil("请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        controller.leave()
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 50001, data: "null", headers: [:]))
        await waitUntil("离页后没回滚") { !fixture.local.personalizationOn }
        XCTAssertTrue(fixture.local.personalizationOffNow, "网络头恢复")
        XCTAssertEqual(fixture.local.personalizationChangedAt, 1, "切换时刻写回")
        await assertNoResend(1, never: false, "离页后失败")
        XCTAssertNil(controller.state.toast, "离页后不提示")
        await assertNextRequestsHeader(fixture, "off", "离页后回滚")
    }

    /// 离页后失败：游客不回滚、不提示。删掉 member 条件或 `if notify, !left` 里的 `!left` 会红。
    func testGuestFailureAfterLeaveKeepsSilently() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make(account: nil)
        let controller = try center(fixture)
        toggle(controller, false)
        await waitUntil("请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        controller.leave()
        let held = try XCTUnwrap(WalletStubProtocol.heldIds.first)
        WalletStubProtocol.release(held, with: .envelope(code: 50001, data: "null", headers: [:]))
        await settle(50)
        XCTAssertFalse(fixture.local.personalizationOn, "游客不回滚")
        XCTAssertTrue(fixture.local.personalizationOffNow)
        XCTAssertNil(controller.state.toast, "离页后不提示")
    }

    // MARK: - 在途标志与界面可用性（D10-1831 ①）

    /// 在途时 `deps.personalization.pending` 为真；成功回来、失败回来后各自为假且可再切换。删掉 `deps.personalization.begin()`
    /// 会红（在途时为假）；删掉结果回来的 `= false` 会红（一直为真、再切换不受理）。
    func testPendingFlagAcrossSuccessAndFailure() async throws {
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        let controller = try center(fixture)
        XCTAssertFalse(controller.deps.personalization.pending, "打开时不在途")
        toggle(controller, false)
        await waitUntil("请求 1 没发出") { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertTrue(controller.deps.personalization.pending, "请求 1 在途")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("成功回来没清在途") { !controller.deps.personalization.pending }
        assertValue(fixture, controller, false, "成功保持")

        toggle(controller, true)
        await waitUntil("成功后再切换没受理") { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertTrue(controller.deps.personalization.pending, "请求 2 在途")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 50001, data: "null", headers: [:]))
        await waitUntil("失败回来没清在途") { !controller.deps.personalization.pending }
        assertValue(fixture, controller, false, "失败回滚")

        toggle(controller, true)
        await waitUntil("失败后再切换没受理") { self.requests("POST", "/v1/consents").count == 3 }
        XCTAssertTrue(controller.deps.personalization.pending, "请求 3 在途")
        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("请求 3 没结算") { !controller.deps.personalization.pending }
    }

    /// 没发请求的分支（限流中、设备未注册）：切换后 `deps.personalization.pending` 始终为假（把 `begin()` 挪到发请求之前会红）。
    func testPendingStaysFalseWhenNotSent() async throws {
        let gated = make()
        let page = try center(gated)
        gated.me.deps.gates.consent.start(60000)
        toggle(page, false)
        XCTAssertFalse(page.deps.personalization.pending, "限流中：切换后不在途")
        await settle()
        XCTAssertFalse(page.deps.personalization.pending, "限流中：之后也不在途")

        let unregistered = fresh(registered: false)
        let other = try center(unregistered)
        toggle(other, false)
        XCTAssertFalse(other.deps.personalization.pending, "设备未注册：切换后不在途")
        await settle()
        XCTAssertFalse(other.deps.personalization.pending, "设备未注册：之后也不在途")
        XCTAssertTrue(requests("POST", "/v1/consents").isEmpty)
    }

    /// 界面层：生产隐私中心页面（真实 Router 取出的 `entry.screen()`）挂进窗口、打开 SwiftUI 无障碍树（`A11yTree`），读个性化行
    /// （标识 `privacy.personalization`，MeSwitchRow 合并后的读屏元素）的 `.notEnabled`：打开时可用，在途时不可用，结果回来恢复可用。
    /// 在途时先核对树是新的（行的值已读作「已关闭」），再判可用性，免得把「树没刷新」当成「没标不可用」；读屏双击在途时也不发请求（补充）。
    /// 删掉 MeSwitchRow 的 `.disabled(!enabled)`，或 PrivacyCenterBody 按 `deps.personalization.pending` 关开关，会红。
    /// 现状：MeSwitchRow 的 `.disabled(!enabled)` 放在 `.accessibilityElement(children: .ignore)` 等读屏修饰的最外层，合并后的读屏元素
    /// 也标不可用（D10-1831 ①；早先放在里面时合并元素不受影响，check1 据此红过）。
    func testSwitchRowDisabledWhileInFlight() async throws {
        try A11yTree.enable(self)
        script.on("POST /v1/consents", .hold)
        let fixture = make()
        let entry = try XCTUnwrap(fixture.open("PrivacyCenter"))
        let canvas = A11yCanvas(AnyView(NavigationStack { entry.screen() }), height: 1600)
        defer { canvas.close() }
        let controller = try XCTUnwrap(entry.controller() as? PrivacyCenterController)
        let id = "privacy.personalization"
        let offText = controller.deps.texts.text("me.switch.off")
        func row(_ nodes: [A11yNode], enabled: Bool) -> Bool {
            nodes.contains { $0.id == id && $0.isElement && $0.traits.contains(.notEnabled) != enabled }
        }
        /// 失败现场：整棵树，逐个标出不可用（A11yLoginTests 同一写法），换行起头。
        func scene() -> String {
            "\n" + A11yTree.nodes(canvas.root)
                .map { "\($0)\($0.traits.contains(.notEnabled) ? " 不可用" : "")" }.joined(separator: "\n")
        }
        let usable = await canvas.wait { row($0, enabled: true) }
        XCTAssertTrue(usable, "打开时个性化行可用：\(scene())")

        toggle(controller, false)
        await waitUntil("请求没发出") { WalletStubProtocol.heldIds.count == 1 }
        XCTAssertTrue(controller.deps.personalization.pending, "控制器在途")
        let fresh = await canvas.wait { $0.contains { $0.id == id && $0.isElement && $0.value.hasSuffix(offText) } }
        XCTAssertTrue(fresh, "树没刷新到在途时的值（不是可用性问题）：\(scene())")
        let disabled = await canvas.wait(3) { row($0, enabled: false) }
        XCTAssertTrue(disabled, "在途时个性化行读屏元素应标不可用（.notEnabled）：\(scene())")
        let node = try XCTUnwrap(A11yTree.elements(canvas.root).first { $0.id == id })
        _ = A11yTree.activate(node)
        await canvas.pump(0.3)
        XCTAssertEqual(requests("POST", "/v1/consents").count, 1, "在途时读屏双击不发请求")

        WalletStubProtocol.release(try XCTUnwrap(WalletStubProtocol.heldIds.first),
                                   with: .envelope(code: 0, data: "{}", headers: [:]))
        await waitUntil("结果没回来") { !controller.deps.personalization.pending }
        let restored = await canvas.wait { row($0, enabled: true) }
        XCTAssertTrue(restored, "结果回来恢复可用：\(scene())")
    }
}
