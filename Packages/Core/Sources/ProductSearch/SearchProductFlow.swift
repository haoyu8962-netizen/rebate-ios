import CouliNetwork
import Foundation
import Generated

// 搜索与商品详情的纯逻辑（APP-06a；向量 specs/search-product-vectors.json，三端同名）。不发请求、不碰界面；执行器
// （SearchController / ProductDetailController）与页面在别处。Search 功能模块转出本模块（`@_exported import`），
// Product 功能模块直接 import 本模块（Feature 之间不互相依赖）。
//
// 规则依据：BR-PROD-07（关键词）、BR-PROD-08（游标）、BR-PROD-10 细则「按平台的搜索开关」、BR-PRICE-08 / 11 / 15 / 21 / 22、
// BR-TEXT-12 / 14、拍板第二批 TRADE-08 / 10 / 21、03 §4.2 / §4.3。
// 规则空白（APP-06a rule-gaps、needs N-27）一律保守处理：判定不了的状态不显示，不用 false / nil 以外的值补造。

/// JSON 取值的小工具（JSONSerialization 的结果；布尔与数字分开，不把 0 / 1 当布尔）。
enum JSON {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func objects(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    /// 真正的 JSON 整数（不把布尔、小数当整数）。
    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integral = number.int64Value
        return NSNumber(value: integral) == number ? integral : nil
    }

