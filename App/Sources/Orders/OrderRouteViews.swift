import Config
import DesignSystem
import Foundation
import Generated
import OrderCore
import Orders
import Privacy
import Router
import SwiftUI
import Web

/// 订单本机数据的清理项（G10、APP-03b 撤回清理名单）：撤回同意与切换环境时删除断网缓存与订单 Tab 根的恢复记录（Application Support 下的 orders.page_state.json，可能含
/// 完整订单号搜索词与锚点订单，共性第 36 条；两者同属 OrderCacheStore 的一个清理单元）；删不掉抛错（撤回清理不算完成、待清理状态保留在
/// 缓存目录之外，启动、读、写、恢复之前都先完成清理，共性第 20、28 条）。启动对账重试撤回清理时 AppOrders 还没创建，照样能删。
/// 无论落盘删除成功与否，都同步通知 AppOrders 作废内存里的列表、恢复记录、详情与各位置的待跟单卡（共性第 36、38 条）。
/// 金额隐藏与通知行「点过」是设备级界面偏好（不含个人信息，不随账号、不随环境，rule-gaps G21、H11、I03），不在此列。
/// 登出、换账号、会话失效由 AppOrders 按归属清理。
@MainActor
final class OrderCacheCleaner: EnvironmentSwitchCleaning {
    static let name = "Orders.cache"
    let cleanerName = OrderCacheCleaner.name
    let store: OrderCacheStore
    /// 清理后的通知（AppOrders 作废内存里的订单显示与执行器；删除失败时同样通知）。
    var onCleared: (@MainActor () -> Void)?

    init(store: OrderCacheStore) {
        self.store = store
    }

    func cleanForEnvironmentSwitch() throws {
        defer { onCleared?() }
        try store.clearAll()
    }

    static let shared = OrderCacheCleaner(store: OrderCacheStore(
        root: OrderCacheStore.defaultRoot(), legacyPageStateDefaults: .standard
    ))

    /// 登记进撤回同意与切换环境两个注册表（已登记过就不重复）。在启动对账之前调用。
    static func register(
        _ cleaner: OrderCacheCleaner = shared,
        withdrawal: EnvironmentSwitchCleanerRegistry = PrivacyWithdrawalCleanup.registry,
        environmentSwitch: EnvironmentSwitchCleanerRegistry = .shared
    ) {
        for registry in [withdrawal, environmentSwitch] where !registry.registeredNames.contains(name) {
            registry.register(cleaner)
        }
    }
}

/// 路由 OrderList（订单 Tab 根；params scope 可选）。执行器一个会话一份，存在 AppOrders：切到别的 Tab、被详情盖住都保留。
struct OrderListRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var orders: AppOrders

    var body: some View {
        OrdersScreen(config: orders.listPage(destination))
            .id(orders.sessionEpoch)
    }
}

/// 路由 OrderDetail（params order_id 必填）。
struct OrderDetailRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var orders: AppOrders

    var body: some View {
        OrderDetailRouteContent(orders: orders, destination: destination)
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
    }
}

private struct OrderDetailRouteContent: View {
    /// StateObject 的初始值只在页面第一次出现时求值：一个路由目的地只有一个执行器（出栈时由 AppOrders.lifetimes leave）。
    @StateObject private var config: OrderDetailPageConfig

    init(orders: AppOrders, destination: RouteDestination) {
        _config = StateObject(wrappedValue: orders.detailPage(destination))
    }

    var body: some View {
        OrderDetailScreen(config: config)
    }
}

/// H5 路由的地址（APP-08 共性第 22 条，Android A14 / A15 同口径）：生效配置的 h5_base_url（必须是 https、不带查询串）+ routes.json 的
/// h5_path（首尾斜杠只留一个），路由参数作为查询串（按名排序、UTF-8 编码）。拼不出（基址缺失、不是 https、带查询串）为 nil：容器显示
/// 自己的加载失败页，不退回占位页。h5_release.version 放在地址哪里未定，暂不带（A15）。
enum H5RouteURL {
    static func make(route: String, params: [String: JSONValue], configJson: String) -> URL? {
        guard let spec = Routes.all[route], spec.kind == .h5, let path = spec.h5Path,
              let data = configJson.data(using: .utf8),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseText = config["h5_base_url"] as? String, var base = URLComponents(string: baseText),
              base.scheme?.lowercased() == "https", base.host?.isEmpty == false, base.query == nil, base.fragment == nil
        else { return nil }
        let trimmedBase = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        base.path = trimmedBase + (path.hasPrefix("/") ? path : "/" + path)
        let items = params.keys.sorted().compactMap { key -> URLQueryItem? in
            params[key]?.stringValue.map { URLQueryItem(name: key, value: $0) }
        }
        base.queryItems = items.isEmpty ? nil : items
        return base.url
    }
}

/// H5 路由（FindOrder、Ledger、Help）：接可信容器（TrustedWebView），地址按配置基址与 h5_path 生成并带参数；首次与「首次未加载成」后的
/// 【重试】都重新读生效配置、重新生成地址（共性第 29 条）。https、可信源（bridge_origins）与桥权限校验照旧。
struct H5RouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var web: AppWeb
    @EnvironmentObject private var router: Router

    var body: some View {
        H5RouteContainer(web: web, destination: destination) {
            router.close(destination)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }
}

private struct H5RouteContainer: View {
    @StateObject private var controller: TrustedWebController

    init(web: AppWeb, destination: RouteDestination, onClose: @escaping @MainActor () -> Void) {
        _controller = StateObject(wrappedValue: {
            let route = destination.route ?? ""
            let params = destination.params
            let controller = web.makeTrustedController(
                url: nil, fromForceUpdatePage: destination.fromForceUpdatePage, container: destination.id,
                onClose: onClose
            )
            controller.urlProvider = { [weak web] in
                web.flatMap { H5RouteURL.make(route: route, params: params, configJson: $0.configJson) }
            }
            web.routeLifetimes.register(destination) { [weak controller] in controller?.teardown() }
            return controller
        }())
    }

    var body: some View {
        TrustedWebScreen(controller: controller)
            .accessibilityIdentifier("h5.container")
            .task { controller.start() }
    }
}
