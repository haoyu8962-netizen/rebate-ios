import Foundation

/// 推送上报的会话跟踪（App 每次会话 / 隐私 / 强更状态同步时调 `sync`；鸿蒙 H07 / H17、Android 同口径，共性第 3 条）：区分「恢复已有会话」与
/// 「真实登录成功」。
/// - 真实登录成功只认登录页给的会话世代（`loginCompleted`）：会话标识变成这个世代时报 login_success；
/// - 其余出现的会话（进程第一次同步就有、隐私结论或环境晚到后才可读的已存会话、桥登录）一律按已登录冷启动：等隐私与版本检查有结果（不低于才报，
///   低于丢弃），期间令牌变化合并到这次冷启动；
/// - 会话标识变空：退出 / 失效（策略实例终止并另建）。
@MainActor
public final class PushSessionTracker {
    private let reporter: PushTokenReporter
    private let sessionKey: () -> String
    private let generation: () -> UInt64
    /// 强更结论：supported / below / unknown。
    private let update: () -> String
    private var last: String?
    private var coldPending = false
    private var loginGeneration: UInt64?

    public init(reporter: PushTokenReporter, sessionKey: @escaping () -> String, generation: @escaping () -> UInt64,
                update: @escaping () -> String) {
        self.reporter = reporter
        self.sessionKey = sessionKey
        self.generation = generation
        self.update = update
    }

    public var coldStartPending: Bool {
        coldPending
    }

    /// 登录完成（会话已保存、尝试仍有效；早于或晚于状态同步都可能）。
    public func loginCompleted(_ generation: UInt64) {
        loginGeneration = generation
        let key = sessionKey()
        if coldPending, !key.isEmpty, key == last, self.generation() == generation {
            // 状态同步先于完成通知到达：这个会话其实是这次登录，按登录成功报（不再等冷启动）
            coldPending = false
            reporter.loginSucceeded()
        }
    }

    /// 撤回、切换环境的清理第一步：不再等冷启动。
    public func cancelColdStart() {
        coldPending = false
        reporter.releaseColdStart()
    }

    public func sync() {
        let key = sessionKey()
        let previous = last
        last = key
        if previous == nil {
            startCold(!key.isEmpty)
        } else if previous != key {
            coldPending = false
            reporter.releaseColdStart()
            if key.isEmpty {
                reporter.loggedOut()
            } else {
                if previous?.isEmpty == false {
                    reporter.sessionChanged()
                }
                if let loginGeneration, generation() == loginGeneration {
                    reporter.loginSucceeded()
                } else {
                    startCold(true)
                }
            }
        }
        guard coldPending, !key.isEmpty else { return }
        switch update() {
        case "below":
            coldPending = false
            reporter.releaseColdStart()
        case "supported":
            coldPending = false
            reporter.coldStart()
        default:
            break
        }
    }

    private func startCold(_ pending: Bool) {
        coldPending = pending
        if pending {
            reporter.holdForColdStart()
        }
    }
}
