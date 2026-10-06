import Config
import Foundation
import SecureStore

/// 会话作用域（04 §2.5 session_scope；BR-ID-01 细则「受限会话」）。
public enum SessionScope {
    public static let full = "full"
    public static let deletionOnly = "deletion_only"
}

/// 一次读出的完整会话（同一次安全存储读取的四项，不会拼出两次读取的混合结果）。
public struct SessionSnapshot: Equatable, Sendable {
    public let access: String
    public let refresh: String
    /// session_scope：full / deletion_only。
    public let scope: String
    /// 登录响应的 user_id；刷新响应不带，刷新时沿用。
    public let account: String?

    public init(access: String, refresh: String, scope: String, account: String?) {
        self.access = access
        self.refresh = refresh
        self.scope = scope
        self.account = account
    }
}

/// 会话读取失败（与「不存在」区分开，R2-01）。
public enum SessionReadError: Error, Equatable, Sendable {
    /// 存储暂时读不了（设备锁定、Keychain 不可用等）：会话可能存在，调用方不得当成没有会话，也不得带凭据发送。
    case readFailed
    /// 读到了条目但内容损坏（解不出完整的四项）：不能当成有效会话使用。
    case corrupted
}

/// 会话令牌（03 §4.2「Token 刷新」）：access_token、refresh_token、session_scope 与登录返回的 user_id（account）。
/// 登录流程在 APP-05。account 是四个 step-up 敏感操作未决记录的账号来源（可信会话上下文），不由调用方传入。
///
/// 读取前调用方必须先确认凭据可读（撤回同意的清理已完成，`WithdrawalCleanupRunner.credentialsReadable`）；
/// 本类型自己不判断隐私状态。
public protocol SessionTokens: AnyObject, Sendable {
    /// 一次读出完整会话：nil = 确认没有会话；抛 `SessionReadError.readFailed` = 读取失败（可能有会话）；
    /// 抛 `SessionReadError.corrupted` = 条目存在但内容损坏。
    func readSession() throws -> SessionSnapshot?
    /// 四项一起写（一个 Keychain 条目，不会只写一半）。
    func save(access: String, refresh: String, scope: String, account: String?) throws
    func clear() throws
}

/// 便捷读取（展示与测试用）：读取失败、损坏都按 nil。发送判定一律用 `readSession()`，不要用这些属性拼会话。
public extension SessionTokens {
    var accessToken: String? {
        (try? readSession())??.access
    }

    var refreshToken: String? {
        (try? readSession())??.refresh
    }

    var scope: String? {
        (try? readSession())??.scope
    }

    var account: String? {
        (try? readSession())??.account
    }
}

/// 安全存储实现：四项合成一个 JSON 存在一个 Keychain 账号下（`SecureSessionTokens.keychainAccount`）。
/// 读失败抛 `readFailed`，内容解不出抛 `corrupted`，条目不存在返回 nil。
public final class SecureSessionTokens: SessionTokens {
    public static let keychainAccount = "session.tokens"

    private struct Stored: Codable {
        let access: String
        let refresh: String
        let scope: String
        let account: String?
    }

    private let store: any SecureKeyValueStore

    public init(store: any SecureKeyValueStore) {
        self.store = store
    }

    public func readSession() throws -> SessionSnapshot? {
        let data: Data?
        do {
            data = try store.data(forAccount: Self.keychainAccount)
        } catch {
            throw SessionReadError.readFailed
        }
        guard let data else {
            return nil
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.access.isEmpty || !stored.refresh.isEmpty
        else {
            throw SessionReadError.corrupted
        }
        return SessionSnapshot(
            access: stored.access,
            refresh: stored.refresh,
            scope: stored.scope,
            account: stored.account
        )
    }

    public func save(access: String, refresh: String, scope: String, account: String?) throws {
        let data = try JSONEncoder().encode(Stored(access: access, refresh: refresh, scope: scope, account: account))
        try store.set(data, forAccount: Self.keychainAccount)
    }

    public func clear() throws {
        try store.remove(account: Self.keychainAccount)
    }
}

/// 内存实现（单测）。
public final class MemorySessionTokens: SessionTokens, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SessionSnapshot?
    private var failing = false
    private var failingClears = false
    private var readError: SessionReadError?

    public init(access: String? = nil, refresh: String? = nil, scope: String? = nil, account: String? = nil) {
        if access != nil || refresh != nil {
            current = SessionSnapshot(
                access: access ?? "", refresh: refresh ?? "", scope: scope ?? "full", account: account
            )
        }
    }

    /// true 时 save 抛错（模拟 Keychain 写入失败）。
    public var failSaves: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    /// true 时 clear 抛错（模拟 Keychain 删除失败，条目仍在）。
    public var failClears: Bool {
        get { lock.withLock { failingClears } }
        set { lock.withLock { failingClears = newValue } }
    }

    /// 非 nil 时 readSession 抛这个错（模拟读取失败或内容损坏；条目本身不变）。
    public var failReads: SessionReadError? {
        get { lock.withLock { readError } }
        set { lock.withLock { readError = newValue } }
    }

    public func readSession() throws -> SessionSnapshot? {
        try lock.withLock {
            if let readError {
                throw readError
            }
            return current
        }
    }

    public struct SaveFailed: Error {}

    public func save(access: String, refresh: String, scope: String, account: String?) throws {
        try lock.withLock {
            guard !failing else {
                throw SaveFailed()
            }
            current = SessionSnapshot(access: access, refresh: refresh, scope: scope, account: account)
        }
    }

    public struct ClearFailed: Error {}

    public func clear() throws {
        try lock.withLock {
            guard !failingClears else {
                throw ClearFailed()
            }
            current = nil
        }
    }
}

/// 会话令牌的清理项：同时登记进撤回同意的清理注册表与切换环境的清理注册表（App 启动时登记）。
@MainActor
public final class SessionTokensCleaner: EnvironmentSwitchCleaning {
    public static let name = "SessionTokens.store"

    public let cleanerName = SessionTokensCleaner.name
    private let tokens: any SessionTokens

    public init(tokens: any SessionTokens) {
        self.tokens = tokens
    }

    public func cleanForEnvironmentSwitch() throws {
        try tokens.clear()
    }
}
