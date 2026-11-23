@testable import Couli
import CouliNetwork
import DesignSystem
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// FU-IOS-AGREEMENT-CHECK-COMPONENT 回归钉（注销 waiver 勾选行）：换组件库勾选圆后，读屏「放弃未提现余额和预估收益，复选框」+ 值
/// 「未选中 / 已选中」、标识 deletion.waiver、命中区、【申请注销】可用条件逐字不变。现状 524f89e 上本就绿。
/// 夹具照 App13a1DeletionStepUpTapTests（真实 App 组装 → 生产 DeleteAccountRouteView 挂进窗口），另打开 SwiftUI 无障碍树，用读屏双击勾选。
/// 只勾选、不点【申请注销】：不发任何写请求。
@MainActor
final class AgreementCheckComponentDeletionPinTests: WalletFlowTestCase {
    private var window: UIWindow?
    private var hidden: [UIWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        hidden.forEach { $0.isHidden = false }
        hidden = []
        super.tearDown()
    }

    private func mount(_ fixture: WalletAppFixture, _ destination: RouteDestination) -> UIWindow {
        let host = UIHostingController(rootView: DeleteAccountRouteView(destination: destination)
            .environmentObject(fixture.wallet))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        frame.frame = CGRect(x: 0, y: 0, width: 390, height: 1600)
        frame.rootViewController = host
        frame.windowLevel = .alert + 1
        hidden = (scene?.windows ?? []).filter { $0 !== frame && !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        frame.makeKeyAndVisible()
        host.view.frame = frame.bounds
        host.view.layoutIfNeeded()
        window = frame
        return frame
    }

    private func treeWait(_ window: UIWindow, _ seconds: Double = 6,
                          until condition: ([A11yNode]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.layoutIfNeeded()
            if condition(A11yTree.nodes(window)) {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func enabled(_ id: String, _ expected: Bool, in window: UIWindow) async -> Bool {
        await treeWait(window, 3) { nodes in
            nodes.contains { $0.id == id && $0.isElement && $0.traits.contains(.notEnabled) != expected }
        }
    }

    /// 读屏标签 / 值 / 标识 / 命中区不变；未勾时【申请注销】不可用；读屏双击勾上后值「已选中」、按钮可用；再双击回到未选中、按钮不可用。
    func testWaiverSpokenTextAndApplyConditionUnchanged() async throws {
        script.ok("GET /v1/me/deletion", "null")
        let fixture = make()
        let destination = RouteDestination(route: DeleteAccountController.route)
        fixture.router.path = [RouteDestination(route: "Settings"), destination]
        let window = mount(fixture, destination)
        await waitUntil("注销页执行器没有建立") { fixture.wallet.pages[destination.id] != nil }
        let host = try XCTUnwrap(fixture.wallet.pages[destination.id]?
            .controller as? MePageHost<DeleteAccountController>)
        let controller = host.controller
        await waitUntil("注销页没有进入可申请的初始态", timeout: 8) {
            controller.view.kind == .initial && controller.view.applyEnabledWhenChecked && controller.view.waiverEnabled
        }
        let shown = await treeWait(window) { $0.contains { $0.id == "deletion.waiver" && $0.isElement } }
        XCTAssertTrue(shown, "勾选行标识 deletion.waiver 不变\n\(A11yTree.dump(A11yTree.elements(window)))")
        let row = try XCTUnwrap(A11yTree.elements(window).first { $0.id == "deletion.waiver" })
        XCTAssertEqual(row.label, "放弃未提现余额和预估收益，复选框", "读屏标签逐字不变")
        XCTAssertEqual(row.value, "未选中", "未勾读「未选中」")
        XCTAssertTrue(row.isButton, "读屏可双击")
        XCTAssertFalse(row.traits.contains(.notEnabled), "初始态可勾")
        XCTAssertGreaterThanOrEqual(row.frame.height, CouliHitTarget.minimum - 0.5, "命中区高 ≥ 44")
        XCTAssertFalse(controller.state.waiver)
        let applyOff = await enabled("deletion.apply", false, in: window)
        XCTAssertTrue(applyOff, "未勾时【申请注销】不可用")
        XCTAssertFalse(controller.applyEnabled)

        XCTAssertTrue(A11yTree.activate(row), "勾选行没有接住双击")
        await waitUntil("双击没有勾上") { controller.state.waiver }
        let on = await treeWait(window, 3) { $0.contains { $0.id == "deletion.waiver" && $0.value == "已选中" } }
        XCTAssertTrue(on, "勾上读「已选中」")
        let applyOn = await enabled("deletion.apply", true, in: window)
        XCTAssertTrue(applyOn, "勾上后【申请注销】可用")
        XCTAssertTrue(controller.applyEnabled)

        let again = try XCTUnwrap(A11yTree.elements(window).first { $0.id == "deletion.waiver" })
        XCTAssertTrue(A11yTree.activate(again), "勾选行没有接住第二次双击")
        await waitUntil("再双击没有取消") { !controller.state.waiver }
        let off = await treeWait(window, 3) { $0.contains { $0.id == "deletion.waiver" && $0.value == "未选中" } }
        XCTAssertTrue(off, "取消后读「未选中」")
        let applyOffAgain = await enabled("deletion.apply", false, in: window)
        XCTAssertTrue(applyOffAgain, "取消后【申请注销】不可用")
        XCTAssertEqual(WalletStubProtocol.requests.filter { $0.method != "GET" }.map(\.path), [], "只勾选不发写请求")
    }
}
