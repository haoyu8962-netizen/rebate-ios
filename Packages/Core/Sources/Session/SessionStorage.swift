import Foundation

/// 持久化会话的完整校验（FU-IOS-0712，跨端教训 13）：access / refresh 是非空字符串；session_scope 只能是 full / deletion_only；
/// account、login_epoch 不在（或 null）或是非空字符串。任一项不满足（含类型不对、不是 JSON 对象）整组按损坏。
enum StoredSession {
    static let accessKey = "access"
    static let refreshKey = "refresh"
    static let scopeKey = "scope"
    static let accountKey = "account"
    static let epochKey = "login_epoch"
    static let scopes: Set<String> = [SessionScope.full, SessionScope.deletionOnly]

    static func parse(_ data: Data) -> SessionSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = text(object[accessKey]), !access.isEmpty,
              let refresh = text(object[refreshKey]), !refresh.isEmpty,
              let scope = text(object[scopeKey]), scopes.contains(scope),
              let account = optionalText(object[accountKey]),
              let epoch = optionalText(object[epochKey])
        else { return nil }
        return SessionSnapshot(access: access, refresh: refresh, scope: scope, account: account, loginEpoch: epoch)
    }

    /// 只认真正的字符串（JSONSerialization 里数字、布尔是 NSNumber，`as? String` 不会把它们转过来）。
    private static func text(_ value: Any?) -> String? {
        value as? String
    }

    /// 可缺省的字段：不在 / null → 有值为 nil 的结果；非空字符串 → 有值；其余（空串、类型不对）→ nil（校验失败）。
    private static func optionalText(_ value: Any?) -> String?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let string = value as? String, !string.isEmpty else { return nil }
        return .some(string)
    }

    static func encode(_ snapshot: SessionSnapshot) throws -> Data {
        var object: [String: Any] = [
            accessKey: snapshot.access, refreshKey: snapshot.refresh, scopeKey: snapshot.scope,
        ]
        if let account = snapshot.account {
            object[accountKey] = account
        }
        if let epoch = snapshot.loginEpoch {
            object[epochKey] = epoch
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 写入前校验：写下去的必须是之后能完整读回的（不合法直接报保存失败，不落一份会被隔离的会话）。空账号 / 空世代按没有。
    static func normalized(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?)
        throws -> SessionSnapshot {
        guard !access.isEmpty, !refresh.isEmpty, scopes.contains(scope) else { throw SessionSaveError.invalid }
        return SessionSnapshot(
            access: access, refresh: refresh, scope: scope,
            account: account.flatMap { $0.isEmpty ? nil : $0 }, loginEpoch: loginEpoch.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

public enum SessionSaveError: Error, Equatable, Sendable {
    /// 要保存的会话不完整（空令牌、非法作用域）。
    case invalid
}

/// 内存实现（单测）。
public final class MemorySessionTokens: SessionTokens, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SessionSnapshot?
    private var failing = false
    private var failingClears = false
    private var readError: SessionReadError?

    /// 预置会话按一次新登录处理（带新的登录世代）。
    public init(access: String? = nil, refresh: String? = nil, scope: String? = nil, account: String? = nil) {
        if access != nil || refresh != nil {
            current = SessionSnapshot(
                access: access ?? "", refresh: refresh ?? "", scope: scope ?? "full", account: account,
                loginEpoch: SessionLoginEpoch.make()
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

    public func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws {
        try lock.withLock {
            guard !failing else {
                throw SaveFailed()
            }
            current = SessionSnapshot(
                access: access, refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch
            )
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
