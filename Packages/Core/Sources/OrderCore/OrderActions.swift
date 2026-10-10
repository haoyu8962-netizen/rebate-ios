import Foundation
import Generated
import Router

// MARK: - 跳转目标

/// 一个经 Router 打开的目标（路由名都在 routes.json）。
public struct RouteTarget: Equatable, Sendable {
    public let route: String
    public let params: [String: String]

    public init(route: String, params: [String: String]) {
        self.route = route
        self.params = params
    }
}

/// 比价说明入口「查看说明」（BR-TEXT-03「比价说明入口」）：help_links.price_compare 已配置，且 ① reason=PRICE_COMPARE 或 ③ NO_REBATE 且
/// is_price_compare=true 时显示（② 比价风险 hint 依赖契约没有的 rebate_basis，G02）。目标必须是 HelpLinkTarget（Help + 非空 article_id），
/// 路由在 routes.json 里、参数按该路由的 schema 校验通过；否则不显示。不占按钮位。
public enum PriceCompareEntry {
    public static let helpLinkKey = "price_compare"

    public static func view(
        _ detail: OrderDetail, helpLinks: [String: Any]?, routes: [String: RouteSpec]
    ) -> RouteTarget? {
        let status = detail.summary.displayStatus
        let applies = detail.summary.reason == "PRICE_COMPARE" || (status == .noRebate && detail.isPriceCompare == true)
        guard applies else { return nil }
        return target(helpLinks, routes: routes)
    }

    /// 配置的帮助文章目标（HelpLinkTarget 校验 + routes.json 校验）；不合法为 nil。
    public static func target(_ helpLinks: [String: Any]?, routes: [String: RouteSpec]) -> RouteTarget? {
        guard let entry = helpLinks?[helpLinkKey] as? [String: Any], let route = entry["route"] as? String,
              let params = entry["params"] as? [String: Any], route == "Help",
              let article = params["article_id"] as? String, !article.isEmpty, let spec = routes[route],
              let values = JSONValue.object(from: params), RouteParamValidator.isValid(values, spec: spec)
        else { return nil }
        let strings = params.compactMapValues { $0 as? String }
        guard strings.count == params.count else { return nil }
        return RouteTarget(route: route, params: strings)
    }

    public static func of(
        _ detail: [String: Any], _ helpLinks: [String: Any]?, _ routes: [String: RouteSpec]
    ) -> [String: Any] {
        guard let target = view(OrderJSON.lenientDetail(detail), helpLinks: helpLinks, routes: routes) else {
            return ["show": false]
        }
        return ["show": true, "route": target.route, "params": target.params]
    }
}

/// 详情底部的一个按钮。`actionRaw` 三端同名：claim、reauth、contact_cs、appeal、withdraw、ledger。
public struct OrderActionButton: Equatable, Sendable {
    public let actionRaw: String
    public let route: String
    public let primary: Bool

    public var labelKey: String {
        "order_action.\(actionRaw)"
    }
}

public struct OrderActionsView: Equatable, Sendable {
    public let buttons: [OrderActionButton]
    public let appealPendingBlock: Bool
}

/// 详情按钮（BR-TEXT-05：状态固有按钮 + reason.action，最多 2 个，有 reason.action 时它为主按钮）：reason_action 里本端认识的动作在前
/// （CLAIM → FindOrder；REAUTH → AuthManage，G09；CONTACT_CS → Help，统一客服出口接入前，TODO(N-31) G09；APPEAL → Appeal，G08），
/// 状态固有按钮在后（CREDITED / CREDITED_PART_CLAWED【去提现】→ Withdraw；CLAWED_BACK【查看流水】→ Ledger），超过 2 个只留前 2 个，
/// 第一个为主按钮；不认识的 action 忽略。分享单同样处理。appeal_pending=true 时原因区下加「申诉中」块（G08）。
public enum OrderDetailActions {
    public static let max = 2
    static let reasonActions: [String: (String, String)] = [
        "CLAIM": ("claim", "FindOrder"),
        "REAUTH": ("reauth", "AuthManage"),
        "CONTACT_CS": ("contact_cs", "Help"),
        "APPEAL": ("appeal", "Appeal"),
    ]

    public static func view(_ detail: OrderDetail) -> OrderActionsView {
        var pairs: [(String, String)] = detail.reasonAction.compactMap { reasonActions[$0] }
        switch detail.summary.displayStatus {
        case .credited, .creditedPartClawed: pairs.append(("withdraw", "Withdraw"))
        case .clawedBack: pairs.append(("ledger", "Ledger"))
        default: break
        }
        var seen = Set<String>()
        let unique = pairs.filter { seen.insert($0.0).inserted }
        let buttons = unique.prefix(max).enumerated().map { index, pair in
            OrderActionButton(actionRaw: pair.0, route: pair.1, primary: index == 0)
        }
        return OrderActionsView(buttons: buttons, appealPendingBlock: detail.appealPending)
    }

    public static func of(_ detail: [String: Any]) -> [String: Any] {
        let view = view(OrderJSON.lenientDetail(detail))
        return [
            "buttons": view.buttons.map { ["actionRaw": $0.actionRaw, "route": $0.route, "primary": $0.primary] },
            "appealPendingBlock": view.appealPendingBlock,
        ]
    }
}

/// 「查看商品」（F-ORD-16，BR-TEXT-02 细则）：product_key 非 null 且 is_other_product=false 时显示；打开 ProductDetail {platform,
/// product_key}
/// （不带 item_ref、不带任何订单或 link 信息），之后的购买是一次新的 open。不占按钮名额。
public enum ViewProductEntry {
    public static let route = "ProductDetail"

    public static func view(_ detail: OrderDetail) -> RouteTarget? {
        guard let key = detail.productKey, !detail.summary.isOtherProduct, !detail.summary.platform.isEmpty else {
            return nil
        }
        return RouteTarget(route: route, params: ["platform": detail.summary.platform, "product_key": key])
    }

    public static func of(_ detail: [String: Any]) -> [String: Any] {
        guard let target = view(OrderJSON.lenientDetail(detail)) else { return ["show": false] }
        return ["show": true, "route": target.route, "params": target.params]
    }
}
