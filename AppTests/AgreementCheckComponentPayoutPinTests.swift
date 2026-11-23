@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// FU-IOS-AGREEMENT-CHECK-COMPONENT 回归钉（资金页，D10-2186）：收款侧实名单独同意半屏、劳务协议页的勾选行换组件库勾选圆后，
/// 读屏标签 / 选中态 / 标识 / 命中区与按钮可用条件逐字不变。现状 524f89e 上本就绿。
/// 夹具照 IdentityVisualLayoutTests / LaborVisualLayoutTests（PayoutVisualTestCase：真实 Router → 生产 WalletRouteView），另打开
/// SwiftUI
/// 无障碍树（同 A11yWithdrawTests），用读屏双击勾选；只勾选、不点【同意并继续】/【签署】：不发任何写请求、不调签署。
@MainActor
final class AgreementCheckComponentPayoutPinTests: PayoutVisualTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    private var writes: [String] {
        WalletStubProtocol.requests.filter { $0.method != "GET" }.map(\.path)
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

    private func element(_ id: String, in window: UIWindow, file: StaticString = #filePath,
                         line: UInt = #line) async throws -> A11yNode {
        let shown = await treeWait(window) { $0.contains { $0.id == id && $0.isElement } }
        XCTAssertTrue(shown, "\(id) 不在读屏树里\n\(A11yTree.dump(A11yTree.elements(window)))", file: file, line: line)
        return try XCTUnwrap(A11yTree.elements(window).first { $0.id == id }, file: file, line: line)
    }

    private func state(_ id: String, selected: Bool, in window: UIWindow) async -> Bool {
        await treeWait(window, 3) { nodes in
            nodes.contains { $0.id == id && $0.isElement && $0.traits.contains(.selected) == selected }
        }
    }

    private func enabled(_ id: String, _ expected: Bool, in window: UIWindow) async -> Bool {
        await treeWait(window, 3) { nodes in
            nodes.contains { $0.id == id && $0.isElement && $0.traits.contains(.notEnabled) != expected }
        }
    }

    /// 勾选行共性：按钮、命中区高 ≥ 44、默认未选中。
    private func assertRow(_ row: A11yNode, label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(row.label, label, "\(row.id)：读屏标签逐字不变", file: file, line: line)
        XCTAssertTrue(row.isButton, "\(row.id)：读屏为按钮", file: file, line: line)
        XCTAssertFalse(row.traits.contains(.selected), "\(row.id)：默认未选中", file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.frame.height, CouliHitTarget.minimum - 0.5, "\(row.id)：命中区高 ≥ 44",
                                    file: file, line: line)
    }

    /// 实名单独同意：勾选行「我已阅读并同意以上说明」；未勾【同意并继续】不可用，勾上可用，再取消又不可用。
    func testRealNameConsentCheckAndOkConditionUnchanged() async throws {
        let (host, _) = try await openRealName()
        _ = try await openConsent(host)
        let window = try XCTUnwrap(host.window)
        let writesBefore = writes
        let row = try await element("realname.consent.check", in: window)
        assertRow(row, label: "我已阅读并同意以上说明")
        XCTAssertEqual(host.realName?.state.consentChecked, false, "前提：默认不勾")
        let okOff = await enabled("realname.consent.ok", false, in: window)
        XCTAssertTrue(okOff, "未勾时【同意并继续】不可用")

        XCTAssertTrue(A11yTree.activate(row), "勾选行没有接住双击")
        await waitUntil("双击没有勾上") { host.realName?.state.consentChecked == true }
        let on = await state("realname.consent.check", selected: true, in: window)
        XCTAssertTrue(on, "勾上后读屏为已选中")
        let okOn = await enabled("realname.consent.ok", true, in: window)
        XCTAssertTrue(okOn, "勾上后【同意并继续】可用")

        let again = try await element("realname.consent.check", in: window)
        XCTAssertTrue(A11yTree.activate(again), "勾选行没有接住第二次双击")
        await waitUntil("再双击没有取消") { host.realName?.state.consentChecked == false }
        let off = await state("realname.consent.check", selected: false, in: window)
        XCTAssertTrue(off, "取消后读屏为未选中")
        let okOffAgain = await enabled("realname.consent.ok", false, in: window)
        XCTAssertTrue(okOffAgain, "取消后【同意并继续】不可用")
        XCTAssertEqual(writes, writesBefore, "只勾选不发写请求")
        XCTAssertNotNil(host.realName?.state.consentId, "半屏仍开着（勾选不等于同意）")
    }

    /// 劳务协议：勾选行读「我已阅读并同意《劳务协议》，版本 v1」；未勾【签署】不可用，勾上可用，再取消又不可用；不调签署。
    func testLaborCheckAndSignConditionUnchanged() async throws {
        let (host, _) = try await openLabor()
        let window = try XCTUnwrap(host.window)
        let writesBefore = writes
        let row = try await element("labor.check", in: window)
        assertRow(row, label: "我已阅读并同意《劳务协议》，版本 v1")
        XCTAssertFalse(row.traits.contains(.notEnabled), "正文已读到（content）时勾选行可用")
        XCTAssertEqual(host.laborPage?.state.checked, false, "前提：默认不勾")
        let signOff = await enabled("labor.sign", false, in: window)
        XCTAssertTrue(signOff, "未勾时【签署】不可用")

        XCTAssertTrue(A11yTree.activate(row), "勾选行没有接住双击")
        await waitUntil("双击没有勾上") { host.laborPage?.state.checked == true }
        let on = await state("labor.check", selected: true, in: window)
        XCTAssertTrue(on, "勾上后读屏为已选中")
        let signOn = await enabled("labor.sign", true, in: window)
        XCTAssertTrue(signOn, "勾上后【签署】可用")

        let again = try await element("labor.check", in: window)
        XCTAssertTrue(A11yTree.activate(again), "勾选行没有接住第二次双击")
        await waitUntil("再双击没有取消") { host.laborPage?.state.checked == false }
        let off = await state("labor.check", selected: false, in: window)
        XCTAssertTrue(off, "取消后读屏为未选中")
        let signOffAgain = await enabled("labor.sign", false, in: window)
        XCTAssertTrue(signOffAgain, "取消后【签署】不可用")
        XCTAssertEqual(laborBackend?.signs.count, 0, "只勾选不调签署")
        XCTAssertEqual(writes, writesBefore, "只勾选不发写请求")
    }
}
