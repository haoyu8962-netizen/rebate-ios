import CouliNetwork
import Foundation
@testable import WalletCore
import XCTest

/// FU-IOS-PAYOUT-50301 写测（独立写测方，编排 D10-2774）：钱包敏感操作（提现提交、收款账号保存 / 换绑、注销流程）与钱包通用错误收到 50301
/// 时，文案键回落 error.50001（统一错误消息照旧附 trace6），不出现「维护中」——钱包没有平台语境（08 BR-TEXT-14 bank_vendor 行，契约
/// bank_vendor 键未合并前）。键结束 / 下次新键（keyEnds / nextSubmitNewKey）与改前一致；其他 5xxxx（50001、50302、50303、50401、未收录）
/// 不变；实名页 50301 本来就回落 error.50001（D10-887 ②，回归钉）。
/// 不按实现反推：其他码的回归钉并在会红的用例里，只钉文案键，不钉键规则以外的东西。
final class SensitiveOutcome50301Tests: XCTestCase {
    private let maintenance = "维护中"
    private let traceId = "trace-unit-abcdef123456"
    private let trace6 = "123456"
    private let texts = WalletDraftTexts()

    // MARK: - 构造

    private func outcomeOf(_ op: String, _ phase: String, _ code: Int, everUnknown: Bool = false) -> Outcome {
        SensitiveOutcome.of(
            op: op, phase: phase, keyEverUnknown: everUnknown,
            input: OutcomeInput(OutcomeInput.errorKind, code: code)
        )
    }

    private func failure(_ code: Int) -> ApiResult {
        .failure(
            code: code, msg: "", data: nil, traceId: traceId,
            effect: ErrorEffect(code: code, kind: .genericError, includeTrace6: true), idempotencyKey: nil
        )
    }

    /// 页面实际显示的那句：与 `SensitiveFlow.outcomeMessage` 同一构造（文案键 + 本次 trace + 结局的 showTrace6）。
    private func shownMessage(_ outcome: Outcome) -> String {
        Notice(outcome.textKey ?? "", id: 1, traceId: traceId, showTrace6: outcome.showTrace6).message(texts)
    }

    private func assertUnified(
        _ outcome: Outcome, action: String, ends: Bool, newKey: Bool, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(outcome.actionRaw, action, "\(label)：结局", file: file, line: line)
        XCTAssertEqual(outcome.keyEnds, ends, "\(label)：键是否结束（与改前一致）", file: file, line: line)
        XCTAssertEqual(outcome.nextSubmitNewKey, newKey, "\(label)：下次是否用新键（与改前一致）", file: file, line: line)
        XCTAssertEqual(outcome.textKey, "error.50001", "\(label)：50301 回落 error.50001", file: file, line: line)
        XCTAssertTrue(outcome.showTrace6, "\(label)：附 trace6", file: file, line: line)
        XCTAssertNil(outcome.route, "\(label)：不引导", file: file, line: line)
        XCTAssertNil(outcome.disableMillis, "\(label)：不禁用", file: file, line: line)
        let message = shownMessage(outcome)
        XCTAssertFalse(message.contains(maintenance), "\(label)：不出现「维护中」，实得「\(message)」", file: file, line: line)
        XCTAssertTrue(message.contains(trace6), "\(label)：统一错误附 trace6，实得「\(message)」", file: file, line: line)
    }

    // MARK: - 文案键函数

    /// serverKey：50301 → error.50001；其余 5xxxx 照旧（已收录用 error.<code>，未收录回落 error.50001）。
    func testServerKey50301FallsBackToUnified() {
        XCTAssertEqual(SensitiveOutcome.serverKey(50301), "error.50001", "50301 不取契约裸键 error.50301")
        // 回归钉：其他 5xxxx 不变
        XCTAssertEqual(SensitiveOutcome.serverKey(50001), "error.50001")
        XCTAssertEqual(SensitiveOutcome.serverKey(50302), "error.50302")
        XCTAssertEqual(SensitiveOutcome.serverKey(50303), "error.50303")
        XCTAssertEqual(SensitiveOutcome.serverKey(50401), "error.50401")
        XCTAssertEqual(SensitiveOutcome.serverKey(59999), "error.50001", "未收录照旧回落")
    }

    /// errorKey：50301 → error.50001（任务书「覆盖 serverKey、errorKey」）；其余照旧。
    func testErrorKey50301FallsBackToUnified() {
        XCTAssertEqual(SensitiveOutcome.errorKey(50301), "error.50001", "50301 不取契约裸键 error.50301")
        XCTAssertEqual(SensitiveOutcome.errorKey(50001), "error.50001")
        XCTAssertEqual(SensitiveOutcome.errorKey(50302), "error.50302")
        XCTAssertEqual(SensitiveOutcome.errorKey(50303), "error.50303")
        XCTAssertEqual(SensitiveOutcome.errorKey(59999), "error.50001")
    }

    // MARK: - 结局表：提现、收款账号

