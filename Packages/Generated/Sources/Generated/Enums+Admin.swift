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
    case unknown = "__unknown__"

    public static let allCases: [ExportResource] = [
        .users,
        .auditLogs,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ExportResource(rawValue: rawValue) ?? .unknown
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
