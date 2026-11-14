import Foundation
import Generated
import Session

/// 调用方固定的请求归属（APP-08 iOS RC-01；Android `ApiCall.expectedAccount` 同口径，APP-09 共性第 39、65 条）：账号、会话世代与
/// 作废世代（环境票据）在执行器构造时由 `ApiClient.currentOwnership(credentialsReadable:)` **一次**读出。
/// 带它发送的调用在首次归属绑定前、每次组请求后与传输层实际写出前只做**比较**，任何一项不一致就本地结束、零发送，不把请求重新绑定到当前会话。
public struct RequestOwnership: Equatable, Sendable {
    /// 账号（nil = 固定时没有可读会话；此时只要求世代不变，带凭据时账号必须一致）。非 nil 时不论 x-auth，发出时读到的会话账号必须是它
    /// （读不出 / 没有会话 / 换了人都不行），x-auth=optional 还必须真的带上它的令牌，否则 account_mismatch（LOCK-ios S1、D10-1704）；
    /// 例外：会话读不出且调用没声明 `ApiCall.sendsWhenIdentityUnknown` 时先按 session_unreadable 拒（D10-1709）。
    public let account: String?
    /// 会话世代（登录、退出、清会话、作废时 +1；刷新不变）。
    public let generation: UInt64
    /// 作废世代（撤回同意、切换环境时 +1）。
    public let epoch: UInt64
    /// 发送前核对要不要看账号（缺省 true）。false = 只固定会话世代与作废世代，`account` 不参与任何核对、也不作绑定归属
    /// （`sessionOnly`，D10-1707：第三方登录不固定账号，会话读不出 / 存着过期或受限会话时照常发出）。
    public let pinsAccount: Bool

    public init(account: String?, generation: UInt64, epoch: UInt64, pinsAccount: Bool = true) {
        self.account = account
        self.generation = generation
        self.epoch = epoch
        self.pinsAccount = pinsAccount
    }

    /// 只固定会话世代与作废世代、不固定账号的归属（D10-1707 ①）：换人（另一账号登录、退出、清会话）一定换会话世代，照样
    /// session_changed 零发送、登录响应不落盘；会话读不出、本机会话的账号是谁都不再拦。
    public var sessionOnly: RequestOwnership {
        RequestOwnership(account: nil, generation: generation, epoch: epoch, pinsAccount: false)
    }
}

/// 一次读出的会话身份（`ApiClient.currentIdentity`）：请求归属、持久化登录世代、身份是否已确认、是否有可带的会话（member），
/// 都出自同一次会话读取。
public struct SessionIdentity: Equatable, Sendable {
    public let ownership: RequestOwnership
    public let loginEpoch: String?
    public let identityKnown: Bool
    /// 有可带的会话（有 access；与 `isolatedSessionScope != nil` 同口径，FU-IOS-0712 整体重理：订单「已登录」也取这一次读取）。
    public var member = false
}

public extension ApiClient {
    /// 此刻的请求归属：受凭据可读性约束的原子快照（APP-08 iOS NEW-01）。同一把锁里一次读出会话世代与作废世代；
    /// `credentialsReadable` 为 false（撤回同意的清理未完成）时**只读内存里的世代**，不调用令牌存储，账号为 nil；为 true 时才在同一把锁里
    /// 读会话账号。调用方传入此刻 `WithdrawalCleanupRunner.credentialsReadable`。只在固定身份时调用一次；之后只拿来比较。
    func currentOwnership(credentialsReadable: Bool) -> RequestOwnership {
        withSessionLock {
            RequestOwnership(
                account: credentialsReadable && !readBarrier
                    ? readSessionLocked().live?.account.flatMap { $0.isEmpty ? nil : $0 } : nil,
                generation: generation, epoch: epoch
            )
        }
    }

