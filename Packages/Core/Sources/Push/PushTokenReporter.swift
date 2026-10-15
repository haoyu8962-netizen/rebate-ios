import CouliNetwork
import Foundation
import MeCore

/// 推送令牌来源（G17）：当前令牌、令牌变化通知、启动 / 停止。真实实现接 MobPush iOS SDK（未接入，TODO(N-33)：AppKey、SDK 版本、APNs 证书与推送
/// 能力都没给，不加 `aps-environment`、不加新依赖）。令牌值只交给上报管线，不进日志、埋点、诊断信息与界面。
@MainActor
public protocol PushTokenSource: AnyObject {
    /// PrivacyGate.onConsented 的推送步骤调用（Release 为空操作）。
    func start()
    /// 撤回同意时停止（不再给令牌、不再通知）。
    func stop()
    func current() -> String?
    /// 令牌值变化（含第一次拿到）；返回退订函数。
    func subscribe(_ listener: @escaping @MainActor () -> Void) -> () -> Void
}

/// Release 的令牌来源：恒为无令牌（不初始化任何推送 SDK、不上报、不报错，G17）。
@MainActor
public final class NoPushTokenSource: PushTokenSource {
    public init() {}

    public func start() {}

    public func stop() {}

    public func current() -> String? {
        nil
    }

    public func subscribe(_: @escaping @MainActor () -> Void) -> () -> Void {
        {}
    }
}

/// 上报管线读的 App 状态（App 组合处给；都在主线程调用）。
@MainActor
public protocol PushReportState: AnyObject {
    /// member（已同意且已登录）/ guest / basic（未同意、基本模式、撤回清理未完成）。
    func level() -> String
    /// full / deletion_only（没有会话为空串）。
    func sessionScope() -> String
    /// 强更结论：supported / below / unknown。
    func forceUpdate() -> String
    /// 当前会话世代的标识（会话世代 + 账号；没有会话为空串）。
    func sessionKey() -> String
    /// 当前会话固定的网络归属（请求只与它比较，不一致零发送）；没有为 nil。
    func ownership() -> RequestOwnership?
    /// 10405：交已有的强更分流（网络层对确需强更的 10405 已调 onForceUpdate；这里只补交，不另弹提示）。
    func onForceUpdate()
}

/// 推送令牌上报执行器（会话级服务，不依赖页面；brief §2.13，G18）。按 `PushReportPolicy` 的结论发 POST /v1/devices/push-token
/// {provider: mobpush, token}；请求绑定发起时的会话世代与固定网络归属（会话变了即作废，旧会话的响应只按原世代结算，不改新会话）。退出、撤回后
/// 终止并另建策略实例。
/// - 停报（共性第 2、19 条）：撤回同意、退出登录在确认生效的同步入口调用 `beginWithdraw` / `halt`，之后的触发、实际发送前（发送前闸门）与结算
///   三处都检查；撤回停报闸门与会话无关，撤回完成（`endWithdraw`）前登录新会话也不恢复上报；
/// - 冷启动等待（共性第 3 条）：已登录冷启动等隐私与版本检查完成，期间的令牌变化合并到这次冷启动上报；
/// - 限流（R1-07，共性第 33 条）：会话级闸门 `gate`。响应是 42901 时先按 Retry-After 启动禁用期（缺省 / 非法 5 秒；只认仍属发起会话的结果），
///   再结算策略、决定是否补发待报；每次实际发送前（触发时与传输层写出前）都核对闸门。禁用期内的新触发（含补发待报）不发，到期后按当时的会话与
///   令牌值补一次（新的触发，不是重试失败的旧请求；失败不自动重试，G18）。会话换代、退出、撤回时闸门与延后的触发一并清掉；到期后任一触发
///   实际开始发送时同步消费本会话延后的触发（R2-02），同一令牌只报一次。
@MainActor
public final class PushTokenReporter {
    public static let operation = "reportPushToken"
    /// 04 push_tokens.provider（契约是字符串，G18）。
    public static let provider = "mobpush"

    private let source: PushTokenSource
    private weak var state: PushReportState?
    private let api: MeApi
    private var policy = PushReportPolicy()
    private var flags: [PushCallFlag] = []
    private var tasks: [Task<Void, Never>] = []
    private var haltedSession: String?
    private var withdrawing = false
    private var coldStartHeld = false
    private var reportedSession: String?
    private var unsubscribe: (() -> Void)?
    /// 会话级限流闸门（42901 Retry-After）。
    public let gate: RetryAfterGate
    /// 禁用期内被拦下、到期后要补一次的触发所属的会话（nil = 没有）。
    private var deferredSession: String?
    private var deferTask: Task<Void, Never>?
    /// 发出的条数（测试与诊断用；不含令牌）。
    public private(set) var sent = 0

