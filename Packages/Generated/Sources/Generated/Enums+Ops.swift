// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/ops.json

/// 契约枚举 `notify_template_code`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NotifyTemplateCode: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case orderTracked = "ORDER_TRACKED"
    case orderInvalid = "ORDER_INVALID"
    case credited = "CREDITED"
    case clawback = "CLAWBACK"
    case wdSuccess = "WD_SUCCESS"
    case wdRejected = "WD_REJECTED"
    case wdFailed = "WD_FAILED"
    case wdOverdue = "WD_OVERDUE"
    case claimResult = "CLAIM_RESULT"
    case riskStateChanged = "RISK_STATE_CHANGED"
    case appealResult = "APPEAL_RESULT"
    case deletionProgress = "DELETION_PROGRESS"
    case balanceAdjusted = "BALANCE_ADJUSTED"
    case smsCode = "SMS_CODE"
    case unionAuthExpiring = "UNION_AUTH_EXPIRING"
    case unionAuthExpired = "UNION_AUTH_EXPIRED"
    case unknown = "__unknown__"

    public static let allCases: [NotifyTemplateCode] = [
        .orderTracked,
        .orderInvalid,
        .credited,
        .clawback,
        .wdSuccess,
        .wdRejected,
        .wdFailed,
        .wdOverdue,
        .claimResult,
        .riskStateChanged,
        .appealResult,
        .deletionProgress,
        .balanceAdjusted,
        .smsCode,
        .unionAuthExpiring,
        .unionAuthExpired,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NotifyTemplateCode(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `notify_category`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NotifyCategory: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case service
    case subscription
    case marketing
    case unknown = "__unknown__"

    public static let allCases: [NotifyCategory] = [
        .service,
        .subscription,
        .marketing,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NotifyCategory(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `user_level`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UserLevel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case l1 = "L1"
    case l2 = "L2"
    case l3 = "L3"
    case unknown = "__unknown__"

    public static let allCases: [UserLevel] = [
        .l1,
        .l2,
        .l3,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UserLevel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `agent_intent`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AgentIntent: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case findByLink = "find_by_link"
    case search
    case refine
    case orderQuery = "order_query"
    case ruleQa = "rule_qa"
    case handoff
    case clarify
    case outOfScope = "out_of_scope"
    case unknown = "__unknown__"

    public static let allCases: [AgentIntent] = [
        .findByLink,
        .search,
        .refine,
        .orderQuery,
        .ruleQa,
        .handoff,
        .clarify,
        .outOfScope,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AgentIntent(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `agent_card_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AgentCardType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case productList = "product_list"
    case rebateQuote = "rebate_quote"
    case orderStatus = "order_status"
    case claimDraft = "claim_draft"
    case handoff
    case authRequired = "auth_required"
    case notice
    case ruleRef = "rule_ref"
    case unknown = "__unknown__"

    public static let allCases: [AgentCardType] = [
        .productList,
        .rebateQuote,
        .orderStatus,
        .claimDraft,
        .handoff,
        .authRequired,
        .notice,
        .ruleRef,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AgentCardType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `agent_finish_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AgentFinishReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case stop
    case cancelled
    case limit
    case budget
    case error
    case authRequired = "auth_required"
    case safety
    case fallback
    case timeout
    case unknown = "__unknown__"

    public static let allCases: [AgentFinishReason] = [
        .stop,
        .cancelled,
        .limit,
        .budget,
        .error,
        .authRequired,
        .safety,
        .fallback,
        .timeout,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AgentFinishReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `watch_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WatchStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case active
    case paused
    case unavailable
    case expired
    case cancelled
    case unknown = "__unknown__"

    public static let allCases: [WatchStatus] = [
        .active,
        .paused,
        .unavailable,
        .expired,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WatchStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `watch_event_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WatchEventStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending
    case suppressed
    case sent
    case unknown = "__unknown__"

    public static let allCases: [WatchEventStatus] = [
        .pending,
        .suppressed,
        .sent,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WatchEventStatus(rawValue: rawValue) ?? .unknown
    }
}
