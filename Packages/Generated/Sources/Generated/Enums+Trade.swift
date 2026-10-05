// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/trade.json

/// 契约枚举 `scene`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ContractScene: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case search
    case detail
    case homeCard = "home_card"
    case feed
    case clipboard
    case agent
    case share
    case h5
    case push
    case taolijin
    case watchAlert = "watch_alert"
    case shareExt = "share_ext"
    case wechatBot = "wechat_bot"
    case mcp
    case unknown = "__unknown__"

    public static let allCases: [ContractScene] = [
        .search,
        .detail,
        .homeCard,
        .feed,
        .clipboard,
        .agent,
        .share,
        .h5,
        .push,
        .taolijin,
        .watchAlert,
        .shareExt,
        .wechatBot,
        .mcp,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ContractScene(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `pid_scene`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PidScene: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case selfBuy = "self_buy"
    case agent
    case share
    case taolijin
    case fallback
    case query
    case unknown = "__unknown__"

    public static let allCases: [PidScene] = [
        .selfBuy,
        .agent,
        .share,
        .taolijin,
        .fallback,
        .query,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PidScene(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `buy_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum BuyType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case contractSelf = "self"
    case share
    case unknown = "__unknown__"

    public static let allCases: [BuyType] = [
        .contractSelf,
        .share,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = BuyType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `scene_basis`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum SceneBasis: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case pid
    case param
    case fallback
    case unknown = "__unknown__"

    public static let allCases: [SceneBasis] = [
        .pid,
        .param,
        .fallback,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = SceneBasis(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `user_basis`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum UserBasis: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case param
    case claim
    case admin
    case unknown = "__unknown__"

    public static let allCases: [UserBasis] = [
        .param,
        .claim,
        .admin,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = UserBasis(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `link_event`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum LinkEvent: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case convert
    case precompute
    case register
    case `open`
    case unknown = "__unknown__"

    public static let allCases: [LinkEvent] = [
        .convert,
        .precompute,
        .register,
        .`open`,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = LinkEvent(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `installed_state`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InstalledState: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case `true`
    case `false`
    case contractUnknown = "unknown"
    case unknown = "__unknown__"

    public static let allCases: [InstalledState] = [
        .`true`,
        .`false`,
        .contractUnknown,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InstalledState(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `no_rebate_reason`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NoRebateReason: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case authDeclined = "auth_declined"
    case authFailed = "auth_failed"
    case relationConflict = "relation_conflict"
    case bindingBlocked = "binding_blocked"
    case unknown = "__unknown__"

    public static let allCases: [NoRebateReason] = [
        .authDeclined,
        .authFailed,
        .relationConflict,
        .bindingBlocked,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NoRebateReason(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `jump_type`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum JumpType: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case sdk
    case scheme
    case universalLink = "universal_link"
    case h5
    case copyTpwd = "copy_tpwd"
    case unknown = "__unknown__"

    public static let allCases: [JumpType] = [
        .sdk,
        .scheme,
        .universalLink,
        .h5,
        .copyTpwd,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = JumpType(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `input_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InputKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case tpwd
    case url
    case text
    case unknown = "__unknown__"

    public static let allCases: [InputKind] = [
        .tpwd,
        .url,
        .text,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InputKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `rebate_basis`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RebateBasis: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case normal
    case priceCompareRisk = "price_compare_risk"
    case noRebate = "no_rebate"
    case amountUnknown = "amount_unknown"
    case loginRequired = "login_required"
    case unknown = "__unknown__"

    public static let allCases: [RebateBasis] = [
        .normal,
        .priceCompareRisk,
        .noRebate,
        .amountUnknown,
        .loginRequired,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RebateBasis(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `availability`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum Availability: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case ok
    case offShelf = "off_shelf"
    case couponGone = "coupon_gone"
    case refExpired = "ref_expired"
    case priceUnavailable = "price_unavailable"
    case contractUnknown = "unknown"
    case unknown = "__unknown__"

    public static let allCases: [Availability] = [
        .ok,
        .offShelf,
        .couponGone,
        .refExpired,
        .priceUnavailable,
        .contractUnknown,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = Availability(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `match_tag`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum MatchTag: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case matched
    case relaxed
    case specUnconfirmed = "spec_unconfirmed"
    case unknown = "__unknown__"

    public static let allCases: [MatchTag] = [
        .matched,
        .relaxed,
        .specUnconfirmed,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = MatchTag(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `benefit`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum Benefit: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case coupon
    case bigCoupon = "big_coupon"
    case taolijin
    case subsidy
    case highRebate = "high_rebate"
    case unknown = "__unknown__"

    public static let allCases: [Benefit] = [
        .coupon,
        .bigCoupon,
        .taolijin,
        .subsidy,
        .highRebate,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = Benefit(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `sort`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum Sort: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case relevance
    case salesDesc = "sales_desc"
    case finalPriceAsc = "final_price_asc"
    case rebateDesc = "rebate_desc"
    case unknown = "__unknown__"

    public static let allCases: [Sort] = [
        .relevance,
        .salesDesc,
        .finalPriceAsc,
        .rebateDesc,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = Sort(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `link_pattern_category`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum LinkPatternCategory: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case product
    case promo
    case unionHost = "union_host"
    case unknown = "__unknown__"

    public static let allCases: [LinkPatternCategory] = [
        .product,
        .promo,
        .unionHost,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = LinkPatternCategory(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `link_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum LinkKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case share
    case other
    case unknown = "__unknown__"

    public static let allCases: [LinkKind] = [
        .share,
        .other,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = LinkKind(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `no_rebate_cause`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum NoRebateCause: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case priceCompare = "price_compare"
    case unknown = "__unknown__"

    public static let allCases: [NoRebateCause] = [
        .priceCompare,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = NoRebateCause(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `tlj_kind`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum TljKind: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case ours
    case brandOpen = "brand_open"
    case thirdParty = "third_party"
    case contractUnknown = "unknown"
    case unknown = "__unknown__"

    public static let allCases: [TljKind] = [
        .ours,
        .brandOpen,
        .thirdParty,
        .contractUnknown,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = TljKind(rawValue: rawValue) ?? .unknown
    }
}
