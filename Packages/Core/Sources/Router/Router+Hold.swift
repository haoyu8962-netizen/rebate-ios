// 第三方登录（APP-05b）的待办暂缓：从 Router.swift 拆出，便于单独阅读。
import Foundation

/// 释放暂缓之后怎样恢复待办（APP-05b 共性第 3、9、14 条）。
public enum PendingHoldRelease: Sendable, Equatable {
    /// 只恢复、不重置计时：引导【暂不】/ 关闭、未绑定离开绑手机页、老用户 getMe 失败。还缺前置（需要手机号而未验证）的保留记录，
    /// 不自动拉起前置页（Android rule-gaps 32 同口径）。
    case resumeOnly
    /// 完成了一个前置步骤：绑定成功、老用户查清手机号状态（重置计时后恢复；还缺前置时进下一个前置页）。
    case prerequisiteDone
}

public extension Router {
    /// 第三方登录保存会话的那一刻（共性第 3 条）：有效待办的计时按「完成一个前置步骤」重置（BR-ID-10；已过期的读取时删除、不复活），
    /// 但暂不执行；`session` 是登录保存后的会话标签。
    func holdPending(session: UInt64) {
        pendingStore.markStepDone(now: pendingStore.now)
        pendingHoldTag = session
    }

    /// 此刻处于暂缓（会话已换代的暂缓自动失效）。所有自动恢复入口都要查它：Router.resumePending，以及发起页自己执行的
    /// 待办（购买页经 sessionVersion 订阅的 resumeAfterLogin 等，R1-01）。
    var pendingHeld: Bool {
        guard let tag = pendingHoldTag else { return false }
        if let current = sessionTag?(), current != tag {
            pendingHoldTag = nil
            return false
        }
        return true
    }

    /// 明确释放暂缓并按 `mode` 恢复。`session` 是发起释放的那次登录 / 绑定所属的会话标签：不是同一会话的暂缓不动（旧引导、旧页面的
    /// 迟到释放不能放掉新会话的暂缓）。没有暂缓时同样按 `mode` 恢复（绑定成功、老用户查清时可能早已释放）。
    func releasePendingHold(_ mode: PendingHoldRelease, session: UInt64) {
        // 发起方的会话已不是当前会话：什么都不做（新会话的待办归新会话的流程）
        if let current = sessionTag?(), current != session {
            return
        }
        if let tag = pendingHoldTag {
            guard tag == session else { return }
            pendingHoldTag = nil
        }
        switch mode {
        case .resumeOnly:
            resumePending(state: state(), entersPrerequisite: false)
        case .prerequisiteDone:
            prerequisiteCompleted()
        }
        // 发起页自己执行的待办（购买 open_link）不归 Router 执行：显式通知原发起页重新核对后恢复一次（R1-01）
        pendingHoldReleased.send(session)
    }

    /// 只解除暂缓、不恢复（结果交给之后的状态同步与守卫）。
    func dropPendingHold(session: UInt64) {
        if pendingHoldTag == session {
            pendingHoldTag = nil
        }
    }
}
