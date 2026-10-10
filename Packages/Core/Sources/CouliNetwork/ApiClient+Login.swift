import Foundation
import Generated
import Session

/// 登录响应的令牌保存与清会话（10404）。
extension ApiClient {
    // MARK: - 登录响应

    /// 登录响应的令牌保存结果。
    enum LoginCapture: Equatable {
        /// 不是登录接口。
        case notLogin
        case saved
        /// 没有保存：原因（`LocalRejectReason` 的 session_save_failed、invalid_session_tokens、session_changed、
        /// call_cancelled）。
        case notSaved(String)
    }

    /// 登录成功：令牌在 data.tokens（LoginResponse），账号是 data.user_id；保存成功才换代、才算登录成功（R1-11）。
    /// 只在请求所属的作废世代与会话世代仍是当前、凭据可读时保存（lessons 23）：作废、退出、换账号之后到达的结果丢弃，
    /// 不覆盖新会话；调用方给了有效性（`send(_:isValid:)`）时在同一把锁里一并核对（APP-05a 共性 1）。强更状态按处理响应这一刻的最新值判断（lessons 28）：未知期间拿到 deletion_only
    /// 按「低于」处理。
    func captureLogin(
        _ operation: ApiOperation,
        _ data: Any?,
        epoch started: UInt64,
        generation session: UInt64,
        valid callValid: (@Sendable () -> Bool)? = nil,
        saved onSaved: (@Sendable (UInt64) -> Void)? = nil
    ) async -> LoginCapture {
        guard Self.loginOperations.contains(operation.operationId) else {
            return .notLogin
        }
        guard let object = data as? [String: Any],
              let pair = object["tokens"] as? [String: Any],
              let access = JSONFields.string(pair, "access_token"), !access.isEmpty,
              let refresh = JSONFields.string(pair, "refresh_token"), !refresh.isEmpty,
              let scope = JSONFields.string(pair, "session_scope"), !scope.isEmpty
        else {
            return .notSaved(LocalRejectReason.invalidSessionTokens)
        }
        let state = await readContext()
        guard state.privacy == PrivacyRaw.full, state.credentialsReadable else {
            return .notSaved(LocalRejectReason.callCancelled)
        }
        let account = JSONFields.string(object, "user_id")
        let saved: LoginCapture = lock.withLock {
            guard epoch == started else {
                return .notSaved(LocalRejectReason.callCancelled)
            }
            // 调用方的归属（APP-05a 共性 1、24）：登录尝试已作废（换号、取消、登录页出栈）时，迟到的成功响应不保存会话。
            // 核对与保存在同一把锁里；登录尝试的作废也在这把锁里完成（`withLoginCommitLock`），不会插在核对之后、写入之前：
            // 作废要么先于核对（不保存），要么等保存完成之后才生效（会话已保存，调用方按「只同步会话、不恢复待办」处理）。
            guard callValid?() ?? true else {
                return .notSaved(LocalRejectReason.callCancelled)
            }
            guard generation == session else {
                return .notSaved(LocalRejectReason.sessionChanged)
            }
            do {
                try tokens.save(access: access, refresh: refresh, scope: scope, account: account)
            } catch {
                return .notSaved(LocalRejectReason.sessionSaveFailed)
            }
            generation &+= 1
            revokedSession = nil
            onSaved?(generation)
            return .saved
        }
        guard saved == .saved else {
            return saved
        }
        if let account, !account.isEmpty {
            pendingKeys.coldStart(account: account)
        } else {
            pendingKeys.signOut()
        }
        if scope == SessionScope.deletionOnly, state.update == UpdateRaw.unknown {
            await hooks.onForceUpdate(nil)
        }
        return .saved
    }

    // MARK: - 清会话（10404）

    /// 清会话（10404 等）：只清本次调用所属的那一代，已换代的新会话不动；删除失败时内存里作废并持续重试。
    /// 返回清理之后的会话世代（会话失效 Effect 的归属，APP-05a 共性 26）；世代已变、没有清理时为 nil——清理是否发生与归属
    /// 哪一代在同一把锁里定下，调用方不要事后再读当前世代补作归属。
    @discardableResult
    func clearSession(ifGeneration value: UInt64) -> UInt64? {
        let (cleared, retry): (UInt64?, Bool) = lock.withLock {
            guard generation == value else {
                return (nil, false)
            }
            let retry = clearSessionLocked()
            return (generation, retry)
        }
        if retry {
            scheduleRevokedRetry()
        }
        return cleared
    }

    // MARK: - 登出（APP-05a 共性 23）

    /// 登出的本机清理：在保存登录会话的同一把锁里核对预期的会话世代，再删除会话。
    /// - 世代没变：删除会话并换代（`signedOut`）；
    /// - 世代变了、此刻没有会话（原会话已被 10404 / 刷新失败清除）：不删任何东西（`alreadyCleared`），调用方照样完成登出收尾；
    /// - 世代变了、已有新会话（等待期间重新登录）：不动新会话（`superseded`）。
    public func signOut(expectedGeneration: UInt64) -> SignOutOutcome {
        let (outcome, retry): (SignOutOutcome, Bool) = lock.withLock {
            if generation == expectedGeneration {
                return (.signedOut, clearSessionLocked())
            }
            // 撤回禁读屏障竖着（撤回同意 / 切换环境的清理期间，r3f NEW-01）：不读令牌。此时不可能已有新登录（登录保存要求凭据可读），
            // 原会话随撤回清理删除，按已清除收尾。
            if readBarrier {
                return (.alreadyCleared, false)
            }
            return readSessionLocked() == SessionRead.none ? (.alreadyCleared, false) : (.superseded, false)
        }
        if retry {
            scheduleRevokedRetry()
        }
        if outcome != .superseded {
            pendingKeys.signOut()
        }
        return outcome
    }
}

public extension ApiClient {
    /// 登录尝试的发送（APP-05a 共性 1、24；APP-04 共性 68）：`isValid` 同 `send(_:isValid:)`，并在保存登录会话的同一把锁里
    /// 再核对一次；保存成功时在这把锁里以保存后的会话世代调用 `onSessionSaved`（只做记录，不得回调 ApiClient）。
    func send(
        _ call: ApiCall,
        isValid: @escaping @Sendable () -> Bool,
        onSessionSaved: @escaping @Sendable (UInt64) -> Void
    ) async -> ApiResult {
        guard let operation = ApiOperations.byId(call.operationId) else {
            return .localReject(reason: LocalRejectReason.invalidCall)
        }
        var options = RunOptions(epoch: currentEpoch)
        options.callValid = isValid
        options.onSessionSaved = onSessionSaved
        return await run(call, operation, isReplay: false, options: options)
    }

    /// 在保存登录会话所用的同一同步区里执行 `body`（APP-05a 共性 24）：登录尝试的作废经它完成，保证不会插在「核对尝试仍有效」
    /// 与「写入令牌」之间。`body` 只改调用方自己的状态，不得再调用 ApiClient（锁不可重入）。
    func withLoginCommitLock<T>(_ body: () -> T) -> T {
        lock.withLock(body)
    }
}

/// `ApiClient.signOut(expectedGeneration:)` 的结果。
public enum SignOutOutcome: Sendable, Equatable {
    case signedOut
    case alreadyCleared
    case superseded
}
