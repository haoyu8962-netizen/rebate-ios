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
    /// 不覆盖新会话。强更状态按处理响应这一刻的最新值判断（lessons 28）：未知期间拿到 deletion_only 按「低于」处理。
    func captureLogin(
        _ operation: ApiOperation,
        _ data: Any?,
        epoch started: UInt64,
        generation session: UInt64
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
    func clearSession(ifGeneration value: UInt64) {
        let retry: Bool = lock.withLock {
            guard generation == value else {
                return false
            }
            return clearSessionLocked()
        }
        if retry {
            scheduleRevokedRetry()
        }
    }
}
