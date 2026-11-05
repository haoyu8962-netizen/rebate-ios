// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/pay.json

/// 契约枚举 `pay_channel`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayChannel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case wechatPay = "wechat_pay"
    case alipay
    case unknown = "__unknown__"

    public static let allCases: [PayChannel] = [
        .wechatPay,
        .alipay,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayChannel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_order_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayOrderStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending = "PENDING"
    case paid = "PAID"
    case closed = "CLOSED"
    case unknown = "__unknown__"

    public static let allCases: [PayOrderStatus] = [
        .pending,
        .paid,
        .closed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayOrderStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_refund_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayRefundStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case processing = "PROCESSING"
    case success = "SUCCESS"
    case failed = "FAILED"
    case unknown = "__unknown__"

    public static let allCases: [PayRefundStatus] = [
        .processing,
        .success,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayRefundStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_refund_target_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayRefundTargetType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case payOrder = "pay_order"
    case payAnomaly = "pay_anomaly"
    case unknown = "__unknown__"

    public static let allCases: [PayRefundTargetType] = [
        .payOrder,
        .payAnomaly,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayRefundTargetType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_query_attempt_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayQueryAttemptKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case query
    case close
    case refund
    case refundQuery = "refund_query"
    case unknown = "__unknown__"

    public static let allCases: [PayQueryAttemptKind] = [
        .query,
        .close,
        .refund,
        .refundQuery,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayQueryAttemptKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_ledger_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayLedgerType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case payReceipt = "PAY_RECEIPT"
    case payRefund = "PAY_REFUND"
    case payAnomaly = "PAY_ANOMALY"
    case payFee = "PAY_FEE"
    case unknown = "__unknown__"

    public static let allCases: [PayLedgerType] = [
        .payReceipt,
        .payRefund,
        .payAnomaly,
        .payFee,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayLedgerType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_refund_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayRefundReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case userRequest = "USER_REQUEST"
    case duplicatePayment = "DUPLICATE_PAYMENT"
    case anomalyReceipt = "ANOMALY_RECEIPT"
    case reconDiff = "RECON_DIFF"
    case other = "OTHER"
    case unknown = "__unknown__"

    public static let allCases: [PayRefundReason] = [
        .userRequest,
        .duplicatePayment,
        .anomalyReceipt,
        .reconDiff,
        .other,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayRefundReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pay_unavailable_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayUnavailableReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case payDisabled = "pay_disabled"
    case channelDisabled = "channel_disabled"
    case platformNotAllowed = "platform_not_allowed"
    case bizNotSellable = "biz_not_sellable"
    case unknown = "__unknown__"

    public static let allCases: [PayUnavailableReason] = [
        .payDisabled,
        .channelDisabled,
        .platformNotAllowed,
        .bizNotSellable,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayUnavailableReason(rawValue: rawValue) ?? .unknown
    }
}
