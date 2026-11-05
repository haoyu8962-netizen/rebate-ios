// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/identity.json

/// 契约枚举 `identity_level`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum IdentityLevel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case basic
    case guest
    case member
    case phone
    case realname
    case unknown = "__unknown__"

    public static let allCases: [IdentityLevel] = [
        .basic,
        .guest,
        .member,
        .phone,
        .realname,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = IdentityLevel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `login_provider`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum LoginProvider: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case wechat
    case apple
    case huawei
    case unknown = "__unknown__"

    public static let allCases: [LoginProvider] = [
        .wechat,
        .apple,
        .huawei,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = LoginProvider(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `device_id_source`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum DeviceIdSource: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case idfv
    case androidId = "android_id"
    case oaid
    case odid
    case unknown = "__unknown__"

    public static let allCases: [DeviceIdSource] = [
        .idfv,
        .androidId,
        .oaid,
        .odid,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = DeviceIdSource(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `oauth_attempt_purpose`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum OauthAttemptPurpose: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case login
    case stepUp = "step_up"
    case payoutBind = "payout_bind"
    case reverify
    case unknown = "__unknown__"

    public static let allCases: [OauthAttemptPurpose] = [
        .login,
        .stepUp,
        .payoutBind,
        .reverify,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = OauthAttemptPurpose(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `reverify_method`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ReverifyMethod: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case idNumber = "id_number"
    case oauth
    case manual
    case unknown = "__unknown__"

    public static let allCases: [ReverifyMethod] = [
        .idNumber,
        .oauth,
        .manual,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ReverifyMethod(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `session_scope`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SessionScope: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case full
    case deletionOnly = "deletion_only"
    case unknown = "__unknown__"

    public static let allCases: [SessionScope] = [
        .full,
        .deletionOnly,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SessionScope(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `h5_token_scope`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum H5TokenScope: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case standard
    case readOnly = "read_only"
    case unknown = "__unknown__"

    public static let allCases: [H5TokenScope] = [
        .standard,
        .readOnly,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = H5TokenScope(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `sms_purpose`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SmsPurpose: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case login
    case bind
    case stepUp = "step_up"
    case unknown = "__unknown__"

    public static let allCases: [SmsPurpose] = [
        .login,
        .bind,
        .stepUp,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SmsPurpose(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `step_up_action`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum StepUpAction: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case withdraw
    case payoutAccountChange = "payout_account_change"
    case phoneChange = "phone_change"
    case accountDeletion = "account_deletion"
    case unknown = "__unknown__"

    public static let allCases: [StepUpAction] = [
        .withdraw,
        .payoutAccountChange,
        .phoneChange,
        .accountDeletion,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = StepUpAction(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `idempotency_abandon_outcome`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum IdempotencyAbandonOutcome: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case abandoned
    case completed
    case unknown = "__unknown__"

    public static let allCases: [IdempotencyAbandonOutcome] = [
        .abandoned,
        .completed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = IdempotencyAbandonOutcome(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `consent_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ConsentType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case privacy
    case agreement
    case aiThirdParty = "ai_third_party"
    case idVerification = "id_verification"
    case personalization
    case laborAgreement = "labor_agreement"
    case clipboardAutoImport = "clipboard_auto_import"
    case unknown = "__unknown__"

    public static let allCases: [ConsentType] = [
        .privacy,
        .agreement,
        .aiThirdParty,
        .idVerification,
        .personalization,
        .laborAgreement,
        .clipboardAutoImport,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ConsentType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `consent_channel`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ConsentChannel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case firstLaunch = "first_launch"
    case loginPage = "login_page"
    case h5Landing = "h5_landing"
    case agentSheet = "agent_sheet"
    case realnameSheet = "realname_sheet"
    case privacyCenter = "privacy_center"
    case loginMerge = "login_merge"
    case withdrawFlow = "withdraw_flow"
    case unknown = "__unknown__"

    public static let allCases: [ConsentChannel] = [
        .firstLaunch,
        .loginPage,
        .h5Landing,
        .agentSheet,
        .realnameSheet,
        .privacyCenter,
        .loginMerge,
        .withdrawFlow,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ConsentChannel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `auth_method`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AuthMethod: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case webCode = "web_code"
    case sdkToken = "sdk_token"
    case unknown = "__unknown__"

    public static let allCases: [AuthMethod] = [
        .webCode,
        .sdkToken,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AuthMethod(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `union_binding_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UnionBindingStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case unbound
    case pendingAuth = "pending_auth"
    case active
    case invalid
    case released
    case blocked
    case unknown = "__unknown__"

    public static let allCases: [UnionBindingStatus] = [
        .unbound,
        .pendingAuth,
        .active,
        .invalid,
        .released,
        .blocked,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UnionBindingStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `union_binding_blocked_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UnionBindingBlockedReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case ban
    case adminDisable = "admin_disable"
    case deletion
    case unknown = "__unknown__"

    public static let allCases: [UnionBindingBlockedReason] = [
        .ban,
        .adminDisable,
        .deletion,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UnionBindingBlockedReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `risk_state`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RiskState: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case normal
    case frozen
    case appealing
    case banned
    case unknown = "__unknown__"

    public static let allCases: [RiskState] = [
        .normal,
        .frozen,
        .appealing,
        .banned,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RiskState(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `risk_reason_category`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RiskReasonCategory: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case maliciousRights = "malicious_rights"
    case fraudInvite = "fraud_invite"
    case abnormalTrade = "abnormal_trade"
    case accountSecurity = "account_security"
    case other
    case unknown = "__unknown__"

    public static let allCases: [RiskReasonCategory] = [
        .maliciousRights,
        .fraudInvite,
        .abnormalTrade,
        .accountSecurity,
        .other,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RiskReasonCategory(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `realname_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RealnameStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case none
    case verified
    case failed
    case unknown = "__unknown__"

    public static let allCases: [RealnameStatus] = [
        .none,
        .verified,
        .failed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RealnameStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `deletion_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum DeletionStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case cooling
    case processing
    case done
    case cancelled
    case unknown = "__unknown__"

    public static let allCases: [DeletionStatus] = [
        .cooling,
        .processing,
        .done,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = DeletionStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `deletion_cancel_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum DeletionCancelReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case user
    case negativeBalance = "negative_balance"
    case unknown = "__unknown__"

    public static let allCases: [DeletionCancelReason] = [
        .user,
        .negativeBalance,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = DeletionCancelReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `tip_key`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum TipKey: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case jumpTip = "jump_tip"
    case inviterBeforeBuy = "inviter_before_buy"
    case unknown = "__unknown__"

    public static let allCases: [TipKey] = [
        .jumpTip,
        .inviterBeforeBuy,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = TipKey(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `appeal_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AppealStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case processing
    case upheld
    case revoked
    case unknown = "__unknown__"

    public static let allCases: [AppealStatus] = [
        .processing,
        .upheld,
        .revoked,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AppealStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `appeal_target_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AppealTargetType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case account
    case order
    case blockedRequest = "blocked_request"
    case unknown = "__unknown__"

    public static let allCases: [AppealTargetType] = [
        .account,
        .order,
        .blockedRequest,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AppealTargetType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `blocked_request_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BlockedRequestType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case register
    case withdraw
    case phoneChange = "phone_change"
    case payoutAccount = "payout_account"
    case unknown = "__unknown__"

    public static let allCases: [BlockedRequestType] = [
        .register,
        .withdraw,
        .phoneChange,
        .payoutAccount,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BlockedRequestType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `appeal_source`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AppealSource: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case app
    case admin
    case unknown = "__unknown__"

    public static let allCases: [AppealSource] = [
        .app,
        .admin,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AppealSource(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `blocked_request_cause`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BlockedRequestCause: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case blocklist
    case rule
    case unknown = "__unknown__"

    public static let allCases: [BlockedRequestCause] = [
        .blocklist,
        .rule,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BlockedRequestCause(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `blocklist_dimension`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BlocklistDimension: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case phone
    case idNo = "id_no"
    case alipay
    case bankCard = "bank_card"
    case wechatOpenid = "wechat_openid"
    case device
    case relationId = "relation_id"
    case orderNoSuffix = "order_no_suffix"
    case channel
    case unknown = "__unknown__"

    public static let allCases: [BlocklistDimension] = [
        .phone,
        .idNo,
        .alipay,
        .bankCard,
        .wechatOpenid,
        .device,
        .relationId,
        .orderNoSuffix,
        .channel,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BlocklistDimension(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `risk_hit_ref_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RiskHitRefType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case order
    case withdrawal
    case blockedRequest = "blocked_request"
    case inviteRelation = "invite_relation"
    case inviteReward = "invite_reward"
    case unknown = "__unknown__"

    public static let allCases: [RiskHitRefType] = [
        .order,
        .withdrawal,
        .blockedRequest,
        .inviteRelation,
        .inviteReward,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RiskHitRefType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `invite_reward_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InviteRewardStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case qualified
    case deferred
    case processed
    case voided
    case expired
    case unknown = "__unknown__"

    public static let allCases: [InviteRewardStatus] = [
        .qualified,
        .deferred,
        .processed,
        .voided,
        .expired,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InviteRewardStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `invite_reward_party_result`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InviteRewardPartyResult: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case granted
    case skipped
    case unknown = "__unknown__"

    public static let allCases: [InviteRewardPartyResult] = [
        .granted,
        .skipped,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InviteRewardPartyResult(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `invite_reward_skip_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InviteRewardSkipReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case sameDevice = "same_device"
    case sameIp = "same_ip"
    case deletedPhoneRetained = "deleted_phone_retained"
    case multiAccount = "multi_account"
    case riskRestricted = "risk_restricted"
    case deleting
    case minor
    case unknown = "__unknown__"

    public static let allCases: [InviteRewardSkipReason] = [
        .sameDevice,
        .sameIp,
        .deletedPhoneRetained,
        .multiAccount,
        .riskRestricted,
        .deleting,
        .minor,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InviteRewardSkipReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `invite_reward_void_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InviteRewardVoidReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case relationChanged = "relation_changed"
    case orderClawedBack = "order_clawed_back"
    case orderRights = "order_rights"
    case unknown = "__unknown__"

    public static let allCases: [InviteRewardVoidReason] = [
        .relationChanged,
        .orderClawedBack,
        .orderRights,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InviteRewardVoidReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `invite_reward_bind_source`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InviteRewardBindSource: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case landing
    case register
    case backfill
    case unknown = "__unknown__"

    public static let allCases: [InviteRewardBindSource] = [
        .landing,
        .register,
        .backfill,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InviteRewardBindSource(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `personal_data_copy_delivery`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PersonalDataCopyDelivery: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case inAppSms = "in_app_sms"
    case wecomSession = "wecom_session"
    case unknown = "__unknown__"

    public static let allCases: [PersonalDataCopyDelivery] = [
        .inAppSms,
        .wecomSession,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PersonalDataCopyDelivery(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `personal_data_copy_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PersonalDataCopyStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pending
    case running
    case ready
    case delivered
    case failed
    case expired
    case cancelled
    case unknown = "__unknown__"

    public static let allCases: [PersonalDataCopyStatus] = [
        .pending,
        .running,
        .ready,
        .delivered,
        .failed,
        .expired,
        .cancelled,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PersonalDataCopyStatus(rawValue: rawValue) ?? .unknown
    }
}
