import CouliNetwork
import Foundation
import Router
import SwiftUI
import Wallet
import WalletCore

/// 栈里一个钱包类页面（导航实例 → 执行器与外壳）。
@MainActor
final class WalletPageEntry {
    let route: String
    let context: WalletPageContext
    let controller: AnyObject
    let setVisible: (Bool) -> Void
    let sessionChanged: (WalletOwner) -> Void
    let leave: () -> Void
    let screen: () -> AnyView
    /// 页面此刻绑定的固定身份（构造时那一次快照；换上身份、换代重建时更新）。
    var owner = WalletOwner.none
    /// 构造时身份未确认的页面在身份确认后换上身份（缺省同换代：清空并按新身份重取；提现页另按新身份恢复金额草稿）。
    lazy var identityConfirmed: (WalletOwner) -> Void = self.sessionChanged
    /// 身份确认后统一补做中止读取与迟到结果的执行器（FU-IOS-0712 整体重理：钱包摘要、提现、提现记录、收款账号、实名、劳务协议都接）。
    weak var resumable: IdentityResumable?

    /// 构造时（或最近一次换上身份时）那一次身份读取是否已确认（RC-02）。
    var identityKnown: Bool {
        owner.identityKnown
    }

    init(route: String, context: WalletPageContext, controller: AnyObject, setVisible: @escaping (Bool) -> Void,
         sessionChanged: @escaping (WalletOwner) -> Void, leave: @escaping () -> Void,
         screen: @escaping () -> AnyView) {
        self.route = route
        self.context = context
        self.controller = controller
        self.setVisible = setVisible
        self.sessionChanged = sessionChanged
        self.leave = leave
        self.screen = screen
    }
}

/// 页面创建、出栈、可见性与成功后的导航。
extension AppWallet {
    /// 路由目的地对应的页面（一个导航实例只建一次执行器；出栈时在同步出口作废，APP-04 第 28 条）。
    func entry(for destination: RouteDestination) -> WalletPageEntry? {
        checkSession()
        if let existing = pages[destination.id] {
            return existing
        }
        guard let route = destination.route else { return nil }
        // 执行器的固定身份与「是否已确认」出自同一次读取（RC-02）：建页期间钉住这一份快照
        let snapshot = identity.snapshot()
        guard let made = identity.pinning(snapshot, { makeEntry(route, destination) }) else { return nil }
        made.owner = owner(for: snapshot)
        pages[destination.id] = made
        let id = destination.id
        lifetimes.register(destination) { [weak self] in
            self?.pages.removeValue(forKey: id)?.leave()
            self?.visibleGen[id] = nil
            self?.lastVisible[id] = nil
        }
        lastVisible[id] = isVisible(id)
        made.setVisible(isVisible(id))
        return made
    }

    private func context(_ destination: RouteDestination) -> WalletPageContext {
        let context = WalletPageContext(texts: deps.texts, readGate: gates.read)
        let router = router
        context.onBack = { router.close(destination) }
        return context
    }

    private func makeEntry(_ route: String, _ destination: RouteDestination) -> WalletPageEntry? {
        let context = context(destination)
        switch route {
        case WalletRoutes.wallet:
            return walletEntry(destination, context)
        case WalletRoutes.withdraw:
            return withdrawEntry(destination, context)
        case WalletRoutes.withdrawRecords:
            return recordsEntry(destination, context)
        case WalletRoutes.payoutAccount:
            return payoutEntry(destination, context)
        case WalletRoutes.realName:
            return realnameEntry(destination, context)
        case WalletRoutes.laborAgreement:
            return laborEntry(destination, context)
        default:
            return nil
        }
    }

