import Foundation

// MARK: - 「我的」页

/// 宫格的一格（向量 grid 的项）：group / item / route（客服格 route=nil、cs=true）。
public struct GridCell: Equatable, Sendable, Hashable {
    public let group: String
    public let item: String
    public let route: String?

    public var cs: Bool {
        route == nil
    }

    var json: [String: Any] {
        guard let route else {
            return ["group": group, "item": item, "route": NSNull(), "cs": true]
        }
        return ["group": group, "item": item, "route": route]
    }
}

/// 「我的」页的显示结论（页面用）。
public struct MeViewModel: Equatable, Sendable {
    public let loginPrompt: Bool
    public let inviteCode: String?
    public let inviterTextKey: String?
    public let withdrawableFen: Int64?
    public let estimatedFen: Int64?
    public let masked: Bool
    public let bell: Bool
    public let grid: [GridCell]
}

/// 「我的」页显示规则（brief §2.2，G04、G05、G06、G31、G36）。输出只有 loginPrompt、inviteCodeBlock、inviterTextKey、balance、bell、grid
/// 六项：不显示等级与邀请人任何信息（OPS-20）。
public enum MeView {
    public static let groupOrders = "orders_wallet"
    public static let groupPromo = "promo"
    public static let groupMore = "more"
    public static let inviterBoundKey = "me.inviter_bound"
    public static let inviterUnboundKey = "me.inviter_unbound"
    public static let mask = "****"
    public static let earnings = "Earnings"
    public static let messages = "Messages"
    public static let wallet = "Wallet"

    /// 宫格顺序照 Me 稿（收藏夹、分享赚不在路由表，不显示，G31）。item 是稿上的名字，界面经 `MeDraftTexts.gridKey` 取键。
    public static let memberGrid: [GridCell] = [
        GridCell(group: groupOrders, item: "我的订单", route: "OrderList"),
        GridCell(group: groupOrders, item: "钱包", route: "Wallet"),
        GridCell(group: groupOrders, item: "余额流水", route: "Ledger"),
        GridCell(group: groupOrders, item: "找回订单", route: "FindOrder"),
        GridCell(group: groupPromo, item: "邀请好友", route: "InviteShare"),
        GridCell(group: groupPromo, item: "收益看板", route: earnings),
        GridCell(group: groupMore, item: "帮助中心", route: "Help"),
        GridCell(group: groupMore, item: "联系客服", route: nil),
        GridCell(group: groupMore, item: "授权管理", route: "AuthManage"),
        GridCell(group: groupMore, item: "设置", route: "Settings"),
    ]
    public static let guestGrid: [GridCell] = [
        GridCell(group: groupMore, item: "帮助中心", route: "Help"),
        GridCell(group: groupMore, item: "设置", route: "Settings"),
    ]

    static func grid(_ specs: [GridCell], _ routes: Set<String>, _ earnings: Bool?) -> [GridCell] {
        specs.filter { cell in
            (cell.route != Self.earnings || earnings == true) && (cell.route.map(routes.contains) ?? true)
        }
    }

    /// `level`：basic / guest / member（basic 在本任务没有自己的「我的」页，按游客口径给）；`me`：已校验的 Me 快照（可空：加载中、失败）；
    /// `availableRoutes`：本端路由表里有、since 满足的路由；`earningsFlag`：features.flags 的收益看板开关。
    public static func model(
        level: String, me: [String: Any]?, masked: Bool, availableRoutes: Set<String>, earningsFlag: Bool?
    ) -> MeViewModel {
        guard level == MeLevel.member else {
            return MeViewModel(
                loginPrompt: true, inviteCode: nil, inviterTextKey: nil, withdrawableFen: nil, estimatedFen: nil,
                masked: masked, bell: false, grid: grid(guestGrid, availableRoutes, nil)
            )
        }
        let cells = grid(memberGrid, availableRoutes, earningsFlag)
        let bell = availableRoutes.contains(messages)
        guard let me else {
            return MeViewModel(
                loginPrompt: false, inviteCode: nil, inviterTextKey: nil, withdrawableFen: nil, estimatedFen: nil,
                masked: masked, bell: bell, grid: cells
            )
        }
        let balance = me["balance"] as? [String: Any]
        return MeViewModel(
            loginPrompt: false,
            inviteCode: me["invite_code"] as? String,
            inviterTextKey: JSONKind.bool(me["inviter_bound"]) == true ? inviterBoundKey : inviterUnboundKey,
            withdrawableFen: JSONKind.int64(balance?["withdrawable_fen"]) ?? 0,
            estimatedFen: JSONKind.int64(balance?["estimated_total_fen"]) ?? 0,
            masked: masked, bell: bell, grid: cells
        )
    }

    /// 向量接线。
    public static func of(
        level: String, me: [String: Any]?, masked: Bool, availableRoutes: [String], earningsFlag: Bool?
    ) -> [String: Any] {
        let model = model(
            level: level, me: me, masked: masked, availableRoutes: Set(availableRoutes), earningsFlag: earningsFlag
        )
        func amount(_ fen: Int64) -> [String: Any] {
            masked ? ["fen": fen, "maskedText": mask] : ["fen": fen]
        }
        var balance: Any = NSNull()
        if let withdrawable = model.withdrawableFen, let estimated = model.estimatedFen {
            balance = ["withdrawable": amount(withdrawable), "estimated": amount(estimated), "withdrawRoute": wallet]
        }
        return [
            "loginPrompt": model.loginPrompt,
            "inviteCodeBlock": model.inviteCode.map { ["code": $0] as Any } ?? NSNull(),
            "inviterTextKey": model.inviterTextKey ?? NSNull(),
            "balance": balance,
            "bell": model.bell ? ["route": messages, "unreadDot": false] as Any : NSNull(),
            "grid": model.grid.map(\.json),
        ]
    }
}

/// 「我的」页通知引导条（G28，BR-ID-13 细则）：已登录 && 系统通知未开启（拒绝过）&& 距上次被拒 ≥ 48 小时 && 距上次关闭引导条 ≥ 7 天。
/// 从未被拒（not_determined / not_asked）、系统已允许、未登录都不出现。
public enum NotifyGuideBar {
    public static let denyWaitMillis: Int64 = 48 * hourMillis
    public static let closeWaitMillis: Int64 = 7 * dayMillis

    public static func visible(
        loggedIn: Bool, systemStatus: String, lastDeniedMs: Int64?, lastClosedMs: Int64?, nowMs: Int64
    ) -> Bool {
        guard loggedIn, systemStatus == "denied" || systemStatus == "permanently_denied", let lastDeniedMs else {
            return false
        }
        guard nowMs - lastDeniedMs >= denyWaitMillis else { return false }
        guard let lastClosedMs else { return true }
        return nowMs - lastClosedMs >= closeWaitMillis
    }
}
