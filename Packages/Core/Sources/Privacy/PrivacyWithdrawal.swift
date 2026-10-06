import Config
import Foundation
import Security

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

    /// 令牌与设备凭证的占位清理器（撤回同意与切换环境共用）。
    public static let credentialCleaners: [any EnvironmentSwitchCleaning] = [
        // TODO(APP-05): Session 实现后换成会话模块自己的清理器（access_token、refresh_token、h5_token）。
        KeychainAccountsCleaner(name: "SessionTokens", accounts: CredentialAccount.sessionTokens),
        // TODO(APP-03): 设备注册实现后换成设备模块自己的清理器（device_id、install_secret）。
        KeychainAccountsCleaner(name: "DeviceIdentity", accounts: CredentialAccount.deviceIdentity),
    ]

    /// 生产用的撤回清理执行器（UserDefaults.standard + 上面的注册表）。
    public static let runner = WithdrawalCleanupRunner()

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
@MainActor
public final class WithdrawalCleanupRunner {
    private let store: any PrivacyStore
    private let registry: EnvironmentSwitchCleanerRegistry

    public init(
        defaults: UserDefaults = .standard,
        registry: EnvironmentSwitchCleanerRegistry? = nil
    ) {
        store = UserDefaultsPrivacyStore(defaults: defaults)
        self.registry = registry ?? PrivacyWithdrawalCleanup.registry
    }

    /// 撤回清理是否还有没完成的。
    public var isPending: Bool {
        store.withdrawalCleanupPending
    }

    /// 会话凭据此刻是否可以读取（撤回清理未完成时为 false）。
    public var credentialsReadable: Bool {
        !isPending
    }

    /// 撤回同意时调用：（标记不在时先合并写入撤回记录）→ 清理 → 全部成功才删标记。返回失败项。
    @discardableResult
    public func run() -> [EnvironmentCleanupFailure] {
        if !isPending {
            store.commitWithdrawal()
        }
        let failures = registry.cleanAll()
        if failures.isEmpty {
            store.clearWithdrawalPending()
        }
        return failures
    }

    /// 启动时调用（任何模块读取凭据之前）：有未完成的撤回清理就再清一次。返回清理后是否已干净。
    @discardableResult
    public func retryIfPending() -> Bool {
        guard isPending else { return true }
        return run().isEmpty
    }
}

/// Keychain 账号名（占位约定，Session / 设备注册模块实现时沿用或替换）。
public enum CredentialAccount {
    public static let sessionTokens = ["access_token", "refresh_token", "h5_token"]
    public static let deviceIdentity = ["device_id", "install_secret"]
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
