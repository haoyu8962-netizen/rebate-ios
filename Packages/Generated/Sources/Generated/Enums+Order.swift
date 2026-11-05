// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/order.json

/// 契约枚举 `platform_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PlatformStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case depositPaid = "DEPOSIT_PAID"
    case paid = "PAID"
    case received = "RECEIVED"
    case settled = "SETTLED"
    case invalid = "INVALID"
    case unknown = "__unknown__"

    public static let allCases: [PlatformStatus] = [
        .depositPaid,
        .paid,
        .received,
        .settled,
        .invalid,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PlatformStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `rebate_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RebateStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case unattributed = "UNATTRIBUTED"
    case estimated = "ESTIMATED"
    case waiting = "WAITING"
    case credited = "CREDITED"
    case void = "VOID"
    case clawedBack = "CLAWED_BACK"
    case unknown = "__unknown__"

    public static let allCases: [RebateStatus] = [
        .unattributed,
        .estimated,
        .waiting,
        .credited,
        .void,
        .clawedBack,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RebateStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `display_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum DisplayStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case paid = "PAID"
    case depositPaid = "DEPOSIT_PAID"
    case waiting = "WAITING"
    case crediting = "CREDITING"
    case reviewing = "REVIEWING"
    case rightsPending = "RIGHTS_PENDING"
    case credited = "CREDITED"
    case creditedPartClawed = "CREDITED_PART_CLAWED"
    case noRebate = "NO_REBATE"
    case invalid = "INVALID"
    case clawedBack = "CLAWED_BACK"
    case unknown = "__unknown__"

    public static let allCases: [DisplayStatus] = [
        .paid,
        .depositPaid,
        .waiting,
        .crediting,
        .reviewing,
        .rightsPending,
        .credited,
        .creditedPartClawed,
        .noRebate,
        .invalid,
        .clawedBack,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = DisplayStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_hold_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderHoldReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case risk = "RISK"
    case cs = "CS"
    case unmappedStatus = "UNMAPPED_STATUS"
    case unknown = "__unknown__"

    public static let allCases: [OrderHoldReason] = [
        .risk,
        .cs,
        .unmappedStatus,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderHoldReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_status_group`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderStatusGroup: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case all
    case estimating
    case credited
    case noRebate = "no_rebate"
    case unknown = "__unknown__"

    public static let allCases: [OrderStatusGroup] = [
        .all,
        .estimating,
        .credited,
        .noRebate,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderStatusGroup(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_timeline_node`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderTimelineNode: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case depositPaid = "deposit_paid"
    case paid
    case finalPaid = "final_paid"
    case received
    case creditExpected = "credit_expected"
    case credited
    case invalid
    case clawedBack = "clawed_back"
    case partClawedBack = "part_clawed_back"
    case unknown = "__unknown__"

    public static let allCases: [OrderTimelineNode] = [
        .depositPaid,
        .paid,
        .finalPaid,
        .received,
        .creditExpected,
        .credited,
        .invalid,
        .clawedBack,
        .partClawedBack,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderTimelineNode(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case refund = "REFUND"
    case rights = "RIGHTS"
    case punish = "PUNISH"
    case presaleUnpaid = "PRESALE_UNPAID"
    case commissionZero = "COMMISSION_ZERO"
    case other = "OTHER"
    case blacklist = "BLACKLIST"
    case partRefund = "PART_REFUND"
    case priceCompare = "PRICE_COMPARE"
    case priceProtect = "PRICE_PROTECT"
    case settleDiff = "SETTLE_DIFF"
    case notTracked = "NOT_TRACKED"
    case expiredClick = "EXPIRED_CLICK"
    case otherTlj = "OTHER_TLJ"
    case relationInvalid = "RELATION_INVALID"
    case cancelled = "CANCELLED"
    case unknown = "__unknown__"

    public static let allCases: [OrderReason] = [
        .refund,
        .rights,
        .punish,
        .presaleUnpaid,
        .commissionZero,
        .other,
        .blacklist,
        .partRefund,
        .priceCompare,
        .priceProtect,
        .settleDiff,
        .notTracked,
        .expiredClick,
        .otherTlj,
        .relationInvalid,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `diff_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum DiffReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case partRefund = "PART_REFUND"
    case priceCompare = "PRICE_COMPARE"
    case priceProtect = "PRICE_PROTECT"
    case settleDiff = "SETTLE_DIFF"
    case unknown = "__unknown__"

    public static let allCases: [DiffReason] = [
        .partRefund,
        .priceCompare,
        .priceProtect,
        .settleDiff,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = DiffReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_rights_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderRightsStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case processing = "PROCESSING"
    case waitCommission = "WAIT_COMMISSION"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case unknown = "__unknown__"

    public static let allCases: [OrderRightsStatus] = [
        .processing,
        .waitCommission,
        .succeeded,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderRightsStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_rights_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderRightsType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case rights = "RIGHTS"
    case punish = "PUNISH"
    case invalidAfterSettle = "INVALID_AFTER_SETTLE"
    case refundAfterSettle = "REFUND_AFTER_SETTLE"
    case unknown = "__unknown__"

    public static let allCases: [OrderRightsType] = [
        .rights,
        .punish,
        .invalidAfterSettle,
        .refundAfterSettle,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderRightsType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `claim_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ClaimStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case submitted
    case autoMatched = "auto_matched"
    case manualReview = "manual_review"
    case approved
    case rejected
    case cancelled
    case unknown = "__unknown__"

    public static let allCases: [ClaimStatus] = [
        .submitted,
        .autoMatched,
        .manualReview,
        .approved,
        .rejected,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ClaimStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `claim_evidence_level`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ClaimEvidenceLevel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case strong
    case weak
    case none
    case unknown = "__unknown__"

    public static let allCases: [ClaimEvidenceLevel] = [
        .strong,
        .weak,
        .none,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ClaimEvidenceLevel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `claim_item_decision`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ClaimItemDecision: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case approved
    case rejected
    case cancelled
    case unknown = "__unknown__"

    public static let allCases: [ClaimItemDecision] = [
        .approved,
        .rejected,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ClaimItemDecision(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `claim_reject_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ClaimRejectReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case noEvidence = "NO_EVIDENCE"
    case expiredClick = "EXPIRED_CLICK"
    case notTracked = "NOT_TRACKED"
    case otherTlj = "OTHER_TLJ"
    case fraud = "FRAUD"
    case other = "OTHER"
    case notInPool = "NOT_IN_POOL"
    case orderInvalid = "ORDER_INVALID"
    case unknown = "__unknown__"

    public static let allCases: [ClaimRejectReason] = [
        .noEvidence,
        .expiredClick,
        .notTracked,
        .otherTlj,
        .fraud,
        .other,
        .notInPool,
        .orderInvalid,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ClaimRejectReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_sync_mode`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderSyncMode: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case window
    case orderNos = "order_nos"
    case unknown = "__unknown__"

    public static let allCases: [OrderSyncMode] = [
        .window,
        .orderNos,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderSyncMode(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `order_sync_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OrderSyncStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case queued
    case running
    case done
    case failed
    case unknown = "__unknown__"

    public static let allCases: [OrderSyncStatus] = [
        .queued,
        .running,
        .done,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OrderSyncStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `rights_import_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RightsImportKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case rights
    case punish
    case channel
    case unknown = "__unknown__"

    public static let allCases: [RightsImportKind] = [
        .rights,
        .punish,
        .channel,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RightsImportKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `rights_import_time_basis`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RightsImportTimeBasis: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case paid
    case received
    case unknown = "__unknown__"

    public static let allCases: [RightsImportTimeBasis] = [
        .paid,
        .received,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RightsImportTimeBasis(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `rights_import_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RightsImportStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case queued
    case running
    case done
    case failed
    case unknown = "__unknown__"

    public static let allCases: [RightsImportStatus] = [
        .queued,
        .running,
        .done,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RightsImportStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `rights_import_failure_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RightsImportFailureReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case invalidRow = "invalid_row"
    case orderNotFound = "order_not_found"
    case subOrderNoMissing = "sub_order_no_missing"
    case receivedAtMissing = "received_at_missing"
    case platformMismatch = "platform_mismatch"
    case unknown = "__unknown__"

    public static let allCases: [RightsImportFailureReason] = [
        .invalidRow,
        .orderNotFound,
        .subOrderNoMissing,
        .receivedAtMissing,
        .platformMismatch,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RightsImportFailureReason(rawValue: rawValue) ?? .unknown
    }
}
