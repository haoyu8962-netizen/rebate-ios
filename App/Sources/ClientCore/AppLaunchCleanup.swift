import ClientCore
import Config
import Privacy

/// 冷启动里启动环境对账之前的固定顺序（APP-03b 共性 23，iOS R1-03）：
/// 1. 登记埋点队列的清理器（撤回同意、切换环境两个注册表）：此时队列还没创建，清理器直接删队列文件与临时文件；
/// 2. 重试上次没清干净的撤回清理；
/// 3. 创建 EnvironmentStore（启动对账：覆盖安装导致环境变化时跑全部清理器）。
/// 环境与隐私就绪后 `AppTracker.startIfReady` 才创建内存队列并绑定到这个清理器。
@MainActor
enum AppLaunchCleanup {
    static func reconcile(
        trackerFile: ClientFile = ClientFile(name: AppTracker.fileName),
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared,
        retryWithdrawal: () -> Void,
        makeEnvironment: () -> EnvironmentStore
    ) -> (trackerCleaner: TrackerQueueCleaner, environment: EnvironmentStore) {
        let trackerCleaner = AppTracker.registerQueueCleaner(
            file: trackerFile, withdrawalRegistry: withdrawalRegistry, environmentRegistry: environmentRegistry
        )
        retryWithdrawal()
        return (trackerCleaner, makeEnvironment())
    }
}
