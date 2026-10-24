import BridgeHost
import Config
import CouliNetwork
import Foundation
import Privacy
import Web

extension AppWeb {
    /// 切号协调器与会话来源（F-X-25）：身份快照与订单 / 钱包同一入口（凭据可读性与会话一次读出）；登录保存 → 读快照判定，
    /// 明确清除会话（退出、10404、刷新被拒）→ 不读凭据直接登记。网络层在任意线程通知，这里切到主线程（已在主线程时同步处理，
    /// 判定与隔离不跨任务）。切换环境、撤回同意经 `TrustedWebAuthCleaner` 在清理链里同步登记。
    static func makeWebAuth(
        network: AppNetwork, dependencies: TrustedWebAuthDependencies
    ) -> TrustedWebAuthCoordinator {
        let client = network.client
        let source = network.source
        let coordinator = TrustedWebAuthCoordinator(
            dependencies: dependencies,
            identity: {
                let snapshot = client.identitySnapshot(credentialsReadable: source.credentialsReadableNow)
                return WebSessionIdentity(
                    known: snapshot.known, account: snapshot.account, loginEpoch: snapshot.loginEpoch
                )
            },
            stamp: { client.sessionGeneration }
        )
        let target = WeakWebAuth(coordinator)
        client.observeSessionChanges { change in
            let handle: @Sendable () -> Void = {
                MainActor.assumeIsolated {
                    switch change {
                    case .saved: target.value?.sessionMaybeChanged()
                    case .cleared: target.value?.sessionExplicitlyCleared()
                    }
                }
            }
            if Thread.isMainThread {
                handle()
            } else {
                DispatchQueue.main.async(execute: handle)
            }
        }
        return coordinator
    }
}

/// 切换环境、撤回同意的清理项（F-X-25 I5）：在清理链里同步登记「Web 数据待清理」并隔离全部可信容器——不读凭据（此时凭据门
/// 已关、身份快照为未知），也不等异步清理（清理由协调器在后台完成，失败保持隔离）。撤回禁读屏障、切换关闭步骤与清理器本身
/// 三处都登记（可重复，同一次清除只发一次 auth.changed）。不抛错：Web 清理失败不阻断切换 / 撤回本身。
@MainActor
final class TrustedWebAuthCleaner: WithdrawalReadBarrierRaising, EnvironmentSwitchClosing {
    static let name = "TrustedWeb.authPending"

    let cleanerName = TrustedWebAuthCleaner.name
    private weak var coordinator: TrustedWebAuthCoordinator?
    private let early: TrustedWebAuthDependencies?

    init(coordinator: TrustedWebAuthCoordinator) {
        self.coordinator = coordinator
        early = nil
    }

    /// 启动对账阶段（AppWeb 还没建，CouliApp.registerEarlyCleaners 登记）：上次没清干净的撤回、换装环境的启动清理只写持久标记，
    /// 协调器创建时在任何可信页面加载前先补清（I3）。AppWeb 建好后被同名的协调器版本替换。
    init(earlyMarking dependencies: TrustedWebAuthDependencies) {
        early = dependencies
    }

    static func registerEarly() {
        register(
            TrustedWebAuthCleaner(earlyMarking: .production()),
            withdrawal: PrivacyWithdrawalCleanup.registry, environmentSwitch: .shared
        )
    }

    /// 登记进两个注册表、排在作废在途桥调用之后；已有同名项（同一注册表上的旧组合）时替换为本实例。
    static func register(
        _ cleaner: TrustedWebAuthCleaner,
        withdrawal: EnvironmentSwitchCleanerRegistry,
        environmentSwitch: EnvironmentSwitchCleanerRegistry
    ) {
        for registry in [withdrawal, environmentSwitch] {
            if registry.registeredNames.contains(name) {
                registry.replace(cleaner)
            } else {
                registry.register(cleaner, after: BridgeHostsCleaner.name)
            }
        }
    }

    func raiseWithdrawalReadBarriers() {
        explicitlyCleared()
    }

    func closeForEnvironmentSwitch() {
        explicitlyCleared()
    }

    func cleanForEnvironmentSwitch() throws {
        explicitlyCleared()
    }

    private func explicitlyCleared() {
        if let coordinator {
            coordinator.sessionExplicitlyCleared()
        } else {
            early?.markPendingClear()
        }
    }
}

/// 网络层通知闭包里弱持有协调器（闭包可在任意线程调用，只在主线程上取用）。
private final class WeakWebAuth: @unchecked Sendable {
    weak var value: TrustedWebAuthCoordinator?

    init(_ value: TrustedWebAuthCoordinator) {
        self.value = value
    }
}
