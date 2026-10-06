import Foundation
import Generated
import Session

/// 判定请求头与能否发送的输入（三端测试接线约定）。
public struct NetworkRequestState: Sendable, Equatable {
    /// `PrivacyRaw`；不认识的取值按 undecided（最保守）。
    public let privacy: String
    /// `SessionScope`；不认识的按 deletion_only（最保守）。
    public let sessionScope: String
    /// 本机有 access_token（凭据可读时才读）。
    public let hasAccessToken: Bool
    /// 服务端签发的 device_id；未注册为 nil。
    public let deviceId: String?
    /// 环境闸门已通过。
    public let environmentSettled: Bool
    /// 撤回同意的本地清理已完成。
    public let credentialsReadable: Bool

    public init(
        privacy: String,
        sessionScope: String,
        hasAccessToken: Bool,
        deviceId: String?,
        environmentSettled: Bool,
        credentialsReadable: Bool
    ) {
        self.privacy = privacy
        self.sessionScope = sessionScope
        self.hasAccessToken = hasAccessToken
        self.deviceId = deviceId
        self.environmentSettled = environmentSettled
        self.credentialsReadable = credentialsReadable
    }
}

/// 判定结果：send 为 false 时本地拒绝、不发出；headerNames 为要带的头。
public struct HeaderDecision: Sendable, Equatable {
    public let send: Bool
    public let localRejectReason: String?
    public let headerNames: [String]
    /// 带 Authorization。
    public let includeAuthorization: Bool
    /// 带 X-Device-Id。
    public let includeDeviceId: Bool

    public var includeSignature: Bool {
        headerNames.contains(HeaderNames.sign)
    }

    public var includeIdempotencyKey: Bool {
        headerNames.contains(HeaderNames.idempotencyKey)
    }

    static func reject(_ reason: String) -> HeaderDecision {
        HeaderDecision(
            send: false, localRejectReason: reason, headerNames: [],
            includeAuthorization: false, includeDeviceId: false
        )
    }
}

/// 公共头、签名头与本地放行判定（03 §4.1、§4.2；BR-ID-01 细则「受限会话」；BR-ID-09；BR-ID-11）。纯函数，三端同一规则。
///
/// 判定顺序：环境未就绪 → 不发；隐私不是已同意、或撤回清理未完成（凭据不可读）→ 只放行匿名白名单
/// （基本模式 BR-ID-11；尚未决定只放行配置与协议文本），剥离 Authorization、X-Device-Id、签名头；
/// 会话 deletion_only → 只放行 x-session-scopes 含 deletion_only 的接口，按请求体才接受的五个接口再看请求体
/// （没有请求体按不接受）；签名接口没有可读的设备凭据 → device_not_ready。
public enum RequestHeaderPolicy {
    /// 基本模式匿名白名单（BR-ID-11）：配置、搜索、商品详情、帮助与规则文章列表。
    /// TODO(N-19): 首页内容与 GET /v1/dict 在锁定 openapi 里没有 operationId；基本模式文章详情（getArticle，
    /// 需区分协议 / 帮助类别）未定，暂不放行（rule-gaps 第 2 条）。
    public static let basicModeAllowed: Set<String> = ["getConfig", "searchProducts", "getProduct", "listArticles"]

    /// 隐私尚未决定时只允许配置与协议文本（BR-ID-11「同意前禁止除配置和协议文本外的网络请求」）。
    /// TODO(N-19): 协议正文接口（文章详情按类别）未定，暂只放行列表。
    public static let undecidedAllowed: Set<String> = ["getConfig", "listArticles"]

    /// 不带 Idempotency-Key 的写接口（openapi：作废请求的原键放请求体）。
    public static let noIdempotencyKey: Set<String> = ["abandonIdempotencyKey"]

    private static let accountDeletion = "account_deletion"

    /// deletion_only 会话下按请求体才接受的接口（BR-ID-01 细则「受限会话」表与「版本策略」表）。
    /// 没有请求体时一律不接受（rule-gaps 第 1 条：不捏造判定结果）。TODO(N-19): 条件以 BR-ID-01 表为准，待补正反向量。
    static func restrictedBodyAllows(_ operationId: String, _ body: [String: Any]) -> Bool? {
        let purpose = JSONFields.string(body, "purpose")
        let action = JSONFields.string(body, "action")
        let deletionStepUp = purpose == "step_up" && action == accountDeletion
        switch operationId {
        case "sendSmsCode", "createOauthAttempt":
            return purpose == "login" || deletionStepUp
        case "stepUp", "abandonIdempotencyKey":
            return action == accountDeletion
        case "recordConsent":
            let type = JSONFields.string(body, "type")
            return JSONFields.bool(body, "accepted") == false || type == "privacy" || type == "agreement"
        default:
            return nil
        }
    }

