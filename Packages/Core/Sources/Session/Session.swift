import Config
import Foundation
import SecureStore

/// 会话作用域（04 §2.5 session_scope；BR-ID-01 细则「受限会话」）。
public enum SessionScope {
    public static let full = "full"
    public static let deletionOnly = "deletion_only"
}

/// 一次读出的完整会话（同一次安全存储读取的各项，不会拼出两次读取的混合结果）。
public struct SessionSnapshot: Equatable, Sendable {
    public let access: String
    public let refresh: String
    /// session_scope：full / deletion_only。
    public let scope: String
    /// 登录响应的 user_id；刷新响应不带，刷新时沿用。
    public let account: String?
    /// 持久化登录世代（FU-IOS-0712）：与令牌同一个 Keychain 条目、同一次写入；登录换新、刷新沿用；升级前保存的会话没有（nil）。
    /// 按账号分区的本机缓存（订单、钱包、订单恢复记录、phone_bound）再按它分一层，nil 即不读不写。
    public let loginEpoch: String?

    public init(access: String, refresh: String, scope: String, account: String?, loginEpoch: String? = nil) {
        self.access = access
        self.refresh = refresh
        self.scope = scope
        self.account = account
        self.loginEpoch = loginEpoch
    }
}

/// 会话读取失败（与「不存在」区分开，R2-01）。
public enum SessionReadError: Error, Equatable, Sendable {
    /// 存储暂时读不了（设备锁定、Keychain 不可用等）：会话可能存在，调用方不得当成没有会话，也不得带凭据发送。
    case readFailed
    /// 读到了条目但内容损坏（解不出完整的四项）：不能当成有效会话使用。
    case corrupted
}

/// 新的登录世代（随机、不含账号与令牌）。
public enum SessionLoginEpoch {
    public static func make() -> String {
        UUID().uuidString.lowercased()
    }
}

/// 会话令牌（03 §4.2「Token 刷新」）：access_token、refresh_token、session_scope、登录返回的 user_id（account）与持久化登录世代。
/// 登录流程在 APP-05。account 是四个 step-up 敏感操作未决记录的账号来源（可信会话上下文），不由调用方传入。
///
/// 读取前调用方必须先确认凭据可读（撤回同意的清理已完成，`WithdrawalCleanupRunner.credentialsReadable`）；
/// 本类型自己不判断隐私状态。
public protocol SessionTokens: AnyObject, Sendable {
    /// 一次读出完整会话：nil = 确认没有会话；抛 `SessionReadError.readFailed` = 读取失败（可能有会话）；
    /// 抛 `SessionReadError.corrupted` = 条目存在但内容损坏。
    func readSession() throws -> SessionSnapshot?
    /// 全部字段一起写（一个 Keychain 条目，不会只写一半）。`loginEpoch`：登录传新世代，刷新传原会话的世代（升级前的会话为 nil）。
    func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws
    /// 便捷写入（测试预置会话、调试假登录）：按一次新登录处理，生成新的登录世代。
    func save(access: String, refresh: String, scope: String, account: String?) throws
    func clear() throws
}

public extension SessionTokens {
    func save(access: String, refresh: String, scope: String, account: String?) throws {
        try save(access: access, refresh: refresh, scope: scope, account: account, loginEpoch: SessionLoginEpoch.make())
    }

    /// 只实现了四项写入的替身（旧测试的计数包装）：登录世代交给它内部的实现（按新登录处理）。
    func save(access: String, refresh: String, scope: String, account: String?, loginEpoch _: String?) throws {
        try save(access: access, refresh: refresh, scope: scope, account: account)
    }
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

    var loginEpoch: String? {
        (try? readSession())??.loginEpoch
    }
}

/// 安全存储实现：会话各项合成一个 JSON 存在一个 Keychain 账号下（`keychainAccount`），撤销标记另存一个 Keychain 账号
/// （`revokedAccount`），Keychain 写不进时标记落在独立介质（`revocationFile`，生产为 Application Support 下的文件）。
///
/// - 读：读不出抛 `readFailed`；内容不完整（`StoredSession` 完整校验不通过）抛 `corrupted`；读到令牌后先核对两处撤销标记——撤销了这份会话
///   就按没有会话（并尽力删除），任一标记读不出（Keychain 出错、文件除「不存在」以外的任何错误）抛 `readFailed`，不缓存成「无标记」；
/// - 清：**从不读取令牌**（零读取，教训 16）：撤销目标取装载 / 保存时记下的那一份，不知道就写 `*`。先落 Keychain 标记；它写不进时
///   **先**落独立介质标记，再删令牌；Keychain 标记已落而删除失败时独立介质也补一份。确认删除后尽力删两处标记；
/// - 写：新登录（登录世代与此前记下的不同）保存成功后删掉两处标记；删不掉的、会阻断这次登录的标记改写成 `s:<新世代>`。刷新保存不动标记。
/// - 残余：Keychain 与独立介质**都**写不进时没有介质能落下撤销，只剩网络层的进程内隔离（rule-gaps G03）。
public final class SecureSessionTokens: SessionTokens, @unchecked Sendable {
    public static let keychainAccount = "session.tokens"
    public static let revokedAccount = "session.revoked"

    /// 本实例知道的存储内容：不知道 / 确认没有令牌 / 某一份会话（撤销目标）。
    private enum Known: Equatable {
        case unknown
        case absent
        case session(String)
    }

    private let store: any SecureKeyValueStore
    private let revocationFile: (any SessionRevocationMedium)?
    private let lock = NSLock()
    private var known = Known.unknown
    /// 已确认两处都没有标记时的 `SessionRevocationSignals` 读数（之后任何实例落过标记就重新核对）。
    private var marksAbsentStamp: UInt64?

