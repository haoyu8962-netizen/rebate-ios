import Foundation
@testable import MeCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：注销页显示规则（纯值输入 `DeletionInput` → `DeletionView`）与撤回结局表（`DeletionCancelOutcome`）。
///
/// 依据：三端任务书 APP-13a/brief.md §2 第 2 项（四态、优先级 pending_confirm > load_failed > cooling / processing > negative >
/// funds_unavailable > initial；【去提现】只在 full 会话且不是从强更进入，G12；【撤回注销】只看服务端 can_cancel，G15；cancelled 按 initial、
/// 是否为负只看 negative_fen，G20；getDeletion 失败申请与撤回都不可用，§0「trace6」）、§2 第 4 项（撤回去向，G18）；
/// 共性第 10、34 条（30416 本次金额优先、资格按明确刷新）、第 46 条（待确认卡独立于读取）。
final class App13a1DeletionPresentationTests: XCTestCase {
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

    // MARK: - 四态与优先级

    /// 从未申请、资金读到、已绑手机：initial，勾选可用、勾选后可申请，没有撤回。
    func testInitialAllowsWaiverAndApply() {
        let view = DeletionPresentation.view(ready())
        XCTAssertEqual(view.kind, .initial)
        XCTAssertTrue(view.waiverEnabled)
        XCTAssertTrue(view.applyEnabledWhenChecked)
        XCTAssertFalse(view.showCancel)
        XCTAssertFalse(view.showContactService)
        XCTAssertEqual(view.funds, funds, "资金区显示读到的三项")
    }

    /// 待确认优先于一切（读取失败、冷静期、负余额）：卡片在，勾选与申请置灰（BR-ID-10「发起页按未决记录进入待确认」、共性第 46 条）。
    func testPendingConfirmBeatsEverything() {
        let inputs: [DeletionInput] = [
            DeletionInput(read: nil, readFailed: true, pending: .unknown),
            DeletionInput(read: .record(deletion(Deletion.cooling, canCancel: true)), funds: funds, pending: .unknown),
            DeletionInput(read: DeletionRead.none, funds: negativeFunds, pending: .unknown),
            DeletionInput(read: DeletionRead.none, fundsFailed: true, pending: .unknown),
            // 待确认卡不等 getDeletion 返回（共性第 46 条）
            DeletionInput(read: nil, pending: .unknown),
        ]
        for input in inputs {
            let view = DeletionPresentation.view(input)
            XCTAssertEqual(view.kind, .pendingConfirm, "\(input)")
            XCTAssertFalse(view.waiverEnabled, "待确认：勾选置灰")
            XCTAssertFalse(view.applyEnabledWhenChecked, "待确认：申请置灰")
            XCTAssertFalse(view.showCancel, "待确认：没有撤回")
        }
    }

    /// 读取失败（失败或坏数据）优先于冷静期 / 负余额：整页错误，申请与撤回都不可用——不能把读取失败当成「从未申请」。
    func testLoadFailedDisablesApplyAndCancel() {
        let inputs: [DeletionInput] = [
            DeletionInput(read: nil, readFailed: true, funds: funds, phoneBound: true),
            DeletionInput(read: .bad, funds: funds, phoneBound: true),
            // 读过一次冷静期，之后重读失败：不按旧值显示撤回
            DeletionInput(
                read: .record(deletion(Deletion.cooling, canCancel: true)), readFailed: true, funds: funds,
                phoneBound: true
            ),
            DeletionInput(read: nil, readFailed: true, funds: negativeFunds, phoneBound: true),
            DeletionInput(read: .bad, funds: funds, phoneBound: true, blocked30416: true, amount30416: 567),
        ]
        for input in inputs {
            let view = DeletionPresentation.view(input)
            XCTAssertEqual(view.kind, .loadFailed, "\(input)")
            XCTAssertFalse(view.applyEnabledWhenChecked, "读取失败：申请不可用")
            XCTAssertFalse(view.waiverEnabled, "读取失败：勾选不可用")
            XCTAssertFalse(view.showCancel, "读取失败：撤回不可用")
            XCTAssertNotEqual(view.kind, .initial, "读取失败不当成从未申请")
        }
    }

    /// 还在读进度：申请与撤回都不可用（不先显示 initial 让冷静期用户再点申请）。
    func testLoadingDisablesApply() {
        let view = DeletionPresentation.view(DeletionInput(read: nil, funds: funds, phoneBound: true))
        XCTAssertNotEqual(view.kind, .initial)
        XCTAssertFalse(view.applyEnabledWhenChecked)
        XCTAssertFalse(view.showCancel)
    }

