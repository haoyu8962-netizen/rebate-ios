// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/fund.json

/// 契约枚举 `ledger_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum LedgerType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case rebateCredit = "REBATE_CREDIT"
    case shareCredit = "SHARE_CREDIT"
    case referralCredit = "REFERRAL_CREDIT"
    case clawback = "CLAWBACK"
    case settleAdjust = "SETTLE_ADJUST"
    case withdrawFreeze = "WITHDRAW_FREEZE"
    case withdrawPaid = "WITHDRAW_PAID"
    case withdrawReturn = "WITHDRAW_RETURN"
    case withdrawFee = "WITHDRAW_FEE"
    case taxWithhold = "TAX_WITHHOLD"
    case reward = "REWARD"
    case adminAdjust = "ADMIN_ADJUST"
    case badDebtWriteoff = "BAD_DEBT_WRITEOFF"
    case unknown = "__unknown__"

    public static let allCases: [LedgerType] = [
        .rebateCredit,
        .shareCredit,
        .referralCredit,
        .clawback,
        .settleAdjust,
        .withdrawFreeze,
        .withdrawPaid,
        .withdrawReturn,
        .withdrawFee,
        .taxWithhold,
        .reward,
        .adminAdjust,
        .badDebtWriteoff,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = LedgerType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `referral_credit_sub_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ReferralCreditSubType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case direct = "DIRECT"
    case indirect = "INDIRECT"
    case unknown = "__unknown__"

    public static let allCases: [ReferralCreditSubType] = [
        .direct,
        .indirect,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ReferralCreditSubType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `clawback_sub_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ClawbackSubType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case full = "FULL"
    case partRefund = "PART_REFUND"
    case rights = "RIGHTS"
    case punish = "PUNISH"
    case unknown = "__unknown__"

    public static let allCases: [ClawbackSubType] = [
        .full,
        .partRefund,
        .rights,
        .punish,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ClawbackSubType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `settle_adjust_sub_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SettleAdjustSubType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case settleDiff = "SETTLE_DIFF"
    case priceCompare = "PRICE_COMPARE"
    case priceProtect = "PRICE_PROTECT"
    case unknown = "__unknown__"

    public static let allCases: [SettleAdjustSubType] = [
        .settleDiff,
        .priceCompare,
        .priceProtect,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SettleAdjustSubType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `reward_sub_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RewardSubType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case newbie
    case checkin
    case invite
    case unknown = "__unknown__"

    public static let allCases: [RewardSubType] = [
        .newbie,
        .checkin,
        .invite,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RewardSubType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_adjust_sub_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminAdjustSubType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case restore = "RESTORE"
    case reconFix = "RECON_FIX"
    case payoutRecovery = "PAYOUT_RECOVERY"
    case accountClosed = "ACCOUNT_CLOSED"
    case other = "OTHER"
    case unknown = "__unknown__"

    public static let allCases: [AdminAdjustSubType] = [
        .restore,
        .reconFix,
        .payoutRecovery,
        .accountClosed,
        .other,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminAdjustSubType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `beneficiary_role`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BeneficiaryRole: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case contractSelf = "self"
    case share
    case direct
    case indirect
    case unknown = "__unknown__"

    public static let allCases: [BeneficiaryRole] = [
        .contractSelf,
        .share,
        .direct,
        .indirect,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BeneficiaryRole(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `forfeit_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ForfeitReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case banned
    case deleted
    case minor
    case unknown = "__unknown__"

    public static let allCases: [ForfeitReason] = [
        .banned,
        .deleted,
        .minor,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ForfeitReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `commission_rule_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum CommissionRuleStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case draft
    case published
    case revoked
    case unknown = "__unknown__"

    public static let allCases: [CommissionRuleStatus] = [
        .draft,
        .published,
        .revoked,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = CommissionRuleStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `income_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum IncomeType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case serviceFee = "SERVICE_FEE"
    case incidental = "INCIDENTAL"
    case unknown = "__unknown__"

    public static let allCases: [IncomeType] = [
        .serviceFee,
        .incidental,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = IncomeType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdrawal_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawalStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pendingReview = "PENDING_REVIEW"
    case approved = "APPROVED"
    case rejected = "REJECTED"
    case paying = "PAYING"
    case paidApi = "PAID_API"
    case paidManual = "PAID_MANUAL"
    case failed = "FAILED"
    case unknown = "__unknown__"

    public static let allCases: [WithdrawalStatus] = [
        .pendingReview,
        .approved,
        .rejected,
        .paying,
        .paidApi,
        .paidManual,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawalStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdraw_reject_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawRejectReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case riskSuspect = "RISK_SUSPECT"
    case orderAbnormal = "ORDER_ABNORMAL"
    case payeeInfoInvalid = "PAYEE_INFO_INVALID"
    case userRequest = "USER_REQUEST"
    case other = "OTHER"
    case negativeBalance = "NEGATIVE_BALANCE"
    case unknown = "__unknown__"

    public static let allCases: [WithdrawRejectReason] = [
        .riskSuspect,
        .orderAbnormal,
        .payeeInfoInvalid,
        .userRequest,
        .other,
        .negativeBalance,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawRejectReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdrawal_hold_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawalHoldReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case payoutDisabled = "payout_disabled"
    case queuePaused = "queue_paused"
    case channelDisabled = "channel_disabled"
    case memberBlocked = "member_blocked"
    case singleCap = "single_cap"
    case dailyCap = "daily_cap"
    case payerSideAfterTransfer = "payer_side_after_transfer"
    case unknown = "__unknown__"

    public static let allCases: [WithdrawalHoldReason] = [
        .payoutDisabled,
        .queuePaused,
        .channelDisabled,
        .memberBlocked,
        .singleCap,
        .dailyCap,
        .payerSideAfterTransfer,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawalHoldReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdrawal_blocked_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawalBlockedReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case negativeBalance = "NEGATIVE_BALANCE"
    case unknown = "__unknown__"

    public static let allCases: [WithdrawalBlockedReason] = [
        .negativeBalance,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawalBlockedReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdrawal_manual_resolution`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawalManualResolution: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case paid
    case failed
    case unknown = "__unknown__"

    public static let allCases: [WithdrawalManualResolution] = [
        .paid,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawalManualResolution(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdraw_hold_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawHoldKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case manual
    case reconDiff = "recon_diff"
    case ledgerMismatch = "ledger_mismatch"
    case manualFailedWatch = "manual_failed_watch"
    case unknown = "__unknown__"

    public static let allCases: [WithdrawHoldKind] = [
        .manual,
        .reconDiff,
        .ledgerMismatch,
        .manualFailedWatch,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawHoldKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdrawal_review_mode`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawalReviewMode: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case auto
    case manual
    case unknown = "__unknown__"

    public static let allCases: [WithdrawalReviewMode] = [
        .auto,
        .manual,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawalReviewMode(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `payout_method`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayoutMethod: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case alipay
    case bankCard = "bank_card"
    case wechat
    case unknown = "__unknown__"

    public static let allCases: [PayoutMethod] = [
        .alipay,
        .bankCard,
        .wechat,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayoutMethod(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdrawal_channel_state`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawalChannelState: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case processing
    case waitUserConfirm = "wait_user_confirm"
    case canceling
    case unknown = "__unknown__"

    public static let allCases: [WithdrawalChannelState] = [
        .processing,
        .waitUserConfirm,
        .canceling,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawalChannelState(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `payout_attempt_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayoutAttemptKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case transfer
    case query
    case cancel
    case unknown = "__unknown__"

    public static let allCases: [PayoutAttemptKind] = [
        .transfer,
        .query,
        .cancel,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayoutAttemptKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `withdraw_condition_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum WithdrawConditionReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case accountFrozen = "account_frozen"
    case belowMin = "below_min"
    case notMultiple = "not_multiple"
    case aboveMax = "above_max"
    case aboveMethodMax = "above_method_max"
    case netTooSmall = "net_too_small"
    case dailyCount = "daily_count"
    case monthlyCount = "monthly_count"
    case payeeDailyCount = "payee_daily_count"
    case payeeDailyUsers = "payee_daily_users"
    case selfPurchaseRequired = "self_purchase_required"
    case payoutAccountChangeLimit = "payout_account_change_limit"
    case payoutAccountVerifyLimit = "payout_account_verify_limit"
    case unknown = "__unknown__"

    public static let allCases: [WithdrawConditionReason] = [
        .accountFrozen,
        .belowMin,
        .notMultiple,
        .aboveMax,
        .aboveMethodMax,
        .netTooSmall,
        .dailyCount,
        .monthlyCount,
        .payeeDailyCount,
        .payeeDailyUsers,
        .selfPurchaseRequired,
        .payoutAccountChangeLimit,
        .payoutAccountVerifyLimit,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = WithdrawConditionReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `payout_batch_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayoutBatchKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case manual
    case auto
    case unknown = "__unknown__"

    public static let allCases: [PayoutBatchKind] = [
        .manual,
        .auto,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayoutBatchKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `bad_debt_writeoff_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BadDebtWriteoffStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case cancelled = "CANCELLED"
    case unknown = "__unknown__"

    public static let allCases: [BadDebtWriteoffStatus] = [
        .pending,
        .approved,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BadDebtWriteoffStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `settle_batch_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SettleBatchStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case draft = "DRAFT"
    case confirmed = "CONFIRMED"
    case executing = "EXECUTING"
    case partial = "PARTIAL"
    case done = "DONE"
    case cancelled = "CANCELLED"
    case unknown = "__unknown__"

    public static let allCases: [SettleBatchStatus] = [
        .draft,
        .confirmed,
        .executing,
        .partial,
        .done,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SettleBatchStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `settle_mode`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SettleMode: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case immediate = "IMMEDIATE"
    case scheduled = "SCHEDULED"
    case unknown = "__unknown__"

    public static let allCases: [SettleMode] = [
        .immediate,
        .scheduled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SettleMode(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `settle_batch_item_result`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SettleBatchItemResult: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case credited
    case skipped
    case deferred
    case unknown = "__unknown__"

    public static let allCases: [SettleBatchItemResult] = [
        .credited,
        .skipped,
        .deferred,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SettleBatchItemResult(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `settle_batch_item_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SettleBatchItemType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case order
    case beneficiary
    case unknown = "__unknown__"

    public static let allCases: [SettleBatchItemType] = [
        .order,
        .beneficiary,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SettleBatchItemType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `settle_adjustment_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SettleAdjustmentStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending
    case approved
    case rejected
    case voidedStaleSeq = "voided_stale_seq"
    case voidedByClawback = "voided_by_clawback"
    case unknown = "__unknown__"

    public static let allCases: [SettleAdjustmentStatus] = [
        .pending,
        .approved,
        .rejected,
        .voidedStaleSeq,
        .voidedByClawback,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SettleAdjustmentStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `beneficiary_credit_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BeneficiaryCreditKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case firstCredit = "first_credit"
    case reassignCredit = "reassign_credit"
    case deferred
    case unknown = "__unknown__"

    public static let allCases: [BeneficiaryCreditKind] = [
        .firstCredit,
        .reassignCredit,
        .deferred,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BeneficiaryCreditKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `beneficiary_credit_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BeneficiaryCreditStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case `open`
    case done
    case forfeited
    case voided
    case unknown = "__unknown__"

    public static let allCases: [BeneficiaryCreditStatus] = [
        .`open`,
        .done,
        .forfeited,
        .voided,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BeneficiaryCreditStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `recon_diff_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ReconDiffType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case unionMismatch = "union_mismatch"
    case channelMismatch = "channel_mismatch"
    case ledgerMismatch = "ledger_mismatch"
    case platformRestore = "platform_restore"
    case monthEndUnbalanced = "month_end_unbalanced"
    case settleAmountMismatch = "settle_amount_mismatch"
    case settleMissing = "settle_missing"
    case appealRestore = "appeal_restore"
    case estimateChangedAfterCredit = "estimate_changed_after_credit"
    case unknown = "__unknown__"

    public static let allCases: [ReconDiffType] = [
        .unionMismatch,
        .channelMismatch,
        .ledgerMismatch,
        .platformRestore,
        .monthEndUnbalanced,
        .settleAmountMismatch,
        .settleMissing,
        .appealRestore,
        .estimateChangedAfterCredit,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ReconDiffType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `payout_batch_item_result`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PayoutBatchItemResult: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case paying
    case skipped
    case blocked
    case movedOut = "moved_out"
    case unknown = "__unknown__"

    public static let allCases: [PayoutBatchItemResult] = [
        .paying,
        .skipped,
        .blocked,
        .movedOut,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PayoutBatchItemResult(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `recon_diff_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ReconDiffStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case `open`
    case processing
    case adjusted
    case writtenOff = "written_off"
    case closed
    case unknown = "__unknown__"

    public static let allCases: [ReconDiffStatus] = [
        .`open`,
        .processing,
        .adjusted,
        .writtenOff,
        .closed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ReconDiffStatus(rawValue: rawValue) ?? .unknown
    }
}
