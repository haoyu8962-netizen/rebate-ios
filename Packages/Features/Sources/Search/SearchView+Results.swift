import DesignSystem
import SwiftUI

/// 搜索页内容区：历史、加载、结果（每屏底部常驻口径说明）、空态与推荐、错误、无可搜索平台。
extension SearchView {
    @ViewBuilder var content: some View {
        switch snapshot.phase {
        case .idle:
            SearchHistoryView(texts: texts, history: history) { keyword in
                page.input = keyword
                submit()
            }
        case .loading:
            ScrollView {
                VStack(spacing: CouliSpacing.s3) {
                    noticeBanner
                    ForEach(0..<3, id: \.self) { _ in
                        ProductCardSkeleton(accessibilityLabel: texts.text(SearchKeys.loading))
                    }
                }
                .padding(CouliSpacing.s4)
            }
            .accessibilityIdentifier("search.loading")
        case .content, .empty:
            results
        case .error:
            VStack(spacing: 0) {
                noticeBanner.padding(CouliSpacing.s4)
                // DS ErrorState：立即播报并把焦点移到【重试】（共性 16）；限流期间【重试】保持禁用。
                ErrorState(
                    title: SearchErrorText.text(snapshot.error, texts: texts, currentPlatform: snapshot.platform),
                    retryTitle: texts.text(SearchKeys.retry)
                ) {
                    controller.retry()
                }
                .disabled(snapshot.blocked)
                .accessibilityIdentifier("search.error")
            }
        case .unavailable:
            VStack(spacing: 0) {
                noticeBanner.padding(CouliSpacing.s4)
                EmptyState(title: texts.text(SearchKeys.unavailableTitle))
                    .accessibilityIdentifier("search.unavailable")
            }
        }
    }

    private var results: some View {
        GeometryReader { geometry in
            resultsList(footerHeight: footerHeight(width: geometry.size.width))
        }
    }

    /// 每屏底部口径说明区的高度（共性 21）：只由屏宽与字号决定——窄屏（< 375pt）留 4 行、其余 3 行，每行高随字号缩放，
    /// 封顶 SearchLayout.footerMaxHeight；可见卡片变化只换区内文字，放不下时区内滚动，列表可视高度不跳。
    func footerHeight(width: CGFloat) -> CGFloat {
        SearchLayout.footerHeight(width: width, lineHeight: footerLineHeight)
    }

