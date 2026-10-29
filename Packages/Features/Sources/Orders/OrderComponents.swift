import DesignSystem
import Generated
import OrderCore
import SwiftUI
import UIKit

/// 本功能用到的文案键（契约 texts.default.json 已有的直接取，缺的在 OrderCore 的 OrderDraftTexts，TODO(N-31)）。
enum OrderKeys {
    static let title = "order_list.title"
    static let tabSelf = "order_list.tab.self"
    static let tabShare = "order_list.tab.share"
    static let findEntry = "order_list.find_entry"
    static let searchPlaceholder = "order_list.search.placeholder"
    static let searchPlaceholderShare = "order_list.search.placeholder_share"
    static let searchLabel = "order_list.search.label"
    static let searchClear = "order_list.search.clear"
    static let filterPlatform = "order_list.filter.platform"
    static let filterMonth = "order_list.filter.month"
    static let allPlatforms = "order_list.filter.all_platforms"
    static let allMonths = "order_list.filter.all_months"
    static let monthNote = "order_list.filter.month_note"
    static let monthItem = "order_list.filter.month_item"
    static let filterClose = "order_list.filter.close"
    static let expanded = "order_list.filter.expanded"
    static let collapsed = "order_list.filter.collapsed"
    static let maskHide = "amount_mask.hide"
    static let maskShow = "amount_mask.show"
    static let emptySelfTitle = "order_list.empty.self.title"
    static let emptySelfMessage = "order_list.empty.self.message"
    static let emptyShareTitle = "order_list.empty.share.title"
    static let emptyShareMessage = "order_list.empty.share.message"
    static let emptyAction = "order_list.empty.action"
    static let searchFound = "order_list.search.found"
    static let searchNone = "order_list.search.none"
    static let shareNote = "order_list.search.share_note"
    static let historyHint = "order_list.history_hint"
    static let loadMore = "order_list.load_more"
    static let loading = "order_list.loading"
    static let end = "order_list.end"
    static let quantity = "order_list.quantity"
    static let orderNo = "order_list.order_no"
    static let copy = "order_list.copy"
    static let copyLabel = "order_list.copy_label"
    static let starSpoken = "order_list.star_spoken"
    static let imagePlaceholder = "order_list.image_placeholder"
    static let retry = "order_list.retry"
    static let loadFailed = "order_list.load_failed"
    static let staleData = "net.stale_data"
    static let detailTitle = "order_detail.title"
    static let back = "order_detail.back"
    static let viewProduct = "order_detail.view_product"
    static let viewHelp = "order_detail.view_help"
    static let timeline = "order_detail.timeline"
    static let descJoin = "order_detail.desc_join"
    static let appealTitle = "order_detail.appeal_pending.title"
    static let appealDesc = "order_detail.appeal_pending.desc"
    static let appealProgress = "order_detail.appeal_progress"
    static let refresh = "order_detail.refresh"
    static let askAI = "order_detail.ask_ai"
    static let notHappened = "order_timeline.not_happened"
    static let creditExpectedMonth = "order_timeline.credit_expected_month"
    static let hiddenSpoken = "amount_mask.hidden_spoken"
    static let groupPrefix = "order_status_group."
}

/// 布局常量。
enum OrderLayout {
    /// 大屏（最小宽度 ≥ 600）内容限宽居中（APP-05a 第 17 条）。
    static let maxContentWidth: CGFloat = 600
    static let imageSize: CGFloat = 64
    /// 分组 / 筛选胶囊视觉高（brief §2.1；命中区另由上下扩展补到 44）。
    static let chipHeight = CouliSpacing.s8
    /// 半屏选项区高度上限：屏高的 45%（一次定下的常量）。
    @MainActor static let sheetOptionsMaxHeight = (UIScreen.main.bounds.height * 0.45).rounded()
}

