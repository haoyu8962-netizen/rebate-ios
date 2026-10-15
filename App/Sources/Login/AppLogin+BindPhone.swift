import CouliNetwork
import DesignSystem
import Foundation
import Generated
import Login
import Router
import Session
import UIKit

/// 第三方新号的绑手机引导（LoginBindPhoneGuide；BR-INV-03 细则 ①）。`session` 是第三方登录保存后的会话世代，`id` 是弹窗实例编号。
struct BindGuide: Equatable {
    let session: UInt64
    let provider: String
    let id: Int
}

/// Sign in with Apple 的 entitlement 开关（rule-gaps iOS I01）：Team ID 与 com.apple.developer.applesignin
/// 都没给，App/Couli.entitlements
/// 为空；没有 entitlement 时系统授权必定失败，所以三套构建都先关着（按钮不显示，不放点不动的按钮）。负责人给齐签名资料、entitlement
/// 加上后把它改成 true，流程不用改。TODO(N-29) APPLE-ENTITLEMENT。
enum AppleSignInSwitch {
    static let enabled = false
}

/// 读屏播报的旁路观察（测试核对「播报一次」）；生产为 nil。
@MainActor
enum AppLoginAnnounceProbe {
    static var observe: ((String) -> Void)?
}

extension AppLogin {
    /// 第三方适配器：正式微信恒不可用（无 SDK、无 AppID）；Release 的 Apple 按 entitlement 开关（AppleSignInSwitch）。Debug / Staging
    /// （App target 都定义 DEBUG）按构建配置默认显示 Apple 并接调试假授权，不靠启动参数（R1-06，N-41）；假适配器 Release 不编译。
    static func authorizers(arguments: [String] = ProcessInfo.processInfo.arguments) -> [String: ThirdPartyAuthorizer] {
        #if DEBUG
        return DebugFakeOAuth.authorizers(arguments: arguments)
        #else
        return releaseAuthorizers()
        #endif
    }

    /// Release 的正式适配器。
    static func releaseAuthorizers() -> [String: ThirdPartyAuthorizer] {
        [
            OAuthProvider.wechat: UnavailableWechatAuthorizer(),
            OAuthProvider.apple: AppleSignInAuthorizer(enabled: AppleSignInSwitch.enabled),
        ]
    }

    // MARK: - 接线

    /// 绑定成功的共享结算接上钱包（APP-13a 共性第 9 条）：清钱包里**全部** action 的 step-up token（内存缓存，换号后旧 token 不再可用）。
    func connect(wallet: AppWallet) {
        onPhoneBound = { [weak wallet] _ in wallet?.deps.tokens.onSessionChanged() }
    }

    func wireBindPhone() {
        // 第三方新号：登录页关闭后盖在恢复页上弹引导（不新增路由，rule-gaps 22 同口径）
        host.onBindGuide = { [weak self] session, provider in
            guard let self else { return }
            guideSerial += 1
            bindGuide = BindGuide(session: session, provider: provider, id: guideSerial)
        }
        // 绑定成功的共享结算（APP-13a 共性第 9、25 条）：已核对固定身份仍是当前会话。清全部 step-up token；解除暂缓（不恢复——出栈与
        // 「完成前置」恢复只由持有原页面许可的页面做，G66）；守卫重算；启动绑定后的新一轮 getMe 更新共享 Me 资料（R1-02：固定原请求归属、
        // 遵守读取限流、不复用绑定前的在途查询；页面在不在都做）。
        bind.onBound = { [weak self] owner in
            guard let self else { return }
            onPhoneBound?(owner)
            routing.router.dropPendingHold(session: owner.request.generation)
            routing.sessionStateChanged(resumePending: false)
            onBoundRefresh?(owner)
        }
        // 绑手机页出栈的同步出口：作废该实例（清空输入、倒计时、弹窗、并号凭据）；栈顶变化同步更新可见性
        pathWatch = routing.router.$path.sink { [weak self] next in
            MainActor.assumeIsolated { self?.pathChanged(next) }
        }
    }

    private func pathChanged(_ next: [RouteDestination]) {
        let alive = Set(next.map(\.id))
        for (id, entry) in bindEntries where !alive.contains(id) {
            bindEntries[id] = nil
            entry.left()
            leftUnbound(entry)
        }
        for (id, entry) in bindEntries where next.last?.id != id {
            entry.controller.disappeared()
        }
    }

    /// 未绑定就离开绑手机页（引导【去绑定】之后，暂缓仍在）：释放并只恢复（BR-INV-03 细则 ①、共性第 3 条）。在本次栈变更发布之后执行。
    private func leftUnbound(_ entry: BindPhoneEntry) {
        let generation = entry.controller.owner.request.generation
        guard routing.router.pendingHeld, phone.bound(generation: generation) != true else { return }
        Task { @MainActor [weak self] in
            self?.routing.router.releasePendingHold(.resumeOnly, session: generation)
        }
    }

    /// 绑手机页（RouteViewRegistry）：一个导航实例只建一次。
    func bindEntry(for destination: RouteDestination) -> BindPhoneEntry {
        if let existing = bindEntries[destination.id] {
            return existing
        }
        // AppLogin 随 App 存活，比任何绑手机页都长
        let entry = BindPhoneEntry(id: destination.id) { [unowned self] id in makeBindController(id) }
        bindEntries[destination.id] = entry
        return entry
    }

