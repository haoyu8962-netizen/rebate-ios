import Foundation
import SecureStore

/// 可按账号注入故障的安全存储（单测）：记下每次读 / 写 / 删（含先后），`beforeRemove` 在删除前拿到此刻的全部内容（截点快照）。
final class ScriptedSecureStore: SecureKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]
    private var log: [String] = []
    var failReads: Set<String> = []
    var failRemoves: Set<String> = []
    /// 整体不可写：任何 set / remove 都失败。
    var failWritesAll = false
    var beforeRemove: ((String, [String: Data]) -> Void)?

    init(values: [String: Data] = [:]) {
        storage = values
    }

    var values: [String: Data] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var events: [String] {
        lock.withLock { log }
    }

    func raw(_ account: String) -> Data? {
        lock.withLock { storage[account] }
    }

    func reads(_ account: String) -> Int {
        lock.withLock { log.filter { $0 == "get:" + account }.count }
    }

    func writes(_ account: String) -> Int {
        lock.withLock { log.filter { $0 == "set:" + account }.count }
    }

    func data(forAccount account: String) throws -> Data? {
        try lock.withLock {
            log.append("get:" + account)
            guard !failReads.contains(account) else { throw SecureStoreError(account: account, status: -25308) }
            return storage[account]
        }
    }

    func set(_ data: Data, forAccount account: String) throws {
        try lock.withLock {
            log.append("set:" + account)
            guard !failWritesAll else { throw SecureStoreError(account: account, status: -25291) }
            storage[account] = data
        }
    }

    func set(_ data: Data, forAccount account: String, label _: String) throws {
        try set(data, forAccount: account)
    }

    func remove(account: String) throws {
        let snapshot = lock.withLock { storage }
        beforeRemove?(account, snapshot)
        try lock.withLock {
            log.append("remove:" + account)
            guard !failWritesAll, !failRemoves.contains(account) else {
                throw SecureStoreError(account: account, status: -25291)
            }
            storage[account] = nil
        }
    }

    func accounts(withLabel _: String) throws -> [String] {
        []
    }
}