/// 金额格（03 §10.2 AmountGrid）：左实付 / 已付定金，右返利类（只用服务端字段；金额为 null 的格整格不显示，不补 0，H07 同口径）。
/// 隐藏开关只管返利类格（实付与已付定金不隐藏，G21），所以两格分开交给 AmountGrid。
struct OrderAmountBlock: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let hidden: Bool
    var valueStyle: CouliTextStyle = .title

    var body: some View {
        let view = OrderAmountCells.view(summary)
        let left = view.left.fen.map { AmountGridItem(label: texts.text(view.left.labelKey), value: .amount($0)) }
        let right = view.right.flatMap { cell in
            cell.fen.map {
                AmountGridItem(label: texts.text(cell.labelKey), value: .amount(cell.minus ? -$0 : $0), isRebate: true)
            }
        }
        if left != nil || right != nil {
            OrderSplitAmountGrid(left: left, right: right, hidden: hidden, valueStyle: valueStyle)
                .accessibilityIdentifier("order.amounts")
        }
    }
}

/// 两格分开控制隐藏：返利格跟开关，实付格永远显示。并排时左实付右返利；放不下（任一格最宽金额段超过半宽）或辅助字号档纵排、返利在上。
struct OrderSplitAmountGrid: View {
    let left: AmountGridItem?
    let right: AmountGridItem?
    let hidden: Bool
    let valueStyle: CouliTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let left, let right {
            ViewThatFits(in: .horizontal) {
                if dynamicTypeSize < .accessibility1 {
                    HStack(alignment: .top, spacing: CouliSpacing.s4) {
                        AmountGrid(items: [left], valueStyle: valueStyle, amountHidden: false)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AmountGrid(items: [right], valueStyle: valueStyle, amountHidden: hidden)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    AmountGrid(items: [right], valueStyle: valueStyle, amountHidden: hidden)
                    AmountGrid(items: [left], valueStyle: valueStyle, amountHidden: false)
                }
            }
        } else if let left {
            AmountGrid(items: [left], valueStyle: valueStyle, amountHidden: false)
        } else if let right {
            AmountGrid(items: [right], valueStyle: valueStyle, amountHidden: hidden)
        }
    }
}