    public init(source: PushTokenSource, state: PushReportState, api: MeApi, gate: RetryAfterGate = RetryAfterGate()) {
        self.source = source
        self.state = state
        self.api = api
        self.gate = gate
        unsubscribe = source.subscribe { [weak self] in self?.tokenChanged() }
    }

    public var inFlight: Bool {
        policy.inFlight
    }

    public var pending: Bool {
        policy.pending
    }

    /// 处于停报中：撤回同意进行中（不论会话），或当前会话已停报（退出登录进行中）。
    public var halted: Bool {
        withdrawing || (haltedSession.map { $0 == sessionKey } ?? false)
    }

    public var withdrawHalted: Bool {
        withdrawing
    }

    public var holdingForColdStart: Bool {
        coldStartHeld
    }

    /// 本次运行在当前会话里是否有一条上报成功（诊断信息「推送是否已上报」，AC-S1-136）：绑定成功那一刻的会话，换账号、退出后不算到当前会话。
    public var reportedThisRun: Bool {
        guard let reportedSession, !reportedSession.isEmpty else { return false }
        return reportedSession == sessionKey
    }

    /// 当前会话标识（App 已释放时为空串）。
    private var sessionKey: String {
        state?.sessionKey() ?? ""
    }

    /// 撤回同意、退出登录在确认生效的同步入口调用：设会话级停报、清待报、作废在途请求，之后本会话里的触发一律不发。
    public func halt() {
        haltedSession = sessionKey
        coldStartHeld = false
        terminate()
    }

    /// 撤回同意确认生效的同步入口：设撤回停报闸门（不随会话变化解除），并按 `halt` 清待报、作废在途。与 `endWithdraw` 成对调用。
    public func beginWithdraw() {
        withdrawing = true
        halt()
    }

    /// 撤回清理结束（成功或落盘失败都调）：解除撤回停报闸门。之后是否上报仍按隐私结论与会话判断（基本模式不报）。
    public func endWithdraw() {
        withdrawing = false
    }

    public func holdForColdStart() {
        coldStartHeld = true
    }

    public func releaseColdStart() {
        coldStartHeld = false
    }

    private func snapshot() -> [String: Any] {
        let token = source.current() ?? ""
        return [
            "levelRaw": state?.level() ?? "basic", "sessionScopeRaw": state?.sessionScope() ?? "",
            "hasToken": !token.isEmpty, "token": token, "forceUpdateRaw": state?.forceUpdate() ?? "unknown",
            "session": sessionKey,
        ]
    }

    /// 已登录冷启动（隐私闸门通过、强更检查不低于、会话 full 之后）；初始化期间的令牌变化合并到这一次。
    public func coldStart() {
        coldStartHeld = false
        guard !halted else { return }
        run(policy.on(event: PushEvent.coldStart, state: snapshot()))
    }

    /// 登录成功（新会话已保存）。
    public func loginSucceeded() {
        coldStartHeld = false
        guard !halted else { return }
        run(policy.on(event: PushEvent.loginSuccess, state: snapshot()))
    }

    /// 会话换代（换账号）：作废在途与待报。
    public func sessionChanged() {
        coldStartHeld = false
        cancelAll()
        clearLimit()
        _ = policy.on(event: PushEvent.sessionChanged, state: snapshot())
    }

    /// 退出登录、会话失效到游客、切换环境：终止本实例并另建（之后的登录用新实例）。
    public func loggedOut() {
        coldStartHeld = false
        terminate()
    }

    /// 撤回同意：终止、停令牌来源、清待报与「已上报」；另建策略实例（重新同意并登录后再启用）。
    public func consentWithdrawn() {
        coldStartHeld = false
        terminate()
        reportedSession = nil
        source.stop()
    }

    private func terminate() {
        cancelAll()
        clearLimit()
        _ = policy.on(event: PushEvent.logout, state: [:])
        policy = PushReportPolicy()
    }

    private func cancelAll() {
        for flag in flags {
            flag.invalidate()
        }
        for task in tasks {
            task.cancel()
        }
        flags = []
        tasks = []
    }

    /// 会话级限流随会话结束：禁用期与延后的触发都不带给下一个会话。
    private func clearLimit() {
        gate.reset()
        deferredSession = nil
        deferTask?.cancel()
        deferTask = nil
    }