    static func parse(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - SearchQuery

/// `SearchQuery.build` 的结果。valid=false 时 query 为空（占位；rule-gaps：无效输入不虚构 reason）。
public struct SearchQueryResult {
    public let valid: Bool
    /// 平铺的契约 query 参数（q、platform、sort、has_coupon、price_min_fen、price_max_fen、cursor）。
    public let query: [String: Any]
    /// TODO(N-27)：无效原因的词表未规定，一律 nil。
    public let reasonRaw: String?

    static var invalid: SearchQueryResult {
        SearchQueryResult(valid: false, query: [:], reasonRaw: nil)
    }

    /// 发出的查询串（不含 "?"；按固定顺序，值做 URL 编码）。无效时为 nil。
    public var queryString: String? {
        guard valid else { return nil }
        var parts: [String] = []
        for key in SearchQuery.order {
            guard let value = query[key] else { continue }
            let text: String = if let flag = value as? Bool {
                flag ? "true" : "false"
            } else {
                "\(value)"
            }
            parts.append(key + "=" + SearchQuery.encode(text))
        }
        return parts.joined(separator: "&")
    }
}

/// 搜索请求的构造（openapi searchProducts 参数）。
public enum SearchQuery {
    /// 关键词长度上限（openapi searchProducts.q maxLength）。
    public static let keywordMax = 100
    /// 价格筛选边界（BR-PRICE-15：整数分 1～10,000,000，两端含，min ≤ max；比 openapi minimum:0 更严，rule-gaps 已登记）。
    public static let priceMinFen: Int64 = 1
    public static let priceMaxFen: Int64 = 10_000_000

    static let order = ["q", "platform", "sort", "has_coupon", "price_min_fen", "price_max_fen", "cursor"]

    /// 关键词规范化（客户端）：首尾去空白、连续空白合并为一个空格。
    /// TODO(N-27)：BR-PROD-07 的 NFKC 与转小写属于服务端 norm(q)（缓存键），客户端是否复用未规定；不改写大小写与兼容字符。
    public static func normalizeKeyword(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// input：keyword（必填）、platform（契约 PlatformCode）、sort（契约 SortCode，省略按 relevance）、
    /// filters {has_coupon?, price_min_fen?, price_max_fen?}、cursor（不透明，原样透传）。
    /// 关键词规范化后 1～100 个 Unicode 码点（TODO(N-27)：长度在规范化前还是后、按什么计数未规定）。
    public static func build(_ input: [String: Any]) -> SearchQueryResult {
        guard let raw = input["keyword"] as? String else { return .invalid }
        let keyword = normalizeKeyword(raw)
        let length = keyword.unicodeScalars.count
        guard length >= 1, length <= keywordMax else { return .invalid }
        guard let platform = input["platform"] as? String, isPlatform(platform) else { return .invalid }
        var sort = Sort.relevance.rawValue
        if let sortRaw = input["sort"], !(sortRaw is NSNull) {
            guard let text = sortRaw as? String, Sort.allCases.contains(where: { $0.rawValue == text }) else {
                return .invalid
            }
            sort = text
        }
        var query: [String: Any] = ["q": keyword, "platform": platform, "sort": sort]
        if let filtersRaw = input["filters"], !(filtersRaw is NSNull) {
            guard let filters = filtersRaw as? [String: Any], apply(filters, to: &query) else { return .invalid }
        }
        if let cursor = input["cursor"], !(cursor is NSNull) {
            guard let text = cursor as? String, !text.isEmpty else { return .invalid }
            query["cursor"] = text
        }
        return SearchQueryResult(valid: true, query: query, reasonRaw: nil)
    }

    private static func apply(_ filters: [String: Any], to query: inout [String: Any]) -> Bool {
        if let coupon = filters["has_coupon"], !(coupon is NSNull) {
            guard let flag = JSON.bool(coupon) else { return false }
            query["has_coupon"] = flag
        }
        guard let min = priceBound(filters["price_min_fen"]), let max = priceBound(filters["price_max_fen"]) else {
            return false
        }
        if let low = min, let high = max, low > high {
            return false
        }
        if let min {
            query["price_min_fen"] = min
        }
        if let max {
            query["price_max_fen"] = max
        }
        return true
    }

    /// 价格边界：缺省 .some(nil)；合法整数分 .some(值)；其余（负数、0、小数、超上限、非数值）nil = 无效。
    static func priceBound(_ value: Any?) -> Int64?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let fen = JSON.int64(value), fen >= priceMinFen, fen <= priceMaxFen else { return nil }
        return .some(fen)
    }

    /// 契约 PlatformCode（不含生成代码的 unknown 占位）。
    public static func isPlatform(_ raw: String) -> Bool {
        Platform.allCases.contains { $0.rawValue == raw }
    }

    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// 价格区间输入（SearchFilterPrice：按元输入，最多两位小数）→ 整数分。不经浮点。
public enum SearchPriceInput {
    /// 空串 → .some(nil)（不限）；合法 → .some(分)；格式不对 → nil。范围由 SearchQuery 判。
    public static func fen(fromYuan raw: String) -> Int64?? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return .some(nil)
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty, whole.count <= 9,
              whole.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        var cents = "00"
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.count <= 2, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            cents = String(fraction) + String(repeating: "0", count: 2 - fraction.count)
        }
        guard let yuan = Int64(whole), let fen = Int64(cents) else { return nil }
        return .some(yuan * 100 + fen)
    }

    /// 分 → 输入框里的元（「10」「10.5」「0.01」）。
    public static func yuanText(_ fen: Int64) -> String {
        let yuan = fen / 100
        let cents = fen % 100
        if cents == 0 {
            return "\(yuan)"
        }
        return cents % 10 == 0 ? "\(yuan).\(cents / 10)" : String(format: "%lld.%02lld", yuan, cents)
    }
}

// MARK: - SearchTabs

/// 搜索平台 Tab（BR-PROD-10 细则「按平台的搜索开关」）。
public enum SearchTabs {
    /// 候选平台与显示顺序：契约 PlatformCode 的顺序。
    public static let candidates: [String] = Platform.allCases.map(\.rawValue)

    /// searchStatus：{current?, lkg?, bundled?}，每层是「平台 → 取值」（ConfigStore.searchStatusLayers）。逐个平台按
    /// current → lkg → bundled 取第一个带该平台取值的层：on 显示；off 与不认识的取值都按 off，且不再回落（未知状态按 off）；
    /// 三层都没有按 off。TODO(N-27)：取值为 JSON null 时按缺失回落（未规定）。
    public static func resolve(_ searchStatus: [String: Any]) -> [String] {
        let layers = ["current", "lkg", "bundled"].compactMap { searchStatus[$0] as? [String: Any] }
        return candidates.filter { platform in
            for layer in layers {
                guard let value = layer[platform], !(value is NSNull) else { continue }
                return (value as? String) == "on"
            }
            return false
        }
    }

