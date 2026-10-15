import CouliNetwork
import Foundation
import Generated
import Session

// 第三方登录、绑手机与空号并入的纯逻辑（APP-05b；BR-ID-04、BR-ID-06、BR-INV-03 细则；03 §4.2）。三端同名；向量
// specs/oauth-login-vectors.json（OAuthLoginVectorTests）。没有界面、网络、SDK 与计时器：执行器是 OAuthLoginService /
// BindPhoneService，页面是 LoginView 的第三方区与 BindPhoneView。routeRaw / actionRaw / resultRaw 是三端接线名，不是契约路由。

/// 第三方 provider 名（openapi CreateOauthAttemptRequest.provider）。
public enum OAuthProvider {
    public static let wechat = "wechat"
    public static let apple = "apple"
    public static let huawei = "huawei"

    /// provider → 登录接口 operationId；不认识的为 nil。
    public static func loginOperation(_ provider: String) -> String? {
        switch provider {
        case wechat: "loginByWechat"
        case apple: "loginByApple"
        case huawei: "loginByHuawei"
        default: nil
        }
    }
}

/// 被拒的回调（观测接线：attempt 句柄与回调编号，不是服务端字段）。
public struct DroppedCallback: Equatable, Sendable {
    public let attempt: String
    public let seq: Int
}

/// 授权尝试的归属与页面世代（BR-ID-04 细则「授权尝试」「先校验、后消费」；任务书 §2.1）：
/// - `create` 取一个新的本地尝试（未终止时再次 create，旧尝试作废：TODO(N-29) ATTEMPT 原文未定义，保守处理）；
/// - `callback` 只接收凭证：当前尝试、已拉起、未终止、还没收到过凭证才接受；其余（迟到、重复、旧尝试）一律记入 `dropped`；
/// - `submit` 是唯一提交边界：同一尝试只提交一次，已终止或没有凭证的不提交（不记 dropped）；
/// - `cancel` / `leave` / `timeout` 终止当前尝试：之后迟到的回调只丢弃。
/// 同步纯逻辑，只在主线程用（执行器 OAuthLoginService 持有一份）。
public struct OAuthAttemptSession {
    private struct Record {
        var launched = false
        var credential = false
        var submitted = false
        var terminated = false
    }

    private var records: [String: Record] = [:]
    private var current: String?
    private var counter = 0
    /// 已提交的尝试（次序即提交次序）。
    public private(set) var submitted: [String] = []
    /// 被拒的回调。
    public private(set) var dropped: [DroppedCallback] = []

    public init() {}

    public mutating func create() -> String {
        terminateCurrent()
        counter += 1
        let handle = "oauth-attempt-\(counter)"
        records[handle] = Record()
        current = handle
        return handle
    }

    public mutating func launch(_ attempt: String) {
        guard isLive(attempt) else { return }
        records[attempt]?.launched = true
    }

    /// 第三方回调带回凭证；返回是否接受（不接受的记入 `dropped`）。
    @discardableResult
    public mutating func callback(_ attempt: String, seq: Int) -> Bool {
        guard isLive(attempt), let record = records[attempt], record.launched, !record.credential, !record.submitted
        else {
            dropped.append(DroppedCallback(attempt: attempt, seq: seq))
            return false
        }
        records[attempt]?.credential = true
        return true
    }

    /// 提交（登录请求的唯一边界）；返回这次是否真正提交。
    @discardableResult
    public mutating func submit(_ attempt: String) -> Bool {
        guard isLive(attempt), let record = records[attempt], record.credential, !record.submitted else {
            return false
        }
        records[attempt]?.submitted = true
        submitted.append(attempt)
        return true
    }

    /// 用户在第三方授权里取消。
    public mutating func cancel() {
        terminateCurrent()
    }

    /// 离开登录页（出栈、换方式、登出、归属变化）。
    public mutating func leave() {
        terminateCurrent()
    }

    /// 授权等待超时。
    public mutating func timeout() {
        terminateCurrent()
    }

