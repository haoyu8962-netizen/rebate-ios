import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// APP-13a-1-ios 写测 r4（独立写测方，首轮评审 S3-3）：本单给共用结局表加了 op = account_deletion 的专用分支
/// （`deletionSubmit` / `deletionConfirm` / `businessText`），提现（withdraw）与改收款（payout_account）不得回归。
///
/// 期望值按基线 5f64ef0 的 `SensitiveOutcome.swift` 规则推出（不从新代码抄）：
/// - 首次提交：10007 / 10010 不在 `shared` / `prerequisite` / `submitEnded` 里、也不是 3xxxx → show_error_key_ends，键结束、
///   下次新键，文案 `errorKey`（字典有 error.10007 / error.10010）；5xxxx → `submitEnded` 的 error_trace6，键结束、新键、trace6，
///   文案 `serverKey`（已收录 error.50401；未收录 59999 回落 error.50001）；表外 3xxxx → show_error_key_ends，键结束、新键，
///   文案 `businessKey` = `errorKey`（字典有 error.30406；没有 error.39999 → error.50001），route = `stayRoute` = nil。
/// - 确认上一笔：10007 / 10010 不在 `keptPending`、不是 20903、不是 3xxxx、不是 2xxxx → `.pending(retry_later)`（键不结束、
///   原键）；5xxxx → `.pending(retry_later, trace: true)`；表外 3xxxx → show_error_key_ends，键结束、新键，文案同上，route nil。
/// 文案键对应 Generated 的 texts.default.json（error.10007、error.10010、error.30406、error.50401 已收录；39999、59999 未收录）。
final class App13a1NonDeletionBaselineTests: XCTestCase {
    private struct Expected {
        let action: String
        let ends: Bool
        let newKey: Bool
        let text: String
        let trace6: Bool
    }

    private struct Row {
        let code: Int
        let expected: Expected
    }

    private let ops = [SensitiveOutcome.withdraw, SensitiveOutcome.payoutAccount]

    private func ended(_ action: String, _ text: String, trace6: Bool = false) -> Expected {
        Expected(action: action, ends: true, newKey: true, text: text, trace6: trace6)
    }

    private func retryLater(trace6: Bool = false) -> Expected {
        Expected(action: SensitiveOutcome.pendingConfirm, ends: false, newKey: false,
                 text: SensitiveOutcome.retryLaterKey, trace6: trace6)
    }

    private var submitRows: [Row] {
        let shown = SensitiveOutcome.showErrorKeyEnds
        let trace = SensitiveOutcome.errorTrace6
        return [
            Row(code: 10007, expected: ended(shown, "error.10007")),
            Row(code: 10010, expected: ended(shown, "error.10010")),
            Row(code: 50401, expected: ended(trace, "error.50401", trace6: true)),
            Row(code: 59999, expected: ended(trace, "error.50001", trace6: true)),
            Row(code: 39999, expected: ended(shown, "error.50001")),
            Row(code: 30406, expected: ended(shown, "error.30406")),
        ]
    }

    private var confirmRows: [Row] {
        let shown = SensitiveOutcome.showErrorKeyEnds
        return [
            Row(code: 10007, expected: retryLater()),
            Row(code: 10010, expected: retryLater()),
            Row(code: 50401, expected: retryLater(trace6: true)),
            Row(code: 59999, expected: retryLater(trace6: true)),
            Row(code: 39999, expected: ended(shown, "error.50001")),
            Row(code: 30406, expected: ended(shown, "error.30406")),
        ]
    }

    private func assertOutcome(
        _ outcome: Outcome, _ expected: Expected, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(outcome.actionRaw, expected.action, "\(label)：action", file: file, line: line)
        XCTAssertEqual(outcome.keyEnds, expected.ends, "\(label)：键是否结束", file: file, line: line)
        XCTAssertEqual(outcome.nextSubmitNewKey, expected.newKey, "\(label)：下次是否新键", file: file, line: line)
        XCTAssertEqual(outcome.textKey, expected.text, "\(label)：文案键", file: file, line: line)
        XCTAssertNil(outcome.route, "\(label)：route", file: file, line: line)
        XCTAssertEqual(outcome.showTrace6, expected.trace6, "\(label)：trace6", file: file, line: line)
        XCTAssertNil(outcome.disableMillis, "\(label)：禁用期", file: file, line: line)
    }

    private func error(_ code: Int) -> OutcomeInput {
        OutcomeInput(OutcomeInput.errorKind, code: code)
    }

    /// 首次提交（从未结果未知、结果未知过的键都一样）：与基线规则相同。
    func testSubmitMatchesBaselineForWithdrawAndPayout() {
        for op in ops {
            for row in submitRows {
                for everUnknown in [false, true] {
                    let outcome = SensitiveOutcome.of(
                        op: op, phase: SensitiveOutcome.submit, keyEverUnknown: everUnknown, input: error(row.code)
                    )
                    assertOutcome(outcome, row.expected, "\(op) 提交 \(row.code)（曾未知 \(everUnknown)）")
                }
            }
        }
    }

    /// 确认上一笔：与基线规则相同（10007 / 10010 / 5xxxx 保持待确认；表外 3xxxx 键结束）。
    func testConfirmMatchesBaselineForWithdrawAndPayout() {
        for op in ops {
            for row in confirmRows {
                let outcome = SensitiveOutcome.of(
                    op: op, phase: SensitiveOutcome.confirm, keyEverUnknown: true, input: error(row.code)
                )
                assertOutcome(outcome, row.expected, "\(op) 确认 \(row.code)")
            }
        }
    }

    /// 对照：同样的码对 account_deletion 走专用分支（证明上面两条确实覆盖到了分叉点，而不是两边恰好同一路径）。
    func testDeletionDivergesOnSameCodes() {
        let deletion = SensitiveOutcome.accountDeletion
        let submit10007 = SensitiveOutcome.of(
            op: deletion, phase: SensitiveOutcome.submit, keyEverUnknown: false, input: error(10007)
        )
        XCTAssertEqual(submit10007.actionRaw, SensitiveOutcome.deletionLocked)
        let submit39999 = SensitiveOutcome.of(
            op: deletion, phase: SensitiveOutcome.submit, keyEverUnknown: false, input: error(39999)
        )
        XCTAssertEqual(submit39999.textKey, "error.39999")
        let confirm10007 = SensitiveOutcome.of(
            op: deletion, phase: SensitiveOutcome.confirm, keyEverUnknown: true, input: error(10007)
        )
        XCTAssertEqual(confirm10007.actionRaw, SensitiveOutcome.showErrorKeepPending)
    }
}
