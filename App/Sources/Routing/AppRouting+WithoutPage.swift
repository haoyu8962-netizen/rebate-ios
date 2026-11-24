import Generated
import MeCore

extension AppRouting {
    /// 契约已登记为已发布、本端还没有页面的路由（P1 取 B，编排 11-04 11:24；D10-613 只钉这两条）。
    static let withoutPage = ["InviteLink", "InviteBackfill"]

    /// 把 withoutPage 按 since.ios 为 null 处理：守卫给升级提示（与升锁 00deded0ef6f 前「路由不存在」的结论相同），
    /// 不落到显示英文路由名的占位页。页面另立单实现后从 withoutPage 删掉。
    static func markWithoutPage(_ table: inout [String: RouteSpec]) {
        for name in withoutPage {
            guard let spec = table[name] else { continue }
            table[name] = spec.withSinceIOS(nil)
        }
    }

    /// 本端发布闸（D10-2903 ②(b)）：契约 since.ios 已填、本端开门另归别的单的路由，按闸给出本端的 since.ios
    /// （闸为 nil = 本端未发布；契约本身为 nil 时仍是 nil）。DeleteAccount：契约 6c97062 起 1.0.0，开门归 APP-13a-3。
    /// 设置页判据 `AppMe.availableRoutes` 与路由表 `routeTable` 共用这一处。
    static func gatedSinceIOS(_ name: String, _ spec: RouteSpec) -> String? {
        guard name == DeleteAccountController.route else { return spec.sinceIOS }
        return spec.sinceIOS == nil ? nil : DeleteAccountEntry.sinceIOS
    }

    /// routeTable 用：没有页面的（markWithoutPage）与本地发布闸关着的（markLocalGates）都按未发布。
    static func markUnreleased(_ table: inout [String: RouteSpec]) {
        markWithoutPage(&table)
        markLocalGates(&table)
    }

    static func markLocalGates(_ table: inout [String: RouteSpec]) {
        for (name, spec) in table {
            let since = gatedSinceIOS(name, spec)
            if since != spec.sinceIOS {
                table[name] = spec.withSinceIOS(since)
            }
        }
    }
}

private extension RouteSpec {
    func withSinceIOS(_ since: String?) -> RouteSpec {
        RouteSpec(
            name: name, kind: kind, auth: auth, sinceIOS: since, entries: entries,
            h5Path: h5Path, debugOnly: debugOnly, agentGuide: agentGuide,
            agentGuideAccount: agentGuideAccount, params: params,
            requiredParams: requiredParams, additionalParams: additionalParams
        )
    }
}
