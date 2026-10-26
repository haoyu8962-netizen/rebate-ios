import DesignSystem
import Foundation
import UIKit
import XCTest

/// APP-08v（订单视觉）三端同一份截图数据：`specs/order-vectors.json` 的 `visualOrders`（G-O11，与 Android 已合入文件逐字节相同）。
/// 只读，不改既有判定组。固定时钟 2026-10-12 10:30（Asia/Shanghai），断网缓存时刻 09:30。
enum OrderVisualData {
    /// 截图图片主机（测试位图，不连网）。
    static let imageHost = "img.example.test"
    /// 错误响应的 trace_id（trace6 = 000123，与 Android / 商品详情基准同字）。
    static let traceId = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e000123"

    static func repo() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    static func vectors() throws -> [String: Any] {
        let data = try Data(contentsOf: repo().appendingPathComponent("specs/order-vectors.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func root() throws -> [String: Any] {
        try XCTUnwrap(vectors()["visualOrders"] as? [String: Any], "共用向量文件缺 visualOrders 组（G-O11）")
    }

    /// 固定时钟（毫秒）。
    static func nowMillis() throws -> Int64 {
        let clock = try XCTUnwrap(root()["clock"] as? [String: Any])
        return try XCTUnwrap((clock["nowMillis"] as? NSNumber)?.int64Value)
    }

    /// 断网缓存的获取时刻（毫秒，今天 09:30）。
    static func staleAtMillis() throws -> Int64 {
        let clock = try XCTUnwrap(root()["clock"] as? [String: Any])
        return try XCTUnwrap((clock["staleAtMillis"] as? NSNumber)?.int64Value)
    }

    /// 列表一页（OrderListData 报文，原样）。
    static func page(_ name: String) throws -> [String: Any] {
        let pages = try XCTUnwrap(root()["pages"] as? [String: Any])
        if let page = pages[name] as? [String: Any] {
            return page
        }
        // v3（评审 r1 S2-3）：iOS 新增页在独立文件 specs/order-visual-extra-pages.json（共用文件不动）
        let data = try Data(contentsOf: repo().appendingPathComponent("specs/order-visual-extra-pages.json"))
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((extra["pages"] as? [String: Any])?[name] as? [String: Any],
                             "visualOrders.pages 与 order-visual-extra-pages 都没有 \(name)")
    }

    /// 单一状态的一页（statusPages.<DISPLAY_STATUS>）。
    static func statusPage(_ status: String) throws -> [String: Any] {
        let pages = try XCTUnwrap(root()["statusPages"] as? [String: Any])
        return try XCTUnwrap(pages[status] as? [String: Any], "visualOrders.statusPages 缺 \(status)")
    }

    /// 详情报文（details.<name> 或 reasonDetails.<name>，原样）。b 组用。
    static func detail(_ name: String) throws -> [String: Any] {
        let root = try root()
        if let detail = (root["details"] as? [String: Any])?[name] as? [String: Any] {
            return detail
        }
        return try XCTUnwrap((root["reasonDetails"] as? [String: Any])?[name] as? [String: Any],
                             "visualOrders.details / reasonDetails 缺 \(name)")
    }

    /// 测试内派生：改几个字段（不写回共用文件）。
    static func change(_ source: [String: Any], _ fields: [String: Any]) -> [String: Any] {
        source.merging(fields) { $1 }
    }

    static func items(_ page: [String: Any]) -> [[String: Any]] {
        page["items"] as? [[String: Any]] ?? []
    }

    /// 成功响应包。
    static func envelope(_ data: Any) -> String {
        let payload: [String: Any] = ["code": 0, "msg": "", "data": data, "trace_id": traceId]
        let bytes = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(bytes: bytes, encoding: .utf8) ?? "{}"
    }

    /// 错误响应包。
    static func errorEnvelope(_ code: Int) -> String {
        "{\"code\":\(code),\"msg\":\"\",\"data\":{},\"trace_id\":\"\(traceId)\"}"
    }

    /// 分（整数）→ 页面上的金额文字：只走 DesignSystem 的 CouliFormat（AGENTS 硬规则 3），断言里找哪段文字用。
    static func money(_ fen: Int64) -> String {
        CouliFormat.money(fen: fen)
    }
}

/// 订单视觉的本机假服务（AppTests）：记录方法、路径与查询串；按脚本回答列表 / 详情；可整体断网（传输失败）或挂住。
/// 生产的 OrdersAppFixture 换成这个会话配置（OrdersAppFixture.make 的 `configuration` 参数），其余组装不变。
final class OrderVisualStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        case data(Any)
        case error(Int)
        /// 成功包但 data 解析不出订单（如 `{}`；评审经验「刷新解析失败（成功响应…）」）。
        case malformed
        case offline
        case hold
    }

