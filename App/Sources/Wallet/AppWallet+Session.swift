import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore
#if DEBUG
import os
#endif

/// 用户点的、要先查实名状态的一次打开（`origin` 发起页的导航实例，`nav` 点击时的导航世代，`visible` 点击时发起页的可见世代，`covered`
/// 点击时发起页的覆盖世代）。
struct WalletOpenIntent {
    let route: String
    let params: [String: String]
    let origin: UUID?
    let nav: Int
    let visible: Int
    let covered: Int
}

/// 会话换代、撤回 / 切环境、实名状态与带实名前置的打开。
extension AppWallet {
    /// 换代判据（测试核对用的视图；判定只在 `SessionReconciler`）："" = 还没有已确认判据（启动时身份暂时未知，RC-04）。
    var sessionKey: String {
        guard let mark = reconciler.confirmed else { return "" }
        return "\(mark.account ?? "-")#\(mark.generation)#\(mark.epoch)#\(mark.loginEpoch ?? "-")"
    }

    /// 会话可能变了（AppLogin 的会话版本变化、页面打开、回前台、用户重试）。一次快照，结论只由 `SessionReconciler` 给出（与订单同一套）：
    /// - 待清理与身份无关，先完成（R3-02）；
    /// - 暂时未知：世代没变什么都不做（不删、不写、不更新判据，RC-01）；世代变了只作废内存（共享状态清空、各页换成未确认身份），不对账；
    /// - 已确认且相同：换上未知期间构造的页面（RC-02 / G54），各页统一补做中止的读取与迟到结果（RC-02 / G53 / RC-05）；
    /// - 启动态落定：按本次身份对账后同上；
    /// - 已知换代（含首次确认没有会话 RC-04、同账号换登录世代 R3-03）：共享状态清空、按本次身份对账（不另读，RC-03）、各页换上新身份重取。
    func checkSession() {
        // 作用域变化不改会话世代（刷新拿到 full）：在同一个同步出口另核对（APP-13a-1）
        defer { resyncDeletionScope() }
        let snapshot = identity.snapshot()
        cache.completePendingClear()
        switch reconciler.observe(snapshot) {
        case .deferred:
            return
        case .invalidated:
            rebuild(snapshot, reconcile: false)
        case .same:
            identityConfirmed(snapshot)
        case .settled:
            reconcileCache(snapshot)
            identityConfirmed(snapshot)
        case .changed:
            rebuild(snapshot)
        }
    }

    /// 身份已确认（判据相同或启动态落定）：未知期间构造（或没有账号时构造、此刻已有账号）的页面换上这一次的身份并重取（不重置禁用期、
    /// 发码倒计时、实名结论，G49）；之后各页统一补做因身份暂时未知中止的读取与迟到结果。
    func identityConfirmed(_ snapshot: IdentitySnapshot) {
        // 会话级共享结算先补（禁用期按原截止、token、钱包刷新；RW-02），页面再采用各自留着的结果
        deps.settlement.resumeAfterIdentityConfirmed()
        let owner = owner(for: snapshot)
        let entries = Array(pages.values)
        for entry in entries where !entry.owner.identityKnown || (entry.owner.account == nil && owner.account != nil) {
            entry.context.openError = nil
            entry.owner = owner
            entry.identityConfirmed(owner)
        }
        for entry in entries {
            entry.resumable?.resumeAfterIdentityConfirmed()
        }
    }

    /// 撤回同意 / 切换环境（WalletCacheCleaner 删了缓存，删除失败时同样回调）：内存里的钱包显示全部作废，各页按此刻快照重建
    /// （判据随之更新；未知时只记世代，确认后按换代处理）。
    func cacheCleared() {
        clearedCount += 1
        let snapshot = identity.snapshot()
        reconciler.adopt(snapshot)
        rebuild(snapshot)
    }

