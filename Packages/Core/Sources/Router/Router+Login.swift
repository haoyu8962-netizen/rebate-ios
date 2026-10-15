// 登录（APP-05a）用到的 Router 入口：查询 / 丢弃 pending_action、关闭登录页。
import Foundation

public extension Router {
    /// 本机有没有未过期的 pending_action（读取不重置计时；过期的读取时删除）。
    var hasPendingAction: Bool {
        pendingStore.load(now: pendingStore.now) != nil
    }

    /// 未过期的 pending_action 要打开的路由名（只读，不重置计时；APP-05b：恢复手机号级待办前先查 phone_bound）。
    var pendingRouteName: String? {
        guard let pending = pendingStore.load(now: pendingStore.now), pending.action == Self.openRouteAction else {
            return nil
        }
        return pending.paramValues["route"]?.stringValue
    }

    /// 删除 pending_action，不执行（登录拿到受限会话且强更结论低于 / 未知、正常会话但强更低于，BR-ID-10）。
    func discardPendingAction() {
        pendingStore.clear()
    }

    /// 从导航栈移除某个路由的全部页面（登录成功关闭登录页；受限登录关闭后落回强更页，APP-05a 共性 2）。
    /// 其余页面原样保留；栈里没有该路由时不改动 `path`（不发出无谓的变更）。
    func removeRoute(_ route: String) {
        guard path.contains(where: { $0.route == route }) else { return }
        path.removeAll { $0.route == route }
    }
}

// MARK: - 登出的清理归属（APP-05a 共性 23、25）

public extension Router {
    /// 登出收尾的 Router 清理，只清原会话归属的部分：
    /// - pending_action：登记时的会话标签不大于 `throughSession`（登出开始时那一代及更早），或归属未知（进程重启前登记、
    ///   记录已被改写）时删除；原会话被别处清掉（10404、刷新失败）之后用户新建的待办，标签更大，保留给正在进行的登录；
    /// - 推送回查：发起时标签不大于它的结果丢弃；之后发起的照常。
    /// 没有接会话标签来源（`sessionTag` 为 nil）时按旧口径整体清理（`sessionEnded()`）。
    func sessionEnded(throughSession: UInt64) {
        guard sessionTag != nil else {
            sessionEnded()
            return
        }
        endedSessionTag = max(endedSessionTag ?? throughSession, throughSession)
        if let held = pendingHoldTag, held <= throughSession {
            pendingHoldTag = nil
        }
        guard let current = pendingStore.load(now: pendingStore.now) else {
            pendingTag = nil
            return
        }
        if let tagged = pendingTag, Self.sameRecord(tagged.record, current), tagged.tag > throughSession {
            return
        }
        pendingStore.clear()
        pendingTag = nil
    }
}

extension Router {
    /// 刚登记的 pending_action 记下此刻的会话标签。
    func tagPending() {
        guard let tag = sessionTag?(), let record = pendingStore.load(now: pendingStore.now) else {
            pendingTag = nil
            return
        }
        pendingTag = (record, tag)
    }

    /// 发起时的会话标签已被登出收尾覆盖（标签未知的同样按已结束）。
    func sessionTagEnded(_ tag: UInt64?) -> Bool {
        guard let ended = endedSessionTag else { return false }
        guard let tag else { return true }
        return tag <= ended
    }

    /// 同一条登记（计时起点会因完成前置步骤而重置，不参与比较）。
    static func sameRecord(_ lhs: PendingAction, _ rhs: PendingAction) -> Bool {
        lhs.action == rhs.action && lhs.paramValues == rhs.paramValues && lhs.origin == rhs.origin
    }
}
