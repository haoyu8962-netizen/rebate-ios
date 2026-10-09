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

    public init(controller: ProductDetailController, texts: SearchTexts) {
        self.controller = controller
        self.texts = texts
    }
}

/// 商品详情页（设计稿 Product、ProductPublic、ProductCardStress、A11yFocusProduct）：返回 + 标题 → 头图（契约 image，没有或失败时占位）→ 详情大卡
/// （DS-01 ProductDetailHeader：主价、副行、返利、预估返后、取价时间、标签、平台 + 标题、店铺）→ 口径说明框 → 底栏
/// 【问问 AI】+ 购买按钮（服务端 cta.text_key）。价格趋势、收藏、分享赚属于各自的任务，不在这里。
/// 公开态（游客 / 基本模式）版式相同：ProductPublic 的【分享赚】由分享任务决定（rule-gaps）。
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(CouliColor.backgroundCanvas.ignoresSafeArea())
        .task { controller.start() }
    }

    @ViewBuilder private var content: some View {
        let snapshot = controller.snapshot
        switch snapshot.phase {
        case .loading:
            ScrollView {
                ProductCardSkeleton(accessibilityLabel: texts.text("search.loading"))
                    .padding(CouliSpacing.s4)
            }
            .accessibilityIdentifier("product.loading")
        case .error:
            errorView(snapshot)
        case .content:
            if let product = snapshot.product, let view = snapshot.view {
                loaded(product, view: view)
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

    private func loaded(_ product: [String: Any], view: ProductDetailView) -> some View {
        var mapping = ProductCardMapper.map(product, texts: texts.text, buyEnabled: view.buyEnabled)
        // 平台购买状态（R2-01、R3-02）：按钮置灰；明确 not_launched 时大卡不显示返利金额与预估返后。
        mapping.data = ProductCardMapper.applyPurchaseStatus(
            mapping.data, statusRaw: controller.snapshot.purchase.rawValue, texts: texts.text
        )
        let title = product["title"] as? String ?? ""
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CouliSpacing.s3) {
                    // 契约 image（共性 22）：加载中、为空、失败时显示占位底。
                    ProductHeroImage(
                        url: ProductImageSource.url(product["image"]),
                        accessibilityLabel: texts.format(ProductKeys.image, ["title": title])
                    )
                    ProductDetailHeader(
                        mapping.data,
                        fetchedAt: mapping.quotedAt,
                        shopName: mapping.shopName,
                        staleNote: view.stale ? texts.text(ProductKeys.priceStale) : nil
                    )
                    // 容器保留子元素（读屏各项不变），标识只给容器，不覆盖内部「平台 + 商品名」的 product.title。
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("product.header")
                    if product["no_rebate_cause"] as? String == "price_compare" {
                        compareReason(product)
                    }
                    let lines = disclaimerLines(mapping, view: view)
                    if !lines.isEmpty {
                        DisclaimerFooter(lines: lines, style: .boxed)
                            .accessibilityIdentifier("product.disclaimer")
                    }
                }
                .padding(CouliSpacing.s4)
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

    /// 比价原因行（ProductPriceCompareCancelled；APP-06b 共性第 15 条：卡片上有 no_rebate_cause=price_compare 就显示，首次进入也有）。
    private func compareReason(_ product: [String: Any]) -> some View {
        CouliFlowLayout(horizontalSpacing: CouliSpacing.s2, verticalSpacing: CouliSpacing.s1) {
            Text(verbatim: texts.text(ProductKeys.compareReason))
                .couliFont(.footnote)
                .foregroundColor(CouliColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            CouliButton(texts.text(ProductKeys.similar), kind: .text, size: .compact) {
                config.onSimilar(product)
            }
            .accessibilityIdentifier("product.similar")
        }
        .padding(.horizontal, CouliSpacing.s1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("product.compareReason")
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

    /// 底栏。购买按钮按平台购买状态（features.platform_status，R2-01；已由 applyPurchaseStatus 并入 mapping）：维护中置灰
    /// 「稍后再试」，未开放置灰「{平台}返利即将开放」；配置变化时随执行器发布刷新，点击时执行器再核对一次。
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
        return HStack(spacing: CouliSpacing.s3) {
            Button(action: config.onAskAI) {
                VStack(spacing: 2) {
                    CouliIconView(.chat, size: CouliSpacing.s6)
                        .accessibilityHidden(true)
                    Text(verbatim: texts.text(ProductKeys.askAI))
                        .couliFont(.caption)
                        .fixedSize()
                }
                .foregroundColor(CouliColor.textSecondary)
                .couliHitTarget()
            }
            .buttonStyle(CouliPlainButtonStyle(cornerRadius: CouliRadius.small))
            .accessibilityIdentifier("product.askAI")
            buyButton(product, mapping: mapping, state: state, notInstalled: notInstalled)
                .accessibilityFocused($buyFocused)
                .accessibilityIdentifier("product.buy")
        }
        .padding(.horizontal, CouliSpacing.s4)
        .padding(.vertical, CouliSpacing.s2)
        .background(
            CouliColor.backgroundSurface
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle().fill(CouliColor.borderSubtle).frame(height: 1)
                }
        )
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
            CouliButton(texts.format(ProductKeys.notInstalled, ["platform_name": name]), fillsWidth: true, action: tap)
        } else {
            BuyButton(
                base: mapping.data.buyBase, rebate: mapping.data.rebate, context: .detail, state: state, size: .regular,
                fillsWidth: true, action: tap
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
                RetryBanner(
                    message: texts.text(ProductKeys.buyTimeout),
                    retryTitle: texts.text(ProductKeys.retry),
                    isEnabled: !purchase.state.rateLimited
                ) {
                    purchase.retryAfterTimeout()
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