    /// 这个尝试仍是当前、没有终止。
    public func isLive(_ attempt: String) -> Bool {
        current == attempt && records[attempt]?.terminated == false
    }

    private mutating func terminateCurrent() {
        if let current {
            records[current]?.terminated = true
        }
        current = nil
    }
}

/// 第三方登录成功后的分流。`routeRaw`：done（老用户直接登录）/ bind_phone_guide（第三方新号绑手机引导）/ error（不是可保存的
/// 登录响应）。`saveSession` 是保存意图（原子保存与世代检查由 ApiClient 与 LoginService 负责）。`firstPurchaseTip`：登录响应不含
/// 判定所需的信息（rule-gaps INVITE-STATE），一律不给值。
public struct OAuthRouteResult: Equatable, Sendable {
    public let routeRaw: String
    public let saveSession: Bool
    public let firstPurchaseTip: Bool?
}

/// 第三方登录响应 → 分流（BR-ID-04 细则：四个登录接口都带 is_new_user；BR-INV-03 细则 ①：第三方新号登录成功后弹一次绑手机引导）。
/// 只看完整外壳的 code、data.tokens 与 is_new_user；deletion_only（受限登录）沿用 APP-05a 的登录后计划（done）。并号不来自登录响应
/// （rule-gaps LOGIN-MERGE），只来自 bindPhone 的 30411 mergeable。
public enum OAuthLoginRoute {
    public static let done = "done"
    public static let bindPhoneGuide = "bind_phone_guide"
    public static let error = "error"

    public static func map(provider: String, response: [String: Any]) -> OAuthRouteResult {
        guard OAuthProvider.loginOperation(provider) != nil, JSONNumber.int(response["code"]) == 0,
              let data = response["data"] as? [String: Any]
        else {
            return OAuthRouteResult(routeRaw: error, saveSession: false, firstPurchaseTip: nil)
        }
        return ofData(data)
    }

    /// 已成功的登录响应的 data（LoginData）→ 分流。
    public static func ofData(_ data: [String: Any]) -> OAuthRouteResult {
        guard let tokens = data["tokens"] as? [String: Any], let access = tokens["access_token"] as? String,
              !access.isEmpty, let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty
        else {
            return OAuthRouteResult(routeRaw: error, saveSession: false, firstPurchaseTip: nil)
        }
        let restricted = (tokens["session_scope"] as? String) == Session.SessionScope.deletionOnly
        let isNew = JSONBool.isTrue(data["is_new_user"])
        return OAuthRouteResult(
            routeRaw: isNew && !restricted ? bindPhoneGuide : done, saveSession: true, firstPurchaseTip: nil
        )
    }
}

/// 第三方登录错误的页面动作。`actionRaw`：reauthorize（20004：用户重新取尝试并授权，不自动重试）/ provider_unavailable（50305：
/// 保留其他方式，不自动重试）/ field_error / risk_blocked（44001）/ force_update（10405）/ service_error（5xxxx，附 trace6）/
/// retry_after（42901）/ message（其余）。`disableMillis` 42901 的禁用毫秒数（Retry-After）。
public struct OAuthErrorResult: Equatable, Sendable {
    public let actionRaw: String
    public let textKey: String?
    public let showTrace6: Bool?
    public let disableMillis: Int64

    init(_ actionRaw: String, _ textKey: String?, trace: Bool = false, disableMillis: Int64 = 0) {
        self.actionRaw = actionRaw
        self.textKey = textKey
        showTrace6 = trace
        self.disableMillis = disableMillis
    }
}

/// 第三方登录（含取授权尝试）错误码 → 页面动作，接已有的 ErrorActionMapper（不另造码表）。
public enum OAuthLoginErrorAction {
    public static let reauthorize = "reauthorize"
    public static let providerUnavailable = "provider_unavailable"
    public static let fieldError = "field_error"
    public static let riskBlocked = "risk_blocked"
    public static let forceUpdate = "force_update"
    public static let serviceError = "service_error"
    public static let retryAfter = "retry_after"
    public static let message = "message"

