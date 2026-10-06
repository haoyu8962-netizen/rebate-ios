// 冷启动与条件变化（F-IOS-08）：从 Router.swift 拆出，便于单独阅读。
import Foundation

public extension Router {
    /// 环境、隐私、强更或外壳（Tab）就绪状态变化时调用（App 的启动协调）。
    ///
    /// 1. 先记录闸门：环境与隐私闸门都通过的那一刻起算强更的 5 秒等待——与外壳是否就绪无关，不因 Tab 未就绪而推迟；
    /// 2. 环境、隐私、强更（有结果，或等满 5 秒按 unknown）与外壳都就绪后：
    ///    恢复持久化的 pending_action（未过期且前置满足 → 执行一次并删除；过期 → 读取时删除、不执行；
    ///    前置未满足 → 保留），再放行排队的启动意图（外壳就绪时已超时的直接按 unknown 交出）。
    /// 返回推送回查的任务（测试可等待）；没有时为 nil。
    @discardableResult
    func launchConditionsChanged(
        readiness: LaunchReadiness,
        shellReady: Bool,
        now: Int64,
        pushLanding: PushLanding? = nil
    ) -> Task<Void, Never>? {
        launchQueue.observeGates(readiness, now: now)
        guard shellReady, readiness.environmentSettled, readiness.privacy != .notDecided,
              let update = LaunchQueue.effectiveUpdate(
                  readiness.update,
                  now: now,
                  waitFrom: launchQueue.gatesOpenedAt
              )
        else {
            return nil
        }
        var current = state()
        current.environmentSettled = readiness.environmentSettled
        current.privacy = readiness.privacy
        current.update = update
        purgeAgentPendingIfPrivacyBlocked(current)
        // 用户在 App 内发起、正等待隐私弹窗结论的动作（`awaitingConsentResult`，只在内存）：本次登记的待办归弹窗结论处理
        // （同意 → 按前置继续；拒绝 → 删除），自动恢复不碰它（R1-01）。进程重启后标记不在，照常按 reject 删除（F-ALL-04）。
        if !awaitingConsentResult {
            resumePending(state: current, entersPrerequisite: false)
        }
        return drainLaunchQueue(readiness: readiness, now: now, pushLanding: pushLanding)
    }

    /// `launchConditionsChanged` 下一次该重试的时刻（毫秒）：闸门已通过、强更仍在检查、
    /// 且有排队的启动意图或待恢复的 pending_action 时为「闸门通过 + 5 秒」（不早于检查开始 + 5 秒）；否则 nil。
    /// 截止时间已到（`now` 不早于它）时也为 nil：超时那一次已按 unknown 协调过，之后还留着的待办（如游客的
    /// OrderList 要登录）只等强更结果或前置状态变化再协调，不再安排计时，避免零延迟循环（R1-06）。
    func launchConditionsRetryAt(readiness: LaunchReadiness, now: Int64) -> Int64? {
        guard readiness.environmentSettled, readiness.privacy != .notDecided,
              let opened = launchQueue.gatesOpenedAt,
              case let .checking(startedAt) = readiness.update,
              launchQueue.pending != nil || pendingStore.load(now: pendingStore.now) != nil
        else {
            return nil
        }
        let deadline = max(startedAt, opened) + LaunchQueue.updateWaitMillis
        return deadline > now ? deadline : nil
    }

    /// 强更 5 秒等待的起算时刻（测试与调试用）。
    var launchGatesOpenedAt: Int64? {
        launchQueue.gatesOpenedAt
    }

    /// 清空排队的启动意图（切换环境等）。注意：运行中停在首启弹窗时收到的**新**深链 / 推送由调用方直接忽略、
    /// 不入队即可，不要调用这里——那会连同冷启动带来的原意图一起删掉（R1-03）。
    func discardLaunchIntent() {
        launchQueue.discard()
    }

    // MARK: - 启动意图队列

    func enqueueLaunch(_ intent: LaunchIntent) {
        launchQueue.enqueue(intent)
    }

    var hasPendingLaunchIntent: Bool {
        launchQueue.pending != nil
    }

    /// 下一次该重试放行启动意图的时刻（毫秒）：闸门已通过、强更仍在检查时为「闸门通过 + 5 秒」；
    /// 闸门未就绪或没有排队的意图时为 nil（调用方不必空转计时，等状态变化再 drain）。
    func launchRetryAt(readiness: LaunchReadiness) -> Int64? {
        launchQueue.nextRetryAt(readiness: readiness)
    }

    // MARK: - 一级 Tab（APP-02b 评审，三端统一）

    /// 一级 Tab 点击：Tab 根路由同样按 App 内请求过守卫，不能绕过守卫直接显示受限页面。
    /// - 放行（open / open_readonly，且落点就是该路由）：返回结论，调用方切到该 Tab，并保留只读标记（强更 unknown、基本模式只读降级）；
    /// - 其余结论照 `open` 执行：需要登录等前置 → 登记 pending_action 并进前置页；基本模式 → 请求补同意（同样登记）；
    ///   拒绝 / 升级提示 / 等待 → 不切换。
    /// 返回值 `allowsSwitch` 为 true 时才切换 Tab。
    @discardableResult
    func selectTab(route: String) -> (decision: GuardDecision, allowsSwitch: Bool) {
        let request = RouteRequest(route: route, from: .inApp)
        let current = state()
        let decision = EntryGuard.decide(request: request, state: current, routes: routes)
        purgeAgentPendingIfPrivacyBlocked(current)
        if decision.opensPage, decision.route == route {
            lastDecision = decision
            // 切到该 Tab（R1-05）：Tab 选择状态由 Router 持有，外壳跟随 `tabRoot`。
            show(RouteDestination(route: route, readonly: decision.kind == .openReadonly))
            return (decision, true)
        }
        apply(decision, for: request)
        return (decision, false)
    }

    /// 进入基本模式（仍不同意、撤回同意）：清空导航栈，受限页面不得继续显示（APP-02b 评审，三端统一）。
    func enteredBasicMode() {
        path = []
        tabRoot = RouteDestination(route: RoutePolicy.home)
        privacyChanged()
    }
}
