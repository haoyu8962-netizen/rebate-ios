// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/admin.json

/// 契约枚举 `admin_permission`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AdminPermission: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
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
