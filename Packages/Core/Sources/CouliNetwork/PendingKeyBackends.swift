import Foundation
import SecureStore

/// 一条未决记录（BR-ID-10 细则「敏感操作的幂等键」）：四个 step-up 操作首次发送前写入，按账号隔离。
/// body 为原请求体的原始文本（含账号或手机号，生产后端放 Keychain）；summary 为发起页展示的摘要。
/// stateRaw：in_flight（在途）或 unknown（结果未知）；everUnknown = 这个键出现过结果未知。
public struct PendingKeyRecord: Sendable, Equatable, Codable {
    public var key: String
    public var operationId: String
    public var body: String
    public var account: String
    public var summary: String
    public var stateRaw: String
    public var everUnknown: Bool
    public var createdAtMillis: Int64

    public init(
        key: String,
        operationId: String,
        body: String,
        account: String,
        summary: String = "",
        stateRaw: String = PendingKeyStore.inFlight,
        everUnknown: Bool = false,
        createdAtMillis: Int64 = 0
    ) {
        self.key = key
        self.operationId = operationId
        self.body = body
        self.account = account
        self.summary = summary
        self.stateRaw = stateRaw
        self.everUnknown = everUnknown
        self.createdAtMillis = createdAtMillis
    }
}

/// 一个键的当前状态（none / in_flight / unknown / done）。
public struct PendingKeyState: Sendable, Equatable {
    public let stateRaw: String
    public let record: PendingKeyRecord?
}

/// 未决记录的持久化（生产：`SecurePendingKeyBackend`；测试：`MemoryPendingKeyBackend`）。
///
/// 「没有记录」与「读不出来」必须分开（R1-07）：`load` / `loadAll` 读失败或记录损坏一律抛错，不得返回 nil 或空列表；
/// 调用方无法确认未决状态时阻止新的提交。写入、删除失败也必须抛错。
public protocol PendingKeyBackend: AnyObject {
    /// 一条记录；确实没有时返回 nil。
    func load(account: String, key: String) throws -> PendingKeyRecord?
    /// 该账号的全部记录（存储层按账号过滤，不读其他账号的条目）。
    func loadAll(account: String) throws -> [PendingKeyRecord]
    func write(_ record: PendingKeyRecord) throws
    func delete(account: String, key: String) throws
}

/// 记录存在但内容解不开（损坏）：按读失败处理，不当成没有。
public struct PendingRecordCorrupted: Error, Equatable, Sendable {
    public let slot: String
}

/// 内存后端（测试）。failWrites / failReads 为 true 时写入 / 读取抛错；`read` / `list` 是不经过故障注入的原始视图。
public final class MemoryPendingKeyBackend: PendingKeyBackend, @unchecked Sendable {
    public struct WriteFailed: Error {}
    public struct ReadFailed: Error {}

    private let lock = NSLock()
    private var records: [String: PendingKeyRecord] = [:]
    private var order: [String] = []
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

    private static func slot(_ account: String, _ key: String) -> String {
        "\(account.count):\(account)|\(key)"
    }

    public func read(account: String, key: String) -> PendingKeyRecord? {
        lock.withLock { records[Self.slot(account, key)] }
    }

    public func list(account: String) -> [PendingKeyRecord] {
        lock.withLock { order.compactMap { records[$0] }.filter { $0.account == account } }
    }

    public func load(account: String, key: String) throws -> PendingKeyRecord? {
        try lock.withLock {
            guard !failingReads else {
                throw ReadFailed()
            }
            return records[Self.slot(account, key)]
        }
    }

    public func loadAll(account: String) throws -> [PendingKeyRecord] {
        try lock.withLock {
            guard !failingReads else {
                throw ReadFailed()
            }
            return order.compactMap { records[$0] }.filter { $0.account == account }
        }
    }

    public func write(_ record: PendingKeyRecord) throws {
        try lock.withLock {
            guard !failing else {
                throw WriteFailed()
            }
            let slot = Self.slot(record.account, record.key)
            if records[slot] == nil {
                order.append(slot)
            }
            records[slot] = record
        }
    }

    public func delete(account: String, key: String) throws {
        lock.withLock {
            let slot = Self.slot(account, key)
            records[slot] = nil
            order.removeAll { $0 == slot }
        }
    }
}

/// 安全存储后端：每条记录一个 Keychain 条目（账号名 pending_key.<账号 hex>.<键 hex>，标签 pending_key.<账号 hex>.），
/// JSON 编码。按账号列出时用标签在 Keychain 里过滤，不读其他账号的条目（lessons 33）。切换环境时随服务名一起清掉。
/// Keychain 查询失败、内容解不开都抛错（不当成没有记录）。
public final class SecurePendingKeyBackend: PendingKeyBackend, @unchecked Sendable {
    public static let prefix = "pending_key."
    private let store: any SecureKeyValueStore

    public init(store: any SecureKeyValueStore) {
        self.store = store
    }

    private static func hex(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    private static func accountPrefix(_ account: String) -> String {
        prefix + hex(account) + "."
    }

    private static func slot(_ account: String, _ key: String) -> String {
        accountPrefix(account) + hex(key)
    }

    private static func decode(_ data: Data, slot: String) throws -> PendingKeyRecord {
        do {
            return try JSONDecoder().decode(PendingKeyRecord.self, from: data)
        } catch {
            throw PendingRecordCorrupted(slot: slot)
        }
    }

    public func load(account: String, key: String) throws -> PendingKeyRecord? {
        let slot = Self.slot(account, key)
        guard let data = try store.data(forAccount: slot) else {
            return nil
        }
        return try Self.decode(data, slot: slot)
    }

    public func loadAll(account: String) throws -> [PendingKeyRecord] {
        let slots = try store.accounts(withLabel: Self.accountPrefix(account))
        return try slots.sorted().compactMap { slot in
            // 列出之后、读取之前被删掉的条目确实没有了；其余读失败或解不开都抛错。
            try store.data(forAccount: slot).map { try Self.decode($0, slot: slot) }
        }
    }

    public func write(_ record: PendingKeyRecord) throws {
        try store.set(
            JSONEncoder().encode(record),
            forAccount: Self.slot(record.account, record.key),
            label: Self.accountPrefix(record.account)
        )
    }

    public func delete(account: String, key: String) throws {
        try store.remove(account: Self.slot(account, key))
    }
}