    /// 提现 / 收款账号首次提交得到 50301：error_trace6，键结束、下次新键（改前 5xxxx 同一条规则），文案 error.50001 + trace6；
    /// 从未结果未知与结果未知过的键都一样（submitEnded 不看 keyEverUnknown）。确认 / 放弃上一笔得到 50301：照旧稍后再试、保持待确认。
    func testWithdrawAndPayoutSubmit50301UsesUnifiedKey() {
        for op in [SensitiveOutcome.withdraw, SensitiveOutcome.payoutAccount] {
            for everUnknown in [false, true] {
                let label = "\(op) 提交 50301（曾结果未知 \(everUnknown)）"
                let outcome = outcomeOf(op, SensitiveOutcome.submit, 50301, everUnknown: everUnknown)
                assertUnified(outcome, action: SensitiveOutcome.errorTrace6, ends: true, newKey: true, label)
            }
            // 回归钉：其他 5xxxx 首次提交不变
            for (code, key) in [(50001, "error.50001"), (50302, "error.50302"), (50303, "error.50303"),
                                (50401, "error.50401"), (59999, "error.50001")] {
                let other = outcomeOf(op, SensitiveOutcome.submit, code)
                XCTAssertEqual(other.actionRaw, SensitiveOutcome.errorTrace6, "\(op) \(code)：结局不变")
                XCTAssertTrue(other.keyEnds && other.nextSubmitNewKey, "\(op) \(code)：键结束、新键不变")
                XCTAssertEqual(other.textKey, key, "\(op) \(code)：文案键不变")
                XCTAssertTrue(other.showTrace6, "\(op) \(code)：trace6 不变")
            }
            // 回归钉：确认 / 放弃上一笔得到 50301 照旧（稍后再试 + trace6，保持待确认）
            for phase in [SensitiveOutcome.confirm, SensitiveOutcome.abandon] {
                let kept = outcomeOf(op, phase, 50301, everUnknown: true)
                XCTAssertEqual(kept.actionRaw, SensitiveOutcome.pendingConfirm, "\(op) \(phase) 50301：保持待确认")
                XCTAssertFalse(kept.keyEnds || kept.nextSubmitNewKey, "\(op) \(phase) 50301：键不结束、不换键")
                XCTAssertEqual(kept.textKey, SensitiveOutcome.retryLaterKey, "\(op) \(phase) 50301：稍后再试")
                XCTAssertTrue(kept.showTrace6, "\(op) \(phase) 50301：附 trace6")
            }
        }
    }

    // MARK: - 结局表：申请注销

    /// 申请注销首次提交得到 50301：error_trace6，键不结束、下次沿用原键（改前 deletionSubmit 的 5xxxx 规则），文案 error.50001 + trace6。
    func testDeletionSubmit50301UsesUnifiedKey() {
        let op = SensitiveOutcome.accountDeletion
        for everUnknown in [false, true] {
            let outcome = outcomeOf(op, SensitiveOutcome.submit, 50301, everUnknown: everUnknown)
            assertUnified(outcome, action: SensitiveOutcome.errorTrace6, ends: false, newKey: false,
                          "申请注销 50301（曾结果未知 \(everUnknown)）")
        }
        for (code, key) in [(50001, "error.50001"), (50302, "error.50302"), (50303, "error.50303"),
                            (50401, "error.50401")] {
            let other = outcomeOf(op, SensitiveOutcome.submit, code)
            XCTAssertEqual(other.actionRaw, SensitiveOutcome.errorTrace6, "申请注销 \(code)：结局不变")
            XCTAssertFalse(other.keyEnds || other.nextSubmitNewKey, "申请注销 \(code)：键不结束、沿用原键不变")
            XCTAssertEqual(other.textKey, key, "申请注销 \(code)：文案键不变")
        }
        for phase in [SensitiveOutcome.confirm, SensitiveOutcome.abandon] {
            let kept = outcomeOf(op, phase, 50301, everUnknown: true)
            XCTAssertEqual(kept.textKey, SensitiveOutcome.retryLaterKey, "注销 \(phase) 50301：稍后再试不变")
            XCTAssertFalse(kept.keyEnds || kept.nextSubmitNewKey, "注销 \(phase) 50301：保持待确认不变")
        }
    }

    // MARK: - 网络结果 → 结局表 / 钱包通用错误

    /// 真实解包：ApiResult.failure(50301) 经 `WalletErrors.outcomeInput` 进结局表，三个操作的提示都是 error.50001 + trace6。
    func testOutcomeInputFrom50301ResultUsesUnifiedKey() {
        let input = WalletErrors.outcomeInput(failure(50301))
        XCTAssertEqual(input.code, 50301, "前提：码原样交结局表")
        let expected: [(String, Bool)] = [
            (SensitiveOutcome.withdraw, true), (SensitiveOutcome.payoutAccount, true),
            (SensitiveOutcome.accountDeletion, false),
        ]
        for (op, ends) in expected {
            let outcome = SensitiveOutcome.of(
                op: op, phase: SensitiveOutcome.submit, keyEverUnknown: false, input: input
            )
            let label = "\(op) 解包 50301"
            assertUnified(outcome, action: SensitiveOutcome.errorTrace6, ends: ends, newKey: ends, label)
        }
    }

