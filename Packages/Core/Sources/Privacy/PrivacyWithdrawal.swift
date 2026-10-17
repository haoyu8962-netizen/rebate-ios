import Config
import Foundation
import SecureStore
import Security
import Session

/// 撤回同意时的本地清理（BR-ID-13：清本地令牌、device_id、install_secret 后进入基本模式）。
///
/// 用 APP-01 的清理器注册表（`EnvironmentSwitchCleanerRegistry` + `EnvironmentSwitchCleaning`）组织：
/// 会话与设备注册还不存在（APP-05、设备注册任务），这里先放占位清理项，删除 Keychain 里约定账号名下的条目；
/// 各模块实现后把自己的清理器登记进 `registry`，并删掉对应占位。
///
/// 与切换环境的区别（03 §3.6、BR-ID-13）：
/// - 切换环境清得更多（LKG、页面缓存、pending_action……），但保留本机隐私决定（`AppNamespace.privacyDecisionKeys`）；
/// - 撤回同意只清下面这些凭证，隐私决定由 `PrivacyGate.withdraw` 改写为基本模式，不删除（否则会变回未决、再弹首启弹窗）。
/// 两边都清的凭证：同一个占位清理器同时登记在两个注册表里，避免任一路径漏删。
@MainActor
public enum PrivacyWithdrawalCleanup {
    /// 撤回同意的清理器注册表。
    public static let registry = EnvironmentSwitchCleanerRegistry(cleaners: credentialCleaners)

    /// 令牌与设备凭证的清理器（撤回同意与切换环境共用）。网络层的作废项（`NetworkInvalidationCleaner`）由创建
    /// ApiClient 的一方（App 的 AppNetwork）用 `registerFirst` 登记到两个注册表的第一位、在允许任何请求之前。
    public static let credentialCleaners: [any EnvironmentSwitchCleaning] = [
        // 会话令牌（access_token、refresh_token、session_scope、user_id，一个 Keychain 条目；APP-03a）。
        SessionTokensCleaner(tokens: SecureSessionTokens.production()),
        // TODO(APP-05): h5_token 实现后换成会话模块自己的清理器。
        KeychainAccountsCleaner(name: "H5Token", accounts: CredentialAccount.h5Token),
        // 设备凭据（device_id、install_secret，一个 Keychain 条目；APP-03b）。App 用 `replaceCredentialCleaner`
        // 换成 ClientCore 的 DeviceRegistryCleaner（同名，同时作废进行中的注册、清内存）；
        // 这里的同名项保证没接线时也删得掉。
        KeychainAccountsCleaner(
            name: CredentialAccount.deviceIdentityCleanerName,
            accounts: CredentialAccount.deviceIdentity
        ),
    ]

    /// 生产用的撤回清理执行器（UserDefaults.standard + 上面的注册表）。
    public static let runner = WithdrawalCleanupRunner()

    /// 把一个清理项同时登记进撤回同意与切换环境两个注册表的第一位（网络层作废在途请求要先于清令牌）。
    public static func registerFirst(
        _ cleaner: any EnvironmentSwitchCleaning,
        withdrawal: EnvironmentSwitchCleanerRegistry = registry,
        environmentSwitch target: EnvironmentSwitchCleanerRegistry
    ) {
        for each in [withdrawal, target] where !each.registeredNames.contains(cleaner.cleanerName) {
            each.registerFirst(cleaner)
        }
    }

    /// 把一个清理项同时登记进两个注册表、排在名为 `name` 的清理项之后（没有这一项时排在最前面）。
    public static func register(
        _ cleaner: any EnvironmentSwitchCleaning,
        after name: String,
        withdrawal: EnvironmentSwitchCleanerRegistry = registry,
        environmentSwitch target: EnvironmentSwitchCleanerRegistry
    ) {
        for each in [withdrawal, target] where !each.registeredNames.contains(cleaner.cleanerName) {
            each.register(cleaner, after: name)
        }
    }

    /// 用同名清理项替换两个注册表里的凭证清理器（没有同名项时追加）；App 把各模块自己的清理器（如设备凭据）换进来。
    public static func replaceCredentialCleaner(
        _ cleaner: any EnvironmentSwitchCleaning,
        withdrawal: EnvironmentSwitchCleanerRegistry = registry,
        environmentSwitch target: EnvironmentSwitchCleanerRegistry
    ) {
        withdrawal.replace(cleaner)
        target.replace(cleaner)
    }

    /// 把凭证清理器也登记进切换环境的注册表（App 启动时调用一次）。
    public static func registerForEnvironmentSwitch(_ target: EnvironmentSwitchCleanerRegistry) {
        let existing = Set(target.registeredNames)
        for cleaner in credentialCleaners where !existing.contains(cleaner.cleanerName) {
            target.register(cleaner)
        }
    }
}

/// 撤回同意的本地清理执行器（APP-02b 评审，三端统一，S0；第 2 轮：中断安全）：
/// - 待清理标记与基本模式、清除同意记录在同一次写入里落盘（`PrivacyStore.commitWithdrawal`，由 `PrivacyGate.withdraw` 先写）；
///   单独调用 `run()` 而标记还不在时，同样先做这次合并写入；
/// - 全部清理器成功才删标记（只删标记）；任一失败则保留，下次启动（`retryIfPending`）重试，直到清干净；
/// - 标记存在期间 `credentialsReadable == false`：任何模块都不得读取会话凭据（令牌、device_id、install_secret）。
///   TODO(APP-05、APP-03): Session 与设备注册读取凭据前必须先检查 `credentialsReadable`。
/// - 撤回记录写入失败不吞掉（F-ALL-05）：内存标记 `writeGuard` 立即生效（凭据不可读、闸门按基本模式），
///   `retryIfPending` 先补写，落盘后再清理。
@MainActor
public final class WithdrawalCleanupRunner {
    private let store: any PrivacyStore
    private let registry: EnvironmentSwitchCleanerRegistry
    /// 撤回记录未落盘的内存标记（PrivacyGate 共用同一个实例）。
    public let writeGuard: WithdrawalWriteGuard

