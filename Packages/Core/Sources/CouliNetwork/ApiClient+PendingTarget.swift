import Foundation
import Generated

/// 点击【确认上一笔】/【确定放弃】时固定的那条未决记录（APP-09 共性第 14、15、39、65 条；Android `PendingTarget` 同口径）：账号与原键取自
/// 页面渲染的待确认卡，归属取自表单构造时一次读出的 `RequestOwnership`。读取记录、占用记录与每次实际发送前都只**比较**——不在执行时按
/// operationId 重新选当前会话的记录，不把点击重新绑定到执行时的会话。`isValid` 是调用归属（会话世代等，失效即作废、零发送），`sendAllowed`
/// 是独立的发送前闸门（共享 42901 禁用期，含二次验证后的续发与 10002 刷新后的重放；只在实际写出前核对，不进归属）。
public struct PendingTarget: Sendable {
    public let account: String
    public let key: String
    public let expected: RequestOwnership?
    public let isValid: @Sendable () -> Bool
    public let sendAllowed: @Sendable () -> Bool

    public init(
        account: String, key: String, expected: RequestOwnership?,
        isValid: @escaping @Sendable () -> Bool = { true }, sendAllowed: @escaping @Sendable () -> Bool = { true }
    ) {
        self.account = account
        self.key = key
        self.expected = expected
        self.isValid = isValid
        self.sendAllowed = sendAllowed
    }
}

public extension ApiClient {
    /// 【确认上一笔】（带点击时固定的目标）：记录账号、原键都与 `target` 一致且仍是 unknown 才占用；之后的发送带固定归属与发送前闸门。
    /// 已有的 `confirmPending(operationId:stepUpToken:)` 行为不变（其余调用方未改）。
    func confirmPending(operationId: String, stepUpToken: String?, target: PendingTarget) async -> ApiResult {
        guard let operation = ApiOperations.byId(operationId), operation.stepUp != nil else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        let record: PendingKeyRecord
        switch await lockTarget(operationId, target) {
        case let .failure(reject):
            return .localReject(reason: reject.reason)
        case let .success(found):
            record = found
        }
        guard let owner = pendingKeys.startUserAction(record.key) else {
            return .localReject(reason: LocalRejectReason.pendingStoreFailed)
        }
        let call = ApiCall(
            operationId: operationId, body: record.body, idempotencyKey: record.key, stepUpToken: stepUpToken,
            summary: record.summary
        )
        var options = targetOptions(target)
        options.held = PendingHold(key: record.key, account: target.account, owner: owner)
        options.boundAccount = target.account
        return await run(call, operation, isReplay: false, options: options)
    }

    /// 【放弃上一笔】（二次确认之后，带点击时固定的目标）：调 `POST /v1/idempotency-keys/abandon`；结局同 `abandonPending(operationId:)`。
    func abandonPending(operationId: String, target: PendingTarget) async -> ApiResult {
        let record: PendingKeyRecord
        switch await lockTarget(operationId, target) {
        case let .failure(reject):
            return .localReject(reason: reject.reason)
        case let .success(found):
            record = found
        }
        guard let original = ApiOperations.byId(operationId), let action = original.stepUp,
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
        var options = targetOptions(target)
        options.guideOnlyPrerequisites = true
        options.boundAccount = target.account
        let result = await run(ApiCall(operationId: Self.abandonOperation, body: body), abandon, isReplay: false,
                               options: options)
        if result.notSentReason != nil {
            pendingKeys.release(key: record.key, account: target.account, callOwner: owner)
            return result
        }
        pendingKeys.onResponse(
            key: record.key, kind: Self.abandonOutcome(result), account: target.account, callOwner: owner
        )
        return await unpackAbandon(result, original: original, key: record.key)
    }
}

extension ApiClient {
    /// 读取记录前先比较：调用仍有效、固定归属仍是当前（作废世代、会话世代、账号），再按固定账号读取并核对原键与状态。只比较，不赋值。
    func lockTarget(_ operationId: String, _ target: PendingTarget) async -> Result<PendingKeyRecord, TargetReject> {
        guard target.isValid() else { return .failure(TargetReject(LocalRejectReason.callCancelled)) }
        let state = await readContext()
        if let expected = target.expected {
            let mismatch: String? = lock.withLock {
                if epoch != expected.epoch {
                    return LocalRejectReason.callCancelled
                }
                if generation != expected.generation {
                    return LocalRejectReason.sessionChanged
                }
                return nil
            }
            if let mismatch {
                return .failure(TargetReject(mismatch))
            }
        }
        guard let account = sessionAccount(state) else {
            return .failure(TargetReject(LocalRejectReason.accountUnknown))
        }
        guard account == target.account else { return .failure(TargetReject(LocalRejectReason.accountMismatch)) }
        syncPendingAccount(account)
        switch pendingKeys.lookup(operationId: operationId) {
        case .unreadable:
            return .failure(TargetReject(LocalRejectReason.pendingStoreFailed))
        case let .record(record) where record.account == target.account && record.key == target.key
            && record.stateRaw == PendingKeyStore.unknown:
            return .success(record)
        default:
            return .failure(TargetReject(LocalRejectReason.pendingKeyUnresolved))
        }
    }

    func targetOptions(_ target: PendingTarget) -> RunOptions {
        var options = RunOptions(epoch: target.expected?.epoch ?? currentEpoch)
        options.callValid = target.isValid
        options.sendAllowed = target.sendAllowed
        options.expected = target.expected
        return options
    }
}

/// `lockTarget` 的本地结束原因。
struct TargetReject: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}
