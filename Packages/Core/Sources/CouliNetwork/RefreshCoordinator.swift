import Foundation
import Generated

/// 一个收到 10002、等待刷新后重放的请求。body 保留原始文本，重放时原样发出；key 为原 Idempotency-Key。
public struct RefreshRequest: Sendable, Equatable {
    public let id: String
    public let operation: ApiOperation
    public let key: String?
    public let body: String

    public init(id: String, operation: ApiOperation, key: String?, body: String) {
        self.id = id
        self.operation = operation
        self.key = key
        self.body = body
    }
}

/// 令牌单飞刷新（03 §4.2「Token 刷新」）：同一窗口里收到 10002 的请求只触发 1 次刷新，其余排队等待；
/// 刷新成功后每个等待的请求用新令牌沿用原键重放 1 次；刷新失败清会话一次，Effect 为跳登录（强更状态下只清会话、停在强更页）。
///
/// - `run`：非阻塞地接纳请求；没有进行中的刷新时发起一次 refresh。
/// - `join`：带「本次用的令牌」的接纳（管线用）。令牌世代检查、复用已完成结果与入队在同一把锁里完成：
///   本次用的令牌正是上一次已完成刷新所替换的那个（同一旧令牌晚到的 10002）→ 直接复用那次的结果（成功给新令牌，
///   失败不再清会话），不再开新窗口。
/// - `awaitRefresh`：不需要重放的刷新（受限会话屏障、10405 refresh_only），与请求共享同一窗口。
/// - 回调在刷新完成的线程上串行交付（先重放 / 清会话，再通知监听）。refresh 必须且只需回调一次；重复回调被忽略。
///
/// 这是三端共用向量（specs/network-vectors.json「refresh」）验证的单飞规则本身，不知道会话世代。`ApiClient` 在它之上
/// 按会话世代隔离窗口、把完整结果直接交给每个等待者（`RefreshWindow`、`RefreshOutcome`，见 ApiClient+Refresh.swift），
/// 规则相同：一个窗口只刷新一次、成功沿用原键重放、失败只清一次会话并按结算那一刻的强更状态定 Effect。
public final class RefreshCoordinator: @unchecked Sendable {
    /// 最近一次刷新的结果：none / replayed / clear_session_login / clear_session_stay_force_update。
    public static let effectNone = "none"
    public static let effectReplayed = "replayed"

    private let refresh: (@escaping (String?) -> Void) -> Void
    private let replay: (RefreshRequest, String) -> Void
    private let clearSession: () -> Void
    private let clock: () -> Int64
    private let onFailure: ([RefreshRequest]) -> Void
    private let forceUpdateNow: (() -> Bool)?

    private let lock = NSLock()
    private var waiting: [RefreshRequest] = []
    private var listeners: [(String?) -> Void] = []
    private var inFlight = false
    /// 已认领收尾（清会话进行中）；窗口仍算在途。
    private var completing = false
    private var forceUpdateInWindow = false
    private var window = 0
    /// 当前窗口发起时要替换的令牌（发起者本次用的令牌）。
    private var windowReplaces: String?
    /// 上一次完成的窗口：替换掉的令牌与结果（nil = 失败）。
    private var lastCompleted: (replaced: String, result: String?)?
    private var calls = 0
    private var replayCount = 0
    private var effect = RefreshCoordinator.effectNone
    private var completedAt: Int64?

    /// - Parameters:
    ///   - refresh: 发起一次刷新；完成时调用传入的回调：nil = 失败，非 nil = 新的 access_token。
    ///   - replay: 用新令牌重放一个请求（沿用 key 与 body）。
    ///   - clearSession: 刷新失败时清会话。
    ///   - onFailure: 刷新失败时本窗口里等待的请求（调用方据此结束它们的等待）。
    ///   - forceUpdateNow: 结算那一刻是否在强更状态（给了就以它为准，不用入队时传入的旧值）。
    public init(
        refresh: @escaping (@escaping (String?) -> Void) -> Void,
        replay: @escaping (RefreshRequest, String) -> Void,
        clearSession: @escaping () -> Void,
        clock: @escaping () -> Int64,
        onFailure: @escaping ([RefreshRequest]) -> Void = { _ in },
        forceUpdateNow: (() -> Bool)? = nil
    ) {
        self.forceUpdateNow = forceUpdateNow
        self.refresh = refresh
        self.replay = replay
        self.clearSession = clearSession
        self.clock = clock
        self.onFailure = onFailure
    }

    /// 实际发起的刷新次数。
    public var refreshCalls: Int {
        lock.withLock { calls }
    }

    /// 已重放的请求数。
    public var replayed: Int {
        lock.withLock { replayCount }
    }

    public var effectRaw: String {
        lock.withLock { effect }
    }

    /// 最近一次刷新完成的时刻（毫秒）。
    public var lastCompletedAtMillis: Int64? {
        lock.withLock { completedAt }
    }

    /// 是否有进行中的刷新。
    public var refreshing: Bool {
        lock.withLock { inFlight }
    }

