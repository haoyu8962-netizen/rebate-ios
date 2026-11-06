import DesignSystem
import ProductSearch
import SwiftUI

/// 排序项（契约 SortCode 的顺序；BR-PRICE-18 的名称在草稿表）。
enum SearchSorts {
    static let all = ["relevance", "sales_desc", "final_price_asc", "rebate_desc"]
}

/// 页底口径说明的键（BR-PRICE-03、09、17；共性 13、25）。合并规则在 DesignSystem 的 `ProductDisclaimers`，首页商品卡同用一份
/// （APP-11 P2）：混排时价格句只放 price_basis.general，有普通返利金额时追加 rebate_estimate，价格句在前。
enum SearchDisclaimers {
    static let rebateEstimate = ProductDisclaimers.rebateEstimate

    static func footerKeys(_ items: [[String: Any]]) -> [String] {
        ProductDisclaimers.footerKeys(items)
    }
}

/// 大屏（最小宽度 ≥ 600pt，03 §10.4）：结果列表限宽并水平居中。
enum SearchLayout {
    static let maxContentWidth: CGFloat = 600
    /// 每屏底部口径说明区的最大高度（约屏高的五分之一；放不下时区内滚动）。
    static let footerMaxHeight: CGFloat = 160
    /// 窄屏（< 375pt）说明区留 4 行，其余 3 行。
    static let narrowWidth: CGFloat = 375

    /// 说明区高度（共性 21）：只由屏宽与字号（每行高）决定，与当前显示哪几句无关。
    static func footerHeight(width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let lines: CGFloat = width < narrowWidth ? 4 : 3
        let content = lines * lineHeight + (lines - 1) * CouliSpacing.s1
        return min(content + CouliSpacing.s2 * 2 + CouliSpacing.s1, footerMaxHeight)
    }
}

/// 结果顶部的提示条（search_disabled、缓存降级）。
struct NoticeBar: View {
    let text: String
    let icon: CouliIcon

    var body: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            CouliIconView(icon, size: CouliComponentMetric.iconInline, relativeTo: .footnote)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .couliFont(.footnote)
        .foregroundColor(CouliColor.textPrimary)
        .padding(CouliSpacing.s3)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .accessibilityElement(children: .combine)
    }
}

/// 筛选胶囊：视觉约 36 高，命中区 44（A11yHitSearch）。
struct FilterChip: View {
    let title: String
    let selected: Bool
    let showsChevron: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CouliSpacing.s1) {
                Text(verbatim: title)
                    .fixedSize(horizontal: false, vertical: true)
                if showsChevron {
                    CouliIconView(.chevronDown, size: CouliComponentMetric.iconSmall, relativeTo: .footnote)
                        .accessibilityHidden(true)
                }
            }
            .couliFont(.footnote, weight: selected ? .couliSemibold : .regular)
            .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textPrimary)
            .padding(.horizontal, CouliSpacing.s3)
            .padding(.vertical, CouliSpacing.s2)
            .background(Capsule().fill(selected ? CouliColor.brandSubtle : CouliColor.backgroundSurface))
            .overlay(
                Capsule().strokeBorder(selected ? CouliColor.brandPrimary : CouliColor.borderSubtle, lineWidth: 1)
            )
            .frame(minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 搜索历史（SearchTyping 画板：搜索历史 +【清空】）。「粘贴查返利」在 APP-07；「搜索发现」「试试这样搜」没有接口来源，不做。
struct SearchHistoryView: View {
    let texts: SearchTexts
    @ObservedObject var history: SearchHistory
    let onPick: (String) -> Void

    var body: some View {
        ScrollView {
            if !history.keywords.isEmpty {
                VStack(alignment: .leading, spacing: CouliSpacing.s2) {
                    HStack {
                        Text(verbatim: texts.text(SearchKeys.historyTitle))
                            .couliFont(.body, weight: .couliSemibold)
                            .foregroundColor(CouliColor.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        CouliButton(texts.text(SearchKeys.historyClear), kind: .text, size: .compact) {
                            history.clear()
                        }
                        .accessibilityIdentifier("search.history.clear")
                    }
                    CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                        ForEach(history.keywords, id: \.self) { keyword in
                            FilterChip(title: keyword, selected: false, showsChevron: false) {
                                onPick(keyword)
                            }
                        }
                    }
                }
                .padding(CouliSpacing.s4)
                .accessibilityIdentifier("search.history")
            }
        }
    }
}
