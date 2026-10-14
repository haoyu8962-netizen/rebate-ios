// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/openapi.yaml（只登记方法、路径与扩展字段，不含请求 / 响应模型）

/// openapi 的 x-min-version-gate（BR-ID-01 细则「最低支持版本的接口层拦截」）。
public enum ApiMinVersionGate: Swift.String, Swift.Sendable, Swift.Equatable {
    /// true：受闸门约束。
    case gated
    /// false：不受约束（例外）。
    case exempt
    /// conditional：按请求体条件（operation 说明里写条件）。
    case conditional
    /// 未标注。
    case unspecified
}

/// openapi 的一个 operation。sessionScopes 未标注时为 ["full"]（BR-ID-01 细则「受限会话」）；
/// planned = x-implementation: planned；stepUp = x-step-up 的 action（不需要二次验证为 nil）。
public struct ApiOperation: Swift.Sendable, Swift.Equatable {
    public let operationId: Swift.String
    /// 大写 HTTP 方法。
    public let method: Swift.String
    public let pathTemplate: Swift.String
    /// x-auth：none / optional / login / realname。
    public let auth: Swift.String
    public let signed: Swift.Bool
    public let idempotent: Swift.Bool
    public let stepUp: Swift.String?
    public let errorCodes: [Swift.Int]
    public let sessionScopes: [Swift.String]
    public let minVersionGate: ApiMinVersionGate
    public let planned: Swift.Bool

    /// 只读接口（GET）。
    public var isRead: Swift.Bool {
        method == "GET"
    }
}