/// 订单号行：自购单「订单号 …」+ 独立的【复制】（44 命中区，点击不穿透到整卡）；分享单只显示脱敏原样（普通 Text：不可选中、没有长按菜单、
/// 没有复制按钮），读屏把「*」读作「星号」。坏数据（两个都有或都没有）不显示任何单号。
struct OrderNumberRow: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let onCopy: (String) -> Void

    var body: some View {
        let number = OrderNumberDisplay.view(summary)
        if let text = number.text {
            HStack(alignment: .center, spacing: CouliSpacing.s2) {
                Text(verbatim: texts.format(OrderKeys.orderNo, ["no": text]))
                    .couliFont(.footnote, monospacedDigits: true)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: CouliHitTarget.minimum)
                    .accessibilityLabel(Text(verbatim: texts.format(
                        OrderKeys.orderNo,
                        ["no": OrderNumberDisplay.spoken(text, star: texts.text(OrderKeys.starSpoken))]
                    )))
                    .accessibilityIdentifier(number.copyable ? "order.number" : "order.maskedNumber")
                Spacer(minLength: 0)
                if number.copyable {
                    CouliButton(
                        texts.text(OrderKeys.copy), kind: .text, size: .compact,
                        accessibilityLabel: texts.text(OrderKeys.copyLabel)
                    ) {
                        onCopy(text)
                    }
                    .accessibilityIdentifier("order.copy")
                    .fixedSize()
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// 商品图：image_url 加载中、为 null 或失败时露出占位底（APP-06a 第 22 条）；装饰，读屏不读。无图时占位写「商品图」；
/// 分享单「好友购买的其他商品」（`otherProduct`）为占位底 + 文档图标、不写「商品图」（APP-08v brief-android O14）。
/// `probe`：列表卡的测量前缀（`<probe>.image` / `.placeholder` / `.placeholderIcon`），nil 不量（详情缺省不变）。
struct OrderImage: View {
    let url: String?
    let texts: OrderTexts
    var otherProduct = false
    var probe: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                .fill(CouliColor.backgroundPlaceholder)
            if otherProduct, probe != nil {
                CouliIconView(.orders, size: CouliGuideMetric.iconMedium)
                    .foregroundColor(CouliColor.textSecondary)
                    .orderProbe(probe.map { $0 + ".placeholderIcon" }, role: "icon")
            } else if url == nil {
                Text(verbatim: texts.text(OrderKeys.imagePlaceholder))
                    .couliFont(.caption)
                    .foregroundColor(CouliColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(CouliSpacing.s1)
                    .modifier(OrderPlaceholderProbe(probe: probe, text: texts.text(OrderKeys.imagePlaceholder)))
            }
            ProductRemoteImage(url: ProductImageSource.url(url))
                .clipShape(RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous))
        }
        .frame(width: OrderLayout.imageSize, height: OrderLayout.imageSize)
        .orderProbe(probe.map { $0 + ".image" }, role: "image")
        .accessibilityHidden(true)
    }
}

/// 占位文字的测量（列表卡用；nil 不量）。
private struct OrderPlaceholderProbe: ViewModifier {
    let probe: String?
    let text: String

    func body(content: Content) -> some View {
        if let probe {
            content.couliTextProbe(probe + ".placeholder", role: "text", text: text,
                                   fontSize: CouliTextStyle.caption.baseSize,
                                   baseFontSize: CouliTextStyle.caption.baseSize)
        } else {
            content
        }
    }
}

/// 状态行（钟表 + 状态文案）。CREDITED_PART_CLAWED 的 {z} 只在有扣回金额且没隐藏时填（H04 同口径），否则用不带金额的 fallback。
struct OrderStatusLine: View {
    let summary: OrderSummary
    let texts: OrderTexts
    let hidden: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CouliSpacing.s2) {
            CouliIconView(.clock, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                .foregroundColor(CouliColor.textSecondary)
            Text(verbatim: Self.label(summary, texts: texts, hidden: hidden))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("order.status")
    }

    static func label(_ summary: OrderSummary, texts: OrderTexts, hidden: Bool) -> String {
        let key = OrderStatusText.view(summary.displayStatus).labelKey
        guard summary.displayStatus == .creditedPartClawed, let fen = summary.clawbackFen, !hidden else {
            return texts.text(key)
        }
        return texts.format(key, ["z": CouliFormat.money(fen: fen)])
    }
}

/// 眼睛按钮（金额隐藏开关，G21）：图标 20（APP-08v brief §2.1-7），读屏名称 amount_mask.hide / show，44 命中区。
struct AmountMaskButton: View {
    @ObservedObject var mask: AmountMaskStore
    let texts: OrderTexts

    var body: some View {
        Button {
            mask.toggle()
        } label: {
            CouliIconView(mask.hidden ? .eyeOff : .eye, size: CouliGuideMetric.iconMedium)
                .foregroundColor(CouliColor.textSecondary)
                .couliHitTarget()
        }
        .buttonStyle(CouliPlainButtonStyle())
        .accessibilityLabel(Text(verbatim: texts.text(mask.hidden ? OrderKeys.maskShow : OrderKeys.maskHide)))
        .accessibilityIdentifier("order.mask")
    }
}

/// 订单页的错误正文（统一错误消息：带 trace6，共性第 8、16 条）。
enum OrderErrorText {
    static func text(_ view: OrderErrorView?, texts: OrderTexts) -> String {
        guard let view else { return texts.text(OrderKeys.loadFailed) }
        return OrderErrorAction.message(texts, view)
    }
}

extension OrderToast {
    /// 转成页顶轻提示（经统一的错误消息生成，带 trace6）。
    func couli(_ texts: OrderTexts) -> CouliToastMessage {
        CouliToastMessage(message(texts))
    }
}
