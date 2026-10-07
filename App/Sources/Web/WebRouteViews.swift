import Router
import SwiftUI
import Web

/// WebPage 路由（可信容器）：url 已由 Router 按 bridge_origins 放行（RouteTargetCheck）；容器加载前再判一次。
struct WebPageRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var web: AppWeb
    @EnvironmentObject private var router: Router

    var body: some View {
        TrustedWebContainer(web: web, destination: destination) {
            router.close(destination)
        }
    }
}

private struct TrustedWebContainer: View {
    @StateObject private var controller: TrustedWebController

    init(web: AppWeb, destination: RouteDestination, onClose: @escaping @MainActor () -> Void) {
        let url = destination.params["url"]?.stringValue.flatMap(URL.init(string:))
        _controller = StateObject(wrappedValue: {
            let controller = web.makeTrustedController(
                url: url, fromForceUpdatePage: destination.fromForceUpdatePage, onClose: onClose
            )
            // 路由真正出栈（关闭、清栈、被替换、强更替换栈）时 teardown：作废全部在途桥调用并停止加载。
            web.routeLifetimes.register(destination) { [weak controller] in controller?.teardown() }
            return controller
        }())
    }

    var body: some View {
        TrustedWebScreen(controller: controller)
            .task {
                // start 只在第一次生效（被其他页面盖住再回来时不重新加载）；路由出栈时由 WebRouteLifetimes teardown。
                controller.start()
            }
    }
}

/// ExternalPage 路由（第三方页容器）。
struct ExternalPageRouteView: View {
    let destination: RouteDestination
    @EnvironmentObject private var web: AppWeb
    @EnvironmentObject private var router: Router

    var body: some View {
        ExternalWebContainer(web: web, destination: destination) {
            router.close(destination)
        }
    }
}

struct ExternalWebContainer: View {
    @StateObject private var controller: ExternalWebController
    private let subtitle: String?
    private let navStyle: ExternalNavStyle

    init(web: AppWeb, destination: RouteDestination, onClose: @escaping @MainActor () -> Void) {
        let url = destination.params["url"]?.stringValue.flatMap(URL.init(string:))
        (subtitle, navStyle) = Self.chrome(destination)
        _controller = StateObject(wrappedValue: {
            let controller = web.makeExternalController(url: url, onClose: onClose)
            web.routeLifetimes.register(destination) { [weak controller] in controller?.teardown() }
            return controller
        }())
    }

    /// 路由参数 → 标题栏：title 是主机名下方的副标题；nav_style 是标题栏配色，缺省 light（三端共性第 24 条，03 §5.1）。
    static func chrome(_ destination: RouteDestination) -> (subtitle: String?, navStyle: ExternalNavStyle) {
        let style = destination.params["nav_style"]?.stringValue.flatMap(ExternalNavStyle.init(rawValue:))
        return (destination.params["title"]?.stringValue, style ?? .light)
    }

    var body: some View {
        ExternalWebScreen(controller: controller, subtitle: subtitle, navStyle: navStyle)
            .task {
                controller.start()
            }
    }
}

extension Router {
    /// 关闭一个容器页：从导航栈里移除它（及其上面的页面）。
    func close(_ destination: RouteDestination) {
        guard let index = path.firstIndex(where: { $0.id == destination.id }) else { return }
        path.removeSubrange(index...)
    }
}
