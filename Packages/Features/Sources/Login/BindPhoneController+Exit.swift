import Foundation

/// 退出本实例的方式（R3-01）：绑定成功按完成前置；查明已绑（进页查询、别的实例绑定成功）只恢复。
enum BindExitKind: Equatable {
    case prerequisiteDone
    case resumeOnly
}

/// 延后的退出：发起时的固定身份 + 退出方式（R3-01）。
struct BindDeferredExit: Equatable {
    let owner: BindPhoneOwner
    let kind: BindExitKind
}

/// 退出（R3-01、R3-03）。
extension BindPhoneController {
    /// 此刻可以按「已绑」退出本实例：存活、尚未退出、固定身份（账号 + 登录世代 + 作废世代 + 作用域）仍是当前会话、共享状态里这一代
    /// 会话已绑手机。页面许可由调用方核对。
    var boundExitAllowed: Bool {
        alive && !exited && service.isCurrent(owner)
            && service.store.bound(generation: owner.request.generation) == true
    }

    /// 绑定成功或查明已绑的结果到达（共享结算已完成）：页面此刻已经恢复（存活、可见、栈顶、前台）就立即退出一次，不等下一次
    /// appeared；仍隐藏就记下发起身份延后（APP-05b 共性第 25、26 条，鸿蒙 FU-HM-0720 R1-01 / R1-02 同口径）。
    func boundArrived(_ kind: BindExitKind) {
        guard alive, !exited else { return }
        if visibleNow {
            exitNow(kind)
        } else {
            deferredExit = BindDeferredExit(owner: owner, kind: kind)
        }
    }

    /// 核对后退出一次；返回是否已退出。
    @discardableResult
    func exitNow(_ kind: BindExitKind) -> Bool {
        guard boundExitAllowed else { return false }
        exited = true
        deferredExit = nil
        switch kind {
        case .prerequisiteDone:
            hooks.completed(entryId, owner.request.generation)
        case .resumeOnly:
            hooks.alreadyBound(entryId, owner.request.generation)
        }
        return true
    }
}
