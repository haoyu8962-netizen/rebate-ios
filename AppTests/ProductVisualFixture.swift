import Foundation
import UIKit
import XCTest

/// APP-06v（商品详情视觉）三端同一份截图数据：`specs/search-product-vectors.json` 的 `visualCards`（G-D16，与 Android 已合入文件
/// 逐字节相同）。只读，不改既有判定组。
enum ProductVisualCards {
    /// 截图图片主机（G-D16：图片字段是测试位图键，不连网）。
    static let imageHost = "img.example.test"
    /// 错误响应的 trace_id（trace6 = 000123，与 Android 基准同字）。
    static let traceId = "0199a3b4-5c6d-7e8f-9a0b-1c2d3e000123"

    static func repo() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract.lock").path) {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }

    static func root() throws -> [String: Any] {
        let data = try Data(contentsOf: repo().appendingPathComponent("specs/search-product-vectors.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["visualCards"] as? [String: Any], "共用向量文件缺 visualCards 组（G-D16）")
    }

    /// 一张完整商品卡（原样）：先找共用 visualCards，再找 iOS v2 新增的 `specs/product-visual-extra-cards.json`（评审 r1 S2-4-5）。
    static func card(_ id: String) throws -> [String: Any] {
        let cards = try XCTUnwrap(root()["cards"] as? [String: Any])
        if let card = cards[id] as? [String: Any] {
            return card
        }
        let data = try Data(contentsOf: repo().appendingPathComponent("specs/product-visual-extra-cards.json"))
        let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let more = try XCTUnwrap(extra["cards"] as? [String: Any])
        return try XCTUnwrap(more[id] as? [String: Any], "visualCards 与 product-visual-extra-cards 都没有 \(id)")
    }

    /// 截图用的卡：`quoted_at` 的**日期**换成运行当天（上海日历），时刻 10:00 / 10:32 与时区不变。
    ///
    /// 原因：详情页取价时间按 BR-TEXT-11 与真实时钟比较（今天 / 昨天 / 月-日），页面没有可注入的时钟；固定日期的卡隔天显示会变，
    /// 截图不可比。换成当天后恒为「今天 10:00」，与 Android 基准（固定时钟同日）同字。不改其余任何字段。
    static func screenshotCard(_ id: String) throws -> [String: Any] {
        try today(card(id))
    }

    /// 同上，作用于已有的卡（测试内派生的卡用）。
    static func today(_ source: [String: Any]) -> [String: Any] {
        var card = source
        if let quoted = card["quoted_at"] as? String, quoted.count > 10 {
            card["quoted_at"] = todayInShanghai() + String(quoted.dropFirst(10))
        }
        return card
    }

    static func todayInShanghai(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 成功响应包（data 为商品卡）。
    static func envelope(_ data: [String: Any]) -> String {
        let payload: [String: Any] = ["code": 0, "msg": "", "data": data, "trace_id": traceId]
        let bytes = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(bytes: bytes, encoding: .utf8) ?? "{}"
    }

    /// 错误响应包。
    static func errorEnvelope(_ code: Int) -> String {
        "{\"code\":\(code),\"msg\":\"\",\"data\":{},\"trace_id\":\"\(traceId)\"}"
    }
}

/// 截图用的商品测试位图（G-D16）：只拦 `img.example.test/product-v/…`，按地址回 400×120 的红 | 绿 | 蓝三段宽图。
///
/// - 宽图放进 358×264 的头图框：完整显示（contain）时上下留出占位底、左缘红右缘蓝；裁切（fill）时只剩中间的绿段——用来区分。
/// - 三段都是高饱和色：下架去色（饱和度 0）后三段都应变灰。
/// - `…/broken.png` 回 404（失败占位）。
final class ProductVisualImages: URLProtocol, @unchecked Sendable {
    static let red = (r: 230, g: 40, b: 40)
    static let green = (r: 40, g: 170, b: 60)
    static let blue = (r: 30, g: 90, b: 230)
    static let size = CGSize(width: 400, height: 120)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var urls: [String] = []

    static func install() {
        reset()
        URLProtocol.registerClass(ProductVisualImages.self)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(ProductVisualImages.self)
    }

    static func reset() {
        lock.withLock { urls = [] }
    }

    static var served: [String] {
        lock.withLock { urls }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == ProductVisualCards.imageHost && request.url?.path.hasPrefix("/product-v/") == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    static func stripes() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let third = size.width / 3
            for (index, color) in [red, green, blue].enumerated() {
                UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255,
                        alpha: 1).setFill()
                context.fill(CGRect(x: third * CGFloat(index), y: 0, width: third + 1, height: size.height))
            }
        }
    }

    /// 像真实网络一样异步回答。
    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let client = client
        let broken = url.path.hasSuffix("/broken.png")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            let response = HTTPURLResponse(url: url, statusCode: broken ? 404 : 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": broken ? "text/plain" : "image/png"])
            client?.urlProtocol(self, didReceive: response ?? URLResponse(), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: broken ? Data() : Self.stripes())
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.withLock { Self.urls.append(url.absoluteString) }
        }
    }

    override func stopLoading() {}
}
