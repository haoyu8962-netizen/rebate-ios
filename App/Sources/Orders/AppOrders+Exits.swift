import Foundation
import Router

/// 订单列表的出口（APP-08v）：打开路由与剪贴板统一写入口。Debug / Staging 下另记到订单视觉 UI 测试的只读记录（DebugOrderLog，
/// 只在注入 COULI_FAKE_ORDER_VISUAL 时记录）；去向、参数与次数不变。
extension AppOrders {
    /// 经 Router 打开（站内）。
    static func exit(_ router: Router, _ route: String, _ values: [String: JSONValue] = [:]) {
        #if DEBUG
        DebugOrderLog.route(route, values.mapValues { $0.stringValue ?? "" })
        #endif
        router.open(RouteRequest(route: route, values: values, from: .inApp))
    }

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