    /// 此刻的请求归属与持久化登录世代（FU-IOS-0712 R1-01）：与 `currentOwnership` 同一口径、**同一把锁、同一次会话读取**里一并取出世代
    /// （世代口径同 `sessionLoginEpoch`：屏障竖着、凭据不可读、隔离、读不出、损坏、被撤销、没有令牌、升级前没有世代 → nil）。
    /// 执行器构造时一次性取得，按「账号 + 登录世代」分区的本机数据的读写只用这一份；之后只拿来比较，写入时不再读当前世代补绑。
    /// `identityKnown`（第 2 轮修复 R2-01）：此刻身份是否**已确认**——凭据可读、禁读屏障没竖着、会话读取有结论（读到会话，或确认没有会话）
    /// 为 true；凭据暂不可读、屏障竖着、Keychain 暂时读失败为 false（身份暂时未知：调用方延后归属删除与恢复决策，不删不写）。
    func currentIdentity(credentialsReadable: Bool) -> SessionIdentity {
        withSessionLock {
            let read = credentialsReadable && !readBarrier ? readSessionLocked() : SessionRead.unreadable
            let live = read.live
            let account = live?.account.flatMap { $0.isEmpty ? nil : $0 }
            let loginEpoch = live.flatMap { $0.access != nil && $0.refresh != nil ? $0.loginEpoch : nil }
            return SessionIdentity(
                ownership: RequestOwnership(account: account, generation: generation, epoch: epoch),
                loginEpoch: loginEpoch, identityKnown: read != .unreadable, member: live?.access != nil
            )
        }
    }

    /// 订单、钱包与各资金页的**唯一**身份快照入口（FU-IOS-0712 整体重理）：凭据可读性与会话在同一时刻一次取得，判据、对账、页面固定身份
    /// 与页面核对都只用这一份。
    func identitySnapshot(credentialsReadable: Bool) -> IdentitySnapshot {
        let identity = currentIdentity(credentialsReadable: credentialsReadable)
        return IdentitySnapshot(identity: identity, readable: credentialsReadable)
    }

    /// 会话世代仍是 `generation` 时这一代会话的持久化登录世代（同一把锁里先比较世代、再取；不是这一代 → nil）。给只按会话世代固定身份的
    /// 内存状态（phone_bound）在**固定时**取一次用：取得的是固定那一代的世代，不会取到之后新登录的世代。
    func loginEpoch(ifGeneration value: UInt64, credentialsReadable: Bool) -> String? {
        withSessionLock {
            guard generation == value, credentialsReadable, !readBarrier, let live = readSessionLocked().live,
                  live.access != nil, live.refresh != nil
            else { return nil }
            return live.loginEpoch
        }
    }

