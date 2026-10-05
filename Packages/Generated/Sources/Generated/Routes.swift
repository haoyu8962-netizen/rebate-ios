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

    public init(
        name: Swift.String, kind: RouteKind, auth: Swift.String, sinceIOS: Swift.String?,
        entries: [RouteEntry], h5Path: Swift.String?, debugOnly: Swift.Bool
    ) {
        self.name = name
        self.kind = kind
        self.auth = auth
        self.sinceIOS = sinceIOS
        self.entries = entries
        self.h5Path = h5Path
        self.debugOnly = debugOnly
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
            h5Path: nil, debugOnly: false
        )
        table["AgentChat"] = RouteSpec(
            name: "AgentChat", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["AgentConsent"] = RouteSpec(
            name: "AgentConsent", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["Agreement"] = RouteSpec(
            name: "Agreement", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/agreement", debugOnly: false
        )
        table["Appeal"] = RouteSpec(
            name: "Appeal", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["AuthManage"] = RouteSpec(
            name: "AuthManage", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["AuthSheet"] = RouteSpec(
            name: "AuthSheet", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["BasicMode"] = RouteSpec(
            name: "BasicMode", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["BindPhone"] = RouteSpec(
            name: "BindPhone", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["DeleteAccount"] = RouteSpec(
            name: "DeleteAccount", kind: .native, auth: "login",
            sinceIOS: nil,
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["Earnings"] = RouteSpec(
            name: "Earnings", kind: .h5, auth: "login",
            sinceIOS: nil,
            entries: [.inApp, .push],
            h5Path: "/earnings", debugOnly: false
        )
        table["ExternalPage"] = RouteSpec(
            name: "ExternalPage", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false
        )
        table["FindOrder"] = RouteSpec(
            name: "FindOrder", kind: .h5, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/find-order", debugOnly: false
        )
        table["ForceUpdate"] = RouteSpec(
            name: "ForceUpdate", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["Help"] = RouteSpec(
            name: "Help", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/help", debugOnly: false
        )
        table["Home"] = RouteSpec(
            name: "Home", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false
        )
        table["InviteShare"] = RouteSpec(
            name: "InviteShare", kind: .h5, auth: "phone",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/invite", debugOnly: false
        )
        table["InvitedFriends"] = RouteSpec(
            name: "InvitedFriends", kind: .native, auth: "phone",
            sinceIOS: nil,
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["JumpTip"] = RouteSpec(
            name: "JumpTip", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["LaborAgreement"] = RouteSpec(
            name: "LaborAgreement", kind: .native, auth: "realname",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["Launch"] = RouteSpec(
            name: "Launch", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["Ledger"] = RouteSpec(
            name: "Ledger", kind: .h5, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/ledger", debugOnly: false
        )
        table["LevelUpgrade"] = RouteSpec(
            name: "LevelUpgrade", kind: .native, auth: "phone",
            sinceIOS: nil,
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["LinkLanding"] = RouteSpec(
            name: "LinkLanding", kind: .native, auth: "none",
            sinceIOS: nil,
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false
        )
        table["Login"] = RouteSpec(
            name: "Login", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp],
            h5Path: nil, debugOnly: false
        )
        table["Me"] = RouteSpec(
            name: "Me", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["Messages"] = RouteSpec(
            name: "Messages", kind: .h5, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: "/messages", debugOnly: false
        )
        table["Notice"] = RouteSpec(
            name: "Notice", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/notice", debugOnly: false
        )
        table["OrderDetail"] = RouteSpec(
            name: "OrderDetail", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["OrderList"] = RouteSpec(
            name: "OrderList", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["PayoutAccount"] = RouteSpec(
            name: "PayoutAccount", kind: .native, auth: "realname",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["PrivacyCenter"] = RouteSpec(
            name: "PrivacyCenter", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["ProductDetail"] = RouteSpec(
            name: "ProductDetail", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false
        )
        table["RealName"] = RouteSpec(
            name: "RealName", kind: .native, auth: "phone",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["RiskNotice"] = RouteSpec(
            name: "RiskNotice", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["Rules"] = RouteSpec(
            name: "Rules", kind: .h5, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: "/rules", debugOnly: false
        )
        table["Search"] = RouteSpec(
            name: "Search", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push, .deeplink],
            h5Path: nil, debugOnly: false
        )
        table["Settings"] = RouteSpec(
            name: "Settings", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["Wallet"] = RouteSpec(
            name: "Wallet", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["WebPage"] = RouteSpec(
            name: "WebPage", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["Withdraw"] = RouteSpec(
            name: "Withdraw", kind: .native, auth: "realname",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        table["WithdrawRecords"] = RouteSpec(
            name: "WithdrawRecords", kind: .native, auth: "login",
            sinceIOS: "1.0.0",
            entries: [.inApp, .push],
            h5Path: nil, debugOnly: false
        )
        #if DEBUG
        table["HomePreview"] = RouteSpec(
            name: "HomePreview", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .deeplink],
            h5Path: nil, debugOnly: true
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
