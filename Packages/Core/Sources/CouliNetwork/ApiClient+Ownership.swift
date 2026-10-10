import Foundation
import Generated
import Session

/// 调用方固定的请求归属（APP-08 iOS RC-01；Android `ApiCall.expectedAccount` 同口径，APP-09 共性第 39、65 条）：账号、会话世代与
/// 作废世代（环境票据）在执行器构造时由 `ApiClient.currentOwnership(credentialsReadable:)` **一次**读出。
/// 带它发送的调用在首次归属绑定前、每次组请求后与传输层实际写出前只做**比较**，任何一项不一致就本地结束、零发送，不把请求重新绑定到当前会话。
public struct RequestOwnership: Equatable, Sendable {
    /// 账号（nil = 固定时没有可读会话；此时只要求世代不变，带凭据时账号必须一致）。
    public let account: String?
    /// 会话世代（登录、退出、清会话、作废时 +1；刷新不变）。
    public let generation: UInt64
    /// 作废世代（撤回同意、切换环境时 +1）。
    public let epoch: UInt64

    public init(account: String?, generation: UInt64, epoch: UInt64) {
        self.account = account
        self.generation = generation
        self.epoch = epoch
    }
}

public extension ApiClient {
    /// 此刻的请求归属：受凭据可读性约束的原子快照（APP-08 iOS NEW-01）。同一把锁里一次读出会话世代与作废世代；
    /// `credentialsReadable` 为 false（撤回同意的清理未完成）时**只读内存里的世代**，不调用令牌存储，账号为 nil；为 true 时才在同一把锁里
    /// 读会话账号。调用方传入此刻 `WithdrawalCleanupRunner.credentialsReadable`。只在固定身份时调用一次；之后只拿来比较。
    func currentOwnership(credentialsReadable: Bool) -> RequestOwnership {
        lock.withLock {
            RequestOwnership(
                account: credentialsReadable && !readBarrier
                    ? readSessionLocked().live?.account.flatMap { $0.isEmpty ? nil : $0 } : nil,
                generation: generation, epoch: epoch
            )
        }
    }

    /// 带调用有效性、发送前闸门与固定归属发送（订单请求，APP-08 iOS RC-01）。`expected` 为 nil 时与
    /// `send(_:isValid:sendAllowed:)` 完全相同；非 nil 时作废世代取它的票据（之后切过环境 / 撤回过同意即 call_cancelled），
    /// 首次归属绑定前、组请求后与实际写出前都与它比较：会话世代变了按 session_changed、带凭据的账号不同按 account_mismatch 本地结束。
    func send(
        _ call: ApiCall,
        isValid: @escaping @Sendable () -> Bool,
        sendAllowed: @escaping @Sendable () -> Bool,
        expected: RequestOwnership?
    ) async -> ApiResult {
        guard let operation = ApiOperations.byId(call.operationId) else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        var options = RunOptions(epoch: expected?.epoch ?? currentEpoch)
        options.callValid = isValid
        options.sendAllowed = sendAllowed
        options.expected = expected
        return await run(call, operation, isReplay: false, options: options)
    }
}

extension ApiClient {
    /// 首次归属绑定前（每次尝试读状态之后）与固定归属比较：作废世代、会话世代必须相同；凭据可读且有会话时账号也必须相同。
    /// 返回本地结束原因，nil = 一致（或没有固定归属）。只比较，不读当前会话来赋值。
    /// APP-08 iOS NEW-01：比较与读取在**同一把锁**里、按「先比较、再读取」——先核作废世代与会话世代，再核可读性（快照之后没有
    /// 撤回 / 切环境），全部通过才读令牌取账号；不信任异步等待之前取得的可读性快照。
    func expectedMismatch(_ state: NetworkContext, _ options: RunOptions) -> String? {
        guard let expected = options.expected else {
            return nil
        }
        return lock.withLock { () -> String? in
            guard epoch == expected.epoch, epoch == options.epoch else {
                return LocalRejectReason.callCancelled
            }
            guard generation == expected.generation else {
                return LocalRejectReason.sessionChanged
            }
            guard credentialsReadableLocked(state, runEpoch: options.epoch) else {
                return nil
            }
            let account = readSessionLocked().live?.account.flatMap { $0.isEmpty ? nil : $0 }
            if let account, account != expected.account {
                return LocalRejectReason.accountMismatch
            }
            return nil
        }
    }

    /// 组请求之后（凭据已读、头已签）再比较一次：本次要带出的会话世代与账号都必须是固定的那一份。
    func expectedMismatch(_ ready: Ready, _ options: RunOptions) -> String? {
        guard let expected = options.expected else {
            return nil
        }
        guard ready.generation == expected.generation else {
            return LocalRejectReason.sessionChanged
        }
        if let account = ready.account, account != expected.account {
            return LocalRejectReason.accountMismatch
        }
        return nil
    }

    /// 每次尝试读状态之后：先与固定归属比较（不一致按本地拒绝结束，零发送），再绑定归属、过受限会话屏障。
    func bindAndPassBarrier(
        _ state: NetworkContext, _ operation: ApiOperation, _ options: inout RunOptions
    ) async -> ApiResult? {
        if let reason = expectedMismatch(state, options) {
            return .localReject(reason: reason)
        }
        bindOwnership(state, &options)
        return await restrictedBarrierIfNeeded(state, operation, options)
    }

    /// 调用归属在任何屏障等待之前绑定（lessons 30）：有令牌时记下会话世代与账号；之后会话变了就结束旧调用。
    func bindOwnership(_ state: NetworkContext, _ options: inout RunOptions) {
        guard options.boundGeneration == nil else {
            return
        }
        // 先比较（快照仍可信、调用仍属当前作废世代、固定归属的会话世代未变）、再读取，同一把锁（APP-08 iOS NEW-01）
        let expectedGeneration = options.expected?.generation
        let (read, session) = lock.withLock { () -> (SessionRead, UInt64) in
            guard credentialsReadableLocked(state, runEpoch: options.epoch),
                  expectedGeneration == nil || expectedGeneration == generation
            else {
                return (SessionRead.none, generation)
            }
            return (readSessionLocked(), generation)
        }
        let live = read.live
        guard live?.access != nil else {
            return
        }
        // 带固定归属的调用：绑定的就是固定的那一份（调用方已在 attempt 里先比较过，这里不读当前会话来赋值，RC-01）
        if let expected = options.expected {
            options.boundGeneration = expected.generation
            options.boundAccount = options.boundAccount ?? expected.account
            return
        }
        options.boundGeneration = session
        if options.boundAccount == nil {
            options.boundAccount = live?.account.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
