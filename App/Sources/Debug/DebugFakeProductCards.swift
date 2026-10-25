#if DEBUG
import Foundation
import UIKit

/// 商品详情视觉 UI 测试的卡片注入（APP-06v；只在 Debug / Staging 编译，Release 制品扫描查环境变量名 `COULI_FAKE_PRODUCT_CARDS`
/// 与类型名 DebugFakeProductCards / DebugFakeProductImages）。
///
/// 环境变量 `COULI_FAKE_PRODUCT_CARDS` = UTF-8 JSON 数组（商品卡对象，原样来自 specs/search-product-vectors.json 的 visualCards）
/// 的 Base64。仅在本机假服务（`-CouliFakeLoginServer`）打开时生效：
/// - `GET /v1/products/<product_key>`：原样回数组里 product_key 相同的那张卡（不改任何字段）；
///   环境变量 `COULI_FAKE_PRODUCT_HOLD=<product_key>` 时这张卡不回答（停在加载态）；
/// - `GET /v1/products/search?q=visual`：按数组顺序只回这些卡（不分页、无兜底推荐）；
/// - open 仍按卡片 `link_id` 走 DebugFakeTrade 既有场景（未知值 = 默认未变方案）；
/// - `https://img.example.test/product-v/…` 图片在本机回答（`DebugFakeProductImages`：400 × 120 红 | 绿 | 蓝三段宽图，
///   `…/broken.png` 回 404），不连网。
enum DebugFakeProductCards {
    static let environmentKey = "COULI_FAKE_PRODUCT_CARDS"
    /// 让指定卡的 getProduct 挂住（UI 测试截加载骨架读屏）。
    static let holdKey = "COULI_FAKE_PRODUCT_HOLD"

    /// 注入的卡（进程启动后读一次；没有或解不开时为空，不接管任何请求）。
    nonisolated(unsafe) static let cards: [[String: Any]] = {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              let data = Data(base64Encoded: raw),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }()

    static var isActive: Bool {
        !cards.isEmpty
    }

    /// 注入卡先回答，不相关时交给购买场景（DebugFakeTrade）。
    static func answerOrTrade(path: String, query: [String: String], request: URLRequest,
                              body: [String: Any]) -> DebugFakeTrade.Answer? {
        answer(path: path, query: query, request: request, body: body)
            ?? DebugFakeTrade.answer(path: path, query: query, request: request, body: body)
    }

    /// 回答注入卡相关的请求；不相关时 nil（交给其他假场景）。
    static func answer(path: String, query: [String: String], request: URLRequest,
                       body: [String: Any]) -> DebugFakeTrade.Answer? {
        guard isActive else { return nil }
        // open：按 link_id 走 DebugFakeTrade 既有场景；注入卡的未知 link（默认未变方案）略放慢回答，
        // 让「正在打开」加载层在 UI 测试取样间隔内可见（只改假服务的回答时机，不改回答内容）。
        if path.hasPrefix("/v1/links/"), path.hasSuffix("/open"), !path.contains("/t-"),
           var answer = DebugFakeTrade.answer(path: path, query: query, request: request, body: body) {
            answer.delay = max(answer.delay, 2)
            return answer
        }
        if path == "/v1/products/search" {
            guard (query["q"] ?? "").contains("visual") else { return nil }
            let data: [String: Any] = [
                "items": cards, "next_cursor": NSNull(), "has_more": false, "fallback_items": [],
            ]
            return DebugFakeTrade.Answer(code: 0, data: DebugFakeSearch.json(data), delay: 0.3)
        }
        if path.hasPrefix("/v1/products/") {
            let key = String(path.dropFirst("/v1/products/".count)).removingPercentEncoding ?? ""
            guard let card = cards.first(where: { ($0["product_key"] as? String) == key }) else { return nil }
            // `COULI_FAKE_PRODUCT_HOLD=<product_key>`：这张卡的 getProduct 挂住不回答（停在详情加载态；搜索照常）
            let hold = ProcessInfo.processInfo.environment[holdKey] == key
            return DebugFakeTrade.Answer(code: 0, data: DebugFakeSearch.json(card), delay: hold ? 86400 : 0.3)
        }
        return nil
    }
}

/// 注入卡的商品测试位图（与 AppTests 的 ProductVisualImages 同一画法），只接管 `img.example.test/product-v/…`。
final class DebugFakeProductImages: URLProtocol {
    static let host = "img.example.test"

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host && request.url?.path.hasPrefix("/product-v/") == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let broken = url.path.hasSuffix("/broken.png")
        let response = HTTPURLResponse(
            url: url, statusCode: broken ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": broken ? "text/plain" : "image/png"]
        )
        client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: broken ? Data() : Self.stripes())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func stripes() -> Data {
        let size = CGSize(width: 400, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let colors: [[CGFloat]] = [[230, 40, 40], [40, 170, 60], [30, 90, 230]]
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let third = size.width / 3
            for (index, color) in colors.enumerated() {
                UIColor(red: color[0] / 255, green: color[1] / 255, blue: color[2] / 255, alpha: 1).setFill()
                context.fill(CGRect(x: third * CGFloat(index), y: 0, width: third + 1, height: size.height))
            }
        }
    }
}
#endif
