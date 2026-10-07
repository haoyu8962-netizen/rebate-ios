import Foundation
import Session

/// 登录触发的受限会话复查结果（APP-05a，三端对齐名 refresh_restricted）。
public enum RestrictedRecheck: String, Sendable, Equatable {
    /// 复查后是正常会话（刷新拿到 full）。
    case full
    /// 仍是受限会话（刷新仍回 deletion_only，或会话没有 refresh_token、刷新暂时失败：会话保留）。
    case restricted
    /// 会话已被清除（刷新被拒、等待期间会话被清）。
    case cleared
    /// 调用方已失效（登录尝试作废、Task 被取消）或会话已换代：不据此做任何路由动作。
    case cancelled
}

public extension ApiClient {
    /// 当前会话的作用域（经过会话隔离判断：隔离中、读取失败、没有会话时为 nil）。守卫的会话状态据此区分受限会话。
    var isolatedSessionScope: String? {
        lock.withLock {
            guard let live = readSessionLocked().live, live.access != nil else {
                return nil
            }
            return live.scope ?? SessionScope.full
        }
    }

    /// 登录拿到 deletion_only 而本机强更结论为受支持时的显式复查（APP-05a 共性 4、10；harmony-review R1-04 / R2-02）：
    /// 存储的会话是 deletion_only 就并入本世代的单飞刷新窗口，按窗口的完整结果返回。`isValid` 是登录尝试的归属：
    /// 它登记为刷新窗口的调用方，调用方的 Task 被取消时立即结束等待；它是最后一个有效调用方时刷新请求一并取消。
    func recheckRestrictedSession(isValid: @escaping @Sendable () -> Bool) async -> RestrictedRecheck {
        let state = await readContext()
        guard isValid() else {
            return .cancelled
        }
        let bound = currentGeneration
        let read = readSession(state)
        guard let live = read.live, let access = live.access else {
            return .cleared
        }
        guard live.scope == SessionScope.deletionOnly else {
            return .full
        }
        guard live.refresh != nil else {
            return .restricted
        }
        let outcome = await joinRefresh(generation: bound, usedToken: access, caller: isValid)
        guard isValid(), !Task.isCancelled else {
            return .cancelled
        }
        switch outcome {
        case .refreshed:
            let scope = lock.withLock { readSessionLocked().live?.scope }
            return scope == SessionScope.deletionOnly ? .restricted : .full
        case .transient:
            return .restricted
        case .cleared:
            return .cleared
        case .superseded:
            return .cancelled
        }
    }
}

extension ApiClient {
    /// 调用方持有 `lock`。会话丢失（刷新失败）的 Effect：以最近读到的强更状态为准（结算前刚读过）。
    /// 只在刚清过会话（`clearSessionLocked`）之后、同一把锁里调用：Effect 归属这次清理之后的会话世代（APP-05a 共性 26）。
    func sessionLostEffectLocked() -> ErrorEffect {
        var effect = lastUpdateSeen == UpdateRaw.below
            ? ErrorEffect(code: 10002, kind: .clearSessionStayForceUpdate, route: "ForceUpdate")
            : ErrorEffect(code: 10002, kind: .clearSessionLogin, route: "Login")
        effect.sessionGeneration = generation
        return effect
    }

    /// 调用方持有 `lock`。记下「这一代因刷新失败被清」（只留最近几代）。
    func recordRefreshFailureLocked(_ value: UInt64, _ effect: ErrorEffect) {
        refreshFailures[value] = effect
        while refreshFailures.count > Self.refreshFailureMemory, let oldest = refreshFailures.keys.min() {
            refreshFailures[oldest] = nil
        }
    }
}
