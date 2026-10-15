import CouliNetwork
import Foundation
import Generated
import Session

/// LoginService 的工具（结果换算、JSON、时间格式）。
extension LoginService {
    public static let genericKey = "error.50001"
    /// 发码供应商超时（BR-ID-05：结果未知，不计成功条数）。
    static let providerTimeoutCode = 50401

    static let phoneInvalidData: [String: Any] = ["fields": ["phone"], "reason": PhoneNumber.reasonInvalid]

    static func otherFailure(_ result: ApiResult) -> LoginOutcome {
        switch result {
        case let .sessionNotSaved(reason, traceId):
            if reason == LocalRejectReason.sessionSaveFailed || reason == LocalRejectReason.invalidSessionTokens {
                // 登录响应缺令牌或令牌没能保存：不算登录成功（APP-03b 19）。
                return LoginOutcome("service_error", textKey: genericKey, trace6: trace6(traceId))
            }
            return LoginOutcome(LoginOutcome.stale)
        case let .localReject(reason):
            if reason == LocalRejectReason.callCancelled || reason == LocalRejectReason.sessionChanged {
                return LoginOutcome(LoginOutcome.stale)
            }
            return LoginOutcome("service_error", textKey: genericKey)
        case let .sessionCleared(effect):
            return LoginOutcome("session_expired", textKey: effect.textKey ?? "error.10404")
        case .transportFailure:
            return LoginOutcome("network_error", textKey: genericKey)
        default:
            return LoginOutcome("service_error", textKey: genericKey)
        }
    }

    static func trace6(_ traceId: String?) -> String {
        String((traceId ?? "").suffix(6))
    }

    static func object(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func isoTime(_ millis: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }
}

/// 登录成功后的计划执行（APP-05a 共性 2）。
extension LoginService {
    func planState() -> [String: Any] {
        ["update": host.updateState(), "pendingAction": host.hasPendingAction()]
    }

    /// 执行登录后计划（共性 2）：先删要丢弃的待办（免得会话变化的路由同步把它执行掉）→ 明确移除登录页（含从强更页进入的
    /// 受限登录）→ 通知会话变化 → 交 Router 恢复待办，或进入 / 同步强更页。hold_pending：待办保留，只同步会话状态。
    func execute(_ actions: [String]) {
        if actions.contains(AfterLoginAction.discardPending) {
            host.discardPending()
        }
        host.closeLogin()
        if actions.contains(AfterLoginAction.holdPending) {
            host.sessionSynced()
        } else {
            host.sessionChanged()
        }
        for action in actions {
            switch action {
            case AfterLoginAction.resumePending:
                host.resumePending()
            case AfterLoginAction.enterForceUpdate:
                host.enterForceUpdate()
            default:
                break
            }
        }
    }
}

/// 页面读的发码截止（APP-05a 共性 21）：一律按规范化号码，从 `deadlines` 读。
public extension LoginService {
    /// 这个号码（任意写法）距可以再发码还有几秒；0 = 可以发。
    func resendRemainingSec(_ rawPhone: String) -> Int {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else { return 0 }
        return deadlines.remainingSec(phone, now: clock())
    }

    /// 这个号码在验证码有效期内收到过码（共性 12：发码限流期间仍可进验证码步继续输入）。
    func hasReceivedCode(_ rawPhone: String) -> Bool {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else { return false }
        return deadlines.hasReceivedCode(phone, now: clock())
    }

    /// 页面显示用（共性 21）：这个号码（任意写法）在给定时刻距可以再发码还有几秒——成功发码的倒计时或 42901 禁用期。
    func sendRemainingSec(_ rawPhone: String, now: Int64) -> Int {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else { return 0 }
        return deadlines.remainingSec(phone, now: now)
    }

    /// 页面显示用（共性 21）：这个号码在给定时刻处于发码 42901 限流期。
    func sendRateLimited(_ rawPhone: String, now: Int64) -> Bool {
        guard let phone = PhoneNumber.normalize(rawPhone).normalized else { return false }
        return deadlines.active(phone, now: now)?.kind == SmsCountdown.stateRateLimited
    }
}

/// 第三方登录（APP-05b）共用的登录尝试与协议版本。
extension LoginService {
    /// 本次登录尝试的归属（第三方登录与短信登录共用：登录页出栈、换号、取消时一起作废）。
    var attemptOwner: AttemptOwner {
        owner
    }

    /// 登录请求上送的协议版本（第三方登录与短信登录同一份）。
    var legalVersions: LegalVersions {
        legal
    }
}
