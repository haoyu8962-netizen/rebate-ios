import Config
import Foundation
import Me
import MeCore
import Router
import SwiftUI

/// 栈里一个「我的」类页面（导航实例 → 执行器与外壳）。
@MainActor
final class MePageEntry {
    let route: String
    /// 页面出现（返回本页、进入）：按 G36 取一次。
    let appeared: () -> Void
    /// 身份变了（不是只能登录访问的页面）：作废旧执行器、按新身份新建。
    let rebuild: (MeIdentity) -> Void
    /// 真正出栈（同步出口）：作废读请求、清草稿。
    let leave: () -> Void
    let screen: () -> AnyView
    /// 测试取执行器。
    let controller: () -> AnyObject

    init(route: String, appeared: @escaping () -> Void, rebuild: @escaping (MeIdentity) -> Void,
         leave: @escaping () -> Void, screen: @escaping () -> AnyView, controller: @escaping () -> AnyObject) {
        self.route = route
        self.appeared = appeared
        self.rebuild = rebuild
        self.leave = leave
        self.screen = screen
        self.controller = controller
    }
}

/// 页面创建、出栈、身份重建，「我的」Tab 的进入 / 离开与场景前后台。
extension AppMe {
    /// 路由目的地对应的页面（一个导航实例只建一次执行器；出栈时在同步出口作废，APP-04 第 28 条）。
    func entry(for destination: RouteDestination) -> MePageEntry? {
        if let existing = pages[destination.id] {
            return existing
        }
        guard let route = destination.route, let made = makeEntry(route, destination) else { return nil }
        pages[destination.id] = made
        let id = destination.id
        lifetimes.register(destination) { [weak self] in
            self?.pages.removeValue(forKey: id)?.leave()
        }
        return made
    }

    private func makeEntry(_ route: String, _ destination: RouteDestination) -> MePageEntry? {
        let id = destination.id
        let deps: MeDeps = deps
        switch route {
        case "Settings":
            return hostEntry(route, make: { SettingsController(deps: deps, identity: $0, page: id) },
                             appeared: { $0.refresh() }, leave: { $0.leave() },
                             screen: { AnyView(SettingsScreen(host: $0)) })
        case "PrivacyCenter":
            // 从强更页进入（打开时固定，03 §4.1）：只留清单、协议与【撤回同意】
            let forced = destination.fromForceUpdatePage || routing.mustShowForceUpdate
            return hostEntry(route, make: { identity in
                PrivacyCenterController(deps: deps, identity: identity, page: id, forceUpdate: forced)
            }, appeared: { $0.refresh() }, leave: { $0.leave() }, screen: { AnyView(PrivacyCenterScreen(host: $0)) })
        case "About":
            let controller = AboutController(deps: deps)
            return MePageEntry(route: route, appeared: {}, rebuild: { _ in }, leave: { controller.leave() },
                               screen: { AnyView(AboutScreen(controller: controller)) }, controller: { controller })
        case Self.riskNotice:
            let controller = RiskNoticeController(deps: deps, identity: computeIdentity(), page: id)
            return MePageEntry(route: route, appeared: { controller.load() }, rebuild: { _ in controller.leave() },
                               leave: { controller.leave() },
                               screen: { AnyView(RiskNoticeScreen(controller: controller)) },
                               controller: { controller })
        case Self.appeal:
            let controller = AppealController(deps: deps, identity: computeIdentity(), page: id)
            return MePageEntry(route: route, appeared: { controller.load() }, rebuild: { _ in controller.leave() },
                               leave: { controller.leave() },
                               screen: { AnyView(AppealScreen(controller: controller)) }, controller: { controller })
        default:
            return nil
        }
    }

    /// 按身份重建执行器的页面（设置、隐私中心）：页面观察 `MePageHost`，身份变了同步作废旧执行器、按新身份新建（共性第 18 条）。
    private func hostEntry<Controller: AnyObject>(
        _ route: String, make: @escaping (MeIdentity) -> Controller, appeared: @escaping (Controller) -> Void,
        leave: @escaping (Controller) -> Void, screen: @escaping (MePageHost<Controller>) -> AnyView
    ) -> MePageEntry {
        let host = MePageHost(make(computeIdentity()))
        host.onAppear = { appeared(host.controller) }
        return MePageEntry(
            route: route, appeared: { appeared(host.controller) },
            rebuild: { identity in
                leave(host.controller)
                host.replace(make(identity))
                appeared(host.controller)
            },
            leave: { leave(host.controller) }, screen: { screen(host) }, controller: { host.controller }
        )
    }

