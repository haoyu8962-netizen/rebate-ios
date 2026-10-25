import DesignSystem
import ProductSearch
import SwiftUI
import Trade

/// 详情页用到的文案键（三端同名）。契约已有的（error.*、external_page.retry）直接取；其余在 App 草稿表 SearchDraftTexts
/// （TODO(N-27) 待定稿，不得提审）。本模块不出现中文。
public enum ProductKeys {
    public static let title = "product.title"
    public static let back = "product.back"
    public static let askAI = "product.ask_ai"
    public static let image = "product.image"
    public static let research = "product.research"
    public static let priceStale = "card.price_stale"
    public static let settleNote = "product.settle_note"
    public static let retry = "external_page.retry"
    /// 购买超时条（ProductBuyTimeout，契约 buy.timeout）。
    public static let buyTimeout = "buy.timeout"
    /// 比价原因行与相似商品入口（ProductPriceCompareCancelled，BR-PRICE-08；契约 no_rebate.price_compare*）。
    public static let compareReason = "no_rebate.price_compare"
    public static let similar = "no_rebate.price_compare.similar"
    /// 明确未安装、全部路径失败后的按钮（ProductJumpNotInstalled，BR-ATTR-27 ②；草稿 TODO(N-28)）。
    public static let notInstalled = "trade.not_installed"
    /// 30143（商品信息已失效，请重新搜索，error-codes navigate → Search）。
    static let refExpiredCode = 30143
    /// 30141（商品已下架，置灰；BR-PRICE-21）。
    static let offShelfCode = 30141
    /// 卡片 availability=off_shelf（下架原位置灰，BR-PRICE-14）。
    static let offShelfAvailability = "off_shelf"
}

/// 详情页配置（App 组合：执行器、文案、跳转出口）。
@MainActor
public final class ProductPageConfig: ObservableObject {
    public let controller: ProductDetailController
    public let texts: SearchTexts
    public var onBack: () -> Void = {}
    /// 30143：回到搜索（经 Router 打开 Search）。
    public var onResearch: () -> Void = {}
    /// 【问问 AI】（经 Router 打开 AgentChat，routes.json 登记的 AI 助手路由；页面本身在 APP-10）。
    public var onAskAI: () -> Void = {}
    /// 购买意图（APP-06b：App 交给 OpenPurchaseController.buy）。
    public var onBuyIntent: (_ product: [String: Any]) -> Void = { _ in }
    /// 【看看相似商品】（BR-PRICE-08：同平台、原样标题；详情首次进入、没点过购买也可用，共性第 15 条）。
    public var onSimilar: (_ product: [String: Any]) -> Void = { _ in }
    /// 本页的购买执行器（APP-06b）：底栏按钮的加载 / 限流 / 安装提示、超时条；浮层由 App 盖在页面之上。
    public var purchase: OpenPurchaseController?
    /// 待跟单卡（APP-08 G07：外跳回到前台后拉一次，只显示同平台那一张；设计稿 ProductPendingTrack 在内容与底栏之间）。App 给，卡片视图在
    /// Orders 功能模块；nil = 不显示。
    public var pendingTrack: AnyView?

    public init(controller: ProductDetailController, texts: SearchTexts) {
        self.controller = controller
        self.texts = texts
    }
}

/// 商品详情页（App 内高保真第 1 批定稿 Product-v2 / ProductJd / ProductDark / ProductOffShelf-v3 / ProductPriceCompareCancelled-v2，
/// APP-06v-a）：组件库导航栏（返回 + 居中标题）→ 可滚内容列（头图 contain → 价格大卡 → 口径块常驻全文）→ 底栏（【问问 AI】竖排入口
/// + 购买按钮，200% 时按测量改两行）。价格走势、收藏（APP-16，G-D01）、分享赚（G-D02）、搜相似商品（APP-SIM，G-D06）不在这里。
/// 公开态（游客 / 基本模式）版式相同。取数、判定与购买执行器不变（只改版式）。
public struct ProductDetailScreen: View {
    private let config: ProductPageConfig
    @ObservedObject private var controller: ProductDetailController
    /// 购买按钮的读屏焦点：购买弹层关闭后回到这里（A11yFocusAuthSheet「返回」）。
    @AccessibilityFocusState private var buyFocused: Bool