    /// - Parameter revocationFile: 独立撤销记录的介质；nil = 只用 Keychain 标记（单测）。生产用 `production()`。
    public init(store: any SecureKeyValueStore, revocationFile: (any SessionRevocationMedium)? = nil) {
        self.store = store
        self.revocationFile = revocationFile
    }

    /// 生产实例：Keychain + Application Support 下的独立撤销文件。
    public static func production() -> SecureSessionTokens {
        SecureSessionTokens(store: KeychainStore(), revocationFile: FileSessionRevocationMarks.standard())
    }

    /// 是否接了独立撤销介质（App 接线测试核对）。
    public var hasIndependentRevocation: Bool {
        revocationFile != nil
    }

    public func readSession() throws -> SessionSnapshot? {
        try lock.withLock {
            let data: Data?
            do {
                data = try store.data(forAccount: Self.keychainAccount)
            } catch {
                known = .unknown
                throw SessionReadError.readFailed
            }
            guard let data else {
                known = .absent
                return nil
            }
            guard let snapshot = StoredSession.parse(data) else {
                known = .unknown
                throw SessionReadError.corrupted
            }
            let target = SessionRevocation.target(loginEpoch: snapshot.loginEpoch, refresh: snapshot.refresh)
            known = .session(target)
            let revoked: Bool
            do {
                revoked = try revokedLocked(target)
            } catch {
                throw SessionReadError.readFailed
            }
            guard !revoked else {
                // 撤销标记阻断：按没有会话；尽力删掉残留的令牌（确认删掉才清标记）
                if (try? store.remove(account: Self.keychainAccount)) != nil {
                    known = .absent
                    dropMarksLocked()
                }
                return nil
            }
            return snapshot
        }
    }

    /// 调用方持有 `lock`。两处标记（Keychain、独立介质的正式与临时文件）有没有撤销 `target`；任一处读不出抛错。
    private func revokedLocked(_ target: String) throws -> Bool {
        let stamp = SessionRevocationSignals.value
        if marksAbsentStamp == stamp {
            return false
        }
        var present = false
        if let mark = try store.data(forAccount: Self.revokedAccount) {
            present = true
            if SessionRevocation.blocks(mark, target: target) {
                return true
            }
        }
        if let revocationFile {
            for mark in try revocationFile.read() {
                present = true
                if SessionRevocation.blocks(mark, target: target) {
                    return true
                }
            }
        }
        marksAbsentStamp = present ? nil : stamp
        return false
    }

    public func save(access: String, refresh: String, scope: String, account: String?, loginEpoch: String?) throws {
        let snapshot = try StoredSession.normalized(
            access: access, refresh: refresh, scope: scope, account: account, loginEpoch: loginEpoch
        )
        let data = try StoredSession.encode(snapshot)
        try lock.withLock {
            let previous = known
            do {
                try store.set(data, forAccount: Self.keychainAccount)
            } catch {
                known = .unknown
                throw error
            }
            let target = SessionRevocation.target(loginEpoch: snapshot.loginEpoch, refresh: snapshot.refresh)
            known = .session(target)
            if let epoch = snapshot.loginEpoch, previous != .session(target) {
                supersedeMarksLocked(newEpoch: epoch)
            }
        }
    }

    /// 调用方持有 `lock`。新登录保存成功后：删掉两处标记；删不掉的、会阻断这次登录的改写成 `s:<新世代>`（改写也失败就留着，
    /// 下次冷启动按已撤销，需要重新登录，偏保守）。
    private func supersedeMarksLocked(newEpoch: String) {
        let target = "e:" + newEpoch
        let superseding = Data(SessionRevocation.encode("s:" + newEpoch).utf8)
        if (try? store.remove(account: Self.revokedAccount)) == nil {
            // 读不出按会阻断处理（改写）
            let blocking: Bool
            do {
                blocking = try store.data(forAccount: Self.revokedAccount)
                    .map { SessionRevocation.blocks($0, target: target) } ?? false
            } catch {
                blocking = true
            }
            if blocking {
                SessionRevocationSignals.bump()
                _ = try? store.set(superseding, forAccount: Self.revokedAccount)
            }
        }
        if let revocationFile, (try? revocationFile.delete()) == nil {
            let blocking: Bool
            do {
                blocking = try revocationFile.read().contains { SessionRevocation.blocks($0, target: target) }
            } catch {
                blocking = true
            }
            if blocking {
                SessionRevocationSignals.bump()
                _ = try? revocationFile.write(superseding)
            }
        }
    }

    public func clear() throws {
        try lock.withLock {
            let target: String = switch known {
            case let .session(value):
                value
            case .unknown, .absent:
                SessionRevocation.anySession
            }
            let mark = Data(SessionRevocation.encode(target).utf8)
            SessionRevocationSignals.bump()
            marksAbsentStamp = nil
            // 删除令牌之前先落标记（教训 14）：Keychain 写不进（多半整体不可写）就先落独立介质
            let inKeychain = (try? store.set(mark, forAccount: Self.revokedAccount)) != nil
            var inFile = false
            if !inKeychain, let revocationFile {
                inFile = (try? revocationFile.write(mark)) != nil
            }
            do {
                try store.remove(account: Self.keychainAccount)
            } catch {
                if inKeychain, !inFile, let revocationFile {
                    _ = try? revocationFile.write(mark)
                }
                throw error
            }
            known = .absent
            dropMarksLocked()
        }
    }

    /// 调用方持有 `lock`。令牌确认删掉之后：尽力删两处标记（删不掉留着无害：只撤销那一份会话；`*` 由下一次登录改写）。
    private func dropMarksLocked() {
        _ = try? store.remove(account: Self.revokedAccount)
        _ = try? revocationFile?.delete()
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
