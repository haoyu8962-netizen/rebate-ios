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

    /// 回答带按钮提示的购买场景（open 放慢，见 `answer`）。
    private static let noticeScenarios = ["t-503", "t-blocked", "t-norebate", "t-rebind"]

    /// 改价类场景回答之后，这张注入卡的 getProduct 按新报价回答（补齐券前价、券额；与 Android / 画板同值，评审 r1 S2-6）。
    private nonisolated(unsafe) static let repricedFields: [String: [String: Any]] = [
        "t-price": ["price_fen": 5990, "coupon_fen": 1000, "final_price_fen": 4990, "est_net_price_fen": 4859,
                    "rebate_min_fen": 131, "rebate_max_fen": 250],
        "t-pricegone": ["price_fen": 5990, "coupon_fen": 1000, "final_price_fen": 4990, "est_net_price_fen": 4990,
                        "rebate_min_fen": 0, "rebate_max_fen": 0],
        "t-coupon": ["price_fen": 5678, "coupon_fen": 0, "final_price_fen": 5678, "est_net_price_fen": 5444],
    ]
    private static let lock = NSLock()
    /// 已回过改价类 open 的 link（之后 getProduct 按新报价回答）。
    private nonisolated(unsafe) static var repriced: Set<String> = []

    /// 取价时间：注入卡的 quoted_at 加 32 分钟（visualCards.purchase 的 open 回答在 10:32，画板与 Android 同；固定值，截图基准
    /// 不随运行时刻变）。解不开时原样。
    private static func purchaseQuotedAt(_ quoted: Any?) -> String? {
        guard let quoted = quoted as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let date = formatter.date(from: quoted) else { return quoted }
        return formatter.string(from: date.addingTimeInterval(32 * 60))
    }

    /// open 回答的 data 里有 quoted_at 时换成 `quoted`（没有或解不开时原样返回）。
    private static func pinQuotedAt(_ data: String, to quoted: String?) -> String {
        guard let quoted,
              var object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
              object["quoted_at"] != nil
        else { return data }
        object["quoted_at"] = quoted
        return DebugFakeSearch.json(object)
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
        // APP-06v-b：带按钮提示的场景（50303 / 30153 / 30103 / 30151）同样放慢（「稍后再试」后再点购买、【仍去购买（无返利）】
        // 各发一次 open，UI 测试要看到每次的加载层）；回答里的 quoted_at 换成注入卡自己的取价时间，截图基准不随运行时刻变。
        // 评审 r1 S1-2：按请求体的 no_rebate 区分——带按钮提示的场景收到无返利 open（no_rebate=true）时按正常外跳方案回答
        // （与服务端一致：无返利购买不再复核返利），并把每次 open 的 link 与 no_rebate 记进 DebugPurchaseLog 供 UI 测试读取。
        if path.hasPrefix("/v1/links/"), path.hasSuffix("/open") {
            let link = String(path.dropFirst("/v1/links/".count).dropLast("/open".count)).removingPercentEncoding ?? ""
            let noRebate = (body["no_rebate"] as? Bool) == true
            DebugPurchaseLog.record("open:\(link):no_rebate=\(noRebate ? 1 : 0)")
            let notice = noticeScenarios.contains(link)
            let routed = notice && noRebate ? "/v1/links/\(link)-r1/open" : path
            guard let answer = DebugFakeTrade.answer(path: routed, query: query, request: request, body: body) else {
                return nil
            }
            if answer.code == 0, repricedFields[link] != nil {
                _ = lock.withLock { repriced.insert(link) }
            }
            let slow = !link.hasPrefix("t-") || notice
            let card = cards.first { ($0["link_id"] as? String) == link }
            return DebugFakeTrade.Answer(
                code: answer.code, data: pinQuotedAt(answer.data, to: purchaseQuotedAt(card?["quoted_at"])),
                headers: answer.headers, delay: slow ? max(answer.delay, 2) : answer.delay
            )
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
            guard var card = cards.first(where: { ($0["product_key"] as? String) == key }) else { return nil }
            if let link = card["link_id"] as? String, lock.withLock({ repriced.contains(link) }),
               let fresh = repricedFields[link] {
                card.merge(fresh) { $1 }
                card["quoted_at"] = purchaseQuotedAt(card["quoted_at"]) ?? card["quoted_at"]
            }
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
