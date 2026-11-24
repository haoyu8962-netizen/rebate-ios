import Foundation
import Generated
@testable import Network
import Session
import XCTest

/// FU-IOS-CONTRACT-LOCK-6c97062（B1-02zzzc #385，D10-2892 / D10-2903 ① 甲）：网络层「敏感操作」保护从 `stepUp != nil` 改挂生成的
/// `sensitiveOperation`，放弃 action 改取生成的 `abandonAction`（任务书第 3 条的 6 处：PendingKeyStore.isSensitive、管线 registerPending、
/// ErrorActionMapper.stepUpOperation、confirmPending 两个入口、abandonPending 两个入口）。带 X-Step-Up-Token 仍按 stepUp：提现不带。
///
/// 升锁后 createWithdrawal 的 stepUp = nil、sensitiveOperation = true，正好把两种判据分开：任何一处还按 stepUp 判断，提现这一行就红
/// （不登记未决 → 结果未知后换键；10001 / 10004 / 10005 / 30101 变成同键重放并登记；确认本地 invalid_call；放弃本地 pending_key_unresolved）。
/// 改收款、换手机号、注销三项 stepUp 与 sensitiveOperation 都在，按原行为钉回归（含照常带 X-Step-Up-Token）。
/// 现状（锁 d47f660、未实现）：`sensitiveOperation` / `abandonAction` 是新生成符号，本文件编译红；契约前提（提现 stepUp == nil）与提现不带头
/// 两类断言在旧锁上也是红的。全部对 URLProtocol 本地假服务，照同目录 ApiClientLessonsTests / App13a1PendingReplayBodyTests 的写法。
final class LockIos6c97062SensitiveOperationTests: XCTestCase {
    private struct Case {
        let operationId: String
        let method: String
        let path: String
        let body: String?
        let otherBody: String?
        let stepUp: String?
        let abandonAction: String
    }

    private static let withdrawal = Case(
        operationId: "createWithdrawal", method: "POST", path: "/v1/withdrawals",
        body: "{\"amount_fen\":1000,\"payout_account_id\":\"pa-1\"}", otherBody: "{\"amount_fen\":1}",
        stepUp: nil, abandonAction: "withdraw"
    )
    private static let payout = Case(
        operationId: "savePayoutAccount", method: "PUT", path: "/v1/me/payout-account",
        body: "{\"payout_method\":\"alipay\", \"logon_id\":\"13800005678\",\"payee_name\":\"测试三\"}",
        otherBody: "{\"payout_method\":\"alipay\",\"logon_id\":\"13900001234\",\"payee_name\":\"测试四\"}",
        stepUp: "payout_account_change", abandonAction: "payout_account_change"
    )
    private static let phone = Case(
        operationId: "bindPhone", method: "POST", path: "/v1/me/phone",
        body: "{\"code\":\"654321\",\"phone\":\"13900001234\"}",
        otherBody: "{\"code\":\"111111\",\"phone\":\"13900005678\"}",
        stepUp: "phone_change", abandonAction: "phone_change"
    )
    private static let deletion = Case(
        operationId: "requestDeletion", method: "POST", path: "/v1/me/deletion", body: nil, otherBody: nil,
        stepUp: "account_deletion", abandonAction: "account_deletion"
    )
    private static let sensitive = [withdrawal, payout, phone, deletion]
    /// 改收款、换手机号、注销：仍按原 stepUp 行为（回归钉）。
    private static let stepUpOnly = [payout, phone, deletion]

    private static let state = ErrorActionState(update: "supported", sessionScope: "full", appVersion: "1.2.0")

    private enum Entry: CaseIterable {
        case plain
        case target
    }

    // MARK: - 辅助

