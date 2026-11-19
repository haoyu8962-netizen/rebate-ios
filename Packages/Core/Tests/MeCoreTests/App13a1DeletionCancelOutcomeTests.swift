import Foundation
@testable import MeCore
import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：【去提现】取值、作用域与未决映射、撤回结局表（`DeletionCancelOutcome`），以及 D10-2094 的文案口径。
/// （由 App13a1DeletionPresentationTests 拆出，r3。）
///
/// 依据：三端任务书 APP-13a/brief.md §2 第 2 项（【去提现】只在 full 会话且不是从强更进入，G12）、§2 第 4 项（撤回去向，G18）；
/// 编排 D10-2094（本单 brief.md 末尾「待改」：①撤回 10007 显示契约 error.10007；②can_cancel=false 不显示撤回、时间线停在「注销处理」、
/// 不新造句；③须知天数变量渲染，BR-TEXT-13）。
@MainActor
final class App13a1DeletionCancelOutcomeTests: XCTestCase {
    private let funds = DeletionFunds(withdrawableFen: 1000, estimatedFen: 1019, negativeFen: 0)
    private let negativeFunds = DeletionFunds(withdrawableFen: 0, estimatedFen: 0, negativeFen: 200)

    private func deletion(_ status: String, canCancel: Bool = false, reason: String? = nil) -> Deletion {
        Deletion(
            status: status, applyAtMillis: 1_790_904_600_000, coolingUntilMillis: 1_791_509_400_000,
            canCancel: canCancel, cancelledAtMillis: status == Deletion.cancelled ? 1_790_992_800_000 : nil,
            cancelReason: reason
        )
    }

    /// 一份「什么都读到了、可以申请」的输入。
    private func ready(scope: String = DeletionScope.full, source: DeletionSource = .settings) -> DeletionInput {
        DeletionInput(read: DeletionRead.none, funds: funds, phoneBound: true, scope: scope, source: source)
    }

    // MARK: - 【去提现】（G12）

    /// full 会话：除强更进入外都显示；deletion_only：一律不显示（受限会话不给表外入口）。
    func testGoWithdrawByScopeAndSource() {
        let sources: [DeletionSource] = [.settings, .forceUpdate, .riskNotice, .error10007, .other]
        for source in sources {
            let full = DeletionPresentation.view(ready(scope: DeletionScope.full, source: source))
            XCTAssertEqual(full.showGoWithdraw, source != .forceUpdate, "full × \(source.rawValue)")
            let restricted = DeletionPresentation.view(ready(scope: DeletionScope.deletionOnly, source: source))
            XCTAssertFalse(restricted.showGoWithdraw, "deletion_only × \(source.rawValue)：不显示【去提现】")
        }
    }

    /// 负余额、冷静期、读取失败等不可申请的状态下 deletion_only 也不给【去提现】。
    func testGoWithdrawNeverShownInRestrictedSessionAnyState() {
        let inputs: [DeletionInput] = [
            DeletionInput(
                read: DeletionRead.none,
                funds: negativeFunds,
                phoneBound: true,
                scope: DeletionScope.deletionOnly
            ),
            DeletionInput(read: DeletionRead.none, funds: funds, phoneBound: true, pending: .unknown,
                          scope: DeletionScope.deletionOnly),
            DeletionInput(read: DeletionRead.none, funds: funds, phoneBound: false, scope: DeletionScope.deletionOnly),
        ]
        for input in inputs {
            XCTAssertFalse(DeletionPresentation.view(input).showGoWithdraw, "\(input)")
        }
    }

    /// 作用域取值：只有 deletion_only 是受限；其余（空、nil、未知）按 full。
    func testScopeNormalization() {
        XCTAssertEqual(DeletionScope.normalized("deletion_only"), DeletionScope.deletionOnly)
        XCTAssertEqual(DeletionScope.normalized("full"), DeletionScope.full)
        XCTAssertEqual(DeletionScope.normalized(nil), DeletionScope.full)
        XCTAssertEqual(DeletionScope.normalized(""), DeletionScope.full)
    }

