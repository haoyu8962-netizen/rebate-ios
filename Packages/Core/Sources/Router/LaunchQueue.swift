import Foundation

/// 冷启动带来的一次性启动意图（只放内存，不落盘；03 §4.4「冷启动时的深链与推送」）。
public enum LaunchIntent: Sendable, Equatable {
    /// 深链：记 {route, params}。
    case route(RouteRequest)
    /// 推送：只记消息编号，执行时再回查。
    case push(messageId: String)
}

/// 强更检查的进度。
public enum UpdateCheckStatus: Sendable, Equatable {
    /// 检查中，从 `startedAt`（毫秒）开始等。
    case checking(startedAt: Int64)
    case finished(UpdateState)
}

/// 放行条件的状态源（02b、02c 接入真正的隐私闸门与强更检查，本任务可注入）。
public struct LaunchReadiness: Sendable, Equatable {
    public var environmentSettled: Bool
    public var privacy: PrivacyState
    public var update: UpdateCheckStatus

    public init(environmentSettled: Bool, privacy: PrivacyState, update: UpdateCheckStatus) {
        self.environmentSettled = environmentSettled
        self.privacy = privacy
        self.update = update
    }
}

/// 启动意图排队器：等 EnvironmentGate settled、隐私闸门有结论、强更检查有结果（或等满 5 秒按 unknown）
/// 再放行给 Router（03 §4.4 冷启动顺序：隐私闸门 → 强更检查 → Tab 就绪 → 推送回查 → 执行）。
/// 启动意图是一次性的：只保留最新一条，新的覆盖旧的；放行或丢弃后即清空。
/// TODO(APP-02b): 「Tab 就绪」一步与热启动时停在首启弹窗 / ForceUpdate 的丢弃，由 02b、02c 接入（rule-gaps G11）。
public struct LaunchQueue: Sendable {
    /// 启动意图等强更检查的上限（03 §4.4，客户端常量）。
    public static let updateWaitMillis: Int64 = 5000

    public private(set) var pending: LaunchIntent?
    /// 环境与隐私闸门都通过的时刻（毫秒）。强更的 5 秒等待从这一刻起算；闸门再次未就绪时清空。
    public private(set) var gatesOpenedAt: Int64?

    public init() {}

    public mutating func enqueue(_ intent: LaunchIntent) {
        pending = intent
    }

    public mutating func discard() {
        pending = nil
    }

    /// 本时刻守卫该用的强更结果；仍要等待时为 nil。等待从 `max(检查开始, waitFrom)` 起算。
    public static func effectiveUpdate(_ status: UpdateCheckStatus, now: Int64,
                                       waitFrom: Int64? = nil) -> UpdateState? {
        switch status {
        case let .finished(state):
            return state
        case let .checking(startedAt):
            let start = max(startedAt, waitFrom ?? startedAt)
            return now - start >= updateWaitMillis ? .unknown : nil
        }
    }

    private static func gatesReady(_ readiness: LaunchReadiness) -> Bool {
        readiness.environmentSettled && readiness.privacy != .notDecided
    }

    /// 记录闸门状态：闸门通过时记下起算时刻（已记的不变），未通过时清空。
    public mutating func observeGates(_ readiness: LaunchReadiness, now: Int64) {
        if Self.gatesReady(readiness) {
            gatesOpenedAt = gatesOpenedAt ?? now
        } else {
            gatesOpenedAt = nil
        }
    }

    /// 下一次需要重试放行的时刻（毫秒）：只有排着意图、闸门已通过、强更仍在检查时才有；
    /// 闸门未就绪时为 nil——不空转计时，等闸门状态变化再调用 `release`。
    public func nextRetryAt(readiness: LaunchReadiness) -> Int64? {
        guard pending != nil, Self.gatesReady(readiness), let opened = gatesOpenedAt,
              case let .checking(startedAt) = readiness.update
        else {
            return nil
        }
        return max(startedAt, opened) + Self.updateWaitMillis
    }

    /// 条件都满足时取出排队的意图（以及守卫该用的强更结果）；否则返回 nil、继续排队。
    /// 强更检查的 5 秒等待从环境与隐私闸门都通过后起算（03 §4.4 冷启动顺序：先过闸门再等强更）。
    public mutating func release(
        readiness: LaunchReadiness,
        now: Int64
    ) -> (intent: LaunchIntent, update: UpdateState)? {
        observeGates(readiness, now: now)
        guard let intent = pending,
              Self.gatesReady(readiness),
              let update = Self.effectiveUpdate(readiness.update, now: now, waitFrom: gatesOpenedAt)
        else {
            return nil
        }
        pending = nil
        return (intent, update)
    }
}