    /// 是否还在禁用期（测试与诊断）。
    public var limited: Bool {
        gate.active
    }

    /// 禁用期内被拦下的触发：撤掉策略里刚记的「在途」（本地没发出），到期后按当时的会话与令牌值补一次。
    private func deferUntilGateOpens(_ sending: UUID, _ session: String) {
        _ = policy.on(event: PushEvent.responseError, state: ["session": session])
        deferredSession = session
        deferTask?.cancel()
        let wait = UInt64(max(1, gate.remainingMillis))
        deferTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            guard !Task.isCancelled, let self, deferredSession == session, policy.instance == sending else { return }
            deferredSession = nil
            deferTask = nil
            guard !gate.active, !coldStartHeld, !halted, sessionKey == session else { return }
            run(policy.on(event: PushEvent.tokenChanged, state: snapshot()))
        }
    }

    /// 消费延后的触发（只认同一会话）：清掉登记并取消还没执行的延后任务。
    private func consumeDeferred(_ session: String) {
        guard deferredSession == session else { return }
        deferredSession = nil
        deferTask?.cancel()
        deferTask = nil
    }

    private func tokenChanged() {
        // 冷启动等待中：合并到冷启动上报；停报中：不发（共性第 2、3 条）
        guard !coldStartHeld, !halted else { return }
        run(policy.on(event: PushEvent.tokenChanged, state: snapshot()))
    }

    private func run(_ action: [String: Any]) {
        guard action["actionRaw"] as? String == PushAction.send, !halted,
              let token = action["sendToken"] as? String, let session = action["sendSession"] as? String
        else { return }
        let sending = policy.instance
        // 每次实际发送前核对会话级限流（R1-07）：禁用期内不发，到期后补一次
        if gate.active {
            deferUntilGateOpens(sending, session)
            return
        }
        guard let owner = state?.ownership(), owner.account != nil else {
            settle(sending, PushEvent.responseError, session)
            return
        }
        // 真正开始发送本会话的最新令牌：同步消费该会话尚未执行的延迟触发（R2-02，G18 / I26）。禁用期已到期、延后任务还没恢复时先来的
        // 新触发已经带上最新值，旧任务不得再登记一次待报，否则同一令牌上报两次。
        consumeDeferred(session)
        // 发送前与收到响应后都核对：会话已换代、停报（撤回 / 退出在同步入口作废全部在途，写出前的发送前闸门同样拦住）、实例已换就作废
        // （不改绑到新会话）
        let flag = PushCallFlag()
        flags.append(flag)
        let body = MeJson.text(["provider": Self.provider, "token": token])
        sent += 1
        let api = api
        let allowed = gate.sendAllowed
        let task = Task { @MainActor [weak self] in
            let result = await api.send(
                ApiCall(operationId: Self.operation, body: body), isValid: { flag.isValid },
                sendAllowed: { flag.isValid && allowed() }, expected: owner
            )
            guard let self, flag.isValid else { return }
            flags.removeAll { $0 === flag }
            let event: String
            switch result {
            case .success:
                if policy.instance == sending, !halted, sessionKey == session {
                    reportedSession = session
                }
                event = PushEvent.responseOk
            case let .failure(code, _, _, _, _, _) where code == 10405:
                event = PushEvent.response10405
            case let .failure(code, _, _, _, effect, _) where code == 42901:
                // 先结算限流再决定补发待报（共性第 22、33 条）；只认仍属发起会话的结果（共性第 34 条）
                if policy.instance == sending, !halted, sessionKey == session {
                    gate.start(effect.disableMillis ?? MeCodes.defaultRetryMillis)
                }
                event = PushEvent.responseError
            default:
                event = PushEvent.responseError
            }
            settle(sending, event, session)
        }
        tasks.append(task)
    }

    private func settle(_ sending: UUID, _ event: String, _ session: String) {
        guard policy.instance == sending else { return }
        let next = policy.on(event: event, state: ["session": session])
        if next["actionRaw"] as? String == PushAction.forceUpdate {
            // 10405 在后台得到：交已有分流（网络层已进强更时重复调用无害），不另弹提示
            state?.onForceUpdate()
            return
        }
        if !halted {
            run(next)
        }
    }

    /// 测试与进程结束：退订令牌来源。
    public func close() {
        unsubscribe?()
        unsubscribe = nil
    }
}

/// 一次上报的归属（线程安全）：停报、换代、终止时在主线程同步作废；网络层在任意线程读。
final class PushCallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.withLock { valid }
    }

    func invalidate() {
        lock.withLock { valid = false }
    }
}