    private func makeBindController(_ id: UUID) -> BindPhoneController {
        BindPhoneController(owner: bind.identity(), entryId: id, service: bind, texts: texts, hooks: bindHooks())
    }

    private func bindHooks() -> BindPhoneHooks {
        var hooks = BindPhoneHooks()
        let router = routing.router
        hooks.isTop = { id in router.path.last?.id == id }
        hooks.sceneActive = { [weak self] in self?.sceneActive ?? false }
        hooks.open = { route in router.open(RouteRequest(route: route, from: .inApp)) }
        hooks.completed = { [weak self] id, generation in
            guard let self else { return }
            toast = CouliToastMessage(LoginDraftTexts.text(BindPhoneKeys.done))
            removeBindPage(id)
            // 真正绑定成功才算完成前置步骤（共性第 3 条）：重置计时后经 Router 守卫恢复
            router.releasePendingHold(.prerequisiteDone, session: generation)
        }
        hooks.alreadyBound = { [weak self] id, generation in
            self?.removeBindPage(id)
            // 进页查清已绑：只恢复，不算完成前置、不重置计时
            router.releasePendingHold(.resumeOnly, session: generation)
        }
        // 返回：只出栈本实例；未绑定离开的待办恢复交给出栈的同步出口（pathChanged → leftUnbound），与侧滑返回同一处理
        hooks.back = { id in router.path.removeAll { $0.id == id } }
        hooks.contactService = { [weak self] in
            if let customerService = self?.customerService {
                customerService(RoutePolicy.bindPhone)
            } else {
                router.open(RouteRequest(route: "Help", from: .inApp))
            }
        }
        hooks.announce = { text in
            guard !text.isEmpty else { return }
            AppLoginAnnounceProbe.observe?(text)
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        hooks.providerName = { [weak self] generation in
            guard let self, let last = oauth.lastProvider, last.generation == generation else { return nil }
            return LoginDraftTexts.text(LoginKeys.providerName(last.provider))
        }
        return hooks
    }

    /// 只出栈这一个实例（不按路由名，APP-09 共性第 50 条）。先从登记里摘掉，出栈的同步出口就不再按「未绑定离开」处理。
    private func removeBindPage(_ id: UUID) {
        let router = routing.router
        if let entry = bindEntries.removeValue(forKey: id) {
            entry.left()
        }
        guard router.path.contains(where: { $0.id == id }) else { return }
        router.path.removeAll { $0.id == id }
    }

    // MARK: - 引导

    /// 【暂不】/ 关闭：释放暂缓并只恢复（不重置计时，共性第 3 条）。
    func skipBindGuide(_ id: Int) {
        guard let guide = bindGuide, guide.id == id else { return }
        bindGuide = nil
        routing.router.releasePendingHold(.resumeOnly, session: guide.session)
    }

    /// 【去绑定】：暂缓继续，经 Router 打开 BindPhone（已登记的路由）；打不开（会话已变等）按【暂不】处理。
    func goBindPhone(_ id: Int) {
        guard let guide = bindGuide, guide.id == id else { return }
        bindGuide = nil
        let decision = routing.router.open(RouteRequest(route: RoutePolicy.bindPhone, from: .inApp))
        if !decision.opensPage {
            routing.router.releasePendingHold(.resumeOnly, session: guide.session)
        }
    }

    // MARK: - 会话与手机号状态

    /// 会话状态同步（AppRouting.sessionStateChanged）：会话换代时作废旧引导与旧绑手机页、按新身份重建（共性第 6、36 条）；失败记忆清零。
    func sessionStateSynced() {
        phoneQueryFailed = nil
        // 请求归属变更的同步出口：上一个归属的绑定限流（phoneGate）不带给新会话（R1-09）
        bind.ownershipChanged()
        if let guide = bindGuide, guide.session != client.sessionGeneration {
            bindGuide = nil
        }
        for entry in bindEntries.values where !bind.isCurrent(entry.controller.owner) {
            entry.rebuild()
        }
    }

    /// 恢复手机号级待办前先查当前会话的 phone_bound（共性第 2、8 条）：有 full 会话、状态未知、有需要手机号（或实名）的待办、没有在查、
    /// 本会话没有失败过时查一次；查清后经启动协调按 Router 守卫恢复（已绑 → 执行；未绑 → 保留，不自动拉起绑手机页）；失败保留待办。
    func ensurePhoneBindingKnown() {
        let generation = client.sessionGeneration
        guard routing.privacy.routerPrivacy == .consented, client.isolatedSessionScope == Session.SessionScope.full,
              phone.bound(generation: generation) == nil, !phoneSync.querying(generation: generation), !oauth.busy,
              phoneQueryFailed != generation, let route = routing.router.pendingRouteName,
              let auth = Routes.all[route]?.auth, auth == "phone" || auth == "realname"
        else { return }
        phoneSync.query { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .bound:
                routing.launchConditionsChanged()
            case .failed:
                phoneQueryFailed = generation
            case .stale:
                break
            }
        }
    }

    /// scenePhase：active 之外（inactive、background）都作废绑手机页的导航与弹窗许可（APP-09 共性第 77 条）；回到 active 时栈顶的页面重新出现。
    func scenePhaseChanged(active: Bool) {
        sceneActive = active
        let top = routing.router.path.last?.id
        for (id, entry) in bindEntries {
            if active, id == top {
                entry.controller.appeared()
            } else {
                entry.controller.disappeared()
            }
        }
    }
}