    public init(config: ProductPageConfig) {
        self.config = config
        controller = config.controller
    }

    private var texts: SearchTexts {
        config.texts
    }

    public var body: some View {
        VStack(spacing: 0) {
            NavBar(
                title: texts.text(ProductKeys.title), backLabel: texts.text(ProductKeys.back), onBack: config.onBack
            )
            .background(CouliColor.backgroundCanvas)
            GeometryReader { proxy in
                content(viewport: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.productSafeAreaBottom, proxy.safeAreaInsets.bottom)
            }
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .task { controller.start() }
    }

    @ViewBuilder private func content(viewport: CGFloat) -> some View {
        let snapshot = controller.snapshot
        switch snapshot.phase {
        case .loading:
            ProductDetailSkeleton(accessibilityLabel: texts.text("search.loading"))
                .accessibilityIdentifier("product.loading")
        case .error:
            errorView(snapshot)
        case .content:
            if let product = snapshot.product, let view = snapshot.view {
                loaded(product, view: view, viewport: viewport)
            }
        }
    }

    @ViewBuilder private func errorView(_ snapshot: ProductSnapshot) -> some View {
        let error = snapshot.error
        let message = SearchErrorText.text(error, texts: texts, currentPlatform: controller.platform)
        if error?.code == ProductKeys.refExpiredCode {
            EmptyState(
                icon: .alert, title: message, actionTitle: texts.text(ProductKeys.research), action: config.onResearch
            )
            .accessibilityIdentifier("product.refExpired")
        } else if error?.code == ProductKeys.offShelfCode {
            // 已下架：不给购买、不给重试（BR-PRICE-21；按钮文案键未规定，TODO(N-27)）。
            EmptyState(icon: .alert, title: message)
                .accessibilityIdentifier("product.offShelf")
        } else {
            ErrorState(title: message, retryTitle: texts.text(ProductKeys.retry)) {
                controller.retry()
            }
            .disabled(snapshot.retryBlocked)
            .accessibilityIdentifier("product.error")
        }
    }

    private func loaded(_ product: [String: Any], view: ProductDetailView, viewport: CGFloat) -> some View {
        var mapping = ProductCardMapper.map(product, texts: texts.text, buyEnabled: view.buyEnabled)
        // 平台购买状态（R2-01、R3-02）：按钮置灰；明确 not_launched 时大卡不显示返利金额与预估返后。
        mapping.data = ProductCardMapper.applyPurchaseStatus(
            mapping.data, statusRaw: controller.snapshot.purchase.rawValue, texts: texts.text
        )
        return VStack(spacing: 0) {
            ScrollView {
                column(product, mapping: mapping, view: view, viewport: viewport)
            }
            if let pendingTrack = config.pendingTrack {
                pendingTrack
                    .frame(maxWidth: ProductLayout.maxContentWidth)
                    .frame(maxWidth: .infinity)
            }
            if let purchase = config.purchase {
                ProductPurchaseBar(purchase: purchase, texts: texts, buyFocus: $buyFocused) { state in
                    bottomBar(product, mapping: mapping, purchase: state)
                }
            } else {
                bottomBar(product, mapping: mapping, purchase: nil)
            }
        }
    }

    /// 可滚内容列（§2）：头图 → 价格大卡 →（价格走势：APP-16，G-D01，不绘制）→ 口径块；页面左右 16、区块间距 12，≥600 限宽居中。
    private func column(
        _ product: [String: Any], mapping: ProductCardMapping, view: ProductDetailView, viewport: CGFloat
    ) -> some View {
        // 价格大卡外框宽：视口宽 − 页边距 16 × 2，限宽 600（不受内容撑宽，供超长金额退档判断；评审 r1 S1-1）
        let cardWidth = min(viewport - CouliSpacing.s4 * 2, ProductLayout.maxContentWidth)
        let title = product["title"] as? String ?? ""
        // 下架原位置灰（ProductOffShelf-v3；availability=off_shelf，含 open 返回 30141 写进卡片的）：映射与按钮置灰不变，只改版式。
        let offShelf = product["availability"] as? String == ProductKeys.offShelfAvailability
        // BR-TEXT-17：ad_label 非 null 原样角标（G-D04；空串按无，不 trim）。
        let adLabel = (product["ad_label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let compare = !offShelf && product["no_rebate_cause"] as? String == "price_compare"
        let lines = disclaimerLines(mapping, view: view)
        return VStack(alignment: .leading, spacing: CouliSpacing.s3) {
            // 契约 image（共性 22）：完整显示（contain），加载中、为空、失败时显示占位底。
            ProductDetailHero(
                url: ProductImageSource.url(product["image"]),
                accessibilityLabel: texts.format(ProductKeys.image, ["title": title]),
                adLabel: adLabel,
                grayscale: offShelf
            )
            ProductDetailCard(
                mapping.data,
                fetchedAt: mapping.quotedAt,
                shopName: mapping.shopName,
                staleNote: view.stale ? texts.text(ProductKeys.priceStale) : nil,
                offShelfLabel: offShelf ? texts.text("error.\(ProductKeys.offShelfCode)") : nil,
                rebateOverride: compare ? AnyView(compareReason(product)) : nil,
                width: cardWidth
            )
            // 容器保留子元素（读屏各项不变），标识只给容器，不覆盖内部「平台 + 商品名」的 product.title。
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("product.header")
            // 下架时口径块整块不显示。
            if !offShelf, !lines.isEmpty {
                ProductDetailDisclaimer(lines: lines)
                    .accessibilityIdentifier("product.disclaimer")
            }
        }
        .frame(maxWidth: ProductLayout.maxContentWidth)
        .couliProbe("product.content", role: "column")
        .padding(.top, CouliSpacing.s2)
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.bottom, CouliSpacing.s4)
        .frame(maxWidth: .infinity)
    }

    /// 比价原因行（ProductPriceCompareCancelled-v2；APP-06b 共性第 15 条：卡片上有 no_rebate_cause=price_compare 就显示，首次进入也有）：
    /// 放在价格大卡内返利标签的位置（§2.3），回调不变。
    private func compareReason(_ product: [String: Any]) -> some View {
        ProductCompareReasonRow(
            reason: texts.text(ProductKeys.compareReason),
            similarTitle: texts.text(ProductKeys.similar)
        ) {
            config.onSimilar(product)
        }
    }

    /// 口径说明框：disclaimer_keys 的句子 + 入账说明（共性 15，BR-TEXT-04、F-PROD-05：设计稿 Product 第二行「确认收货后随联盟
    /// 月度结算入账」）。入账说明按入账规则（`ProductCardMapper.showsSettleNote`）：这张卡不返利（暂无返利）或价格不可用时
    /// 不显示；平台购买状态 not_launched 只隐藏金额，不影响这句（R3F-04，共性 34）。
    private func disclaimerLines(_ mapping: ProductCardMapping, view: ProductDetailView) -> [DisclaimerFooter.Line] {
        var lines = mapping.disclaimerLines.map { DisclaimerFooter.Line($0, icon: .info) }
        let settle = texts.text(ProductKeys.settleNote)
        if !settle.isEmpty, ProductCardMapper.showsSettleNote(mapping.data, priceUnavailable: view.priceUnavailable) {
            lines.append(DisclaimerFooter.Line(settle, icon: .clock))
        }
        return lines
    }

    /// 底栏（§2.6）。购买按钮按平台购买状态（features.platform_status，R2-01；已由 applyPurchaseStatus 并入 mapping）：维护中置灰
    /// 「稍后再试」，未开放置灰「{平台}返利即将开放」；配置变化时随执行器发布刷新，点击时执行器再核对一次。
    /// 【收藏】属 APP-16（G-D01）、【分享赚】属公开版（G-D02），本任务不绘制。
    private func bottomBar(
        _ product: [String: Any], mapping: ProductCardMapping, purchase: PurchaseState?
    ) -> some View {
        var state = mapping.data.buyState
        if state == .normal, let purchase {
            // 购买在途：按钮加载态；42901 限流：置灰（APP-06b，共性第 11 条）
            if purchase.phase == .loading {
                state = .loading
            } else if purchase.rateLimited {
                state = .disabled
            }
        }
        let notInstalled = state == .normal && purchase?.notInstalled == true
        return ProductBottomBarShell {
            ProductBottomBarLayout {
                ProductBarEntry(icon: .chat, title: texts.text(ProductKeys.askAI), probeID: "product.askAI",
                                action: config.onAskAI)
                    .accessibilityIdentifier("product.askAI")
                buyButton(product, mapping: mapping, state: state, notInstalled: notInstalled)
                    .accessibilityFocused($buyFocused)
                    .accessibilityIdentifier("product.buy")
                    .couliProbe("product.buy", role: "hit")
            }
        }
    }
}

extension ProductDetailScreen {
    /// 购买按钮。明确未安装、全部路径失败（ProductJumpNotInstalled）：「安装X后下单才有返利」，点了重新发起一次购买（新键，A08 同口径）。
    @ViewBuilder
    func buyButton(
        _ product: [String: Any], mapping: ProductCardMapping, state: BuyButtonState, notInstalled: Bool
    ) -> some View {
        let tap = {
            if controller.buyIntent() {
                config.onBuyIntent(product)
            }
        }
        if notInstalled {
            let name = texts.text("platform." + controller.platform)
            CouliButton(
                texts.format(ProductKeys.notInstalled, ["platform_name": name]), fillsWidth: true,
                labelProbeID: "product.buy.label", action: tap
            )
        } else {
            BuyButton(
                base: mapping.data.buyBase, rebate: mapping.data.rebate, context: .detail, state: state, size: .regular,
                fillsWidth: true, labelProbeID: "product.buy.label", action: tap
            )
        }
    }
}

/// 大屏（最小宽度 ≥ 600pt，03 §10.4）：详情内容限宽并水平居中。
enum ProductLayout {
    static let maxContentWidth: CGFloat = 600
}

/// 订阅购买执行器的底栏：超时条（ProductBuyTimeout：「网络不稳定，请重试」+【重试】，沿用原键）在底栏上方；底栏按购买状态渲染。
struct ProductPurchaseBar<Bar: View>: View {
    @ObservedObject var purchase: OpenPurchaseController
    let texts: SearchTexts
    let buyFocus: AccessibilityFocusState<Bool>.Binding
    @ViewBuilder let bar: (PurchaseState) -> Bar

    var body: some View {
        VStack(spacing: 0) {
            if purchase.state.phase == .timeout {
                // 渲染时捕获这次超时的编号（r3g NEW-02），旧回调重放不了之后的超时
                let ticket = purchase.state.loadingTicket
                RetryBanner(
                    message: texts.text(ProductKeys.buyTimeout),
                    retryTitle: texts.text(ProductKeys.retry),
                    isEnabled: !purchase.state.rateLimited
                ) {
                    purchase.retryAfterTimeout(ticket)
                }
                .padding(.horizontal, CouliSpacing.s4)
                .padding(.bottom, CouliSpacing.s2)
                .accessibilityIdentifier("product.buyTimeout")
            }
            bar(purchase.state)
        }
        .onChange(of: purchase.state.dialog == nil) { closed in
            // 弹层关闭（取消、授权取消、确认后）：焦点回到底栏购买按钮（A11yFocusAuthSheet；DS 弹层关闭动画后再移）
            guard closed else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                buyFocus.wrappedValue = true
            }
        }
    }
}
