@testable import Couli
import DesignSystem
import Foundation
import SwiftUI
import UIKit
import Wallet
import WalletCore
import XCTest

/// FU-IOS-A11Y（QA-12b iOS 报告 P6 钱包、P7 提现）：资金页只验读屏与焦点，**不触发任何资金动作**。
/// - A11Y-02 / 共性 ④：问号说明半屏能用读屏「返回」手势关闭；D10-1248 ③ 资金页的返回手势只能等同【知道了】/关闭：
///   擦除前后没有新增任何写请求（非 GET），也没有新增提现 / 二次验证 / 放弃类请求。
/// - A11Y-06 / 共性 ③、A11Y-07：关闭后焦点回到触发它的问号 /【放弃】。没有读屏时系统忽略对读屏焦点的写入，进程内看不到真实落点，
///   这里按本仓库既有做法用源码守卫钉「弹层传了 restoreFocusTo、触发控件挂了焦点绑定」（PrivacyVisualGuardTests、SettingsVisualGuardTests 同口径），
///   实际落点由开发验收用 VoiceOver 录屏核（钱包三个问号各回各的）。
@MainActor
final class A11yWalletTests: WalletVisualTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    private var writes: [WalletStubProtocol.Recorded] {
        WalletStubProtocol.requests.filter { $0.method != "GET" }
    }

    func testWalletHelpSheetsCloseWithEscapeWithoutFundsAction() async throws {
        let (page, _) = try await openWallet("normal")
        let window = try XCTUnwrap(page.window)
        let labels = ["wallet.help.estimated_label", "wallet.help.pending_paused_label", "wallet.help.frozen_label"]
            .map(texts.text).filter { !$0.isEmpty }
        var checked = 0
        for label in labels {
            guard let trigger = A11yTree.element(labelled: label, in: window) else { continue }
            XCTAssertTrue(trigger.isButton, "\(label) 是按钮")
            XCTAssertTrue(A11yTree.activate(trigger), "\(label) 没有接住双击")
            await quietWindow(0.6)
            let body = try XCTUnwrap(A11yTree.node("wallet.help.text", in: window), "\(label)：说明半屏没有打开")
            let before = WalletStubProtocol.requests.count
            let writesBefore = writes.count
            XCTAssertTrue(A11yTree.escape(from: body.object), "\(label)：半屏没有接住读屏「返回」手势（A11Y-02）")
            await quietWindow(0.8)
            XCTAssertNil(A11yTree.node("wallet.help.text", in: window), "\(label)：「返回」手势要关闭半屏，等同【知道了】")
            XCTAssertEqual(writes.count, writesBefore, "\(label)：返回手势不能新增任何写请求（D10-1248 ③）")
            XCTAssertEqual(WalletStubProtocol.requests.count, before, "\(label)：关闭说明不该发任何请求")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 1, "前提：钱包页至少一个问号（\(labels)）")
    }
}

@MainActor
final class A11yWithdrawTests: WithdrawVisualTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try A11yTree.enable(self)
    }

    func testFeeHelpSheetClosesWithEscapeWithoutFundsAction() async throws {
        let (host, _) = try await openWithdraw(amount: "10", estimate: "estimated", waitFor: "withdraw.estimate.help")
        let window = try XCTUnwrap(host.window)
        let label = WalletDraftTexts().text("wallet.help.fee_tax_label")
        let trigger = try XCTUnwrap(A11yTree.element(labelled: label, in: window), "预计到账没有问号")
        XCTAssertTrue(A11yTree.activate(trigger), "问号没有接住双击")
        await quietWindow(0.6)
        let body = try XCTUnwrap(A11yTree.node("wallet.help.text", in: window), "说明半屏没有打开")
        let before = WalletStubProtocol.requests.filter { $0.method != "GET" }.count
        XCTAssertTrue(A11yTree.escape(from: body.object), "半屏没有接住读屏「返回」手势（A11Y-02）")
        await quietWindow(0.8)
        XCTAssertNil(A11yTree.node("wallet.help.text", in: window), "「返回」手势要关闭半屏")
        XCTAssertEqual(WalletStubProtocol.requests.filter { $0.method != "GET" }.count, before,
                       "返回手势不能新增任何写请求（D10-1248 ③）")
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/withdrawals").count, 0, "没有提现请求")
        XCTAssertEqual(WalletStubProtocol.requests("POST", "/v1/auth/step-up").count, 0, "没有二次验证")
        XCTAssertFalse(host.flow?.state.phase == .pending, "没有进待确认")
    }
}

/// 源码守卫：焦点还原（A11Y-06 / 07）。去注释后在调用处整段查。
final class A11yFocusRestoreSourceTests: XCTestCase {
    /// 取 `marker` 起到下一个顶层修饰（换行后以「        .」开头且不是参数续行）为止的调用段；简单起见取 marker 起 400 字。
    private func call(_ code: String, _ marker: String, file: StaticString = #filePath,
                      line: UInt = #line) -> String? {
        guard let range = code.range(of: marker) else {
            XCTFail("源码里找不到 \(marker)", file: file, line: line)
            return nil
        }
        return String(code[range.lowerBound...].prefix(400))
    }

    @MainActor
    func testWalletHelpSheetRestoresFocusToQuestionMark() throws {
        let code = try A11yAudit.source("Packages/Features/Sources/Wallet/WalletScreen.swift")
        let sheet = try XCTUnwrap(call(code, ".couliSheet(isPresented: help != nil"))
        let head = sheet.components(separatedBy: "sheet:").first ?? sheet
        XCTAssertTrue(head.contains("restoreFocusTo:"), "钱包问号半屏要传 restoreFocusTo（A11Y-06）：\(head)")
        let wallet = try ["WalletScreen+Hero.swift", "WalletScreen+Cards.swift", "WalletScreen+Parts.swift"]
            .map { try A11yAudit.source("Packages/Features/Sources/Wallet/" + $0) }.joined()
        XCTAssertTrue(wallet.contains("accessibilityFocused("), "问号按钮要挂读屏焦点绑定（关闭后焦点回到它）")
    }

    @MainActor
    func testWithdrawFeeHelpAndAbandonRestoreFocus() throws {
        let code = try A11yAudit.source("Packages/Features/Sources/Wallet/WithdrawScreen.swift")
        let fee = try XCTUnwrap(call(code, ".couliSheet(isPresented: feeHelp"))
        XCTAssertTrue((fee.components(separatedBy: "sheet:").first ?? fee).contains("restoreFocusTo:"),
                      "预计到账问号半屏要传 restoreFocusTo（A11Y-06）：\(fee)")
        let abandon = try XCTUnwrap(call(code, ".couliDialog(isPresented: flowState.abandonConfirmKey != nil"))
        let head = abandon.components(separatedBy: ") {").first ?? abandon
        XCTAssertTrue(head.contains("restoreFocusTo:"), "放弃上一笔确认框要传 restoreFocusTo（A11Y-07）：\(head)")
    }
}