    private func walletEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        let controller = WalletController(deps: deps)
        controller.page = destination.id
        let mask = mask
        let entry = WalletPageEntry(
            route: WalletRoutes.wallet, context: context, controller: controller,
            setVisible: { [weak controller] shown in
                guard let controller else { return }
                let was = controller.visibility.visible
                controller.visibility.set(shown)
                if shown, !was {
                    controller.refresh()
                }
            },
            sessionChanged: { [weak controller] in controller?.sessionChanged($0) },
            leave: { [weak controller] in controller?.leave() },
            screen: { AnyView(WalletScreen(controller: controller, mask: mask, context: context)) }
        )
        entry.resumable = controller
        return entry
    }

    private func withdrawEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        // 固定身份与恢复的金额草稿来自同一次读取（共性第 65 条）：按这份身份的账号读草稿（账号相同才恢复，不恢复估算）
        let owner = currentOwner()
        let restored = cache.readDraft(account: owner.account, loginEpoch: owner.loginEpoch) ?? ""
        let controller = WithdrawController(deps: deps, owner: owner, restored: restored)
        controller.page = destination.id
        let gates = gates
        let entry = WalletPageEntry(
            route: WalletRoutes.withdraw, context: context, controller: controller,
            setVisible: { [weak controller] in controller?.setVisible($0) },
            sessionChanged: { [weak controller] in controller?.sessionChanged($0) },
            leave: { [weak controller] in controller?.leave() },
            screen: { AnyView(WithdrawScreen(controller: controller, gates: gates, context: context)) }
        )
        entry.resumable = controller
        // 构造时身份未确认：换上已确认身份时按它恢复金额草稿（共性第 65 条：草稿与身份同一份）
        let cache = cache
        entry.identityConfirmed = { [weak controller] owner in
            let restored = cache.readDraft(account: owner.account, loginEpoch: owner.loginEpoch) ?? ""
            controller?.identityConfirmed(owner, restored: restored)
        }
        return entry
    }

    private func recordsEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        let controller = WithdrawRecordsController(
            deps: deps, focusId: destination.params[WalletRoutes.withdrawalId]?.stringValue
        )
        controller.page = destination.id
        let sla = configText("withdraw.sla_text")
        let entry = WalletPageEntry(
            route: WalletRoutes.withdrawRecords, context: context, controller: controller,
            setVisible: { [weak controller] in controller?.setVisible($0) },
            sessionChanged: { [weak controller] in controller?.sessionChanged($0) },
            leave: { [weak controller] in controller?.leave() },
            screen: { AnyView(WithdrawRecordsScreen(controller: controller, context: context, slaText: sla)) }
        )
        entry.resumable = controller
        return entry
    }

    private func payoutEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        let controller = PayoutAccountController(deps: deps, owner: currentOwner())
        controller.page = destination.id
        let gates = gates
        let entry = WalletPageEntry(
            route: WalletRoutes.payoutAccount, context: context, controller: controller,
            setVisible: { [weak controller] in controller?.setVisible($0) },
            sessionChanged: { [weak controller] in controller?.sessionChanged($0) },
            leave: { [weak controller] in controller?.leave() },
            screen: { AnyView(PayoutAccountScreen(controller: controller, gates: gates, context: context)) }
        )
        entry.resumable = controller
        entry.identityConfirmed = { [weak controller] in controller?.identityConfirmed($0) }
        return entry
    }

    private func realnameEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        let controller = RealNameController(deps: deps)
        controller.page = destination.id
        let entry = WalletPageEntry(
            route: WalletRoutes.realName, context: context, controller: controller,
            setVisible: { [weak controller] in controller?.setVisible($0) },
            sessionChanged: { [weak controller] in controller?.sessionChanged($0) },
            leave: { [weak controller] in controller?.leave() },
            screen: { AnyView(RealNameScreen(controller: controller, context: context)) }
        )
        entry.resumable = controller
        return entry
    }

    private func laborEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        let controller = LaborAgreementController(deps: deps)
        controller.page = destination.id
        let entry = WalletPageEntry(
            route: WalletRoutes.laborAgreement, context: context, controller: controller,
            setVisible: { [weak controller] in controller?.setVisible($0) },
            sessionChanged: { [weak controller] in controller?.sessionChanged($0) },
            leave: { [weak controller] in controller?.leave() },
            screen: { AnyView(LaborAgreementScreen(controller: controller, context: context)) }
        )
        entry.resumable = controller
        return entry
    }

    // MARK: - 可见性与导航

    func isVisible(_ id: UUID) -> Bool {
        sceneActive && router.path.last?.id == id
    }

    /// Router 栈变了（@Published 在赋值前发出，`path` 是新值）：导航世代加一；每个页面按「新栈顶 + 场景在前台」更新可见性。
    /// 变得不可见在同步出口立即生效（覆盖、离开时作废导航许可，共性第 37 条）；变得可见放到下一轮主线程：`@Published` 在赋值前发出，此刻
    /// `router.path` 还是旧值，回到可见后要做的替换 / 出栈（提现成功进记录、实名 / 签署 / 保存成功出栈，共性第 41 条）按栈顶判断会落空。
    func pathChanged(_ path: [RouteDestination]) {
        navGeneration += 1
        updateVisibility(top: path.last?.id, hideOnly: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            updateVisibility(top: router.path.last?.id)
        }
    }

    func updateVisibility(top: UUID?, hideOnly: Bool = false) {
        for (id, entry) in pages {
            let shown = sceneActive && top == id
            if hideOnly, shown {
                continue
            }
            if lastVisible[id] != shown {
                lastVisible[id] = shown
                visibleGen[id, default: 0] += 1
            }
            if !shown {
                // 实名查询失败条只显示在发起页（共性第 21 条）：离开就收起
                entry.context.openError = nil
            }
            entry.setVisible(shown)
        }
    }

    /// 系统 scenePhase 的接线（CouliApp 的 onChange(of: scenePhase) 原样转入）：只有 active 算在前台；inactive（下拉通知中心、系统弹窗、
    /// 切换 App 的过渡）与 background 一样立即作废等待中的导航与浮层许可（可见世代前进；共性第 37、57、77 条，iOS R2-03）。写请求的
    /// 会话级结算（WalletSettlement）不受影响。
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            sceneChanged(active: true)
        case .inactive, .background:
            guard sceneActive else { return }
            sceneChanged(active: false)
        @unknown default:
            sceneChanged(active: false)
        }
    }

    /// 场景进出前台（回前台按页面可见性重取，进后台算被覆盖）。
    func sceneChanged(active: Bool) {
        sceneActive = active
        updateVisibility(top: router.path.last?.id)
        if active {
            checkSession()
            let client = client
            Task { await client.restorePending() }
        }
    }

    func replace(page: UUID, route: String, params: [String: String]) -> Bool {
        #if DEBUG
        DebugWalletLog.route(route, params: params)
        #endif
        guard router.path.last?.id == page else { return false }
        router.path.removeLast()
        router.open(RouteRequest(route: route, values: params.mapValues { .string($0) }, from: .inApp))
        return true
    }

    func close(page: UUID) -> Bool {
        guard router.path.last?.id == page else { return false }
        router.path.removeLast()
        return true
    }

    func payoutSaved(page: UUID) -> Bool {
        let path = router.path
        guard path.last?.id == page, path.count >= 2, path[path.count - 2].route == WalletRoutes.withdraw else {
            return false
        }
        router.path.removeLast()
        return true
    }
}
