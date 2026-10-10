import Foundation
import Generated
import Router

/*
 * 订单卡与详情的显示规则（纯逻辑；三端向量 specs/order-vectors.json）。每个规则一个类型：强类型入口 `view(...)` 给页面用，`of(...)` 是向量的
 * JSON 出口（只做解包与组装，判定都在强类型入口里）。金额只用服务端字段，为 null 时不显示、不补 0、不由别的字段推算（BR-TEXT-02、
 * APP-06a 第 1 条）。
 */

private func nullable(_ value: String?) -> Any {
    JSONPick.value(value)
}

// MARK: - 订单号

/// 订单号的显示（BR-TEXT-02 细则「订单号的显示」）：自购单完整可复制；分享单脱敏原样、不可复制；两个都有或都没有为坏数据，不显示任何单号。
public struct OrderNumberView: Equatable, Sendable {
    public let text: String?
    public let copyable: Bool
    public let valid: Bool
}

public enum OrderNumberDisplay {
    public static func view(_ item: OrderSummary) -> OrderNumberView {
        switch (item.orderNo, item.maskedOrderNo) {
        case let (full?, nil): OrderNumberView(text: full, copyable: true, valid: true)
        case let (nil, masked?): OrderNumberView(text: masked, copyable: false, valid: true)
        default: OrderNumberView(text: nil, copyable: false, valid: false)
        }
    }

    public static func of(_ item: [String: Any]) -> [String: Any] {
        let view = view(OrderJSON.lenientSummary(item))
        return ["text": nullable(view.text), "copyable": view.copyable, "valid": view.valid]
    }

    /// 读屏：脱敏号里的「*」读作「星号」（adaptation-a11y-spec §9），其余原样。
    public static func spoken(_ text: String, star: String) -> String {
        text.replacingOccurrences(of: "*", with: star)
    }
}

// MARK: - 标题与图

/// 标题与商品图：is_other_product 时标题用「好友购买的其他商品」、图用占位；标题为 null 时标题区留空（不编造）、图用占位。
public struct OrderTitleView: Equatable, Sendable {
    public let title: String?
    public let titleKey: String?
    public let imageUrl: String?

    public var usePlaceholderImage: Bool {
        imageUrl == nil
    }
}

public enum OrderTitleImage {
    public static let otherProductKey = "order_list.other_product"

    public static func view(_ item: OrderSummary) -> OrderTitleView {
        if item.isOtherProduct {
            return OrderTitleView(title: nil, titleKey: otherProductKey, imageUrl: nil)
        }
        guard let title = item.title else {
            return OrderTitleView(title: nil, titleKey: nil, imageUrl: nil)
        }
        return OrderTitleView(title: title, titleKey: nil, imageUrl: item.imageUrl)
    }

    public static func of(_ item: [String: Any]) -> [String: Any] {
        let view = view(OrderJSON.lenientSummary(item))
        return [
            "title": nullable(view.title), "titleKey": nullable(view.titleKey),
            "usePlaceholderImage": view.usePlaceholderImage,
        ]
    }
}

// MARK: - 状态文案

/// 状态在文案键里的名字：契约编码原样，UNKNOWN 写成 UNKNOWN（生成枚举的 raw 是 __unknown__）。
extension DisplayStatus {
    var keyName: String {
        self == .unknown ? "UNKNOWN" : rawValue
    }
}

/// 状态文案键（G01：草稿表，原文 BR-TEXT-02 映射表）。INVALID、CLAWED_BACK 的说明由原因区给（WhyNoRebate），这里为 nil。
public struct OrderStatusView: Equatable, Sendable {
    public let status: DisplayStatus
    public let labelKey: String
    public let hintKey: String?
}

public enum OrderStatusText {
    static let hinted: Set<DisplayStatus> = [
        .depositPaid, .paid, .waiting, .crediting, .rightsPending, .reviewing, .unknown,
    ]

    public static func view(_ status: DisplayStatus) -> OrderStatusView {
        let name = status.keyName
        return OrderStatusView(
            status: status, labelKey: "order_status.\(name).label",
            hintKey: hinted.contains(status) ? "order_status.\(name).hint" : nil
        )
    }

    public static func of(_ displayStatus: String) -> [String: Any] {
        let view = view(OrderJSON.status(displayStatus))
        return ["labelKey": view.labelKey, "hintKey": nullable(view.hintKey), "statusRaw": view.status.keyName]
    }
}

// MARK: - 金额格

/// 金额格的一格。`fen` 为 nil 时不显示该格（H07 同口径，整格不显示）；`fixedZero` 是 INVALID 的「返利 ¥0」（映射表原文，固定值，不是推算）；
/// `minus` 是扣回「-¥z」；`maskable` 为金额隐藏开关管得着的格（预估返、实返、推广收益、扣回、返利；实付与已付定金不隐藏，G21）。
public struct AmountCellView: Equatable, Sendable {
    public let labelKey: String
    public let fen: Int64?
    public var minus = false
    public var fixedZero = false
    public var maskable = false
}

