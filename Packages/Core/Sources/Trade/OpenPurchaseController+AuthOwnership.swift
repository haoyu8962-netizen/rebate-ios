import CouliNetwork
import Foundation

// MARK: - 授权归属与固定来源

extension OpenPurchaseController {
    /// 授权归属仍有效（共性第 20 条）：页面没离开、世代没变、授权上下文仍是它、购买尝试仍是当前的。
    func authLive(_ context: AuthContext, _ gen: Int) -> Bool {
        !left && gen == authGen && authContext === context && current === context.attempt
    }

    /// 授权归属仍有效且来源仍是拿到授权码时固定的那一份（iOS RC-06）：来源变了就作废这次授权（`dropStaleAuth`）。
    func authCurrent(_ context: AuthContext, _ gen: Int) -> Bool {
        guard authLive(context, gen) else { return false }
        guard originCurrent(context.origin) else {
            dropStaleAuth(context)
            return false
        }
        return true
    }

    /// 授权上下文的来源已不是当前（换账号、切环境、换执行器；iOS RC-06）：世代加 1 作废在途授权，删本页这次尝试的待办，关弹层，
    /// 提示重新点购买取新方案；不发任何授权请求、不自动 open。
    func dropStaleAuth(_ context: AuthContext) {
        authGen += 1
        if authContext === context {
            authContext = nil
        }
        if authResume === context {
            authResume = nil
        }
        awaitingAuthReturn = false
        calls.cancel(group: Self.authGroup)
        clearOwnPending(context.attempt)
        hideDialog()
        ready = nil
        revokePermit()
        toast(PurchaseTextKeys.jumpExpired)
    }

    /// 作废旧的授权归属（共性第 20 条）：新的 open 请求发出前调用。世代加 1（在途查询、授权流程的结果与延迟恢复一律丢弃），清掉授权
    /// 上下文、「等授权回来」，以及属于旧授权上下文的授权待办（之后不会被旧查询自动执行）；先作废归属再取消在途授权请求。
    func invalidateAuth() {
        authGen += 1
        let old = authContext
        authContext = nil
        awaitingAuthReturn = false
        calls.cancel(group: Self.authGroup)
        if let old {
            dropAuthPending(old)
        }
        if let resume = authResume {
            dropAuthPending(resume)
        }
        authResume = nil
    }
}

// MARK: - 弹窗上的重试与无返利购买（先核对弹窗的固定来源，APP-08 iOS NEW-02）

public extension OpenPurchaseController {
    /// 二选一的【重试】、50303 的【重试】：一次新的点击（新键）；二选一里的【重试】是用户主动授权，不受自动弹出次数限制（共性第 10 条）。
    /// 先核对弹窗的固定来源与尝试（APP-08 iOS NEW-02）：不一致（换账号、切环境、换执行器、已有新尝试）即作废弹窗，不清上下文、不发请求，
    /// 要求用户重新点购买；一致才清上下文，按产生弹窗的那次尝试的卡与固定来源发起新尝试。
    /// `ticket`：页面渲染时捕获的弹窗票据（r3f NEW-02）。票据不是当前弹窗（旧回调）时什么都不做、不碰新弹窗；是当前弹窗但来源 / 尝试
    /// 已变时作废它。
    func retryPurchase(_ ticket: PurchaseDialogTicket?) {
        let dialog = state.dialog
        let owned: DialogOrigin
        switch checkDialog(ticket) {
        case .foreign:
            return
        case .stale:
            dropStaleDialog()
            return
        case let .owned(value):
            owned = value
        }
        hideDialog()
        authContext = nil
        let target = latestCard(owned.attempt)
        var userRetry = false
        if case .authDeclined = dialog {
            userRetry = true
        }
        buy(target, spm: spm, userAuthRetry: userRetry, source: owned.source)
    }

    /// 【仍去购买（无返利）】：no_rebate=true 的新请求（BR-ID-18、BR-PRICE-08）。
    /// 先核对弹窗的固定来源与尝试（APP-08 iOS NEW-02），不一致即作废弹窗（不清上下文、零请求）；原因只取自产生弹窗的同一来源。
    /// `ticket`：同 `retryPurchase(_:)`（r3f NEW-02）。
    func buyWithoutRebate(_ ticket: PurchaseDialogTicket?) {
        let owned: DialogOrigin
        switch checkDialog(ticket) {
        case .foreign:
            return
        case .stale:
            dropStaleDialog()
            return
        case let .owned(value):
            owned = value
        }
        hideDialog()
        let reason = owned.noRebateReason
        authContext = nil
        guard !left, !busy, !gate.active else { return }
        let target = latestCard(owned.attempt)
        // 无返利购买同样先核对平台状态与可购状态（共性第 27 条；send 里还会再核对一次）
        guard purchasable(target, notify: true) else { return }
        startClick(
            target, key: keys.start(), noRebate: true, noRebateReason: reason, userAuthRetry: false,
            source: owned.source
        )
    }
}