    /// 选中的 Tab：想要的平台在可用 Tab 里就用它，否则第一个；没有可用 Tab 为 nil。
    public static func select(_ tabs: [String], wanted: String?) -> String? {
        if let wanted, tabs.contains(wanted) {
            return wanted
        }
        return tabs.first
    }
}

// MARK: - 结果态与分页

/// 结果态（03 §3.2）。
public enum SearchStateRaw {
    public static let content = "content"
    public static let empty = "empty"
    public static let error = "error"
}

/// 分页累积（BR-PROD-08：游标不透明、服务端去重；BR-PRICE-08：has_more 与过滤后页大小无关）。
/// items 只含搜索命中，按服务端顺序追加；fallback_items（无结果推荐）另放，不混入。到底：has_more≠true。
/// TODO(N-27)：has_more=true 却没有 next_cursor 无法继续翻页，按到底处理（矛盾的处理未规定）。
public struct SearchPager {
    public private(set) var items: [[String: Any]] = []
    public private(set) var fallbackItems: [[String: Any]] = []
    public private(set) var endReached = false
    public private(set) var nextCursor: String?
    public private(set) var pages = 0

    public init() {}

    public var stateRaw: String {
        items.isEmpty ? SearchStateRaw.empty : SearchStateRaw.content
    }

    /// 追加一页（完整成功 envelope）。
    public mutating func append(_ envelope: [String: Any]) {
        let data = JSON.object(envelope["data"]) ?? [:]
        items += JSON.objects(data["items"])
        if pages == 0 {
            // fallback_items 只在首页 items 为空时出现（openapi SearchProductsData）。
            fallbackItems = JSON.objects(data["fallback_items"])
        }
        pages += 1
        let cursor = JSON.string(data["next_cursor"])
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
        endReached = JSON.bool(data["has_more"]) != true || nextCursor == nil
    }
}

/// `SearchResultState.map` 的结果（错误时带码、平台、trace_id，页面拼文案用）。
public struct SearchResultView: Equatable, Sendable {
    public let stateRaw: String
    /// error 时的文案键（error.<code>[.<reason>]，Core 错误映射）；字典里没有为 nil（页面用通用失败兜底）。
    public let textKey: String?
    public let code: Int
    /// 50304 等错误带的 data.platform（文案 {platform_name}）。
    public let platform: String?
    public let traceId: String

    public init(stateRaw: String, textKey: String?, code: Int = 0, platform: String? = nil, traceId: String = "") {
        self.stateRaw = stateRaw
        self.textKey = textKey
        self.code = code
        self.platform = platform
        self.traceId = traceId
    }
}

/// 搜索响应 → 结果态（content / empty / error；错误文案 BR-TEXT-14，复用 ErrorActionMapper.resolveTextKey）。
public enum SearchResultState {
    public static func map(_ envelope: [String: Any]) -> SearchResultView {
        let code = JSON.int64(envelope["code"]).map(Int.init) ?? -1
        let data = JSON.object(envelope["data"]) ?? [:]
        let traceId = JSON.string(envelope["trace_id"]) ?? ""
        if code == 0 {
            let hits = JSON.objects(data["items"])
            return SearchResultView(
                stateRaw: hits.isEmpty ? SearchStateRaw.empty : SearchStateRaw.content, textKey: nil, traceId: traceId
            )
        }
        let key = code > 0
            ? ErrorActionMapper.resolveTextKey(code: code, reason: JSON.string(data["reason"])) {
                DefaultTexts.text($0) != nil
            }
            : nil
        return SearchResultView(
            stateRaw: SearchStateRaw.error, textKey: key, code: code, platform: JSON.string(data["platform"]),
            traceId: traceId
        )
    }
}

// MARK: - 请求归属

/// 请求归属与页面世代（lessons：迟到响应只丢弃、出栈即失效）。每次搜索、换 Tab、换排序、换筛选、翻页都 begin 一个
/// 新序号：新请求一开始旧序号就失效（不等新响应）。leave（页面出栈）让当前序号失效；序号单调递增、不复用，重新进入后
/// 旧请求也不会重新生效。accept 只接受当前序号，接受后记为 shownSeq。
public struct SearchSession {
    private var counter: Int64 = 0
    private var current: Int64?
    public private(set) var shownSeq: Int64?

    public init() {}

    public mutating func begin(kind _: String) -> Int64 {
        counter += 1
        current = counter
        return counter
    }

    public func isCurrent(_ seq: Int64) -> Bool {
        current == seq
    }

    /// 响应到达：是当前序号返回 true 并记为已展示；否则丢弃（false）。
    @discardableResult
    public mutating func accept(_ seq: Int64) -> Bool {
        guard isCurrent(seq) else { return false }
        shownSeq = seq
        return true
    }

    public mutating func leave() {
        current = nil
    }
}
