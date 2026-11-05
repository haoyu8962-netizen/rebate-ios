import Generated

extension AppRouting {
    /// 契约已登记为已发布、本端还没有页面的路由（P1 取 B，编排 11-04 11:24；D10-613 只钉这两条）。
    static let withoutPage = ["InviteLink", "InviteBackfill"]

    /// 把 withoutPage 按 since.ios 为 null 处理：守卫给升级提示（与升锁 00deded0ef6f 前「路由不存在」的结论相同），
    /// 不落到显示英文路由名的占位页。页面另立单实现后从 withoutPage 删掉。
    static func markWithoutPage(_ table: inout [String: RouteSpec]) {
        for name in withoutPage {
            guard let spec = table[name] else { continue }
            table[name] = RouteSpec(
                name: spec.name, kind: spec.kind, auth: spec.auth, sinceIOS: nil, entries: spec.entries,
                h5Path: spec.h5Path, debugOnly: spec.debugOnly, agentGuide: spec.agentGuide,
                agentGuideAccount: spec.agentGuideAccount, params: spec.params,
                requiredParams: spec.requiredParams, additionalParams: spec.additionalParams
            )
        }
    }
}
