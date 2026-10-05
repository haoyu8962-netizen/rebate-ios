// 生成物，禁止手改；来源 contract.lock
// 快照：contracts/routes.json（debug_only 为 true 的路由）

#if DEBUG
import Generated

/// debug_only 路由表：只在 Debug / Staging 编译（App target 定义 DEBUG）。Release 制品里没有这些名字，
/// release-scan.sh 查 `tableMarker`。路由层（APP-02）在 DEBUG 下把它并进 `Routes.all`。
enum DebugOnlyRoutes {
    static let tableMarker = "COULI_DEBUG_ONLY_ROUTE_TABLE"

    static let all: [Swift.String: Generated.RouteSpec] = {
        var table: [Swift.String: Generated.RouteSpec] = [:]
        table["HomePreview"] = RouteSpec(
            name: "HomePreview", kind: .native, auth: "none",
            sinceIOS: "1.0.0",
            entries: [.inApp, .deeplink],
            h5Path: nil, debugOnly: true
        )
        if table.count != 1 {
            Swift.fatalError("COULI_DEBUG_ONLY_ROUTE_TABLE: debug-only route table incomplete")
        }
        return table
    }()
}
#endif
