import CouliNetwork
import DesignSystem
import Foundation
import Product
import ProductSearch
import Router
import Search
import Trade

/// 本页面打开的路由名（都在 routes.json 里登记；SearchWiringTests 逐个核对）。
enum AppSearchRoutes {
    static let search = "Search"
    static let productDetail = "ProductDetail"
    /// 【问问 AI】：AI 助手的 Tab 根路由（routes.json AgentChat）。
    static let agentChat = "AgentChat"
    static let all = [search, productDetail, agentChat]
}

/// 购买按钮的 spm（03 §4.7 page.module.slot；三端命名待统一，H10 同口径，TODO(N-28)）。
enum AppSearchSpm {
    static let productBottom = "ProductDetail.bottom.buy"
    static let searchList = "Search.list.buy"
}

/// App 侧的搜索与商品详情（APP-06a）：组合 SearchController / ProductDetailController（ApiClient、AppConfig），给页面配置，
/// 接 Router（路由参数按 routes.json Search、ProductDetail），并在路由真正出栈时让执行器 leave（共性：出栈清理）。
@MainActor
final class AppSearch: ObservableObject {
    /// 页顶轻提示（Debug / Staging 的购买意图提示）。
    @Published var toast: CouliToastMessage?

    let history = SearchHistory()
    let texts = AppSearchTexts()
    private let client: ApiClient
    private let config: AppConfig
    private let privacy: PrivacyController
    private let router: Router
    /// 购买（APP-06b）：每个详情页、搜索页一份 OpenPurchaseController；点击结果确认的平台状态并入卡片映射。
    /// nil = 不接购买（单测组合）：页面按 APP-06a 只到购买意图。
    let trade: AppTrade?
    private let purchaseStatus: PurchaseStatusSource
    /// 路由真正出栈（返回、清栈、整栈替换）时执行 leave；只是被盖住不算（与 WebView 容器同一判定）。
    let lifetimes: WebRouteLifetimes
    /// 进程回收恢复（共性 20）：按路由身份保存页面状态并持久化，冷启动外壳出现后重开。
    let restoration: SearchRouteRestoration

    init(
        network: AppNetwork, config: AppConfig, privacy: PrivacyController, routing: AppRouting, trade: AppTrade? = nil,
        restorationDefaults: UserDefaults = .standard
    ) {
        client = network.client
        self.config = config
        self.privacy = privacy
        self.trade = trade
        purchaseStatus = trade.map { TradePurchaseStatusSource(config: config, overrides: $0.overrides) } ?? config
        router = routing.router
        lifetimes = WebRouteLifetimes(router: router)
        restoration = SearchRouteRestoration(router: router, defaults: restorationDefaults)
        // 页面恢复接在启动协调上（R2-03）：等本轮强更检查有结果或等满 5 秒、外壳就绪后才执行。
        restoration.attach(to: routing)
    }

    func searchPage(_ destination: RouteDestination) -> SearchPageConfig {
        let controller = SearchController(api: client, config: config)
        let page = SearchPageConfig(
            controller: controller, history: history, texts: texts,
            initialQuery: destination.params["q"]?.stringValue,
            initialPlatform: destination.params["platform"]?.stringValue,
            restored: SearchPageState.decode(restoration.pageState(for: destination.id)),
            purchase: purchaseStatus
        )
        let router = router
        let restoration = restoration
        let id = destination.id
        page.onStateChange = { restoration.save($0.encoded(), for: id) }
        // 出栈：作废请求、恢复目标与延迟保存（购买执行器一并 leave）。进后台：先同步保存本页最新状态（R3F-03）。
        let trade = trade
        lifetimes.register(destination) { [weak controller, weak page] in
            controller?.leave()
            page?.leave()
            trade?.pageLeft(id)
        }
        restoration.registerFlush(for: id) { [weak page] in page?.flushState() }
        page.onBack = { router.close(destination) }
        page.onOpenProduct = { platform, key, ref in
            var values: [String: JSONValue] = ["platform": .string(platform), "product_key": .string(key)]
            if let ref, !ref.isEmpty {
                values["item_ref"] = .string(ref)
            }
            router.open(RouteRequest(route: AppSearchRoutes.productDetail, values: values, from: .inApp))
        }
        // 列表卡的购买（APP-06b）：open 流程直接在搜索页执行（8 秒超时条、同键重试，共性第 29 条）；卡片写回只换那一张。
        if let trade {
            let purchase = trade.makePurchase(
                for: destination,
                updateCard: { [weak controller] target, transform in
                    guard let key = target["product_key"] as? String else { return }
                    controller?.updateItem(productKey: key, transform)
                },
                refetchCard: { [weak controller] target, merge in
                    guard let key = target["product_key"] as? String else { return }
                    controller?.refetchItem(productKey: key, itemRef: target["item_ref"] as? String, merge: merge)
                }
            )
            page.purchaseController = purchase
            page.onBuy = { [weak purchase] item in purchase?.buy(item, spm: AppSearchSpm.searchList) }
            page.onSimilar = { [weak purchase] item in purchase?.similar(item) }
        }
        return page
    }

    func productPage(_ destination: RouteDestination) -> ProductPageConfig {
        let client = client
        let privacy = privacy
        let controller = ProductDetailController(
            api: client,
            platform: destination.params["platform"]?.stringValue ?? "",
            productKey: destination.params["product_key"]?.stringValue ?? "",
            itemRef: destination.params["item_ref"]?.stringValue,
            purchase: purchaseStatus
        ) {
            [
                "loggedIn": client.isolatedSessionScope != nil,
                "privacy": privacy.state.decision == .basicMode ? "basic" : "consented",
            ]
        }
        let purchase = trade?.makePurchase(
            for: destination,
            updateCard: { [weak controller] _, transform in controller?.updateProduct(transform) },
            refetchCard: { [weak controller] _, merge in controller?.refetch(merge: merge) }
        )
        let trade = trade
        let destinationId = destination.id
        lifetimes.register(destination) { [weak controller] in
            controller?.leave()
            trade?.pageLeft(destinationId)
        }
        let page = ProductPageConfig(controller: controller, texts: texts)
        page.purchase = purchase
        let router = router
        page.onBack = { router.close(destination) }
        page.onResearch = {
            router.close(destination)
            if router.path.last?.route != AppSearchRoutes.search {
                router.open(RouteRequest(route: AppSearchRoutes.search, from: .inApp))
            }
        }
        page.onAskAI = { router.open(RouteRequest(route: AppSearchRoutes.agentChat, from: .inApp)) }
        // 购买（APP-06b）：open 流程、TradeJump、JumpTip、AuthSheet、link_jump 上报都在 OpenPurchaseController。
        page.onBuyIntent = { [weak purchase] product in purchase?.buy(product, spm: AppSearchSpm.productBottom) }
        page.onSimilar = { [weak purchase] product in purchase?.similar(product) }
        return page
    }
}
