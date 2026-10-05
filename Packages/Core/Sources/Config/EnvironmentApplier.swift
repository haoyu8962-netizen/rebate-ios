import Foundation

/// 环境生效记录与切换前清理（03 §3.6「切换环境」）。
///
/// 持久化「上次生效的环境」。Debug、Staging、Release 同一个 Bundle ID，会互相覆盖安装；
/// 所以每个构建启动时都核对：本次要用的环境（显式选择或构建默认）与记录不同，就先跑全部清理器，
/// 全部成功才记录新环境；有失败不记录，下次启动重试。首次安装（没有记录）只记录、不清理。
/// 调试面板手动切换也走这里（`apply(environmentID:)`）。
///
/// 环境记录键（`AppNamespace.environmentRecordKeys`）在清理期间先保存、清理后恢复，
/// 任何清理器误删都不会丢失选择。
@MainActor
public final class EnvironmentApplier {
    public enum LaunchOutcome: Equatable, Sendable {
        /// 没有记录（首次安装）：只记录，不清理。
        case firstRecord
        /// 与记录一致。
        case unchanged
        /// 与记录不同：已清理并记录新环境。
        case cleaned(previous: String)
        /// 与记录不同但清理有失败：不记录，下次启动重试。
        case cleanupFailed(previous: String, failures: [EnvironmentCleanupFailure])
    }

    private let defaults: UserDefaults
    private let registry: EnvironmentSwitchCleanerRegistry

    public init(defaults: UserDefaults = .standard, registry: EnvironmentSwitchCleanerRegistry = .shared) {
        self.defaults = defaults
        self.registry = registry
    }

    /// 上次清理完成、已生效的环境标识。
    public var appliedEnvironmentID: String? {
        defaults.string(forKey: AppNamespace.appliedEnvironmentKey)
    }

    /// 启动时调用：核对本次要用的环境与记录。
    public func reconcileAtLaunch(environmentID: String) -> LaunchOutcome {
        guard let previous = appliedEnvironmentID else {
            record(environmentID)
            return .firstRecord
        }
        if previous == environmentID {
            return .unchanged
        }
        let failures = cleanPreservingRecords()
        guard failures.isEmpty else {
            return .cleanupFailed(previous: previous, failures: failures)
        }
        record(environmentID)
        return .cleaned(previous: previous)
    }

    /// 切换到另一个环境前调用：跑全部清理器，全部成功才记录新环境；有失败抛出第一个失败，记录不变。
    public func apply(environmentID: String) throws {
        let failures = cleanPreservingRecords()
        if let first = failures.first {
            throw first
        }
        record(environmentID)
    }

    private func record(_ environmentID: String) {
        defaults.set(environmentID, forKey: AppNamespace.appliedEnvironmentKey)
    }

    private func cleanPreservingRecords() -> [EnvironmentCleanupFailure] {
        let saved = AppNamespace.environmentRecordKeys.map { ($0, defaults.object(forKey: $0)) }
        let failures = registry.cleanAll()
        for (key, value) in saved {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return failures
    }
}

/// 启动对账的结果闸门（只读状态，由 App 的环境状态持有）。
///
/// 对账清理失败时本次启动不得进入正常界面、不得读取任何会话或缓存：先自动重试一次，仍失败即 `blocked`，
/// 只显示阻断页（说明 +「重试」），重试成功才转为 `settled`。
public enum EnvironmentGate: Equatable, Sendable {
    case settled
    case blocked
}

public extension EnvironmentApplier {
    /// 启动对账：清理失败自动重试一次；返回最终结果与闸门状态。
    func settleAtLaunch(environmentID: String) -> (outcome: LaunchOutcome, gate: EnvironmentGate) {
        var outcome = reconcileAtLaunch(environmentID: environmentID)
        if case .cleanupFailed = outcome {
            outcome = reconcileAtLaunch(environmentID: environmentID)
        }
        if case .cleanupFailed = outcome {
            return (outcome, .blocked)
        }
        return (outcome, .settled)
    }
}