    /// 冷静期：【撤回注销】只看 can_cancel（G15，客户端不按本机时钟推算）；申请不可用。
    func testCoolingCancelFollowsCanCancelOnly() {
        let canCancel = DeletionPresentation.view(DeletionInput(
            read: .record(deletion(Deletion.cooling, canCancel: true)), funds: funds, phoneBound: true
        ))
        XCTAssertEqual(canCancel.kind, .cooling)
        XCTAssertTrue(canCancel.showCancel)
        XCTAssertFalse(canCancel.applyEnabledWhenChecked)
        XCTAssertFalse(canCancel.waiverEnabled)

        let cannot = DeletionPresentation.view(DeletionInput(
            read: .record(deletion(Deletion.cooling, canCancel: false)), funds: funds, phoneBound: true
        ))
        XCTAssertEqual(cannot.kind, .cooling)
        XCTAssertFalse(cannot.showCancel, "can_cancel=false：没有【撤回注销】")
    }

    /// 冷静期优先于负余额与本次 30416（共性第 34 条：进度状态仍按优先级展示，不被 30416 标记覆盖）。
    func testCoolingBeatsNegativeAnd30416() {
        let view = DeletionPresentation.view(DeletionInput(
            read: .record(deletion(Deletion.cooling, canCancel: true)), funds: negativeFunds, phoneBound: true,
            blocked30416: true, amount30416: 567
        ))
        XCTAssertEqual(view.kind, .cooling)
        XCTAssertTrue(view.showCancel)
    }

    /// processing / done：只提示，没有操作（brief §2 第 2 项）。
    func testProcessingAndDoneHaveNoActions() {
        for status in [Deletion.processing, Deletion.done] {
            let view = DeletionPresentation.view(DeletionInput(
                read: .record(deletion(status)), funds: funds, phoneBound: true, blocked30416: true, amount30416: 1
            ))
            XCTAssertEqual(view.kind, .processing, status)
            XCTAssertFalse(view.applyEnabledWhenChecked)
            XCTAssertFalse(view.waiverEnabled)
            XCTAssertFalse(view.showCancel)
            XCTAssertFalse(view.showGoWithdraw)
        }
    }

    /// 进页 negative_fen > 0：负余额态，金额取 negative_fen，【联系客服】，勾选与申请置灰（BR-ID-27「进页即提示」、AC-S2-58 ①）。
    func testEntryNegativeBalance() {
        let view = DeletionPresentation.view(DeletionInput(read: DeletionRead.none, funds: negativeFunds, phoneBound: true))
        XCTAssertEqual(view.kind, .negative)
        XCTAssertEqual(view.negativeFen, 200)
        XCTAssertFalse(view.negativeFromSubmit, "进页提示的来源是 negative_fen")
        XCTAssertTrue(view.showContactService)
        XCTAssertFalse(view.waiverEnabled)
        XCTAssertFalse(view.applyEnabledWhenChecked)
    }

    /// cancelled（含系统按负余额撤销）按 initial 判断，是否为负只看这一次 negative_fen（G20、AC-S2-60 ④）。
    func testCancelledFollowsInitialAndNegativeFen() {
        for reason in [Deletion.reasonUser, Deletion.reasonNegative] {
            let negative = DeletionPresentation.view(DeletionInput(
                read: .record(deletion(Deletion.cancelled, reason: reason)), funds: negativeFunds, phoneBound: true
            ))
            XCTAssertEqual(negative.kind, .negative, "cancelled(\(reason)) + negative_fen>0")
            let back = DeletionPresentation.view(DeletionInput(
                read: .record(deletion(Deletion.cancelled, reason: reason)), funds: funds, phoneBound: true
            ))
            XCTAssertEqual(back.kind, .initial, "cancelled(\(reason)) + 回正：可重新申请")
            XCTAssertTrue(back.applyEnabledWhenChecked)
        }
    }

    // MARK: - 30416 本次金额与资格

    /// 本次 30416 金额优先于进页 negative_fen（共性第 10 条）。
    func testSubmit30416AmountBeatsEntryNegativeFen() {
        let view = DeletionPresentation.view(DeletionInput(
            read: DeletionRead.none, funds: negativeFunds, phoneBound: true, blocked30416: true, amount30416: 567
        ))
        XCTAssertEqual(view.kind, .negative)
        XCTAssertEqual(view.negativeFen, 567, "提示金额取本次响应 amount_fen，不取 negative_fen 200")
        XCTAssertTrue(view.negativeFromSubmit)
        XCTAssertTrue(view.showContactService)
    }

