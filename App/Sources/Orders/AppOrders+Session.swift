import CouliNetwork
import Foundation
import OrderCore
import Orders

/// 订单的会话核对（FU-IOS-0712 整体重理）：一次身份快照 → `SessionReconciler` 给出结论 → 按结论清显示 / 对账 / 换上未知期页面 / 统一补做。
extension AppOrders {
    /// 换代判据（测试核对用的视图；判定只在 `SessionReconciler`）：账号、会话世代、持久化登录世代与是否已确认过。
    struct SessionKey: Equatable {
        let account: String?
        let generation: UInt64
        var loginEpoch: String?
        var known = true
    }

    var sessionKey: SessionKey {
        let confirmed = reconciler.confirmed
        return SessionKey(
            account: confirmed?.account, generation: confirmed?.generation ?? reconciler.boundGeneration,
            loginEpoch: confirmed?.loginEpoch, known: confirmed != nil
        )
    }

    /// 按一次快照构造的固定身份（列表 / 详情 / 待跟单执行器构造时取它）。
    func owner(for snapshot: IdentitySnapshot) -> OrderOwner {
        OrderOwner(
            account: snapshot.account,
            key: AppIdentity.ownerKey(account: snapshot.account, snapshot, cleared: clearedCount),
            member: snapshot.member, request: snapshot.request, loginEpoch: snapshot.loginEpoch,
            identityKnown: snapshot.known
        )
    }

    /// 固定身份与此刻身份的核对（一次读取；口径见 `AppIdentity.check`）。
    func check(_ owner: OrderOwner) -> IdentityCheck {
        let now = identity.snapshot()
        let result = AppIdentity.check(
            matchesNow: self.owner(for: now) == owner,
            fixed: FixedIdentity(key: owner.key, account: owner.account, known: owner.identityKnown),
            now: now, cleared: clearedCount
        )
        if result == .current {
            identityCheckPassed?()
        }
        return result
    }

    /// 页面在身份暂时未知时被用户点了【重试】：立即核对一次。
    func recheckIdentity() {
        checkSession()
    }

    /// 会话可能变了（AppLogin 的会话版本变化、页面打开、回前台、进后台、用户重试）。一次快照，结论只由 `SessionReconciler` 给出：
    /// - 待清理与身份无关，先完成（R3-02）；
    /// - 暂时未知：世代没变什么都不做；世代变了只作废内存里的显示（不删恢复记录、不对账、不更新判据）；
    /// - 已确认且相同：换上未知期间构造的页面，统一补做中止的读取（判据相同也补，RC-02 / RC-05 / G54 同口径）；
    /// - 启动态落定（首次确认有账号等）：按本次身份对账，不删恢复记录（F-X-19），再换上页面、补做；
    /// - 已知换代（含首次确认没有会话、同账号换登录世代）：清显示、删恢复记录、按本次身份对账（不另读，RC-03），Tab 根重建。
    func checkSession() {
        let snapshot = identity.snapshot()
        _ = cache.completePendingClear()
        switch reconciler.observe(snapshot) {
        case .deferred:
            return
        case .invalidated:
            clearDisplays(eraseRecord: false)
            rebuildRoot()
        case .same:
            identityConfirmed(snapshot)
        case .settled:
            reconcileCache(snapshot)
            identityConfirmed(snapshot)
        case .changed:
            sessionChanged(snapshot)
        }
    }

    /// 身份已确认（判据相同或启动态落定）：未知期间构造（或没有账号时构造、此刻已有账号）的列表页换掉（不删记录，新页面按已确认身份
    /// 决策并恢复）；详情换上这一次的身份；各页补做因身份暂时未知中止的读取。
    func identityConfirmed(_ snapshot: IdentitySnapshot) {
        if let page = listConfig, unbound(page.controller.owner, now: snapshot) {
            if page.controller.userTookOver {
                let taken = page.controller.snapshot
                takeover = (taken.query.conditions, taken.searchText)
            }
            page.invalidate()
            page.controller.leave()
            page.pendingTrack?.discard()
            listConfig = nil
            rebuildRoot()
        }
        let confirmed = owner(for: snapshot)
        let live = details.values.compactMap(\.controller)
        for controller in live {
            controller.identityConfirmed(confirmed)
        }
        listConfig?.controller.resumeAfterIdentityConfirmed()
        for controller in live {
            controller.resumeAfterIdentityConfirmed()
        }
    }

    /// 页面固定身份还没绑定到已确认身份：构造时身份未确认，或构造时没有账号而此刻已有。
    func unbound(_ owner: OrderOwner, now: IdentitySnapshot) -> Bool {
        !owner.identityKnown || (owner.account == nil && now.account != nil)
    }

    /// 缓存归属对账（启动、启动态落定、换代）：只用调用方这一次快照（不另读，RC-03）。待清理先完成（R3-02）；身份暂时未知延后（R2-01）；
    /// 确认没有会话按无归属删除；缺登录世代的旧会话判断不了分区，不删也不读写（F-X-21）。
    func reconcileCache(_ snapshot: IdentitySnapshot) {
        _ = cache.completePendingClear()
        guard snapshot.known else { return }
        cache.reconcileOwner(account: snapshot.account, loginEpoch: snapshot.loginEpoch)
    }
}
