import Combine
import CouliNetwork
import Foundation
import Router
import Session

/// LoginService 的生产出口（APP-05a）：Router（pending_action、导航栈）、强更状态，以及「状态变化」——App 接
/// AppRouting 的会话同步。登录集成测试用同一份代码与真实 Router（APP-05a 共性 2：不用替身直接重置导航栈）。
@MainActor
public final class RouterLoginHost: LoginHost {
    /// 强更检查进度 → AfterLogin.plan 的取值。
    public enum Update: Sendable {
        case checking
        case supported
        case below
        case unknown
    }

    private let router: Router
    private let update: @MainActor () -> Update
    private let markBelow: @MainActor () -> Void
    private let stateChanged: @MainActor (_ resumePending: Bool) -> Void
    private var pathWatch: AnyCancellable?

    /// - update：强更检查进度（App：AppUpdate.routerStatus 换算）；
    /// - markBelow：受限会话按「低于」处理（App：AppUpdate.on10405(nil)），已是低于时不调；
    /// - stateChanged：会话变化后的路由同步。`resumePending = false` 时只同步守卫的会话状态与强更页，不恢复 pending_action
    ///   （共性 10：已作废的尝试只能通知会话变了，不能顺带恢复待办）。
    public init(
        router: Router,
        update: @escaping @MainActor () -> Update,
        markBelow: @escaping @MainActor () -> Void,
        stateChanged: @escaping @MainActor (_ resumePending: Bool) -> Void
    ) {
        self.router = router
        self.update = update
        self.markBelow = markBelow
        self.stateChanged = stateChanged
    }

    /// 登录页确定出栈的同步出口（共性 9）：导航栈移除 Login（关闭、侧滑返回、清栈、强更替换导航栈）的同一次发布里作废
    /// 本次登录尝试并取消它的请求——不等页面 onDisappear（退场动画结束才回调）。`@Published` 在赋值前发布：此刻
    /// `router.path` 还是旧值，与新值比较即可判断 Login 是否被移除。登录成功时执行器自己 closeLogin 也会走到这里：
    /// 那时会话已保存、计划已定，作废不影响后续步骤。
    public func watchLoginPage(_ service: LoginService) {
        pathWatch = router.$path.sink { [weak self, weak service] next in
            MainActor.assumeIsolated {
                guard let self, let service else { return }
                if Self.removesLogin(from: self.router.path, to: next) {
                    service.invalidateAttempt()
                }
            }
        }
    }

    /// 旧栈里有 Login 页、新栈里同一页（按 id）不在了。
    nonisolated static func removesLogin(from old: [RouteDestination], to new: [RouteDestination]) -> Bool {
        let before = Set(old.filter { $0.route == RoutePolicy.login }.map(\.id))
        guard !before.isEmpty else { return false }
        let after = Set(new.filter { $0.route == RoutePolicy.login }.map(\.id))
        return !before.isSubset(of: after)
    }

    /// 守卫用的会话状态：按 ApiClient 经过会话隔离判断的会话现算：没有 → 游客；deletion_only → 受限；其余 → 已绑手机
    /// （短信登录的账号一定有手机号；TODO(APP-05b)：第三方登录的会话按 getMe.phone_bound 区分）。
    public nonisolated static func sessionState(scope: String?) -> SessionState {
        guard let scope else { return .guest }
        return scope == Session.SessionScope.deletionOnly ? .restricted : .phoneBound
    }

    public func updateState() -> String {
        switch update() {
        case .checking: AfterLoginUpdate.checking
        case .supported: AfterLoginUpdate.supported
        case .below: AfterLoginUpdate.below
        case .unknown: AfterLoginUpdate.unknown
        }
    }

    public func hasPendingAction() -> Bool {
        router.hasPendingAction
    }

    public func closeLogin() {
        router.removeRoute(RoutePolicy.login)
    }

    public func resumePending() {
        router.prerequisiteCompleted()
    }

    public func discardPending() {
        router.discardPendingAction()
    }

    public func enterForceUpdate() {
        // 受限会话在强更未知时网络层已按「低于」处理；检查中或其余情况在这里补一次，再同步强更页。登录页已由 closeLogin
        // 移除：栈底已是强更页（从强更页进入的受限登录）时落回强更页，否则由同步换成强更页（共性 2）。
        if update() != .below {
            markBelow()
        }
        stateChanged(false)
    }

    public func sessionChanged() {
        stateChanged(true)
    }

    public func sessionSynced() {
        stateChanged(false)
    }

    public func sessionEnded(throughSession: UInt64) {
        router.sessionEnded(throughSession: throughSession)
    }

    public func bindSessionTag(_ tag: @escaping @MainActor () -> UInt64) {
        router.sessionTag = tag
    }
}
