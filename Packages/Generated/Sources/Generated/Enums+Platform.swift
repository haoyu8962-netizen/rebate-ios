// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/enums/platform.json

/// 契约枚举 `platform`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum Platform: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case taobao
    case jd
    case pdd
    case meituan
    case vip
    case douyin
    case eleme
    case kuaishou
    case suning
    case unknown = "__unknown__"

    public static let allCases: [Platform] = [
        .taobao,
        .jd,
        .pdd,
        .meituan,
        .vip,
        .douyin,
        .eleme,
        .kuaishou,
        .suning,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = Platform(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `key_stability`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum KeyStability: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case unverified
    case stable24h = "stable_24h"
    case stable7d = "stable_7d"
    case unstable
    case unknown = "__unknown__"

    public static let allCases: [KeyStability] = [
        .unverified,
        .stable24h,
        .stable7d,
        .unstable,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = KeyStability(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `client_platform`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum ClientPlatform: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case ios
    case android
    case harmony
    case h5
    case admin
    case unknown = "__unknown__"

    public static let allCases: [ClientPlatform] = [
        .ios,
        .android,
        .harmony,
        .h5,
        .admin,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = ClientPlatform(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `route_entry`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum RouteEntry: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case inApp = "in_app"
    case push
    case deeplink
    case unknown = "__unknown__"

    public static let allCases: [RouteEntry] = [
        .inApp,
        .push,
        .deeplink,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = RouteEntry(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `platform_search_status`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PlatformSearchStatus: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case on
    case off
    case unknown = "__unknown__"

    public static let allCases: [PlatformSearchStatus] = [
        .on,
        .off,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PlatformSearchStatus(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `install_channel`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum InstallChannel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case appstore
    case official
    case huawei
    case agc
    case unknown = "__unknown__"

    public static let allCases: [InstallChannel] = [
        .appstore,
        .official,
        .huawei,
        .agc,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = InstallChannel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `auth_level`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum AuthLevel: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case none
    case optional
    case login
    case phone
    case realname
    case unknown = "__unknown__"

    public static let allCases: [AuthLevel] = [
        .none,
        .optional,
        .login,
        .phone,
        .realname,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = AuthLevel(rawValue: rawValue) ?? .unknown
    }
}

/// 契约枚举 `platform_icon_key`。未知取值解码为 `.unknown`（不在 `allCases` 里）。
public enum PlatformIconKey: Swift.String, Swift.Sendable, Swift.CaseIterable, Swift.Codable {
    case taobao
    case tmall
    case jd
    case pdd
    case wechat
    case wechatPay = "wechat_pay"
    case alipay
    case wecom
    case unknown = "__unknown__"

    public static let allCases: [PlatformIconKey] = [
        .taobao,
        .tmall,
        .jd,
        .pdd,
        .wechat,
        .wechatPay,
        .alipay,
        .wecom,
    ]

    public init(from decoder: any Swift.Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(Swift.String.self)
        self = PlatformIconKey(rawValue: rawValue) ?? .unknown
    }
}