    struct Recorded: Equatable {
        let method: String
        let path: String
        let query: [String: String]

        var line: String {
            let pairs = query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
            return pairs.isEmpty ? "\(method) \(path)" : "\(method) \(path)?\(pairs)"
        }
    }

    /// 脚本：key 规则见 `answer`。
    struct Script {
        /// 列表：`self` / `share`（按 scope）；`q:<词>`（有搜索词时优先）；`cursor:<游标>`（翻页）。缺省回空页。
        var pages: [String: Reply] = [:]
        /// 详情：order_id → 回答。缺省 30701。
        var details: [String: Reply] = [:]
        /// 整体断网（列表与详情都按传输失败结束）。
        var offline = false
        /// v5：待跟单卡（`GET /v1/orders/pending-tracks` 的 items；缺省空）。
        var pendingTracks: [[String: Any]] = []
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var script = Script()
    private nonisolated(unsafe) static var recorded: [Recorded] = []
    private var held = false

    static func install(_ script: Script) {
        lock.withLock {
            self.script = script
            recorded = []
        }
    }

    /// 运行中改脚本（如刷新前改成断网 / 坏响应）。
    static func update(_ change: (inout Script) -> Void) {
        lock.withLock { change(&script) }
    }

    static func reset() {
        install(Script())
    }

    static var requests: [Recorded] {
        lock.withLock { recorded }
    }

    /// 订单接口的请求（不含待跟单卡）。
    static var orderRequests: [Recorded] {
        requests.filter { $0.path.hasPrefix("/v1/orders") && !$0.path.hasPrefix("/v1/orders/pending-tracks") }
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrderVisualStub.self]
        return config
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private static func answer(_ entry: Recorded, _ script: Script) -> Reply {
        let path = entry.path
        if path == "/v1/orders/pending-tracks" {
            return .data(["items": script.pendingTracks])
        }
        if path.hasPrefix("/v1/orders/pending-tracks/") {
            return .data([String: Any]())
        }
        if path == "/v1/orders" {
            if script.offline {
                return .offline
            }
            if let cursor = entry.query["cursor"] {
                return script.pages["cursor:\(cursor)"] ?? .data(emptyPage)
            }
            if let keyword = entry.query["q"] {
                return script.pages["q:\(keyword)"] ?? .data(emptyPage)
            }
            return script.pages[entry.query["scope"] ?? "self"] ?? .data(emptyPage)
        }
        if path.hasPrefix("/v1/orders/") {
            if script.offline {
                return .offline
            }
            let id = String(path.dropFirst("/v1/orders/".count)).removingPercentEncoding ?? ""
            return script.details[id] ?? .error(30701)
        }
        // 其余（配置、会话等）：空成功
        return .data([String: Any]())
    }

    static var emptyPage: [String: Any] {
        ["items": [Any](), "next_cursor": NSNull(), "earliest_visible_date": NSNull()]
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let entry = Recorded(method: request.httpMethod ?? "GET", path: url.path, query: query)
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(entry)
            return Self.answer(entry, Self.script)
        }
        switch reply {
        case let .data(data):
            deliver(url, status: 200, body: OrderVisualData.envelope(data))
        case let .error(code):
            deliver(url, status: 400, body: OrderVisualData.errorEnvelope(code))
        case .malformed:
            deliver(url, status: 200, body: OrderVisualData.envelope([String: Any]()))
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .hold:
            held = true
        }
    }

    private func deliver(_ url: URL, status: Int, body: String) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 订单商品图的测试位图：只拦 `img.example.test/order-v/…`，回 128 × 128 的红 | 绿 | 蓝三段方图（与商品详情测试位图同色，
/// 64 × 64 缩略图里三段都看得见；fill 裁切后仍三段）。
final class OrderVisualImages: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var urls: [String] = []

    static func install() {
        reset()
        URLProtocol.registerClass(OrderVisualImages.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(OrderVisualImages.self)
    }

    static func reset() {
        lock.withLock { urls = [] }
    }

    static var served: [String] {
        lock.withLock { urls }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == OrderVisualData.imageHost && request.url?.path.hasPrefix("/order-v/") == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    static func stripes() -> Data {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let third = size.width / 3
            for (index, color) in [ProductVisualImages.red, ProductVisualImages.green, ProductVisualImages.blue]
                .enumerated() {
                UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255,
                        alpha: 1).setFill()
                context.fill(CGRect(x: third * CGFloat(index), y: 0, width: third + 1, height: size.height))
            }
        }
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let client = client
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.stripes())
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.withLock { Self.urls.append(url.absoluteString) }
        }
    }

    override func stopLoading() {}
}
