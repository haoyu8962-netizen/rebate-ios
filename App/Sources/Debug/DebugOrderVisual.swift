#if DEBUG
import Foundation
import SwiftUI

/// 订单视觉 UI 测试的数据注入（APP-08v；只在 Debug / Staging 编译，Release 制品扫描查环境变量名 `COULI_FAKE_ORDER_VISUAL`、
/// 类型名 DebugOrderVisual / DebugOrderLog 与标识 debug.order.log）。调试开关只走环境变量，不写 App 标准偏好。
///
/// 环境变量 `COULI_FAKE_ORDER_VISUAL` = UTF-8 JSON 对象的 Base64：
/// `{"list": {"self" | "share" | "q:<词>" | "cursor:<游标>": OrderListData}, "details": {"<order_id>": OrderDetail}}`
/// （报文原样来自 specs/order-vectors.json 的 visualOrders）。仅在本机假服务（`-CouliFakeLoginServer`）打开时生效，
/// 生效时接管订单接口（先于 DebugFakeOrders 通用样例）：
/// - `GET /v1/orders`：有 cursor 回 `cursor:<游标>`，有 q 回 `q:<词>`，否则按 scope 回 `self` / `share`；缺省回空页；
/// - `GET /v1/orders/<order_id>`：回 `details` 同 id 的报文，没有回 30701；`/v1/orders/pending-tracks` 回空（不记录）。
enum DebugOrderVisual {
    static let environmentKey = "COULI_FAKE_ORDER_VISUAL"
    static let prefix = "/v1/orders"

    /// 注入的数据（进程启动后读一次；没有或解不开时为 nil，不接管任何请求）。
    nonisolated(unsafe) static let payload: [String: Any]? = {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              let data = Data(base64Encoded: raw),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object
    }()

    static var isActive: Bool {
        payload != nil
    }

    private static var emptyPage: [String: Any] {
        ["items": [Any](), "next_cursor": NSNull(), "earliest_visible_date": NSNull()]
    }

    /// 假服务在网络线程调用：注入生效且是订单接口时回答，否则 nil（交给其他场景）。
    static func answer(method: String, path: String, query: [String: String]) -> DebugFakeOrders.Reply? {
        guard let injected = payload, path == prefix || path.hasPrefix(prefix + "/") else { return nil }
        if path.hasPrefix(prefix + "/pending-tracks") {
            let empty: [String: Any] = path == prefix + "/pending-tracks" ? ["items": [Any]()] : [:]
            return ok(empty)
        }
        DebugOrderLog.record("request:" + line(method: method, path: path, query: query))
        if path == prefix {
            let pages = injected["list"] as? [String: Any] ?? [:]
            return ok(pages[pageKey(query)] ?? emptyPage)
        }
        let id = String(path.dropFirst(prefix.count + 1)).removingPercentEncoding ?? ""
        let details = injected["details"] as? [String: Any] ?? [:]
        guard let detail = details[id] else {
            return .answer(code: 30701, data: "{}", headers: [:], delay: 0.3)
        }
        return ok(detail)
    }

    /// 有 cursor 回 `cursor:<游标>`，有 q 回 `q:<词>`，否则按 scope。
    private static func pageKey(_ query: [String: String]) -> String {
        if let cursor = query["cursor"] {
            return "cursor:" + cursor
        }
        if let keyword = query["q"] {
            return "q:" + keyword
        }
        return query["scope"] ?? "self"
    }

    private static func ok(_ object: Any) -> DebugFakeOrders.Reply {
        .answer(code: 0, data: DebugFakeSearch.json(object), headers: [:], delay: 0.3)
    }

    /// 「<方法> <路径>[?<查询串按键名排序 k=v&…>]」。
    static func line(method: String, path: String, query: [String: String]) -> String {
        let pairs = query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
        return pairs.isEmpty ? "\(method) \(path)" : "\(method) \(path)?\(pairs)"
    }
}

/// 订单视觉 UI 测试的只读记录（同 DebugPurchaseLog 做法；只在注入生效时记录与显示）：
/// `request:<方法> <路径>[?…]`（假服务收到的订单请求）、`route:<路由名>[?<参数按键名排序>]`（订单列表 / 详情经 App 出口打开的路由）、
/// `cs:OrderDetail`（统一客服出口）、`copy:<原文>`（订单号经剪贴板统一写入口写入）。UI 测试读根视图左上角 1×1 的只读元素
/// `debug.order.log`：accessibilityValue = 全部记录按发生顺序以「 | 」连接。不影响任何回答内容与界面。
@MainActor
final class DebugOrderLog: ObservableObject {
    static let shared = DebugOrderLog()
    static let identifier = "debug.order.log"

    @Published private(set) var entries: [String] = []

    /// 任意线程调用；在主线程追加。
    nonisolated static func record(_ entry: String) {
        guard DebugOrderVisual.isActive else { return }
        Task { @MainActor in
            shared.entries.append(entry)
        }
    }

    /// 路由记录：参数按键名排序 k=v，用 & 连接。
    nonisolated static func route(_ name: String, _ params: [String: String] = [:]) {
        let pairs = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined(separator: "&")
        record("route:" + (pairs.isEmpty ? name : "\(name)?\(pairs)"))
    }

    var value: String {
        entries.joined(separator: " | ")
    }
}

/// `debug.order.log` 只读元素（1×1、透明，不挡点击）。
struct DebugOrderLogReadout: View {
    @ObservedObject var log = DebugOrderLog.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: DebugOrderLog.identifier))
            .accessibilityValue(Text(verbatim: log.value))
            .accessibilityIdentifier(DebugOrderLog.identifier)
    }
}
#endif
