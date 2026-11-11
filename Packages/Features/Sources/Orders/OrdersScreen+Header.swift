import DesignSystem
import Generated
import OrderCore
import SwiftUI

/// 列表头部（brief §2.1，Orders-v2 自上而下）：标题行（视觉 44）→ 置顶找回行（G-O04）→ 断网提示条 → 子 Tab → 搜索框 → 分组胶囊 → 筛选行。
/// 胶囊与筛选视觉 32、命中区 44 由上下各 6 的透明扩展给出（不撑高视觉，两行扩展相接不重叠，§9 风险 1）。
extension OrdersScreen {
    // MARK: - 标题行

    var titleBar: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s2) {
            OrderProbedText(texts.text(OrderKeys.title), style: .title, weight: .couliSemibold, probeID: "orders.title")
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: CouliSpacing.s2)
            if !snapshot.claimPinned {
                // 右上入口（置顶时不显示，G-O04）。标识 orders.findEntry 也是登录 / OAuth 冒烟「进了订单页」的标志，不改
                Button(action: config.onFindOrder) {
                    OrderProbedText(texts.text(OrderKeys.findEntry), style: .footnote, weight: .couliSemibold,
                                    probeID: "orders.findEntry.label")
                        .foregroundColor(CouliColor.brandEmphasis)
                        .fixedSize(horizontal: false, vertical: true)
                        // 辅助字号下会折行、掉出标题行：带描边，明确是按钮（D10-1223 按钮口径）
                        .couliTextButtonOutline(dynamicTypeSize.isAccessibilitySize)
                        .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle())
                .couliProbe("orders.findEntry", role: "hit")
                .accessibilityIdentifier("orders.findEntry")
            }
        }
        .frame(minHeight: CouliHitTarget.minimum)
        .padding(.horizontal, CouliSpacing.s4)
        .couliProbe("orders.titleRow", role: "row")
        .frame(maxWidth: OrderLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.claimPinned {
                pinnedFindRow.padding(.bottom, CouliSpacing.s3)
            }
            if snapshot.phase == .stale, let at = snapshot.staleAt {
                staleBanner(at).padding(.bottom, CouliSpacing.s3)
            }
            scopeTabs.padding(.bottom, CouliSpacing.s3)
            searchField.padding(.bottom, CouliSpacing.s3)
            groupChips
            filterRow
        }
        .padding(.top, CouliSpacing.s2)
    }

    /// 置顶找回行（OrdersClaimPinned）：`brand.subtle` 浅底圆角整行，找回图标 20 + 「未跟单？去找回」17/600 + ›；整行一个目标 → FindOrder。
    var pinnedFindRow: some View {
        Button(action: config.onFindOrder) {
            HStack(alignment: .center, spacing: CouliSpacing.s2) {
                CouliIconView(.claim, size: CouliComponentMetric.iconMedium)
                    .couliProbe("orders.findPinned.icon", role: "icon")
                OrderProbedText(texts.text(OrderKeys.findEntry), style: .body, weight: .couliSemibold,
                                probeID: "orders.findPinned.label")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: CouliSpacing.s2)
                CouliIconView(.chevron, size: CouliComponentMetric.iconInline)
            }
            .foregroundColor(CouliColor.brandEmphasis)
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.vertical, CouliSpacing.s3)
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
            .background(
                RoundedRectangle(cornerRadius: CouliRadius.card, style: .continuous).fill(CouliColor.brandSubtle)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.card))
        .couliProbe("orders.findPinned", role: "hit")
        .accessibilityIdentifier("orders.findPinned")
    }

    /// 断网提示条（OrdersStale-v2）：警告浅底圆角 12、断网图标 20 +「网络不可用，显示的是 {time} 的数据」14；礼貌播报。
    func staleBanner(_ at: Int64) -> some View {
        let text = texts.format(
            OrderKeys.staleData, ["time": CouliFormat.timeListPast(epochMillis: at, nowEpochMillis: config.now())]
        )
        return HStack(alignment: .center, spacing: CouliSpacing.s2) {
            CouliIconView(.wifiOff, size: CouliComponentMetric.iconMedium, relativeTo: .footnote)
                .couliProbe("orders.stale.icon", role: "icon")
            OrderProbedText(text, style: .footnote, probeID: "orders.stale.text")
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(CouliColor.statusWarningText)
        .padding(CouliSpacing.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .fill(CouliColor.statusWarningBackground)
        )
        .couliProbe("orders.stale", role: "banner")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("orders.stale")
    }

    // MARK: - 子 Tab / 搜索

    var scopeTabs: some View {
        HStack(spacing: CouliSpacing.s1) {
            ForEach([OrderQuery.selfScope, OrderQuery.shareScope], id: \.self) { scope in
                let selected = snapshot.query.scope == scope
                Button {
                    if !selected {
                        searchFocused = false
                        controller.setScope(scope)
                    }
                } label: {
                    Text(verbatim: texts.text(scope == OrderQuery.selfScope ? OrderKeys.tabSelf : OrderKeys.tabShare))
                        .couliFont(.footnote, weight: selected ? .couliSemibold : .regular)
                        .foregroundColor(selected ? CouliColor.textPrimary : CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                        .background(
                            RoundedRectangle(cornerRadius: CouliRadius.small, style: .continuous)
                                .fill(selected ? CouliColor.backgroundSurface : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle())
                .disabled(snapshot.blocked)
                .couliProbe("orders.tab.\(scope)", role: "hit")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("orders.tab.\(scope)")
            }
        }
        .padding(CouliSpacing.s1)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
        .couliProbe("orders.tabs", role: "tabs")
    }

    var searchField: some View {
        let share = snapshot.query.scope == OrderQuery.shareScope
        let placeholder = texts.text(share ? OrderKeys.searchPlaceholderShare : OrderKeys.searchPlaceholder)
        return HStack(spacing: CouliSpacing.s2) {
            CouliIconView(.search, size: CouliComponentMetric.iconMedium)
                .foregroundColor(CouliColor.textSecondary)
            TextField(
                "",
                text: Binding(get: { controller.snapshot.searchText }, set: { controller.updateSearchText($0) }),
                prompt: Text(verbatim: placeholder)
            )
            .couliFont(.body)
            .focused($searchFocused)
            .submitLabel(.search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { controller.submitSearch() }
            .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.searchLabel)))
            .accessibilityIdentifier("orders.search")
            if !snapshot.searchText.isEmpty {
                Button {
                    controller.clearSearch()
                } label: {
                    CouliIconView(.close)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle())
                .disabled(snapshot.blocked)
                .accessibilityLabel(Text(verbatim: texts.text(OrderKeys.searchClear)))
                .accessibilityIdentifier("orders.search.clear")
            }
        }
        .padding(.horizontal, CouliSpacing.s3)
        .frame(minHeight: CouliHitTarget.minimum)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .strokeBorder(CouliColor.borderControl, lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                        .fill(CouliColor.backgroundSurface)
                )
        )
        .couliProbe("orders.searchBox", role: "box")
    }
}
