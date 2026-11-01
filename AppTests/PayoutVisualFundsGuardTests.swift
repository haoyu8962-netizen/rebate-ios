@testable import Couli
import CryptoKit
import Foundation
import XCTest

/// 资金写页硬约束：回调块、可用条件、输入绑定按底版 1df9114 字面锁定（WalletCore 逻辑文件与受保护测试的逐字节指纹在 c 组
/// `WithdrawVisualFundsGuardTests`，同步跑）。底版绿，实现后必须仍绿；变了走「需要编排裁定」，不许改基线。
final class PayoutVisualFundsGuardTests: XCTestCase {
    private let root = "Packages/Features/Sources/Wallet/"
    private let core = "Packages/Core/Sources/WalletCore/"
    private let pages = ["PayoutAccountScreen.swift", "PayoutAccountScreen+Form.swift", "PayoutFormCard.swift",
                         "IdentityScreens.swift", "LaborAgreementScreen.swift"]

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func raw(_ path: String) throws -> String {
        try String(contentsOf: WalletVisualData.repo().appendingPathComponent(path), encoding: .utf8)
    }

    /// 钱包功能目录全部源码，空白折叠（实现者可以拆文件，字面仍要在）。
    private func features() throws -> String {
        let url = WalletVisualData.repo().appendingPathComponent(root)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".swift") }
            .sorted()
        return try normalized(names.map { try raw(root + $0) }.joined(separator: "\n"))
    }

    /// 本组页面（含实现者新拆的 Payout* / Identity* / Labor* / RealName* 文件），未折叠。
    private func ownPages() throws -> String {
        let url = WalletVisualData.repo().appendingPathComponent(root)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).filter {
            $0.hasSuffix(".swift") && ["Payout", "Identity", "Labor", "RealName"].contains(where: $0.hasPrefix)
        }
        return try names.map { try raw(root + $0) }.joined(separator: "\n")
    }

    /// 三个回调块（渲染时身份 / 版本 / 半屏实例票据）一字不改。
    func testActionBlocksVerbatim() throws {
        func digest(_ file: String, _ start: String) throws -> String {
            let text = try raw(root + file)
            let from = try XCTUnwrap(text.range(of: start), "\(start) 不见了")
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: from.upperBound..<text.endIndex))
            let block = normalized(String(text[from.lowerBound..<end.upperBound]))
            return SHA256.hash(data: Data(block.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(try digest("PayoutAccountScreen.swift", "public struct PayoutActions"),
                       "b1bbd1aa51dbc53ae7f13dbcd74062230a86bae2b51d6d5adb22477b7ee0902b", "PayoutActions 被改")
        XCTAssertEqual(try digest("IdentityScreens.swift", "public struct RealNameActions"),
                       "da3b0c90c84d99db607bf8db108a1ca24bf3cc4602133a139680c2749fe6936f", "RealNameActions 被改")
        XCTAssertEqual(try digest("LaborAgreementScreen.swift", "public struct LaborActions"),
                       "36b8f425401d4bf97b11d52b7e8b5489323a529188aaf52b1953fa73f9a3013c", "LaborActions 被改")
    }

    /// 保存 / 提交 / 同意 / 签署的可用条件与回调字面。
    func testGateExpressionsVerbatim() throws {
        let source = try features()
        let lines = [
            // 收款账号
            "let saving = flowState.phase == .submitting && !flowState.awaitingIdentity",
            "isLoading: saving, isEnabled: flowState.canSubmit && !gate.blocked, fillsWidth: true, "
                + "action: actions.save",
            "if snapshot.editing, snapshot.phase == .content, flowState.pending == nil {",
            "if snapshot.editing, flowState.pending == nil {",
            "let editable = flowState.phase == .editing && flowState.pending == nil",
            ".disabled(!editable)",
            // 实名
            "isLoading: snapshot.showsSubmitting, isEnabled: controller.submitEnabled && !gate.blocked, "
                + "fillsWidth: true, action: actions.submit",
            "isEnabled: snapshot.consentChecked, fillsWidth: true, action: actions.agree",
            ".couliSheet(isPresented: snapshot.consentId != nil, dismissOnScrim: nil",
            ".disabled(!controller.available || snapshot.submitting)",
            ".accessibilityAction(.escape, actions.decline)",
            // 劳务
            "isLoading: snapshot.showsSigning, isEnabled: controller.signEnabled && !gate.blocked, "
                + "fillsWidth: true, action: actions.sign",
            ".disabled(snapshot.phase != .content)",
            ".task { controller.load() }",
        ]
        for line in lines {
            XCTAssertTrue(source.contains(normalized(line)), "资金字面被改：\(line)")
        }
    }

    /// G-W21 只能收紧：【更换收款账号】原有两个条件都在、回调不变。
    func testChangeButtonOnlyTightens() throws {
        let source = try features()
        let start = try XCTUnwrap(source.range(of: #"CouliButton(texts.text("payout.change")"#), "更换按钮不见了")
        let end = try XCTUnwrap(source.range(of: "action: actions.change", range: start.upperBound..<source.endIndex))
        let call = String(source[start.lowerBound..<end.upperBound])
        XCTAssertTrue(call.contains("snapshot.loadError == nil"), "原条件被改：\(call)")
        XCTAssertTrue(call.contains("flowState.pending == nil"), "原条件被改：\(call)")
        XCTAssertFalse(call.contains("||"), "只追加拒绝：\(call)")
    }

    /// 输入绑定仍走渲染时回调（`set` 字面）；显示如何对回由实现者定，写入口不变。
    func testInputSettersVerbatim() throws {
        let source = try features()
        for line in ["set: actions.card", "set: actions.bank", "set: actions.logon", "set: actions.payee",
                     "set: actions.name", "set: actions.idNo", "actions.method(value)"] {
            XCTAssertTrue(source.contains(line), "输入入口被改：\(line)")
        }
    }

    /// 不新增提交入口：输入法完成键、勾选顺手提交；每个写入口只接一处。
    func testNoNewWriteEntry() throws {
        let source = try ownPages()
        for banned in [".onSubmit", ".submitLabel"] {
            XCTAssertFalse(source.contains(banned), "不加输入法完成键提交：\(banned)")
        }
        for (name, count) in [("actions.save", 1), ("actions.submit", 1), ("actions.agree", 1), ("actions.sign", 1)] {
            let escaped = name.replacingOccurrences(of: ".", with: "\\.")
            let pattern = try NSRegularExpression(pattern: "(?<![A-Za-z])" + escaped + "\\b")
            let range = NSRange(source.startIndex..., in: source)
            XCTAssertEqual(pattern.numberOfMatches(in: source, range: range), count, "\(name) 只接一处")
        }
    }

    /// G-W24：实名 / 劳务真实接口不在本任务接入。
    func testRealInterfacesNotWired() throws {
        let source = try ownPages()
        for banned in ["recordConsent", "signLaborAgreement", "getLaborAgreement", "signed_version", "signedVersion"] {
            XCTAssertFalse(source.contains(banned), "G-W24：\(banned) 不进视图")
        }
    }

    /// 隐私：页面与执行器源码不打印、不埋点（身份证号、卡号、姓名只在内存）。
    func testNoLoggingInSensitiveSources() throws {
        var source = try ownPages()
        for name in ["PayoutAccountController.swift", "PayoutAccountController+Form.swift", "PayoutLogic.swift",
                     "RealNameController.swift", "LaborAgreementController.swift"] {
            source += try raw(core + name)
        }
        for banned in ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "dump(", ".track("] {
            XCTAssertFalse(source.contains(banned), "敏感页不得打印 / 埋点：\(banned)")
        }
    }

    /// 隐私：敏感输入框关自动更正（输入不进键盘词库）；不做明文持久化（不引入 @AppStorage / @SceneStorage / UserDefaults）。
    func testSensitiveInputsStayInMemory() throws {
        let source = try ownPages()
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".autocorrectionDisabled(true)").count - 1, 2)
        for banned in ["@AppStorage", "@SceneStorage", "UserDefaults"] {
            XCTAssertFalse(source.contains(banned), "敏感输入不落盘：\(banned)")
        }
    }

    /// 测量不得把完整输入报出去（Debug 场景的测量会序列化进只读元素，d r1 备注同类）。
    func testInputProbesCarryNoValue() throws {
        let source = try normalized(ownPages())
        for value in ["text: form.cardNo", "text: form.alipayLogonId", "text: form.payeeName", "text: snapshot.idNo",
                      "text: snapshot.name", "text: value"] {
            XCTAssertFalse(probeCarries(source, value), "测量带了完整输入：\(value)")
        }
    }

    private func probeCarries(_ source: String, _ value: String) -> Bool {
        source.components(separatedBy: "Probe(").dropFirst().contains { $0.prefix(120).contains(value) }
    }
}
