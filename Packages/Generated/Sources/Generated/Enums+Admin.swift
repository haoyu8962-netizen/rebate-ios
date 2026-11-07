// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/admin.json

/// 契约枚举 `admin_permission`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminPermission: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case dashboardView = "dashboard.view"
    case userList = "user.list"
    case userLookup = "user.lookup"
    case piiRevealPhone = "pii.reveal_phone"
    case piiRevealIdentity = "pii.reveal_identity"
    case fundView = "fund.view"
    case auditViewAll = "audit.view_all"
    case export
    case contentPage = "content.page"
    case contentPool = "content.pool"
    case contentArticle = "content.article"
    case contentAgreement = "content.agreement"
    case contentPoster = "content.poster"
    case contentAppVersion = "content.app_version"
    case contentFundTerms = "content.fund_terms"
    case contentPlatformIcon = "content.platform_icon"
    case notifyChannels = "notify.channels"
    case configGeneral = "config.general"
    case configRisk = "config.risk"
    case configBusiness = "config.business"
    case switchAll = "switch.all"
    case switchPayout = "switch.payout"
    case switchPay = "switch.pay"
    case riskFreeze = "risk.freeze"
    case riskBan = "risk.ban"
    case riskBlocklist = "risk.blocklist"
    case riskAppeal = "risk.appeal"
    case unionBindingReset = "union.binding_reset"
    case unionBindingDisable = "union.binding_disable"
    case unionAccountAuth = "union.account_auth"
    case unionPid = "union.pid"
    case userLevel = "user.level"
    case userInviter = "user.inviter"
    case userRealnameFix = "user.realname_fix"
    case userPhoneChange = "user.phone_change"
    case userDataExport = "user.data_export"
    case orderView = "order.view"
    case orderClaim = "order.claim"
    case orderAssign = "order.assign"
    case orderHold = "order.hold"
    case orderRestore = "order.restore"
    case withdrawReview = "withdraw.review"
    case payoutExecute = "payout.execute"
    case payView = "pay.view"
    case payRefund = "pay.refund"
    case payResolve = "pay.resolve"
    case payoutManualEntry = "payout.manual_entry"
    case settleBill = "settle.bill"
    case settleStatementUpload = "settle.statement_upload"
    case fundAdjust = "fund.adjust"
    case fundWriteoff = "fund.writeoff"
    case fundSettleAdjust = "fund.settle_adjust"
    case fundRecon = "fund.recon"
    case fundCashEntry = "fund.cash_entry"
    case taxExportFull = "tax.export_full"
    case agentTrace = "agent.trace"
    case agentReport = "agent.report"
    case unknown = "__unknown__"

    public static let allCases: [AdminPermission] = [
        .dashboardView,
        .userList,
        .userLookup,
        .piiRevealPhone,
        .piiRevealIdentity,
        .fundView,
        .auditViewAll,
        .export,
        .contentPage,
        .contentPool,
        .contentArticle,
        .contentAgreement,
        .contentPoster,
        .contentAppVersion,
        .contentFundTerms,
        .contentPlatformIcon,
        .notifyChannels,
        .configGeneral,
        .configRisk,
        .configBusiness,
        .switchAll,
        .switchPayout,
        .switchPay,
        .riskFreeze,
        .riskBan,
        .riskBlocklist,
        .riskAppeal,
        .unionBindingReset,
        .unionBindingDisable,
        .unionAccountAuth,
        .unionPid,
        .userLevel,
        .userInviter,
        .userRealnameFix,
        .userPhoneChange,
        .userDataExport,
        .orderView,
        .orderClaim,
        .orderAssign,
        .orderHold,
        .orderRestore,
        .withdrawReview,
        .payoutExecute,
        .payView,
        .payRefund,
        .payResolve,
        .payoutManualEntry,
        .settleBill,
        .settleStatementUpload,
        .fundAdjust,
        .fundWriteoff,
        .fundSettleAdjust,
        .fundRecon,
        .fundCashEntry,
        .taxExportFull,
        .agentTrace,
        .agentReport,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminPermission(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_step_up_tier`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminStepUpTier: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case totp
    case sms
    case unknown = "__unknown__"

    public static let allCases: [AdminStepUpTier] = [
        .totp,
        .sms,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminStepUpTier(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_login_step`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminLoginStep: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case totp
    case changePassword = "change_password"
    case bindTotp = "bind_totp"
    case unknown = "__unknown__"

    public static let allCases: [AdminLoginStep] = [
        .totp,
        .changePassword,
        .bindTotp,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminLoginStep(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_account_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminAccountStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case active
    case disabled
    case unknown = "__unknown__"

    public static let allCases: [AdminAccountStatus] = [
        .active,
        .disabled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminAccountStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_auth_level`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminAuthLevel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case none
    case admin
    case `super`
    case unknown = "__unknown__"

    public static let allCases: [AdminAuthLevel] = [
        .none,
        .admin,
        .`super`,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminAuthLevel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_dashboard_todo_key`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminDashboardTodoKey: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case withdrawReviewPending = "withdraw_review_pending"
    case claimReviewPending = "claim_review_pending"
    case settleBillPending = "settle_bill_pending"
    case reconDiffOpen = "recon_diff_open"
    case appealPending = "appeal_pending"
    case agentReportOverdue = "agent_report_overdue"
    case beneficiaryHeldOverdue = "beneficiary_held_overdue"
    case unionAuthExpiring = "union_auth_expiring"
    case unknown = "__unknown__"

    public static let allCases: [AdminDashboardTodoKey] = [
        .withdrawReviewPending,
        .claimReviewPending,
        .settleBillPending,
        .reconDiffOpen,
        .appealPending,
        .agentReportOverdue,
        .beneficiaryHeldOverdue,
        .unionAuthExpiring,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminDashboardTodoKey(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_search_hit_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminSearchHitType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case order
    case user
    case withdrawal
    case unknown = "__unknown__"

    public static let allCases: [AdminSearchHitType] = [
        .order,
        .user,
        .withdrawal,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminSearchHitType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `export_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ExportStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending
    case running
    case done
    case failed
    case expired
    case cancelled
    case unknown = "__unknown__"

    public static let allCases: [ExportStatus] = [
        .pending,
        .running,
        .done,
        .failed,
        .expired,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ExportStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `export_resource`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ExportResource: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case users
    case auditLogs = "audit_logs"
    case taxWithdrawals = "tax_withdrawals"
    case unknown = "__unknown__"

    public static let allCases: [ExportResource] = [
        .users,
        .auditLogs,
        .taxWithdrawals,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ExportResource(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `audit_actor_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AuditActorKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case admin
    case system
    case unknown = "__unknown__"

    public static let allCases: [AuditActorKind] = [
        .admin,
        .system,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AuditActorKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `audit_system_actor`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AuditSystemActor: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case systemRisk = "system:risk"
    case systemPayout = "system:payout"
    case unknown = "__unknown__"

    public static let allCases: [AuditSystemActor] = [
        .systemRisk,
        .systemPayout,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AuditSystemActor(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_claim_match_field`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminClaimMatchField: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case orderNo = "order_no"
    case paidDate = "paid_date"
    case unknown = "__unknown__"

    public static let allCases: [AdminClaimMatchField] = [
        .orderNo,
        .paidDate,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminClaimMatchField(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_order_flag`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminOrderFlag: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case locked
    case statusLocked = "status_locked"
    case rightsPending = "rights_pending"
    case hold
    case unknown = "__unknown__"

    public static let allCases: [AdminOrderFlag] = [
        .locked,
        .statusLocked,
        .rightsPending,
        .hold,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminOrderFlag(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_order_history_field`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminOrderHistoryField: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case platform
    case rebate
    case unknown = "__unknown__"

    public static let allCases: [AdminOrderHistoryField] = [
        .platform,
        .rebate,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminOrderHistoryField(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_order_history_source`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminOrderHistorySource: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case sync
    case admin
    case claim
    case system
    case unknown = "__unknown__"

    public static let allCases: [AdminOrderHistorySource] = [
        .sync,
        .admin,
        .claim,
        .system,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminOrderHistorySource(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `risk_rule_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RiskRuleStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case enabled
    case disabled
    case unknown = "__unknown__"

    public static let allCases: [RiskRuleStatus] = [
        .enabled,
        .disabled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RiskRuleStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `risk_action`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RiskAction: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pass
    case manualReview = "manual_review"
    case block
    case voidCommission = "void_commission"
    case unknown = "__unknown__"

    public static let allCases: [RiskAction] = [
        .pass,
        .manualReview,
        .block,
        .voidCommission,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RiskAction(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `union_auth_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UnionAuthStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case active
    case expiring
    case expired
    case unknown = "__unknown__"

    public static let allCases: [UnionAuthStatus] = [
        .active,
        .expiring,
        .expired,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UnionAuthStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `union_reauth_mode`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UnionReauthMode: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case oauth
    case manual
    case none
    case unknown = "__unknown__"

    public static let allCases: [UnionReauthMode] = [
        .oauth,
        .manual,
        .none,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UnionReauthMode(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_union_auth_session_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminUnionAuthSessionStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending
    case succeeded
    case failed
    case expired
    case unknown = "__unknown__"

    public static let allCases: [AdminUnionAuthSessionStatus] = [
        .pending,
        .succeeded,
        .failed,
        .expired,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminUnionAuthSessionStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `union_pid_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UnionPidStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending
    case active
    case retired
    case unknown = "__unknown__"

    public static let allCases: [UnionPidStatus] = [
        .pending,
        .active,
        .retired,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UnionPidStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `product_pool_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ProductPoolStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case active
    case disabled
    case unknown = "__unknown__"

    public static let allCases: [ProductPoolStatus] = [
        .active,
        .disabled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ProductPoolStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pool_item_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PoolItemStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case online
    case offline
    case unknown = "__unknown__"

    public static let allCases: [PoolItemStatus] = [
        .online,
        .offline,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PoolItemStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `notify_channel`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NotifyChannel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case inbox
    case push
    case sms
    case unknown = "__unknown__"

    public static let allCases: [NotifyChannel] = [
        .inbox,
        .push,
        .sms,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NotifyChannel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `sms_template_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SmsTemplateType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case verify
    case notice
    case unknown = "__unknown__"

    public static let allCases: [SmsTemplateType] = [
        .verify,
        .notice,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SmsTemplateType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `notify_sms_state`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NotifySmsState: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case disabled
    case enabled
    case enabledNotReady = "enabled_not_ready"
    case unknown = "__unknown__"

    public static let allCases: [NotifySmsState] = [
        .disabled,
        .enabled,
        .enabledNotReady,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NotifySmsState(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `notify_sms_test_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NotifySmsTestStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case accepted
    case failed
    case notSentNoVerifyPhone = "not_sent_no_verify_phone"
    case unknown = "__unknown__"

    public static let allCases: [NotifySmsTestStatus] = [
        .accepted,
        .failed,
        .notSentNoVerifyPhone,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NotifySmsTestStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_withdrawal_display_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminWithdrawalDisplayStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pendingReview = "pending_review"
    case pendingHandle = "pending_handle"
    case rejected
    case paidManual = "paid_manual"
    case paidAutoSystem = "paid_auto_system"
    case paidAutoReview = "paid_auto_review"
    case paying
    case failed
    case unknown = "__unknown__"

    public static let allCases: [AdminWithdrawalDisplayStatus] = [
        .pendingReview,
        .pendingHandle,
        .rejected,
        .paidManual,
        .paidAutoSystem,
        .paidAutoReview,
        .paying,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminWithdrawalDisplayStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_settle_supplement_outcome`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminSettleSupplementOutcome: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case generated
    case duplicate
    case unknown = "__unknown__"

    public static let allCases: [AdminSettleSupplementOutcome] = [
        .generated,
        .duplicate,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminSettleSupplementOutcome(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_recon_diff_outcome`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminReconDiffOutcome: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case union
    case ours
    case unknown = "__unknown__"

    public static let allCases: [AdminReconDiffOutcome] = [
        .union,
        .ours,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminReconDiffOutcome(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `admin_settle_bill_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminSettleBillStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case generating
    case issued
    case settled
    case settling
    case scheduled
    case unknown = "__unknown__"

    public static let allCases: [AdminSettleBillStatus] = [
        .generating,
        .issued,
        .settled,
        .settling,
        .scheduled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AdminSettleBillStatus(rawValue: rawValue) ?? .unknown
    }
}
