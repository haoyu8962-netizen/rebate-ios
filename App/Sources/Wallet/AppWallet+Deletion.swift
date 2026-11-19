import CouliNetwork
import Foundation
import Me
import MeCore
import Router
import SwiftUI
import Wallet
import WalletCore

/// 注销页（APP-13a-1）的 App 接线：页面放在钱包的页面表里（与提现、收款账号共用 WalletDeps：未决键、二次验证、token 缓存、发码槽位、
/// 共享结算），页面本身在 Features/Me（执行器在 MeCore）。
/// - 固定身份 = WalletOwner + 会话作用域 + 入口来源，构造时一次取得；会话换代（登录、退出、换账号、撤回同意、切环境）随钱包页面同步重建；
///   作用域变化（受限 → full）在会话同步出口按新作用域重建，并清空内存 step-up token（brief 第 15 行）；
/// - 入口来源不走路由参数（DeleteAccount 丢参）：从强更页进入看目的地标记，其余按导航栈下面一层交接一次（共性第 4 条）；
/// - 入口仍被 EntryGuard 过渡守卫挡着（DeleteAccount since.ios=null，D10-1562）：这里只登记页面，不改守卫。
extension AppWallet: DeleteAccountPorts {
    static let settingsRoute = "Settings"
    static let riskSources: Set<String> = ["RiskNotice", "Appeal"]

    /// 此刻的会话作用域（只给注销页比较用；没有会话或读不出为空串，按 full 对待）。
    func sessionScope() -> String {
        client.isolatedSessionScope ?? ""
    }

    func deletionScopeNow() -> String {
        DeletionScope.normalized(client.isolatedSessionScope)
    }

    func open(_ route: String, from page: UUID) {
        open(route, params: [:], from: page)
    }

    func contactService() {
        contactService(from: DeleteAccountController.route)
    }

    /// 回到强更页：只在本页仍是栈顶时，弹到栈里最近的 ForceUpdate（强更页留在栈底，03 §4.1）；随后重取标签。
    func returnToForceUpdate(page: UUID) {
        forceUpdateDeletion.reload()
        guard router.path.last?.id == page else { return }
        if let index = router.path.lastIndex(where: { $0.route == RoutePolicy.forceUpdate }) {
            router.path.removeSubrange((index + 1)...)
        } else {
            router.path.removeLast()
        }
    }

    /// 回到 Settings 的唯一导航实例（只在本页仍是栈顶、下面紧挨着 Settings 时；APP-09 第 50 条），在那里轻提示。
    func returnToSettings(page: UUID) -> Bool {
        let path = router.path
        guard path.last?.id == page, path.count >= 2, path[path.count - 2].route == Self.settingsRoute else {
            return false
        }
        let settings = path[path.count - 2].id
        router.path.removeLast()
        settingsDeletionToast(settings)
        return true
    }

    func deletionChanged(_ owner: WalletOwner) {
        guard isCurrent(owner) else { return }
        forceUpdateDeletion.reload()
    }

    // MARK: - 页面

    /// 入口来源（只交接一次：构造执行器时定下，之后重建沿用）。
    func deletionSource(_ destination: RouteDestination) -> DeletionSource {
        if destination.fromForceUpdatePage {
            return .forceUpdate
        }
        let path = router.path
        guard let index = path.firstIndex(where: { $0.id == destination.id }), index > 0 else { return .other }
        let below = path[index - 1].route ?? ""
        if below == Self.settingsRoute {
            return .settings
        }
        return Self.riskSources.contains(below) ? .riskNotice : .other
    }

