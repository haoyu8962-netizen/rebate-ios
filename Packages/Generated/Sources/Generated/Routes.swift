// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/routes.json

public enum RouteKind: Swift.String, Swift.Sendable {
    case native, h5
}

public struct RouteSpec: Swift.Sendable, Swift.Equatable {
    public let name: Swift.String
    public let kind: RouteKind
    public let auth: Swift.String
    /// routes.json 的 since.ios；null 表示 iOS 尚未上线该路由。
    public let sinceIOS: Swift.String?
    public let entries: [RouteEntry]
    public let h5Path: Swift.String?
    public let debugOnly: Swift.Bool
    /// routes.json 的 agent_guide（缺省 false）：Agent 页面引导卡与收益卡按钮能否打开该路由。
    public let agentGuide: Swift.Bool
    /// routes.json 的 agent_guide_account（phone / delete / fund，缺省 nil）：Agent 从不引导的账号安全路由。
    public let agentGuideAccount: Swift.String?
    /// routes.json params.properties（按参数名排序）。
    public let params: [RouteParamSpec]
    /// routes.json params.required。
    public let requiredParams: [Swift.String]
    /// routes.json params.additionalProperties（缺省 false）。
    public let additionalParams: Swift.Bool

    public init(
        name: Swift.String, kind: RouteKind, auth: Swift.String, sinceIOS: Swift.String?,
        entries: [RouteEntry], h5Path: Swift.String?, debugOnly: Swift.Bool,
        agentGuide: Swift.Bool = false, agentGuideAccount: Swift.String? = nil,
        params: [RouteParamSpec] = [], requiredParams: [Swift.String] = [], additionalParams: Swift.Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.auth = auth
        self.sinceIOS = sinceIOS
        self.entries = entries
        self.h5Path = h5Path
        self.debugOnly = debugOnly
        self.agentGuide = agentGuide
        self.agentGuideAccount = agentGuideAccount
        self.params = params
        self.requiredParams = requiredParams
        self.additionalParams = additionalParams
    }

    public func param(_ name: Swift.String) -> RouteParamSpec? {
        params.first { $0.name == name }
    }
}

/// 路由参数的 JSON 类型（routes.json params.properties.*.type）。
public enum RouteParamType: Swift.String, Swift.Sendable {
    case string, integer, number, boolean, object, array
}

/// 一个路由参数的 JSON Schema 约束（只转写 routes.json 用到的关键字）。
public struct RouteParamSpec: Swift.Sendable, Swift.Equatable {
    public let name: Swift.String
    public let type: RouteParamType
    public let enumValues: [Swift.String]?
    public let minLength: Swift.Int?
    public let maxLength: Swift.Int?
    public let pattern: Swift.String?

    public init(
        name: Swift.String, type: RouteParamType, enumValues: [Swift.String]? = nil,
        minLength: Swift.Int? = nil, maxLength: Swift.Int? = nil, pattern: Swift.String? = nil
    ) {
        self.name = name
        self.type = type
        self.enumValues = enumValues
        self.minLength = minLength
        self.maxLength = maxLength
        self.pattern = pattern
    }
}

