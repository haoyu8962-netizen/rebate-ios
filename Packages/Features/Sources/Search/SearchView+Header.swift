import DesignSystem
import SwiftUI

/// 搜索页头部：搜索栏、平台 Tab、排序、筛选（A11yHitSearch：命中区都不小于 44pt）。
extension SearchView {
    var header: some View {
        VStack(spacing: 0) {
            searchBar
            if !snapshot.tabs.isEmpty, snapshot.phase != .idle {
                tabsRow
                Rectangle().fill(CouliColor.borderSubtle).frame(height: 1).accessibilityHidden(true)
            }
            if snapshot.phase != .idle, snapshot.phase != .unavailable {
                sortRow
                filterRow
            }
        }
        .background(CouliColor.backgroundSurface.ignoresSafeArea(edges: .top))
        // 头部（搜索框、Tab、排序、筛选）字号封顶在辅助字号第 2 档（≈200%，与 DS NavBar 同一做法，03 §10.4），
        // 最大辅助字号下结果区仍占屏幕大半；结果卡片不封顶。
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var searchBar: some View {
        HStack(spacing: CouliSpacing.s2) {
            Button(action: config.onBack) {
                CouliIconView(.back)
                    .foregroundColor(CouliColor.textPrimary)
                    .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityLabel(Text(verbatim: texts.text(SearchKeys.back)))
            .accessibilityIdentifier("search.back")
            searchField
            CouliButton(texts.text(SearchKeys.submit), kind: .primary, size: .compact, isEnabled: !snapshot.blocked) {
                submit()
            }
            .fixedSize()
            .accessibilityIdentifier("search.submit")
        }
        .padding(.leading, CouliSpacing.s1)
        .padding(.trailing, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
    }

    private var searchField: some View {
        HStack(spacing: CouliSpacing.s2) {
            CouliIconView(.search, size: CouliSpacing.s5)
                .foregroundColor(CouliColor.textSecondary)
                .accessibilityHidden(true)
            TextField(text: $page.input) {
                Text(verbatim: texts.text(SearchKeys.placeholder))
            }
            .couliFont(.body)
            .foregroundColor(CouliColor.textPrimary)
            .focused($fieldFocused)
            .submitLabel(.search)
            .onSubmit(submit)
            .accessibilityIdentifier("search.field")
            if !page.input.isEmpty {
                Button {
                    page.input = ""
                    fieldFocused = true
                } label: {
                    CouliIconView(.close, size: CouliGuideMetric.iconInline)
                        .foregroundColor(CouliColor.textSecondary)
                        .couliHitTarget()
                }
                .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                .padding(.vertical, -CouliSpacing.s1)
                .accessibilityLabel(Text(verbatim: texts.text(SearchKeys.clear)))
                .accessibilityIdentifier("search.clear")
            }
        }
        .padding(.leading, CouliSpacing.s3)
        .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
        .background(
            RoundedRectangle(cornerRadius: CouliRadius.button, style: .continuous)
                .strokeBorder(CouliColor.borderControl, lineWidth: 1)
        )
    }

    private var tabsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CouliSpacing.s2) {
                ForEach(snapshot.tabs, id: \.self) { platform in
                    tabButton(platform)
                }
            }
            .padding(.horizontal, CouliSpacing.s2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: texts.text(SearchKeys.tabsLabel)))
    }

    private func tabButton(_ platform: String) -> some View {
        let selected = platform == snapshot.platform
        return Button {
            controller.selectTab(platform)
        } label: {
            VStack(spacing: CouliSpacing.s1) {
                Text(verbatim: texts.text(SearchErrorText.platformKey(platform)))
                    .couliFont(.body, weight: selected ? .couliSemibold : .regular)
                    .foregroundColor(selected ? CouliColor.brandEmphasis : CouliColor.textSecondary)
                    .fixedSize()
                Capsule()
                    .fill(selected ? CouliColor.brandPrimary : Color.clear)
                    .frame(height: 3)
            }
            .padding(.horizontal, CouliSpacing.s3)
            .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
        }
        .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
        .disabled(snapshot.blocked)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("search.tab.\(platform)")
    }

    private var sortRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CouliSpacing.s1) {
                ForEach(SearchSorts.all, id: \.self) { sort in
                    let selected = sort == snapshot.sort
                    Button {
                        controller.selectSort(sort)
                    } label: {
                        Text(verbatim: texts.text(SearchKeys.sort(sort)))
                            .couliFont(.footnote, weight: selected ? .couliSemibold : .regular)
                            .foregroundColor(selected ? CouliColor.textPrimary : CouliColor.textSecondary)
                            .fixedSize()
                            .padding(.horizontal, CouliSpacing.s3)
                            .frame(minWidth: CouliHitTarget.minimum, minHeight: CouliHitTarget.minimum)
                    }
                    .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
                    .disabled(snapshot.blocked)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("search.sort.\(sort)")
                }
            }
            .padding(.horizontal, CouliSpacing.s2)
        }
    }

    private var filterRow: some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: 0) {
            FilterChip(title: texts.text(SearchKeys.filterCoupon), selected: snapshot.hasCoupon, showsChevron: false) {
                controller.setFilters(
                    hasCoupon: !snapshot.hasCoupon, minFen: snapshot.priceMinFen, maxFen: snapshot.priceMaxFen
                )
            }
            .disabled(snapshot.blocked)
            .accessibilityIdentifier("search.filter.coupon")
            FilterChip(
                title: priceChipTitle,
                selected: snapshot.priceMinFen != nil || snapshot.priceMaxFen != nil,
                showsChevron: true,
                action: openPriceSheet
            )
            .disabled(snapshot.blocked)
            .accessibilityFocused($priceChipFocused)
            .accessibilityIdentifier("search.filter.price")
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.bottom, CouliSpacing.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priceChipTitle: String {
        let min = snapshot.priceMinFen.map { CouliFormat.money(fen: $0) }
        let max = snapshot.priceMaxFen.map { CouliFormat.money(fen: $0) }
        switch (min, max) {
        case let (min?, max?):
            return texts.format(SearchKeys.filterPriceRange, ["min": min, "max": max])
        case let (min?, nil):
            return texts.format(SearchKeys.filterPriceMinOnly, ["min": min])
        case let (nil, max?):
            return texts.format(SearchKeys.filterPriceMaxOnly, ["max": max])
        default:
            return texts.text(SearchKeys.filterPrice)
        }
    }
}