    func deletionEntry(_ destination: RouteDestination, _ context: WalletPageContext) -> WalletPageEntry {
        let source = deletionSource(destination)
        let page = destination.id
        let deps: WalletDeps = deps
        let make: (WalletOwner) -> DeleteAccountController = { [unowned self] owner in
            DeleteAccountController(
                deps: deps, identity: DeletionIdentity(owner: owner, scope: deletionScopeNow(), source: source),
                page: page, ports: self
            )
        }
        let host = MePageHost(make(currentOwner()))
        let texts = AccountDraftTexts()
        let gates = gates
        // 弱引用：页面表持有 entry，entry.sessionChanged 持有 rebuild；这里强持有会成环，出栈后 entry / host / 执行器都放不掉
        weak var entryRef: WalletPageEntry?
        // 整页按新身份重建（共性第 15、36 条）：同步作废旧执行器（读请求、面板、确认框、勾选），换上新执行器并重读
        let rebuild: (WalletOwner) -> Void = { [weak host] owner in
            guard let host else { return }
            let wasVisible = host.controller.flow.visibility.visible
            host.controller.leave()
            host.replace(make(owner))
            host.controller.setVisible(wasVisible)
            host.controller.start()
            entryRef?.resumable = host.controller
        }
        let entry = WalletPageEntry(
            route: DeleteAccountController.route, context: context, controller: host,
            setVisible: { [weak host] in host?.controller.setVisible($0) },
            sessionChanged: rebuild,
            leave: { [weak host] in host?.controller.leave() },
            screen: {
                AnyView(DeleteAccountRouteContent(
                    host: host, texts: texts, smsGate: gates.sms, verifyGate: gates.verify
                ))
            }
        )
        entryRef = entry
        entry.resumable = host.controller
        // 作用域核对用会话同步出口那一次读取（不另读令牌存储）
        entry.scopeCheck = { [weak host, unowned self] scope in
            guard let host, host.controller.identity.scope != scope else { return }
            rebuild(currentOwner())
        }
        // 起点：没在跟踪作用域时，以本页固定身份的作用域（构造时那一次读取）为起点，保证建页后、下一次同步前发生的受限 → full 也能清 token
        if lastDeletionScope == nil {
            lastDeletionScope = host.controller.identity.scope
        }
        return entry
    }

    /// 会话同步出口（`checkSession` 末尾）：作用域变了就清空内存 step-up token（brief 第 15 行；无注销页时
    /// full → deletion_only 不跟踪、不清，D10-2136），栈里的注销页按新作用域重建；
    /// 强更页标签按此刻会话重取。
    /// 只在需要时读作用域（读作用域要读一次令牌存储 / 钥匙串；`checkSession` 是所有钱包页的高频路径，`entry(for:)` 的建页快照也依赖读取
    /// 次数不变）。需要 = 页面表里有注销页，或上次看到的是受限作用域（deletion_only）：
    /// - 受限会话的 step-up token 只可能由注销页的二次验证签发（StepUpTokenCache 没有只读的判空接口、且在资金守卫锁定文件里，不从外面
    ///   判空），有注销页就一直跟踪，注销页出栈后只要上次仍是受限就继续跟踪，直到看到 full / 无会话、清过 token 为止；
    /// - 不需要时不读，并把 `lastDeletionScope` 置 nil：下次重新需要时不拿停止跟踪前的陈旧值比较（避免误清 / 漏清），起点由注销页建页时
    ///   的固定作用域补上（`deletionEntry`）。
    func resyncDeletionScope() {
        let deletionPages = pages.values.compactMap(\.scopeCheck)
        if deletionPages.isEmpty, lastDeletionScope != DeletionScope.deletionOnly {
            lastDeletionScope = nil
        } else {
            let raw = client.isolatedSessionScope
            let scope = raw.map { DeletionScope.normalized($0) }
            if let last = lastDeletionScope, last != scope {
                deps.tokens.onSessionChanged()
            }
            lastDeletionScope = scope
            let pageScope = DeletionScope.normalized(raw)
            for check in deletionPages {
                check(pageScope)
            }
        }
        // 自身只在强更页显示时才读身份（`showing` 先判），不显示时零读取
        forceUpdateDeletion.sessionMaybeChanged()
    }
}

/// 注销页的路由视图：一个导航实例只建一次执行器（AppWallet 按 RouteDestination.id 缓存，出栈时作废）。系统导航栏。
struct DeleteAccountRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var wallet: AppWallet

    var body: some View {
        Group {
            if let entry = wallet.entry(for: destination) {
                entry.screen()
            }
        }
        .debugRouteMarker(destination)
    }
}

