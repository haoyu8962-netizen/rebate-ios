import Foundation
import Generated

/// 入站链接配置：自定义 scheme 与 `l.<主域>` 链接域名（apps.json 入站回调类，03 §4.4、§4.5）。
/// 由调用方传入，解析器不内建任何 scheme 或域名（apps.json inbound 当前为空，needs N-05）。
public struct DeepLinkConfig: Sendable, Equatable {
    public let schemes: [String]
    public let hosts: [String]

    public init(schemes: [String], hosts: [String]) {
        self.schemes = schemes
        self.hosts = hosts
    }

    public static let empty = DeepLinkConfig(schemes: [], hosts: [])
}

/// 深链解析（03 §4.4「深链」）。只认两种形状，其余一律返回 nil：
/// - `https://<hosts 之一>/r/<name>?<params>`（经验证的网页链接；不认 http）
/// - `<schemes 之一>://r/<name>?<params>`
/// 参数按 routes.json 的 params schema 校验（类型、枚举、长度、pattern、必填、多余参数）；
/// 查询参数一律是字符串，不做数字或布尔转换。路由名不在表里时不校验参数、照常返回，由守卫进升级提示。
public enum DeepLinkParser {
    /// TODO(N-14): 整个 URL 的长度上限规划未定（rule-gaps G05），先取保守值。
    public static let maxURLLength = 4096
    private static let routeNamePattern = "^[A-Za-z][A-Za-z0-9_]{0,63}$"

    public static func parse(url: String, config: DeepLinkConfig) -> RouteRequest? {
        parse(url: url, config: config, routes: Routes.all)
    }

    public static func parse(url: String, config: DeepLinkConfig, routes: [String: RouteSpec]) -> RouteRequest? {
        guard !url.isEmpty, url.count <= maxURLLength,
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              components.user == nil, components.password == nil, components.port == nil,
              // TODO(N-14): fragment 的处理未定（rule-gaps G05），保守拒绝。
              components.fragment == nil,
              let host = components.percentEncodedHost?.lowercased()
        else {
            return nil
        }

        let name: String
        let path = components.percentEncodedPath
        if scheme == "https" {
            guard config.hosts.contains(where: { $0.lowercased() == host }),
                  path.hasPrefix("/r/")
            else {
                return nil
            }
            name = String(path.dropFirst(3))
        } else {
            let customSchemes = config.schemes.map { $0.lowercased() }.filter { $0 != "https" && $0 != "http" }
            guard customSchemes.contains(scheme), host == "r", path.hasPrefix("/") else {
                return nil
            }
            name = String(path.dropFirst())
        }
        guard name.range(of: routeNamePattern, options: .regularExpression) != nil else {
            return nil
        }

        var params: [String: JSONValue] = [:]
        for item in components.queryItems ?? [] {
            guard !item.name.isEmpty, let value = item.value, params[item.name] == nil else {
                // 空键、没有值、重复键：拒绝（TODO(N-14) rule-gaps G05）。
                return nil
            }
            params[item.name] = .string(value)
        }

        if let spec = routes[name], !valid(params: params, spec: spec) {
            return nil
        }
        return RouteRequest(route: name, values: params, from: .deeplink)
    }

    /// 按 routes.json params schema 校验查询参数（值都是字符串）。
    static func valid(params: [String: JSONValue], spec: RouteSpec) -> Bool {
        // 深链只能带文本；声明为对象、数字等类型的参数不能从深链进入。
        for name in params.keys {
            if let param = spec.param(name), param.type != .string {
                return false
            }
        }
        return RouteParamValidator.isValid(params, spec: spec)
    }
}