public enum Routes {
    /// 键为路由名。debug_only 路由只在 DEBUG（Debug / Staging）里登记，Release 生成物里没有这些名字。
    public static let all: [Swift.String: RouteSpec] = {
        var table: [Swift.String: RouteSpec] = [:]
        table["About"] = RouteSpec(
            name: "About", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["AgentChat"] = RouteSpec(
            name: "AgentChat", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "context", type: .object),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["AgentConsent"] = RouteSpec(
            name: "AgentConsent", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Agreement"] = RouteSpec(
            name: "Agreement", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/agreement", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "type", type: .string, enumValues: ["agreement", "privacy", "sdk_list"]),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Appeal"] = RouteSpec(
            name: "Appeal", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["AuthManage"] = RouteSpec(
            name: "AuthManage", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: true,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["AuthSheet"] = RouteSpec(
            name: "AuthSheet", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "platform", type: .string, enumValues: ["taobao", "jd", "pdd", "meituan", "vip", "douyin", "eleme", "kuaishou", "suning"]),
            ],
            requiredParams: ["platform"],
            additionalParams: false
        )
        table["BasicMode"] = RouteSpec(
            name: "BasicMode", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["BindPhone"] = RouteSpec(
            name: "BindPhone", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: "phone",
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["DeleteAccount"] = RouteSpec(
            name: "DeleteAccount", kind: .native, auth: "login",
            sinceIOS: nil,
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: "delete",
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Earnings"] = RouteSpec(
            name: "Earnings", kind: .h5, auth: "login",
            sinceIOS: nil,
            entries: [.inApp, .push],
            h5Path: "/earnings", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "platform", type: .string, enumValues: ["taobao", "jd", "pdd", "meituan", "vip", "douyin", "eleme", "kuaishou", "suning"]),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["ExternalPage"] = RouteSpec(
            name: "ExternalPage", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "nav_style", type: .string, enumValues: ["light", "dark"]),
                RouteParamSpec(name: "title", type: .string, maxLength: 20),
                RouteParamSpec(name: "url", type: .string, maxLength: 2048, pattern: "^https://"),
            ],
            requiredParams: ["url"],
            additionalParams: false
        )
        table["FindOrder"] = RouteSpec(
            name: "FindOrder", kind: .h5, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/find-order", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["ForceUpdate"] = RouteSpec(
            name: "ForceUpdate", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Help"] = RouteSpec(
            name: "Help", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/help", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "article_id", type: .string, minLength: 1),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Home"] = RouteSpec(
            name: "Home", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["InviteShare"] = RouteSpec(
            name: "InviteShare", kind: .h5, auth: "phone",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/invite", debugOnly: false,
            agentGuide: true,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["InvitedFriends"] = RouteSpec(
            name: "InvitedFriends", kind: .native, auth: "phone",
            sinceIOS: nil,
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["JumpTip"] = RouteSpec(
            name: "JumpTip", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "platform", type: .string, enumValues: ["taobao", "jd", "pdd", "meituan", "vip", "douyin", "eleme", "kuaishou", "suning"]),
            ],
            requiredParams: ["platform"],
            additionalParams: false
        )
        table["LaborAgreement"] = RouteSpec(
            name: "LaborAgreement", kind: .native, auth: "realname",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: "fund",
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Launch"] = RouteSpec(
            name: "Launch", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Ledger"] = RouteSpec(
            name: "Ledger", kind: .h5, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/ledger", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["LevelUpgrade"] = RouteSpec(
            name: "LevelUpgrade", kind: .native, auth: "phone",
            sinceIOS: nil,
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["LinkLanding"] = RouteSpec(
            name: "LinkLanding", kind: .native, auth: "none",
            sinceIOS: nil,
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "link_id", type: .string, minLength: 1),
            ],
            requiredParams: ["link_id"],
            additionalParams: false
        )
        table["Login"] = RouteSpec(
            name: "Login", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Me"] = RouteSpec(
            name: "Me", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Messages"] = RouteSpec(
            name: "Messages", kind: .h5, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/messages", debugOnly: false,
            agentGuide: true,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Notice"] = RouteSpec(
            name: "Notice", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/notice", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "article_id", type: .string, minLength: 1),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["OrderDetail"] = RouteSpec(
            name: "OrderDetail", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "order_id", type: .string, minLength: 1),
            ],
            requiredParams: ["order_id"],
            additionalParams: false
        )
        table["OrderList"] = RouteSpec(
            name: "OrderList", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: true,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "scope", type: .string, enumValues: ["self", "share"]),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["PayoutAccount"] = RouteSpec(
            name: "PayoutAccount", kind: .native, auth: "realname",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: "fund",
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["PrivacyCenter"] = RouteSpec(
            name: "PrivacyCenter", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["ProductDetail"] = RouteSpec(
            name: "ProductDetail", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "item_ref", type: .string, minLength: 1, maxLength: 1024),
                RouteParamSpec(name: "platform", type: .string, enumValues: ["taobao", "jd", "pdd", "meituan", "vip", "douyin", "eleme", "kuaishou", "suning"]),
                RouteParamSpec(name: "product_key", type: .string, minLength: 3, maxLength: 128),
            ],
            requiredParams: ["platform", "product_key"],
            additionalParams: false
        )
        table["RealName"] = RouteSpec(
            name: "RealName", kind: .native, auth: "phone",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: "fund",
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["RiskNotice"] = RouteSpec(
            name: "RiskNotice", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Rules"] = RouteSpec(
            name: "Rules", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/rules", debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Search"] = RouteSpec(
            name: "Search", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "platform", type: .string, enumValues: ["taobao", "jd", "pdd", "meituan", "vip", "douyin", "eleme", "kuaishou", "suning"]),
                RouteParamSpec(name: "q", type: .string, maxLength: 100),
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Settings"] = RouteSpec(
            name: "Settings", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["Wallet"] = RouteSpec(
            name: "Wallet", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: true,
            agentGuideAccount: nil,
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["WebPage"] = RouteSpec(
            name: "WebPage", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "url", type: .string, maxLength: 2048, pattern: "^https://"),
            ],
            requiredParams: ["url"],
            additionalParams: false
        )
        table["Withdraw"] = RouteSpec(
            name: "Withdraw", kind: .native, auth: "realname",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: false,
            agentGuideAccount: "fund",
            params: [
            ],
            requiredParams: [],
            additionalParams: false
        )
        table["WithdrawRecords"] = RouteSpec(
            name: "WithdrawRecords", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false,
            agentGuide: true,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "withdrawal_id", type: .string, minLength: 1),
            ],
            requiredParams: [],
            additionalParams: false
        )
        #if DEBUG
        table["HomePreview"] = RouteSpec(
            name: "HomePreview", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .deeplink],
            h5Path: nil, debugOnly: true,
            agentGuide: false,
            agentGuideAccount: nil,
            params: [
                RouteParamSpec(name: "page_key", type: .string, minLength: 1),
                RouteParamSpec(name: "token", type: .string, minLength: 1),
            ],
            requiredParams: ["page_key", "token"],
            additionalParams: false
        )
        if table.count != 43 {
            Swift.fatalError("COULI_DEBUG_ONLY_ROUTE_TABLE: debug-only route table incomplete")
        }
        #endif
        return table
    }()

    public static func spec(_ name: Swift.String) -> RouteSpec? {
        all[name]
    }
}