    static let restrictedBodyOperations: Set<String> = [
        "sendSmsCode", "createOauthAttempt", "stepUp", "abandonIdempotencyKey", "recordConsent",
    ]

    public static func decide(
        state: NetworkRequestState,
        operation: ApiOperation,
        body: [String: Any]? = nil
    ) -> HeaderDecision {
        let declared = state.privacy == PrivacyRaw.full || state.privacy == PrivacyRaw.basic
            ? state.privacy : PrivacyRaw.undecided
        // 撤回清理未完成：与基本模式同一张匿名白名单（不只是剥离请求头；registerDevice 等请求体带设备标识的接口本地拒绝）。
        let privacy = declared == PrivacyRaw.full && !state.credentialsReadable ? PrivacyRaw.basic : declared
        if !state.environmentSettled {
            return .reject(LocalRejectReason.environmentUnsettled)
        }
        if privacy == PrivacyRaw.basic, !basicModeAllowed.contains(operation.operationId) {
            return .reject(LocalRejectReason.basicModeDenied)
        }
        if privacy == PrivacyRaw.undecided, !undecidedAllowed.contains(operation.operationId) {
            return .reject(LocalRejectReason.basicModeDenied)
        }
        if !scopeAllows(state.sessionScope, operation: operation, body: body) {
            return .reject(LocalRejectReason.sessionScopeDenied)
        }
        let credentials = privacy == PrivacyRaw.full
        let deviceId = credentials ? state.deviceId.flatMap { $0.isEmpty ? nil : $0 } : nil
        if operation.signed, deviceId == nil {
            return .reject(LocalRejectReason.deviceNotReady)
        }
        let authorization = credentials && state.hasAccessToken && operation.auth != "none"
        var names = HeaderNames.anonymous
        if authorization {
            names.append(HeaderNames.authorization)
        }
        if deviceId != nil {
            names.append(HeaderNames.deviceId)
        }
        if !operation.isRead, !noIdempotencyKey.contains(operation.operationId) {
            names.append(HeaderNames.idempotencyKey)
        }
        if operation.signed {
            names += HeaderNames.signature
        }
        return HeaderDecision(
            send: true, localRejectReason: nil, headerNames: names,
            includeAuthorization: authorization, includeDeviceId: deviceId != nil
        )
    }

    /// 当前会话作用域能否发这个接口（BR-ID-01 细则「受限会话」）。
    public static func scopeAllows(_ sessionScope: String, operation: ApiOperation,
                                   body: [String: Any]? = nil) -> Bool {
        if sessionScope == SessionScope.full {
            return operation.sessionScopes.contains(SessionScope.full)
        }
        guard operation.sessionScopes.contains(SessionScope.deletionOnly) else {
            return false
        }
        guard restrictedBodyOperations.contains(operation.operationId) else {
            return true
        }
        guard let body else {
            return false
        }
        return restrictedBodyAllows(operation.operationId, body) ?? false
    }
}

/// 自动重试策略（03 §4.2 超时、重试与弱网）。
public struct RetryDecision: Sendable, Equatable {
    public let autoRetries: Int
    public let backoffMillis: Int64
    public let timeoutMillis: Int64
}

public enum RetryPolicy {
    public static let timeoutMillis: Int64 = 10000
    public static let openLinkTimeoutMillis: Int64 = 8000
    public static let readBackoffMillis: Int64 = 500

    /// 读接口（GET）超时 / 断连自动重试 1 次（退避 500 毫秒）；写接口不自动重试；`POST /v1/links/{link_id}/open` 8 秒结束。
    /// TODO(N-19): GET 遇到没有统一外壳的 HTTP 5xx 是否重试未规定（rule-gaps 第 4 条），ApiClient 只对超时、断连重试。
    public static func forOperation(_ operation: ApiOperation) -> RetryDecision {
        let timeout = operation.operationId == "openLink" ? openLinkTimeoutMillis : timeoutMillis
        if operation.isRead {
            return RetryDecision(autoRetries: 1, backoffMillis: readBackoffMillis, timeoutMillis: timeout)
        }
        return RetryDecision(autoRetries: 0, backoffMillis: 0, timeoutMillis: timeout)
    }
}
