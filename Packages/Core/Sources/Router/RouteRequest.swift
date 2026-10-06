import Foundation
import Generated

/// 打开请求的来源（任务书 §2）。入口类别看来源，不看请求里的任何标记（03 §4.4、BR-ID-10）。
public enum RouteSource: String, Sendable, CaseIterable {
    case inApp = "in_app"
    case push
    case deeplink
    case bridge
    case pendingAction = "pending_action"
    case agentCard = "agent_card"

    /// 来源字符串不认识时按 deeplink（最严格的外部入口）处理。
    public init(raw: String) {
        self = RouteSource(rawValue: raw) ?? .deeplink
    }

    /// 校验 routes.json `entry` 时用的入口类别：push 只给回查得到的 route，deeplink 是外部直接带来的 route，
    /// 其余（原生页面、JSBridge nav.open、Agent 卡片、pending_action 恢复）按 in_app。
    /// TODO(N-14): pending_action 的原始来源未进 RouteRequest（rule-gaps G01、G09），恢复时按 in_app 校验。
    public var entry: RouteEntry {
        switch self {
        case .push: .push
        case .deeplink: .deeplink
        case .inApp, .bridge, .pendingAction, .agentCard: .inApp
        }
    }
}

/// 一次打开请求：路由名 + 参数 + 来源。
public struct RouteRequest: Sendable, Hashable {
    public let route: String
    public let paramValues: [String: JSONValue]
    public let sourceKind: RouteSource

    public init(route: String, values: [String: JSONValue] = [:], from source: RouteSource) {
        self.route = route
        paramValues = values
        sourceKind = source
    }

    /// 任务书原样签名：params 为 JSON 对象，source 为原始字符串。不是 JSON 的参数值被丢弃。
    public init(route: String, params: [String: Any], source: String) {
        self.route = route
        var values: [String: JSONValue] = [:]
        for (key, value) in params {
            if let converted = JSONValue(any: value) {
                values[key] = converted
            }
        }
        paramValues = values
        sourceKind = RouteSource(raw: source)
    }

    /// JSON 对象视图（与 JSONSerialization 互通）。
    public var params: [String: Any] {
        paramValues.mapValues(\.anyValue)
    }

    /// 来源的原始字符串（任务书 §2 的取值）。
    public var source: String {
        sourceKind.rawValue
    }
}
