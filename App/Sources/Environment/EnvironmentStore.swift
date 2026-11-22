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
    /// 正在切换环境（清理与提交期间）：网络状态源按「环境未就绪」处理，禁止设备注册与一切请求（APP-03b 共性 10）。
    private(set) var switching = false
    /// 每次切换尝试结束（成功或失败）后 +1：AppNetwork 据此在当前环境恢复设备注册与配置拉取（APP-03b 共性 5、14）。
    @Published private(set) var switchAttempts = 0
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
        let initial = Self.selectedEnvironment(defaults: defaults, fallback: defaultEnvironment)
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
        defer {
            switching = false
            switchAttempts += 1
        }
        // 发布 switching、读取保留项之前先同步关闭（FU-IOS-0711，APP-03b 共性 10、17）：`apply` 先做网络作废（推进作废世代、
        // 竖网络屏障）、设备禁读、取消在途传输，之后才回调这里发布 switching（关闭环境闸门：清理与提交期间不放行任何请求，
        // 含设备注册），再读取保留项、运行清理器。持有切换前「环境就绪」快照的后台请求此后零读取凭据、零发送。
        try applier.apply(environmentID: environment.id) {
            switching = true
        }
        defaults.set(environment.id, forKey: AppNamespace.environmentSelectionKey)
        current = environment
    }

    var debugCapabilities: DebugCapabilities {
        DebugCapabilities(environment: current)
    }

    /// 显式选择（调试面板写入、且是可选环境之一）优先，否则 `fallback`（构建默认环境）。
    nonisolated static func selectedEnvironment(defaults: UserDefaults, fallback: AppEnvironment) -> AppEnvironment {
        defaults.string(forKey: AppNamespace.environmentSelectionKey)
            .flatMap { id in AppEnvironment.selectable.first { $0.id == id } } ?? fallback
    }
    #else
    init(defaults: UserDefaults = .standard, registry: EnvironmentSwitchCleanerRegistry = .shared) {
        applier = EnvironmentApplier(defaults: defaults, registry: registry)
        current = .prod
        (launchOutcome, gate) = applier.settleAtLaunch(environmentID: AppEnvironment.prod.id)
    }
    #endif

    /// 当前运行环境 id 的非隔离读法（N-22：AppConfig 的 bridge_origins 验签每次现取；AppConfig 早于 EnvironmentStore 创建，
    /// 拿不到实例）。与已提交的 `current.id` 同源：Debug / Staging 取显式选择（`switchTo` 写记录与改 current 在同一同步区），
    /// 否则构建默认环境；Release 固定 prod。切换的清理与提交期间配置拉取被环境闸门挡住，不会在新旧之间验签。
    nonisolated static func runtimeEnvironmentId(defaults: UserDefaults = .standard) -> String {
        #if DEBUG
        selectedEnvironment(defaults: defaults, fallback: BuildInfo.defaultEnvironment).id
        #else
        AppEnvironment.prod.id
        #endif
    }

    /// 阻断页的「重试」：再跑一次启动对账，成功才转为 settled（记录随之更新）；失败保持 blocked、记录不变。
    func retryLaunchCleanup() {
        guard gate == .blocked else {
            return
        }
        (launchOutcome, gate) = applier.settleAtLaunch(environmentID: current.id)
    }
}