    /// 接纳已收到 10002 的请求。forceUpdate = 当前在强更状态（刷新失败时只清会话、停在强更页）。
    public func run(requests: [RefreshRequest], forceUpdate: Bool) {
        guard !requests.isEmpty else {
            return
        }
        enqueue(usedToken: nil, currentToken: nil, forceUpdate: forceUpdate, request: requests, listener: nil)
    }

    /// 管线用：接纳一个请求并带上它本次用的令牌（见类型说明）。复用结果时同步回调 replay 或 onFailure。
    /// currentToken 在同一把锁里读取：没有进行中的刷新且当前令牌已不是本次用的（被别的刷新或登录换掉了）→ 直接用当前令牌。
    public func join(
        request: RefreshRequest,
        usedToken: String?,
        currentToken: (() -> String?)? = nil,
        forceUpdate: Bool
    ) {
        enqueue(
            usedToken: usedToken, currentToken: currentToken, forceUpdate: forceUpdate, request: [request],
            listener: nil
        )
    }

    /// 等待（必要时发起）一次刷新，不重放任何请求。listener 收到新令牌或 nil（失败）。规则同 join。
    public func awaitRefresh(
        usedToken: String? = nil,
        currentToken: (() -> String?)? = nil,
        forceUpdate: Bool,
        listener: @escaping (String?) -> Void
    ) {
        enqueue(
            usedToken: usedToken,
            currentToken: currentToken,
            forceUpdate: forceUpdate,
            request: [],
            listener: listener
        )
    }

    /// 丢弃上一次的完成结果（清会话、撤回同意、切换环境之后，旧令牌的结果不能再复用）。
    public func forgetCompleted() {
        lock.withLock { lastCompleted = nil }
    }

    private enum Admission {
        case start(Int)
        case joined
        case reuse(String?)
    }

    private func enqueue(
        usedToken: String?,
        currentToken: (() -> String?)?,
        forceUpdate: Bool,
        request: [RefreshRequest],
        listener: ((String?) -> Void)?
    ) {
        let admission: Admission = lock.withLock {
            if !inFlight {
                if let current = currentToken?(), current != usedToken {
                    return .reuse(current)
                }
                if let usedToken, let last = lastCompleted, last.replaced == usedToken {
                    return .reuse(last.result)
                }
            }
            waiting += request
            if let listener {
                listeners.append(listener)
            }
            forceUpdateInWindow = forceUpdateInWindow || forceUpdate
            if inFlight {
                return .joined
            }
            inFlight = true
            calls += 1
            window += 1
            windowReplaces = usedToken
            return .start(window)
        }
        switch admission {
        case let .start(id):
            refresh { [weak self] token in
                self?.complete(window: id, token: token)
            }
        case .joined:
            break
        case let .reuse(token):
            deliver(token, request, listener.map { [$0] } ?? [])
        }
    }

    /// 结算一批等待者：成功逐个重放，失败一次性交给 onFailure；然后通知监听。
    private func deliver(_ token: String?, _ batch: [RefreshRequest], _ notify: [(String?) -> Void]) {
        if let token {
            for item in batch {
                replay(item, token)
            }
            lock.withLock { replayCount += batch.count }
        } else if !batch.isEmpty {
            onFailure(batch)
        }
        for listener in notify {
            listener(token)
        }
    }

    /// 刷新收尾（三端同序）：保存或清除会话（保存在 refresh 回调之前已完成）→ 定下刷新结果 → 结算全部等待者 → 解除窗口。
    /// 清会话期间窗口保持在途：新来的 10002 并入本窗口、随失败一起结算，不会带着旧令牌先发出去。
    /// 每个等待者只结算一次；回调都是非抛出的，结算放在 defer 里，清理一侧出什么问题也不会漏结算。
    private func complete(window id: Int, token: String?) {
        let claimed: Bool = lock.withLock {
            // 同一窗口只完成一次（刷新回调被重复调用时忽略）。
            guard inFlight, id == window, !completing else {
                return false
            }
            completing = true
            return true
        }
        guard claimed else {
            return
        }
        var batch: [RefreshRequest] = []
        var notify: [(String?) -> Void] = []
        defer {
            deliver(token, batch, notify)
        }
        if token == nil {
            clearSession()
        }
        (batch, notify) = settleWindow(token)
    }

    /// 定下刷新结果并解除窗口；返回要结算的等待者。强更状态以结算这一刻为准（给了 forceUpdateNow 时）。
    private func settleWindow(_ token: String?) -> ([RefreshRequest], [(String?) -> Void]) {
        let now = clock()
        let forceUpdateAtSettle = forceUpdateNow?()
        return lock.withLock {
            let settled = (waiting, listeners)
            let forceUpdate = forceUpdateAtSettle ?? forceUpdateInWindow
            waiting.removeAll()
            listeners.removeAll()
            forceUpdateInWindow = false
            if let replaced = windowReplaces {
                lastCompleted = (replaced, token)
            }
            windowReplaces = nil
            completedAt = now
            if token != nil {
                effect = Self.effectReplayed
            } else {
                effect = forceUpdate
                    ? ErrorEffectKind.clearSessionStayForceUpdate.rawValue
                    : ErrorEffectKind.clearSessionLogin.rawValue
            }
            completing = false
            inFlight = false
            return settled
        }
    }
}
