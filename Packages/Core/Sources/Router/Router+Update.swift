// 强更（APP-02c）：ForceUpdate 页的进出、从强更页次要入口打开、前置完成后交给启动协调恢复（F-IOS-09）。
import Foundation

public extension Router {
    /// 强更状态（below_min）：无论停在哪个页面都进入 ForceUpdate（03 §4.1）。
    /// 已经在强更页（及其上的次要入口页面）时不动：从强更页进入的隐私政策、登录等页面不被打断，返回后回到强更页。
    func enterForceUpdate() {
        guard path.first?.route != RoutePolicy.forceUpdate else { return }
        path = [RouteDestination(route: RoutePolicy.forceUpdate)]
    }

    /// 强更状态解除（升级后或最低版本被调低后的复查）：离开 ForceUpdate 及其上的页面，回到 Tab 外壳。
    func leaveForceUpdate() {
        guard path.first?.route == RoutePolicy.forceUpdate else { return }
        path = []
    }

    /// 守卫此刻用的状态（页面按会话决定入口时读，如强更页「注销账号」未登录先去登录）。
    var currentGuardState: GuardState {
        state()
    }

    /// 是否正停在 ForceUpdate（含其上的次要入口页面）。
    var isOnForceUpdate: Bool {
        path.first?.route == RoutePolicy.forceUpdate
    }

    /// 强更页的次要入口（「隐私政策」→ PrivacyCenter、「注销账号」→ DeleteAccount，以及由此进入的 Agreement、Login）：
    /// 以 `fromForceUpdatePage` 过守卫（只放行这四个路由，03 §4.1、§4.4）。打开的页面带 `fromForceUpdatePage` 标记
    /// （登录页按受限登录显示）；需要登录时进登录页，不登记 pending_action（强更状态下不登记，03 §4.2）。
    @discardableResult
    func openFromForceUpdatePage(_ request: RouteRequest) -> GuardDecision {
        var current = state()
        current.fromForceUpdatePage = true
        let decision = EntryGuard.decide(request: request, state: current, routes: routes)
        lastDecision = decision
        switch decision.kind {
        case .open, .openReadonly, .requireLogin:
            guard let route = decision.route else { break }
            path.append(RouteDestination(
                route: route,
                params: route == request.route ? EntryGuard.effectiveParams(request) : [:],
                readonly: decision.kind == .openReadonly,
                fromForceUpdatePage: true
            ))
        case .requireConsent:
            // 基本模式下从强更页进需要同意的入口（如「注销账号」→ Login，R1-01）：弹补同意，强更页留着；
            // 不登记 pending_action（强更状态下不登记普通业务待办），请求只记在内存，同意后按强更来源继续。
            forceUpdateConsentRequest = request
            awaitingConsentResult = true
            consentRequested = true
        default:
            apply(decision, for: request)
        }
        return decision
    }

    /// 隐私弹窗（首启弹窗、二次说明、补同意）里的协议链接（F-ALL-06）：强更状态（below_min）下按强更来源打开
    /// ——Agreement 是强更页次要入口之一，弹窗叠在强更页上（或强更前的启动底上）时同样能读协议；其余情况照常 App 内打开。
    /// 只有 Agreement 走强更来源，别的路由不借这个口子绕过强更。
    @discardableResult
    func openFromPrivacyDialog(_ request: RouteRequest) -> GuardDecision {
        if RoutePolicy.privacyUndecidedReadableRoutes.contains(request.route), state().update == .belowMin {
            return openFromForceUpdatePage(request)
        }
        return open(request)
    }

    /// 完成了一个前置步骤（同意隐私政策等）：只重置待办计时并记下「刚完成前置」，恢复交给启动协调
    /// （`launchConditionsChanged`：环境、隐私、强更有结果或等满 5 秒、Tab 就绪后再恢复，F-IOS-09）。
    /// 没有待办时什么都不记。直接恢复的 `prerequisiteCompleted()` 只在调用方已确认条件都满足时用。
    func recordPrerequisiteCompleted() {
        guard pendingStore.load(now: pendingStore.now) != nil else { return }
        pendingStore.markStepDone(now: pendingStore.now)
        resumeAfterPrerequisite = true
    }

    /// 隐私弹窗已处理（App 用；F-IOS-09）：同 `consentHandled`，但同意后不直接恢复待办，交给启动协调。
    func consentResolved(granted: Bool) {
        awaitingConsentResult = false
        consentRequested = false
        if let request = forceUpdateConsentRequest {
            // 强更页发起的补同意（R1-01）：同意且仍在强更状态 → 按强更来源继续（受限登录）；拒绝或强更已解除 → 丢弃。
            forceUpdateConsentRequest = nil
            if granted, state().privacy == .consented, state().update == .belowMin {
                openFromForceUpdatePage(request)
            }
            return
        }
        guard let pending = pendingStore.load(now: pendingStore.now) else { return }
        guard granted, pending.origin != RouteSource.agentCard.rawValue else {
            pendingStore.clear()
            return
        }
        recordPrerequisiteCompleted()
    }
}
