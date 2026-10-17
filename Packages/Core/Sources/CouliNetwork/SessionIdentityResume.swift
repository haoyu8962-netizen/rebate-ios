import Foundation

// FU-IOS-0712 整体重理：订单、钱包与各资金页共用的一处身份快照、一套换代判据与一套页面恢复机制。
// - 身份只经 `ApiClient.identitySnapshot` 一次取得（`IdentitySnapshot`）：判据、对账、页面固定身份与页面核对都只用这一份；
// - 换代判据统一由 `SessionReconciler` 给出（未知只延后；首次确认无会话照删并重置；已知换代清旧分区并重建）；
// - 页面读取 / 写入结果在身份核对上的三种结论统一由 `IdentityCheck` 表达，「暂时未知」统一经 `IdentityDeferral` 记下待补做，身份确认时
//   由 App 对全部页面调 `IdentityResumable.resumeAfterIdentityConfirmed()` 统一补做。

/// 一次读出的身份快照（凭据可读性 + `SessionIdentity`）。
public struct IdentitySnapshot: Equatable, Sendable {
    public let identity: SessionIdentity
    /// 撤回同意的清理已完成、凭据可读（读取那一刻传入的内存标记）。
    public let readable: Bool

    public init(identity: SessionIdentity, readable: Bool) {
        self.identity = identity
        self.readable = readable
    }

    /// 身份已确认：凭据可读、禁读屏障没竖着、会话读取有结论（读到会话，或确认没有会话）。
    public var known: Bool {
        readable && identity.identityKnown
    }

    public var account: String? {
        readable ? identity.ownership.account : nil
    }

    /// 持久化登录世代（升级前登录、缺世代的合法旧会话为 nil：在线可用，按「账号 + 世代」分区的本机数据不读不写，F-X-21）。
    public var loginEpoch: String? {
        readable ? identity.loginEpoch : nil
    }

    public var member: Bool {
        readable && identity.member
    }

    public var generation: UInt64 {
        identity.ownership.generation
    }

    public var epoch: UInt64 {
        identity.ownership.epoch
    }

    /// 网络归属（账号、会话世代、作废世代，与上面同一次读取）。
    public var request: RequestOwnership {
        RequestOwnership(account: identity.ownership.account, generation: generation, epoch: epoch)
    }

    /// 按「账号 + 登录世代」分区的本机数据可用（F-X-21：身份已确认且账号、世代都有）。
    public var partitionUsable: Bool {
        known && account != nil && loginEpoch != nil
    }

    /// 判据（已确认身份时才有意义）。
    public var mark: SessionMark {
        SessionMark(account: account, generation: generation, epoch: epoch, loginEpoch: loginEpoch)
    }
}

/// 换代判据：账号、会话世代、作废世代与持久化登录世代（完整的已确认分区身份）。
public struct SessionMark: Equatable, Sendable {
    public let account: String?
    public let generation: UInt64
    public let epoch: UInt64
    public let loginEpoch: String?

    public init(account: String?, generation: UInt64, epoch: UInt64, loginEpoch: String?) {
        self.account = account
        self.generation = generation
        self.epoch = epoch
        self.loginEpoch = loginEpoch
    }
}

/// 一次核对快照的结论（订单、钱包同一套）。
public enum SessionOutcome: Equatable, Sendable {
    /// 身份暂时未知、内存里的会话 / 作废世代没变：什么都不做（不删、不写、不更新判据）。
    case deferred
    /// 身份暂时未知、但会话 / 作废世代已变：只作废内存里的显示与页面（页面换成未确认身份），不删、不对账、不更新判据。
    case invalidated
    /// 已确认，与上次已确认的相同：换上未知期间构造的页面、补做因身份未知中止的读取。
    case same
    /// 启动态落定（首次确认且有账号；或已确认的「没有账号」在世代不变时变成有账号）：按本次身份对账，不删恢复记录、不清页面；
    /// 换上没有账号的页面、补做中止的读取。
    case settled
    /// 已知换代（账号、会话世代、作废世代或登录世代变了；含首次确认没有会话）：清显示与共享闸门、按本次身份对账、重建页面。
    case changed
}

/// 换代判据（订单、钱包各持一份，判定规则只有这一处）。只在主线程使用。
@MainActor
public final class SessionReconciler {
    /// 上次已确认的判据；nil = 本进程还没有确认过身份（启动时身份暂时未知）。
    public private(set) var confirmed: SessionMark?
    /// 页面此刻所属的会话 / 作废世代（未知期间世代变化时据此只作废一次）。
    public private(set) var boundGeneration: UInt64
    public private(set) var boundEpoch: UInt64