    public static func map(provider: String, code: Int, data: [String: Any], headers: [String: String] = [:])
        -> OAuthErrorResult {
        let id = OAuthProvider.loginOperation(provider) ?? "loginByWechat"
        guard let operation = ApiOperations.byId(id) else {
            return OAuthErrorResult(message, nil)
        }
        // 登录页没有会话：按「受支持、正常作用域」映射（同 LoginErrorMapper；网络层按真实状态另行处理强更与会话）
        let effect = ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: operation, headers: headers, isReplay: false,
            state: ErrorActionState(
                update: UpdateRaw.supported,
                sessionScope: Session.SessionScope.full,
                appVersion: ""
            )
        ))
        return ofEffect(code: code, effect: effect)
    }

    /// 网络层已给出的 Effect（ApiResult.failure 的 effect）→ 页面动作。
    public static func ofEffect(code: Int, effect: ErrorEffect) -> OAuthErrorResult {
        let key = effect.textKey
        if code == 44001 {
            return OAuthErrorResult(riskBlocked, key)
        }
        if code == 50305 {
            return OAuthErrorResult(providerUnavailable, key)
        }
        switch effect.kind {
        case .reauthorize:
            return OAuthErrorResult(reauthorize, key)
        case .fieldError:
            return OAuthErrorResult(fieldError, key)
        case .forceUpdate:
            return OAuthErrorResult(forceUpdate, key)
        case .disableButton:
            return OAuthErrorResult(
                retryAfter, key, disableMillis: effect.disableMillis ?? ErrorActionMapper.defaultRetryAfterMillis
            )
        case .genericError:
            return OAuthErrorResult(serviceError, key, trace: true)
        default:
            return OAuthErrorResult(message, key, trace: effect.includeTrace6)
        }
    }
}

/// 第三方登录按钮是否显示（BR-ID-04 细则「未安装微信时」；任务书 §2.2）：
/// - 微信：本机已安装（检测结果未知时调用方按「照常显示」传 true，iOS 无微信查询项时一律未知，APP-12 I04 同口径）且适配器已允许启用。
///   三端正式适配器恒为不可用（无 SDK、无 AppID），所以正式包不显示；Debug 假适配器只用于测试与截图（rule-gaps BUTTONS）。
/// - Apple：只有 iOS（BR-ID-04 默认值只给 iOS 写了 SIWA）；是否真的可用另由适配器决定（entitlement 占位，iOS I0x）。
public enum ThirdPartyButtons {
    public static let ios = "ios"
    static let platforms: Set<String> = ["ios", "android", "harmony"]

    public static func wechatVisible(platform: String, installed: Bool, adapterAvailable: Bool) -> Bool {
        platforms.contains(platform) && installed && adapterAvailable
    }

    public static func appleVisible(platform: String) -> Bool {
        platform == ios
    }
}

/// 绑手机相关响应的页面动作。`actionRaw`：done（bindPhone 成功：之后刷新 getMe 与会话状态）/ retry_after（发码已受理交倒计时，或
/// 42901 按 Retry-After 等待）/ merge_confirm（30411 mergeable 且带 merge_ticket：弹并号确认，不自动并号）/ error（提示 textKey）。
public struct BindActionResult: Equatable, Sendable {
    public let actionRaw: String
    public let textKey: String?
}

/// 绑手机发码（purpose=bind）与 bindPhone 的响应 → 页面动作（BR-ID-05、BR-ID-06；openapi bindPhone 的 30411 data.reason=mergeable 与
/// merge_ticket）。输入是本地接线包装 {operation, purpose?, body, headers?}，body 才是契约外壳。
public enum BindPhoneAction {
    public static let done = "done"
    public static let retryAfter = "retry_after"
    public static let mergeConfirm = "merge_confirm"
    public static let error = "error"
    public static let bindOperation = "bindPhone"
    public static let smsOperation = "sendSmsCode"
    static let genericKey = "error.50001"

