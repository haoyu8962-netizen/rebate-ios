import Config
import Foundation
import Security

/// 安全存储（03 §3.3：令牌、未决请求体等敏感数据放 Keychain）。键是 Keychain 的账号名，值是任意字节。
///
/// 读写都可能失败（设备锁定、Keychain 不可用）：读失败按「没有」处理由调用方决定是否保守；写失败抛错，调用方不得
/// 假装已经存好（例如未决记录写不进去就不发送）。
public protocol SecureKeyValueStore: AnyObject, Sendable {
    func data(forAccount account: String) throws -> Data?
    func set(_ data: Data, forAccount account: String) throws
    /// 写入并打上分组标签（Keychain 的 kSecAttrLabel），用于按组查询。
    func set(_ data: Data, forAccount account: String, label: String) throws
    /// 删除；不存在算成功。
    func remove(account: String) throws
    /// 标签等于 label 的全部账号名（无序）。查询在存储层按属性过滤，不读出其他组的条目。
    func accounts(withLabel label: String) throws -> [String]
}

public struct SecureStoreError: Error, Equatable, Sendable {
    public let account: String
    public let status: Int32

    public init(account: String, status: Int32) {
        self.account = account
        self.status = status
    }
}

/// Keychain 实现：本 App 服务名（`AppNamespace.keychainService`）下的通用密码项，只在本机解锁后可读、不随备份迁移。
/// 切换环境时 `KeychainServiceCleaner` 会整体删除这个服务名下的全部条目。
public final class KeychainStore: SecureKeyValueStore {
    private let service: String

    public init(service: String = AppNamespace.keychainService) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func data(forAccount account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureStoreError(account: account, status: status)
        }
        return result as? Data
    }

    public func set(_ data: Data, forAccount account: String) throws {
        try write(data, account: account, label: nil)
    }

    public func set(_ data: Data, forAccount account: String, label: String) throws {
        try write(data, account: account, label: label)
    }

    private func write(_ data: Data, account: String, label: String?) throws {
        var update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let label {
            update[kSecAttrLabel as String] = label
        }
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add.merge(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw SecureStoreError(account: account, status: status)
        }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError(account: account, status: status)
        }
    }

    public func accounts(withLabel label: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw SecureStoreError(account: label, status: status)
        }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// 内存实现（单测与预览）。`failWrites` 为 true 时写入与删除都抛错，`failReads` 为 true 时读取抛错
/// （模拟 Keychain 不可用、设备锁定）。
public final class MemorySecureStore: SecureKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var labels: [String: String] = [:]
    private var labelQueries: [String] = []
    private var failing = false
    private var failingReads = false

    public init() {}

    public var failWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    public var failReads: Bool {
        get { lock.withLock { failingReads } }
        set { lock.withLock { failingReads = newValue } }
    }

    public func data(forAccount account: String) throws -> Data? {
        try lock.withLock {
            guard !failingReads else {
                throw SecureStoreError(account: account, status: errSecInteractionNotAllowed)
            }
            return values[account]
        }
    }

    public func set(_ data: Data, forAccount account: String) throws {
        try lock.withLock {
            guard !failing else {
                throw SecureStoreError(account: account, status: errSecNotAvailable)
            }
            values[account] = data
        }
    }

    public func set(_ data: Data, forAccount account: String, label: String) throws {
        try set(data, forAccount: account)
        lock.withLock { labels[account] = label }
    }

    /// 按标签查询过的标签（测试据此确认只查了本账号的组）。
    public var queriedLabels: [String] {
        lock.withLock { labelQueries }
    }

    public func remove(account: String) throws {
        try lock.withLock {
            guard !failing else {
                throw SecureStoreError(account: account, status: errSecNotAvailable)
            }
            values[account] = nil
            labels[account] = nil
        }
    }

    public func accounts(withLabel label: String) throws -> [String] {
        lock.withLock {
            labelQueries.append(label)
            return labels.filter { $0.value == label }.map(\.key)
        }
    }
}