    /// 钱包通用错误（读请求：摘要、rules、记录、收款账号、详情；WalletErrors.swift 5xxxx 一路）：50301 → server、error.50001、trace6；
    /// 其他 5xxxx 不变。
    func testWalletErrors50301UsesUnifiedKey() {
        let error = WalletErrors.of(failure(50301))
        XCTAssertEqual(error.kind, .server, "仍是服务端错误")
        XCTAssertEqual(error.textKey, "error.50001", "50301 回落 error.50001")
        XCTAssertTrue(error.showTrace6, "附 trace6")
        XCTAssertEqual(error.traceId, traceId, "trace 原样带上")
        let message = error.notice(id: 1).message(texts)
        XCTAssertFalse(message.contains(maintenance), "钱包通用错误不出现「维护中」，实得「\(message)」")
        XCTAssertTrue(message.contains(trace6), "附 trace6，实得「\(message)」")
        for (code, key) in [(50001, "error.50001"), (50302, "error.50302"), (50303, "error.50303"),
                            (50401, "error.50401"), (59999, "error.50001")] {
            let other = WalletErrors.of(failure(code))
            XCTAssertEqual(other.kind, .server, "\(code)：分类不变")
            XCTAssertEqual(other.textKey, key, "\(code)：文案键不变")
            XCTAssertTrue(other.showTrace6, "\(code)：trace6 不变")
        }
    }

    // MARK: - 实名页（回归钉）

    /// 实名页 50301 本来就回落 error.50001 + trace6（D10-887 ②）；其他 5xxxx 照统一分类。本单不动实名页，现状即绿。
    @MainActor
    func testRealNameNotice50301StillUnified() {
        let notice = RealNameController.notice(WalletErrors.of(failure(50301)), code: 50301, id: 7)
        XCTAssertEqual(notice.key, "error.50001", "实名页 50301 回落 error.50001")
        XCTAssertTrue(notice.showTrace6, "附 trace6")
        XCTAssertEqual(notice.traceId, traceId)
        XCTAssertFalse(notice.message(texts).contains(maintenance), "实名页不出现「维护中」")
        for (code, key) in [(50001, "error.50001"), (50302, "error.50302"), (50401, "error.50401")] {
            let other = RealNameController.notice(WalletErrors.of(failure(code)), code: code, id: 8)
            XCTAssertEqual(other.key, key, "实名页 \(code)：文案键不变")
            XCTAssertTrue(other.showTrace6, "实名页 \(code)：trace6 不变")
        }
    }
}

/// 申请注销的执行层（真实 SensitiveFlow.accountDeletion + ApiClient + 本地假服务，夹具同 App13a1DeletionPipelineTests）：50301 后页面错误
/// 是 error.50001 + trace6、不出现「维护中」；再点沿用原键（改前 5xxxx 规则）。
@MainActor
final class Deletion50301PipelineTests: XCTestCase {
    private var fixture: App13a1PipelineFixture!

    override func setUp() async throws {
        try await super.setUp()
        App13a1Stub.reset()
        fixture = App13a1PipelineFixture()
    }

    override func tearDown() async throws {
        fixture?.closePanel()
        fixture = nil
        App13a1Stub.reset()
        try await super.tearDown()
    }

    private var posts: [App13a1Stub.Recorded] {
        App13a1Stub.requests("POST", App13a1PipelineFixture.deletionPath)
    }

    func testDeletion50301ShowsUnifiedErrorAndKeepsKey() async throws {
        fixture.script.on(
            "POST \(App13a1PipelineFixture.deletionPath)", .envelope(50301, "null"),
            .envelope(0, App13a1PipelineFixture.cooling)
        )

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()

        let error = try XCTUnwrap(fixture.flow.state.error, "50301 要有页面错误")
        XCTAssertNil(fixture.flow.state.pending, "50301 有统一外壳，不进待确认")
        XCTAssertEqual(error.key, "error.50001", "50301 回落 error.50001")
        XCTAssertTrue(error.showTrace6, "附 trace6")
        let message = error.message(WalletDraftTexts())
        XCTAssertFalse(message.contains("维护中"), "不出现「维护中」，实得「\(message)」")
        XCTAssertTrue(message.contains("6789ab"), "附假服务 trace 的末 6 位，实得「\(message)」")

        fixture.flow.submitDeletion(owner: fixture.owner)
        await fixture.idle()
        XCTAssertEqual(posts.count, 2, "再点照常发出")
        let first = try XCTUnwrap(posts.first)
        let second = try XCTUnwrap(posts.last)
        XCTAssertEqual(second.header(HeaderNames.idempotencyKey), first.header(HeaderNames.idempotencyKey),
                       "5xxxx 后再点沿用原键（改前规则不变）")
        XCTAssertEqual(fixture.keys.issued, 1, "不生成新键")
    }
}