/// 注销页 + 二次验证面板（面板在 Features/Wallet，Feature 之间不依赖，由 App 套上；面板随执行器重建换成新的）。
struct DeleteAccountRouteContent: View {
    @ObservedObject var host: MePageHost<DeleteAccountController>
    let texts: AccountDraftTexts
    @ObservedObject var smsGate: RetryAfterGate
    @ObservedObject var verifyGate: RetryAfterGate
    /// 【申请注销】的读屏焦点：半屏关闭后回到触发控件（同提现页、收款账号页的 restoreFocus，A11yFocusStepUp）。
    @AccessibilityFocusState private var applyFocused: Bool

    var body: some View {
        DeleteAccountScreen(host: host, texts: texts, applyFocus: $applyFocused)
            .walletStepUpSheet(
                host.controller.flow.stepUp, texts: texts, smsBlocked: smsGate.blocked,
                verifyBlocked: verifyGate.blocked, restoreFocus: $applyFocused
            )
    }
}

/// 强更页次要入口的标签（03 §4.1，brief §2.8）：已登录（含 deletion_only）时取一次 getDeletion，冷静期且 can_cancel=true 显示「撤销注销」，
/// 其余、游客、读取失败、限流期间都显示「注销账号」。读取与注销页共用 `gates.deletionRead` 的发送前检查与 42901 结算（共性第 32 条），
/// 结果按发起时的固定身份与读取序号采用。
@MainActor
final class ForceUpdateDeletionLabel: ObservableObject {
    static let deleteKey = "app_update.delete_account"
    static let cancelKey = "app_update.cancel_deletion"

    @Published private(set) var key = ForceUpdateDeletionLabel.deleteKey
    private unowned let wallet: AppWallet
    private var serial = 0
    private var flag: RequestFlag?
    private var ownerKey: String?

    /// 强更页在显示（只在这时读；不在强更时不为标签发请求）。
    private var showing = false

    init(wallet: AppWallet) {
        self.wallet = wallet
    }

    func appeared() {
        showing = true
        reload()
    }

    func disappeared() {
        showing = false
        serial += 1
        flag?.invalidate()
        flag = nil
    }

    /// 会话可能变了：固定身份变了才重取（同一会话不重复读）。
    func sessionMaybeChanged() {
        guard showing, wallet.currentOwner().key != ownerKey else { return }
        reload()
    }

    func reload() {
        guard showing else { return }
        serial += 1
        let ticket = serial
        flag?.invalidate()
        flag = nil
        let owner = wallet.currentOwner()
        // 发起时的完整身份：账号 + 会话世代 + 持久化登录世代（WalletOwner）+ 作用域（共性第 49 条）
        let scope = wallet.deletionScopeNow()
        ownerKey = owner.key
        guard owner.account != nil, owner.identityKnown else {
            key = Self.deleteKey
            return
        }
        let gate = wallet.gates.deletionRead
        guard !gate.active else {
            key = Self.deleteKey
            return
        }
        let request = RequestFlag()
        flag = request
        let probe = gate.probe()
        let api = wallet.api
        Task { @MainActor [weak self] in
            let result = await api.send(
                ApiCall(operationId: "getDeletion"), isValid: { request.isValid }, sendAllowed: probe.allowed,
                expected: owner.request
            )
            // 写闸门、改标签之前复核完整身份：同世代作用域刷新后迟到的旧 42901 不写进新作用域的闸门（共性第 49 条）
            guard let self, request.isValid, ticket == serial, wallet.isCurrent(owner),
                  wallet.deletionScopeNow() == scope
            else { return }
            flag = nil
            let millis = WalletErrors.disableMillis(result)
            if millis > 0 {
                gate.start(millis)
            }
            guard case let .success(data, _, _) = result, let deletion = DeletionJson.read(data).deletion else {
                key = Self.deleteKey
                return
            }
            key = deletion.status == Deletion.cooling && deletion.canCancel ? Self.cancelKey : Self.deleteKey
        }
    }
}
