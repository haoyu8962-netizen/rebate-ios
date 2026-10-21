import Foundation
import Generated

/// routes.json params 的 JSON Schema 校验（03 §4.4「统一入口守卫」：所有来源都校验参数）。
/// 只认 routes.json 用到的关键字：type、enum、minLength、maxLength、pattern、minimum（CT-LOCK-02：Agreement.version）、required、
/// additionalProperties。
public enum RouteParamValidator {
    public static func isValid(_ params: [String: JSONValue], spec: RouteSpec) -> Bool {
        for name in spec.requiredParams where params[name] == nil {
            return false
        }
        for (name, value) in params {
            guard let param = spec.param(name) else {
                if spec.additionalParams {
                    continue
                }
                return false
            }
            guard isValid(value, param: param) else {
                return false
            }
        }
        return true
    }

    static func isValid(_ value: JSONValue, param: RouteParamSpec) -> Bool {
        guard matchesType(value, param.type) else {
            return false
        }
        if let values = param.enumValues {
            guard let text = value.stringValue, values.contains(text) else {
                return false
            }
        }
        guard meetsMinimum(value, param.minimum) else {
            return false
        }
        guard let text = value.stringValue else {
            return true
        }
        // JSON Schema 的长度按 Unicode 码点计。
        let length = text.unicodeScalars.count
        if let minLength = param.minLength, length < minLength {
            return false
        }
        if let maxLength = param.maxLength, length > maxLength {
            return false
        }
        if let pattern = param.pattern, text.range(of: pattern, options: .regularExpression) == nil {
            return false
        }
        return true
    }

    /// minimum 只约束数值（integer / number）；没有 minimum 或不是数值时不限。
    private static func meetsMinimum(_ value: JSONValue, _ minimum: Int?) -> Bool {
        guard let minimum else { return true }
        switch value {
        case let .integer(number):
            return number >= Int64(minimum)
        case let .number(number):
            return number >= Double(minimum)
        default:
            return true
        }
    }

    private static func matchesType(_ value: JSONValue, _ type: RouteParamType) -> Bool {
        switch (type, value) {
        case (.string, .string), (.boolean, .bool), (.object, .object), (.array, .array),
             (.integer, .integer), (.number, .integer), (.number, .number):
            true
        case let (.integer, .number(number)):
            number.rounded() == number
        default:
            false
        }
    }
}

/// ExternalPage / WebPage 的目标地址白名单（03 §4.4「入口限制」，BR-ID-10 细则）。
/// - ExternalPage：**只有从深链进入时**，url 的主机须在 external_hosts 里（完整主机名、不分大小写）。可信页内的跨域跳转、推送等
///   App 内来源不受这张表限制，进容器后走 ExternalWebView 自己的导航判定（03 §4.4、§5.1；APP-04 三端共性第 10 条）。
///   url 必须是 https、有主机、不带用户信息（所有来源）。
/// - WebPage：url 的 origin 须在 bridge_origins 里（所有来源）。
public enum RouteTargetCheck {
    /// 该路由的目标地址是否在白名单内；不是这两个路由时恒为 true。
    public static func isAllowed(
        route: String,
        params: [String: JSONValue],
        allowlist: RouteTargetAllowlist,
        source: RouteSource = .deeplink
    ) -> Bool {
        switch route {
        case RoutePolicy.externalPage:
            guard let url = params["url"]?.stringValue, let target = parse(url) else { return false }
            guard source == .deeplink else { return true }
            let hosts = Set(allowlist.externalHosts.map { $0.lowercased() })
            // 完整主机名匹配；带端口的地址不按主机名放行。
            return target.port == nil && hosts.contains(target.host)
        case RoutePolicy.webPage:
            guard let url = params["url"]?.stringValue, let target = parse(url) else { return false }
            let origins = Set(allowlist.bridgeOrigins.compactMap { parse($0)?.origin })
            return origins.contains(target.origin)
        default:
            return true
        }
    }

    private struct Target {
        let host: String
        let port: Int?

        var origin: String {
            port.map { "https://\(host):\($0)" } ?? "https://\(host)"
        }
    }

    /// 只认 https、无用户信息、有主机名的地址；默认端口 443 归一为无端口。
    private static func parse(_ text: String) -> Target? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            return nil
        }
        let port = components.port == 443 ? nil : components.port
        return Target(host: host, port: port)
    }
}