    /// 同步出口：共享状态清空，各页清掉旧会话的数据并换上同一次读取的新身份（共性第 13、65 条）。`reconcile` = false：身份暂时未知而世代
    /// 已变，只作废内存，不对账。
    private func rebuild(_ snapshot: IdentitySnapshot, reconcile: Bool = true) {
        deps.settlement.sessionChanged()
        gates.reset()
        deps.tokens.onSessionChanged()
        deps.sms.clear()
        realnameState = nil
        realnameFlag?.invalidate()
        realnameFlag = nil
        openingEnded()
        let owner = owner(for: snapshot)
        if reconcile {
            reconcileCache(snapshot)
        }
        for entry in pages.values {
            entry.context.openError = nil
            entry.owner = owner
            entry.sessionChanged(owner)
        }
        if owner.account != nil {
            let client = client
            Task { await client.restorePending() }
        }
    }

    /// 守卫用的实名状态（当前会话查清了且已实名）。
    func realnameVerified() -> Bool {
        guard let state = realnameState else { return false }
        return state.key == currentOwner().key && state.verified
    }

    /// 经 Router 以 App 内来源打开。要实名的资金页（Withdraw、PayoutAccount、LaborAgreement）在本会话还没查过实名状态时，先取 GET /v1/me
    /// 再打开（守卫按查到的状态放行或去 RealName）。
    func open(_ route: String, params: [String: String], from page: UUID?) {
        #if DEBUG
        // APP-09v-a：钱包视觉 UI 测试的只读出口记录（交给 Router 之前记；只在注入生效时记录）
        DebugWalletLog.route(route, params: params)
        // FU-IOS-WITHDRAW-ENTRY-SILENT 实跑定位（D10-2670）：控制器已放行、App 侧开始打开（只记路由名）
        Logger(subsystem: "com.couli.app", category: "wallet.entry").notice("open route: \(route, privacy: .public)")
        #endif
        let owner = currentOwner()
        if Routes.all[route]?.auth == "realname", realnameState?.key != owner.key, owner.account != nil {
            if let page {
                pages[page]?.context.openError = nil
            }
            let intent = WalletOpenIntent(
                route: route, params: params, origin: page, nav: navGeneration,
                visible: page.flatMap { visibleGen[$0] } ?? 0, covered: page.flatMap { coveredGen[$0] } ?? 0
            )
            refreshRealname(intent)
            return
        }
        router.open(RouteRequest(route: route, values: params.mapValues { .string($0) }, from: .inApp))
    }

    /// 取 GET /v1/me 的 realname_status（只认 verified）。共享请求世代（共性第 9 条）：只接收最新一次查询的结论，换代与新查询都作废旧请求。
    /// 带点击的查询在途时发起页的【提现】显示进行中（`isOpeningWithdraw`），查询结束（任一出口）收起。
    func refreshRealname(_ intent: WalletOpenIntent?) {
        let owner = currentOwner()
        guard owner.account != nil else {
            if intent != nil {
                silentExit("query skipped: no account")
            }
            return
        }
        realnameSerial += 1
        let serial = realnameSerial
        realnameFlag?.invalidate()
        let flag = RequestFlag()
        realnameFlag = flag
        // 新查询作废旧查询：旧查询的进行中一并收起（同一时刻只有最新一次查询可能在途）
        openingEnded()
        // getMe 的读取截止时间三处共用（APP-12 共性第 32、33 条：「我的」、钱包实名查询、桥 auth.getUser）：任一处的 42901 都拦住这里
        if gates.read.active || meReadGate?.active == true {
            realnameFailed(WalletError(.gated, "error.42901"), intent)
            return
        }
        openingStarted(intent)
        let probe = gates.read.probe(extra: meReadGate?.sendAllowed)
        let client = client
        Task { @MainActor [weak self] in
            let result = await client.send(
                ApiCall(operationId: "getMe"), isValid: { flag.isValid }, sendAllowed: probe.allowed,
                expected: owner.request
            )
            guard let self else { return }
            // 只有最新一次查询收起进行中（新查询已接手时不动它的进行中）
            if serial == realnameSerial {
                openingEnded()
            }
            // 真作废（新查询接手、会话换代 / 撤回 / 切环境、身份变了）：静默
            guard flag.isValid, serial == realnameSerial else {
                if intent != nil {
                    silentExit(serial == realnameSerial ? "query voided: session rebuilt" : "query voided: superseded")
                }
                return
            }
            guard isCurrent(owner) else {
                if intent != nil {
                    silentExit("query voided: identity changed")
                }
                return
            }
            realnameArrived(result, owner: owner, probe: probe, intent: intent)
        }
    }

