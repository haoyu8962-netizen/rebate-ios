import Foundation
import Router

/// 订单列表的出口（APP-08v）：打开路由与剪贴板统一写入口。Debug / Staging 下另记到订单视觉 UI 测试的只读记录（DebugOrderLog，
/// 只在注入 COULI_FAKE_ORDER_VISUAL 时记录）；去向、参数与次数不变。
extension AppOrders {
    /// 经 Router 打开（站内）。
    static func exit(_ router: Router, _ route: String, _ values: [String: JSONValue] = [:]) {
        #if DEBUG
        DebugOrderLog.route(route, flatten(values))
        #endif
        let decision = router.open(RouteRequest(route: route, values: values, from: .inApp))
        #if DEBUG
        // 守卫判定与落地（APP-08v-b 评审 r1 S2-4 排查）：判定种类 / 原因、此刻与稍后的 Tab 根与导航栈深度
        let root = router.tabRoot.route ?? "-"
        DebugOrderLog.record("decision:\(decision.kind) \(decision.reason) root=\(root) path=\(router.path.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak router] in
            guard let router else { return }
            DebugOrderLog.record("landed:\(route) root=\(router.tabRoot.route ?? "-") path=\(router.path.count)")
        }
        #endif
    }

    /// 详情【联系客服】交给统一客服出口（Debug 下记一条只读记录 `cs:OrderDetail`；去向不变）。
    static func recordCustomerService() {
        #if DEBUG
        DebugOrderLog.record("cs:OrderDetail")
        #endif
    }

    #if DEBUG
    /// 只读记录用：嵌套对象按点号展开（`context.order_id`），非字符串叶子记空串。
    private static func flatten(_ values: [String: JSONValue], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in values {
            if case let .object(inner) = value {
                out.merge(flatten(inner, prefix: prefix + key + ".")) { $1 }
            } else {
                out[prefix + key] = value.stringValue ?? ""
            }
        }
        return out
    }
    #endif

    /// 订单号经剪贴板统一写入口写入；返回是否写了。
    func writeClipboard(_ text: String) -> Bool {
        let written = clipboard?.writer.write(text) ?? false
        #if DEBUG
        if written {
            DebugOrderLog.record("copy:\(text)")
        }
        #endif
        return written
    }
}
