import Foundation

// MARK: - 有效性（共性第 31、35、41、42 条）

extension AppOrders {
    /// 卡内【开启通知】（共性第 31 条）：`isValid` 已并上点击时捕获的页面 / 会话 / 隐私 / 环境有效性。
    func requestPush(isValid: @escaping @MainActor () -> Bool) async {
        guard isValid() else { return }
        await pushRequest(isValid)
        refreshNotificationStatus()
    }

    /// 点击时一次性取得身份（会话：账号 + 会话世代、网络作废世代、订单缓存清理次数），返回之后只做比较的闭包；任一变化或撤回清理进行中即失效。
    func pushValidity() -> @MainActor () -> Bool {
        let owner = currentOwner()
        return { [weak self] in self?.isCurrent(owner) ?? false }
    }
}
