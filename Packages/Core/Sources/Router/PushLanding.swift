import Foundation
import Generated

/// 按消息编号回查的结果（GET /v1/messages/{message_id}，04 §6.4）。
public enum PushLookupResult: Sendable, Equatable {
    /// 回查成功；route 可能为空。
    case found(route: String?, params: [String: JSONValue])
    /// 30701：消息不存在或不属于当前账号。
    case notFound
    /// 请求失败。
    case failed
}

/// 推送点击的落点结论。
public struct PushLandingResult: Sendable, Equatable {
    public let decision: GuardDecision
    /// 交给守卫的请求（回查到的 route 或兜底的 Messages）；没有回查时为 nil。
    public let request: RouteRequest?
    /// 未登录时：登录成功后要打开的请求（Messages，不回查这条消息）。
    public let afterLogin: RouteRequest?
}

/// 推送点击（03 §4.4「推送点击」，BR-ID-10 细则「推送点击的落点」）：
/// 载荷只带消息编号 → 先过守卫（环境、隐私、强更）→ 已登录时用注入的回查函数取 route → 以 push 入口再过守卫。
/// 未登录：进登录页，登录成功后打开 Messages，不拿这条消息编号回查新登录的账号。
/// 回查失败、超时、30701、route 为空：打开 Messages。
public struct PushLanding: Sendable {
    /// 推送回查等待上限（03 §4.4，客户端常量）。
    public static let lookupTimeout: Duration = .seconds(5)

    private let lookup: @Sendable (String) async -> PushLookupResult
    private let timeout: Duration

    public init(
        timeout: Duration = PushLanding.lookupTimeout,
        lookup: @escaping @Sendable (String) async -> PushLookupResult
    ) {
        self.timeout = timeout
        self.lookup = lookup
    }

    public func land(
        messageId: String,
        state: GuardState,
        routes: [String: RouteSpec] = Routes.all
    ) async -> PushLandingResult {
        if let blocked = Self.probe(state: state, routes: routes) {
            return blocked
        }
        let messages = RouteRequest(route: RoutePolicy.messages, from: .push)
        let request = await messageId.isEmpty ? messages : requestFor(lookupWithTimeout(messageId), fallback: messages)
        return Self.resolve(lookedUp: request, state: state, routes: routes)
    }

    /// 回查之前先过守卫里与目标无关的几步：用 Messages 作探针（它只声明 in_app、push，且在只读清单里）。
    /// 需要停下（等待、强更、隐私、未登录等）时返回结论；可以回查时返回 nil。
    public static func probe(state: GuardState, routes: [String: RouteSpec] = Routes.all) -> PushLandingResult? {
        let messages = RouteRequest(route: RoutePolicy.messages, from: .push)
        let probe = EntryGuard.decide(request: messages, state: state, routes: routes)
        switch probe.kind {
        case .deferred, .forceUpdate, .reject, .requireConsent, .upgrade:
            return PushLandingResult(decision: probe, request: nil, afterLogin: nil)
        case .requireLogin:
            let afterLogin = RouteRequest(route: RoutePolicy.messages, from: .pendingAction)
            return PushLandingResult(decision: probe, request: nil, afterLogin: afterLogin)
        case .open, .openReadonly, .requireBindPhone, .requireRealname:
            return nil
        }
    }

    /// 对回查得到的请求（或兜底的 Messages）按给定状态判定。Router 在回查返回时用**当时最新**的状态再调一次，
    /// 回查挂起期间发生的退出登录、强更、环境变化、隐私变化都生效（R1-01）。
    public static func resolve(
        lookedUp request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec] = Routes.all
    ) -> PushLandingResult {
        if let blocked = probe(state: state, routes: routes) {
            return blocked
        }
        let decision = EntryGuard.decide(request: request, state: state, routes: routes)
        return PushLandingResult(
            decision: guardedFallback(decision, for: request, state: state, routes: routes),
            request: request,
            afterLogin: nil
        )
    }

    /// 守卫把回查到的路由改落 Messages 时（未声明 push、强更未知），Messages 本身也要再过一次守卫：
    /// 守卫拦下 Messages 就按 Messages 的结论处理；放行时保留兜底原因码，任一方只读则只读。
    static func guardedFallback(
        _ decision: GuardDecision,
        for request: RouteRequest,
        state: GuardState,
        routes: [String: RouteSpec]
    ) -> GuardDecision {
        guard decision.route == RoutePolicy.messages, request.route != RoutePolicy.messages else {
            return decision
        }
        let messages = EntryGuard.decide(
            request: RouteRequest(route: RoutePolicy.messages, from: .push),
            state: state,
            routes: routes
        )
        guard messages.opensPage, messages.route == RoutePolicy.messages else {
            return messages
        }
        let readonly = decision.kind == .openReadonly || messages.kind == .openReadonly
        return GuardDecision(
            kind: readonly ? .openReadonly : .open,
            route: RoutePolicy.messages,
            reason: decision.reason
        )
    }

    private func requestFor(_ result: PushLookupResult, fallback: RouteRequest) -> RouteRequest {
        if case let .found(route?, params) = result, !route.isEmpty {
            return RouteRequest(route: route, values: params, from: .push)
        }
        return fallback
    }

    /// 超时按失败处理（03 §4.4：推送回查最多等 5 秒）。回查与计时做一次性竞争：先到的结果结束等待，
    /// 不依赖回查函数响应取消（R2-02）——不用 withTaskGroup（它退出前要等子任务结束）；迟到的结果丢弃。
    private func lookupWithTimeout(_ messageId: String) async -> PushLookupResult {
        let lookup = lookup
        let timeout = timeout
        let race = OneShotRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PushLookupResult, Never>) in
                race.install(continuation)
                let lookupTask = Task {
                    let result = await lookup(messageId)
                    race.finish(result)
                }
                let timerTask = Task {
                    try? await Task.sleep(for: timeout)
                    race.finish(.failed)
                }
                race.onFinish {
                    lookupTask.cancel()
                    timerTask.cancel()
                }
            }
        } onCancel: {
            race.finish(.failed)
        }
    }
}

/// 一次性结果竞争：只有第一个 `finish` 恢复等待方，其余（迟到的回查结果）丢弃。
private final class OneShotRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PushLookupResult, Never>?
    private var result: PushLookupResult?
    private var cleanup: (@Sendable () -> Void)?
    private var finished = false

    func install(_ continuation: CheckedContinuation<PushLookupResult, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// 结束后要做的清理（取消剩余工作）；已结束时立即执行。
    func onFinish(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            action()
            return
        }
        cleanup = action
        lock.unlock()
    }

    func finish(_ value: PushLookupResult) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        result = value
        let continuation = continuation
        let cleanup = cleanup
        self.continuation = nil
        self.cleanup = nil
        lock.unlock()
        continuation?.resume(returning: value)
        cleanup?()
    }
}