/// 两列金额格：`left` 实付 / 已付定金；`right` 预估返、实返、推广收益、扣回或「返利 ¥0」，没有为 nil。
public struct AmountCellsView: Equatable, Sendable {
    public let left: AmountCellView
    public let right: AmountCellView?
}

public enum OrderAmountCells {
    public static let depositKey = "order_list.deposit_amount"
    public static let paidKey = "order_amount.paid"
    public static let estKey = "order_amount.est_rebate"
    public static let actualKey = "order_amount.actual"
    public static let rebateKey = "order_amount.rebate"
    public static let clawbackKey = "order_amount.clawback"
    public static let estPromoKey = "order_amount.est_promo"
    public static let promoKey = "order_amount.promo"
    public static let mask = "****"

    static let estimated: Set<DisplayStatus> = [.paid, .waiting, .crediting, .rightsPending, .reviewing]
    static let credited: Set<DisplayStatus> = [.credited, .creditedPartClawed]

    // TODO(N-31) G02：PAID 的区间「预估返 ¥a–¥b」需要 rebate_min_fen / rebate_max_fen，契约只有 est_rebate_fen，先按单值显示
    public static func view(_ item: OrderSummary) -> AmountCellsView {
        let status = item.displayStatus
        let left = AmountCellView(labelKey: status == .depositPaid ? depositKey : paidKey, fen: item.payAmountFen)
        let share = item.isShare
        let right: AmountCellView? = if estimated.contains(status) {
            AmountCellView(labelKey: share ? estPromoKey : estKey, fen: item.estRebateFen, maskable: true)
        } else if credited.contains(status) {
            AmountCellView(labelKey: share ? promoKey : actualKey, fen: item.actualFen, maskable: true)
        } else if status == .clawedBack {
            AmountCellView(labelKey: clawbackKey, fen: item.clawbackFen, minus: true, maskable: true)
        } else if status == .invalid {
            AmountCellView(labelKey: rebateKey, fen: 0, fixedZero: true, maskable: true)
        } else {
            nil
        }
        return AmountCellsView(left: left, right: right)
    }

    /// 隐藏后的文字：只给可隐藏、且有金额的格（金额为 null 本来就不显示）。
    public static func maskedText(_ cell: AmountCellView, masked: Bool) -> String? {
        masked && cell.maskable && cell.fen != nil ? mask : nil
    }

    /// 金额格的 JSON 出口（三端向量）：隐藏时可隐藏的格 maskedText 为「****」（不带 ¥、位数、正负号）。
    public static func of(_ item: [String: Any], _ masked: Bool) -> [String: Any] {
        let view = view(OrderJSON.lenientSummary(item))
        return ["left": cell(view.left, masked), "right": view.right.map { cell($0, masked) as Any } ?? NSNull()]
    }

    private static func cell(_ cell: AmountCellView, _ masked: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "labelKey": cell.labelKey, "fen": JSONPick.value(cell.fen), "maskedText": nullable(maskedText(
                cell,
                masked: masked
            )),
        ]
        if cell.minus {
            out["sign"] = "minus"
        }
        if cell.fixedZero {
            out["fixedZero"] = true
        }
        return out
    }
}

// MARK: - 预计结算月份

/// 预计结算月份（BR-TEXT-04，OPS-01）：只 WAITING 且 period 非 null 出「预计 {credit_period} 结算」，同年「{M} 月」、跨年「{YYYY} 年 {M} 月」
/// （今天按 +08:00）；客户端只格式化、不推算。PAID 显示「确认收货后随联盟月度结算入账」（G05：入账开关读不到时按开启）。
public struct CreditPeriodView: Equatable, Sendable {
    public let textKey: String?
    public let monthText: String?
}

public enum CreditPeriodText {
    public static let waitingKey = "order_status.WAITING.hint"
    public static let paidKey = "order_status.PAID.hint"

    public static func view(_ status: DisplayStatus, period: String?, nowMs: Int64) -> CreditPeriodView {
        switch status {
        case .waiting:
            guard let month = monthText(period, nowMs: nowMs) else { return CreditPeriodView(
                textKey: nil,
                monthText: nil
            ) }
            return CreditPeriodView(textKey: waitingKey, monthText: month)
        case .paid:
            return CreditPeriodView(textKey: paidKey, monthText: nil)
        default:
            return CreditPeriodView(textKey: nil, monthText: nil)
        }
    }

    /// 「11 月」/「2027 年 1 月」；格式不对为 nil（不显示，不猜）。
    public static func monthText(_ period: String?, nowMs: Int64) -> String? {
        guard let period, OrderQuery.isMonth(period), let year = Int(period.prefix(4)),
              let month = Int(period.suffix(2))
        else { return nil }
        let nowYear = OrderClock.parts(nowMs).year ?? 0
        return year == nowYear ? "\(month) 月" : "\(year) 年 \(month) 月"
    }

    public static func of(_ displayStatus: String, _ period: String?, _ nowMs: Int64) -> [String: Any] {
        let view = view(OrderJSON.status(displayStatus), period: period, nowMs: nowMs)
        return ["textKey": nullable(view.textKey), "monthText": nullable(view.monthText)]
    }
}

// MARK: - 时间线