    private func realnameArrived(_ result: ApiResult, owner: WalletOwner, probe: SendProbe, intent: WalletOpenIntent?) {
        if case let .success(data, _, _) = result {
            let status = (WalletJSON.parse(data) as? [String: Any])?["realname_status"] as? String
            realnameState = (owner.key, status == "verified")
            if let intent {
                continueOpen(intent)
            }
            return
        }
        let error = WalletErrors.of(result, probe: probe)
        if error.kind == .retryAfter {
            gates.read.start(error.disableMillis)
            meReadGate?.start(error.disableMillis)
        }
        realnameFailed(error, intent, sessionEnded: Self.sessionEnded(result))
    }

    /// 查询成功后接着打开（共性第 31、57 条）：
    /// - 许可仍在 → 经 Router 打开（守卫按刚查到的状态放行进 Withdraw，或去 RealName 并登记 pending_action）；
    /// - 许可只因场景切换作废（点击之后 inactive / 后台过，发起页一直在栈顶、没被盖过）而此刻在前台 → 不替用户跳转，也不静默：发起页
    ///   显示打开失败条 +【重试】（实名状态已查清，【重试】同步打开）；
    /// - 发起页被盖过（含已退回）、已离开、此刻不在前台 → 静默。
    private func continueOpen(_ intent: WalletOpenIntent) {
        if mayNavigate(intent) {
            router.open(RouteRequest(
                route: intent.route, values: intent.params.mapValues { .string($0) }, from: .inApp
            ))
            return
        }
        guard sceneActive else {
            silentExit("navigation voided: not in foreground")
            return
        }
        guard let entry = originEntry(intent, "navigation voided") else { return }
        errorSerial += 1
        showOpenError(Notice(Self.openVoidedKey, id: errorSerial), intent, entry)
    }

    /// 读取失败（共性第 3、21 条）：不当成未实名继续导航；发起页一直在栈顶就显示在发起页（5xxxx 带 trace6）并可【重试】——本地取消类结果
    /// （会话没换代、请求没作废）同样提示，不静默。静默的只有：没有点击（实名成功后的复查）、强更接管、会话已结束、发起页被盖过或已离开。
    private func realnameFailed(_ error: WalletError, _ intent: WalletOpenIntent?, sessionEnded: Bool = false) {
        guard let intent else { return }
        guard error.kind != .forceUpdate else {
            silentExit("query failed: force update takes over")
            return
        }
        guard !sessionEnded else {
            silentExit("query cancelled: session ended")
            return
        }
        guard let entry = originEntry(intent, "query failed") else { return }
        errorSerial += 1
        let notice = switch error.kind {
        case .gated: Notice("error.42901", id: errorSerial)
        case .cancelled: Notice(Self.openVoidedKey, id: errorSerial)
        default: error.notice(id: errorSerial)
        }
        showOpenError(notice, intent, entry)
    }

    /// 发起页一直在栈顶且页面还在时的那一页；否则（被盖过、已离开、没有发起页）记一条静默出口、返回 nil。
    private func originEntry(_ intent: WalletOpenIntent, _ stage: String) -> WalletPageEntry? {
        guard let origin = intent.origin else {
            silentExit("\(stage): no origin page")
            return nil
        }
        guard stillOnOrigin(intent) else {
            silentExit("\(stage): origin covered (or was) or left")
            return nil
        }
        guard let entry = pages[origin] else {
            silentExit("\(stage): origin page gone")
            return nil
        }
        return entry
    }

