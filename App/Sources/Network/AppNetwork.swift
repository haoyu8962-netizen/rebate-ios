import Config
import CouliNetwork
import Foundation
import Generated
import Privacy
import Router
import SecureStore
import Session

/// App 的网络核心组装（APP-03a）：本 App 唯一的 `ApiClient` 在这里创建，并接上真实的状态源与回调。
///
/// - 创建即把 `NetworkInvalidationCleaner` 登记到撤回同意、切换环境两个真实注册表的**第一位**（先作废并取消在途请求，
///   含还在等连接、TLS 的，再清令牌；lessons 1、22、35）。登记在 `attach` 之前完成：attach 之前状态源一律返回
///   「环境未就绪」，客户端什么都不发。
/// - 状态源：环境闸门与当前环境的 API 基址（Release 只编译进 prod）、隐私结论、撤回清理是否完成（credentialsReadable）、
///   强更进度（AppUpdate.routerStatus）。
/// - AppUpdate 的每次状态发布接到 `ApiClient.updateStateChanged`（由低于 / 未知恢复为受支持时立即做受限会话刷新）；
///   `NetworkHooks.onForceUpdate` 接到 `AppUpdate.on10405`。
/// TODO(APP-03b): 设备凭据（device_id、install_secret）与 10402 重新注册设备；现在是未注册。
/// TODO(APP-05): 会话级 Effect（跳登录等）接 Router。
@MainActor
final class AppNetwork {
    let client: ApiClient
    let cleaner: NetworkInvalidationCleaner
    private let source: NetworkContextSource

    init(
        tokens: any SessionTokens = SecureSessionTokens(store: KeychainStore()),
        pendingBackend: any PendingKeyBackend = SecurePendingKeyBackend(store: KeychainStore()),
        device: any DeviceCredentials = UnregisteredDevice(),
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared,
        credentialsReadable: @escaping @MainActor () -> Bool = {
            PrivacyWithdrawalCleanup.runner.credentialsReadable
        },
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        let source = NetworkContextSource(credentialsReadable: credentialsReadable)
        self.source = source
        client = ApiClient(
            identity: Self.identity,
            context: { await source.snapshot() },
            device: device,
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: pendingBackend, clock: PendingActionStore.wallClockMillis),
            hooks: NetworkHooks(onForceUpdate: { minimum in await source.forceUpdate(minimum) }),
            configuration: configuration
        )
        cleaner = NetworkInvalidationCleaner(client: client)
        PrivacyWithdrawalCleanup.registerFirst(
            cleaner, withdrawal: withdrawalRegistry, environmentSwitch: environmentRegistry
        )
    }

    /// 本 App 的公共头取值（03 §4.2）。X-App-Version 是不带构建后缀的 SemVer，X-Build 是构建号。
    static var identity: ClientIdentity {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let version = AppRouting.appVersion.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        return ClientIdentity(
            platform: ClientPlatform.ios.rawValue,
            appVersion: version,
            build: build,
            channel: InstallChannel.appstore.rawValue
        )
    }

    /// 接上真实的状态源与强更通知（CouliApp 在环境、隐私、强更都创建好之后调用一次）。
    func attach(environment: EnvironmentStore, privacy: PrivacyController, update: AppUpdate) {
        source.environment = environment
        source.privacy = privacy
        source.update = update
        update.observeRouterStatus { [client] status in
            client.updateStateChanged(Self.networkUpdate(status))
        }
    }

    /// Router 的强更进度 → 网络层的强更状态（检查中按未知）。
    static func networkUpdate(_ status: UpdateCheckStatus) -> String {
        switch status {
        case .finished(.belowMin):
            UpdateRaw.below
        case .finished(.ok), .finished(.belowRecommended):
            UpdateRaw.supported
        case .finished(.unknown), .finished(.checking), .checking:
            UpdateRaw.unknown
        }
    }
}

/// 每次发请求前取的状态（主线程上读 App 的状态对象）。attach 之前一律「环境未就绪」，不发任何请求。
@MainActor
final class NetworkContextSource {
    weak var environment: EnvironmentStore?
    weak var privacy: PrivacyController?
    weak var update: AppUpdate?
    private let credentialsReadable: @MainActor () -> Bool

    init(credentialsReadable: @escaping @MainActor () -> Bool) {
        self.credentialsReadable = credentialsReadable
    }

    func snapshot() -> NetworkContext {
        guard let environment, let privacy, let update else {
            return NetworkContext(
                privacy: PrivacyRaw.undecided, environmentSettled: false, credentialsReadable: false,
                update: UpdateRaw.unknown, apiBaseURL: nil
            )
        }
        let settled = environment.gate == .settled
        return NetworkContext(
            privacy: Self.privacyRaw(privacy.routerPrivacy),
            environmentSettled: settled,
            credentialsReadable: credentialsReadable(),
            update: AppNetwork.networkUpdate(update.routerStatus),
            apiBaseURL: settled ? environment.current.endpoints.apiBaseURL : nil
        )
    }

    /// 确需强更的 10405（或强更检查未知期间拿到 deletion_only）：进强更（AppUpdate.on10405）。
    func forceUpdate(_ minimum: String?) {
        update?.on10405(minSupported: minimum)
    }

    static func privacyRaw(_ state: PrivacyState) -> String {
        switch state {
        case .consented: PrivacyRaw.full
        case .basicMode: PrivacyRaw.basic
        case .notDecided: PrivacyRaw.undecided
        }
    }
}
