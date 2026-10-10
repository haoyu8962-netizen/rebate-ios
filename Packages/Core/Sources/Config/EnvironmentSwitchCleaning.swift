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

/// 撤回同意的禁读屏障（APP-08 iOS r3h NEW-05）：要在**发布待清理标记之前**同步竖起的那部分（如网络层的禁读屏障、作废世代、
/// 设备凭据屏障）。只竖屏障、不删任何东西；可重复调用。清理器注册表在撤回清理的每个入口、写待清理标记之前调用它。
@MainActor
public protocol WithdrawalReadBarrierRaising: EnvironmentSwitchCleaning {
    func raiseWithdrawalReadBarriers()
}

/// 切换环境的关闭步骤（FU-IOS-0711，APP-03b 共性 10、17）：要在**发布 switching、读取保留项之前**同步完成的那部分——
/// 网络作废（推进作废世代、竖网络禁读屏障）、设备禁读（设备屏障）、取消在途传输。不删任何东西、不抛错、可重复调用。
/// 切换环境的每个入口（`EnvironmentApplier.closeRequests`）在一切清理之前调用；清理器本身仍照常在 `cleanAll` 里执行。
@MainActor
public protocol EnvironmentSwitchClosing: EnvironmentSwitchCleaning {
    func closeForEnvironmentSwitch()
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

    /// 登记到名为 `name` 的清理项之后（没有这一项时登记到最前面）：如桥的在途调用作废排在网络层作废之后、清令牌之前。
    public func register(_ cleaner: any EnvironmentSwitchCleaning, after name: String) {
        if let index = cleaners.firstIndex(where: { $0.cleanerName == name }) {
            cleaners.insert(cleaner, at: index + 1)
        } else {
            cleaners.insert(cleaner, at: 0)
        }
    }

    /// 替换同名清理项（位置不变）；没有同名项时追加。
    public func replace(_ cleaner: any EnvironmentSwitchCleaning) {
        if let index = cleaners.firstIndex(where: { $0.cleanerName == cleaner.cleanerName }) {
            cleaners[index] = cleaner
        } else {
            cleaners.append(cleaner)
        }
    }

    public var registeredNames: [String] {
        cleaners.map(\.cleanerName)
    }

    /// 按登记顺序竖起全部撤回禁读屏障（APP-08 iOS r3h NEW-05）：撤回清理的每个入口在发布待清理标记（含内存的未落盘标记）之前
    /// 同步调用，使「标记已生效、清理器尚未执行」的窗口里旧请求已读不到凭据。
    public func raiseWithdrawalReadBarriers() {
        for case let cleaner as any WithdrawalReadBarrierRaising in cleaners {
            cleaner.raiseWithdrawalReadBarriers()
        }
    }

    /// 按登记顺序同步执行全部切换关闭步骤（FU-IOS-0711）：切换环境入口在发布 switching、读取保留项、运行任何清理器之前调用，
    /// 使「switching 已生效、清理器尚未执行」的窗口里旧请求已读不到凭据、发不出去。
    public func closeForEnvironmentSwitch() {
        for case let cleaner as any EnvironmentSwitchClosing in cleaners {
            cleaner.closeForEnvironmentSwitch()
        }
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
