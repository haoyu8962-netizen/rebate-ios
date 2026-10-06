import Foundation
import Security

/// 切换环境前要清掉的一类本机数据（03 §3.6「切换环境」：会话、缓存、设备标识、pending_action 等）。
///
/// 本任务只有 UserDefaults 命名空间与 Keychain 服务两项；会话、LKG、页面缓存等模块
/// 在各自任务里实现本协议并注册进 `EnvironmentSwitchCleanerRegistry.shared`。
@MainActor
public protocol EnvironmentSwitchCleaning: AnyObject {
    var cleanerName: String { get }
    func cleanForEnvironmentSwitch() throws
}

public struct EnvironmentCleanupFailure: Error, Sendable, Equatable {
    public let cleanerName: String
    public let message: String
}

/// 清理入口注册表。
@MainActor
public final class EnvironmentSwitchCleanerRegistry {
    public static let shared = EnvironmentSwitchCleanerRegistry(cleaners: [
        UserDefaultsNamespaceCleaner(),
        KeychainServiceCleaner(),
    ])

    private var cleaners: [any EnvironmentSwitchCleaning]

    public init(cleaners: [any EnvironmentSwitchCleaning] = []) {
        self.cleaners = cleaners
    }

    public func register(_ cleaner: any EnvironmentSwitchCleaning) {
        cleaners.append(cleaner)
    }

    /// 登记到最前面（要先于其他清理项执行的，如网络层作废在途请求先于清令牌）。
    public func registerFirst(_ cleaner: any EnvironmentSwitchCleaning) {
        cleaners.insert(cleaner, at: 0)
    }

    public var registeredNames: [String] {
        cleaners.map(\.cleanerName)
    }

    /// 依次运行全部清理；一项失败不影响其他项，返回全部失败。
    public func cleanAll() -> [EnvironmentCleanupFailure] {
        cleaners.compactMap { cleaner in
            do {
                try cleaner.cleanForEnvironmentSwitch()
                return nil
            } catch {
                return EnvironmentCleanupFailure(cleanerName: cleaner.cleanerName, message: "\(error)")
            }
        }
    }
}

/// 清除 UserDefaults 里本 App 命名空间（`AppNamespace.userDefaultsPrefix`）下的键，
/// 环境记录键与本机隐私决定键（`AppNamespace.preservedOnEnvironmentSwitchKeys`）除外。
@MainActor
public final class UserDefaultsNamespaceCleaner: EnvironmentSwitchCleaning {
    public let cleanerName = "UserDefaults"
    private let defaults: UserDefaults
    private let prefix: String
    private let preservedKeys: Set<String>

    public init(
        defaults: UserDefaults = .standard,
        prefix: String = AppNamespace.userDefaultsPrefix,
        preservedKeys: Set<String> = AppNamespace.preservedOnEnvironmentSwitchKeys
    ) {
        self.defaults = defaults
        self.prefix = prefix
        self.preservedKeys = preservedKeys
    }

    public func cleanForEnvironmentSwitch() throws {
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(prefix) && !preservedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// 删除 Keychain 里本 App 服务名下的全部通用密码项。
@MainActor
public final class KeychainServiceCleaner: EnvironmentSwitchCleaning {
    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    public let cleanerName = "Keychain"
    private let service: String

    public init(service: String = AppNamespace.keychainService) {
        self.service = service
    }

    public func cleanForEnvironmentSwitch() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
