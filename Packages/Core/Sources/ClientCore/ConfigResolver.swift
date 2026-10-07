import Foundation

/// 配置取值顺序（03 §4.3）。三层都是 `/v1/config` 的 data（JSON 对象）：当前响应 → LKG（上一次成功的响应）→ 包内默认。
/// 纯函数：入参是 JSON 文本（nil = 这一层没有），结果是选中值的 JSON 文本。
public enum ConfigResolver {
    /// 顶层键（可用 "." 写嵌套路径）：取第一层带该键的值；值为 null 按没有。
    public static func resolve(current: String?, lkg: String?, bundled: String?, key: String) -> String? {
        let layers = [current, lkg, bundled].map(ConfigDocument.parse)
        for layer in layers {
            if let value = layer?.value(at: key) {
                return ConfigDocument.encode(value)
            }
        }
        return nil
    }

    /// `features.search_status` 按平台逐个取值（BR-PROD-10 细则「按平台的搜索开关」）：取第一层带该平台取值的；
    /// 缺字段、缺平台不当作 off，继续回落；明确下发的 off 有效。
    /// TODO(N-21): 三层都没有、取值为 null 或不是字符串时的结论未规定：返回 nil（按缺失），由调用方决定。
    public static func searchStatus(current: String?, lkg: String?, bundled: String?, platformKey: String) -> String? {
        searchStatus(layers: [current, lkg, bundled].map(ConfigDocument.parse), platformKey: platformKey)
    }

    /// `link_patterns`（BR-ATTR-29）：当前版本 → 上一次成功的版本 → 包内快照，取第一层完整的（version 为非空字符串、
    /// rules 为数组；明确的空规则数组不等于缺失）。
    /// TODO(N-21): 损坏、同版本异内容、版本回退的处理未规定：不完整的一层整层跳过，不比较版本。
    public static func linkPatterns(current: String?, lkg: String?, bundled: String?) -> String? {
        linkPatterns(layers: [current, lkg, bundled].map(ConfigDocument.parse)).flatMap { ConfigDocument.encode($0) }
    }

    static func searchStatus(layers: [ConfigDocument?], platformKey: String) -> String? {
        for layer in layers {
            if let value = layer?.value(at: "features.search_status") as? [String: Any],
               let status = value[platformKey] as? String {
                return status
            }
        }
        return nil
    }

    static func linkPatterns(layers: [ConfigDocument?]) -> [String: Any]? {
        for layer in layers {
            if let patterns = layer?.value(at: "link_patterns"), let complete = completePatterns(patterns) {
                return complete
            }
        }
        return nil
    }

    /// 完整的 link_patterns：version 为非空字符串、rules 为数组。
    static func completePatterns(_ value: Any) -> [String: Any]? {
        guard let object = value as? [String: Any],
              let version = object["version"] as? String, !version.isEmpty,
              object["rules"] is [Any]
        else {
            return nil
        }
        return object
    }
}

/// 一份配置 data（JSON 对象）。
struct ConfigDocument {
    let object: [String: Any]

    static func parse(_ text: String?) -> ConfigDocument? {
        guard let data = text?.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return ConfigDocument(object: object)
    }

    /// 按 "a.b" 路径取值；null 按没有。
    func value(at path: String) -> Any? {
        var node: Any = object
        for part in path.split(separator: ".") {
            guard let dictionary = node as? [String: Any], let next = dictionary[String(part)], !(next is NSNull) else {
                return nil
            }
            node = next
        }
        return node
    }

    var json: String {
        Self.encode(object) ?? "{}"
    }

    static func encode(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