    public init(
        defaults: UserDefaults = .standard,
        registry: EnvironmentSwitchCleanerRegistry? = nil,
        writeGuard: WithdrawalWriteGuard = WithdrawalWriteGuard()
    ) {
        store = UserDefaultsPrivacyStore(defaults: defaults)
        self.registry = registry ?? PrivacyWithdrawalCleanup.registry
        self.writeGuard = writeGuard
    }

    /// 指定存储（单测注入写入失败）。
    public init(
        store: any PrivacyStore,
        registry: EnvironmentSwitchCleanerRegistry,
        writeGuard: WithdrawalWriteGuard = WithdrawalWriteGuard()
    ) {
        self.store = store
        self.registry = registry
        self.writeGuard = writeGuard
    }

    /// 撤回清理是否还有没完成的。
    public var isPending: Bool {
        store.withdrawalCleanupPending
    }

    /// 会话凭据此刻是否可以读取（撤回清理未完成、或撤回记录还没落盘时为 false）。
    public var credentialsReadable: Bool {
        !isPending && !writeGuard.isUnpersisted
    }

    /// 撤回同意时调用：（标记不在时先合并写入撤回记录，写不进去置内存标记）→ 清理 → 全部成功且记录已落盘才删标记。
    /// 返回失败项。
    @discardableResult
    public func run() -> [EnvironmentCleanupFailure] {
        // 屏障先于标记（APP-08 iOS r3h NEW-05）：发布待清理标记（含内存的未落盘标记）之前同步竖起禁读屏障。
        raiseReadBarriers()
        if !isPending {
            if store.commitWithdrawalVerified() {
                writeGuard.markPersisted()
            } else {
                writeGuard.markUnpersisted()
            }
        }
        let failures = registry.cleanAll()
        if failures.isEmpty, !writeGuard.isUnpersisted {
            store.clearWithdrawalPending()
        }
        return failures
    }

    /// 撤回禁读屏障（APP-08 iOS r3h NEW-05）：同步竖起清理器注册表里各项的禁读屏障（网络 readBarrier、作废世代、设备
    /// withdrawalBarrier）。撤回清理的每个入口——`PrivacyGate.withdraw`、补写撤回记录、`run`、`retryIfPending`——都在发布待清理
    /// 标记（含内存的未落盘标记）之前调用它；只竖屏障、不删除，可重复调用。
    public func raiseReadBarriers() {
        registry.raiseWithdrawalReadBarriers()
    }

    /// 启动、回前台时调用（任何模块读取凭据之前）：撤回记录没落盘的先补写；有未完成的撤回清理就再清一次。
    /// 返回是否已干净（记录已落盘且清理完成）。
    @discardableResult
    public func retryIfPending() -> Bool {
        if writeGuard.isUnpersisted {
            // 补写待清理标记之前先竖屏障（APP-08 iOS r3h NEW-05）。
            raiseReadBarriers()
            guard store.commitWithdrawalVerified() else {
                return false
            }
            writeGuard.markPersisted()
        }
        guard isPending else { return true }
        return run().isEmpty
    }
}

/// Keychain 账号名（占位约定，Session / 设备注册模块实现时沿用或替换）。
public enum CredentialAccount {
    /// 会话令牌的 Keychain 账号名（`SecureSessionTokens`）。
    public static let sessionTokens = [SecureSessionTokens.keychainAccount]
    /// h5_token（APP-05 前的占位）。
    public static let h5Token = ["h5_token"]
    /// 设备凭据：device_id 与 install_secret 合成一个条目（一次写入、一次读出，不会只写一半；APP-03b）。
    public static let deviceIdentityAccount = "device.identity"
    public static let deviceIdentity = [deviceIdentityAccount]
    /// 设备凭据清理项的名字（占位项与 ClientCore 的 DeviceRegistryCleaner 同名，后者替换前者）。
    public static let deviceIdentityCleanerName = "DeviceIdentity"
}

public struct KeychainAccountError: Error, Equatable {
    public let account: String
    public let status: OSStatus
}

/// 删除 Keychain 里本 App 服务名下指定账号的通用密码项；不存在算成功。
@MainActor
public final class KeychainAccountsCleaner: EnvironmentSwitchCleaning {
    public let cleanerName: String
    public let accounts: [String]
    private let service: String

    public init(name: String, accounts: [String], service: String = AppNamespace.keychainService) {
        cleanerName = name
        self.accounts = accounts
        self.service = service
    }

    public func cleanForEnvironmentSwitch() throws {
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainAccountError(account: account, status: status)
            }
        }
    }
}

/// 撤回同意记录没能落盘（F-ALL-05，三端统一）：内存里的「已撤回、未落盘」标记。标记在期间闸门一律按基本模式、
/// 不放行完整功能，凭据不可读；写入持续重试，落盘成功才清除。闸门与撤回清理执行器共用同一个实例（App 接线）。
public final class WithdrawalWriteGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var unpersisted = false

    public init() {}

    /// 撤回记录还没落盘。
    public var isUnpersisted: Bool {
        lock.withLock { unpersisted }
    }

    func markUnpersisted() {
        lock.withLock { unpersisted = true }
    }

    func markPersisted() {
        lock.withLock { unpersisted = false }
    }
}