    /// 页面状态 → 未决：有待确认卡为 unknown，首次提交在途为 in_flight。
    func testPendingMapping() {
        XCTAssertEqual(DeletionPresentation.pending(hasPendingCard: true, submitting: true), .unknown)
        XCTAssertEqual(DeletionPresentation.pending(hasPendingCard: false, submitting: true), .inFlight)
        XCTAssertEqual(DeletionPresentation.pending(hasPendingCard: false, submitting: false), .none)
    }

    // MARK: - 撤回结局（brief §2 第 4 项）

    private func cancelOutcome(_ code: Int?, _ source: DeletionSource) -> DeletionCancelOutcome {
        DeletionCancelOutcome.of(
            code: code, source: source, serverKey: { _ in "error.50001" }, errorKey: { "error.\($0)" }
        )
    }

    /// 成功：settings → 回 Settings 并轻提示；force_update → 回强更页；其他 → 本页轻提示（G18）。
    func testCancelSuccessDestinations() {
        let settings = cancelOutcome(0, .settings)
        XCTAssertEqual(settings.next, .cancelled)
        XCTAssertEqual(settings.navigate, .settings)
        XCTAssertEqual(settings.textKey, DeletionCancelOutcome.withdrawnKey)

        XCTAssertEqual(cancelOutcome(0, .forceUpdate).navigate, .forceUpdate)

        for source in [DeletionSource.riskNotice, .error10007, .other] {
            let stay = cancelOutcome(0, source)
            XCTAssertEqual(stay.next, .cancelled, source.rawValue)
            XCTAssertEqual(stay.navigate, .none, "\(source.rawValue)：留在本页")
            XCTAssertEqual(stay.textKey, DeletionCancelOutcome.withdrawnKey, "\(source.rawValue)：同一轻提示")
        }
    }

    /// 10007：停在冷静期页，提示契约 error.10007（D10-2094 ①），然后重取 getDeletion。
    func testCancel10007StaysAndRefetches() {
        let outcome = DeletionCancelOutcome.of(
            code: 10007, source: .settings, serverKey: SensitiveOutcome.serverKey,
            errorKey: DeleteAccountController.errorKey
        )
        XCTAssertEqual(outcome.next, .stay)
        XCTAssertEqual(outcome.navigate, .none)
        XCTAssertTrue(outcome.refetch, "10007 后重取进度")
        // D10-2094 ①：冷静期已过显示契约 error.10007（08「注销页·冷静期」、设计说明「其他结果一览 ③」），不用自拟 cancel_expired
        XCTAssertEqual(outcome.textKey, "error.10007", "撤回 10007：提示契约 error.10007")
        XCTAssertNotEqual(outcome.textKey, "deletion.cooling.cancel_expired")
    }

    /// 42901：停在本页提示限流（禁用期由执行层按 Retry-After 结算）。
    func testCancel42901Stays() {
        let outcome = cancelOutcome(42901, .settings)
        XCTAssertEqual(outcome.next, .stay)
        XCTAssertEqual(outcome.textKey, "error.42901")
        XCTAssertEqual(outcome.navigate, .none)
    }

    /// 5xxxx：统一错误 + trace6，停在本页（不伪装成撤回成功或「没有申请」）。
    func testCancel5xxxxShowsTrace6() {
        let outcome = cancelOutcome(50401, .forceUpdate)
        XCTAssertEqual(outcome.next, .stay)
        XCTAssertTrue(outcome.showTrace6)
        XCTAssertEqual(outcome.navigate, .none)
    }

    /// 无响应：不自动重发，提示「暂时没有收到结果」，重取 getDeletion 核对（共性第 14、33 条）。
    func testCancelNoResponseReconcilesByRead() {
        let outcome = cancelOutcome(nil, .settings)
        XCTAssertEqual(outcome.next, .stay)
        XCTAssertTrue(outcome.refetch, "结果未知：重取进度")
        XCTAssertTrue(outcome.reconcile, "结果未知：按读取核对")
        XCTAssertEqual(outcome.navigate, .none, "核对之前不离页")
    }