    /// 30416 不带 amount_fen：金额为空（页面用 fallbacks 里不带金额的句子），不拿 negative_fen 补。
    func testSubmit30416WithoutAmountUsesFallback() {
        let view = DeletionPresentation.view(DeletionInput(
            read: DeletionRead.none, funds: negativeFunds, phoneBound: true, blocked30416: true, amount30416: nil
        ))
        XCTAssertEqual(view.kind, .negative)
        XCTAssertNil(view.negativeFen, "缺金额走兜底句，不用 negative_fen 补")
        XCTAssertTrue(view.negativeFromSubmit)
    }

    /// 30416 之后自动重读到 negative_fen = 0：仍是负余额态（资格只在明确刷新后更新，共性第 34 条），申请置灰。
    func testSubmit30416StaysBlockedAfterAutomaticReadShowsZero() {
        let view = DeletionPresentation.view(DeletionInput(
            read: DeletionRead.none, funds: funds, phoneBound: true, blocked30416: true, amount30416: 567
        ))
        XCTAssertEqual(view.kind, .negative)
        XCTAssertEqual(view.negativeFen, 567)
        XCTAssertFalse(view.applyEnabledWhenChecked)
    }

    // MARK: - 资金区

    /// 钱包摘要读取失败：funds_unavailable，申请置灰（申请前必须展示余额，BR-ID-27）；5xxxx 不伪装成「余额为 0」。
    func testFundsFailedDisablesApply() {
        let view = DeletionPresentation.view(DeletionInput(read: DeletionRead.none, fundsFailed: true, phoneBound: true))
        XCTAssertEqual(view.kind, .fundsUnavailable)
        XCTAssertFalse(view.applyEnabledWhenChecked)
        XCTAssertNil(view.funds, "没读到不显示数字")
    }

    /// 资金还没读到：申请置灰（必须先展示余额）。
    func testFundsNotYetReadDisablesApply() {
        let view = DeletionPresentation.view(DeletionInput(read: DeletionRead.none, phoneBound: true))
        XCTAssertFalse(view.applyEnabledWhenChecked)
    }

    /// 负余额优先于资金读取失败的判断只在读到时成立；读取失败优先于 initial（优先级 negative > funds_unavailable > initial）。
    func testNegativeBeatsFundsUnavailableOrder() {
        // 30416 标记在、资金读取失败：仍是负余额（negative > funds_unavailable）
        let view = DeletionPresentation.view(DeletionInput(
            read: DeletionRead.none, fundsFailed: true, phoneBound: true, blocked30416: true, amount30416: 300
        ))
        XCTAssertEqual(view.kind, .negative)
        XCTAssertEqual(view.negativeFen, 300)
    }

    /// 未绑手机（phone_bound=false）：申请可点，点后只提示 BR-ID-08 原句、不发请求（G10；显示层只管可点）。
    func testNoPhoneStillClickable() {
        let view = DeletionPresentation.view(DeletionInput(read: DeletionRead.none, funds: funds, phoneBound: false))
        XCTAssertEqual(view.kind, .noPhone)
        XCTAssertTrue(view.applyEnabledWhenChecked)
    }

    /// 本进程首次提交在途：勾选与申请不可用（不重复提交）。
    func testInFlightDisablesApply() {
        var input = ready()
        input.pending = .inFlight
        let view = DeletionPresentation.view(input)
        XCTAssertFalse(view.applyEnabledWhenChecked)
        XCTAssertFalse(view.waiverEnabled)
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
            DeletionInput(read: DeletionRead.none, funds: negativeFunds, phoneBound: true, scope: DeletionScope.deletionOnly),
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

    /// 10007：停在冷静期页，提示撤回已不可用，然后重取 getDeletion。
    func testCancel10007StaysAndRefetches() {
        let outcome = cancelOutcome(10007, .settings)
        XCTAssertEqual(outcome.next, .stay)
        XCTAssertEqual(outcome.navigate, .none)
        XCTAssertTrue(outcome.refetch, "10007 后重取进度")
        XCTAssertNotEqual(outcome.textKey, DeletionCancelOutcome.withdrawnKey)
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
}