/// 时间线的一行：`time` 为「YYYY-MM-DD HH:mm」（+08:00），没有时间为 nil 且置灰；credit_expected 的 `monthText` 按 G16。
public struct TimelineRow: Equatable, Sendable {
    public let node: OrderTimelineNode
    public let labelKey: String
    public let time: String?
    public let grey: Bool
    public let monthText: String?
}

/// 时间线（BR-TEXT-02「时间线」）：按响应顺序；不认识的节点忽略（不显示编码原文）；at 为 null 的节点置灰、不显示时间；credit_expected 只在
/// display_status=WAITING 且 period 非 null 时显示「预计 {credit_period} 结算」，否则「联盟结算」（G16）；预售单的 deposit_paid 没有时间时
/// 只显示「付定金」（同一个键的 fallback），final_paid 用「付尾款 {time}」。
public enum OrderTimelineView {
    public static func rows(_ status: DisplayStatus, _ nodes: [OrderTimelineItem], nowMs: Int64) -> [TimelineRow] {
        nodes.compactMap { item in
            let node = item.node
            guard node != .unknown else { return nil }
            let time = item.at.flatMap(OrderClock.minute)
            let month = node == .creditExpected && status == .waiting
                ? CreditPeriodText.monthText(item.period, nowMs: nowMs) : nil
            return TimelineRow(
                node: node, labelKey: "order_timeline.\(node.rawValue)", time: time, grey: time == nil, monthText: month
            )
        }
    }

    public static func of(_ displayStatus: String, _ nodes: [[String: Any]], _ nowMs: Int64) -> [[String: Any]] {
        rows(OrderJSON.status(displayStatus), nodes.compactMap(OrderJSON.timelineItem), nowMs: nowMs).map {
            ["labelKey": $0.labelKey, "time": nullable($0.time), "grey": $0.grey, "monthText": nullable($0.monthText)]
        }
    }
}

// MARK: - 原因区

/// 原因区「为什么没返利？」（AI-09：直接显示，不进 AI、不发任何请求；BR-TEXT-02、03、05）：
/// - INVALID / CLAWED_BACK 且 reason 为已知编码：标题 + 说明（CLAWED_BACK 另加「已从余额扣除」）；
/// - NO_REBATE 且 is_price_compare=true：order.price_compare.hint；
/// - 其他状态下 reason 为 diff 类（PART_REFUND、PRICE_COMPARE、PRICE_PROTECT、SETTLE_DIFF）：只显示原因标题（G03）；
/// - 未知编码不显示原因区（G15），CANCELLED 在枚举里但 BR-TEXT-05 没有文案行，按未知处理。
public struct WhyNoRebateView: Equatable, Sendable {
    public var show: Bool
    public var headingKey: String?
    public var titleKey: String?
    public var descKey: String?
    public var extraKey: String?
    public var hintKey: String?
    public var reason: String?

    public static let hidden = WhyNoRebateView(show: false)
}

public enum WhyNoRebate {
    public static let headingKey = "order_detail.why_no_rebate"
    public static let priceCompareHint = "order.price_compare.hint"
    public static let clawedExtra = "order_reason.clawed_back_extra"

    /// BR-TEXT-05 细则表里有文案的编码（CANCELLED 不在内）。
    public static let known: Set<String> = [
        "REFUND", "PART_REFUND", "RIGHTS", "PUNISH", "PRICE_COMPARE", "PRICE_PROTECT", "SETTLE_DIFF", "NOT_TRACKED",
        "EXPIRED_CLICK", "RELATION_INVALID", "OTHER_TLJ", "BLACKLIST", "PRESALE_UNPAID", "COMMISSION_ZERO", "OTHER",
    ]
    public static let diff: Set<String> = ["PART_REFUND", "PRICE_COMPARE", "PRICE_PROTECT", "SETTLE_DIFF"]

    public static func view(_ detail: OrderDetail) -> WhyNoRebateView {
        let status = detail.summary.displayStatus
        let reason = detail.summary.reason.flatMap { known.contains($0) ? $0 : nil }
        let ended = status == .invalid || status == .clawedBack
        if ended, let reason {
            return WhyNoRebateView(
                show: true,
                headingKey: status == .invalid ? headingKey : nil,
                titleKey: "order_reason.\(reason).title",
                descKey: "order_reason.\(reason).desc",
                extraKey: status == .clawedBack ? clawedExtra : nil,
                reason: reason
            )
        }
        if status == .noRebate, detail.isPriceCompare == true {
            return WhyNoRebateView(show: true, hintKey: priceCompareHint)
        }
        if !ended, let reason, diff.contains(reason) {
            return WhyNoRebateView(show: true, titleKey: "order_reason.\(reason).title", reason: reason)
        }
        return .hidden
    }

    public static func of(_ detail: [String: Any]) -> [String: Any] {
        let view = view(OrderJSON.lenientDetail(detail))
        return [
            "show": view.show, "titleKey": nullable(view.titleKey), "descKey": nullable(view.descKey),
            "hintKey": nullable(view.hintKey), "extraKey": nullable(view.extraKey),
        ]
    }
}
