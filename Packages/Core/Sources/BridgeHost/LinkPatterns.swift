import Foundation
import Generated

/// 链接形态类别（contracts/enums link_pattern_category）。
public enum LinkCategory {
    public static let product = "product"
    public static let promo = "promo"
    public static let unionHost = "union_host"
}

/// 一条命中：平台与类别。
public struct LinkMatch: Sendable, Equatable {
    public let platform: String
    public let category: String
}

/// 规范化后的 https 地址（BR-ATTR-29 细则「桥方法不留没有归因的打开入口」、03 §5.1；APP-04 三端共性第 17 条）：
/// 浏览器式解析——路径里的反斜杠当斜杠、消除点段（含 `%2e` 编码的点段），主机转小写、去掉末尾的点，默认端口 443 去掉；
/// 然后路径按百分号解码一次再去匹配规则。解析不了、不是 https、带用户信息、没有主机的为 nil。
public struct NormalizedURL: Sendable, Equatable {
    public let host: String
    public let port: Int?
    public let path: String

    public static func parse(_ raw: String) -> NormalizedURL? {
        guard let components = URLComponents(string: browserForm(raw)),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let rawHost = components.host
        else { return nil }
        var host = rawHost.lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        let port = components.port == 443 ? nil : components.port
        let resolved = removeDotSegments(components.percentEncodedPath)
        let decoded = resolved.removingPercentEncoding ?? resolved
        return NormalizedURL(host: host, port: port, path: decoded.isEmpty ? "/" : decoded)
    }

    /// 特殊 scheme 的地址里，查询串与片段之前的反斜杠按斜杠处理（WHATWG URL）。
    static func browserForm(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cut = trimmed.firstIndex(where: { $0 == "?" || $0 == "#" }) else {
            return trimmed.replacingOccurrences(of: "\\", with: "/")
        }
        return trimmed[..<cut].replacingOccurrences(of: "\\", with: "/") + trimmed[cut...]
    }

    /// 消除点段（RFC 3986 §5.2.4 / WHATWG：`.`、`%2e` 为单点段，`..`、`.%2e`、`%2e.`、`%2e%2e` 为双点段，不分大小写）。
    static func removeDotSegments(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        for (index, segment) in segments.enumerated() {
            let lowered = segment.lowercased()
            let isLast = index == segments.count - 1
            if index == 0, segment.isEmpty {
                continue
            }
            if [".", "%2e"].contains(lowered) {
                if isLast {
                    output.append("")
                }
                continue
            }
            if ["..", ".%2e", "%2e.", "%2e%2e"].contains(lowered) {
                if !output.isEmpty {
                    output.removeLast()
                }
                if isLast {
                    output.append("")
                }
                continue
            }
            output.append(segment)
        }
        return "/" + output.joined(separator: "/")
    }
}

/// 链接形态表（/v1/config.link_patterns：`{version, rules:[{platform, category, hosts, path_patterns}]}`）。
/// 主机按「整域含子域」匹配：主机等于规则主机，或以「.规则主机」结尾。path_patterns 为空表示整域命中；非空时路径（规范化、
/// 解码一次）命中其中任一正则才算（正则自带锚点）。表要完整校验：任何一条缺字段、类型不对或正则写错，整张表都算坏表、解析
/// 结果为 nil，调用方整表回落到上一层（APP-04 三端共性第 18 条），不逐条跳过。
public final class LinkPatterns: @unchecked Sendable {
    private struct Rule {
        let platform: String
        let category: String
        let hosts: [String]
        let paths: [NSRegularExpression]
    }

    public static let empty = LinkPatterns(rules: [])

    private let rules: [Rule]

    private init(rules: [Rule]) {
        self.rules = rules
    }

    /// 规则条数（0 = 空表）。
    public var count: Int {
        rules.count
    }

    /// 空表（没有任何规则）。
    public var isEmpty: Bool {
        rules.isEmpty
    }

    /// 命中的全部类别（按表内顺序）。
    public func matches(_ url: NormalizedURL) -> [LinkMatch] {
        rules.filter { rule in
            rule.hosts.contains { Self.hostMatches(url.host, $0) } && Self.pathMatches(rule, url.path)
        }
        .map { LinkMatch(platform: $0.platform, category: $0.category) }
    }

    public static func hostMatches(_ host: String, _ ruleHost: String) -> Bool {
        var target = ruleHost.lowercased()
        while target.hasSuffix(".") {
            target.removeLast()
        }
        return !target.isEmpty && (host == target || host.hasSuffix("." + target))
    }

    /// union_host 按规则主机整域（含子域）阻断，不看 path_patterns：路径规则写得不对也不会因此放行平台域名
    /// （APP-04 三端共性第 18 条）。其他类别 path_patterns 为空时整域命中，否则须命中其中任一正则。
    private static func pathMatches(_ rule: Rule, _ path: String) -> Bool {
        rule.category == LinkCategory.unionHost || rule.paths.isEmpty || rule.paths.contains { regex in
            regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
        }
    }

    /// 解析 link_patterns 对象；不是对象或没有 rules 数组时为 nil（调用方据此回落到上一层）。
    public static func parse(_ table: [String: Any]?) -> LinkPatterns? {
        guard let rules = table?["rules"] as? [Any] else { return nil }
        let parsed = rules.compactMap { ($0 as? [String: Any]).flatMap(rule) }
        guard parsed.count == rules.count else { return nil }
        return LinkPatterns(rules: parsed)
    }

    /// JSON 文本形式（ConfigStore.linkPatternsJson）。
    public static func parse(json: String?) -> LinkPatterns? {
        json.flatMap(JSONKind.object).flatMap(parse)
    }

    private static func rule(_ item: [String: Any]) -> Rule? {
        guard let platform = item["platform"] as? String, !platform.isEmpty,
              let category = item["category"] as? String, isContractCategory(category),
              let hosts = (item["hosts"] as? [Any])?.compactMap({ $0 as? String }), !hosts.isEmpty,
              let rawPaths = item["path_patterns"] as? [Any]
        else { return nil }
        // 主机必须是合法主机名：带协议、路径、端口的写法永远匹配不上，等于悄悄放行（三端共性第 40 条）——整表算坏表。
        guard hosts.count == (item["hosts"] as? [Any])?.count, hosts.allSatisfy(isHostName) else { return nil }
        let compiled = rawPaths.map { ($0 as? String).flatMap { try? NSRegularExpression(pattern: $0) } }
        // 有写错的正则：整张表算坏表（调用方整表回落）。
        guard !compiled.contains(where: { $0 == nil }) else { return nil }
        return Rule(platform: platform, category: category, hosts: hosts, paths: compiled.compactMap(\.self))
    }

    /// 类别属于契约枚举 `link_pattern_category`（拼错的类别不拦任何东西，按坏表处理）。
    static func isContractCategory(_ category: String) -> Bool {
        LinkPatternCategory.allCases.contains { $0.rawValue == category }
    }

    /// 合法主机名（RFC 1123 标签，不分大小写）：点分标签，每个标签 1–63 个字母、数字或连字符，不以连字符开头或结尾，
    /// 总长不超过 253。带协议、路径、端口、用户信息、空白或末尾点的一律不合法。
    static func isHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