    /// 首次发送没有统一外壳（超时）→ 键进入结果未知；返回键。调用方故意给令牌（提现不得带）。
    private func makeUnknown(_ harness: Harness, _ item: Case) async throws -> String {
        StubURLProtocol.install { _ in .error(.timedOut) }
        let first = await harness.client.send(
            ApiCall(operationId: item.operationId, body: item.body, stepUpToken: "step-up-1")
        )
        guard case let .transportFailure(_, _, key, unknown) = first else {
            XCTFail("\(item.operationId)：首次发送应结果未知，实际 \(first)")
            throw NSError(domain: "lock-6c97062", code: 1)
        }
        XCTAssertTrue(unknown, item.operationId)
        return try XCTUnwrap(key, item.operationId)
    }

    private func target(_ harness: Harness, key: String) -> PendingTarget {
        PendingTarget(
            account: "account-A",
            key: key,
            expected: harness.client.currentOwnership(credentialsReadable: true)
        )
    }

    private func confirm(_ harness: Harness, _ item: Case, key: String, via entry: Entry,
                         stepUpToken: String? = "step-up-2") async -> ApiResult {
        switch entry {
        case .plain:
            await harness.client.confirmPending(operationId: item.operationId, stepUpToken: stepUpToken)
        case .target:
            await harness.client.confirmPending(
                operationId: item.operationId, stepUpToken: stepUpToken, target: target(harness, key: key)
            )
        }
    }

    private func abandon(_ harness: Harness, _ item: Case, key: String, via entry: Entry) async -> ApiResult {
        switch entry {
        case .plain:
            await harness.client.abandonPending(operationId: item.operationId)
        case .target:
            await harness.client.abandonPending(operationId: item.operationId, target: target(harness, key: key))
        }
    }

