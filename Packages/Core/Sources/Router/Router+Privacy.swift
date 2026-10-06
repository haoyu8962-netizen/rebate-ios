// 隐私相关的 Router 入口（APP-02b）：从 Router.swift 拆出，便于单独阅读。
import Foundation

extension Router {
    /// 隐私弹窗已处理（02b 调用）。`granted` = 用户同意。
    /// - Agent 卡片登记的动作：一律删除，要用户重新点击（BR-ID-10，R1-05）。
    /// - 其余动作：同意后计为完成一个前置步骤，按前置继续（登录、绑手机、实名）并恢复原路由（R1-06）；不同意则删除。
    public func consentHandled(granted: Bool = true) {
        awaitingConsentResult = false
        consentRequested = false
        guard let pending = pendingStore.load(now: pendingStore.now) else { return }
        guard granted, pending.origin != RouteSource.agentCard.rawValue else {
            pendingStore.clear()
            return
        }
        prerequisiteCompleted()
    }

    /// 隐私状态变化（02b 在弹窗结论、撤回同意、进入基本模式时调用）：Agent 卡片登记的动作遇隐私阻断即删除。
    public func privacyChanged() {
        purgeAgentPendingIfPrivacyBlocked(state())
    }

    /// 只有隐私已同意时才保留 Agent 卡片来源的 pending_action；未决、基本模式都算隐私阻断（BR-ID-10 Agent 卡片 ②，R1-05）。
    func privacyAllowsAgentRecord(_ state: GuardState) -> Bool {
        state.privacy == .consented
    }

    /// 任何时刻观察到隐私阻断，都删除 origin=agent_card 的记录（读记录不重置计时）。
    func purgeAgentPendingIfPrivacyBlocked(_ state: GuardState) {
        guard !privacyAllowsAgentRecord(state),
              let pending = pendingStore.load(now: pendingStore.now),
              pending.origin == RouteSource.agentCard.rawValue
        else {
            return
        }
        pendingStore.clear()
    }
}