    /// 发起页的打开失败条 +【重试】【关闭】（【重试】只在发起页仍在栈顶、不在读禁用期时重新打开）。
    private func showOpenError(_ notice: Notice, _ intent: WalletOpenIntent, _ entry: WalletPageEntry) {
        guard let origin = intent.origin else { return }
        entry.context.openError = notice
        entry.context.retryOpen = { [weak self] in
            guard let self else { return }
            guard !gates.read.active, router.path.last?.id == origin else {
                silentExit("retry refused: read gate active or origin not on top")
                return
            }
            entry.context.openError = nil
            open(intent.route, params: intent.params, from: origin)
        }
        entry.context.dismissOpenError = { [weak entry] in entry?.context.openError = nil }
    }

    /// 点击之后发起页一直在栈顶：此刻在栈顶、覆盖世代未变（栈每次发值时它都在栈顶；读取失败与许可作废的提示据此显示在发起页）。
    /// 有发起页时不看导航世代：栈的任何一次发值（含同值赋值）都会推进它，而发起页其实一直在栈顶、用户什么也没看到。没有发起页时仍按导航世代。
    func stillOnOrigin(_ intent: WalletOpenIntent) -> Bool {
        guard let origin = intent.origin else { return navGeneration == intent.nav }
        return router.path.last?.id == origin && (coveredGen[origin] ?? 0) == intent.covered
    }

    /// 查询之后的导航许可（共性第 31、37、57 条）：同一发起实例一直在栈顶、点击之后可见世代未变（没被覆盖、没退到后台），且此刻在前台。
    func mayNavigate(_ intent: WalletOpenIntent) -> Bool {
        guard stillOnOrigin(intent), sceneActive else { return false }
        guard let origin = intent.origin else { return true }
        return (visibleGen[origin] ?? 0) == intent.visible
    }

    /// 许可作废、本地取消时发起页上的提示文案键：BR-TEXT-14 表 C 通用状态键（DSX-01 登记、三端共用；D10-2659 不借 error.10401——
    /// 那是签名 / 防重放失效且要上报 10401 埋点）。出错卡对它另显标题 state.load_failed.title、【重试】用 state.retry。
    static let openVoidedKey = WalletOpenErrorKeys.loadFailedDesc

    /// 网络层判为会话已换代 / 已清的本地结果（真换代：静默）。
    private static func sessionEnded(_ result: ApiResult) -> Bool {
        switch result {
        case let .localReject(reason):
            [LocalRejectReason.sessionChanged, LocalRejectReason.accountMismatch].contains(reason)
        case .sessionCleared, .sessionNotSaved:
            true
        default:
            false
        }
    }

    /// 带点击的【提现】查询发出：发起页的【提现】显示进行中。
    private func openingStarted(_ intent: WalletOpenIntent?) {
        guard let intent, intent.route == WalletRoutes.withdraw, let origin = intent.origin else { return }
        pages[origin]?.context.isOpeningWithdraw = true
    }

    /// 查询结束、被新查询接手或会话换代：收起进行中。
    private func openingEnded() {
        for entry in pages.values where entry.context.isOpeningWithdraw {
            entry.context.isOpeningWithdraw = false
        }
    }

    /// 实名前置打开保留的静默出口（FU-IOS-WITHDRAW-ENTRY-SILENT §1.3）：只在 Debug / Staging 记一条原因，不写金额、身份、号码。
    private func silentExit(_ reason: String) {
        #if DEBUG
        WalletEntryLog.silent(reason)
        #endif
    }
}

#if DEBUG
/// 钱包入口静默出口的日志（只在 Debug / Staging 编译；staging 实跑看命中哪个出口）。
enum WalletEntryLog {
    static func silent(_ reason: String) {
        Logger(subsystem: "com.couli.app", category: "wallet.entry").notice("silent exit: \(reason, privacy: .public)")
    }
}
#endif