    private func map(_ code: Int, _ operationId: String, data: [String: Any] = [:]) throws -> ErrorEffect {
        ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: try XCTUnwrap(ApiOperations.byId(operationId), operationId),
            headers: [:],
            isReplay: false, state: Self.state
        ))
    }

    // MARK: - 契约前提（生成物）

    /// 4 个敏感操作 = sensitiveOperation 集合；stepUp 只剩 3 个（提现 nil，是 4 个的子集）；abandonAction 只在这 4 个上有值且逐个对上
    /// IdempotencyAbandonAction；提现错误码没有 10003、仍有 20903。
    func testGeneratedSensitiveOperationsAndAbandonActions() throws {
        let sensitiveIds = Set(ApiOperations.all.values.filter(\.sensitiveOperation).map(\.operationId))
        XCTAssertEqual(sensitiveIds, Set(Self.sensitive.map(\.operationId)), "sensitiveOperation 恰为 4 个敏感操作")
        let stepUpIds = Set(ApiOperations.all.values.filter { $0.stepUp != nil }.map(\.operationId))
        XCTAssertEqual(stepUpIds, Set(Self.stepUpOnly.map(\.operationId)), "stepUp 只剩 3 个，提现不在其中")
        XCTAssertTrue(stepUpIds.isSubset(of: sensitiveIds))
        let abandonIds = Set(ApiOperations.all.values.filter { $0.abandonAction != nil }.map(\.operationId))
        XCTAssertEqual(abandonIds, sensitiveIds, "abandonAction 只在敏感操作上有值")
        for item in Self.sensitive {
            let operation = try XCTUnwrap(ApiOperations.byId(item.operationId))
            XCTAssertEqual(operation.method, item.method, item.operationId)
            XCTAssertEqual(operation.pathTemplate, item.path, item.operationId)
            XCTAssertEqual(operation.stepUp, item.stepUp, item.operationId)
            XCTAssertEqual(operation.abandonAction, item.abandonAction, item.operationId)
            XCTAssertTrue(operation.idempotent, item.operationId)
            XCTAssertTrue(operation.errorCodes.contains(20903), "\(item.operationId)：20903")
            XCTAssertTrue(PendingKeyStore.isSensitive(item.operationId), "\(item.operationId)：网络层按敏感操作处理")
        }
        let withdraw = try XCTUnwrap(ApiOperations.byId("createWithdrawal"))
        XCTAssertFalse(withdraw.errorCodes.contains(10003), "提现不再有 10003")
        XCTAssertFalse(PendingKeyStore.isSensitive("getMe"), "对照：非敏感操作")
    }

    // MARK: - ① ② 结果未知时幂等键不换（PendingKeyStore.isSensitive / admit、管线 registerPending）

    /// 首次发送前落 in_flight 记录，没有外壳 → unknown；结果未知期间换体新提交本地拒绝（pending_key_unresolved），零发送。
    func testUnknownKeepsKeyForEverySensitiveOperation() async throws {
        for item in Self.sensitive where item.otherBody != nil {
            let harness = makeHarness()
            let key = try await makeUnknown(harness, item)
            let record = try XCTUnwrap(
                harness.backend.read(account: "account-A", key: key),
                "\(item.operationId)：落了未决记录"
            )
            XCTAssertEqual(record.operationId, item.operationId)
            XCTAssertEqual(record.stateRaw, PendingKeyStore.unknown, item.operationId)
            XCTAssertEqual(record.body, item.body ?? "", "\(item.operationId)：记录原体")

            StubURLProtocol.install { _ in ok() }
            let blocked = await harness.client.send(ApiCall(operationId: item.operationId, body: item.otherBody))
            XCTAssertEqual(
                blocked.rejectReason,
                LocalRejectReason.pendingKeyUnresolved,
                "\(item.operationId)：结果未知期间不得换键"
            )
            XCTAssertTrue(StubURLProtocol.requests.isEmpty, "\(item.operationId)：零发送")
            let found = await harness.client.pendingFor(operationId: item.operationId)
            XCTAssertEqual(found?.key, key, "\(item.operationId)：待确认用原键")
        }
    }

    /// 没有请求体的申请注销：结果未知后再次申请（同样无体）也被挡。
    func testUnknownDeletionBlocksSecondRequest() async throws {
        let harness = makeHarness()
        _ = try await makeUnknown(harness, Self.deletion)
        StubURLProtocol.install { _ in ok() }
        let blocked = await harness.client.send(ApiCall(operationId: "requestDeletion"))
        XCTAssertEqual(blocked.rejectReason, LocalRejectReason.pendingKeyUnresolved)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - ③ 补完前置后只引导、不自动重放（ErrorActionMapper.stepUpOperation）

    /// 10001 / 10004 / 10005、30101 / 30102 / 30111：4 个敏感操作只引导（guide_only），不重放、不登记 pending_action。
    func testPrerequisitesOnlyGuideOnSensitiveOperations() throws {
        for item in Self.sensitive {
            for code in [10001, 10004, 10005, 30101, 30102, 30111] {
                let effect = try map(code, item.operationId)
                let label = "\(item.operationId) \(code)"
                XCTAssertEqual(effect.kind, .guideOnly, label)
                XCTAssertEqual(effect.replay, ReplayMode.none, label)
                XCTAssertFalse(effect.registerPending, label)
            }
        }
    }

    /// 对照：非敏感操作照旧——前置补完后同键重放并登记，授权码新键重放并登记（防止判据放宽成「全都只引导」）。
    func testPrerequisitesOnNonSensitiveOperationStillReplay() throws {
        let consent = try map(10004, "getMe")
        XCTAssertEqual(consent.kind, .consent)
        XCTAssertEqual(consent.replay, .sameKey)
        XCTAssertTrue(consent.registerPending)
        let authorize = try map(30101, "getMe")
        XCTAssertEqual(authorize.kind, .authorize)
        XCTAssertEqual(authorize.replay, .newKey)
        XCTAssertTrue(authorize.registerPending)
    }

    /// 管线：提现首次提交得到 10004 / 10005 → 只引导，只发一次，不登记 pending_action（不会在补完后自动重放提现）。
    func testWithdrawalPrerequisiteThroughPipelineDoesNotReplay() async throws {
        for code in [10004, 10005] {
            let harness = makeHarness()
            StubURLProtocol.install { _ in fail(code, status: 403, data: "{\"consent_type\":\"privacy\"}") }
            let result = await harness.client.send(ApiCall(operationId: "createWithdrawal", body: Self.withdrawal.body))
            let effect = try XCTUnwrap(result.effect, "\(code)：\(result)")
            XCTAssertEqual(effect.kind, .guideOnly, "\(code)")
            XCTAssertEqual(effect.replay, ReplayMode.none, "\(code)")
            XCTAssertFalse(effect.registerPending, "\(code)")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "\(code) 不自动重放")
        }
    }

    /// 结果未知后确认得到 10001 / 10004 / 10005：只引导、不重放，键仍是待确认（不登记、不换键）。
    func testPrerequisiteAfterUnknownKeepsPendingWithoutReplay() async throws {
        for code in [10004, 10005] {
            let harness = makeHarness()
            let key = try await makeUnknown(harness, Self.withdrawal)
            StubURLProtocol.install { _ in fail(code, status: 403, data: "{\"consent_type\":\"privacy\"}") }
            let result = await harness.client.confirmPending(operationId: "createWithdrawal")
            let effect = try XCTUnwrap(result.effect, "\(code)：\(result)")
            XCTAssertNotEqual(effect.replay, .sameKey, "\(code)：不自动同键重放")
            XCTAssertNotEqual(effect.replay, .newKey, "\(code)：不换键")
            XCTAssertFalse(effect.registerPending, "\(code)")
            XCTAssertEqual(effect.pendingKeyUnknown, true, "\(code)")
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "\(code) 只有那次确认")
            XCTAssertEqual(harness.pending.state(key: key).stateRaw, PendingKeyStore.unknown, "\(code) 保持待确认")
        }
    }

    // MARK: - ④ ⑤ 【确认上一笔】两个入口；带头仍按 stepUp

    /// 结果未知 → 两个确认入口都接受（不是本地 invalid_call），原键原体只发一次；提现不带令牌，另外 3 项带确认时给的令牌；成功后记录清除。
    func testConfirmPendingWorksOnBothEntries() async throws {
        for item in Self.sensitive {
            for entry in Entry.allCases {
                let harness = makeHarness()
                let key = try await makeUnknown(harness, item)
                let label = "\(item.operationId) / \(entry)"
                StubURLProtocol.install { _ in ok() }
                let result = await confirm(harness, item, key: key, via: entry)
                XCTAssertNotEqual(result.rejectReason, LocalRejectReason.invalidCall, "\(label)：确认入口不得本地拒绝")
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                XCTAssertEqual(StubURLProtocol.requests.count, 1, "\(label)：只发一次")
                let sent = try XCTUnwrap(StubURLProtocol.requests(path: item.path).first, label)
                XCTAssertEqual(sent.method, item.method, label)
                XCTAssertEqual(sent.header("Idempotency-Key"), key, "\(label)：原键")
                XCTAssertEqual(sent.body, item.body ?? "", "\(label)：原体")
                if item.stepUp == nil {
                    XCTAssertNil(sent.header("X-Step-Up-Token"), "\(label)：提现确认不带令牌")
                } else {
                    XCTAssertEqual(sent.header("X-Step-Up-Token"), "step-up-2", "\(label)：回归，照常带")
                }
                XCTAssertNil(harness.backend.read(account: "account-A", key: key), "\(label)：成功后记录清除")
            }
        }
    }

    /// 改收款、换手机号、注销：确认得到 10003 → 二次验证、同键、不登记、键仍未知（回归钉）。提现不会再收到 10003，不在此列。
    func testConfirm10003StillStepsUpForStepUpOperations() async throws {
        for item in Self.stepUpOnly {
            let harness = makeHarness()
            let key = try await makeUnknown(harness, item)
            StubURLProtocol.install { _ in fail(10003, status: 403) }
            let result = await harness.client.confirmPending(operationId: item.operationId)
            let effect = try XCTUnwrap(result.effect, "\(item.operationId)：\(result)")
            XCTAssertEqual(effect.kind, .stepUp, item.operationId)
            XCTAssertEqual(effect.replay, .sameKey, item.operationId)
            XCTAssertFalse(effect.registerPending, item.operationId)
            XCTAssertEqual(effect.pendingKeyUnknown, true, item.operationId)
            XCTAssertEqual(harness.pending.state(key: key).stateRaw, PendingKeyStore.unknown, item.operationId)
        }
    }

    /// 安卓 review-r1 S3-1 对照：带头这道门（ApiClient+Prepare callHeaders）必须仍按 stepUp，不得改成 sensitiveOperation 或去掉条件。
    /// 调用方**显式**传了 stepUpToken（非空）：提现的首发、【确认上一笔】两个入口都不带 X-Step-Up-Token，任何请求头里都没有这个值；
    /// 改收款、换手机号、注销三项传了照常带（回归钉）。令牌缓存不参与（网络层直接收参数），头为空只能是这道门挡下的。
    func testExplicitStepUpTokenIsSentOnlyForStepUpOperations() async throws {
        let token = "explicit-step-up-token"
        for item in Self.sensitive {
            // 首发
            let harness = makeHarness()
            StubURLProtocol.install { _ in ok() }
            let first = await harness.client.send(
                ApiCall(operationId: item.operationId, body: item.body, stepUpToken: token)
            )
            XCTAssertTrue(first.isSuccess, "\(item.operationId) 首发：\(first)")
            let sent = try XCTUnwrap(StubURLProtocol.requests(path: item.path).first, item.operationId)
            XCTAssertNotNil(sent.header("Idempotency-Key"), item.operationId)
            assertStepUpHeader(sent, item, token, "\(item.operationId) 首发")

            // 【确认上一笔】两个入口
            for entry in Entry.allCases {
                let pending = makeHarness()
                let key = try await makeUnknown(pending, item)
                StubURLProtocol.install { _ in ok() }
                let label = "\(item.operationId) 确认 / \(entry)"
                let result = await confirm(pending, item, key: key, via: entry, stepUpToken: token)
                XCTAssertTrue(result.isSuccess, "\(label)：\(result)")
                let resent = try XCTUnwrap(StubURLProtocol.requests(path: item.path).first, label)
                XCTAssertEqual(resent.header("Idempotency-Key"), key, "\(label)：原键")
                assertStepUpHeader(resent, item, token, label)
            }
        }
    }

    private func assertStepUpHeader(
        _ sent: StubURLProtocol.Recorded, _ item: Case, _ token: String, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if item.stepUp == nil {
            XCTAssertNil(sent.header("X-Step-Up-Token"), "\(label)：提现不带二次验证令牌", file: file, line: line)
            XCTAssertFalse(sent.headers.values.contains(token), "\(label)：任何请求头里都没有这个令牌", file: file, line: line)
        } else {
            XCTAssertEqual(sent.header("X-Step-Up-Token"), token, "\(label)：回归，照常带", file: file, line: line)
        }
        XCTAssertFalse(sent.body.contains(token), "\(label)：令牌不进请求体", file: file, line: line)
    }

    // MARK: - 20903

    /// 结果未知后确认得到 20903（已作废）：键结束、记录删除，不改写成「暂时确认不了」；之后的新提交放行（新键）。
    func testConfirm20903EndsKeyForEverySensitiveOperation() async throws {
        for item in Self.sensitive {
            let harness = makeHarness()
            let key = try await makeUnknown(harness, item)
            StubURLProtocol.install { _ in fail(20903) }
            let result = await harness.client.confirmPending(operationId: item.operationId)
            let effect = try XCTUnwrap(result.effect, "\(item.operationId)：\(result)")
            XCTAssertNotEqual(effect.action, ErrorPageAction.pendingConfirm, "\(item.operationId)：20903 不是暂时确认不了")
            XCTAssertNotEqual(effect.pendingKeyUnknown, true, "\(item.operationId)：键已结束")
            XCTAssertNil(harness.backend.read(account: "account-A", key: key), "\(item.operationId)：记录删除")

            StubURLProtocol.install { _ in ok() }
            let next = await harness.client.send(ApiCall(operationId: item.operationId, body: item.otherBody))
            XCTAssertTrue(next.isSuccess, "\(item.operationId)：作废后可新提交：\(next)")
            let sent = try XCTUnwrap(StubURLProtocol.requests(path: item.path).first, item.operationId)
            XCTAssertNotEqual(sent.header("Idempotency-Key"), key, "\(item.operationId)：新提交用新键")
        }
    }

    /// 对照：确认得到 20903 以外的 2xxxx（20002）→ 暂时确认不了，保持待确认（提现在新判据下照样走这条）。
    func testConfirmOther2xxxxKeepsPendingOnWithdrawal() async throws {
        let harness = makeHarness()
        let key = try await makeUnknown(harness, Self.withdrawal)
        StubURLProtocol.install { _ in fail(20002) }
        let result = await harness.client.confirmPending(operationId: "createWithdrawal")
        let effect = try XCTUnwrap(result.effect, "\(result)")
        XCTAssertEqual(effect.kind, .pageAction)
        XCTAssertEqual(effect.action, ErrorPageAction.pendingConfirm)
        XCTAssertEqual(effect.pendingKeyUnknown, true)
        XCTAssertEqual(harness.pending.state(key: key).stateRaw, PendingKeyStore.unknown)
    }

    /// 契约依据：abandonIdempotencyKey 的 x-error-codes 只有 [20001, 40901, 10405]，作废接口不返回 20903（「已作废」是成功返回
    /// outcome=abandoned，见 testAbandonPendingUsesAbandonActionOnBothEntries；20903 只在之后带原键重新提交时出现，见
    /// testConfirm20903EndsKeyForEverySensitiveOperation）。提现结果未知后，两个放弃入口调作废接口得到 40901（原请求仍在处理）
    /// 或 20001：作废请求发出 1 次，键保持待确认（记录还在、state 仍是 unknown），结果不是 .abandoned。
    func testAbandon40901KeepsPendingOnWithdrawal() async throws {
        for (code, status) in [(40901, 409), (20001, 400)] {
            for entry in Entry.allCases {
                let harness = makeHarness()
                let key = try await makeUnknown(harness, Self.withdrawal)
                let label = "\(code) / \(entry)"
                StubURLProtocol.install { _ in fail(code, status: status) }
                let result = await abandon(harness, Self.withdrawal, key: key, via: entry)
                XCTAssertEqual(
                    StubURLProtocol.requests(path: "/v1/idempotency-keys/abandon").count, 1, "\(label)：作废请求发出 1 次"
                )
                XCTAssertNotEqual(result, .abandoned(idempotencyKey: key), "\(label)：不是已作废：\(result)")
                XCTAssertNotNil(harness.backend.read(account: "account-A", key: key), "\(label)：记录还在")
                XCTAssertEqual(
                    harness.pending.state(key: key).stateRaw, PendingKeyStore.unknown, "\(label)：保持待确认"
                )
            }
        }
    }

    // MARK: - ⑥ 【放弃上一笔】两个入口：action 取 abandonAction

    /// 结果未知 → 两个放弃入口都发作废请求，体为 {action: abandonAction, idempotency_key: 原键}（提现 action = withdraw）；abandoned → 键结束。
    func testAbandonPendingUsesAbandonActionOnBothEntries() async throws {
        for item in Self.sensitive {
            for entry in Entry.allCases {
                let harness = makeHarness()
                let key = try await makeUnknown(harness, item)
                let label = "\(item.operationId) / \(entry)"
                StubURLProtocol.install { _ in ok("{\"outcome\":\"abandoned\",\"original\":null}") }
                let result = await abandon(harness, item, key: key, via: entry)
                XCTAssertNotEqual(result.rejectReason, LocalRejectReason.pendingKeyUnresolved, "\(label)：放弃入口不得本地拒绝")
                let sent = try XCTUnwrap(StubURLProtocol.requests(path: "/v1/idempotency-keys/abandon").first, label)
                XCTAssertEqual(
                    sent.body, "{\"action\":\"\(item.abandonAction)\",\"idempotency_key\":\"\(key)\"}", "\(label)：作废体"
                )
                XCTAssertEqual(result, .abandoned(idempotencyKey: key), "\(label)：\(result)")
                XCTAssertNil(harness.backend.read(account: "account-A", key: key), "\(label)：键结束")
            }
        }
    }
}
