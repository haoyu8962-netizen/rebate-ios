#if DEBUG
import Config
import CouliNetwork
import Foundation
import HomeCore

/// TODO(N-35): 待定页面、卡片接口只经本机端口；每次实际请求都复核当前环境。
@MainActor final class DebugFakeHome: HomeContractPort {
    static let marker = "COULI_FAKE_HOME_SERVER_APP11_IOS_5e2c7a"
    private let environment: @MainActor () -> AppEnvironment
    private init(environment: @escaping @MainActor () -> AppEnvironment) {
        self.environment = environment
    }

    static func port(arguments: [String] = ProcessInfo.processInfo.arguments,
                     environment: @escaping @MainActor () -> AppEnvironment) -> HomeContractPort? {
        guard arguments.contains(DebugFakeLoginServer.launchArgument) else { return nil }
        // UI 测试设施：首页读本机数据之前按需清空（DebugHomeUITestSupport）
        DebugHomeUITestSupport.resetIfRequested(arguments: arguments)
        return DebugFakeHome(environment: environment)
    }

    func getPage(pageKey _: String, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed(), DebugCapabilities(environment: environment()).isAvailable(.mockData) else {
            return .localReject(reason: LocalRejectReason.sendBlocked)
        }
        let name = UserDefaults.standard.string(forKey: "CouliFakeHome") ?? "main"
        DebugHomeUITestSupport.pageServed(name)
        return .success(data: Self.page(name), traceId: Self.marker, idempotencyKey: nil)
    }

    func listSectionItems(pageKey _: String, sectionId _: String, cursor: String?, call: HomeCall) async -> ApiResult {
        guard call.sendAllowed(), DebugCapabilities(environment: environment()).isAvailable(.mockData) else {
            return .localReject(reason: LocalRejectReason.sendBlocked)
        }
        return .success(data: Self.products(cursor: cursor), traceId: Self.marker, idempotencyKey: nil)
    }

    nonisolated static func page(_ name: String) -> Data? {
        let pages = (try? JSONSerialization.jsonObject(with: Data(DebugFakeHomePages.json.utf8))) as? [String: Any] ??
            [:]
        if let page = pages[name] {
            return try? JSONSerialization.data(withJSONObject: page)
        }
        let names = [
            "notice_static",
            "banner",
            "default_home",
            "product_scroll",
            "activity_entry",
            "product_grid",
            "feed_infinite",
        ]
        let sections = names.flatMap { ((pages[$0] as? [String: Any])?["sections"] as? [[String: Any]]) ?? [] }
        return try? JSONSerialization.data(withJSONObject: ["page_key": "home", "version": 101, "sections": sections])
    }

    nonisolated static func products(cursor: String?) -> Data? {
        // 复用已有本机商品样例与整数分口径；排序参数不进入首页端口。
        guard let reply = DebugFakeSearch.answer(path: "/v1/products/search", query: ["q": "", "platform": "taobao"]),
              let object = try? JSONSerialization.jsonObject(with: Data(reply.data.utf8)) as? [String: Any]
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "items": cursor == nil ? object["items"] ?? [] : [],
            "next_cursor": NSNull(),
        ])
    }

    /// 新增的草稿、公告假响应在实际传输入口检查请求主机；prod 绝不回答假数据。
    nonisolated static func answer(_ request: URLRequest) -> DebugFakeLoginServer.Reply? {
        guard let url = request.url else { return nil }
        let preview = url.path.hasPrefix("/v1/pages/") && url.path.hasSuffix("/preview")
        let notice = url.path == "/v1/articles" && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "category" && $0.value == "notice" }) == true
        guard preview || notice else { return nil }
        let allowedHosts = [AppEnvironment.test, .staging].compactMap(\.endpoints.apiBaseURL.host)
        guard let host = url.host, allowedHosts.contains(host) else {
            return DebugFakeLoginServer.Reply(code: 30701, data: "null")
        }
        if preview {
            return DebugFakeLoginServer.Reply(
                code: 0,
                data: String(data: page("main") ?? Data(), encoding: .utf8) ?? "null"
            )
        }
        let pages = (try? JSONSerialization.jsonObject(with: Data(DebugFakeHomePages.json.utf8))) as? [String: Any]
        let section = ((pages?["notice_static"] as? [String: Any])?["sections"] as? [[String: Any]])?.first
        let notices = (section?["props"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return DebugFakeLoginServer.Reply(code: 0, data: DebugFakeSearch.json([
            "items": notices
                .map { ["article_id": "test-home-notice", "category": "notice", "title": "test", "version": 1,
                        "published_at": "2026-10-01T00:00:00+08:00", "notice": $0] as [String: Any] },
            "next_cursor": NSNull(),
        ]))
    }
}
#endif
