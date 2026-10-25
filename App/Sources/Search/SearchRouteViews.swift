import Product
import Purchase
import Router
import Search
import SwiftUI

/// 路由 Search（APP-06a；params q、platform 都可选）。自己的搜索栏，系统导航栏隐藏。
struct SearchRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var search: AppSearch

    var body: some View {
        SearchRouteContent(search: search, destination: destination)
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
    }
}

private struct SearchRouteContent: View {
    /// StateObject 的初始值只在页面第一次出现时求值：一个路由目的地只有一个执行器（出栈时由 AppSearch.lifetimes leave）。
    @StateObject private var config: SearchPageConfig

    init(search: AppSearch, destination: RouteDestination) {
        _config = StateObject(wrappedValue: search.searchPage(destination))
    }

    var body: some View {
        if let purchase = config.purchaseController {
            SearchView(config: config)
                .purchaseOverlay(purchase, texts: config.texts, host: .search)
        } else {
            SearchView(config: config)
        }
    }
}

/// 路由 ProductDetail（APP-06a；params platform、product_key 必填，item_ref 可选）。
struct ProductDetailRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var search: AppSearch

    var body: some View {
        ProductRouteContent(search: search, destination: destination)
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .couliToast($search.toast)
    }
}

private struct ProductRouteContent: View {
    @StateObject private var config: ProductPageConfig

    init(search: AppSearch, destination: RouteDestination) {
        _config = StateObject(wrappedValue: search.productPage(destination))
    }

    var body: some View {
        if let purchase = config.purchase {
            ProductDetailScreen(config: config)
                .purchaseOverlay(purchase, texts: config.texts, host: .detail)
        } else {
            ProductDetailScreen(config: config)
        }
    }
}