    private func resultsList(footerHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    Color.clear.frame(height: 0).id(SearchView.topAnchor)
                    noticeBanner
                    if snapshot.stale {
                        NoticeBar(text: texts.text(SearchKeys.staleNotice), icon: .info)
                            .accessibilityIdentifier("search.staleNotice")
                    }
                    if snapshot.phase == .empty {
                        emptyBlock
                    }
                    ForEach(Array(snapshot.items.enumerated()), id: \.offset) { index, item in
                        card(item, index: index, prefix: "search.card")
                            .onAppear {
                                if index == snapshot.items.count - 1 {
                                    controller.loadMore()
                                }
                            }
                    }
                    if snapshot.phase == .content || !snapshot.endReached {
                        footer
                    }
                }
                .padding(CouliSpacing.s4)
                .frame(maxWidth: SearchLayout.maxContentWidth)
                .frame(maxWidth: .infinity)
                .background(SearchScrollViewLocator(tracker: scrollTracker))
            }
            .coordinateSpace(name: SearchScrollSpace.name)
            .accessibilityIdentifier("search.results")
            .onPreferenceChange(SearchCardFramesKey.self, perform: cardFramesChanged)
            // 共性 17：只有开始一轮新查询才回到顶部；共性 20、33：滚动恢复任务的接线（可见性、执行器状态变化）。
            .modifier(SearchRestoreHooks(snapshot: snapshot, page: page, tracker: scrollTracker, proxy: proxy) {
                listOnScreen = $0
            })
            // 共性 14：价格口径全文每屏底部常驻（按当前可见卡片选句），不只放在列表最后。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hasDisclaimerFooter {
                    disclaimerArea(height: footerHeight)
                }
            }
        }
    }

    /// 区高固定（共性 21），放不下就在区内滚动（结果区仍占屏幕大部分；全文在区内可读完）。
    private func disclaimerArea(height: CGFloat) -> some View {
        ScrollView {
            disclaimerFooter
        }
        .frame(height: height)
        .clipped()
        .background(
            CouliColor.backgroundCanvas
                .overlay(alignment: .top) {
                    Rectangle().fill(CouliColor.borderSubtle).frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        )
        .accessibilityIdentifier("search.disclaimerFooter")
    }

    static let topAnchor = "search.top"

    /// R3-01：卡片框交给跟踪器——有恢复任务时按它校正，否则按实际视口记录顶部结果卡及其偏移（被详情盖住时冻结）。
    private func cardFramesChanged(_ frames: [Int: CGRect]) {
        scrollTracker.update(frames)
    }

    /// 结果里有任何适用说明就常驻说明区（按全部结果判断，滚动时不出现、消失）。
    private var hasDisclaimerFooter: Bool {
        !SearchDisclaimers.footerKeys(snapshot.items + snapshot.fallbackItems).map(texts.text).allSatisfy(\.isEmpty)
    }

    private var disclaimerFooter: some View {
        DisclaimerFooter(lines: screenDisclaimerLines.map { DisclaimerFooter.Line($0) })
            .padding(.horizontal, CouliSpacing.s4)
            .padding(.vertical, CouliSpacing.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var emptyBlock: some View {
        EmptyState(title: texts.text(SearchKeys.emptyTitle), message: texts.text(SearchKeys.emptyMessage))
            .accessibilityIdentifier("search.empty")
        if !snapshot.fallbackItems.isEmpty {
            let name = texts.text(SearchErrorText.platformKey(snapshot.platform ?? ""))
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                Text(verbatim: texts.format(SearchKeys.fallbackTitle, ["platform_name": name]))
                    .couliFont(.body, weight: .couliSemibold)
                    .foregroundColor(CouliColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: texts.format(SearchKeys.fallbackNote, ["platform_name": name]))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(snapshot.fallbackItems.enumerated()), id: \.offset) { index, item in
                card(item, index: SearchView.fallbackIndexBase + index, prefix: "search.fallback")
            }
        }
    }

    static let fallbackIndexBase = 10000

    @ViewBuilder private var noticeBanner: some View {
        if let notice = snapshot.notice {
            NoticeBar(
                text: SearchErrorText.text(notice, texts: texts, currentPlatform: snapshot.platform),
                icon: .alert
            )
            .accessibilityIdentifier("search.notice")
        }
    }

    @ViewBuilder private var footer: some View {
        if snapshot.loadingMore {
            HStack(spacing: CouliSpacing.s2) {
                ProgressView()
                Text(verbatim: texts.text(SearchKeys.loading))
            }
            .couliFont(.footnote)
            .foregroundColor(CouliColor.textSecondary)
            .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("search.loadingMore")
        } else if let error = snapshot.loadMoreError {
            // 共性 9：先显示错误文案（带 trace6），再给【重试】。
            VStack(spacing: CouliSpacing.s2) {
                Text(verbatim: SearchErrorText.text(error, texts: texts, currentPlatform: snapshot.platform))
                    .couliFont(.footnote)
                    .foregroundColor(CouliColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("search.loadMoreError")
                CouliButton(
                    texts.text(SearchKeys.retry), kind: .secondary, size: .compact, isEnabled: !snapshot.blocked
                ) {
                    controller.retry()
                }
                .accessibilityFocused($loadMoreRetryFocused)
                .accessibilityIdentifier("search.loadMoreRetry")
            }
            .frame(maxWidth: .infinity)
        } else if snapshot.endReached {
            Text(verbatim: texts.text(SearchKeys.end))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: CouliHitTarget.minimum)
                .accessibilityIdentifier("search.end")
        } else {
            CouliButton(texts.text(SearchKeys.loadMore), kind: .text, size: .compact, isEnabled: !snapshot.blocked) {
                controller.loadMore()
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("search.loadMore")
        }
    }

    /// 每屏底部的口径说明：当前可见卡片的 disclaimer_keys（还没有可见记录时用全部结果）。
    private var screenDisclaimerLines: [String] {
        let all = snapshot.items + snapshot.fallbackItems
        let shown = visible.sorted().compactMap { index -> [String: Any]? in
            if index >= SearchView.fallbackIndexBase {
                let fallback = index - SearchView.fallbackIndexBase
                return fallback < snapshot.fallbackItems.count ? snapshot.fallbackItems[fallback] : nil
            }
            return index < snapshot.items.count ? snapshot.items[index] : nil
        }
        return SearchDisclaimers.footerKeys(shown.isEmpty ? all : shown).map(texts.text).filter { !$0.isEmpty }
    }

    private func card(_ item: [String: Any], index: Int, prefix: String) -> some View {
        let platform = item["platform"] as? String ?? ""
        // 下架（30141 / availability=off_shelf，只绑定这张卡）：购买按钮立即置灰（APP-06b 共性第 5、28 条）
        let offShelf = item["availability"] as? String == "off_shelf"
        var mapping = ProductCardMapper.map(item, texts: texts.text, buyEnabled: !offShelf)
        // 平台购买状态（features.platform_status，R2-01）：维护中置灰「稍后再试」，未开放置灰「{平台}返利即将开放」，
        // 未开放还隐藏返利金额与预估返后（R3-02，设计稿 ProductCardDegrade ①）。
        mapping.data = ProductCardMapper.applyPurchaseStatus(
            mapping.data, statusRaw: page.purchaseStatusRaw(platform: platform), texts: texts.text
        )
        // 本页购买状态（APP-06b）：这张卡的 open 在途显示加载态；42901 限流期间置灰（共性第 11 条）
        if mapping.data.buyState == .normal, let purchase = page.purchaseController?.state {
            if purchase.phase == .loading, purchase.owns(item) {
                mapping.data.buyState = .loading
            } else if purchase.rateLimited {
                mapping.data.buyState = .disabled
            }
        }
        let key = item["product_key"] as? String
        let ref = item["item_ref"] as? String
        let open = {
            if let key, !key.isEmpty {
                config.onOpenProduct(platform, key, ref)
            }
        }
        return ProductCard(
            mapping.data,
            onBuy: {
                // 列表上的购买直接走 open 流程（APP-06b）。点击前按此刻的配置再核对一次平台购买状态（R2-01）。
                if page.buyAllowed(platform: platform), !offShelf {
                    config.onBuy(item)
                }
            },
            onDisclaimer: {
                disclaimerIndex = index
                disclaimer = DisclaimerNote(lines: mapping.disclaimerLines)
            },
            disclaimerFocus: disclaimerIndex == index ? $infoFocused : nil,
            // 契约 image（共性 22）：加载中、为空、失败时显示占位底。
            image: { ProductRemoteImage(url: ProductImageSource.url(item["image"])) }
        )
        .contentShape(Rectangle())
        // 点卡片（读屏双击标题）进详情；卡内 i 按钮与购买按钮各自独立聚焦。
        .onTapGesture(perform: open)
        .modifier(SearchCompareReason(item: item, texts: texts) { config.onSimilar(item) })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix).\(index)")
        // 结果卡（推荐卡不算）在列表视口坐标系里的框：用来找视口顶部的卡（R3-01）。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SearchCardFramesKey.self,
                    value: index < SearchView.fallbackIndexBase
                        ? [index: proxy.frame(in: .named(SearchScrollSpace.name))] : [:]
                )
            }
        )
        .onAppear { visible.insert(index) }
        .onDisappear { visible.remove(index) }
    }
}

/// 比价无返利原因行（ProductPriceCompareCancelled 的卡片原因行；APP-06b 共性第 15 条：搜索卡关闭比价无返利弹窗后也要渲染原因行与
/// 【看看相似商品】）：卡片上 no_rebate_cause=price_compare 时接在卡片下方。
struct SearchCompareReason: ViewModifier {
    let item: [String: Any]
    let texts: SearchTexts
    let onSimilar: () -> Void

    func body(content: Content) -> some View {
        if item["no_rebate_cause"] as? String == "price_compare" {
            VStack(alignment: .leading, spacing: CouliSpacing.s1) {
                content
                CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
                    Text(verbatim: texts.text(SearchKeys.compareReason))
                        .couliFont(.footnote)
                        .foregroundColor(CouliColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CouliButton(texts.text(SearchKeys.similar), kind: .text, size: .compact, action: onSimilar)
                        .accessibilityIdentifier("search.similar")
                }
                .padding(.horizontal, CouliSpacing.s3)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("search.compareReason")
            }
        } else {
            content
        }
    }
}
