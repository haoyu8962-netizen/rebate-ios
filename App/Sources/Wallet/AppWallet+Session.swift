import CouliNetwork
import Foundation
import Generated
import Router
import Wallet
import WalletCore

/// 用户点的、要先查实名状态的一次打开（`origin` 发起页的导航实例，`nav` 点击时的导航世代，`visible` 点击时发起页的可见世代）。
struct WalletOpenIntent {
    let route: String
    let params: [String: String]
    let origin: UUID?
    let nav: Int
    let visible: Int
}

/// 会话换代、撤回 / 切环境、实名状态与带实名前置的打开。
extension AppWallet {
    /// 会话可能变了（AppLogin 的会话版本变化、页面打开、回前台）：账号或会话世代不同即换代。
    func currentSessionKey() -> String {
        let owner = currentOwner()
        return "\(owner.account ?? "-")#\(owner.request?.generation ?? 0)#\(owner.request?.epoch ?? 0)"
    }

    func checkSession() {
        let key = currentSessionKey()
        guard key != sessionKey else { return }
        sessionKey = key
        rebuild()
    }

    /// 撤回同意 / 切换环境（WalletCacheCleaner 删了缓存，删除失败时同样回调）：内存里的钱包显示全部作废。
    func cacheCleared() {
        clearedCount += 1
        sessionKey = currentSessionKey()
        rebuild()
    }

    /// 同步出口：共享状态清空，各页清掉旧会话的数据并换上同一次读取的新身份（共性第 13、65 条）。
    private func rebuild() {
        gates.reset()
        deps.tokens.onSessionChanged()
        deps.sms.clear()
        realnameState = nil
        realnameFlag?.invalidate()
        realnameFlag = nil
        let owner = currentOwner()
        cache.reconcileOwner(account: owner.account)
        for entry in pages.values {
            entry.context.openError = nil
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
        let owner = currentOwner()
        if Routes.all[route]?.auth == "realname", realnameState?.key != owner.key, owner.account != nil {
            if let page {
                pages[page]?.context.openError = nil
            }
            let intent = WalletOpenIntent(
                route: route, params: params, origin: page, nav: navGeneration,
                visible: page.flatMap { visibleGen[$0] } ?? 0
            )
            refreshRealname(intent)
            return
        }
        router.open(RouteRequest(route: route, values: params.mapValues { .string($0) }, from: .inApp))
    }

    /// 取 GET /v1/me 的 realname_status（只认 verified）。共享请求世代（共性第 9 条）：只接收最新一次查询的结论，换代与新查询都作废旧请求。
    func refreshRealname(_ intent: WalletOpenIntent?) {
        let owner = currentOwner()
        guard owner.account != nil else { return }
        realnameSerial += 1
        let serial = realnameSerial
        realnameFlag?.invalidate()
        let flag = RequestFlag()
        realnameFlag = flag
        // getMe 的读取截止时间三处共用（APP-12 共性第 32、33 条：「我的」、钱包实名查询、桥 auth.getUser）：任一处的 42901 都拦住这里
        if gates.read.active || meReadGate?.active == true {
            realnameFailed(WalletError(.gated, "error.42901"), intent)
            return
        }
        let probe = gates.read.probe(extra: meReadGate?.sendAllowed)
        let client = client
        Task { @MainActor [weak self] in
            let result = await client.send(
                ApiCall(operationId: "getMe"), isValid: { flag.isValid }, sendAllowed: probe.allowed,
                expected: owner.request
            )
            guard let self, flag.isValid, serial == realnameSerial, isCurrent(owner) else { return }
            realnameArrived(result, owner: owner, probe: probe, intent: intent)
        }
    }

    private func realnameArrived(_ result: ApiResult, owner: WalletOwner, probe: SendProbe, intent: WalletOpenIntent?) {
        if case let .success(data, _, _) = result {
            let status = (WalletJSON.parse(data) as? [String: Any])?["realname_status"] as? String
            realnameState = (owner.key, status == "verified")
            if let intent, mayNavigate(intent) {
                router.open(RouteRequest(
                    route: intent.route, values: intent.params.mapValues { .string($0) }, from: .inApp
                ))
            }
            return
        }
        let error = WalletErrors.of(result, probe: probe)
        if error.kind == .retryAfter {
            gates.read.start(error.disableMillis)
            meReadGate?.start(error.disableMillis)
        }
        realnameFailed(error, intent)
    }

    /// 读取失败（共性第 3、21 条）：不当成未实名继续导航；5xxxx 带 trace6 显示在发起页并可【重试】；作废的静默。
    private func realnameFailed(_ error: WalletError, _ intent: WalletOpenIntent?) {
        guard let intent, let origin = intent.origin, error.kind != .cancelled, error.kind != .forceUpdate,
              stillOnOrigin(intent), let entry = pages[origin]
        else { return }
        errorSerial += 1
        entry.context.openError = error.kind == .gated ? Notice("error.42901", id: errorSerial)
            : error.notice(id: errorSerial)
        entry.context.retryOpen = { [weak self] in
            guard let self, !gates.read.active, router.path.last?.id == origin else { return }
            entry.context.openError = nil
            open(intent.route, params: intent.params, from: origin)
        }
        entry.context.dismissOpenError = { [weak entry] in entry?.context.openError = nil }
    }

    /// 发起页仍在栈顶、点击之后导航没有变过（读取失败的提示据此显示在发起页）。
    func stillOnOrigin(_ intent: WalletOpenIntent) -> Bool {
        guard navGeneration == intent.nav else { return false }
        guard let origin = intent.origin else { return true }
        return router.path.last?.id == origin
    }

    /// 查询之后的导航许可（共性第 31、37、57 条）：同一发起实例、导航世代未变、点击之后可见世代未变（没被覆盖、没退到后台），且此刻在前台。
    func mayNavigate(_ intent: WalletOpenIntent) -> Bool {
        guard stillOnOrigin(intent), sceneActive else { return false }
        guard let origin = intent.origin else { return true }
        return (visibleGen[origin] ?? 0) == intent.visible
    }
}
