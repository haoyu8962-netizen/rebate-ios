import Combine
import Config
import Foundation

/// 当前环境。Debug 默认 test、Staging 默认 staging，可在调试面板切换；Release 固定 prod，没有切换代码。
///
/// 每次启动都经 `EnvironmentApplier` 核对「上次生效的环境」：三套配置同一个 Bundle ID，会互相覆盖安装，
/// 环境与记录不同时先清理本机会话与缓存（X-01）。清理失败自动重试一次，仍失败则 `gate == .blocked`：
/// RootView 只显示阻断页，任何模块都不得在 blocked 时读取会话或缓存；阻断页「重试」成功后转为 settled。
@MainActor
final class EnvironmentStore: ObservableObject {
    @Published private(set) var current: AppEnvironment
    /// 启动对账闸门（只读）。
    @Published private(set) var gate: EnvironmentGate
    /// 最近一次对账结果。
    private(set) var launchOutcome: EnvironmentApplier.LaunchOutcome

    private let applier: EnvironmentApplier

    #if DEBUG
    /// 启动对账未完成（blocked）时不允许切换。
    struct BlockedError: Error {}

    private let defaults: UserDefaults

    /// 显式选择（调试面板写入）优先，否则用构建默认环境。
    init(
        defaultEnvironment: AppEnvironment,
        defaults: UserDefaults = .standard,
        registry: EnvironmentSwitchCleanerRegistry = .shared
    ) {
        self.defaults = defaults
        applier = EnvironmentApplier(defaults: defaults, registry: registry)
        let selected = defaults.string(forKey: AppNamespace.environmentSelectionKey)
            .flatMap { id in AppEnvironment.selectable.first { $0.id == id } }
        let initial = selected ?? defaultEnvironment
        current = initial
        (launchOutcome, gate) = applier.settleAtLaunch(environmentID: initial.id)
    }

    /// 切换环境：先运行全部清理入口，全部成功才记录并切换；有失败则不切换、记录不变，并抛出。
    func switchTo(_ environment: AppEnvironment) throws {
        guard gate == .settled else {
            throw BlockedError()
        }
        guard environment != current else {
            return
        }
        try applier.apply(environmentID: environment.id)
        defaults.set(environment.id, forKey: AppNamespace.environmentSelectionKey)
        current = environment
    }

    var debugCapabilities: DebugCapabilities {
        DebugCapabilities(environment: current)
    }
    #else
    init(defaults: UserDefaults = .standard, registry: EnvironmentSwitchCleanerRegistry = .shared) {
        applier = EnvironmentApplier(defaults: defaults, registry: registry)
        current = .prod
        (launchOutcome, gate) = applier.settleAtLaunch(environmentID: AppEnvironment.prod.id)
    }
    #endif

    /// 阻断页的「重试」：再跑一次启动对账，成功才转为 settled（记录随之更新）；失败保持 blocked、记录不变。
    func retryLaunchCleanup() {
        guard gate == .blocked else {
            return
        }
        (launchOutcome, gate) = applier.settleAtLaunch(environmentID: current.id)
    }
}
