import Foundation

/// 一轮查询的条件（进程回收后恢复用；不含 cursor）。
public struct OrderConditions: Codable, Equatable, Sendable {
    public var scope: String
    public var group: String
    public var platform: String?
    public var month: String?
    public var keyword: String?

    public init(scope: String, group: String = OrderQuery.all, platform: String? = nil, month: String? = nil,
                keyword: String? = nil) {
        self.scope = scope
        self.group = group
        self.platform = platform
        self.month = month
        self.keyword = keyword
    }
}

/// 订单列表的查询状态（纯逻辑，三端向量 query 组；BR-TEXT-02 细则「订单列表的状态分组与查找」、G11）：
/// - 只带非默认的参数：scope 必带；status_group 为 all 时不带（契约「不传 = 全部」）；平台、月份、搜索词为空不带；从不带 display_status；
/// - 搜索词只去首尾空白（含全角空格），其余原样上传（客户端不做任何匹配）；规整后为空不带；最多 40 个 Unicode 码点（超长截到 40，I01）；
/// - 切子 Tab：分组回到「全部」，平台、月份、搜索词清空；筛选可叠加；
/// - 任一条件变化或下拉刷新都开新一轮（cursor 清空）；翻页带上一页的 next_cursor，为 null 时不再发请求。
public struct OrderQuery: Equatable, Sendable {
    public static let selfScope = "self"
    public static let shareScope = "share"
    public static let all = "all"
    /// 搜索框最多 40 个 Unicode 字符（openapi listOrders q maxLength 40，G11）。
    public static let qMax = 40
    /// 状态分组（enum order_status_group）；顺序即胶囊顺序。
    public static let groups = [all, "estimating", "credited", "no_rebate"]

    public private(set) var scope: String
    public private(set) var group = OrderQuery.all
    public private(set) var platform: String?
    public private(set) var month: String?
    public private(set) var keyword: String?
    public private(set) var cursor: String?
    /// 查询轮次：任一条件变化或刷新加 1（翻页不变）。
    public private(set) var round = 0
    /// 最近一次翻页拿到的 next_cursor 为 null：已到底，不再发翻页请求。
    private var exhausted = false

    private init(scope: String) {
        self.scope = scope
    }

    /// 路由参数 scope（routes.json OrderList：self / share，缺省 self）。
    public static func initial(_ scope: String?) -> OrderQuery {
        OrderQuery(scope: normalizeScope(scope))
    }

    /// 按保存的条件重建（进程回收后恢复；不合法的条件丢弃）。
    public static func restore(_ saved: OrderConditions) -> OrderQuery {
        var query = OrderQuery(scope: normalizeScope(saved.scope))
        query.group = groups.contains(saved.group) ? saved.group : all
        query.platform = saved.platform.flatMap { $0.isEmpty ? nil : $0 }
        query.month = saved.month.flatMap { isMonth($0) ? $0 : nil }
        query.keyword = normalizeQ(saved.keyword)
        return query
    }

    /// 原地修改（三端测试接线约定）：set_scope、set_group、set_platform、set_month、set_q、next_page、refresh。
    public mutating func apply(_ op: String, _ value: String?) {
        switch op {
        case "set_scope": setScope(value)
        case "set_group": setGroup(value)
        case "set_platform": setPlatform(value)
        case "set_month": setMonth(value)
        case "set_q": setQ(value)
        case "next_page": nextPage(value)
        case "refresh": newRound()
        default: break
        }
    }

    /// 切子 Tab：分组回到「全部」、其余条件清空（BR-TEXT-02 细则）。
    public mutating func setScope(_ value: String?) {
        scope = Self.normalizeScope(value)
        group = Self.all
        platform = nil
        month = nil
        keyword = nil
        newRound()
    }

    public mutating func setGroup(_ value: String?) {
        group = value.flatMap { Self.groups.contains($0) ? $0 : nil } ?? Self.all
        newRound()
    }

    public mutating func setPlatform(_ value: String?) {
        platform = value.flatMap { $0.isEmpty ? nil : $0 }
        newRound()
    }

    public mutating func setMonth(_ value: String?) {
        month = value.flatMap { Self.isMonth($0) ? $0 : nil }
        newRound()
    }

    /// 提交或清空搜索框（不是每次键入；G11）。
    public mutating func setQ(_ value: String?) {
        keyword = Self.normalizeQ(value)
        newRound()
    }

    /// 翻页：带上一页的 next_cursor；为 null 时不再发请求（`sendsRequest` = false）。
    public mutating func nextPage(_ nextCursor: String?) {
        guard let nextCursor, !nextCursor.isEmpty else {
            exhausted = true
            return
        }
        cursor = nextCursor
        exhausted = false
    }

    /// 下拉刷新 / 重试：新一轮（第一页）。
    public mutating func newRound() {
        cursor = nil
        exhausted = false
        round += 1
    }

    /// 这一刻要不要发请求：已到底的翻页不发。
    public func sendsRequest() -> Bool {
        !exhausted
    }

    /// 请求参数（只带非默认的；三端向量 params）。
    public func params() -> [String: Any] {
        var out: [String: Any] = ["scope": scope]
        if group != Self.all {
            out["status_group"] = group
        }
        if let platform {
            out["platform"] = platform
        }
        if let month {
            out["paid_month"] = month
        }
        if let keyword {
            out["q"] = keyword
        }
        if let cursor {
            out["cursor"] = cursor
        }
        return out
    }