    /// 初始化（启动时那一次快照）：已确认就记为判据；未知不记。
    public init(_ initial: IdentitySnapshot) {
        boundGeneration = initial.generation
        boundEpoch = initial.epoch
        confirmed = initial.known ? initial.mark : nil
    }

    /// 按这一次快照给出结论，并更新判据（只有已确认时才更新）。
    public func observe(_ snapshot: IdentitySnapshot) -> SessionOutcome {
        guard snapshot.known else {
            guard snapshot.generation != boundGeneration || snapshot.epoch != boundEpoch else { return .deferred }
            boundGeneration = snapshot.generation
            boundEpoch = snapshot.epoch
            return .invalidated
        }
        let mark = snapshot.mark
        let previous = confirmed
        confirmed = mark
        boundGeneration = mark.generation
        boundEpoch = mark.epoch
        guard let previous else {
            // 首次确认：没有会话按换代（重置页面与闸门、按无归属删除）；有账号是启动态落定（不删恢复记录，F-X-19）
            return mark.account == nil ? .changed : .settled
        }
        if previous == mark {
            return .same
        }
        if previous.account == nil, mark.account != nil, previous.generation == mark.generation,
           previous.epoch == mark.epoch {
            return .settled
        }
        return .changed
    }

    /// 页面已按这一份快照重建（撤回同意 / 切换环境的清理回调）：已确认时记为判据；未知时只记世代（判据保留，确认后按换代处理）。
    public func adopt(_ snapshot: IdentitySnapshot) {
        boundGeneration = snapshot.generation
        boundEpoch = snapshot.epoch
        if snapshot.known {
            confirmed = snapshot.mark
        }
    }
}

/// 页面固定身份与此刻身份的核对结论。
public enum IdentityCheck: Equatable, Sendable {
    /// 仍是当前会话：照常结算。
    case current
    /// 身份暂时未知（Keychain 暂时读失败、禁读屏障；或页面构造时身份未确认、还没换上）：不结算、不写，记待补做，身份确认后补做。
    case unknown
    /// 已确定不是当前会话（换代、撤回、切环境）：丢弃，换代另有重建。
    case stale
}

/// 一个页面因身份暂时未知而中止、待身份确认后补做的动作（读取重发、迟到结果的采用）。按槽位记（同一槽位只留最新一份）。只在主线程使用。
@MainActor
public final class IdentityDeferral {
    private var slots: [String] = []
    private var actions: [String: @MainActor () -> Void] = [:]

    public init() {}

    /// 有待补做的动作。
    public var isPending: Bool {
        !slots.isEmpty
    }

    public func isPending(_ slot: String) -> Bool {
        actions[slot] != nil
    }

    /// 核对结论的统一处理：当前 → 清掉这一槽、放行；暂时未知 → 记下这一槽的补做动作、执行结算（在途标记复位、无内容时进可重试的
    /// 结算态）、不放行；已不是当前 → 清掉这一槽、不放行（换代另有重建）。
    public func admit(
        _ check: IdentityCheck, slot: String, resume: @escaping @MainActor () -> Void, settle: () -> Void = {}
    ) -> Bool {
        switch check {
        case .current:
            drop(slot)
            return true
        case .unknown:
            hold(slot, resume)
            settle()
            return false
        case .stale:
            drop(slot)
            return false
        }
    }

    public func hold(_ slot: String, _ action: @escaping @MainActor () -> Void) {
        if actions[slot] == nil {
            slots.append(slot)
        }
        actions[slot] = action
    }

    public func drop(_ slot: String) {
        guard actions.removeValue(forKey: slot) != nil else { return }
        slots.removeAll { $0 == slot }
    }

    /// 会话换代、页面离开：全部作废。
    public func reset() {
        slots = []
        actions = [:]
    }

    /// 身份确认之后：取出全部待补做动作按登记顺序执行（各自在执行时重新核对身份；再次未知会重新登记）。
    public func resume() {
        let order = slots
        let pending = actions
        reset()
        for slot in order {
            pending[slot]?()
        }
    }
}

/// 能在身份确认后补做中止动作的页面（订单列表 / 详情、钱包摘要、提现、提现记录、收款账号、实名、劳务协议）。
@MainActor
public protocol IdentityResumable: AnyObject {
    /// 身份确认之后（判据相同也调）：补做因身份暂时未知而中止的读取与迟到结果。
    func resumeAfterIdentityConfirmed()
}
