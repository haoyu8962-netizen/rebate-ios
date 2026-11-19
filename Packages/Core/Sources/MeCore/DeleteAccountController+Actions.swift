import CouliNetwork
import Foundation
import WalletCore

/// 注销页的按钮入口（回调都带渲染时的版本与固定身份，执行时只比较）。
public extension DeleteAccountController {
    // MARK: - 页面操作（回调都带渲染时的版本与固定身份）

    /// 勾选框。
    func toggleWaiver(version: Int, owner: WalletOwner) {
        guard owns(version, owner), view.waiverEnabled else { return }
        state.waiver.toggle()
    }

    /// 【申请注销】：先核对勾选与规则，再按 phone_bound 判断（false → 只提示 BR-ID-08 原句、不发请求；未知 → 先重取 getMe）。
    func apply(version: Int, owner: WalletOwner) {
        guard owns(version, owner), applyEnabled else { return }
        state.notice = nil
        state.withdrawHint = false
        switch state.phoneBound {
        case false?:
            state.notice = notice(Self.noPhoneKey)
        case nil:
            submitAfterMe = true
            loadMe()
        case true?:
            flow.submitDeletion(owner: identity.owner)
        }
    }

    /// 【确认上一次提交】。
    func confirmPending(key: String, owner: WalletOwner) {
        guard alive, owner == identity.owner, scopeHolds else { return }
        flow.confirm(key: key, owner: owner)
    }

    /// 【放弃上一次提交】：先弹二次确认（DeleteAccountPendingAbandonConfirm）。
    func askAbandon(key: String, owner: WalletOwner) {
        guard alive, owner == identity.owner, scopeHolds else { return }
        flow.askAbandon(key: key, owner: owner)
    }

    /// 二次确认里【确定放弃】。
    func abandon(key: String, owner: WalletOwner) {
        guard alive, owner == identity.owner, scopeHolds else {
            flow.cancelAbandon()
            return
        }
        flow.abandon(key: key, owner: owner)
    }

    func cancelAbandon() {
        flow.cancelAbandon()
    }

    /// 读取失败态 / 30416 之后的【重试】：用户主动刷新，资格按新读取更新（explicit，共性第 42 条）。
    func retry(version: Int, owner: WalletOwner) {
        guard owns(version, owner) else { return }
        state.notice = nil
        loadAll(explicit: true)
    }

    /// 【去提现】（只在 full 会话、不是从强更进入时显示，G12）。
    func goWithdraw(version: Int, owner: WalletOwner) {
        guard owns(version, owner), identity.scope == DeletionScope.full, identity.source != .forceUpdate else {
            return
        }
        flow.visibility.navigated()
        ports?.open(Self.withdrawRoute, from: page)
    }

    /// 【去绑定手机号】（G10：未绑手机、full 会话）。
    func goBindPhone(version: Int, owner: WalletOwner) {
        guard owns(version, owner), identity.scope == DeletionScope.full else { return }
        flow.visibility.navigated()
        ports?.open(Self.bindPhoneRoute, from: page)
    }

    /// 【联系客服】：统一客服出口。
    func contactService(version: Int, owner: WalletOwner) {
        guard owns(version, owner) else { return }
        ports?.contactService()
    }

    /// 被拦下的自动引导的手动入口。
    func openGuide(owner: WalletOwner) {
        guard alive, owner == identity.owner, scopeHolds else { return }
        flow.openGuideManually(owner: owner)
    }

    func consumeToast(_ id: Int) {
        if state.toast?.id == id {
            state.toast = nil
        }
    }
}