    public static func map(_ input: [String: Any]) -> BindActionResult {
        guard let operation = input["operation"] as? String, let body = input["body"] as? [String: Any],
              let code = JSONNumber.int(body["code"])
        else {
            return BindActionResult(actionRaw: error, textKey: genericKey)
        }
        let data = body["data"] as? [String: Any] ?? [:]
        let headers = (input["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return ofCode(operation: operation, code: code, data: data, headers: headers)
    }

    public static func ofCode(operation: String, code: Int, data: [String: Any], headers: [String: String] = [:])
        -> BindActionResult {
        if code == 0 {
            return BindActionResult(actionRaw: operation == bindOperation ? done : retryAfter, textKey: nil)
        }
        if operation == bindOperation, code == 30411 {
            return mergeTicket(data) != nil
                ? BindActionResult(actionRaw: mergeConfirm, textKey: "error.30411.mergeable")
                : BindActionResult(actionRaw: error, textKey: "error.30411")
        }
        guard let op = ApiOperations.byId(operation) else {
            return BindActionResult(actionRaw: error, textKey: genericKey)
        }
        let effect = ErrorActionMapper.map(ErrorActionInput(
            code: code, data: data, operation: op, headers: headers, isReplay: false,
            state: ErrorActionState(
                update: UpdateRaw.supported,
                sessionScope: Session.SessionScope.full,
                appVersion: ""
            )
        ))
        return ofEffect(effect)
    }

    /// 网络层已给出的 Effect → 页面动作（30411 先经 `ofCode` 判并号）。
    public static func ofEffect(_ effect: ErrorEffect) -> BindActionResult {
        BindActionResult(actionRaw: effect.kind == .disableButton ? retryAfter : error, textKey: effect.textKey)
    }

    /// 30411 的并号凭据：reason=mergeable 且 merge_ticket 是非空字符串才有；否则 nil（不能并号）。凭据只在内存。
    public static func mergeTicket(_ data: [String: Any]) -> String? {
        guard (data["reason"] as? String) == "mergeable", let ticket = data["merge_ticket"] as? String,
              !ticket.isEmpty
        else {
            return nil
        }
        return ticket
    }
}

/// 并号确认的结果。`resultRaw`：cancelled（请求发出前取消确认：不并号、不保存会话）/ rejected（确认后收到 30411：票据过期、已用或
/// 条件改变）/ unavailable（锁定契约没有并号接口，TODO(N-29) MERGE-SUCCESS：不发请求）/ unsupported（收到成功外壳但没有契约
/// schema，不拿 LoginResponse 冒充，不保存）/ failed（其他错误）。
public struct MergeResult: Equatable, Sendable {
    public let resultRaw: String
    public let saveSession: Bool
}

/// 并号确认 / 取消（BR-ID-06 OPS-04；规划/04 §6.1 30411）。任何结果都不保存会话（并号成功响应的形状未定）。
public enum MergeDecision {
    public static let cancel = "cancel"
    public static let confirm = "confirm"
    public static let cancelled = "cancelled"
    public static let rejected = "rejected"
    public static let unavailable = "unavailable"
    public static let unsupported = "unsupported"
    public static let failed = "failed"

    public static func apply(decision: String, response: [String: Any]?) -> MergeResult {
        guard decision == confirm else {
            return MergeResult(resultRaw: cancelled, saveSession: false)
        }
        guard let response else {
            return MergeResult(resultRaw: unavailable, saveSession: false)
        }
        switch JSONNumber.int(response["code"]) {
        case 30411: return MergeResult(resultRaw: rejected, saveSession: false)
        case 0: return MergeResult(resultRaw: unsupported, saveSession: false)
        default: return MergeResult(resultRaw: failed, saveSession: false)
        }
    }
}

/// JSON 里的真整数（不把布尔、小数当整数）。
enum JSONNumber {
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return NSNumber(value: int) == number ? int : nil
    }
}
