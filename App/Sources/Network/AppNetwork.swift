import ClientCore
import Combine
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
/// - 设备凭据（APP-03b）：`DeviceRegistry` 是 ApiClient 的 `DeviceCredentials`（签名用真实凭据），10402 经
///   `NetworkHooks.reRegisterDevice` 单飞重新注册；它的清理项（作废进行中的注册、删凭据）替换两个注册表里的同名占位。
///   同意后的注册步骤由 PrivacyController 经 `registerDevice(done:)` 登记进 PrivacyGate（退避沿用闸门的）。
/// TODO(APP-05): 会话级 Effect（跳登录等）接 Router。
@MainActor
final class AppNetwork {
    let client: ApiClient
    let cleaner: NetworkInvalidationCleaner
    let registry: DeviceRegistry
    let deviceCleaner: DeviceRegistryCleaner
    let tokens: any SessionTokens
    let source: NetworkContextSource
    private var subscriptions: Set<AnyCancellable> = []

    init(
        tokens: any SessionTokens = SecureSessionTokens(store: KeychainStore()),
        pendingBackend: any PendingKeyBackend = SecurePendingKeyBackend(store: KeychainStore()),
        device: (any DeviceCredentials)? = nil,
        deviceStore: DeviceIdentityStore = DeviceIdentityStore(store: KeychainStore()),
        identifierReader: any DeviceIdentifierReading = VendorIdentifierReader(),
        withdrawalRegistry: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentRegistry: EnvironmentSwitchCleanerRegistry = .shared,
        credentialsReadable: @escaping @MainActor () -> Bool = {
            PrivacyWithdrawalCleanup.runner.credentialsReadable
        },
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        let source = NetworkContextSource(credentialsReadable: credentialsReadable)
        self.source = source
        self.tokens = tokens
        let registry = DeviceRegistry(
            store: deviceStore,
            reader: identifierReader,
            platform: ClientPlatform.ios.rawValue,
            context: { await source.snapshot() },
            // 读 IDFV 前最后一次同步检查：隐私已同意、撤回清理已完成、环境就绪（与清理共用同步区，共性 12）。
            admitRead: { [weak source] in
                guard let state = source?.snapshot() else {
                    return false
                }
                return state.environmentSettled && state.privacy == PrivacyRaw.full && state.credentialsReadable
            }
        )
        self.registry = registry
        client = ApiClient(
            identity: Self.identity,
            context: { await source.snapshot() },
            device: device ?? registry,
            tokens: tokens,
            pendingKeys: PendingKeyStore(backend: pendingBackend, clock: PendingActionStore.wallClockMillis),
            hooks: NetworkHooks(
                onForceUpdate: { minimum in await source.forceUpdate(minimum) },
                reRegisterDevice: { rejected, isValid in
                    await registry.reRegister(rejectedDeviceId: rejected, isValid: isValid)
                },
                deviceRejected: { rejected in registry.deviceRejected(rejectedDeviceId: rejected) }
            ),
            configuration: configuration
        )
        registry.bind(client: client)
        cleaner = NetworkInvalidationCleaner(client: client)
        PrivacyWithdrawalCleanup.registerFirst(
            cleaner, withdrawal: withdrawalRegistry, environmentSwitch: environmentRegistry
        )
        deviceCleaner = DeviceRegistryCleaner(registry: registry)
        PrivacyWithdrawalCleanup.replaceCredentialCleaner(
            deviceCleaner, withdrawal: withdrawalRegistry, environmentSwitch: environmentRegistry
        )
    }

    /// PrivacyGate 的设备注册步骤（同意后第一步，03 §4.1）：完成时在主线程回调是否已有凭据；失败由闸门退避重试。
    func registerDevice(done: @escaping (Bool) -> Void) {
        Task { @MainActor [registry] in
            let outcome = await registry.registerIfNeeded()
            done(outcome.hasCredentials)
        }
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
    /// - Parameter onEnvironmentChanged: 切换环境提交完成后（新环境已生效、清理已结束）调用，App 用它重新拉配置。
    func attach(
        environment: EnvironmentStore,
        privacy: PrivacyController,
        update: AppUpdate,
        onEnvironmentChanged: (@MainActor () -> Void)? = nil
    ) {
        source.environment = environment
        source.privacy = privacy
        source.update = update
        update.observeRouterStatus { [client] status in
            client.updateStateChanged(Self.networkUpdate(status))
        }
        // 切换环境提交完成后（`switchTo` 先跑完清理、再写记录、最后改 current）在新环境重新注册设备、重新拉配置
        // （03 §3.6；APP-03b 共性 5）。@Published 在赋值前发布，这里排到之后的主线程任务再执行，确保已提交。
        // 切换失败（清理器可能已删掉设备凭据与 LKG，仍留在旧环境）同样恢复（共性 14）：观察每次切换尝试的结束。
        environment.$switchAttempts.dropFirst().sink { [weak privacy] _ in
            Task { @MainActor in
                privacy?.restartDeviceRegistration()
                onEnvironmentChanged?()
            }
        }.store(in: &subscriptions)
        // 10402 重新注册失败：交给 PrivacyGate 的退避流程重新注册（APP-03b 共性 4）。
        registry.onNeedsRegistration = { [weak privacy] in
            Task { @MainActor in privacy?.restartDeviceRegistration() }
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
        // 切换环境的清理与提交期间按未就绪：不发任何请求（含设备注册；APP-03b 共性 10）。
        let settled = environment.gate == .settled && !environment.switching
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
