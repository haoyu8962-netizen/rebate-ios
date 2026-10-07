import Combine
import Foundation
import Router

/// 容器页与路由栈的生命周期（APP-04 三端共性第 28 条）：路由真正出栈时 teardown 容器——立即撤销全部在途桥调用的有效性、
/// 停止加载。真正出栈包括：关闭（返回、nav.close）、Router 清栈（打开 Tab 根路由）、整栈被替换（强更替换导航栈、退出强更）。
/// 只是被别的页面盖住（目的地仍在栈里）不算。
///
/// 判断依据只看 Router 的导航栈：订阅 `path`，登记过的目的地一旦不在新栈里就 teardown 并注销。不依赖 SwiftUI 的
/// onDisappear（被盖住时也会触发，清栈时又不一定及时）。
@MainActor
final class WebRouteLifetimes {
    private struct Entry {
        let teardown: @MainActor () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var observation: AnyCancellable?

    init(router: Router) {
        // @Published 在 willSet 时发出新值：栈一变就 teardown，比视图销毁早。
        observation = router.$path.sink { [weak self] path in
            MainActor.assumeIsolated {
                self?.pathChanged(path)
            }
        }
    }

    /// 登记一个容器页（目的地已在栈里时调用；容器以弱引用持有）。
    func register(_ destination: RouteDestination, teardown: @escaping @MainActor () -> Void) {
        entries[destination.id] = Entry(teardown: teardown)
    }

    var registeredCount: Int {
        entries.count
    }

    private func pathChanged(_ path: [RouteDestination]) {
        let alive = Set(path.map(\.id))
        let removed = entries.keys.filter { !alive.contains($0) }
        for id in removed {
            let entry = entries.removeValue(forKey: id)
            entry?.teardown()
        }
    }
}
