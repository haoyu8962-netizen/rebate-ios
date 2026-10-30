@testable import Couli
import CryptoKit
import Foundation
import XCTest

/// 资金写页硬约束（prompt、brief §3 / §5、G-W12「一字不改」）：逻辑文件与受保护测试逐字节锁底版；提交可用条件表达式、回调块、
/// 弹窗槽位映射按源码字面锁定。本文件全部用例在底版上应为绿，实现后必须仍绿。
final class WithdrawVisualFundsGuardTests: XCTestCase {
    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ path: String) throws -> Data {
        try Data(contentsOf: WalletVisualData.repo().appendingPathComponent(path))
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 钱包功能页全部源码（实现者可拆文件，字面仍要在），空白折叠。
    private func features() throws -> String {
        let root = WalletVisualData.repo().appendingPathComponent("Packages/Features/Sources/Wallet")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }
            .sorted()
        return try normalized(names.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n"))
    }

    func testLogicFilesUnchanged() throws {
        XCTAssertEqual(WithdrawVisualBaseline.logicFiles.count, 29)
        for (path, digest) in WithdrawVisualBaseline.logicFiles {
            XCTAssertEqual(try sha(file(path)), digest, "\(path) 被改了：资金逻辑零改动（brief §3）")
        }
    }

    func testProtectedTestsUnchanged() throws {
        XCTAssertGreaterThan(WithdrawVisualBaseline.protectedTests.count, 15)
        for (path, digest) in WithdrawVisualBaseline.protectedTests {
            XCTAssertEqual(try sha(file(path)), digest, "\(path) 被改了：受保护测试零改动")
        }
    }

    /// G-W12：【提交】可用条件、loading 条件、回调一字不改；计算中不置灰。
    func testSubmitExpressionVerbatim() throws {
        let source = try features()
        let expected = [
            "let enabled = (display?.submitEnabled ?? false) && flowState.canSubmit && !snapshot.serverBlocked "
                + "&& !snapshot.successPending && !gate.blocked",
            "let submitting = flowState.phase == .submitting && !flowState.awaitingIdentity",
            "isEnabled: enabled, fillsWidth: true, action: actions.submit",
            "let editable = display.amountEditable && flowState.pending == nil && flowState.phase == .editing",
            "isEnabled: display.allEnabled && editable, action: actions.fillAll",
        ]
        for line in expected {
            XCTAssertTrue(source.contains(normalized(line)), "资金字面被改：\(line)")
        }
        XCTAssertFalse(source.contains("estimate != .calculating"), "G-W12：计算中不得进提交条件")
        XCTAssertFalse(source.contains("snapshot.estimate == .calculating"), "G-W12：计算中不得进提交条件")
    }

    /// `WithdrawActions`、`FlowActions`（渲染时票据：版本、身份、原键、弹窗实例）一字不改。
    func testActionBlocksVerbatim() throws {
        let screen = try String(data: file("Packages/Features/Sources/Wallet/WithdrawScreen.swift"), encoding: .utf8) ??
            ""
        let flow = try String(
            data: file("Packages/Features/Sources/Wallet/SensitiveFlowViews.swift"),
            encoding: .utf8
        ) ??
            ""
        func block(_ text: String, _ start: String) throws -> String {
            let from = try XCTUnwrap(text.range(of: start), "\(start) 不见了")
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: from.upperBound..<text.endIndex), "\(start) 没有收尾")
            return String(text[from.lowerBound..<end.upperBound])
        }
        XCTAssertEqual(try sha(Data(normalized(block(screen, "public struct WithdrawActions")).utf8)),
                       WithdrawVisualBaseline.withdrawActions, "WithdrawActions 被改")
        XCTAssertEqual(try sha(Data(normalized(block(flow, "public struct FlowActions")).utf8)),
                       WithdrawVisualBaseline.flowActions, "FlowActions 被改")
    }

    private func wallet(_ name: String) throws -> String {
        try normalized(String(
            contentsOf: WalletVisualData.repo().appendingPathComponent("Packages/Features/Sources/Wallet/" + name),
            encoding: .utf8
        ))
    }

    private func assertOnce(_ literal: String, in text: String, _ place: String, file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(text.components(separatedBy: normalized(literal)).count - 1, 1, "\(place)：\(literal)",
                       file: file, line: line)
    }

    /// 取 `start` 到 `end` 之间的源码片段（v2 / F9：同样字面按所在按钮定位）。
    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), "\(start) 不见了")
        let until = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), "\(end) 不见了")
        return String(text[from.lowerBound..<until.lowerBound])
    }

    /// G-W16 槽位映射（错位 = 误放弃上一笔，资金 S0）与待确认卡回调 / 可用条件。
    /// v2：同样字面在别处还有时 `contains` 查不出单处改动（实现变异 F8、F9），改为按文件 / 按按钮恰好一次。
    func testDialogSlotsAndPendingWiringVerbatim() throws {
        let flow = try wallet("SensitiveFlowViews.swift")
        for line in [
            #"primary: CouliDialogAction(texts.text("pending_confirm.abandon.cancel"), action: actions.cancelAbandon)"#,
            #"secondary: CouliDialogAction(texts.text("pending_confirm.abandon.ok"), action: actions.abandon)"#,
            #"primary: CouliDialogAction(texts.text("cs.appeal_entry"), action: appeal)"#,
            #"secondary: CouliDialogAction(texts.text("withdraw.risk_blocked.ok"), action: ok)"#,
        ] {
            assertOnce(line, in: flow, "两弹窗槽位")
        }
        // 两页各自的 44001：`ok` / `appeal` 接线连同本页说明文案一起定位
        assertOnce(
            #"desc: texts.text("withdraw.risk_blocked.desc"), ok: flowActions.dismissRisk, appeal: actions.appeal)"#,
            in: try wallet("WithdrawScreen.swift"),
            "提现页 44001"
        )
        assertOnce(#"desc: texts.text("payout.blocked.desc"), ok: flowActions.dismissRisk, appeal: actions.appeal)"#,
                   in: try wallet("PayoutAccountScreen.swift"), "收款账号页 44001")
        // 两个按钮各自的可用条件与回调
        let abandon = try slice(flow, from: "var abandonButton: some View", to: "var confirmButton: some View")
        assertOnce("isEnabled: actionsEnabled && !blocked", in: abandon, "【放弃】可用条件")
        assertOnce("action: actions.askAbandon", in: abandon, "【放弃】回调")
        let confirm = try slice(flow, from: "var confirmButton: some View", to: "放弃确认弹窗里的上一笔")
        assertOnce("isEnabled: actionsEnabled && !blocked", in: confirm, "【确认】可用条件")
        assertOnce("action: actions.confirm", in: confirm, "【确认】回调")
        // 两页把执行器状态传给待确认卡
        let wiring = "blocked: gate.blocked, busy: flowState.pendingCardBusy, "
            + "actionsEnabled: flowState.pendingActionsEnabled"
        assertOnce(wiring, in: try wallet("WithdrawScreen+Sections.swift"), "提现页待确认卡")
        assertOnce(wiring, in: try wallet("PayoutAccountScreen+Form.swift"), "收款账号页待确认卡")
        assertOnce(
            "link: PendingCard.Link(title: texts.text(\"pending_confirm.withdraw.records\"), action: actions.records)",
            in: try wallet("WithdrawScreen+Sections.swift"), "查看提现记录"
        )
    }

    /// 不新增提交入口（brief §3、§9 第 3 条）：输入法完成键提交、档位顺手提交。
    func testNoNewSubmitEntry() throws {
        let root = "Packages/Features/Sources/Wallet/"
        let source = try ["WithdrawScreen.swift", "WithdrawScreen+Sections.swift", "WithdrawScreen+Bottom.swift",
                          "SensitiveFlowViews.swift"]
            .map { try String(contentsOf: WalletVisualData.repo().appendingPathComponent(root + $0), encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(source.contains(".onSubmit"), "不加输入法完成键提交")
        XCTAssertEqual(source.components(separatedBy: "actions.submit").count - 1, 1, "actions.submit 只接【提交】一处")
        XCTAssertEqual(source.components(separatedBy: "actions.abandon").count - 1, 1, "actions.abandon 只接确定放弃一处")
    }
}
