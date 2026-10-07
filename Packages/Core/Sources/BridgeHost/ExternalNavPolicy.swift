import Foundation

/// 导航去向（三端测试接线约定的 actionRaw）。
public enum ExternalNavAction {
    public static let load = "load"
    public static let block = "block"
    public static let toNativeProduct = "to_native_product"
    public static let cancelReport = "cancel_report"
}

/// 一次导航判定。`reason` 没有契约枚举（TODO(N-22)），只作日志与埋点映射用：非 https 时为 scheme 类别
/// （http、intent、market、tel、sms、mailto、app_scheme、other_scheme，与 events.yaml external_page_blocked_nav.kind 同名），
/// 命中规则时为类别名，解析失败为 invalid_url。`match` 为命中的规则（平台、类别）。
public struct ExternalNavDecision: Sendable, Equatable {
    public let actionRaw: String
    public let reason: String?
    public let match: LinkMatch?

    public init(actionRaw: String, reason: String?, match: LinkMatch? = nil) {
        self.actionRaw = actionRaw
        self.reason = reason
        self.match = match
    }
}

/// 第三方页容器的导航判定（ExternalNavigationPolicy，03 §5.1；规则在 BR-ATTR-29）。输入 URL、框架类型（主框架 / 子框架、
/// 是否新窗口）与规则表，输出去向；没有界面，三端共用一组向量。
///
/// - 先看 scheme：只放行 https；其余（http、intent://、应用市场、tel、sms、mailto、file、javascript、blob、data 及其他自定义
///   scheme）一律 cancel_report（取消并上报，不交给系统，intent:// 不解析也不加载备用地址）。
/// - https 再按链接形态表：product 命中（主机与路径）时，主框架与新窗口请求交原生商品识别（to_native_product），子框架只拦下
///   （block，BR-ATTR-29 ②(b)）；union_host 命中（整域含子域）block；promo 不用于容器导航阻断（load）；其余 load。
/// - 规则表：调用方给的当前表（ConfigStore 的 current → 上一次成功 → 包内）优先；为 nil 时用构造时注入的包内快照，
///   当前表不会与快照逐条合并。
///
/// 不在本函数里的（由容器接线另判，见 Features/Web 的 ExternalWebView）：隐私状态、external_page.product_intercept 开关、
/// 授权页、下载（响应头 / MIME）、子框架回调能否拿到。
public struct ExternalNavPolicy: Sendable {
    public static let invalidURL = "invalid_url"

    private let bundled: LinkPatterns

    public init(bundledLinkPatterns: [String: Any]) {
        bundled = LinkPatterns.parse(bundledLinkPatterns) ?? .empty
    }

    public init(bundled: LinkPatterns) {
        self.bundled = bundled
    }

    public func decide(
        url: String,
        isMainFrame: Bool,
        isNewWindow: Bool,
        linkPatterns: [String: Any]?
    ) -> ExternalNavDecision {
        decide(url: url, isMainFrame: isMainFrame, isNewWindow: isNewWindow, table: table(linkPatterns))
    }

    public func decide(url: String, isMainFrame: Bool, isNewWindow: Bool, table: LinkPatterns) -> ExternalNavDecision {
        let scheme = Self.scheme(of: url)
        guard scheme == "https" else {
            return ExternalNavDecision(actionRaw: ExternalNavAction.cancelReport, reason: Self.schemeKind(scheme))
        }
        guard let normalized = NormalizedURL.parse(url) else {
            return ExternalNavDecision(actionRaw: ExternalNavAction.cancelReport, reason: Self.invalidURL)
        }
        let matches = table.matches(normalized)
        if let product = matches.first(where: { $0.category == LinkCategory.product }) {
            let action = isNewWindow || isMainFrame ? ExternalNavAction.toNativeProduct : ExternalNavAction.block
            return ExternalNavDecision(actionRaw: action, reason: LinkCategory.product, match: product)
        }
        if let union = matches.first(where: { $0.category == LinkCategory.unionHost }) {
            return ExternalNavDecision(actionRaw: ExternalNavAction.block, reason: LinkCategory.unionHost, match: union)
        }
        return ExternalNavDecision(actionRaw: ExternalNavAction.load, reason: nil)
    }

    /// 系统浏览器出口（03 §5.1 can_open_in_browser）：地址是 https 且不命中链接形态表的任何类别（union_host、product、promo）。
    public func canOpenInBrowser(url: String, table: LinkPatterns) -> Bool {
        guard let normalized = NormalizedURL.parse(url) else { return false }
        return table.matches(normalized).isEmpty
    }

    /// 生效的规则表：当前表能解析就用当前表，否则用包内快照。
    public func table(_ current: [String: Any]?) -> LinkPatterns {
        LinkPatterns.parse(current) ?? bundled
    }

    /// 生效的规则表（JSON 文本形式）。
    public func table(json: String?) -> LinkPatterns {
        LinkPatterns.parse(json: json) ?? bundled
    }

    /// URL 的 scheme（小写）；没有合法 scheme 时为空串。
    public static func scheme(of url: String) -> String {
        guard let colon = url.firstIndex(of: ":") else { return "" }
        let candidate = url[..<colon]
        guard let first = candidate.first, first.isASCII, first.isLetter,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return "" }
        return candidate.lowercased()
    }

    /// scheme → external_page_blocked_nav.kind。
    public static func schemeKind(_ scheme: String) -> String {
        switch scheme {
        case "http": "http"
        case "intent": "intent"
        case "market", "itms-apps", "itms-appss": "market"
        case "tel", "telprompt": "tel"
        case "sms", "smsto": "sms"
        case "mailto": "mailto"
        case "", "file", "javascript", "blob", "data", "about", "content": "other_scheme"
        default: "app_scheme"
        }
    }
}
