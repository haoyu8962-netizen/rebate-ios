import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// APP-13a-1-ios 写测（独立写测方）：申请注销（op = account_deletion）的结局表——申请 / 确认上一次 / 放弃上一次 × 各响应类别。
/// 只断言三件事：键是否结束（keyEnds）、下次点击是否用新键（nextSubmitNewKey）、提示键（textKey）；必要时附 42901 禁用毫秒、trace6。
///
/// 依据（按优先级）：
/// - 契约 openapi requestDeletion x-error-codes [30412, 30416, 10003, 20903, 10010]；error-codes 10007 / 20903 / 40901 /
/// 10405；
/// - 三端任务书 APP-13a/brief.md §0 第 1 条（键只在业务成功、写入幂等记录的 3xxxx、已作废三种结果下结束；其余 1xxxx、20903 以外的 2xxxx、
///   40901、42901、5xxxx、10405、无响应都不结束；**从未结果未知**的键只在 42901、明确的 40901、20001–20003、44001 后结束、下次用新键），
///   §2 第 3 项（申请 / 确认 / 放弃各分支），G26（表外 3xxxx 显示 error.<code>、回落服务端 msg，键结束）；
/// - 共性 cross-platform-lessons 第 7、22 条（10007 / 5xxxx / 10405 等非终结响应保留原键：nextKey = same；补办码从未未知时补办后再点用新键）。
/// 不按实现反推：与依据不符的用例应当红（见回报「按依据判定的实现缺陷」）。
final class App13a1DeletionOutcomeTests: XCTestCase {
    private let op = SensitiveOutcome.accountDeletion

    // MARK: - 构造

    private func submit(_ input: OutcomeInput, everUnknown: Bool = false) -> Outcome {
        SensitiveOutcome.of(op: op, phase: SensitiveOutcome.submit, keyEverUnknown: everUnknown, input: input)
    }

    private func confirm(_ input: OutcomeInput) -> Outcome {
        SensitiveOutcome.of(op: op, phase: SensitiveOutcome.confirm, keyEverUnknown: true, input: input)
    }

    private func abandon(_ input: OutcomeInput) -> Outcome {
        SensitiveOutcome.of(op: op, phase: SensitiveOutcome.abandon, keyEverUnknown: true, input: input)
    }

    private func error(_ code: Int, data: [String: String] = [:], retryAfter: Int64? = nil) -> OutcomeInput {
        OutcomeInput(OutcomeInput.errorKind, code: code, data: data, retryAfterMillis: retryAfter)
    }

    private var ok: OutcomeInput {
        OutcomeInput(OutcomeInput.okKind)
    }

    private var noResponse: OutcomeInput {
        OutcomeInput(OutcomeInput.transportKind)
    }

    private func assertKey(
        _ outcome: Outcome, ends: Bool, newKey: Bool, text: String?, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(outcome.keyEnds, ends, "\(label)：键是否结束", file: file, line: line)
        XCTAssertEqual(outcome.nextSubmitNewKey, newKey, "\(label)：下次点击是否用新键", file: file, line: line)
        if let text {
            XCTAssertEqual(outcome.textKey, text, "\(label)：提示键", file: file, line: line)
        }
    }

    // MARK: - 申请（首次提交，从未结果未知）

