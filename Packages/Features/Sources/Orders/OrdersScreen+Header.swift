import DesignSystem
import Generated
import OrderCore
import SwiftUI

extension OrdersScreen {
    // MARK: - 头部

    var titleBar: some View {
        HStack(alignment: .center, spacing: CouliSpacing.s2) {
            Text(verbatim: texts.text(OrderKeys.title))
                .couliFont(.heading, weight: .couliBold)
                .foregroundColor(CouliColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: CouliSpacing.s2)
            CouliButton(texts.text(OrderKeys.findEntry), kind: .text, size: .compact, action: config.onFindOrder)
                .accessibilityIdentifier("orders.findEntry")
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
        .frame(maxWidth: OrderLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            scopeTabs
            searchField
            groupChips
            filterRow
        }
        .padding(.top, CouliSpacing.s1)
    }

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
                        .couliFont(.body, weight: selected ? .couliSemibold : .regular)
                        .foregroundColor(selected ? CouliColor.textPrimary : CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                        .background(
                            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                                .fill(selected ? CouliColor.backgroundSurface : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(CouliPlainButtonStyle())
                .disabled(snapshot.blocked)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("orders.tab.\(scope)")
            }
        }
        .padding(CouliSpacing.s1)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous).fill(CouliColor.backgroundMuted)
        )
    }

    var searchField: some View {
        let share = snapshot.query.scope == OrderQuery.shareScope
        let placeholder = texts.text(share ? OrderKeys.searchPlaceholderShare : OrderKeys.searchPlaceholder)
        return HStack(spacing: CouliSpacing.s2) {
            CouliIconView(.search)
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
    }

    var groupChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CouliSpacing.s2) {
                    ForEach(OrderQuery.groups, id: \.self) { group in
                        let selected = snapshot.query.group == group
                        Button {
                            controller.setGroup(group)
                        } label: {
                            Text(verbatim: texts.text(OrderKeys.groupPrefix + group))
                                .couliFont(.footnote, weight: selected ? .couliSemibold : .regular)
                                .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textPrimary)
                                .padding(.horizontal, CouliSpacing.s3)
                                .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                                .background(Capsule()
                                    .fill(selected ? CouliColor.brandSubtle : CouliColor.backgroundSurface))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.pill))
                        .disabled(snapshot.blocked)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .accessibilityIdentifier("orders.group.\(group)")
                        .id(group)
                    }
                }
            }
            .onChange(of: snapshot.query.group) { group in
                withAnimation { proxy.scrollTo(group, anchor: .center) }
            }
        }
    }

    var filterRow: some View {
        HStack(alignment: .top, spacing: CouliSpacing.s2) {
            // 已选长筛选（平台 + 「2026 年 10 月」）在窄屏大字号下换行；眼睛按钮固定行尾、保住完整命中区（共性第 11 条）
            CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                filterButton(
                    label: snapshot.query.platform.map { texts.text("platform." + $0) } ?? texts
                        .text(OrderKeys.filterPlatform),
                    sheet: .platform, focus: $platformFocused
                )
                filterButton(label: monthLabel, sheet: .month, focus: $monthFocused)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AmountMaskButton(mask: mask, texts: texts)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    var monthLabel: String {
        guard let month = snapshot.query.month, let parts = OrderFormat.monthParts(month) else {
            return texts.text(OrderKeys.filterMonth)
        }
        return texts.format(OrderKeys.monthItem, ["year": parts.year, "month": parts.month])
    }

    func filterButton(
        label: String, sheet: OrderFilterSheet, focus: AccessibilityFocusState<Bool>.Binding
    ) -> some View {
        let open = config.sheet == sheet
        return Button {
            config.sheet = sheet
        } label: {
            HStack(alignment: .center, spacing: CouliSpacing.s1) {
                Text(verbatim: label)
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                CouliIconView(.chevronDown, size: CouliGuideMetric.iconInline, relativeTo: .footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize()
            }
            .padding(.horizontal, CouliSpacing.s2)
            .frame(minHeight: CouliHitTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(CouliPlainButtonStyle())
        .disabled(snapshot.blocked)
        .accessibilityFocused(focus)
        .accessibilityValue(Text(verbatim: texts.text(open ? OrderKeys.expanded : OrderKeys.collapsed)))
        .accessibilityIdentifier("orders.filter.\(sheet.rawValue)")
    }
}