    /// 带调用有效性、发送前闸门与固定归属发送（订单请求，APP-08 iOS RC-01）。`expected` 为 nil 时与
    /// `send(_:isValid:sendAllowed:)` 完全相同；非 nil 时作废世代取它的票据（之后切过环境 / 撤回过同意即 call_cancelled），
    /// 首次归属绑定前、组请求后与实际写出前都与它比较：会话世代变了按 session_changed、带凭据的账号不同按 account_mismatch 本地结束；
    /// 固定了账号时（不论 x-auth），组请求后读到的会话账号不是它（读不出、没有会话、换了人）也按 account_mismatch 结束，optional 还须带上
    /// 该账号令牌（D10-1704）。
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
    /// 这里读不出 / 没有会话不判冲突（交给后面：要会话的接口与未声明 `sendsWhenIdentityUnknown` 的 optional 在 prepare 按
    /// session_unreadable 拒，其余固定了账号的调用（不论 x-auth）在
    /// `expectedMismatch(_:_:_:)` 按 account_mismatch 拒）。返回本地结束原因，nil = 一致（或没有固定归属）。只比较，不读当前会话来赋值。
    /// APP-08 iOS NEW-01：比较与读取在**同一把锁**里、按「先比较、再读取」——先核作废世代与会话世代，再核可读性（快照之后没有
    /// 撤回 / 切环境），全部通过才读令牌取账号；不信任异步等待之前取得的可读性快照。
    func expectedMismatch(_ state: NetworkContext, _ options: RunOptions) -> String? {
        guard let expected = options.expected else {
            return nil
        }
        return withSessionLock { () -> String? in
            guard epoch == expected.epoch, epoch == options.epoch else {
                return LocalRejectReason.callCancelled
            }
            guard generation == expected.generation else {
                return LocalRejectReason.sessionChanged
            }
            guard expected.pinsAccount, credentialsReadableLocked(state, runEpoch: options.epoch) else {
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
    /// 调用方固定了账号（`expected.account != nil`）时，**与接口 x-auth 无关**（D10-1704 (b)，与 Android `attempts` 里
    /// `pendingAccount` 对 `session?.userId` 的核对同口径）：此刻读到的会话账号必须就是固定的账号——会话读不出、凭据不可读、
    /// 没有会话、账号不同都按 account_mismatch 本地结束、零发送；x-auth=optional 还必须**真的带着**这个账号的令牌（Authorization
    /// 已组上；声明了 `sendsWhenIdentityUnknown` 的 optional 的「身份未知照常匿名发出」只给没固定账号的调用，D10-1709 ⑤ / D10-1704）。
    /// x-auth=none 不带令牌，只核账号。会话读不出时，要会话的接口与未声明 `sendsWhenIdentityUnknown` 的 optional 在 prepare 已按
    /// session_unreadable 拒，走不到这里（不被改报 account_mismatch；D10-1709 身份未知判断先于固定账号核对）。
    /// 固定时没有可读会话（`account == nil`）的调用照旧：此刻读到有账号的会话即 account_mismatch。`pinsAccount == false`
    /// （`sessionOnly`，第三方登录）只核会话世代，不看账号。
    func expectedMismatch(_ ready: Ready, _ operation: ApiOperation, _ options: RunOptions) -> String? {
        guard let expected = options.expected else {
            return nil
        }
        guard ready.generation == expected.generation else {
            return LocalRejectReason.sessionChanged
        }
        guard expected.pinsAccount else {
            return nil
        }
        if let pinned = expected.account {
            guard ready.account == pinned else {
                return LocalRejectReason.accountMismatch
            }
            let carried = ready.request.headers[HeaderNames.authorization] != nil
            return operation.auth == Self.authOptional && !carried ? LocalRejectReason.accountMismatch : nil
        }
        if ready.account != nil {
            return LocalRejectReason.accountMismatch
        }
        return nil
    }

    /// 每次尝试读状态之后：先与固定归属比较（不一致按本地拒绝结束，零发送），再绑定归属、过受限会话屏障。
    func bindAndPassBarrier(
        _ state: NetworkContext, _ operation: ApiOperation, _ call: ApiCall, _ options: inout RunOptions
    ) async -> ApiResult? {
        if let reason = expectedMismatch(state, options) {
            return .localReject(reason: reason)
        }
        bindOwnership(state, &options)
        return await restrictedBarrierIfNeeded(state, operation, call, options)
    }

    /// 调用归属在任何屏障等待之前绑定（lessons 30）：有令牌时记下会话世代与账号；之后会话变了就结束旧调用。
    func bindOwnership(_ state: NetworkContext, _ options: inout RunOptions) {
        guard options.boundGeneration == nil else {
            return
        }
        // 先比较（快照仍可信、调用仍属当前作废世代、固定归属的会话世代未变）、再读取，同一把锁（APP-08 iOS NEW-01）
        let expectedGeneration = options.expected?.generation
        let (read, session) = withSessionLock { () -> (SessionRead, UInt64) in
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
            options.boundAccount = options.boundAccount
                ?? (expected.pinsAccount ? expected.account : live?.account.flatMap { $0.isEmpty ? nil : $0 })
            return
        }
        options.boundGeneration = session
        if options.boundAccount == nil {
            options.boundAccount = live?.account.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

extension ApiClient {
    /// 10006 的统一落点（APP-12 G09）：调用仍属当前作废世代且调用方仍有效时才交给 App（App 再核对导航票据）。
    /// 带上本次请求发起时绑定的归属（账号 + 登录世代 + 作废世代，APP-12 R2-01）：App 在主线程只与此刻比较，不用当前身份补作归属。
    func deliverRiskNotice(_ effect: ErrorEffect, _ options: RunOptions, _ ready: Ready) async {
        guard effect.kind == .navigate, effect.route == "RiskNotice" else { return }
        let epochAtStart = options.epoch
        let callValid = options.callValid
        let owner = RequestOwnership(
            account: options.boundAccount ?? ready.account,
            generation: options.boundGeneration ?? ready.generation, epoch: epochAtStart
        )
        await hooks.riskNotice(options.navTicket, owner) { [weak self] in
            guard let self, currentEpoch == epochAtStart else { return false }
            return callValid?() ?? true
        }
    }
}
