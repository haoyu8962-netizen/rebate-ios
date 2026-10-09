import CouliNetwork
import DesignSystem
import Foundation
import Product
import ProductSearch
import Router
import Search

/// 本页面打开的路由名（都在 routes.json 里登记；SearchWiringTests 逐个核对）。
enum AppSearchRoutes {
    static let search = "Search"
    static let productDetail = "ProductDetail"
    /// 【问问 AI】：AI 助手的 Tab 根路由（routes.json AgentChat）。
    static let agentChat = "AgentChat"
    static let all = [search, productDetail, agentChat]
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
    /// 路由真正出栈（返回、清栈、整栈替换）时执行 leave；只是被盖住不算（与 WebView 容器同一判定）。
    let lifetimes: WebRouteLifetimes
    /// 进程回收恢复（共性 20）：按路由身份保存页面状态并持久化，冷启动外壳出现后重开。
    let restoration: SearchRouteRestoration

    init(
        network: AppNetwork, config: AppConfig, privacy: PrivacyController, routing: AppRouting,
        restorationDefaults: UserDefaults = .standard
    ) {
        client = network.client
        self.config = config
        self.privacy = privacy
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
            purchase: config
        )
        let router = router
        let restoration = restoration
        let id = destination.id
        page.onStateChange = { restoration.save($0.encoded(), for: id) }
        // 出栈：作废请求、恢复目标与延迟保存。进后台：先同步保存本页最新状态（R3F-03）。
        lifetimes.register(destination) { [weak controller, weak page] in
            controller?.leave()
            page?.leave()
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
            purchase: config
        ) {
            [
                "loggedIn": client.isolatedSessionScope != nil,
                "privacy": privacy.state.decision == .basicMode ? "basic" : "consented",
            ]
        }
        lifetimes.register(destination) { [weak controller] in controller?.leave() }
        let page = ProductPageConfig(controller: controller, texts: texts)
        let router = router
        page.onBack = { router.close(destination) }
        page.onResearch = {
            router.close(destination)
            if router.path.last?.route != AppSearchRoutes.search {
                router.open(RouteRequest(route: AppSearchRoutes.search, from: .inApp))
            }
        }
        page.onAskAI = { router.open(RouteRequest(route: AppSearchRoutes.agentChat, from: .inApp)) }
        page.onBuyIntent = { [weak self] _ in
            // TODO(APP-06b)：open 购买（8 秒超时、同键重试、可取消加载层）、TradeJump、JumpTip、AuthSheet、link_jump 上报。
            #if DEBUG
            self?.toast = CouliToastMessage(SearchDraftTexts.drafts["product.buy_intent.debug"] ?? "")
            #endif
        }
        return page
    }
}