/// 全部 operation（contracts/openapi.yaml）。
public enum ApiOperations {
    public static let all: [Swift.String: ApiOperation] = [
        "getHealthz": ApiOperation(
            operationId: "getHealthz",
            method: "GET",
            pathTemplate: "/healthz",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "registerDevice": ApiOperation(
            operationId: "registerDevice",
            method: "POST",
            pathTemplate: "/v1/devices",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: false
        ),
        "reportPushToken": ApiOperation(
            operationId: "reportPushToken",
            method: "POST",
            pathTemplate: "/v1/devices/push-token",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "sendSmsCode": ApiOperation(
            operationId: "sendSmsCode",
            method: "POST",
            pathTemplate: "/v1/auth/sms-codes",
            auth: "none",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 44001, 44003, 42901, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .conditional,
            planned: false
        ),
        "loginBySms": ApiOperation(
            operationId: "loginBySms",
            method: "POST",
            pathTemplate: "/v1/auth/login/sms",
            auth: "none",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 20002, 20003, 44001, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: false
        ),
        "createOauthAttempt": ApiOperation(
            operationId: "createOauthAttempt",
            method: "POST",
            pathTemplate: "/v1/auth/oauth-attempts",
            auth: "optional",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [10001, 20001, 50001, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .conditional,
            planned: false
        ),
        "loginByWechat": ApiOperation(
            operationId: "loginByWechat",
            method: "POST",
            pathTemplate: "/v1/auth/login/wechat",
            auth: "none",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 20004, 44001, 50305, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: true
        ),
        "loginByApple": ApiOperation(
            operationId: "loginByApple",
            method: "POST",
            pathTemplate: "/v1/auth/login/apple",
            auth: "none",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 20004, 44001, 50305, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: true
        ),
        "loginByHuawei": ApiOperation(
            operationId: "loginByHuawei",
            method: "POST",
            pathTemplate: "/v1/auth/login/huawei",
            auth: "none",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 20004, 44001, 50305, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: true
        ),
        "stepUp": ApiOperation(
            operationId: "stepUp",
            method: "POST",
            pathTemplate: "/v1/auth/step-up",
            auth: "login",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 20002, 20003, 20004, 50305, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .conditional,
            planned: false
        ),
        "refreshToken": ApiOperation(
            operationId: "refreshToken",
            method: "POST",
            pathTemplate: "/v1/auth/refresh",
            auth: "none",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [10404],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: false
        ),
        "logout": ApiOperation(
            operationId: "logout",
            method: "POST",
            pathTemplate: "/v1/auth/logout",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: false
        ),
        "recordConsent": ApiOperation(
            operationId: "recordConsent",
            method: "POST",
            pathTemplate: "/v1/consents",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .conditional,
            planned: false
        ),
        "issueH5Token": ApiOperation(
            operationId: "issueH5Token",
            method: "POST",
            pathTemplate: "/v1/auth/h5-token",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: false
        ),
        "listUnionBindings": ApiOperation(
            operationId: "listUnionBindings",
            method: "GET",
            pathTemplate: "/v1/unions/bindings",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "getUnionAuthUrl": ApiOperation(
            operationId: "getUnionAuthUrl",
            method: "GET",
            pathTemplate: "/v1/unions/{platform}/auth-url",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30101, 30102, 30153, 50301],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "bindUnion": ApiOperation(
            operationId: "bindUnion",
            method: "POST",
            pathTemplate: "/v1/unions/{platform}/bindings",
            auth: "login",
            signed: true,
            idempotent: true,
            stepUp: nil,
            errorCodes: [20001, 30101, 30102, 30104, 30151, 30153, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: false
        ),
        "listOrders": ApiOperation(
            operationId: "listOrders",
            method: "GET",
            pathTemplate: "/v1/orders",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "listPendingTracks": ApiOperation(
            operationId: "listPendingTracks",
            method: "GET",
            pathTemplate: "/v1/orders/pending-tracks",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "dismissPendingTrack": ApiOperation(
            operationId: "dismissPendingTrack",
            method: "POST",
            pathTemplate: "/v1/orders/pending-tracks/{link_id}/dismiss",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "getOrder": ApiOperation(
            operationId: "getOrder",
            method: "GET",
            pathTemplate: "/v1/orders/{order_id}",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30701],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "listArticles": ApiOperation(
            operationId: "listArticles",
            method: "GET",
            pathTemplate: "/v1/articles",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getArticle": ApiOperation(
            operationId: "getArticle",
            method: "GET",
            pathTemplate: "/v1/articles/{article_id}",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30701],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "checkAppVersion": ApiOperation(
            operationId: "checkAppVersion",
            method: "GET",
            pathTemplate: "/v1/app-versions/check",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "previewPage": ApiOperation(
            operationId: "previewPage",
            method: "GET",
            pathTemplate: "/v1/pages/{page_key}/preview",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30701],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getMessage": ApiOperation(
            operationId: "getMessage",
            method: "GET",
            pathTemplate: "/v1/messages/{message_id}",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30701],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getWalletSummary": ApiOperation(
            operationId: "getWalletSummary",
            method: "GET",
            pathTemplate: "/v1/wallet/summary",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getEarningsSummary": ApiOperation(
            operationId: "getEarningsSummary",
            method: "GET",
            pathTemplate: "/v1/earnings/summary",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30701],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "listWalletLedger": ApiOperation(
            operationId: "listWalletLedger",
            method: "GET",
            pathTemplate: "/v1/wallet/ledger",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getWithdrawRules": ApiOperation(
            operationId: "getWithdrawRules",
            method: "GET",
            pathTemplate: "/v1/withdrawals/rules",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "listWithdrawals": ApiOperation(
            operationId: "listWithdrawals",
            method: "GET",
            pathTemplate: "/v1/withdrawals",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "createWithdrawal": ApiOperation(
            operationId: "createWithdrawal",
            method: "POST",
            pathTemplate: "/v1/withdrawals",
            auth: "realname",
            signed: true,
            idempotent: true,
            stepUp: "withdraw",
            errorCodes: [10004, 10005, 30301, 30302, 30303, 30304, 30305, 30306, 30307, 30309, 10003, 20903, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "getWithdrawal": ApiOperation(
            operationId: "getWithdrawal",
            method: "GET",
            pathTemplate: "/v1/withdrawals/{withdrawal_id}",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30701],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getMe": ApiOperation(
            operationId: "getMe",
            method: "GET",
            pathTemplate: "/v1/me",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "bindPhone": ApiOperation(
            operationId: "bindPhone",
            method: "POST",
            pathTemplate: "/v1/me/phone",
            auth: "login",
            signed: true,
            idempotent: true,
            stepUp: "phone_change",
            errorCodes: [20001, 20002, 20003, 30411, 30414, 44001, 10003, 20903, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "getPayoutAccount": ApiOperation(
            operationId: "getPayoutAccount",
            method: "GET",
            pathTemplate: "/v1/me/payout-account",
            auth: "realname",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30304],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "savePayoutAccount": ApiOperation(
            operationId: "savePayoutAccount",
            method: "PUT",
            pathTemplate: "/v1/me/payout-account",
            auth: "realname",
            signed: true,
            idempotent: true,
            stepUp: "payout_account_change",
            errorCodes: [30303, 30304, 30307, 30308, 10003, 20903, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "getTips": ApiOperation(
            operationId: "getTips",
            method: "GET",
            pathTemplate: "/v1/me/tips",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "markTipRead": ApiOperation(
            operationId: "markTipRead",
            method: "POST",
            pathTemplate: "/v1/me/tips/{tip_key}/read",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "resetTip": ApiOperation(
            operationId: "resetTip",
            method: "DELETE",
            pathTemplate: "/v1/me/tips/{tip_key}",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "getDeletion": ApiOperation(
            operationId: "getDeletion",
            method: "GET",
            pathTemplate: "/v1/me/deletion",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "requestDeletion": ApiOperation(
            operationId: "requestDeletion",
            method: "POST",
            pathTemplate: "/v1/me/deletion",
            auth: "login",
            signed: true,
            idempotent: true,
            stepUp: "account_deletion",
            errorCodes: [30412, 30416, 10003, 20903],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: true
        ),
        "cancelDeletion": ApiOperation(
            operationId: "cancelDeletion",
            method: "POST",
            pathTemplate: "/v1/me/deletion/cancel",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [10007],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .exempt,
            planned: true
        ),
        "listAppeals": ApiOperation(
            operationId: "listAppeals",
            method: "GET",
            pathTemplate: "/v1/me/appeals",
            auth: "login",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "submitAppeal": ApiOperation(
            operationId: "submitAppeal",
            method: "POST",
            pathTemplate: "/v1/me/appeals",
            auth: "login",
            signed: false,
            idempotent: true,
            stepUp: nil,
            errorCodes: [20001, 30701, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: false
        ),
        "abandonIdempotencyKey": ApiOperation(
            operationId: "abandonIdempotencyKey",
            method: "POST",
            pathTemplate: "/v1/idempotency-keys/abandon",
            auth: "login",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 40901, 10405],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .conditional,
            planned: false
        ),
        "getConfig": ApiOperation(
            operationId: "getConfig",
            method: "GET",
            pathTemplate: "/v1/config",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [],
            sessionScopes: ["full", "deletion_only"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "searchProducts": ApiOperation(
            operationId: "searchProducts",
            method: "GET",
            pathTemplate: "/v1/products/search",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [50304],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "getProduct": ApiOperation(
            operationId: "getProduct",
            method: "GET",
            pathTemplate: "/v1/products/{product_key}",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30141, 30143],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "parseInput": ApiOperation(
            operationId: "parseInput",
            method: "POST",
            pathTemplate: "/v1/inputs/parse",
            auth: "optional",
            signed: true,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30131, 30132, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: false
        ),
        "openLink": ApiOperation(
            operationId: "openLink",
            method: "POST",
            pathTemplate: "/v1/links/{link_id}/open",
            auth: "optional",
            signed: true,
            idempotent: true,
            stepUp: nil,
            errorCodes: [10001, 30101, 30102, 30103, 30111, 30121, 30141, 30143, 30144, 30151, 30153, 50301, 50303, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: false
        ),
        "convertLink": ApiOperation(
            operationId: "convertLink",
            method: "POST",
            pathTemplate: "/v1/links/convert",
            auth: "login",
            signed: true,
            idempotent: true,
            stepUp: nil,
            errorCodes: [30101, 30102, 30103, 30111, 30121, 30131, 30141, 30143, 30151, 30153, 50301, 50303, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: false
        ),
        "getLink": ApiOperation(
            operationId: "getLink",
            method: "GET",
            pathTemplate: "/v1/links/{link_id}",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30144],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: false
        ),
        "getSharePage": ApiOperation(
            operationId: "getSharePage",
            method: "GET",
            pathTemplate: "/v1/share-pages/{link_id}",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30102, 30111, 30144],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "getShareTpwd": ApiOperation(
            operationId: "getShareTpwd",
            method: "POST",
            pathTemplate: "/v1/share-pages/{link_id}/tpwd",
            auth: "none",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [20001, 42901],
            sessionScopes: ["full"],
            minVersionGate: .exempt,
            planned: true
        ),
        "createAgentSession": ApiOperation(
            operationId: "createAgentSession",
            method: "POST",
            pathTemplate: "/v1/agent/sessions",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "getCurrentAgentSession": ApiOperation(
            operationId: "getCurrentAgentSession",
            method: "GET",
            pathTemplate: "/v1/agent/sessions/current",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "listAgentSessionMessages": ApiOperation(
            operationId: "listAgentSessionMessages",
            method: "GET",
            pathTemplate: "/v1/agent/sessions/{id}/messages",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004, 30504],
            sessionScopes: ["full"],
            minVersionGate: .unspecified,
            planned: true
        ),
        "sendAgentMessage": ApiOperation(
            operationId: "sendAgentMessage",
            method: "POST",
            pathTemplate: "/v1/agent/sessions/{id}/messages",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004, 30504, 20001, 30506, 30502, 50302, 10405, 42901, 50001, 50401],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "cancelAgentRun": ApiOperation(
            operationId: "cancelAgentRun",
            method: "POST",
            pathTemplate: "/v1/agent/runs/{run_id}/cancel",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004, 30505, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "setAgentMessageFeedback": ApiOperation(
            operationId: "setAgentMessageFeedback",
            method: "POST",
            pathTemplate: "/v1/agent/messages/{message_id}/feedback",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004, 30504, 20001, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
        "reportAgentMessage": ApiOperation(
            operationId: "reportAgentMessage",
            method: "POST",
            pathTemplate: "/v1/agent/messages/{message_id}/report",
            auth: "optional",
            signed: false,
            idempotent: false,
            stepUp: nil,
            errorCodes: [30501, 10001, 10005, 10004, 30504, 20001, 10405],
            sessionScopes: ["full"],
            minVersionGate: .gated,
            planned: true
        ),
    ]

    public static func byId(_ operationId: Swift.String) -> ApiOperation? {
        all[operationId]
    }
}
