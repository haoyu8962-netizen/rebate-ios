import Foundation
import Session

/// 会话读取与隔离（R2-01）：一次读出完整会话，区分没有、可用、读取失败；清会话时删除失败的隔离与删除重试。
extension ApiClient {
    // MARK: - 会话读取（作废的会话不可读）

    /// 一份会话快照（同一次 Keychain 读取的四项；空串按没有）。
    struct LiveSession: Equatable {
        let access: String?
        let refresh: String?
        let scope: String?
        let account: String?

        init(access: String?, refresh: String?, scope: String?, account: String?) {
            self.access = access
            self.refresh = refresh
            self.scope = scope
            self.account = account
        }

        init(_ snapshot: SessionSnapshot) {
            access = snapshot.access.isEmpty ? nil : snapshot.access
            refresh = snapshot.refresh.isEmpty ? nil : snapshot.refresh
            scope = snapshot.scope.isEmpty ? nil : snapshot.scope
            account = snapshot.account
        }
    }

    /// 一次会话读取的结果（R2-01）：确认没有、可用的会话、读取失败（可能有会话，不得带凭据发送）。
    /// 内容损坏的条目不能用：按没有会话处理（没有可带的凭据），并尽力删除。
    enum SessionRead: Equatable {
        case none
        case live(LiveSession)
        case unreadable

        var live: LiveSession? {
            if case let .live(value) = self {
                return value
            }
            return nil
        }
    }

    /// 删除失败、内存里已作废的会话：以当时的 access / refresh 识别；清除时读不出（读取失败、损坏）的身份未知，
    /// 存储里的任何会话都按它处理（新登录成功会直接解除隔离）。
    struct RevokedSession: Equatable {
        let access: String?
        let refresh: String?
        let identityKnown: Bool

        func matches(_ live: LiveSession) -> Bool {
            !identityKnown || (access == live.access && refresh == live.refresh)
        }
    }

    /// 凭据可读时的当前会话读取结果（隐私不允许读时按没有）。
    func readSession(_ state: NetworkContext) -> SessionRead {
        guard state.privacy == PrivacyRaw.full, state.credentialsReadable else {
            return .none
        }
        return lock.withLock { readSessionLocked() }
    }

    /// 凭据可读时的当前会话（作废、读取失败都按没有；需要区分读取失败的地方用 `readSession(_:)`）。
    func liveSession(_ state: NetworkContext) -> LiveSession? {
        readSession(state).live
    }

    /// 调用方持有 `lock`。一次读出完整会话。隔离中（`revokedSession`）：
    /// - 确认没有会话 → 解除隔离；
    /// - 读到的仍是被隔离的会话，或读取失败 → 重试删除（存储里只可能是它：新登录在同一把锁里先解除隔离），删掉才解除；
    ///   没删掉时按没有会话（读到的）或读取失败（读不出的）返回，绝不当成「没有」而解除隔离；
    /// - 读到另一个会话 → 解除隔离（已被新会话覆盖）。
    func readSessionLocked() -> SessionRead {
        let snapshot: SessionSnapshot?
        do {
            snapshot = try tokens.readSession()
        } catch SessionReadError.corrupted {
            // 损坏的条目不能当会话用；尽力删除（删不掉下次读还会再试）。不涉及隔离的解除：删除成功才算确认没有。
            if (try? tokens.clear()) != nil {
                revokedSession = nil
            }
            return .none
        } catch {
            if revokedSession != nil, (try? tokens.clear()) != nil {
                revokedSession = nil
                return .none
            }
            return .unreadable
        }
        guard let snapshot else {
            revokedSession = nil
            return .none
        }
        let live = LiveSession(snapshot)
        if let revoked = revokedSession {
            guard revoked.matches(live) else {
                revokedSession = nil
                return live.access == nil && live.refresh == nil ? .none : .live(live)
            }
            if (try? tokens.clear()) != nil {
                revokedSession = nil
            }
            return .none
        }
        guard live.access != nil || live.refresh != nil else {
            return .none
        }
        return .live(live)
    }

    /// 调用方持有 `lock`。清本世代会话并换代：先在内存里作废（不可读），再删除；删除失败保持作废、返回 true（要重试）。
    /// 读不出当前会话（读取失败、损坏）时同样隔离（身份未知），只有确认没有会话才不隔离。
    @discardableResult
    func clearSessionLocked() -> Bool {
        generation &+= 1
        let revoked: RevokedSession
        do {
            guard let snapshot = try tokens.readSession() else {
                revokedSession = nil
                return false
            }
            let live = LiveSession(snapshot)
            revoked = RevokedSession(access: live.access, refresh: live.refresh, identityKnown: true)
        } catch {
            revoked = RevokedSession(access: nil, refresh: nil, identityKnown: false)
        }
        revokedSession = revoked
        do {
            try tokens.clear()
            revokedSession = nil
            return false
        } catch {
            return true
        }
    }

    /// 删除失败的会话按退避持续重试删除（每次读会话也会重试）。
    func scheduleRevokedRetry() {
        let delay: Int64 = lock.withLock {
            let index = min(revokedRetryAttempt, revokedRetryDelays.count - 1)
            revokedRetryAttempt += 1
            return revokedRetryDelays[index]
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0)) * 1_000_000)
            guard let self else {
                return
            }
            let again: Bool = lock.withLock {
                _ = readSessionLocked()
                if revokedSession == nil {
                    revokedRetryAttempt = 0
                    return false
                }
                return true
            }
            if again {
                scheduleRevokedRetry()
            }
        }
    }

    /// 可信会话账号：凭据可读时取登录时保存的 user_id。
    func sessionAccount(_ state: NetworkContext) -> String? {
        liveSession(state)?.account.flatMap { $0.isEmpty ? nil : $0 }
    }
}

public extension ApiClient {
    /// 经过会话隔离判断的当前账号（登录时保存的 user_id）：隔离中（清会话删除失败）、读取失败、没有会话时为 nil。
    /// 不判断隐私状态（调用方先确认凭据可读）。埋点的 user_id 取它（APP-03b 共性 9）。
    var isolatedAccount: String? {
        lock.withLock { readSessionLocked().live?.account.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// 会话世代（登录、退出、清会话都会加一）。同一账号退出后重新登录也是新世代（APP-04 三端共性第 15 条：桥调用按世代绑定）。
    var sessionGeneration: UInt64 {
        lock.withLock { generation }
    }
}