    /// 成功：键结束、下次新键（brief §0 第 1 条「业务成功」）。
    func testSubmitSuccessEndsKey() {
        let outcome = submit(ok)
        assertKey(outcome, ends: true, newKey: true, text: nil, "申请成功")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.done)
    }

    /// 10003：弹二次验证、沿用原键重放（BR-ID-08「10003 后沿用原键」；error-codes 10003）。
    func testSubmit10003StepsUpWithSameKey() {
        let outcome = submit(error(10003))
        assertKey(outcome, ends: false, newKey: false, text: nil, "申请 10003")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.stepUp)
    }

    /// 10002：网络层原键自动重发（brief §0 第 1 条「自动重发」）。
    func testSubmit10002ResendsWithSameKey() {
        let outcome = submit(error(10002))
        assertKey(outcome, ends: false, newKey: false, text: nil, "申请 10002")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.autoResend)
    }

    /// 10001 / 10004 / 10005：只引导补办、不重放；从未结果未知的键补办后再点用新键（共性第 22 条、brief §0 第 2 条）。
    func testSubmitPrerequisitesGuideAndNextClickUsesNewKey() {
        let cases: [(Int, String?)] = [(10001, WalletRoutes.login), (10004, nil), (10005, WalletRoutes.bindPhone)]
        for (code, route) in cases {
            let outcome = submit(error(code))
            assertKey(outcome, ends: true, newKey: true, text: "error.\(code)", "申请 \(code)")
            XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.guide, "申请 \(code)：引导补办")
            if let route {
                XCTAssertEqual(outcome.route, route, "申请 \(code)：补办去向")
            }
            XCTAssertNotEqual(outcome.actionRaw, SensitiveOutcome.pendingConfirm, "申请 \(code)：不进待确认")
        }
    }

    /// 30416（带 / 不带 amount_fen）：写入幂等记录的 3xxxx，键结束、下次新键，提示 error.30416（金额由页面取本次响应，见显示规则测试）。
    func testSubmit30416EndsKeyWithOrWithoutAmount() {
        // amount_fen 是数字，不进字符串 data；带不带金额都只影响页面句子，不影响键
        for input in [error(30416), error(30416, data: ["note": "no-amount"])] {
            let outcome = submit(input)
            assertKey(outcome, ends: true, newKey: true, text: "error.30416", "申请 30416")
            XCTAssertNotEqual(outcome.actionRaw, SensitiveOutcome.pendingConfirm)
        }
    }

    /// 30412：键结束、下次新键，提示 error.30412（error-codes「仅提示」；brief §2 第 3 项）。
    func testSubmit30412EndsKey() {
        let outcome = submit(error(30412))
        assertKey(outcome, ends: true, newKey: true, text: "error.30412", "申请 30412")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.showErrorKeyEnds)
    }

    /// 表外 3xxxx：键结束（G26：写入了幂等记录的 3xxxx）。
    func testSubmitUnlistedBusinessCodeEndsKey() {
        let outcome = submit(error(39999))
        assertKey(outcome, ends: true, newKey: true, text: nil, "申请表外 3xxxx")
        XCTAssertNotEqual(outcome.actionRaw, SensitiveOutcome.pendingConfirm)
    }

    /// 表外 3xxxx 的提示：显示 error.<code>、回落服务端 msg（G26）；不能伪装成 5xxxx 的「服务繁忙」error.50001（APP-06b 第 19 条同口径）。
    func testSubmitUnlistedBusinessCodeDoesNotFallBackToServerBusy() {
        let outcome = submit(error(39999))
        XCTAssertNotEqual(outcome.textKey, "error.50001", "表外 3xxxx 回落服务端 msg，不显示 error.50001")
    }

    /// 20903：已作废，键结束，提示 error.20903（brief §2 第 3 项「20903：键结束，回到初始态」）。
    func testSubmit20903EndsKey() {
        let outcome = submit(error(20903))
        assertKey(outcome, ends: true, newKey: true, text: "error.20903", "申请 20903")
    }

    /// 10007（stage = cooling / processing）：停在本页、提示 error.10007、重取进度；键不结束、下次沿用原键（G27、共性第 7、22 条）。
    func testSubmit10007KeepsKeyForBothStages() {
        for stage in ["cooling", "processing"] {
            let outcome = submit(error(10007, data: ["stage": stage]))
            assertKey(outcome, ends: false, newKey: false, text: "error.10007", "申请 10007 \(stage)")
            XCTAssertNotEqual(outcome.actionRaw, SensitiveOutcome.pendingConfirm, "10007 不是结果未知")
        }
    }

    /// 10010（待加验，契约 requestDeletion x-error-codes；不写幂等结果、不消耗 token）：是 1xxxx，按 brief §0 第 1 条不结束键；
    /// 「从未结果未知即结束」的例外清单里没有它（只有 42901、40901、20001–20003、44001），所以下次沿用原键。
    func testSubmit10010DoesNotEndKey() {
        let outcome = submit(error(10010, data: ["method": "manual"]))
        assertKey(outcome, ends: false, newKey: false, text: "error.10010", "申请 10010")
    }

    /// 40901（明确的同键在途）、从未结果未知：这个键结束，下次新键（APP-09 编排者补充，brief §0 第 1 条）。
    func testSubmit40901NeverUnknownEndsKey() {
        let outcome = submit(error(40901))
        assertKey(outcome, ends: true, newKey: true, text: "error.40901", "申请 40901")
    }

    /// 42901、从未结果未知：键结束、下次新键；按 Retry-After 禁用，缺省或非法 5 秒（brief §0「Retry-After」）。
    func testSubmit42901DisablesAndEndsKey() {
        let withHeader = submit(error(42901, retryAfter: 12000))
        assertKey(withHeader, ends: true, newKey: true, text: "error.42901", "申请 42901")
        XCTAssertEqual(withHeader.disableMillis, 12000, "按 Retry-After 禁用")
        let fallback = submit(error(42901))
        XCTAssertEqual(fallback.disableMillis, 5000, "Retry-After 缺省：5 秒")
    }

    /// 5xxxx：统一错误 + trace6（未收录回落 error.50001）；键不结束、下次沿用原键（任务书 13a-1 §1「5xxxx 不换键」、共性第 7、22 条）。
    func testSubmit5xxxxKeepsKeyWithTrace6() {
        let known = submit(error(50401))
        assertKey(known, ends: false, newKey: false, text: "error.50401", "申请 50401")
        XCTAssertTrue(known.showTrace6, "5xxxx 附 trace6")
        let unknown = submit(error(59999))
        assertKey(unknown, ends: false, newKey: false, text: "error.50001", "申请未收录 5xxxx")
        XCTAssertTrue(unknown.showTrace6)
        XCTAssertNotEqual(known.actionRaw, SensitiveOutcome.pendingConfirm, "5xxxx 有统一外壳，不是结果未知")
    }

    /// 10405（requestDeletion 版本闸门 false，理论上不出现）：若出现只接已有分流；10405 不结束未决键，下次沿用原键（共性第 22 条：
    /// 「50401 / 10405 等非终结响应 nextKeyRaw=same」，brief §0「10405 不结束未决键」）。
    func testSubmit10405KeepsKey() {
        let outcome = submit(error(10405))
        assertKey(outcome, ends: false, newKey: false, text: nil, "申请 10405")
    }

    /// 无响应（超时、断连、网关错误页）：进待确认，不换键、不自动重发（brief §0 第 1 条「结果未知」）。
    func testSubmitNoResponseEntersPendingWithSameKey() {
        let outcome = submit(noResponse)
        assertKey(outcome, ends: false, newKey: false, text: nil, "申请无响应")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.pendingConfirm)
    }

    // MARK: - 确认上一次提交（出现过结果未知的键）

    func testConfirmSuccessEndsKey() {
        let outcome = confirm(ok)
        assertKey(outcome, ends: true, newKey: true, text: nil, "确认成功")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.done)
    }

    /// 确认得到 10003：二次验证照常、沿用原键（brief §2 第 3 项「确认」）。
    func testConfirm10003StepsUpWithSameKey() {
        let outcome = confirm(error(10003))
        assertKey(outcome, ends: false, newKey: false, text: nil, "确认 10003")
        XCTAssertEqual(outcome.actionRaw, SensitiveOutcome.stepUp)
    }

    /// 确认得到 3xxxx（30416 / 30412 / 表外）：键结束，显示原结果（brief §2 第 3 项）。
    func testConfirmBusinessCodesEndKey() {
        for code in [30416, 30412] {
            assertKey(confirm(error(code)), ends: true, newKey: true, text: "error.\(code)", "确认 \(code)")
        }
        assertKey(confirm(error(39999)), ends: true, newKey: true, text: nil, "确认表外 3xxxx")
    }

    /// 确认得到 20903：键结束，提示 pending_confirm.abandoned 或 error.20903（brief §2 第 3 项）。
    func testConfirm20903EndsKey() {
        let outcome = confirm(error(20903))
        assertKey(outcome, ends: true, newKey: true, text: nil, "确认 20903")
        XCTAssertTrue(
            [SensitiveOutcome.abandonedKey, "error.20903"].contains(outcome.textKey ?? ""),
            "确认 20903 的提示键：\(outcome.textKey ?? "nil")"
        )
    }

    /// 确认得到 10001 / 10004 / 10005：补办后仍是待确认，键不结束（brief §0 第 2 条「该键出现过结果未知的除外」）。
    func testConfirmPrerequisitesKeepPending() {
        for code in [10001, 10004, 10005] {
            let outcome = confirm(error(code))
            assertKey(outcome, ends: false, newKey: false, text: "error.\(code)", "确认 \(code)")
        }
    }

    /// 确认得到 20903 以外的 2xxxx：pending_confirm.cannot_confirm，保持待确认（brief §2 第 3 项）。
    func testConfirmOther2xxxxCannotConfirm() {
        for code in [20002, 20003] {
            assertKey(
                confirm(error(code)), ends: false, newKey: false, text: SensitiveOutcome.cannotConfirmKey, "确认 \(code)"
            )
        }
    }

    /// 确认得到 40901 / 42901 / 5xxxx / 无响应：pending_confirm.retry_later，保持待确认；42901 另按 Retry-After 禁用（brief §2 第 3 项）。
    func testConfirmRetryLaterFamilyKeepsPending() {
        assertKey(confirm(error(40901)), ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "确认 40901")
        let limited = confirm(error(42901, retryAfter: 8000))
        assertKey(limited, ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "确认 42901")
        XCTAssertEqual(limited.disableMillis, 8000)
        let server = confirm(error(50001))
        assertKey(server, ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "确认 5xxxx")
        XCTAssertTrue(server.showTrace6, "确认 5xxxx 附 trace6")
        assertKey(confirm(noResponse), ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "确认无响应")
    }

    /// 确认得到 10007：只说明账号已在冷静期，说明不了这个键有没有结果，键不结束（brief §2 第 3 项「10007：重取 getDeletion，键不结束」）。
    func testConfirm10007KeepsPending() {
        for stage in ["cooling", "processing"] {
            assertKey(confirm(error(10007, data: ["stage": stage])), ends: false, newKey: false, text: nil, "确认 10007")
        }
    }

    /// 确认得到 10010 / 10405：不结束键（brief §0 第 1 条）。
    func testConfirm10010And10405KeepPending() {
        assertKey(confirm(error(10010)), ends: false, newKey: false, text: nil, "确认 10010")
        assertKey(confirm(error(10405)), ends: false, newKey: false, text: nil, "确认 10405")
    }

    // MARK: - 放弃上一次提交

    /// abandoned：pending_confirm.abandoned，键结束、回初始态（brief §2 第 3 项「放弃」）。
    func testAbandonAbandonedEndsKey() {
        let outcome = abandon(.abandonResult(SensitiveOutcome.abandoned))
        assertKey(outcome, ends: true, newKey: true, text: SensitiveOutcome.abandonedKey, "放弃 abandoned")
    }

    /// completed 且原结果 code 0：pending_confirm.already_done，切冷静期（键结束）。
    func testAbandonCompletedSuccessEndsKey() {
        let outcome = abandon(.abandonResult("completed", originalCode: 0))
        assertKey(outcome, ends: true, newKey: true, text: SensitiveOutcome.alreadyDoneKey, "放弃 completed 0")
    }

    /// completed 且原结果 3xxxx（如 30416）：显示该错误，键结束。
    func testAbandonCompletedBusinessErrorEndsKey() {
        let outcome = abandon(.abandonResult("completed", originalCode: 30416))
        assertKey(outcome, ends: true, newKey: true, text: "error.30416", "放弃 completed 30416")
    }

    /// 40901：pending_confirm.abandon_busy，保持待确认（error-codes 40901「作废时保持待确认」）。
    func testAbandon40901Busy() {
        assertKey(
            abandon(error(40901)), ends: false, newKey: false, text: SensitiveOutcome.abandonBusyKey, "放弃 40901"
        )
    }

    /// 其他（42901、5xxxx、10405、无响应）：retry_later，保持待确认（brief §2 第 3 项「其他：retry_later」）。
    func testAbandonOthersRetryLater() {
        let limited = abandon(error(42901, retryAfter: 3000))
        assertKey(limited, ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "放弃 42901")
        XCTAssertEqual(limited.disableMillis, 3000)
        assertKey(abandon(error(50001)), ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "放弃 5xxxx")
        assertKey(abandon(error(10405)), ends: false, newKey: false, text: nil, "放弃 10405")
        assertKey(abandon(noResponse), ends: false, newKey: false, text: SensitiveOutcome.retryLaterKey, "放弃无响应")
    }

    /// 作废接口直接得到 20903：已作废，键结束。
    func testAbandon20903EndsKey() {
        assertKey(abandon(error(20903)), ends: true, newKey: true, text: nil, "放弃 20903")
    }
}
