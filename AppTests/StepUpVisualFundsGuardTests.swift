@testable import Couli
import CryptoKit
import Foundation
import XCTest

/// APP-09v-d 资金指纹（底版 1df9114；brief §3、§9 第 2、3 条，G-W19）：半屏版式可以重排，但提交表达式、回调、发码节流一字不改，不新增提交入口。
/// 逻辑文件（含 StepUpController*.swift）与受保护测试的逐字节指纹在 c 组 `WithdrawVisualFundsGuardTests`，本类不重复。全部用例底版应绿，实现后必须仍绿；
/// 变了走「需要编排裁定」，不许改基线。
final class StepUpVisualFundsGuardTests: XCTestCase {
    /// `public struct StepUpActions` 整块折叠空白后的 SHA-256（渲染时取面板实例编号，共性第 60、63 条）。
    private static let stepUpActions = "cd743ed0455dd94eb0e674a95b8015b32ceb1913373dda3001842bbd4313e5c1"

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func walletDirectory() -> URL {
        WalletVisualData.repo().appendingPathComponent("Packages/Features/Sources/Wallet")
    }

    private func walletFile(_ name: String) throws -> String {
        try String(contentsOf: walletDirectory().appendingPathComponent(name), encoding: .utf8)
    }

    /// 实现者可把半屏拆成多个 StepUp*.swift：合起来算。
    private func sheetSources() throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: walletDirectory().path)
            .filter { $0.hasPrefix("StepUp") && $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(names.contains("StepUpSheet.swift"))
        // 只比代码：注释里提到的修饰符不算
        return try names.map { try walletFile($0) }.joined(separator: "\n")
            .replacingOccurrences(of: "(?m)^\\s*//.*$", with: "", options: .regularExpression)
    }

    private func occurrences(_ literal: String, in text: String) -> Int {
        text.components(separatedBy: literal).count - 1
    }

    private func assertOnce(_ literal: String, in text: String, _ place: String, file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertEqual(occurrences(normalized(literal), in: text), 1, "\(place)：\(literal)", file: file, line: line)
    }

    /// 回调块一字不改。
    func testStepUpActionsBlockVerbatim() throws {
        let source = try walletFile("StepUpSheet.swift")
        let from = try XCTUnwrap(source.range(of: "public struct StepUpActions"), "StepUpActions 不见了")
        let end = try XCTUnwrap(source.range(of: "\n}\n", range: from.upperBound..<source.endIndex))
        let block = normalized(String(source[from.lowerBound..<end.upperBound]))
        let digest = SHA256.hash(data: Data(block.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.stepUpActions, "StepUpActions 被改")
    }

    /// 【验证并提交】可用条件、loading、回调；输入绑定；重新获取的可用条件与回调；每处恰一次。
    func testVerifyAndResendExpressionsVerbatim() throws {
        let source = try normalized(sheetSources())
        assertOnce(
            #"texts.text("step_up.submit"), isLoading: state.showsVerifying, "#
                + "isEnabled: state.canVerify && !verifyBlocked, fillsWidth: true, action: actions.verify",
            in: source, "验证按钮"
        )
        assertOnce("isEnabled: !smsBlocked && !state.awaitingIdentity && state.phase == .ready", in: source, "重发可用条件")
        assertOnce("action: actions.resend", in: source, "重发回调")
        assertOnce("Binding(get: { state.code }, set: actions.code)", in: source, "输入绑定")
        assertOnce("if state.resendLeftSec > 0", in: source, "倒计时分支")
        assertOnce("let locked = state.phase == .verifying || state.phase == .noPhone", in: source, "锁定表达式")
        assertOnce(".disabled(locked)", in: source, "锁定接到输入框")
    }

    /// 不新增提交入口：`actions.verify` 只接按钮；没有输入法提交、没有监听验证码变化、没有手势提交。
    func testNoNewVerifyEntry() throws {
        let source = try normalized(sheetSources())
        XCTAssertEqual(occurrences("actions.verify", in: source), 1, "actions.verify 只接【验证并提交】一处")
        XCTAssertEqual(occurrences(".verify(", in: source), 1, "只有 StepUpActions 里调控制器验证，视图不直接调")
        XCTAssertFalse(source.contains(".onSubmit"), "不加输入法完成键提交")
        XCTAssertFalse(source.contains("submitLabel"), "不加输入法提交键")
        XCTAssertFalse(source.contains("onChange(of: state.code"), "不监听验证码变化")
        XCTAssertFalse(source.contains("onChange(of: code"), "不监听验证码变化")
        XCTAssertFalse(source.contains("codeLength"), "视图不判输满（判定只在 StepUpUiState.canVerify）")
        XCTAssertFalse(source.contains("code.count == 6"), "视图不判输满")
    }

    /// 半屏仍是 `.sheet` + 禁下滑；关闭走同一出口；不加点遮罩 / 下滑关闭；把手不接手势。
    func testSheetStaysLocked() throws {
        let source = try normalized(sheetSources())
        assertOnce(".interactiveDismissDisabled(true)", in: source, "禁下滑")
        let escape = occurrences(".accessibilityAction(.escape, actions.close)", in: source)
        XCTAssertGreaterThanOrEqual(escape, 1, "读屏擦除走关闭")
        assertOnce("StepUpActions.make(controller, state).close()", in: source, "系统收起走关闭出口")
        XCTAssertFalse(source.contains("presentationDragIndicator(.visible)"), "不用系统把手（系统把手可操作，brief：纯装饰）")
        XCTAssertFalse(source.contains("DragGesture"), "把手不响应拖动")
        XCTAssertFalse(source.contains("fullScreenCover"), "不换展示方式")
        XCTAssertFalse(source.contains("138"), "不写号码")
    }

    /// 消费方：iOS 目前只有提现、收款账号两页。**第三个调用点出现即红**：换手机号 / 注销落地时补真点用例再改这里（交回 §6）。
    func testConsumersAreKnown() throws {
        var hits: [String] = []
        let root = WalletVisualData.repo()
        for top in ["App/Sources", "Packages/Features/Sources", "Packages/Core/Sources"] {
            let base = root.appendingPathComponent(top)
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.contains(".walletStepUpSheet(") {
                    hits.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(hits.sorted(), ["PayoutAccountScreen.swift", "WithdrawScreen.swift"], "二次验证半屏的页面清单变了")
        for page in ["WithdrawScreen.swift", "PayoutAccountScreen.swift"] {
            let text = try normalized(walletFile(page))
            let call = ".walletStepUpSheet(stepUp, texts: texts, smsBlocked: smsGate.blocked, "
                + "verifyBlocked: verifyGate.blocked,"
            assertOnce(call, in: text, page)
        }
    }

    /// 输入类型：一次性验证码 + 数字键盘，整串一个输入框（设计 A11yFocusStepUp、brief §7）。
    func testOneInputOneTimeCode() throws {
        let source = try normalized(sheetSources())
        assertOnce(".textContentType(.oneTimeCode)", in: source, "短信自动填充")
        assertOnce(".keyboardType(.numberPad)", in: source, "数字键盘")
    }
}
