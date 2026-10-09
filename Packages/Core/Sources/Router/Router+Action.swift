// 发起页自己执行的 pending_action（APP-06b 购买 open_link）：与 open_route 共用同一份本地记录（只存 1 条、10 分钟、完成一步重新计时、
// 退出登录 / 切换环境清除，BR-ID-10），但 Router 不执行它（resumePending 只认 open_route，见 Router.swift）。
import Foundation

public extension Router {
    /// 登记一条发起页自己执行的待办（新的覆盖旧的）。`action` 不能是 open_route；params 不得含令牌、验证码等敏感键（存储层拒绝）。
    @discardableResult
    func registerAction(_ action: String, params: [String: Any]) -> Bool {
        guard action != Self.openRouteAction, let values = JSONValue.object(from: params) else { return false }
        guard pendingStore.save(
            action: action, values: values, now: pendingStore.now, origin: RouteSource.inApp.rawValue
        ) else { return false }
        tagPending()
        return true
    }

    /// 仍有效的、动作名为 `action` 的待办参数；没有、已过期或不是这个动作为 nil。读取不重置计时。
    func pendingAction(_ action: String) -> [String: Any]? {
        guard let pending = pendingStore.load(now: pendingStore.now), pending.action == action else { return nil }
        return pending.params
    }

    /// 完成了一个前置步骤（登录、授权）：动作名为 `action` 的待办重新计时。
    func markActionStepDone(_ action: String) {
        guard pendingAction(action) != nil else { return }
        pendingStore.markStepDone(now: pendingStore.now)
    }

    /// 删除动作名为 `action` 的待办（别的动作的记录不动）。
    func clearAction(_ action: String) {
        guard pendingAction(action) != nil else { return }
        pendingStore.clear()
    }
}