    /// 查询串（ApiCall.query；按名排序、百分号编码，不含 "?"）。
    public func queryString() -> String {
        let pairs = params().compactMap { key, value -> (String, String)? in
            (value as? String).map { (key, $0) }
        }
        return pairs.sorted { $0.0 < $1.0 }.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
    }

    /// 默认视图（全部分组、没有平台 / 月份 / 搜索词）：只有它的第一页可以落盘缓存（G10）。
    public var isDefaultView: Bool {
        group == Self.all && platform == nil && month == nil && keyword == nil
    }

    /// 有筛选或搜索词（传输失败时不用缓存，G10）。
    public var filtered: Bool {
        !isDefaultView
    }

    public var conditions: OrderConditions {
        OrderConditions(scope: scope, group: group, platform: platform, month: month, keyword: keyword)
    }

    public static func normalizeScope(_ value: String?) -> String {
        value == shareScope ? shareScope : selfScope
    }

    /// 只去首尾空白（含全角空格），超过 40 个 Unicode 码点截到 40（I01）；空为 nil。
    public static func normalizeQ(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let limited = limit(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }

    /// 输入框的上限：按 Unicode 码点截到 40。
    public static func limit(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > qMax else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.prefix(qMax))
        return String(view)
    }

    static func isMonth(_ text: String) -> Bool {
        text.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}

/// 上海时区的公历（BR-TEXT-11，不随设备时区）。
enum OrderClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar
    }()

    static func parts(_ epochMillis: Int64) -> DateComponents {
        let seconds = epochMillis >= 0 ? epochMillis / 1000 : -((-epochMillis + 999) / 1000)
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
    }

    /// ISO 8601（带时区）→ 毫秒；格式不对为 nil（不显示，不猜）。
    static func epochMillis(_ iso: String?) -> Int64? {
        guard let iso else { return nil }
        for formatter in [plain, fractional] {
            if let date = formatter.date(from: iso) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
            }
        }
        return nil
    }

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 「YYYY-MM-DD HH:mm」（订单时间线，BR-TEXT-11）。
    static func minute(_ iso: String) -> String? {
        guard let millis = epochMillis(iso) else { return nil }
        let fields = parts(millis)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", fields.year ?? 0, fields.month ?? 0, fields.day ?? 0, fields.hour ?? 0,
            fields.minute ?? 0
        )
    }
}

/// 月份筛选的选项（G12）：当前月份按本机时钟在 +08:00 下取；earliest_visible_date 非空时从当前月份倒推到它所在的月份（含），为 null 时只给
/// 最近 12 个月；另加「全部月份」（不带 paid_month）。服务端给的很早的日期最多列 10 年。
public enum OrderMonthOptions {
    static let recent = 12
    static let maxMonths = 120

    public static func months(_ earliestVisibleDate: String?, nowMs: Int64) -> [String] {
        let now = OrderClock.parts(nowMs)
        let year = now.year ?? 1970
        let month = now.month ?? 1
        var count = recent
        if let earliest = earliestVisibleDate, earliest.count >= 7,
           let earliestYear = Int(earliest.prefix(4)), let earliestMonth = Int(earliest.dropFirst(5).prefix(2)),
           (1...12).contains(earliestMonth) {
            count = min(max((year - earliestYear) * 12 + (month - earliestMonth) + 1, 1), maxMonths)
        }
        return (0..<count).map { offset in
            let index = year * 12 + (month - 1) - offset
            return String(format: "%04d-%02d", index / 12, index % 12 + 1)
        }
    }

    /// 三端向量的 JSON 出口：{months, includesAll}。
    public static func of(_ earliestVisibleDate: String?, _ nowMs: Int64) -> [String: Any] {
        ["months": months(earliestVisibleDate, nowMs: nowMs), "includesAll": true]
    }
}

/// 平台筛选的选项（G13）：enums/platform 里 phase 为 M-内测 的淘宝、京东、拼多多；nil 为「全部平台」。
public enum OrderPlatformOptions {
    public static let platforms = ["taobao", "jd", "pdd"]
}

/// 订单页用到的时间换算（BR-TEXT-11：+08:00；格式化本身在 DesignSystem 的 CouliFormat）。
public enum OrderFormat {
    /// ISO 8601（带时区）→ 毫秒；格式不对为 nil（不显示，不猜）。
    public static func epochMillis(_ iso: String?) -> Int64? {
        OrderClock.epochMillis(iso)
    }

    /// 付款时间：paid_at；预售单 DEPOSIT_PAID 阶段 paid_at 为 null 时取时间线 deposit_paid 的 at，都没有就不显示。
    public static func paidMillis(_ summary: OrderSummary, timeline: [OrderTimelineItem] = []) -> Int64? {
        if let paid = epochMillis(summary.paidAt) {
            return paid
        }
        guard summary.displayStatus == .depositPaid else { return nil }
        return epochMillis(timeline.first { $0.node == .depositPaid }?.at)
    }

    /// 月份选项的显示参数（{year}、{month}）。
    public static func monthParts(_ month: String) -> (year: String, month: String)? {
        guard OrderQuery.isMonth(month), let value = Int(month.suffix(2)) else { return nil }
        return (String(month.prefix(4)), String(value))
    }
}
