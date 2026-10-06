import Foundation
import Generated

/// 未决键的对外入口（查询、确认、放弃；页面在 APP-09）。查询、确认、放弃都先核对记录账号与当前会话账号。
public extension ApiClient {
    /// 进程启动、登录成功、回前台：恢复当前会话账号的未决记录（只读，不发）。只把不属于本进程在途请求的 in_flight
    /// （上个进程遗留）改为 unknown；本进程仍在执行的请求不动。凭据不可读或没有会话时停止读取任何账号的记录。
    func restorePending() async {
        let state = await readContext()
        guard let account = sessionAccount(state) else {
            pendingKeys.signOut()
            return
        }
        pendingKeys.coldStart(account: account)
    }

    /// 当前会话账号某个 step-up 操作的未决记录（发起页据此进入待确认）。记录账号与当前会话账号不一致时不返回；
    /// 读不出来时也是 nil，要区分请用 `pendingStatus(operationId:)`。
    func pendingFor(operationId: String) async -> PendingKeyRecord? {
        if case let .record(record) = await pendingStatus(operationId: operationId) {
            return record
        }
        return nil
    }

    /// 当前会话账号某个 step-up 操作的未决状态（没有 / 有记录 / 读不出来）。读不出来时发起页不得放行新的提交
    /// （管线也会以 pending_store_failed 本地拒绝）。
    func pendingStatus(operationId: String) async -> PendingLookup {
        let state = await readContext()
        guard let account = sessionAccount(state) else {
            return .none
        }
        syncPendingAccount(account)
        switch pendingKeys.lookup(operationId: operationId) {
        case let .record(record):
            return record.account == account ? .record(record) : .none
        case .none:
            return .none
        case .unreadable:
            return .unreadable
        }
    }

    /// 用户点【确认】：用原键、原请求体重发（只在结果未知时接受）。结果未知后收到 10003 的，二次验证完成后带上
    /// stepUpToken 再调本入口，仍沿用原键与原请求体。账号先核对一次，发送前（管线里）再核对一次。
    func confirmPending(operationId: String, stepUpToken: String? = nil) async -> ApiResult {
        guard let operation = ApiOperations.byId(operationId), operation.stepUp != nil else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        let state = await readContext()
        guard let account = sessionAccount(state) else {
            return .localReject(reason: LocalRejectReason.accountUnknown)
        }
        syncPendingAccount(account)
        let lookup = pendingKeys.lookup(operationId: operationId)
        if lookup == .unreadable {
            return .localReject(reason: LocalRejectReason.pendingStoreFailed)
        }
        guard case let .record(record) = lookup, record.account == account, record.stateRaw == PendingKeyStore.unknown
        else {
            return .localReject(reason: LocalRejectReason.pendingKeyUnresolved)
        }
        // 先把 in_flight 落盘再改内存；写不进去保持 unknown，明确返回存储失败（lessons 32）。
        guard let owner = pendingKeys.startUserAction(record.key) else {
            return .localReject(reason: LocalRejectReason.pendingStoreFailed)
        }
        let call = ApiCall(
            operationId: operationId, body: record.body, idempotencyKey: record.key,
            stepUpToken: stepUpToken, summary: record.summary
        )
        var options = RunOptions(epoch: currentEpoch)
        options.held = PendingHold(key: record.key, account: account, owner: owner)
        options.boundAccount = account
        return await run(call, operation, isReplay: false, options: options)
    }

    /// 用户点【放弃】（二次确认之后）：调 `POST /v1/idempotency-keys/abandon`。abandoned → 键结束，返回 `.abandoned`；
    /// completed → 解包 original，按原操作给出业务结果（成功或 3xxxx 的 failure 与 Effect），键结束；没有外壳或其他码
    /// （40901、10001/10004/10005 等）→ 保持待确认。
    /// 遇到 10001 / 10004 / 10005 只引导补办，不登记 pending_action、不自动重放（BR-ID-10）。
    func abandonPending(operationId: String) async -> ApiResult {
        let state = await readContext()
        guard let account = sessionAccount(state) else {
            return .localReject(reason: LocalRejectReason.accountUnknown)
        }
        syncPendingAccount(account)
        let lookup = pendingKeys.lookup(operationId: operationId)
        if lookup == .unreadable {
            return .localReject(reason: LocalRejectReason.pendingStoreFailed)
        }
        guard case let .record(record) = lookup, record.account == account,
              record.stateRaw == PendingKeyStore.unknown,
              let original = ApiOperations.byId(operationId), let action = original.stepUp,
              let abandon = ApiOperations.byId(Self.abandonOperation)
        else {
            return .localReject(reason: LocalRejectReason.pendingKeyUnresolved)
        }
        guard let owner = pendingKeys.startUserAction(record.key) else {
            return .localReject(reason: LocalRejectReason.pendingStoreFailed)
        }
        let payload = ["action": action, "idempotency_key": record.key]
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var options = RunOptions(epoch: currentEpoch)
        options.guideOnlyPrerequisites = true
        options.boundAccount = account
        let result = await run(
            ApiCall(operationId: Self.abandonOperation, body: body),
            abandon,
            isReplay: false,
            options: options
        )
        if result.notSentReason != nil {
            pendingKeys.release(key: record.key, account: account, callOwner: owner)
            return result
        }
        pendingKeys.onResponse(key: record.key, kind: Self.abandonOutcome(result), account: account, callOwner: owner)
        return await unpackAbandon(result, original: original, key: record.key)
    }
}
