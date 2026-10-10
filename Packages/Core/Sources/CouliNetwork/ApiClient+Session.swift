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

    /// 凭据可读时的当前会话读取结果（隐私不允许读时按没有）。可读性判断与读取在同一把锁里（APP-08 iOS NEW-01）。
    func readSession(_ state: NetworkContext) -> SessionRead {
        lock.withLock { credentialsReadableLocked(state) ? readSessionLocked() : .none }
    }

    /// 调用方持有 `lock`（APP-08 iOS NEW-01）：此刻能否读取凭据。必须同时满足——
    /// - 撤回禁读屏障已放下（`readBarrier`，r3f）；
    /// - 快照允许：完整模式、撤回清理已完成（`credentialsReadable`）；
    /// - 快照仍可信：取快照之前的作废世代（`readEpoch`）仍是当前的。撤回同意、切换环境都在这把锁里推进作废世代
    ///   （`invalidateSessions`，先于清令牌），所以异步等待期间发生过撤回的旧快照在这里被拒，不会再去读残留令牌；
    /// - 调用仍属当前作废世代（`runEpoch`，给出时）。
    /// 调用方据此在**同一把锁里**先比较、再读取；任何一项不满足都不读令牌、不读设备凭据。
    func credentialsReadableLocked(_ state: NetworkContext, runEpoch: UInt64? = nil) -> Bool {
        guard !readBarrier, state.privacy == PrivacyRaw.full, state.credentialsReadable,
              let readEpoch = state.readEpoch, readEpoch == epoch
        else {
            return false
        }
        if let runEpoch, runEpoch != epoch {
            return false
        }
        return true
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
    /// 撤回禁读屏障竖着时（撤回同意 / 切换环境的清理期间，r3f NEW-01）只删除、不读取：身份按未知隔离（存储里的任何会话都按它处理；
    /// 新登录保存成功会在同一把锁里解除隔离）。
    @discardableResult
    func clearSessionLocked() -> Bool {
        generation &+= 1
        let revoked: RevokedSession
        if readBarrier {
            revokedSession = RevokedSession(access: nil, refresh: nil, identityKnown: false)
            return deleteRevokedLocked()
        }
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
        return deleteRevokedLocked()
    }

    /// 调用方持有 `lock`。只删除、不读取：删掉即解除隔离（返回 false），删不掉保持隔离（返回 true，要重试）。
    /// 隔离中存储里只可能是被隔离的会话（新登录与刷新保存都在这把锁里、且分别先解除隔离 / 要求世代未变），所以不必先读出来核对身份。
    func deleteRevokedLocked() -> Bool {
        do {
            try tokens.clear()
            revokedSession = nil
            return false
        } catch {
            return true
        }
    }

    /// 删除失败的会话按退避持续重试删除（每次读会话也会重试）。后台重试**只删除、不读取**（APP-08 iOS r3f NEW-01）：醒来时不论
    /// 撤回禁读屏障、作废世代如何，都不调用令牌存储的读取，只在仍有隔离时再删一次。
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
                guard revokedSession != nil, deleteRevokedLocked() else {
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
    /// 撤回禁读屏障竖着时（r3f NEW-01）不读令牌，按 nil。
    var isolatedAccount: String? {
        lock.withLock {
            readBarrier ? nil : readSessionLocked().live?.account.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// 会话世代（登录、退出、清会话都会加一）。同一账号退出后重新登录也是新世代（APP-04 三端共性第 15 条：桥调用按世代绑定）。
    var sessionGeneration: UInt64 {
        lock.withLock { generation }
    }
}