    /// 身份变了：栈里的页面与「我的」Tab 根按新身份重建（只能登录访问的页面已先移出导航栈）。
    func rebuildPages(_ identity: MeIdentity) {
        for entry in pages.values where !Self.loginOnly.contains(entry.route) {
            entry.rebuild(identity)
        }
        let wasEntered = tabEntered
        leaveTab()
        tabHost.replace(MeTabController(deps: deps, identity: identity))
        if wasEntered {
            enterTab()
        }
    }

    // MARK: - 「我的」Tab

    /// 「我的」Tab 根此刻可见：Tab 是「我的」、上面没有压页面、场景在前台。
    var tabVisible: Bool {
        router.tabRoot.route == Self.me && router.path.isEmpty && sceneActive
    }

    /// 进入（Tab 根出现、从子页返回、回前台）：上一次进入已离开就按此刻身份新建执行器（每一次进入一个，R1-03），取一次 Me、查引导条（G36）。
    func enterTab() {
        guard tabVisible, !tabEntered else { return }
        tabEntered = true
        let identity = computeIdentity()
        if tabHost.controller.hasLeft || tabHost.controller.identity != identity {
            tabHost.replace(MeTabController(deps: deps, identity: identity))
        }
        tabHost.controller.autoRefresh()
        tabHost.controller.checkGuideBar()
    }

    /// 离开（切到别的 Tab、被下一页盖住、进后台、身份变了）的同步出口：撤销这一次进入的读取许可并取消在途 getMe（R2-01）。
    func leaveTab() {
        guard tabEntered else { return }
        tabEntered = false
        tabHost.controller.leave()
    }

    /// Router 栈变了（@Published 在赋值前发出，`path` 是新值）：导航票据加一；离开「我的」Tab 根在同步出口立即生效；回到可见放到下一轮主线程
    /// （那时 Router 的两个发布值都已落定）。
    func pathChanged(_ path: [RouteDestination]) {
        navigated()
        if !path.isEmpty {
            leaveTab()
        } else {
            scheduleEnterTab()
        }
    }

    func tabRootChanged(_ root: RouteDestination) {
        navigated()
        if root.route != Self.me {
            leaveTab()
        } else {
            scheduleEnterTab()
        }
    }

    private func navigated() {
        tickets.advance()
        if !internalNavigation {
            userNavigations += 1
        }
    }

    private func scheduleEnterTab() {
        guard !tabEnterScheduled else { return }
        tabEnterScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            tabEnterScheduled = false
            enterTab()
        }
    }

    /// 系统 scenePhase 的接线：只有 active 算在前台；inactive（通知中心、系统弹窗）与 background 一样立即作废导航许可（导航票据加一，APP-09
    /// 共性第 77 条）。回前台：重新同步身份（撤回清理、会话可能在后台变了），「我的」可见时按新的一次进入取一次（G36）。
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard !sceneActive else { return }
            sceneActive = true
            syncIdentity()
            enterTab()
        default:
            guard sceneActive else { return }
            sceneActive = false
            navigated()
            leaveTab()
        }
    }
}

/// 会话级清理项（G29）：撤回同意与切换环境时清内存里的 Me 快照、草稿、推送上报状态、客服半屏与禁用期；设备级偏好在 MeLocalCleaner（只撤回）。
@MainActor
final class MeSessionCleaner: EnvironmentSwitchCleaning {
    enum Kind {
        case withdrawal, environment
    }

    static let withdrawalName = "Me.session.withdrawal"
    static let environmentName = "Me.session.environment"
    let cleanerName: String
    let kind: Kind
    weak var owner: AppMe?

    init(kind: Kind, owner: AppMe) {
        self.kind = kind
        self.owner = owner
        cleanerName = kind == .withdrawal ? Self.withdrawalName : Self.environmentName
    }

    func cleanForEnvironmentSwitch() throws {
        switch kind {
        case .withdrawal: owner?.clearForConsentRevoked()
        case .environment: owner?.clearForEnvironmentSwitch()
        }
    }

    static func register(
        withdrawal: EnvironmentSwitchCleanerRegistry,
        environmentSwitch: EnvironmentSwitchCleanerRegistry,
        owner: AppMe
    ) {
        withdrawal.replace(MeSessionCleaner(kind: .withdrawal, owner: owner))
        environmentSwitch.replace(MeSessionCleaner(kind: .environment, owner: owner))
    }
}
