import Foundation
import Router

// MARK: - 等启动协调的自动动作（APP-06a R2-03）

/// 等启动协调的自动动作（进程回收后的页面恢复等）。`launchSettled` 在条件都满足时调用（可能多次，动作自己保证只执行
/// 一次）；执行完（或决定不执行）后 `launchActionFinished` 为 true，协调随即注销它。
@MainActor
protocol LaunchAutoAction: AnyObject {
    var launchActionFinished: Bool { get }
    func launchSettled(update: UpdateState)
}

extension AppRouting {
    /// 还有没执行的自动动作在等启动协调。
    var hasWaitingLaunchAutoAction: Bool {
        launchAutoActions.contains { !$0.launchActionFinished }
    }

    /// 登记一个等启动协调的自动动作，并立即协调一次（条件早已满足时马上执行）。
    func addLaunchAutoAction(_ action: LaunchAutoAction) {
        launchAutoActions.append(action)
        launchConditionsChanged()
    }

    /// 本时刻启动协调给自动动作用的强更结果：外壳就绪、环境与隐私闸门通过、强更有结果或等满 5 秒（按 unknown）时有值；
    /// 仍要等待时为 nil。与 Router 放行启动意图同一判定（等待从闸门通过起算）。
    func settledLaunchUpdate(readiness: LaunchReadiness, now: Int64) -> UpdateState? {
        guard shellReady, readiness.environmentSettled, readiness.privacy != .notDecided else { return nil }
        return LaunchQueue.effectiveUpdate(readiness.update, now: now, waitFrom: router.launchGatesOpenedAt)
    }

    func runLaunchAutoActions(readiness: LaunchReadiness, now: Int64) {
        launchAutoActions.removeAll { $0.launchActionFinished }
        guard !launchAutoActions.isEmpty, let update = settledLaunchUpdate(readiness: readiness, now: now) else {
            return
        }
        for action in launchAutoActions {
            action.launchSettled(update: update)
        }
        launchAutoActions.removeAll { $0.launchActionFinished }
    }

    /// 有自动动作在等、闸门已通过、强更仍在检查时，到「检查起点（不早于闸门通过）+ 5 秒」再协调一次；否则 nil。
    func autoActionRetryAt(readiness: LaunchReadiness, now: Int64) -> Int64? {
        guard hasWaitingLaunchAutoAction, readiness.environmentSettled, readiness.privacy != .notDecided,
              let opened = router.launchGatesOpenedAt,
              case let .checking(startedAt) = readiness.update
        else {
            return nil
        }
        let deadline = max(startedAt, opened) + LaunchQueue.updateWaitMillis
        return deadline > now ? deadline : nil
    }
}