    /// 核对判据：用户撤回的 cancelled 才按撤回成功结算；系统按负余额撤销的不算（G20）。
    func testCancelledByUserJudgement() {
        XCTAssertTrue(deletion(Deletion.cancelled, reason: Deletion.reasonUser).cancelledByUser)
        XCTAssertFalse(deletion(Deletion.cancelled, reason: Deletion.reasonNegative).cancelledByUser)
        XCTAssertFalse(deletion(Deletion.cooling, canCancel: true).cancelledByUser)
    }

    // MARK: - D10-2094 文案口径

    /// D10-2094 ①②：自拟句 deletion.cooling.cancel_expired（撤回 10007）与 deletion.cooling.cannot_cancel（can_cancel=false）
    /// 都删掉、不新造句；
    /// can_cancel=false 时只是不显示撤回，时间线停在「注销处理」一步，用契约的 deletion.timeline.processing / processing_desc。
    func testSelfDraftedCoolingSentencesRemoved() {
        for key in ["deletion.cooling.cancel_expired", "deletion.cooling.cannot_cancel"] {
            XCTAssertNil(AccountDraftTexts.drafts[key], "\(key)：草稿表里不再有自拟句")
            XCTAssertFalse(AccountDraftTexts().has(key), "\(key)：字典里也没有")
        }
        for key in ["deletion.timeline.processing", "deletion.timeline.processing_desc"] {
            XCTAssertTrue(AccountDraftTexts().has(key), "\(key)：时间线「注销处理」一步用契约键")
        }
        let view = DeletionPresentation.view(DeletionInput(
            read: .record(deletion(Deletion.cooling, canCancel: false)), funds: funds, phoneBound: true
        ))
        XCTAssertEqual(view.kind, .cooling)
        XCTAssertFalse(view.showCancel, "can_cancel=false：不显示撤回")
    }

    /// D10-2094 ③（BR-TEXT-13）：注销须知里的天数不写死在句子里——草稿原文没有「数字 + 天 / 个工作日」的字面量，渲染时按变量填
    /// （占位名按契约时间线同名 cooling_days / process_workdays；天数来源待 w1 盘点 D10-2094 ④）。换一组变量，渲染结果随之变。
    func testNoticeDaysRenderedFromVariables() throws {
        let texts = AccountDraftTexts()
        let keys = (1...6).map { "deletion.notice.\($0)" }
        let literal = try NSRegularExpression(pattern: "[0-9０-９]+\\s*(天|个工作日)")
        var mentionsDays = false
        var mentionsWorkdays = false
        for key in keys {
            let raw = try XCTUnwrap(AccountDraftTexts.drafts[key], "\(key)：须知仍是草稿占位")
            let range = NSRange(raw.startIndex..., in: raw)
            XCTAssertNil(literal.firstMatch(in: raw, range: range), "\(key)：天数不写死在句子里：\(raw)")
            mentionsDays = mentionsDays || raw.contains("天")
            mentionsWorkdays = mentionsWorkdays || raw.contains("工作日")
        }
        XCTAssertTrue(mentionsDays, "前提：须知里有冷静期天数")
        XCTAssertTrue(mentionsWorkdays, "前提：须知里有处理工作日")
        let first = keys.map { texts.format($0, ["cooling_days": "31", "process_workdays": "42"]) }.joined()
        let second = keys.map { texts.format($0, ["cooling_days": "53", "process_workdays": "64"]) }.joined()
        XCTAssertTrue(first.contains("31") && first.contains("42"), "按变量渲染：\(first)")
        XCTAssertTrue(second.contains("53") && second.contains("64"), "按变量渲染：\(second)")
        XCTAssertFalse(first.contains("53") || second.contains("31"), "两组变量互不串")
    }
}
